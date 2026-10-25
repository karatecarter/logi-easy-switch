import SwiftUI

struct DeckHAEditor: View {
    @Binding var button: DeckButton
    var configuration: DeckConfiguration
    var token: String
    @State private var catalog: DeckHACatalog?
    @State private var loading = false
    @State private var error: String?
    @State private var reload = UUID()
    @State private var showAllEntities = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(loading ? "Loading…" : "Refresh actions and entities") { reload = UUID() }.disabled(loading)
                if loading { ProgressView().controlSize(.small) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            DeckSearchPicker(title: "Action", selection: button.settings["action"] ?? "", choices: (catalog?.actions ?? []).map { DeckChoice(id: $0.id, title: $0.name, detail: $0.id) }) { action in
                button.settings["action"] = action
                if let metadata = catalog?.actions.first(where: { $0.id == action }) { button.settings["returnResponse"] = metadata.responseRequired ? "true" : "false" }
            }
            DeckSearchPicker(title: "Entity", selection: DeckHATarget.entities(button).joined(separator: ", "), choices: [DeckChoice(id: "", title: "No entity target")] + availableEntities.map { DeckChoice(id: $0.id, title: $0.name, detail: $0.id) }) { entity in
                do { button.settings["data"] = try DeckHATarget.selecting(entity, in: button.settings["data"] ?? "{}") }
                catch { self.error = error.localizedDescription }
            }
            Toggle("Show entities from all domains", isOn: $showAllEntities).font(.caption)
            if (button.settings["action"] ?? "").hasPrefix("light.") {
                Toggle("Automatic lightbulb icon from entity state", isOn: Binding(get: { button.settings["automaticLightIcon"] != "false" }, set: { button.settings["automaticLightIcon"] = $0 ? "true" : "false" }))
                Text("On: illuminated bulb. Off: dim bulb. For multiple light targets, the bulb is illuminated when any is on.").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Advanced action settings") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Additional parameters, multiple entities, device and area targets can be configured below. Choosing an entity preserves other parameters.").font(.caption).foregroundStyle(.secondary)
                    codeField("Service data JSON", key: "data", fallback: "{}")
                    Toggle("Action supports/requires response data", isOn: Binding(get: { button.settings["returnResponse"] == "true" }, set: { button.settings["returnResponse"] = $0 ? "true" : "false" }))
                    codeField("Dynamic text (Home Assistant template)", key: "textTemplate")
                    codeField("Custom icon template (overrides automatic icon)", key: "iconTemplate")
                }.padding(.top, 8)
            }
        }
        .task(id: configuration.homeAssistantURL + token + reload.uuidString) {
            catalog = nil
            error = nil
            loading = true
            do {
                try await Task.sleep(for: .milliseconds(300))
                let value = try await DeckHACatalog.load(configuration, token: token)
                try Task.checkCancellation()
                catalog = value
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }
    }
    private var availableEntities: [DeckHAEntity] {
        guard let catalog else { return [] }
        return showAllEntities ? catalog.entities : catalog.entities(for: button.settings["action"] ?? "")
    }
    private func codeField(_ title: String, key: String, fallback: String = "") -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption)
            DeckCodeEditor(text: Binding(get: { button.settings[key] ?? fallback }, set: { button.settings[key] = $0 })).frame(height: 70).border(.quaternary)
        }
    }
}
