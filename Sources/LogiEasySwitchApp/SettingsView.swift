import AppKit
import SwiftUI

final class DeviceDefaults: ObservableObject {
    @Published var mouseID: String
    @Published var keyboardID: String
    @Published var hotkeys: [String: Shortcut]
    @Published var aliases: [String: String]
    @Published var hiddenMachineNames: Set<String>
    @Published var removedMachineNames: Set<String>
    @Published var mqtt: MQTTConfiguration
    @Published private(set) var knownMachineNames: [String]

    private let mouseKey = "defaultMouseID"
    private let keyboardKey = "defaultKeyboardID"
    private let mouseNameKey = "defaultMouseName"
    private let keyboardNameKey = "defaultKeyboardName"
    private var mouseName: String
    private var keyboardName: String

    init() {
        mouseID = UserDefaults.standard.string(forKey: mouseKey) ?? ""
        keyboardID = UserDefaults.standard.string(forKey: keyboardKey) ?? ""
        mouseName = UserDefaults.standard.string(forKey: mouseNameKey) ?? ""
        keyboardName = UserDefaults.standard.string(forKey: keyboardNameKey) ?? ""
        hotkeys = (try? JSONDecoder().decode([String: Shortcut].self, from: UserDefaults.standard.data(forKey: "hotkeys") ?? Data())) ?? [:]
        aliases = (try? JSONDecoder().decode([String: String].self, from: UserDefaults.standard.data(forKey: "machineAliases") ?? Data())) ?? [:]
        hiddenMachineNames = Set(UserDefaults.standard.stringArray(forKey: "hiddenMachineNames") ?? [])
        removedMachineNames = Set(UserDefaults.standard.stringArray(forKey: "removedMachineNames") ?? [])
        mqtt = (try? JSONDecoder().decode(MQTTConfiguration.self, from: UserDefaults.standard.data(forKey: "mqttConfiguration") ?? Data())) ?? MQTTConfiguration()
        knownMachineNames = UserDefaults.standard.stringArray(forKey: "knownMachineNames") ?? []
    }

    func selectedDevices(from devices: [LogiDevice]) -> [LogiDevice] {
        let mouse = devices.first { $0.id == mouseID && $0.type == "MOUSE" }
        let keyboard = devices.first { $0.id == keyboardID && $0.type == "KEYBOARD" }
        return [mouse, keyboard].compactMap { $0 }
    }

    func applyFallbacks(from devices: [LogiDevice]) {
        let mouse = devices.first { $0.id == mouseID && $0.type == "MOUSE" }
            ?? devices.first { $0.type == "MOUSE" && namesMatch($0.name, mouseName) }
            ?? devices.first { $0.name.localizedCaseInsensitiveContains("MX Master 3S") }
        let keyboard = devices.first { $0.id == keyboardID && $0.type == "KEYBOARD" }
            ?? devices.first { $0.type == "KEYBOARD" && namesMatch($0.name, keyboardName) }
            ?? devices.first { $0.name.localizedCaseInsensitiveContains("ERGO K860") }

        let previous = (mouseID, keyboardID, mouseName, keyboardName)
        if let mouse {
            mouseID = mouse.id
            mouseName = mouse.name
        }
        if let keyboard {
            keyboardID = keyboard.id
            keyboardName = keyboard.name
        }
        if previous != (mouseID, keyboardID, mouseName, keyboardName) { save() }
    }

    func setSelectedDevices(mouseID: String, keyboardID: String, from devices: [LogiDevice]) {
        self.mouseID = mouseID
        self.keyboardID = keyboardID
        mouseName = devices.first { $0.id == mouseID && $0.type == "MOUSE" }?.name ?? mouseName
        keyboardName = devices.first { $0.id == keyboardID && $0.type == "KEYBOARD" }?.name ?? keyboardName
        save()
    }

    func save() {
        UserDefaults.standard.set(mouseID, forKey: mouseKey)
        UserDefaults.standard.set(keyboardID, forKey: keyboardKey)
        UserDefaults.standard.set(mouseName, forKey: mouseNameKey)
        UserDefaults.standard.set(keyboardName, forKey: keyboardNameKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(hotkeys), forKey: "hotkeys")
        UserDefaults.standard.set(try? JSONEncoder().encode(aliases), forKey: "machineAliases")
        UserDefaults.standard.set(Array(hiddenMachineNames).sorted(), forKey: "hiddenMachineNames")
        UserDefaults.standard.set(Array(removedMachineNames).sorted(), forKey: "removedMachineNames")
        UserDefaults.standard.set(try? JSONEncoder().encode(mqtt), forKey: "mqttConfiguration")
        UserDefaults.standard.set(knownMachineNames, forKey: "knownMachineNames")
    }

    func displayName(for machine: String) -> String {
        let alias = aliases[machine]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return alias.isEmpty ? machine : alias
    }

    func isMachineVisible(_ machine: String) -> Bool {
        !hiddenMachineNames.contains(machine) && !removedMachineNames.contains(machine)
    }

    func setMachine(_ machine: String, visible: Bool) {
        if visible {
            hiddenMachineNames.remove(machine)
        } else {
            hiddenMachineNames.insert(machine)
        }
        save()
    }

    func removeMachine(_ machine: String) {
        removedMachineNames.insert(machine)
        hiddenMachineNames.remove(machine)
        knownMachineNames.removeAll { $0 == machine }
        aliases.removeValue(forKey: machine)
        hotkeys.removeValue(forKey: "default:\(machine)")
        save()
    }

    func rememberMachineNames(_ names: [String]) {
        let remembered = names.filter { !$0.isEmpty && !removedMachineNames.contains($0) }
        let combined = Array(Set(knownMachineNames + remembered)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        guard combined != knownMachineNames else { return }
        knownMachineNames = combined
        save()
    }

    func machineName(matchingDisplayName displayedName: String) -> String? {
        knownMachineNames.first { machine in
            guard !removedMachineNames.contains(machine) else { return false }
            return machine.compare(displayedName, options: .caseInsensitive) == .orderedSame ||
            displayName(for: machine).compare(displayedName, options: .caseInsensitive) == .orderedSame
        }
    }

    private func namesMatch(_ left: String, _ right: String) -> Bool {
        !right.isEmpty && left.compare(right, options: .caseInsensitive) == .orderedSame
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
    @State private var startAtLogin = false
    @State private var loginItemMessage: String?
    @State private var mqtt = MQTTConfiguration()
    @State private var mqttPassword = ""
    @State private var mqttTestStatus: String?
    @State private var testingMQTT = false
    @StateObject private var capture = ShortcutCaptureModel()

    private var mice: [LogiDevice] { devices.filter { $0.type == "MOUSE" } }
    private var keyboards: [LogiDevice] { devices.filter { $0.type == "KEYBOARD" } }

    var body: some View {
        ScrollView {
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

            Toggle("Start Logi Easy Switch at login", isOn: $startAtLogin)
                .onChange(of: startAtLogin) { _, enabled in
                    do {
                        try LaunchAtLogin.setEnabled(enabled)
                        startAtLogin = LaunchAtLogin.isRegistered
                        loginItemMessage = LaunchAtLogin.requiresApproval
                            ? "Approval required in System Settings → General → Login Items."
                            : nil
                    } catch {
                        startAtLogin = LaunchAtLogin.isRegistered
                        loginItemMessage = error.localizedDescription
                    }
                }

            if let loginItemMessage {
                Text(loginItemMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Home Assistant")
                .font(.headline)

            Toggle("Enable network switching through MQTT", isOn: $mqtt.enabled)

            if mqtt.enabled {
                Group {
                    TextField("Broker address", text: $mqtt.host)
                    HStack {
                        TextField("Port", value: $mqtt.port, format: .number.grouping(.never))
                            .frame(width: 120)
                        Toggle("Use TLS", isOn: $mqtt.useTLS)
                    }
                    TextField("Username", text: $mqtt.username)
                    SecureField("Password", text: $mqttPassword)

                    Picker("This computer", selection: $mqtt.computerName) {
                        if !machineNames.contains(mqtt.computerName) {
                            Text(defaults.displayName(for: mqtt.computerName)).tag(mqtt.computerName)
                        }
                        ForEach(machineNames.filter { !defaults.removedMachineNames.contains($0) }, id: \.self) { machine in
                            Text(defaults.displayName(for: machine)).tag(machine)
                        }
                    }

                    Toggle("Add controls to Home Assistant automatically", isOn: $mqtt.discoveryEnabled)

                    HStack {
                        Button(testingMQTT ? "Testing…" : "Test Connection") { testMQTTConnection() }
                            .disabled(testingMQTT)
                        if let mqttTestStatus {
                            Text(mqttTestStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Home Assistant will receive a target-computer selector and current-computer sensor. MQTT credentials are stored in Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Machine aliases")
                .font(.headline)

            Text("Uncheck Show to hide a remembered computer from menus, hotkeys, and Home Assistant controls.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(machineNames.filter { !defaults.removedMachineNames.contains($0) }, id: \.self) { machine in
                HStack {
                    Toggle("Show", isOn: machineVisibilityBinding(for: machine))
                        .toggleStyle(.checkbox)
                        .frame(width: 65, alignment: .leading)
                    Text(machine)
                        .frame(width: 180, alignment: .leading)
                    TextField("Optional alias", text: aliasBinding(for: machine))
                    Button {
                        defaults.removeMachine(machine)
                        didSave()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Forget \(machine)")
                    .disabled(machine == mqtt.computerName)
                }
            }

            Text("Hotkeys")
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(targets.filter { defaults.isMachineVisible($0.machineName) }) { target in
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
        }
        .onAppear {
            defaults.applyFallbacks(from: devices)
            mouseID = defaults.mouseID
            keyboardID = defaults.keyboardID
            workingHotkeys = defaults.hotkeys
            startAtLogin = LaunchAtLogin.isRegistered
            loginItemMessage = LaunchAtLogin.requiresApproval
                ? "Approval required in System Settings → General → Login Items."
                : nil
            mqtt = defaults.mqtt
            mqttPassword = MQTTPasswordStore.load()
            capture.onCapture = { id, shortcut in
                workingHotkeys[id] = shortcut
                saveHotkeys()
            }
        }
        .onChange(of: mouseID) { _, _ in saveSelectedDevices() }
        .onChange(of: keyboardID) { _, _ in saveSelectedDevices() }
        .onChange(of: mqtt) { _, value in
            defaults.mqtt = value
            defaults.save()
            didSave()
        }
        .onChange(of: mqttPassword) { _, value in
            MQTTPasswordStore.save(value)
            didSave()
        }
    }

    private func saveSelectedDevices() {
        guard !mouseID.isEmpty, !keyboardID.isEmpty else { return }
        defaults.setSelectedDevices(mouseID: mouseID, keyboardID: keyboardID, from: devices)
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

    private func machineVisibilityBinding(for machine: String) -> Binding<Bool> {
        Binding(
            get: { defaults.isMachineVisible(machine) },
            set: { visible in
                defaults.setMachine(machine, visible: visible)
                didSave()
            }
        )
    }

    private func testMQTTConnection() {
        testingMQTT = true
        mqttTestStatus = nil
        MQTTCoordinator.test(configuration: mqtt, password: mqttPassword) { result in
            DispatchQueue.main.async {
                testingMQTT = false
                switch result {
                case .success: mqttTestStatus = "Connected"
                case .failure(let error): mqttTestStatus = error.localizedDescription
                }
            }
        }
    }
}

struct ShortcutTarget: Identifiable {
    let id: String
    let label: String
    let machineName: String
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
