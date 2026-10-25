import AppKit
import SwiftUI

private final class DeckPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class DeckController: ObservableObject {
    let store: DeckStore
    private let providers: [DeckActionProvider] = [BuiltinDeckProvider()]
    @Published var folder: UUID?
    @Published var presentations: [UUID: DeckPresentation] = [:]
    @Published var error: String?
    @Published var running: UUID?
    @Published private(set) var countdown: DeckCountdown?
    private var panel: NSPanel?
    private var monitor: Any?
    private var refreshTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var generation = UUID()
    private var navigationRevision = UUID()
    private weak var previousApp: NSRunningApplication?
    var visibleButtons: [DeckButton] { store.configuration.buttons.filter { $0.parentID == folder } }
    init(store: DeckStore) { self.store = store }

    func toggle() { if panel?.isVisible == true { hide() } else { show() } }
    func show() {
        if panel == nil {
            let panel = DeckPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460), styleMask: [.borderless], backing: .buffered, defer: false)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: DeckView(controller: self, store: store))
            self.panel = panel
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        folder = nil
        navigationRevision = UUID()
        error = nil
        generation = UUID()
        panel?.center()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            guard !event.isARepeat else { return nil }
            if event.keyCode == 53 { self.hide(); return nil }
            if event.keyCode == 51 { self.back(); return nil }
            let matches = DeckGroups.activationTargets(in: self.folder, configuration: self.store.configuration).filter { $0.key?.keyCode == UInt32(event.keyCode) && $0.key?.modifiers == carbonModifiers(from: event.modifierFlags) }
            if matches.count == 1 { self.activate(matches[0]); return nil }
            if matches.count > 1 { self.error = "Multiple buttons use this key. Change their keys in settings."; return nil }
            return event
        }
        armIdleTimeout()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    func hide() {
        generation = UUID()
        cancelTimer()
        refreshTask?.cancel()
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { previousApp?.activate(options: []) }
    }
    func back() {
        guard let folder else { return }
        navigationRevision = UUID()
        self.folder = DeckGroups.backDestination(from: folder, configuration: store.configuration)
        armIdleTimeout()
    }
    private func cancelTimer() {
        dismissTask?.cancel()
        dismissTask = nil
        countdown = nil
    }
    private func scheduleDismiss(_ seconds: Double) {
        cancelTimer()
        let timer = DeckCountdown(title: "Auto-dismiss", seconds: seconds)
        countdown = timer
        dismissTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: timer.deadline) } catch { return }
            self?.hide()
        }
    }
    private func scheduleReturn(_ button: DeckButton, seconds: Double) {
        cancelTimer()
        let session = generation
        let navigation = navigationRevision
        let destination = DeckGroups.returnDestination(for: button, configuration: store.configuration)
        let name = store.configuration.buttons.first { $0.id == destination }?.name ?? "Top level"
        let timer = DeckCountdown(title: "Return to \(name)", seconds: seconds)
        countdown = timer
        dismissTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: timer.deadline) } catch { return }
            guard let self, self.generation == session, self.navigationRevision == navigation, self.panel?.isVisible == true else { return }
            self.folder = DeckGroups.returnDestination(for: button, configuration: self.store.configuration)
            self.navigationRevision = UUID()
            // Keep the returned folder visible rather than rearming the opening timeout.
            self.dismissTask = nil
            self.countdown = nil
            await self.refresh()
        }
    }
    private func armIdleTimeout() {
        cancelTimer()
        if store.configuration.openingDismissEnabled { scheduleDismiss(store.configuration.idleTimeout) }
    }
    func activate(_ button: DeckButton) {
        guard running == nil else { return }
        error = nil
        if button.kind == "group" { return }
        if button.kind == "folder" { navigationRevision = UUID(); folder = button.id; armIdleTimeout(); return }
        cancelTimer()
        running = button.id
        let session = generation
        let navigation = navigationRevision
        let config = store.configuration
        Task {
            do {
                guard let provider = providers.first(where: { $0.kinds.contains(button.kind) }) else { throw DeckError.message("No provider for \(button.kind).") }
                try await provider.execute(button, configuration: config)
                running = nil
                guard generation == session, navigationRevision == navigation, panel?.isVisible == true else { return }
                if let rule = button.returnAfterAction, rule.enabled,
                   DeckGroups.containingFolder(of: button, configuration: config) != nil {
                    scheduleReturn(button, seconds: rule.delay)
                } else if let delay = button.dismiss.delay(defaultEnabled: config.dismissAfterAction, defaultDelay: config.actionDelay, override: button.delay) { scheduleDismiss(delay) }
                else if button.dismiss == .inherit { armIdleTimeout() }
                // Never also suppresses the global timeout until another action or folder is chosen.
                await refresh()
            } catch {
                running = nil
                guard generation == session, navigationRevision == navigation else { return }
                self.error = error.localizedDescription
            }
        }
    }
    private func refresh() async {
        let session = generation
        for button in visibleButtons {
            guard !Task.isCancelled, generation == session else { return }
            guard let provider = providers.first(where: { $0.kinds.contains(button.kind) }) else { continue }
            do {
                let value = try await provider.presentation(button, configuration: store.configuration)
                guard generation == session, !Task.isCancelled else { return }
                presentations[button.id] = value
            } catch {
                presentations[button.id] = DeckPresentation(text: "Unavailable: \(error.localizedDescription)")
            }
        }
    }
}

private struct DeckView: View {
    @ObservedObject var controller: DeckController
    @ObservedObject var store: DeckStore
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                if controller.folder != nil { Button { controller.back() } label: { Image(systemName: "chevron.left") }.help("Back (Delete)") }
                Text(store.configuration.buttons.first(where: { $0.id == controller.folder })?.name ?? "Shortcuts").font(.title2.bold())
                Spacer()
                Button { controller.hide() } label: { Image(systemName: "xmark") }.help("Close (Escape)")
            }
            if controller.visibleButtons.isEmpty { Text("Add shortcuts in Shortcuts Settings from the menu bar.").foregroundStyle(.secondary).frame(maxHeight: .infinity) }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], spacing: 12) {
                    ForEach(controller.visibleButtons) { button in
                        if button.kind == "group" {
                            VStack(spacing: 12) {
                                tileContent(button)
                                let controls = DeckGroups.controls(button, in: store.configuration)
                                if controls.isEmpty { Text("Add controls in settings").font(.caption).foregroundStyle(.secondary) }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 45))], spacing: 6) {
                                    ForEach(controls) { control in
                                        Button { controller.activate(control) } label: {
                                            VStack(spacing: 3) {
                                                Text(control.name).font(.headline)
                                                if let key = control.key { Text(key.displayLabel).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                                            }.frame(maxWidth: .infinity, minHeight: 32)
                                        }.disabled(controller.running != nil)
                                        .help(control.kind == "folder" ? "Open \(control.name)" : control.name)
                                    }
                                }
                            }.padding(12).frame(maxWidth: .infinity).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        } else {
                            Button { controller.activate(button) } label: {
                                tileContent(button).frame(maxWidth: .infinity, minHeight: 110).padding(10)
                            }.buttonStyle(.plain).background(.quaternary, in: RoundedRectangle(cornerRadius: 12)).disabled(controller.running != nil)
                        }
                    }
                }
            }
            if let countdown = controller.countdown { DeckCountdownView(countdown: countdown) }
            if let error = controller.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
    private func tileContent(_ button: DeckButton) -> some View {
        let presentation = controller.presentations[button.id]
        let replaceName = button.settings["textReplacesName"] == "true" && !(presentation?.text ?? "").isEmpty
        return VStack(spacing: 8) {
            if button.kind != "group" {
                HStack { Spacer(); Text(button.key?.displayLabel ?? "").font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
            Image(systemName: presentation?.icon ?? (DeckHATarget.automaticLight(button) ? "lightbulb" : button.icon)).font(.system(size: 28))
                .foregroundStyle(presentation?.highlighted == true ? Color.yellow : (presentation?.highlighted == false ? Color.secondary : Color.primary))
            if !replaceName { Text(button.name).font(.headline).lineLimit(2) }
            Text(controller.running == button.id ? "Running…" : presentation?.text ?? " ")
                .font(replaceName ? .headline : .caption)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }
}
