import AppKit
import SwiftUI

struct DeckSyncView: View {
    @ObservedObject var sync: DeckSyncCoordinator
    @ObservedObject var store: DeckStore
    @State private var message: String?
    var body: some View {
        DisclosureGroup("Shortcut sync") {
            ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Sync mode", selection: $sync.settings.role) {
                    ForEach(DeckSyncSettings.Role.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if sync.settings.role == .publisher {
                    HStack {
                        Text("Publisher ID: \(sync.publisherID)").font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sync.publisherID, forType: .string) }
                    }
                    Button("Publish now") { sync.publish(force: true) }
                }
                if sync.isFollower {
                    TextField("Publisher ID from the editing Mac", text: $sync.settings.source)
                    Text("Shared settings are read-only on this Mac. The launcher hotkey, Home Assistant connection and Python paths remain local.").font(.caption).foregroundStyle(.secondary)
                }
                Text(sync.status).font(.caption).textSelection(.enabled)
                Text("Uses the TLS MQTT broker and namespace from the main Settings window. Use one publishing Mac. Tokens and broker credentials are never included; script source and action data are shared.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Reconnect") { sync.reconnect() }.disabled(sync.settings.role == .off)
                    Button("Export backup…") { exportConfiguration() }
                    Button("Import backup…") { importConfiguration() }.disabled(sync.isFollower)
                    Button("Show backups") {
                        do {
                            try FileManager.default.createDirectory(at: DeckSyncBackup.directory, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(DeckSyncBackup.directory)
                        } catch { message = error.localizedDescription }
                    }
                }
                if let message { Text(message).font(.caption) }
                if sync.isFollower {
                    ForEach(store.configuration.buttons.filter { $0.kind == "python" }) { button in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Local Python paths: \(button.name)").font(.caption)
                            TextField("Script absolute path", text: localPath(button.id, key: "path"))
                            TextField("Interpreter (default /usr/bin/python3)", text: localPath(button.id, key: "interpreter"))
                        }
                    }
                }
            }.padding(.vertical, 6)
            }.frame(maxHeight: 280)
        }
    }
    private func localPath(_ id: UUID, key: String) -> Binding<String> {
        Binding(get: { store.configuration.buttons.first { $0.id == id }?.settings[key] ?? "" }, set: { value in
            if let index = store.configuration.buttons.firstIndex(where: { $0.id == id }) {
                if value.isEmpty { store.configuration.buttons[index].settings.removeValue(forKey: key) }
                else { store.configuration.buttons[index].settings[key] = value }
            }
        })
    }
    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Switchboard-shortcuts.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONEncoder().encode(store.configuration).write(to: url, options: .atomic); message = "Configuration exported (Keychain items are not included)." }
        catch { message = error.localizedDescription }
    }
    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_000_000 else { throw DeckError.message("Backup exceeds the 1 MB import limit.") }
            let imported = try JSONDecoder().decode(DeckConfiguration.self, from: data)
            try DeckSharedConfiguration(imported).validate()
            try DeckSyncBackup.save(store.configuration)
            store.configuration = imported
            message = "Backup imported."
        } catch { message = error.localizedDescription }
    }
}
