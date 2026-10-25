import Foundation

@MainActor
final class MQTTCoordinator: ObservableObject {
    enum State: Equatable {
        case disabled
        case connecting
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .disabled: "Disabled"
            case .connecting: "Connecting…"
            case .connected: "Connected"
            case .failed(let message): message
            }
        }
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var currentTarget: String?
    var onDeviceTargetRequested: ((DeckLogiRequest) -> Void)?
    var onTargetRequested: ((String) -> Void)?
    var onStateChanged: (() -> Void)?

    private var commandTopic: String { "\(configuration.topicPrefix)/command/target" }
    private var deviceCommandTopic: String { "\(configuration.topicPrefix)/command/devices" }
    private var stateTopic: String { "\(configuration.topicPrefix)/state/current-target" }
    private var configuration = MQTTConfiguration()
    private var password = ""
    private var targets: [String] = []
    private var client: MQTTClient?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectDelay: TimeInterval = 2
    private var intentionallyDisconnected = false
    private var localCurrentTarget: String?

    func configure(_ configuration: MQTTConfiguration, password: String, targets: [String]) {
        let connectionChanged = self.configuration != configuration || self.password != password
        // Report the old namespace offline before replacing its configuration.
        if connectionChanged { publishMacAvailability(online: false) }
        self.configuration = configuration
        self.password = password
        self.targets = Array(Set(targets.filter { !$0.isEmpty })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        guard configuration.isUsable else {
            intentionallyDisconnected = true
            reconnectWorkItem?.cancel()
            publishMacAvailability(online: false)
            client?.disconnect()
            client = nil
            state = configuration.enabled ? .failed(configuration.validationMessage ?? "Broker settings incomplete") : .disabled
            return
        }
        if connectionChanged || client == nil {
            intentionallyDisconnected = true
            publishMacAvailability(online: false)
            client?.disconnect()
            intentionallyDisconnected = false
            connect()
        } else if state == .connected {
            publishDiscovery()
        }
    }

    func requestTarget(_ target: String) -> Bool {
        guard state == .connected, targets.contains(target) else { return false }
        currentTarget = target
        onStateChanged?()
        client?.publish(topic: commandTopic, string: target)
        return true
    }

    func requestDevices(_ request: DeckLogiRequest) -> Bool {
        if request.devices == .both { return requestTarget(request.target) }
        guard state == .connected, targets.contains(request.target), let data = try? JSONEncoder().encode(request) else { return false }
        client?.publish(topic: deviceCommandTopic, payload: data)
        return true
    }

    func isLocalOwner(_ computer: String) -> Bool {
        localCurrentTarget?.compare(computer, options: .caseInsensitive) == .orderedSame
    }

    func publishCurrentTarget(_ target: String) {
        localCurrentTarget = target
        currentTarget = target
        if state == .connected { client?.publish(topic: stateTopic, string: target, retain: true) }
        onStateChanged?()
    }

    func clearLocalOwnership() {
        localCurrentTarget = nil
    }

    func stop() {
        intentionallyDisconnected = true
        reconnectWorkItem?.cancel()
        publishMacAvailability(online: false)
        client?.disconnect()
        client = nil
        state = .disabled
    }

    private func connect() {
        reconnectWorkItem?.cancel()
        guard configuration.isUsable else { return }
        state = .connecting
        let storedID = stableClientID()
        let availabilityTopic = "\(configuration.topicPrefix)/mac/\(storedID)/availability"
        let mqtt = MQTTClient(
            configuration: configuration,
            password: password,
            clientID: "logi-easy-switch-\(storedID)",
            will: (availabilityTopic, "offline")
        )
        client = mqtt
        mqtt.onConnected = { [weak self, weak mqtt] in
            Task { @MainActor in
                guard let self, self.client === mqtt else { return }
                self.state = .connected
                self.reconnectDelay = 2
                mqtt?.subscribe(self.commandTopic)
                mqtt?.subscribe(self.deviceCommandTopic)
                mqtt?.subscribe(self.stateTopic)
                self.publishDiscovery()
                self.publishMacAvailability(online: true)
                if let target = self.localCurrentTarget {
                    mqtt?.publish(topic: self.stateTopic, string: target, retain: true)
                }
                self.onStateChanged?()
            }
        }
        let subscribedTopics = [commandTopic, deviceCommandTopic, stateTopic]
        mqtt.onMessage = { [weak self, weak mqtt] topic, payload, retained in
            guard subscribedTopics.contains(topic), payload.count <= 1_024 else { return }
            Task { @MainActor in
                guard let self, self.client === mqtt, let value = String(data: payload, encoding: .utf8) else { return }
                if topic == self.commandTopic,
                   let target = MQTTCommandPolicy.acceptedTarget(payload: payload, retained: retained, targets: self.targets) {
                    self.onTargetRequested?(target)
                }
                if topic == self.deviceCommandTopic,
                   let request = DeckLogiRequest.accepted(payload: payload, retained: retained, targets: self.targets) {
                    self.onDeviceTargetRequested?(request)
                }
                if topic == self.stateTopic {
                    self.currentTarget = value
                    self.onStateChanged?()
                }
            }
        }
        mqtt.onDisconnected = { [weak self, weak mqtt] error in
            Task { @MainActor in
                guard let self, self.client === mqtt else { return }
                self.client = nil
                if self.intentionallyDisconnected { return }
                self.state = .failed(error?.localizedDescription ?? "Disconnected")
                self.onStateChanged?()
                self.scheduleReconnect()
            }
        }
        mqtt.connect()
    }

    private func scheduleReconnect() {
        guard configuration.isUsable else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.connect() }
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay, execute: work)
        reconnectDelay = min(reconnectDelay * 2, 30)
    }

    private var discoveryID: String { configuration.topicPrefix == "logi-easy-switch" ? "logi_easy_switch" : "logi_namespace_\(configuration.topicPrefix)" }

    private func publishDiscovery() {
        guard configuration.discoveryEnabled, state == .connected else { return }
        let options = targets.isEmpty ? [configuration.computerName] : targets
        let device: [String: Any] = [
            "identifiers": ["\(configuration.topicPrefix)-network"],
            "name": "Switchboard",
            "manufacturer": "Switchboard",
            "model": "Network Controller",
        ]
        let origin: [String: Any] = ["name": "Switchboard", "sw_version": "0.2.0", "support_url": "https://github.com/karatecarter/logi-easy-switch"]
        let select: [String: Any] = [
            "name": "Target computer",
            "unique_id": "\(discoveryID)_target",
            "command_topic": commandTopic,
            "state_topic": stateTopic,
            "options": options,
            "device": device,
            "origin": origin,
            "icon": "mdi:keyboard-outline",
        ]
        let sensor: [String: Any] = [
            "name": "Current computer",
            "unique_id": "\(discoveryID)_current_computer",
            "state_topic": stateTopic,
            "device": device,
            "origin": origin,
            "icon": "mdi:monitor",
        ]
        let id = stableClientID()
        let availability: [String: Any] = [
            "name": "\(configuration.computerName) availability",
            "unique_id": "\(discoveryID)_\(id)_availability",
            "state_topic": "\(configuration.topicPrefix)/mac/\(id)/availability",
            "payload_on": "online",
            "payload_off": "offline",
            "device_class": "connectivity",
            "device": device,
            "origin": origin,
        ]
        publishJSON(select, topic: "homeassistant/select/\(discoveryID)/target/config")
        publishJSON(sensor, topic: "homeassistant/sensor/\(discoveryID)/current_computer/config")
        publishJSON(availability, topic: "homeassistant/binary_sensor/\(discoveryID)/\(id)_availability/config")
    }

    private func publishMacAvailability(online: Bool) {
        let id = stableClientID()
        client?.publish(topic: "\(configuration.topicPrefix)/mac/\(id)/availability", string: online ? "online" : "offline", retain: true)
        client?.publish(topic: "\(configuration.topicPrefix)/mac/\(id)/name", string: configuration.computerName, retain: true)
    }

    private func publishJSON(_ object: [String: Any], topic: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        client?.publish(topic: topic, payload: data, retain: true)
    }

    private func stableClientID() -> String {
        let key = "mqttClientID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    static func test(configuration: MQTTConfiguration, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard configuration.isUsable else { completion(.failure(MQTTClient.ClientError.invalidConfiguration)); return }
        let client = MQTTClient(configuration: configuration, password: password, clientID: "logi-easy-switch-test-\(UUID().uuidString.prefix(8))")
        var finished = false
        func finish(_ result: Result<Void, Error>) {
            guard !finished else { return }
            finished = true
            completion(result)
            client.disconnect()
        }
        client.onConnected = { Task { @MainActor in finish(.success(())) } }
        client.onDisconnected = { error in
            Task { @MainActor in finish(.failure(error ?? MQTTClient.ClientError.disconnected("Disconnected"))) }
        }
        client.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            finish(.failure(MQTTClient.ClientError.disconnected("Connection timed out")))
        }
    }
}
