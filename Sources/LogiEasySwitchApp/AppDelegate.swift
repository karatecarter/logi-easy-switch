import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var optionMode = false
    private var isMenuOpen = false
    private var refreshPending = false
    private var isOpeningSettings = false
    private var settingsWindow: NSWindow?
    private var cachedDevices: [LogiDevice] = []
    private var cachedHosts: [String: [LogiHost]] = [:]
    private let defaults = DeviceDefaults()
    private let hotkeys = HotkeyManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.title = ""
        statusItem.button?.isHidden = false
        statusItem.button?.toolTip = "Logi Easy Switch"
        menu.delegate = self
        statusItem.menu = menu
        installHotkeys()
        rebuildMenu()
        loadDevices()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        optionMode = NSEvent.modifierFlags.contains(.option)
        refreshSnapshotForOpenMenu()
        rebuildMenu()
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

    private func refreshSnapshotForOpenMenu() {
        guard let devices = try? LogiAgent().devices() else { return }
        cachedDevices = devices
        defaults.applyFallbacks(from: devices)

        let devicesToRefresh = optionMode
            ? devices.filter(\.isAvailable)
            : defaults.selectedDevices(from: devices)
        for device in devicesToRefresh {
            if let hosts = try? LogiAgent().hosts(for: device) {
                cachedHosts[device.id] = hosts
            }
        }
    }

    private func loadDevices() {
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
                    self.defaults.applyFallbacks(from: devices)
                    if self.isMenuOpen {
                        self.refreshPending = true
                    } else {
                        self.rebuildMenu()
                    }
                }
            } catch {
                await MainActor.run { self.showError(error) }
            }
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let selected = defaults.selectedDevices(from: cachedDevices)
        if cachedDevices.isEmpty {
            menu.addItem(withTitle: "Open menu to load devices", action: nil, keyEquivalent: "")
        } else if optionMode {
            buildPerDeviceMenu(cachedDevices.filter(\.isAvailable))
        } else if selected.count == 2 {
            buildCommonTargetsMenu(for: selected)
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
            item.state = target.isCurrent && devices.allSatisfy(\.connected) ? .on : .off
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
                for target in targets where !target.host.connected {
                    try LogiAgent().switchDevice(target.device, to: target.host)
                }
                await MainActor.run { self.refreshMenu() }
            } catch {
                await MainActor.run { self.showError(error) }
            }
        }
    }

    @objc private func refreshMenuFromAction() { refreshMenu() }

    @objc private func openSettings() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard !isOpeningSettings else { return }
        isOpeningSettings = true
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let devices = try LogiAgent().devices()
                var hostsByDevice: [String: [LogiHost]] = [:]
                for device in devices {
                    hostsByDevice[device.id] = (try? LogiAgent().hosts(for: device)) ?? []
                }
                let loadedHosts = hostsByDevice
                await MainActor.run {
                    self.isOpeningSettings = false
                    self.cachedDevices = devices
                    self.cachedHosts = loadedHosts
                    self.defaults.applyFallbacks(from: devices)
                    self.presentSettings()
                }
            } catch {
                await MainActor.run {
                    self.isOpeningSettings = false
                    self.showError(error)
                }
            }
        }
    }

    private func presentSettings() {
        let targets = shortcutTargets()
        let machineNames = Array(Set(cachedHosts.values.flatMap { $0.map(\.name) })).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        let controller = NSHostingController(rootView: SettingsView(defaults: defaults, devices: cachedDevices, didSave: { [weak self] in
            self?.installHotkeys()
            self?.refreshMenu()
        }, targets: targets, machineNames: machineNames))
        let window = NSWindow(contentViewController: controller)
        window.title = "Logi Easy Switch Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 580, height: 620))
        window.isReleasedWhenClosed = false
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
        return first.compactMap { host in
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

    private func runHotkey(_ target: String) {
        let parts = target.split(separator: ":", maxSplits: 2).map(String.init)
        guard let kind = parts.first else { return }
        if kind == "default", parts.count == 2 { switchDevices(defaults.selectedDevices(from: cachedDevices), targetName: parts[1]); return }
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
