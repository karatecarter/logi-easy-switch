import Foundation

struct DeckSharedGlobals: Codable, Equatable {
    var dismissAfterAction: Bool
    var actionDelay: Double
    var idleTimeout: Double
    var dismissAfterOpening: Bool?
    init(_ shared: DeckSharedConfiguration) {
        dismissAfterAction = shared.dismissAfterAction; actionDelay = shared.actionDelay
        idleTimeout = shared.idleTimeout; dismissAfterOpening = shared.dismissAfterOpening
    }
}

struct DeckSharedVersion: Codable, Equatable, Identifiable {
    var id = UUID().uuidString.lowercased()
    var clock: [String: Int]
    var writer: String
    var device: String
    var button: DeckButton?
    var globals: DeckSharedGlobals?
    var order: [UUID]?
    func sameContent(as other: Self) -> Bool { button == other.button && globals == other.globals && order == other.order }
}

struct DeckSharedDocument: Codable, Equatable {
    var group: String
    var clock: [String: Int] = [:]
    var records: [String: [DeckSharedVersion]] = [:]

    static func dominates(_ lhs: [String: Int], _ rhs: [String: Int]) -> Bool {
        rhs.allSatisfy { lhs[$0.key, default: 0] >= $0.value } && lhs != rhs
    }
    static func joinedClock(_ lhs: [String: Int], _ rhs: [String: Int]) -> [String: Int] {
        lhs.merging(rhs, uniquingKeysWith: max)
    }
    private static func mergeVersions(_ values: [DeckSharedVersion]) -> [DeckSharedVersion] {
        var unique: [String: DeckSharedVersion] = [:]
        for value in values { unique[value.id] = value }
        let candidates = Array(unique.values)
        return candidates.filter { value in !candidates.contains(where: { dominates($0.clock, value.clock) }) }
            .sorted { ($0.writer, $0.id) < ($1.writer, $1.id) }
    }

    func merging(_ other: Self) throws -> Self {
        guard group == other.group else { throw DeckError.message("Sync group does not match.") }
        var result = self
        result.clock = Self.joinedClock(clock, other.clock)
        for key in Set(records.keys).union(other.records.keys) {
            let combined = (records[key] ?? []) + (other.records[key] ?? [])
            // A stable event ID must always identify the same event.
            var events: [String: DeckSharedVersion] = [:]
            for event in combined {
                if let existing = events[event.id], existing != event { throw DeckError.message("Conflicting sync event identifiers.") }
                events[event.id] = event
            }
            result.records[key] = Self.mergeVersions(Array(events.values))
        }
        try result.validate()
        return result
    }
    var conflicts: [String] {
        records.keys.filter { key in
            guard key != "order", let versions = records[key], let first = versions.first else { return false }
            return versions.contains { !$0.sameContent(as: first) }
        }.sorted()
    }
    private func winner(_ key: String) -> DeckSharedVersion? { records[key]?.first }

    func materialized() -> DeckSharedConfiguration {
        var configuration = DeckConfiguration()
        if let global = winner("globals")?.globals {
            configuration.dismissAfterAction = global.dismissAfterAction
            configuration.actionDelay = global.actionDelay
            configuration.idleTimeout = global.idleTimeout
            configuration.dismissAfterOpening = global.dismissAfterOpening
        }
        let alive = records.filter { UUID(uuidString: $0.key) != nil }.compactMapValues { $0.first?.button }
        var order: [UUID] = []
        // Concurrent additions/reorders keep all live buttons, in deterministic order.
        for version in records["order"] ?? [] {
            for id in version.order ?? [] where !order.contains(id) { order.append(id) }
        }
        for id in alive.values.map(\.id).sorted(by: { $0.uuidString < $1.uuidString }) where !order.contains(id) { order.append(id) }
        configuration.buttons = order.compactMap { alive[$0.uuidString.lowercased()] }
        let indexed = Dictionary(uniqueKeysWithValues: configuration.buttons.map { ($0.id, $0) })
        // Concurrent folder deletion/moves must never hide surviving children or create navigation cycles.
        for index in configuration.buttons.indices {
            var parent = configuration.buttons[index].parentID
            var visited: Set<UUID> = [configuration.buttons[index].id]
            while let id = parent {
                guard visited.insert(id).inserted, let owner = indexed[id], ["folder", "group"].contains(owner.kind) else {
                    configuration.buttons[index].parentID = nil
                    break
                }
                parent = owner.parentID
            }
        }
        return DeckSharedConfiguration(configuration)
    }
    mutating func edit(from baseline: DeckSharedConfiguration, to updated: DeckSharedConfiguration, writer: String, device: String) throws {
        try updated.validate()
        let before = Dictionary(uniqueKeysWithValues: baseline.buttons.map { ($0.id.uuidString.lowercased(), $0) })
        let after = Dictionary(uniqueKeysWithValues: updated.buttons.map { ($0.id.uuidString.lowercased(), $0) })
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
        let globalsChanged = DeckSharedGlobals(baseline) != DeckSharedGlobals(updated) || records["globals"] == nil
        let orderChanged = baseline.buttons.map(\.id) != updated.buttons.map(\.id) || records["order"] == nil
        guard !changed.isEmpty || globalsChanged || orderChanged else { return }
        guard clock[writer, default: 0] < Int.max - 1 else { throw DeckError.message("Sync counter limit reached.") }
        clock[writer, default: 0] += 1
        for key in changed { records[key] = [DeckSharedVersion(clock: clock, writer: writer, device: device, button: after[key])] }
        if globalsChanged { records["globals"] = [DeckSharedVersion(clock: clock, writer: writer, device: device, globals: DeckSharedGlobals(updated))] }
        if orderChanged { records["order"] = [DeckSharedVersion(clock: clock, writer: writer, device: device, order: updated.buttons.map(\.id))] }
        try validate()
    }
    mutating func resolve(key: String, versionID: String, writer: String, device: String) throws {
        guard var selected = records[key]?.first(where: { $0.id == versionID }) else { return }
        guard clock[writer, default: 0] < Int.max - 1 else { throw DeckError.message("Sync counter limit reached.") }
        clock[writer, default: 0] += 1
        selected.id = UUID().uuidString.lowercased(); selected.clock = clock; selected.writer = writer; selected.device = device
        records[key] = [selected]
        try validate()
    }
    func validate() throws {
        guard UUID(uuidString: group) != nil, clock.count <= 64, records.count <= 1500,
              clock.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value > 0 && $0.value < Int.max }) else { throw DeckError.message("Invalid shared sync document.") }
        for (key, versions) in records {
            guard key == "globals" || key == "order" || UUID(uuidString: key) != nil,
                  !versions.isEmpty, versions.count <= 64 else { throw DeckError.message("Invalid shared records.") }
            for version in versions {
                guard UUID(uuidString: version.id) != nil, UUID(uuidString: version.writer) != nil,
                      !version.clock.isEmpty, version.clock.count <= 64, version.clock[version.writer, default: 0] > 0,
                      version.clock.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value > 0 && $0.value <= clock[$0.key, default: 0] }),
                      version.button == nil || version.button?.id.uuidString.lowercased() == key,
                      (key != "globals" || version.globals != nil), (key != "order" || version.order != nil),
                      version.order?.count ?? 0 <= 1500 else { throw DeckError.message("Invalid shared record version.") }
            }
        }
        try materialized().validate()
    }
}

struct DeckSharedPeerEnvelope: Codable {
    var schema = 2
    var source: String
    var document: DeckSharedDocument
    static func decode(_ data: Data, source: String, group: String) throws -> Self {
        guard data.count <= DeckSyncTransfer.maximumSnapshot else { throw DeckError.message("Shared configuration exceeds 4 MB.") }
        let envelope = try JSONDecoder().decode(Self.self, from: data)
        guard envelope.schema == 2, envelope.source == source, envelope.document.group == group else { throw DeckError.message("Shared group or peer mismatch.") }
        try envelope.document.validate()
        return envelope
    }
}
