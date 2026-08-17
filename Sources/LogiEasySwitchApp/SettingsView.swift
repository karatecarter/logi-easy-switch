import AppKit
import SwiftUI

final class DeviceDefaults: ObservableObject {
    @Published var mouseID: String
    @Published var keyboardID: String
    @Published var hotkeys: [String: Shortcut]
    @Published var aliases: [String: String]

    private let mouseKey = "defaultMouseID"
    private let keyboardKey = "defaultKeyboardID"

    init() {
        mouseID = UserDefaults.standard.string(forKey: mouseKey) ?? ""
        keyboardID = UserDefaults.standard.string(forKey: keyboardKey) ?? ""
        hotkeys = (try? JSONDecoder().decode([String: Shortcut].self, from: UserDefaults.standard.data(forKey: "hotkeys") ?? Data())) ?? [:]
        aliases = (try? JSONDecoder().decode([String: String].self, from: UserDefaults.standard.data(forKey: "machineAliases") ?? Data())) ?? [:]
    }

    func selectedDevices(from devices: [LogiDevice]) -> [LogiDevice] {
        let mouse = devices.first { $0.id == mouseID && $0.type == "MOUSE" }
        let keyboard = devices.first { $0.id == keyboardID && $0.type == "KEYBOARD" }
        return [mouse, keyboard].compactMap { $0 }
    }

    func applyFallbacks(from devices: [LogiDevice]) {
        if mouseID.isEmpty { mouseID = devices.first(where: { $0.name.localizedCaseInsensitiveContains("MX Master 3S") })?.id ?? "" }
        if keyboardID.isEmpty { keyboardID = devices.first(where: { $0.name.localizedCaseInsensitiveContains("ERGO K860") })?.id ?? "" }
    }

    func save() {
        UserDefaults.standard.set(mouseID, forKey: mouseKey)
        UserDefaults.standard.set(keyboardID, forKey: keyboardKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(hotkeys), forKey: "hotkeys")
        UserDefaults.standard.set(try? JSONEncoder().encode(aliases), forKey: "machineAliases")
    }

    func displayName(for machine: String) -> String {
        let alias = aliases[machine]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return alias.isEmpty ? machine : alias
    }
}

struct SettingsView: View {
    @ObservedObject var defaults: DeviceDefaults
    let devices: [LogiDevice]
    let didSave: () -> Void
    let targets: [ShortcutTarget]
    let machineNames: [String]

    @State private var mouseID = ""
    @State private var keyboardID = ""
    @State private var workingHotkeys: [String: Shortcut] = [:]
    @StateObject private var capture = ShortcutCaptureModel()

    private var mice: [LogiDevice] { devices.filter { $0.type == "MOUSE" } }
    private var keyboards: [LogiDevice] { devices.filter { $0.type == "KEYBOARD" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Default devices")
                .font(.title2)

            Text("Normal menu items switch this mouse and keyboard together. Hold Option while the menu is open to switch any connected device independently.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("Default mouse", selection: $mouseID) {
                Text("Choose a mouse").tag("")
                ForEach(mice) { device in Text(device.name).tag(device.id) }
            }

            Picker("Default keyboard", selection: $keyboardID) {
                Text("Choose a keyboard").tag("")
                ForEach(keyboards) { device in Text(device.name).tag(device.id) }
            }

            Text("Machine aliases")
                .font(.headline)

            ForEach(machineNames, id: \.self) { machine in
                HStack {
                    Text(machine)
                        .frame(width: 180, alignment: .leading)
                    TextField("Optional alias", text: aliasBinding(for: machine))
                }
            }

            Text("Hotkeys")
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(targets) { target in
                        HStack(spacing: 12) {
                            Text(target.label)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            Button(capture.recordingID == target.id ? "Press shortcut…" : workingHotkeys[target.id]?.displayLabel ?? "Set Shortcut") {
                                capture.begin(target.id)
                            }
                            .frame(width: 170)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 200)

            if capture.recordingID != nil {
                Text("Press a modified key, Delete to clear, or Escape to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onAppear {
            defaults.applyFallbacks(from: devices)
            mouseID = defaults.mouseID
            keyboardID = defaults.keyboardID
            workingHotkeys = defaults.hotkeys
            capture.onCapture = { id, shortcut in
                workingHotkeys[id] = shortcut
                saveHotkeys()
            }
        }
        .onChange(of: mouseID) { _, _ in saveSelectedDevices() }
        .onChange(of: keyboardID) { _, _ in saveSelectedDevices() }
    }

    private func saveSelectedDevices() {
        guard !mouseID.isEmpty, !keyboardID.isEmpty else { return }
        defaults.mouseID = mouseID
        defaults.keyboardID = keyboardID
        defaults.save()
        didSave()
    }

    private func saveHotkeys() {
        defaults.hotkeys = workingHotkeys
        defaults.save()
        didSave()
    }

    private func aliasBinding(for machine: String) -> Binding<String> {
        Binding(
            get: { defaults.aliases[machine] ?? "" },
            set: { value in
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    defaults.aliases.removeValue(forKey: machine)
                } else {
                    defaults.aliases[machine] = value
                }
                defaults.save()
            }
        )
    }
}

struct ShortcutTarget: Identifiable {
    let id: String
    let label: String
}

@MainActor
final class ShortcutCaptureModel: ObservableObject {
    @Published private(set) var recordingID: String?
    var onCapture: ((String, Shortcut?) -> Void)?
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let id = self.recordingID else { return event }
            if event.keyCode == 53 {
                self.recordingID = nil
                return nil
            }
            if event.keyCode == 51 || event.keyCode == 117 {
                self.onCapture?(id, nil)
                self.recordingID = nil
                return nil
            }
            let modifiers = carbonModifiers(from: event.modifierFlags)
            guard modifiers != 0 else { return nil }
            let fallback = event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
            let label = shortcutKeyLabel(keyCode: UInt32(event.keyCode), fallback: fallback)
            self.onCapture?(id, Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label))
            self.recordingID = nil
            return nil
        }
    }

    func begin(_ id: String) { recordingID = id }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
