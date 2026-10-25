import Foundation

enum DeckTicks {
    static func sign(_ button: DeckButton) -> Int? {
        guard button.kind == "homeassistant", let data = try? DeckHomeAssistantClient.actionData(button.settings["data"] ?? "{}"),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let value = body["increment"] as? String else { return nil }
        return value == "ticks" ? 1 : value == "-ticks" ? -1 : nil
    }
    static func resolved(_ button: DeckButton, ticks: Int) throws -> DeckButton {
        guard let sign = sign(button) else { return button }
        guard ticks > 0, ticks <= 10000 else { throw DeckError.message("Invalid adjustment tap count.") }
        let data = try DeckHomeAssistantClient.actionData(button.settings["data"] ?? "{}")
        var body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        body["increment"] = sign * ticks
        var result = button
        result.settings["data"] = String(decoding: try JSONSerialization.data(withJSONObject: body, options: .sortedKeys), as: UTF8.self)
        return result
    }
}

extension DeckConfiguration {
    func migratingThermostatTicks() -> DeckConfiguration {
        var updated = migratingLegacyThermostatIncrement()
        let groups = Set(buttons.filter { $0.kind == "group" && $0.settings["preset"] == "thermostat" }.map(\.id))
        for index in updated.buttons.indices {
            let button = updated.buttons[index]
            guard button.parentID.map({ groups.contains($0) }) == true,
                  let role = button.settings["thermostatRole"], ["increase", "decrease"].contains(role),
                  let source = button.settings["data"], let data = source.data(using: .utf8),
                  var body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            body["increment"] = role == "increase" ? "ticks" : "-ticks"
            guard let encoded = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys) else { continue }
            updated.buttons[index].settings["data"] = String(decoding: encoded, as: UTF8.self)
        }
        return updated
    }
}

/// Replace a scheduled flush on each tap; cancelled tasks never dispatch an action.
@MainActor final class DeckTickDebouncer {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var versions: [UUID: UUID] = [:]
    private let delay: Duration
    init(delay: Duration = .seconds(1)) { self.delay = delay }
    func schedule(_ id: UUID, operation: @escaping @MainActor () async -> Void) {
        tasks[id]?.cancel()
        let version = UUID()
        versions[id] = version
        let delay = delay
        tasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await operation()
            guard let self, self.versions[id] == version else { return }
            self.tasks.removeValue(forKey: id)
            self.versions.removeValue(forKey: id)
        }
    }
    deinit { for task in tasks.values { task.cancel() } }
}
