import AppKit
import SwiftUI

@MainActor final class DeckKeyCapture: ObservableObject {
    @Published var recording = false
    var onCapture: ((Shortcut?) -> Void)?
    private var monitor: Any?
    func begin(global: Bool, onCapture: @escaping (Shortcut?) -> Void) {
        stop()
        self.onCapture = onCapture
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording else { return event }
            if event.keyCode == 53 { self.stop(); return nil }
            if event.keyCode == 51 { onCapture(nil); self.stop(); return nil }
            let modifiers = carbonModifiers(from: event.modifierFlags)
            if global && modifiers == 0 { return nil }
            let label = event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
            onCapture(Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: event.modifierFlags.contains(.numericPad) ? "Numpad \(label)" : label))
            self.stop()
            return nil
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; recording = false }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

struct DeckSettingsView: View {
    @ObservedObject var store: DeckStore
    @ObservedObject var sync: DeckSyncCoordinator
    let logi: DeckLogiService
    @State private var selected: UUID?
    @State private var token = ""
    @State private var message: String?
    @State private var testingConnection = false
    @State private var connectionStatus: String?
    @State private var connectionSucceeded = false
    @StateObject private var capture = DeckKeyCapture()
    @StateObject private var settingsCapture = DeckKeyCapture()
    private let kinds = ["logi", "application", "url", "group", "folder", "homeassistant", "shortcuts", "applescript", "python", "microphone", "volumeUp", "volumeDown", "volumeMute"]
    private let names = ["Switch Logitech device", "Open File", "Open URL", "Multi-action button", "Folder", "Home Assistant", "Apple Shortcuts", "AppleScript", "Python script", "Microphone mute", "Volume up", "Volume down", "Speaker mute"]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Shortcuts").font(.title2.bold())
                Spacer()
                Button("Show launcher") { NotificationCenter.default.post(name: .showDeck, object: nil) }
            }
            HStack {
                Button(capture.recording ? "Press key…" : "Launcher hotkey: \(store.configuration.hotkey?.displayLabel ?? "None")") {
                    settingsCapture.stop()
                    capture.begin(global: true) { store.configuration.hotkey = $0 }
                }
                Text("Modified key required. Delete clears, Escape cancels.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(settingsCapture.recording ? "Press key…" : "Shortcuts settings hotkey: \(store.configuration.settingsHotkey?.displayLabel ?? "None")") {
                    capture.stop()
                    settingsCapture.begin(global: true) { store.configuration.settingsHotkey = $0 }
                }
                Text("Modified key required. Delete clears, Escape cancels.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.hotkeyError { Text(error).font(.caption).foregroundStyle(.red) }
            Toggle("Always show shortcuts on the main display", isOn: Binding(get: {
                store.configuration.alwaysOnMainDisplay ?? false
            }, set: { store.configuration.alwaysOnMainDisplay = $0 }))
                .toggleStyle(.checkbox)
                .help("When unchecked, shortcuts open on the display containing the pointer. This setting stays local to this Mac.")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Toggle("Dismiss", isOn: Binding(get: { store.configuration.openingDismissEnabled }, set: { enabled in
                        if enabled && store.configuration.idleTimeout <= 0 { store.configuration.idleTimeout = 5 }
                        store.configuration.openingDismissEnabled = enabled
                    })).toggleStyle(.checkbox)
                    TextField("Seconds", value: $store.configuration.idleTimeout, format: .number)
                        .frame(width: 60).disabled(!store.configuration.openingDismissEnabled)
                        .accessibilityLabel("Seconds after opening")
                    Text("seconds after opening")
                }
                HStack(spacing: 6) {
                    Toggle("Dismiss", isOn: $store.configuration.dismissAfterAction).toggleStyle(.checkbox)
                    TextField("Seconds", value: $store.configuration.actionDelay, format: .number)
                        .frame(width: 60).disabled(!store.configuration.dismissAfterAction)
                        .accessibilityLabel("Seconds after an action")
                    Text("seconds after an action by default")
                }
            }
            .disabled(sync.isReadOnly)
            DeckSyncView(sync: sync, store: store)
            DisclosureGroup("Home Assistant connection") {
                TextField("Base URL, e.g. https://home.example.com", text: $store.configuration.homeAssistantURL)
                SecureField("Long-lived access token", text: $token)
                Button("Reload token from Keychain") { token = DeckTokenStore.load(retry: true) }
                Button("Save token to Keychain") { do { try DeckTokenStore.save(token); message = "Token saved." } catch { message = error.localizedDescription } }
                HStack {
                    Button(testingConnection ? "Testing…" : "Test Connection") { testHomeAssistantConnection() }
                        .disabled(testingConnection)
                    if testingConnection { ProgressView().controlSize(.small) }
                }
                if let connectionStatus {
                    Text(connectionStatus).font(.caption).foregroundStyle(connectionSucceeded ? Color.green : Color.red)
                }
                Text("Tests the URL and token above without running an action. Save the token to use it in the launcher.").font(.caption).foregroundStyle(.secondary)
                Text("Use HTTPS for remote connections. HTTP sends the token unencrypted. This connection is separate from MQTT.").font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.caption) }
            }
            Divider()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    DeckShortcutOutline(buttons: $store.configuration.buttons, selection: $selected, readOnly: sync.isReadOnly)
                        .help("Drag between rows to reorder, or onto a folder to move inside. Double-click a folder to expand or collapse.")
                    HStack {
                        Menu("Add") {
                            Button("Shortcut") { addButton(kind: "application") }
                            Button("Folder") { addButton(kind: "folder") }
                            Button("Multi-action button") { addButton(kind: "group") }
                            Button("Thermostat preset") {
                                let buttons = DeckThermostatPreset.make(parentID: additionParent(kind: "group"))
                                store.configuration.buttons.append(contentsOf: buttons)
                                selected = buttons.first?.id
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 70)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                        .disabled(sync.isReadOnly)
                        Button("Remove") { removeSelected() }.disabled(selected == nil || sync.isReadOnly)
                    }
                    Button("Duplicate") {
                        guard let selected, let copy = DeckShortcutTree.duplicating(selected, buttons: store.configuration.buttons) else { return }
                        store.configuration.buttons = copy.buttons
                        self.selected = copy.selection
                    }.disabled(selected == nil || sync.isReadOnly)
                    HStack {
                        Button("Move up") { move(-1) }.disabled(selected == nil || sync.isReadOnly)
                        Button("Move down") { move(1) }.disabled(selected == nil || sync.isReadOnly)
                    }
                }.frame(width: 180, alignment: .topLeading)
                ScrollView {
                    if let index = store.configuration.buttons.firstIndex(where: { $0.id == selected }) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Sync with group", isOn: Binding(get: { store.configuration.buttons[index].syncWithGroup ?? true }, set: { store.configuration.buttons[index].syncWithGroup = $0 }))
                                .toggleStyle(.checkbox)
                            if store.configuration.buttons[index].syncWithGroup != false && !DeckSyncScope.isShared(store.configuration.buttons[index], in: store.configuration) {
                                Text("This shortcut stays local because its parent folder or multi-action button is not synced.").font(.caption).foregroundStyle(.secondary)
                            } else if !DeckSyncScope.isShared(store.configuration.buttons[index], in: store.configuration) {
                                Text("Local to this Mac. Local folders and multi-action buttons also keep their contents local.").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Uncheck to keep this shortcut on this Mac only. In Edit on any Mac mode, this also removes its shared copy from the group.").font(.caption).foregroundStyle(.secondary)
                            }
                            editor(index).disabled(sync.isReadOnly && DeckSyncScope.isShared(store.configuration.buttons[index], in: store.configuration))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else { Text("Add a shortcut to begin.").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("Settings save automatically. Keys only activate buttons in the current folder. Escape closes; Left Arrow or Delete goes back. Folder navigation never dismisses.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 800, minHeight: 650)
        .disclosureGroupStyle(DeckDisclosureStyle())
        .textFieldStyle(.roundedBorder)
        .onAppear { token = DeckTokenStore.load() }
        .onDisappear { capture.stop(); settingsCapture.stop() }
        .onChange(of: store.configuration.homeAssistantURL) { _, _ in connectionStatus = nil }
        .onChange(of: token) { _, _ in connectionStatus = nil }
        .onChange(of: sync.isReadOnly) { _, _ in capture.stop() }
        .onChange(of: selected) { _, _ in capture.stop() }
    }
    private func testHomeAssistantConnection() {
        testingConnection = true
        connectionStatus = nil
        let configuration = store.configuration
        let testedToken = token
        Task { @MainActor in
            defer { testingConnection = false }
            do {
                try await DeckHomeAssistantClient.testConnection(configuration, token: testedToken)
                guard store.configuration.homeAssistantURL == configuration.homeAssistantURL, token == testedToken else { return }
                connectionSucceeded = true
                connectionStatus = "Connected to Home Assistant. Authentication succeeded."
            } catch {
                guard store.configuration.homeAssistantURL == configuration.homeAssistantURL, token == testedToken else { return }
                connectionSucceeded = false
                connectionStatus = error.localizedDescription
            }
        }
    }

    private func editor(_ index: Int) -> some View {
        let button = $store.configuration.buttons[index]
        return VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: button.name)
            Picker("Type", selection: button.kind) { ForEach(Array(zip(kinds, names)), id: \.0) { Text($0.1).tag($0.0) } }
                .disabled(store.configuration.buttons.contains { $0.parentID == selected })
                .help("Remove or move a folder’s children before changing its type.")
                .pickerStyle(.menu).fixedSize(horizontal: true, vertical: false)
            if button.wrappedValue.kind == "application" { DeckApplicationEditor(button: button) }
            if button.wrappedValue.kind == "url" { field("URL", "url", index) }
            Picker("Folder / multi-action button", selection: button.parentID) {
                Text("Top level").tag(nil as UUID?)
                ForEach(store.configuration.buttons.filter { ($0.kind == "folder" || ($0.kind == "group" && button.wrappedValue.kind != "group")) && !descendants(of: selected).contains($0.id) && $0.id != selected }) { folder in Text(folder.name).tag(Optional(folder.id)) }
            }.pickerStyle(.menu).fixedSize(horizontal: true, vertical: false)
            if button.wrappedValue.kind != "group", store.configuration.buttons.contains(where: { $0.id == button.wrappedValue.parentID && $0.kind == "folder" }) {
                Toggle("Show as action control on folder tile", isOn: Binding(get: {
                    button.wrappedValue.settings["folderControl"] == "true"
                }, set: { button.wrappedValue.settings["folderControl"] = $0 ? "true" : "false" }))
                    .toggleStyle(.checkbox)
                Text("Tile controls run from the folder’s parent screen instead of appearing inside the folder.").font(.caption).foregroundStyle(.secondary)
            }
            if button.wrappedValue.kind != "group" {
                Button("Button key: \(button.wrappedValue.key?.displayLabel ?? "None")") {
                    let id = button.wrappedValue.id
                    settingsCapture.stop()
                    capture.begin(global: false) { key in
                        if let location = store.configuration.buttons.firstIndex(where: { $0.id == id }) { store.configuration.buttons[location].key = key }
                    }
                }
                if capture.recording { Text("Press a key (including numpad), Delete clears, Escape cancels.").font(.caption) }
                if let key = button.wrappedValue.key, DeckGroups.keyPeers(for: button.wrappedValue, configuration: store.configuration).contains(where: { $0.id != button.wrappedValue.id && $0.key?.keyCode == key.keyCode && $0.key?.modifiers == key.modifiers }) { Text("Duplicate key in this folder; choose another key.").foregroundStyle(.red) }
            }
            if let main = DeckGroups.mainAction(button.wrappedValue, in: store.configuration) {
                HStack {
                    Text("Icon")
                    DeckButtonIcon(button: main)
                    Button("Edit main action icon…") { selected = main.id }
                }
            } else {
                DeckIconOptions(button: button).id(button.wrappedValue.id)
            }
            switch button.wrappedValue.kind {
            case "logi": DeckLogiEditor(button: button, service: logi)
            case "folder":
                let controls = DeckGroups.controls(button.wrappedValue, in: store.configuration)
                Text("Folder tile actions").font(.headline)
                ForEach(controls) { child in
                    Button("Edit \(child.name)") { selected = child.id }
                }
                Button("Add action to folder tile") {
                    var child = DeckButton()
                    child.parentID = button.wrappedValue.id
                    child.settings["folderControl"] = "true"
                    child.dismiss = .never
                    store.configuration.buttons.append(child)
                    selected = child.id
                }
                Text("Shortcuts inside folder").font(.headline)
                ForEach(store.configuration.buttons.filter { $0.parentID == button.wrappedValue.id && !DeckGroups.isFolderControl($0, in: store.configuration) }) { child in
                    Button("Edit \(child.name)") { selected = child.id }
                }
                Button("Add shortcut to this folder") {
                    var child = DeckButton()
                    child.parentID = button.wrappedValue.id
                    store.configuration.buttons.append(child)
                    selected = child.id
                }
            case "group":
                DeckGroupEditor(store: store, groupID: button.wrappedValue.id, token: token, selected: $selected).id(button.wrappedValue.id)
            case "homeassistant":
                DeckHAEditor(button: button, configuration: store.configuration, token: token)
                    .id(button.wrappedValue.id)
            case "shortcuts": field("Exact name in Apple Shortcuts", "name", index)
            case "python":
                field("Interpreter absolute path (default /usr/bin/python3)", "interpreter", index)
                field("Script absolute path", "path", index)
            case "applescript":
                field("AppleScript to run", "script", index, multiline: true)
            default: EmptyView()
            }
            if button.wrappedValue.kind != "folder" && button.wrappedValue.kind != "group" {
                Picker("Auto-dismiss behavior", selection: button.dismiss) { ForEach(DeckDismiss.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu).fixedSize(horizontal: true, vertical: false)
                if button.wrappedValue.dismiss == .always {
                    HStack {
                        Text("Auto-dismiss delay")
                        TextField("Seconds", value: button.delay, format: .number).frame(width: 60)
                        Text("seconds")
                    }
                }
                if DeckGroups.containingFolder(of: button.wrappedValue, configuration: store.configuration) != nil {
                    DeckReturnEditor(button: button, configuration: store.configuration)
                }
                Text("Default inherits the global action rule. Always closes after a successful action and its delay. Never keeps the window open and cancels the timeout until the next action or folder navigation. Failed actions stay visible.").font(.caption).foregroundStyle(.secondary)
            }
        }.textFieldStyle(.roundedBorder).padding(2)
    }
    private func field(_ title: String, _ key: String, _ index: Int, multiline: Bool = false) -> some View {
        let binding = Binding<String>(get: { store.configuration.buttons.indices.contains(index) ? store.configuration.buttons[index].settings[key] ?? "" : "" }, set: { if store.configuration.buttons.indices.contains(index) { store.configuration.buttons[index].settings[key] = $0 } })
        return Group {
            if multiline {
                VStack(alignment: .leading) {
                    Text(title).font(.caption)
                    DeckCodeEditor(text: binding).frame(height: 70).border(.quaternary)
                }
            } else {
                HStack {
                    Text(title)
                    TextField("", text: binding).accessibilityLabel(title)
                }
            }
        }
    }
    private func descendants(of id: UUID?) -> Set<UUID> {
        guard let id else { return [] }
        var result: Set<UUID> = [id]
        var changed = true
        while changed { let before = result; for button in store.configuration.buttons where button.parentID.map({ result.contains($0) }) == true { result.insert(button.id) }; changed = before != result }
        return result
    }
    private func additionParent(kind: String) -> UUID? {
        guard let item = store.configuration.buttons.first(where: { $0.id == selected }) else { return nil }
        let parent = DeckShortcutTree.isContainer(item) ? item.id : item.parentID
        if kind == "group", let owner = store.configuration.buttons.first(where: { $0.id == parent }), owner.kind == "group" { return owner.parentID }
        return parent
    }
    private func addButton(kind: String) {
        var button = DeckButton()
        button.kind = kind
        button.parentID = additionParent(kind: kind)
        if kind == "folder" { button.name = "New folder" }
        if kind == "group" { button.name = "Multi-action button" }
        store.configuration.buttons.append(button)
        selected = button.id
    }
    private func move(_ direction: Int) {
        guard let index = store.configuration.buttons.firstIndex(where: { $0.id == selected }) else { return }
        let peers = store.configuration.buttons.indices.filter { store.configuration.buttons[$0].parentID == store.configuration.buttons[index].parentID }
        guard let position = peers.firstIndex(of: index), peers.indices.contains(position + direction) else { return }
        store.configuration.buttons.swapAt(index, peers[position + direction])
    }
    private func removeSelected() {
        let ids = descendants(of: selected)
        store.configuration.buttons.removeAll { ids.contains($0.id) }
        selected = nil
    }
}

extension Notification.Name { static let showDeck = Notification.Name("ShowShortcutDeck") }

// Code must remain literal regardless of the user's system text substitution settings.
struct DeckCodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.isRichText = false
        editor.importsGraphics = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.textContainerInset = NSSize(width: 4, height: 4)
        editor.string = text
        editor.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text {
            editor.string = text
            editor.undoManager?.removeAllActions()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}
