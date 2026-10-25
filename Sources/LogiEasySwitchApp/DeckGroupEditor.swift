import SwiftUI

struct DeckGroupEditor: View {
    @ObservedObject var store: DeckStore
    var groupID: UUID
    var token: String
    @Binding var selected: UUID?
    @State private var catalog: DeckHACatalog?
    @State private var error: String?
    @State private var loading = false
    @State private var reload = UUID()
    private var group: DeckButton? { store.configuration.buttons.first { $0.id == groupID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Each control runs independently and has its own key and dismissal rule. A folder control opens its shortcuts.").font(.caption).foregroundStyle(.secondary)
            if group?.settings["preset"] == "thermostat" {
                HStack {
                    Button(loading ? "Loading…" : "Refresh thermostats and scripts") { reload = UUID() }.disabled(loading)
                    if loading { ProgressView().controlSize(.small) }
                }
                DeckSearchPicker(title: "Thermostat", selection: group?.settings["climateEntity"] ?? "", choices: (catalog?.entities ?? []).filter { $0.id.hasPrefix("climate.") }.map { DeckChoice(id: $0.id, title: $0.name, detail: $0.id) }) { entity in
                    configure(entity: entity)
                }
                DeckSearchPicker(title: "Adjustment script", selection: group?.settings["adjustScript"] ?? "script.adjust_thermostat", choices: (catalog?.actions ?? []).filter { $0.id.hasPrefix("script.") && !["script.turn_on", "script.turn_off", "script.toggle", "script.reload"].contains($0.id) }.map { DeckChoice(id: $0.id, title: $0.name, detail: $0.id) }) { script in
                    configure(script: script)
                }
                Text("+/− taps accumulate for one second after the last tap, then send increment: ticks or −ticks. Choosing a thermostat sets the live text and targets for Cool, Heat, Auto and Off. Edit the Mode folder’s controls if your thermostat uses different modes.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Controls").font(.headline)
            if let group {
                ForEach(DeckGroups.controls(group, in: store.configuration)) { control in
                    Button { selected = control.id } label: {
                        HStack { Text(control.name); Spacer(); Text(control.kind == "folder" ? "Folder" : "Edit action").foregroundStyle(.secondary); Image(systemName: "chevron.right") }
                    }
                }
            }
            HStack {
                Button("Add action") { addControl(folder: false) }
                Button("Add folder control") { addControl(folder: true) }
            }
            Text("Dynamic button text (Home Assistant template)").font(.caption)
            DeckCodeEditor(text: setting("textTemplate")).frame(height: 110).border(.quaternary)
            Toggle("Use dynamic text as the full button title", isOn: Binding(get: { group?.settings["textReplacesName"] == "true" }, set: { set("textReplacesName", $0 ? "true" : "false") }))
        }
        .task(id: store.configuration.homeAssistantURL + token + reload.uuidString) {
            guard group?.settings["preset"] == "thermostat" else { return }
            catalog = nil
            loading = true
            error = nil
            do {
                try await Task.sleep(for: .milliseconds(300))
                let result = try await DeckHACatalog.load(store.configuration, token: token)
                try Task.checkCancellation()
                catalog = result
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }
    }
    private func configure(entity: String? = nil, script: String? = nil) {
        do {
            var configuration = store.configuration
            try DeckThermostatPreset.configure(groupID: groupID, entity: entity, script: script, configuration: &configuration)
            store.configuration = configuration
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func addControl(folder: Bool) {
        var control = DeckButton()
        control.kind = folder ? "folder" : "application"
        control.name = folder ? "Mode" : "New action"
        control.parentID = groupID
        control.dismiss = .never
        store.configuration.buttons.append(control)
        selected = control.id
    }
    private func set(_ key: String, _ value: String) {
        if let index = store.configuration.buttons.firstIndex(where: { $0.id == groupID }) { store.configuration.buttons[index].settings[key] = value }
    }
    private func setting(_ key: String) -> Binding<String> {
        Binding(get: { group?.settings[key] ?? "" }, set: { set(key, $0) })
    }
}
