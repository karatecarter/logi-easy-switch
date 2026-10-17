import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var optionMode = false
    private var isMenuOpen = false
    private var refreshPending = false
    private var settingsWindow: NSWindow?
    private var cachedDevices: [LogiDevice] = []
    private var cachedHosts: [String: [LogiHost]] = [:]
    private var deviceLoadError: String?
    private let defaults = DeviceDefaults()
    private let hotkeys = HotkeyManager()
    private let mqtt = MQTTCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        HIDPPTransport.requestInputMonitoringAccessIfNeeded()
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.title = ""
        statusItem.button?.isHidden = false
        statusItem.button?.toolTip = "Logi Easy Switch"
        menu.delegate = self
        statusItem.menu = menu
        mqtt.onTargetRequested = { [weak self] target in
            guard let self else { return }
            let machine = self.defaults.machineName(matchingDisplayName: target) ?? target
            // Probe on every network command. A Mac that just received the
            // devices may not have refreshed its menu cache yet.
            self.loadDevices(requestedTarget: machine)
        }
        mqtt.onStateChanged = { [weak self] in
            guard let self else { return }
            if self.isMenuOpen { self.updateVisibleMenuState() } else { self.rebuildMenu() }
        }
        configureMQTT()
        installHotkeys()
        rebuildMenu()
        loadDevices()
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Logi Easy Switch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        mqtt.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        optionMode = NSEvent.modifierFlags.contains(.option)
        rebuildMenu()
        loadDevices()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        optionMode = false
        if refreshPending {
            refreshPending = false
            rebuildMenu()
        }
    }

    private func refreshMenu() {
        guard !isMenuOpen else {
            loadDevices()
            return
        }
        menu.removeAllItems()
        menu.addItem(withTitle: "Loading Logi devices…", action: nil, keyEquivalent: "")
        loadDevices()
    }

    private func loadDevices(requestedTarget: String? = nil) {
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let devices = try LogiAgent().devices()
                var hostsByDevice: [String: [LogiHost]] = [:]
                for device in devices {
                    hostsByDevice[device.id] = (try? LogiAgent().hosts(for: device)) ?? []
                }
                await MainActor.run {
                    self.cachedDevices = devices
                    self.cachedHosts = hostsByDevice
                    self.deviceLoadError = nil
                    self.defaults.applyFallbacks(from: devices)
                    let hostNames = hostsByDevice.values.flatMap { $0.map(\.name) }
                    self.defaults.rememberMachineNames(hostNames)
                    self.configureMQTT()
                    if let current = self.currentLocalTarget() {
                        self.mqtt.publishCurrentTarget(self.defaults.displayName(for: current))
                    } else {
                        self.mqtt.clearLocalOwnership()
                    }
                    if let requestedTarget {
                        let selected = self.defaults.selectedDevices(from: devices)
                        if selected.count == 2 { self.switchDevices(selected, targetName: requestedTarget) }
                    }
                    if self.isMenuOpen {
                        self.updateVisibleMenuState()
                        self.refreshPending = true
                    } else {
                        self.rebuildMenu()
                    }
                }
            } catch {
                await MainActor.run {
                    self.deviceLoadError = error.localizedDescription
                    if self.isMenuOpen {
                        self.refreshPending = true
                    } else {
                        self.rebuildMenu()
                    }
                }
            }
        }
    }

    private func updateVisibleMenuState() {
        if optionMode {
            for deviceItem in menu.items {
                guard let submenu = deviceItem.submenu,
                      let device = cachedDevices.first(where: { $0.name == deviceItem.title }) else { continue }
                for hostItem in submenu.items {
                    guard let target = hostItem.representedObject as? DeviceTarget,
                          let host = cachedHosts[device.id]?.first(where: { $0.index == target.host.index }) else { continue }
                    hostItem.state = host.connected && device.connected ? .on : .off
                }
            }
            return
        }

        let selected = defaults.selectedDevices(from: cachedDevices)
        let targets = Dictionary(uniqueKeysWithValues: commonTargets(selected.map { cachedHosts[$0.id] ?? [] }).map { ($0.name, $0) })
        for item in menu.items {
            guard let name = item.representedObject as? String, let target = targets[name] else { continue }
            item.state = isCurrentTarget(name, hardwareCurrent: target.isCurrent, devices: selected) ? .on : .off
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let selected = defaults.selectedDevices(from: cachedDevices)
        if defaults.mqtt.enabled {
            let status = NSMenuItem(title: "Home Assistant: \(mqtt.state.label)", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(.separator())
        }
        if let deviceLoadError, cachedDevices.isEmpty {
            if defaults.mqtt.isUsable, !defaults.knownMachineNames.isEmpty {
                buildNetworkTargetsMenu()
            } else {
                let errorItem = menu.addItem(withTitle: deviceLoadError, action: nil, keyEquivalent: "")
                errorItem.isEnabled = false
            }
        } else if cachedDevices.isEmpty {
            if defaults.mqtt.isUsable, !defaults.knownMachineNames.isEmpty {
                buildNetworkTargetsMenu()
            } else {
                menu.addItem(withTitle: "Open menu to load devices", action: nil, keyEquivalent: "")
            }
        } else if optionMode {
            buildPerDeviceMenu(cachedDevices.filter(\.isAvailable))
        } else if selected.count == 2 {
            buildCommonTargetsMenu(for: selected)
        } else if defaults.mqtt.isUsable, !defaults.knownMachineNames.isEmpty {
            buildNetworkTargetsMenu()
        } else {
            menu.addItem(withTitle: "Choose a default mouse and keyboard in Settings", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "S\u{0435}ttings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshMenuFromAction), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Logi Easy Switch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
    }

    private func buildCommonTargetsMenu(for devices: [LogiDevice]) {
        let common = commonTargets(devices.map { cachedHosts[$0.id] ?? [] })
        if common.isEmpty {
            menu.addItem(withTitle: "No common Easy-Switch target", action: nil, keyEquivalent: "")
        }
        for target in common {
            let item = NSMenuItem(title: defaults.displayName(for: target.name), action: #selector(switchDefaultPair(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.name
            item.state = isCurrentTarget(target.name, hardwareCurrent: target.isCurrent, devices: devices) ? .on : .off
            menu.addItem(item)
        }
    }

    private func isCurrentTarget(_ name: String, hardwareCurrent: Bool, devices: [LogiDevice]) -> Bool {
        guard devices.count == 2, devices.allSatisfy(\.connected) else { return false }
        if defaults.mqtt.isUsable {
            return name.compare(defaults.mqtt.computerName, options: .caseInsensitive) == .orderedSame
        }
        return hardwareCurrent
    }

    private func buildNetworkTargetsMenu() {
        for target in defaults.knownMachineNames {
            let item = NSMenuItem(title: defaults.displayName(for: target), action: #selector(switchDefaultPair(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target
            item.state = mqtt.currentTarget?.compare(defaults.displayName(for: target), options: .caseInsensitive) == .orderedSame ? .on : .off
            menu.addItem(item)
        }
    }

    private func buildPerDeviceMenu(_ devices: [LogiDevice]) {
        let title = NSMenuItem(title: "Per-device switching", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        for device in devices {
            let item = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: device.name)
            item.submenu = submenu
            menu.addItem(item)
            let hosts = cachedHosts[device.id] ?? []
            if hosts.isEmpty {
                submenu.addItem(withTitle: "No paired Easy-Switch targets", action: nil, keyEquivalent: "")
            }
            for host in hosts {
                let hostItem = NSMenuItem(title: defaults.displayName(for: host.name), action: #selector(switchSingleDevice(_:)), keyEquivalent: "")
                hostItem.target = self
                hostItem.representedObject = DeviceTarget(device: device, host: host)
                hostItem.state = host.connected && device.connected ? .on : .off
                submenu.addItem(hostItem)
            }
        }
    }

    @objc private func switchDefaultPair(_ sender: NSMenuItem) {
        guard let targetName = sender.representedObject as? String else { return }
        if defaults.mqtt.isUsable {
            guard mqtt.requestTarget(targetName) else {
                showError(LogiError.unavailable("Home Assistant MQTT is not connected."))
                return
            }
            return
        }
        let devices = defaults.selectedDevices(from: cachedDevices)
        switchDevices(devices, targetName: targetName)
    }

    @objc private func switchSingleDevice(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? DeviceTarget else { return }
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try LogiAgent().switchDevice(target.device, to: target.host)
                await MainActor.run { self.refreshMenu() }
            } catch {
                await MainActor.run { self.showError(error) }
            }
        }
    }

    private func switchDevices(_ devices: [LogiDevice], targetName: String) {
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                var targets: [DeviceTarget] = []
                for device in devices {
                    guard let host = try LogiAgent().hosts(for: device).first(where: {
                        $0.name.compare(targetName, options: .caseInsensitive) == .orderedSame
                    }) else {
                        throw LogiError.requestFailed("\(targetName) is not paired on \(device.name).")
                    }
                    targets.append(DeviceTarget(device: device, host: host))
                }
                // Keep the keyboard connected until the pointing device has moved.
                targets.sort { $0.device.type == "MOUSE" && $1.device.type == "KEYBOARD" }
                let pending = targets.filter { !$0.host.connected }.map { ($0.device, $0.host) }
                try LogiAgent().switchDevices(pending)
                await MainActor.run {
                    self.mqtt.publishCurrentTarget(self.defaults.displayName(for: targetName))
                    self.refreshMenu()
                }
            } catch {
                await MainActor.run { self.showError(error) }
            }
        }
    }

    @objc private func refreshMenuFromAction() { refreshMenu() }

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Settings must remain available even when Logitech device discovery is
        // slow or a device is temporarily disconnected. Present the cached
        // configuration immediately, then refresh the cache in the background.
        presentSettings()
        Task.detached { [weak self] in
            guard let self else { return }
            guard let devices = try? LogiAgent().devices() else { return }
            var hostsByDevice: [String: [LogiHost]] = [:]
            for device in devices {
                hostsByDevice[device.id] = (try? LogiAgent().hosts(for: device)) ?? []
            }
            await MainActor.run {
                self.cachedDevices = devices
                self.cachedHosts = hostsByDevice
                self.defaults.applyFallbacks(from: devices)
            }
        }
    }

    private func presentSettings() {
        let targets = shortcutTargets()
        let machineNames = Array(Set(defaults.knownMachineNames + cachedHosts.values.flatMap { $0.map(\.name) })).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        let controller = NSHostingController(rootView: SettingsView(defaults: defaults, devices: cachedDevices, didSave: { [weak self] in
            self?.installHotkeys()
            self?.configureMQTT()
            self?.refreshMenu()
        }, targets: targets, machineNames: machineNames))
        let window = NSWindow(contentViewController: controller)
        window.title = "Logi Easy Switch Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 620, height: 720))
        window.isReleasedWhenClosed = false
        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.keyEquivalent = "w"
            closeButton.keyEquivalentModifierMask = .command
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    private func showError(_ error: Error) {
        if isMenuOpen {
            refreshPending = true
            return
        }
        menu.removeAllItems()
        menu.addItem(withTitle: error.localizedDescription, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "S\u{0435}ttings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    nonisolated private func commonTargets(_ hostLists: [[LogiHost]]) -> [CommonTarget] {
        guard let first = hostLists.first else { return [] }
        var seenNames: Set<String> = []
        return first.compactMap { host in
            let normalizedName = host.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seenNames.insert(normalizedName).inserted else { return nil }
            let matching = hostLists.map { list in list.first { $0.name.compare(host.name, options: .caseInsensitive) == .orderedSame } }
            guard matching.allSatisfy({ $0 != nil }) else { return nil }
            return CommonTarget(name: host.name, isCurrent: matching.allSatisfy { $0?.connected == true })
        }
    }

    private func shortcutTargets() -> [ShortcutTarget] {
        var results: [ShortcutTarget] = []
        let pairs = cachedDevices.map { ($0, cachedHosts[$0.id] ?? []) }
        let selected = defaults.selectedDevices(from: cachedDevices)
        let selectedHosts = selected.compactMap { device in pairs.first(where: { $0.0.id == device.id })?.1 }
        if selectedHosts.count == 2 {
            for host in selectedHosts[0] where selectedHosts[1].contains(where: { $0.name == host.name }) {
                results.append(ShortcutTarget(id: "default:\(host.name)", label: "Default pair → \(host.name)"))
            }
        }
        for (device, hosts) in pairs {
            for host in hosts { results.append(ShortcutTarget(id: "device:\(device.id):\(host.index)", label: "\(device.name) → \(host.name)")) }
        }
        return results
    }

    private func installHotkeys() {
        hotkeys.replace(with: defaults.hotkeys) { [weak self] target in
            Task { @MainActor in self?.runHotkey(target) }
        }
    }

    private func configureMQTT() {
        mqtt.configure(defaults.mqtt, password: MQTTPasswordStore.load(), targets: defaults.knownMachineNames.map(defaults.displayName(for:)))
    }

    private func currentLocalTarget() -> String? {
        let selected = defaults.selectedDevices(from: cachedDevices)
        guard selected.count == 2, selected.allSatisfy(\.connected) else { return nil }
        if defaults.mqtt.isUsable { return defaults.mqtt.computerName }
        let connected = selected.compactMap { device in cachedHosts[device.id]?.first(where: \.connected)?.name }
        guard connected.count == 2,
              connected[0].compare(connected[1], options: .caseInsensitive) == .orderedSame else { return nil }
        return connected[0]
    }

    private func runHotkey(_ target: String) {
        let parts = target.split(separator: ":", maxSplits: 2).map(String.init)
        guard let kind = parts.first else { return }
        if kind == "default", parts.count == 2 {
            if defaults.mqtt.isUsable, mqtt.requestTarget(parts[1]) { return }
            switchDevices(defaults.selectedDevices(from: cachedDevices), targetName: parts[1])
            return
        }
        if kind == "device", parts.count == 3, let channel = Int(parts[2]), let device = cachedDevices.first(where: { $0.id == parts[1] }) {
            Task.detached { [weak self] in
                do {
                    guard let host = try LogiAgent().hosts(for: device).first(where: { $0.index == channel }) else { return }
                    try LogiAgent().switchDevice(device, to: host)
                    await MainActor.run { self?.refreshMenu() }
                } catch { await MainActor.run { self?.showError(error) } }
            }
        }
    }

    private static func menuBarIcon() -> NSImage {
        let size = NSSize(width: 27, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let stroke = NSColor.black
            stroke.setStroke()

            let keyboard = NSBezierPath(roundedRect: NSRect(x: 0.8, y: 3.5, width: 15, height: 10), xRadius: 2, yRadius: 2)
            keyboard.lineWidth = 1.5
            keyboard.stroke()
            for x in [3.5, 7.5, 11.5] {
                let key = NSBezierPath()
                key.move(to: NSPoint(x: x, y: 10))
                key.line(to: NSPoint(x: x + 1.5, y: 10))
                key.lineWidth = 1.3
                key.stroke()
            }
            let space = NSBezierPath()
            space.move(to: NSPoint(x: 4, y: 6.5))
            space.line(to: NSPoint(x: 10.5, y: 6.5))
            space.lineWidth = 1.3
            space.stroke()

            let mouse = NSBezierPath(roundedRect: NSRect(x: 18, y: 1.2, width: 8, height: 15.6), xRadius: 4, yRadius: 4)
            mouse.lineWidth = 1.5
            mouse.stroke()
            let divide = NSBezierPath()
            divide.move(to: NSPoint(x: 22, y: 12))
            divide.line(to: NSPoint(x: 22, y: 16.5))
            divide.lineWidth = 1.3
            divide.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

}

private struct DeviceTarget: Sendable {
    let device: LogiDevice
    let host: LogiHost
}

private struct CommonTarget {
    let name: String
    let isCurrent: Bool
}
