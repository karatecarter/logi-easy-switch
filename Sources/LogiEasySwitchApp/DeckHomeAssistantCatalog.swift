import Foundation

struct DeckHAAction: Identifiable {
    var id: String
    var name: String
    var domains: [String]
    var responseRequired: Bool
}

struct DeckHAEntity: Decodable, Identifiable {
    var entity_id: String
    var state: String
    var attributes: Attributes
    var id: String { entity_id }
    var name: String { attributes.friendly_name ?? entity_id }
    struct Attributes: Decodable { var friendly_name: String? }
}

struct DeckHACatalog {
    var actions: [DeckHAAction]
    var entities: [DeckHAEntity]
    static func load(_ configuration: DeckConfiguration, token: String) async throws -> Self {
        async let services = DeckHomeAssistantClient.send(DeckHomeAssistantClient.makeRequest(configuration, token: token, path: "services"))
        async let states = DeckHomeAssistantClient.send(DeckHomeAssistantClient.makeRequest(configuration, token: token, path: "states"))
        return try await Self(actions: parseActions(services), entities: JSONDecoder().decode([DeckHAEntity].self, from: states).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }
    static func parseActions(_ data: Data) throws -> [DeckHAAction] {
        guard let groups = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw DeckError.message("Home Assistant returned an invalid action list.") }
        return groups.flatMap { group -> [DeckHAAction] in
            guard let domain = group["domain"] as? String, let services = group["services"] as? [String: [String: Any]] else { return [] }
            return services.map { service, metadata in
                let target = metadata["target"] as? [String: Any]
                let filters = (target?["entity"] as? [[String: Any]]) ?? (target?["entity"] as? [String: Any]).map { [$0] } ?? []
                let domains = filters.flatMap { filter -> [String] in
                    if let value = filter["domain"] as? String { return [value] }
                    return filter["domain"] as? [String] ?? []
                }
                let response = metadata["response"] as? [String: Any]
                return DeckHAAction(id: domain + "." + service, name: metadata["name"] as? String ?? service.replacingOccurrences(of: "_", with: " ").capitalized, domains: domains, responseRequired: response != nil && response?["optional"] as? Bool != true)
            }
        }.sorted { $0.id < $1.id }
    }
    func entities(for action: String) -> [DeckHAEntity] {
        var domains = actions.first { $0.id == action }?.domains ?? []
        let domain = String(action.split(separator: ".").first ?? "")
        if domains.isEmpty && ["light", "switch", "cover", "fan", "climate", "media_player", "lock", "input_boolean"].contains(domain) { domains = [domain] }
        return entities.filter { domains.isEmpty || domains.contains(String($0.id.split(separator: ".").first ?? "")) }
    }
}

enum DeckHATarget {
    static func entities(_ button: DeckButton) -> [String] {
        guard let data = try? DeckHomeAssistantClient.actionData(button.settings["data"] ?? "{}"), let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let value = body["entity_id"] as? String { return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        return body["entity_id"] as? [String] ?? []
    }
    static func selecting(_ entity: String, in source: String) throws -> String {
        let data = try DeckHomeAssistantClient.actionData(source.isEmpty ? "{}" : source)
        var body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        body["entity_id"] = entity.isEmpty ? nil : entity
        return String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self)
    }
    static func automaticLight(_ button: DeckButton) -> Bool {
        button.kind == "homeassistant" && (button.settings["action"] ?? "").hasPrefix("light.") && button.settings["automaticLightIcon"] != "false" && (button.settings["iconTemplate"] ?? "").isEmpty
    }
    static func lightPresentation(states: [String]) -> DeckPresentation {
        if states.contains("on") { return DeckPresentation(text: "On", icon: "lightbulb.fill", highlighted: true) }
        if !states.isEmpty && states.allSatisfy({ $0 == "off" }) { return DeckPresentation(text: "Off", icon: "lightbulb", highlighted: false) }
        return DeckPresentation(text: "Unavailable", icon: "lightbulb.slash", highlighted: false)
    }
}
