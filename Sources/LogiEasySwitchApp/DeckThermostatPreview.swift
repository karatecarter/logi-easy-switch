import Foundation
import CoreFoundation

/// Optimistic display only: the action still runs unchanged and HA remains authoritative.
struct DeckThermostatPreview {
    struct Ticket { let groupID: UUID; let id: UUID }
    private struct Entry {
        let id: UUID
        let expected: Double
        let expires: Date
        var actual: String
    }
    private var entries: [UUID: Entry] = [:]
    private static let pattern = try! NSRegularExpression(pattern: "(?i)\\bset to\\s+(-?[0-9]+(?:\\.[0-9]+)?)(?![0-9.])")

    mutating func begin(action: DeckButton, configuration: DeckConfiguration, text: String, now: Date = Date()) -> (Ticket, String)? {
        guard let action = try? DeckTicks.resolved(action, ticks: 1), action.kind == "homeassistant", ["increase", "decrease"].contains(action.settings["thermostatRole"] ?? ""),
              let group = configuration.buttons.first(where: { $0.id == action.parentID && $0.settings["preset"] == "thermostat" }),
              let data = try? DeckHomeAssistantClient.actionData(action.settings["data"] ?? "{}"),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let increment = body["increment"] as? NSNumber, CFGetTypeID(increment) != CFBooleanGetTypeID(),
              increment.doubleValue.isFinite, increment.doubleValue != 0,
              let target = Self.target(in: text) else { return nil }
        let expected = target.value + increment.doubleValue
        guard expected.isFinite else { return nil }
        let id = UUID()
        entries[group.id] = Entry(id: id, expected: expected, expires: now.addingTimeInterval(10), actual: entries[group.id]?.actual ?? text)
        return (Ticket(groupID: group.id, id: id), Self.replacingTarget(in: text, with: expected))
    }

    mutating func reconcile(groupID: UUID, actual: String, now: Date = Date()) -> (text: String, pending: Bool) {
        guard var entry = entries[groupID] else { return (actual, false) }
        guard let target = Self.target(in: actual), now < entry.expires, abs(target.value - entry.expected) > 0.00001 else {
            entries.removeValue(forKey: groupID)
            return (actual, false)
        }
        entry.actual = actual
        entries[groupID] = entry
        return (Self.replacingTarget(in: actual, with: entry.expected), true)
    }
    mutating func cancel(_ ticket: Ticket) -> String? {
        guard let entry = entries[ticket.groupID], entry.id == ticket.id else { return nil }
        entries.removeValue(forKey: ticket.groupID)
        return entry.actual
    }
    mutating func reset() -> [UUID: String] {
        let actual = entries.mapValues(\.actual)
        entries.removeAll()
        return actual
    }
    private static func target(in text: String) -> (value: Double, range: NSRange)? {
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: range)
        guard matches.count == 1, let match = matches.first,
              let numberRange = Range(match.range(at: 1), in: text),
              let value = Double(text[numberRange]), value.isFinite else { return nil }
        // Range setpoints need script-specific knowledge; do not guess which bound moves.
        let suffix = text[numberRange.upperBound...].trimmingCharacters(in: .whitespaces)
        if let first = suffix.first, ["–", "—", "-"].contains(first) { return nil }
        return (value, match.range(at: 1))
    }
    private static func replacingTarget(in text: String, with value: Double) -> String {
        guard let target = target(in: text), let range = Range(target.range, in: text) else { return text }
        let number = String(format: "%.10g", locale: Locale(identifier: "en_US_POSIX"), value)
        return text.replacingCharacters(in: range, with: number)
    }
}
