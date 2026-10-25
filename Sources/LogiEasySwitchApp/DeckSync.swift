import Foundation

struct DeckSharedConfiguration: Codable, Equatable {
    var buttons: [DeckButton]
    var dismissAfterAction: Bool
    var actionDelay: Double
    var idleTimeout: Double
    var dismissAfterOpening: Bool?

    init(_ configuration: DeckConfiguration) {
        buttons = configuration.buttons.map { button in
            var shared = button
            shared.settings.removeValue(forKey: "path")
            shared.settings.removeValue(forKey: "interpreter")
            return shared
        }
        dismissAfterAction = configuration.dismissAfterAction
        actionDelay = configuration.actionDelay
        idleTimeout = configuration.idleTimeout
        dismissAfterOpening = configuration.dismissAfterOpening
    }
    func applying(to local: DeckConfiguration) -> DeckConfiguration {
        var result = local
        let existing = Dictionary(local.buttons.map { ($0.id, $0.settings) }, uniquingKeysWith: { first, _ in first })
        result.buttons = buttons.map { button in
            var merged = button
            for key in ["path", "interpreter"] {
                merged.settings.removeValue(forKey: key)
                if let value = existing[button.id]?[key] { merged.settings[key] = value }
            }
            return merged
        }
        result.dismissAfterAction = dismissAfterAction
        result.actionDelay = actionDelay
        result.idleTimeout = idleTimeout
        result.dismissAfterOpening = dismissAfterOpening
        return result
    }
    func validate() throws {
        guard buttons.count <= 500, Set(buttons.map(\.id)).count == buttons.count,
              actionDelay.isFinite, idleTimeout.isFinite else { throw DeckError.message("Invalid shared shortcut configuration.") }
        let indexed = Dictionary(uniqueKeysWithValues: buttons.map { ($0.id, $0) })
        for button in buttons {
            guard button.delay.isFinite, button.returnAfterAction?.delay.isFinite != false else { throw DeckError.message("Invalid shortcut delay.") }
            var visited: Set<UUID> = [button.id]
            var parent = button.parentID
            while let id = parent {
                guard visited.insert(id).inserted, let owner = indexed[id], ["folder", "group"].contains(owner.kind) else { throw DeckError.message("Shared shortcuts have invalid folders or a folder cycle.") }
                parent = owner.parentID
            }
        }
    }
}

struct DeckSyncEnvelope: Codable {
    var schema = 1
    var source: String
    var revision: Int
    var configuration: DeckSharedConfiguration
    static let maximumPayload = 60_000
    static func decode(_ data: Data, source: String) throws -> Self {
        guard data.count <= maximumPayload else { throw DeckError.message("Shared shortcut configuration exceeds 60 KB.") }
        let envelope = try JSONDecoder().decode(Self.self, from: data)
        guard envelope.schema == 1, envelope.source == source, envelope.revision > 0 else { throw DeckError.message("Unsupported shortcut snapshot or publisher mismatch.") }
        try envelope.configuration.validate()
        return envelope
    }
}

struct DeckSyncSettings: Codable, Equatable {
    enum Role: String, Codable, CaseIterable { case off = "Off", publisher = "Publish from this Mac", follower = "Follow another Mac" }
    var role: Role = .off
    var source = ""
}

@MainActor final class DeckSyncCoordinator: ObservableObject {
    @Published var settings: DeckSyncSettings { didSet {
        defaults.set(try? JSONEncoder().encode(settings), forKey: "deckSyncSettings.v1")
        reconnect()
    } }
    @Published private(set) var status = "Sync is off."
    let publisherID: String
    var isFollower: Bool { settings.role == .follower }
    private let store: DeckStore
    private var broker = MQTTConfiguration()
    private var password = ""
    private var client: MQTTClient?
    private var connected = false
    private var configured = false
    private var retry: Task<Void, Never>?
    private var pendingPublish: Task<Void, Never>?
    private var retryDelay = 2.0
    private var lastShared: DeckSharedConfiguration?
    private let defaults: UserDefaults
    private let backup: (DeckConfiguration) throws -> Void
    private var topic: String { "\(broker.topicPrefix)/shortcuts/config/\(source)" }
    private var source: String { isFollower ? settings.source.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) : publisherID }
    private var receiptKey: String { "deckSync.received.\(broker.host):\(broker.port)/\(broker.topicPrefix)/\(source)" }

    init(store: DeckStore, defaults: UserDefaults = .standard, backup: @escaping (DeckConfiguration) throws -> Void = DeckSyncBackup.save) {
        self.store = store
        self.defaults = defaults
        self.backup = backup
        settings = (try? JSONDecoder().decode(DeckSyncSettings.self, from: defaults.data(forKey: "deckSyncSettings.v1") ?? Data())) ?? DeckSyncSettings()
        publisherID = defaults.string(forKey: "deckSyncPublisherID") ?? UUID().uuidString.lowercased()
        defaults.set(publisherID, forKey: "deckSyncPublisherID")
    }
    func configure(broker: MQTTConfiguration, password: String) {
        guard !configured || self.broker != broker || self.password != password else { return }
        configured = true
        self.broker = broker
        self.password = password
        reconnect()
    }
    func stop() {
        retry?.cancel()
        pendingPublish?.cancel()
        client?.disconnect()
        client = nil
        connected = false
    }
    func reconnect() {
        stop()
        guard settings.role != .off else { status = "Sync is off."; return }
        guard broker.isUsable else { status = "Configure and enable MQTT in the main Settings window first."; return }
        guard UUID(uuidString: source) != nil else { status = "Enter the publisher ID shown on your editing Mac."; return }
        status = "Connecting…"
        let mqtt = MQTTClient(configuration: broker, password: password, clientID: "switchboard-sync-\(publisherID)")
        client = mqtt
        let subscribedTopic = topic
        mqtt.onConnected = { [weak self, weak mqtt] in
            Task { @MainActor in
                guard let self, self.client === mqtt else { return }
                self.connected = true
                self.retryDelay = 2
                if self.isFollower {
                    self.status = "Connected; waiting for the publisher's configuration."
                    mqtt?.subscribe(subscribedTopic)
                } else { self.publish(force: true) }
            }
        }
        mqtt.onMessage = { [weak self, weak mqtt] topic, payload, _ in
            guard topic == subscribedTopic else { return }
            Task { @MainActor in
                guard let self, self.client === mqtt, self.isFollower else { return }
                self.receive(payload)
            }
        }
        mqtt.onDisconnected = { [weak self, weak mqtt] error in
            Task { @MainActor in
                guard let self, self.client === mqtt else { return }
                self.connected = false
                self.status = "Offline; using local shortcuts. \(error?.localizedDescription ?? "Reconnecting…")"
                self.retry?.cancel()
                let delay = self.retryDelay
                self.retryDelay = min(30, delay * 2)
                self.retry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    self?.reconnect()
                }
            }
        }
        mqtt.connect()
    }
    func localConfigurationChanged() {
        guard settings.role == .publisher else { return }
        pendingPublish?.cancel()
        pendingPublish = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.publish(force: false)
        }
    }
    func publish(force: Bool) {
        guard settings.role == .publisher else { return }
        guard connected else { status = "Offline; local edits will publish when reconnected."; return }
        let shared = DeckSharedConfiguration(store.configuration)
        guard force || shared != lastShared else { return }
        do {
            try shared.validate()
            let previous = defaults.integer(forKey: "deckSyncRevision")
            guard previous < Int.max else { throw DeckError.message("Sync revision limit reached.") }
            let revision = previous + 1
            let envelope = DeckSyncEnvelope(source: publisherID, revision: revision, configuration: shared)
            let data = try JSONEncoder().encode(envelope)
            guard data.count <= DeckSyncEnvelope.maximumPayload else { throw DeckError.message("Shortcut configuration exceeds the 60 KB sync limit.") }
            defaults.set(revision, forKey: "deckSyncRevision")
            client?.publish(topic: topic, payload: data, retain: true)
            lastShared = shared
            status = "Sent revision \(revision) to the broker."
        } catch { status = error.localizedDescription }
    }
    func receive(_ data: Data) {
        guard isFollower else { return }
        do {
            let snapshot = try DeckSyncEnvelope.decode(data, source: source)
            let previousData = defaults.data(forKey: receiptKey)
            let previous = previousData.flatMap { try? DeckSyncEnvelope.decode($0, source: source) }
            guard snapshot.revision >= (previous?.revision ?? 0) else {
                status = "Up to date (revision \(previous?.revision ?? snapshot.revision))."
                return
            }
            if let previous, previous.revision == snapshot.revision, previous.configuration != snapshot.configuration {
                throw DeckError.message("Publisher sent conflicting snapshots with the same revision.")
            }
            let merged = snapshot.configuration.applying(to: store.configuration)
            if merged != store.configuration { try backup(store.configuration) }
            defaults.set(data, forKey: receiptKey)
            store.configuration = merged
            status = "Synced revision \(snapshot.revision)."
        } catch { status = "Could not apply shared shortcuts: \(error.localizedDescription)" }
    }
}

enum DeckSyncBackup {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Switchboard/ShortcutBackups", isDirectory: true)
    }
    static func save(_ configuration: DeckConfiguration) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString).json")
        try JSONEncoder().encode(configuration).write(to: url, options: [.atomic, .completeFileProtection])
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in files.dropFirst(10) { try manager.removeItem(at: file) }
    }
}
