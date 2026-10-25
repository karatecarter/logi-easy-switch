import AppKit
import SwiftUI
import QuartzCore

private final class DeckPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class DeckController: ObservableObject {
    let store: DeckStore
    private let providers: [DeckActionProvider]
    @Published var folder: UUID?
    @Published private(set) var navigatingBack = false
    @Published private(set) var columns = 3
    @Published var presentations: [UUID: DeckPresentation] = [:]
    @Published var error: String?
    @Published var running: UUID?
    @Published private(set) var countdown: DeckCountdown?
    private var panel: NSPanel?
    private var launcherVisible = false
    private var monitor: Any?
    private var outsideClickMonitors: [Any] = []
    private var refreshTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var generation = UUID()
    private var navigationRevision = UUID()
    private var thermostatPreview = DeckThermostatPreview()
    private struct TickBatch {
        var count: Int
        var button: DeckButton
        var preview: DeckThermostatPreview.Ticket?
        var session: UUID
        var navigation: UUID
    }
    @Published private(set) var pendingTickCounts: [UUID: Int] = [:]
    private var tickBatches: [UUID: TickBatch] = [:]
    private let tickDebouncer = DeckTickDebouncer()
    private weak var previousApp: NSRunningApplication?
    var visibleButtons: [DeckButton] { store.configuration.buttons.filter { $0.parentID == folder } }
    init(store: DeckStore, logi: DeckLogiService? = nil) {
        self.store = store
        providers = [BuiltinDeckProvider()] + (logi.map { [DeckLogiProvider(service: $0)] } ?? [])
    }

    func toggle() { if launcherVisible { hide() } else { show() } }
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
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }
        launcherVisible = true
        folder = nil
        navigationRevision = UUID()
        error = nil
        generation = UUID()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        resizeToFit(animated: false, on: screen)
        NSApp.activate(ignoringOtherApps: true)
        panel?.ignoresMouseEvents = false
        if panel?.isVisible != true { panel?.alphaValue = 0 }
        panel?.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = 1
        }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            guard !event.isARepeat else { return nil }
            if event.keyCode == 53 { self.hide(); return nil }
            if event.keyCode == 51 || event.keyCode == 123 { self.back(); return nil }
            let matches = DeckGroups.activationTargets(in: self.folder, configuration: self.store.configuration).filter { $0.key?.keyCode == UInt32(event.keyCode) && $0.key?.modifiers == carbonModifiers(from: event.modifierFlags) }
            if matches.count == 1 { self.activate(matches[0]); return nil }
            if matches.count > 1 { self.error = "Multiple buttons use this key. Change their keys in settings."; return nil }
            return event
        }
        installOutsideClickMonitors()
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
    private func installOutsideClickMonitors() {
        outsideClickMonitors.forEach { NSEvent.removeMonitor($0) }
        outsideClickMonitors = []
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            self?.hide(restoreFocus: false)
        }) { outsideClickMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return event }
            if event.window !== self.panel && !(self.panel?.childWindows?.contains(where: { $0 === event.window }) ?? false) {
                self.hide(restoreFocus: false)
            }
            return event
        }) { outsideClickMonitors.append(monitor) }
    }
    func hide(restoreFocus: Bool = true) {
        guard launcherVisible else { return }
        launcherVisible = false
        outsideClickMonitors.forEach { NSEvent.removeMonitor($0) }
        outsideClickMonitors = []
        generation = UUID()
        for (id, actual) in thermostatPreview.reset() {
            presentations[id]?.text = actual
            presentations[id]?.pendingSetpoint = false
        }
        cancelTimer()
        refreshTask?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        panel?.ignoresMouseEvents = true
        let closingGeneration = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == closingGeneration, !self.launcherVisible else { return }
                self.panel?.orderOut(nil)
                if restoreFocus && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    self.previousApp?.activate(options: [])
                }
            }
        }
    }
    func back() {
        guard let folder else { return }
        navigate(to: DeckGroups.backDestination(from: folder, configuration: store.configuration), backwards: true)
        armIdleTimeout()
    }
    private func navigate(to destination: UUID?, backwards: Bool) {
        navigationRevision = UUID()
        guard folder != destination else { return }
        navigatingBack = backwards
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            folder = destination
        } else {
            withAnimation(.easeInOut(duration: 0.22)) { folder = destination }
        }
        resizeToFit(animated: true)
    }
    func resizeToFit(animated: Bool, on screen: NSScreen? = nil) {
        guard let panel, let screen = screen ?? panel.screen ?? NSScreen.main else { return }
        let layout = DeckWindowLayout.fit(in: screen.visibleFrame) { count, width in
            let view = NSHostingView(rootView: DeckView(controller: self, store: store, measuringColumns: count)
                .frame(width: width).fixedSize(horizontal: false, vertical: true))
            view.layoutSubtreeIfNeeded()
            return view.fittingSize.height
        }
        if columns != layout.columns { columns = layout.columns }
        guard abs(panel.frame.width - layout.frame.width) > 0.5 || abs(panel.frame.height - layout.frame.height) > 0.5 ||
              abs(panel.frame.midX - layout.frame.midX) > 0.5 || abs(panel.frame.midY - layout.frame.midY) > 0.5 else { return }
        if animated && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(layout.frame, display: true)
            }
        } else { panel.setFrame(layout.frame, display: true) }
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
            self.navigate(to: DeckGroups.returnDestination(for: button, configuration: self.store.configuration), backwards: true)
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
        if DeckTicks.sign(button) != nil {
            queueTicks(button)
            return
        }
        guard running == nil else { return }
        execute(button)
    }
    private func queueTicks(_ button: DeckButton) {
        cancelTimer()
        error = nil
        let batchID = DeckTicks.batchID(button, configuration: store.configuration)
        var batch = tickBatches[batchID] ?? TickBatch(count: 0, button: button, session: generation, navigation: navigationRevision)
        let increment = batch.count + (DeckTicks.sign(button) ?? 0)
        guard abs(increment) <= 10000 else { return }
        batch.count = increment
        batch.button = button
        if let groupID = button.parentID, let text = presentations[groupID]?.text,
           let (ticket, preview) = thermostatPreview.begin(action: button, configuration: store.configuration, text: text) {
            batch.preview = ticket
            presentations[groupID]?.text = preview
            presentations[groupID]?.pendingSetpoint = true
        }
        for control in store.configuration.buttons where DeckTicks.batchID(control, configuration: store.configuration) == batchID {
            pendingTickCounts.removeValue(forKey: control.id)
        }
        pendingTickCounts[button.id] = batch.count
        tickBatches[batchID] = batch
        tickDebouncer.schedule(batchID) { [weak self] in
            guard let self else { return }
            // Serialize against other actions without dropping a queued adjustment.
            while self.running != nil {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard let ready = self.tickBatches.removeValue(forKey: batchID) else { return }
            for control in self.store.configuration.buttons where DeckTicks.batchID(control, configuration: self.store.configuration) == batchID {
                self.pendingTickCounts.removeValue(forKey: control.id)
            }
            do {
                let resolved = try DeckTicks.resolvedIncrement(ready.button, increment: ready.count)
                self.execute(resolved, previewTicket: ready.preview, previewAlreadyApplied: true, originSession: ready.session, originNavigation: ready.navigation)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func execute(_ button: DeckButton, previewTicket existingTicket: DeckThermostatPreview.Ticket? = nil, previewAlreadyApplied: Bool = false, originSession: UUID? = nil, originNavigation: UUID? = nil) {
        error = nil
        if button.kind == "group" { return }
        if button.kind == "folder" { navigate(to: button.id, backwards: false); armIdleTimeout(); return }
        cancelTimer()
        running = button.id
        let session = originSession ?? generation
        let navigation = originNavigation ?? navigationRevision
        let config = store.configuration
        var previewTicket = existingTicket
        if !previewAlreadyApplied, let groupID = button.parentID, let text = presentations[groupID]?.text,
           let (ticket, preview) = thermostatPreview.begin(action: button, configuration: config, text: text) {
            previewTicket = ticket
            presentations[groupID]?.text = preview
            presentations[groupID]?.pendingSetpoint = true
        }
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
                guard generation == session else { return }
                if let previewTicket, let actual = thermostatPreview.cancel(previewTicket) {
                    presentations[previewTicket.groupID]?.text = actual
                    presentations[previewTicket.groupID]?.pendingSetpoint = false
                }
                guard navigationRevision == navigation else { return }
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
                var value = try await provider.presentation(button, configuration: store.configuration)
                guard generation == session, !Task.isCancelled else { return }
                let resolved = thermostatPreview.reconcile(groupID: button.id, actual: value.text)
                value.text = resolved.text
                value.pendingSetpoint = resolved.pending
                presentations[button.id] = value
            } catch {
                presentations[button.id] = DeckPresentation(text: "Unavailable: \(error.localizedDescription)")
            }
        }
    }
}

struct DeckView: View {
    @ObservedObject var controller: DeckController
    @ObservedObject var store: DeckStore
    var measuringColumns: Int? = nil
    private var columnCount: Int { measuringColumns ?? controller.columns }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var folderTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: controller.navigatingBack ? .leading : .trailing).combined(with: .opacity),
            removal: .move(edge: controller.navigatingBack ? .trailing : .leading).combined(with: .opacity))
    }
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                if controller.folder != nil { Button { controller.back() } label: { Image(systemName: "chevron.left") }.help("Back (← or Delete)") }
                Text(store.configuration.buttons.first(where: { $0.id == controller.folder })?.name ?? "Shortcuts").font(.title2.bold())
                Spacer()
                Button { controller.hide() } label: { Image(systemName: "xmark") }.help("Close (Escape)")
            }
            ZStack {
            if measuringColumns != nil {
                iconGrid.fixedSize(horizontal: false, vertical: true)
            } else {
            ScrollView {
                iconGrid
            }
            .overlay {
                if controller.visibleButtons.isEmpty {
                    Text("Add shortcuts in Shortcuts Settings from the menu bar.").foregroundStyle(.secondary)
                }
            }
            .id(controller.folder)
            .transition(folderTransition)
            }
            }
            .frame(maxWidth: .infinity, maxHeight: measuringColumns == nil ? .infinity : nil)
            .clipped()
            statusFooter
                .frame(height: 28)
                .frame(maxWidth: .infinity)
            if let error = controller.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .onChange(of: store.configuration) { _, _ in updateSize() }
        .onChange(of: controller.presentations) { _, _ in updateSize() }
        .onChange(of: controller.error) { _, _ in updateSize() }
    }
    private var statusFooter: some View {
        let updating = !controller.pendingTickCounts.isEmpty || controller.presentations.values.contains { $0.pendingSetpoint }
        return Group {
            if let countdown = controller.countdown {
                DeckCountdownView(countdown: countdown, status: updating ? "Updating setpoint…" : nil)
            } else {
                VStack(spacing: 5) {
                    HStack {
                        if updating { Text("Updating setpoint…").font(.caption).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                    }
                    Color.clear.frame(height: 4)
                }
            }
        }
    }
    private func updateSize() {
        guard measuringColumns == nil else { return }
        controller.resizeToFit(animated: true)
    }
    private var iconGrid: some View {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount), spacing: 12) {
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
                                                if let key = control.key { Text(key.compactDisplayLabel).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                                            }.frame(maxWidth: .infinity, minHeight: 32)
                                        }.disabled(controller.running != nil && DeckTicks.sign(control) == nil)
                                        .help(control.kind == "folder" ? "Open \(control.name)" : control.name)
                                    }
                                }
                            }.padding(12).frame(maxWidth: .infinity).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        } else {
                            Button { controller.activate(button) } label: {
                                tileContent(button).frame(maxWidth: .infinity, minHeight: 110).padding(10)
                            }.buttonStyle(.plain).background(.quaternary, in: RoundedRectangle(cornerRadius: 12)).disabled(controller.running != nil && DeckTicks.sign(button) == nil)
                        }
                    }
                }

    }
    private func tileContent(_ button: DeckButton) -> some View {
        let presentation = controller.presentations[button.id]
        let realIcon = ["image", "favicon", "application"].contains(button.settings["iconSource"] ?? "")
        let replaceName = button.settings["textReplacesName"] == "true" && !(presentation?.text ?? "").isEmpty
        return Group {
            if realIcon {
                VStack(spacing: 4) {
                    GeometryReader { geometry in
                        DeckButtonIcon(button: button, presentation: presentation, size: min(geometry.size.height, geometry.size.width))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if !replaceName { Text(button.name).font(.headline).lineLimit(2) }
                    if controller.running == button.id || !(presentation?.text ?? "").isEmpty {
                        Text(controller.running == button.id ? "Running…" : presentation?.text ?? "")
                            .font(replaceName ? .headline : .caption).lineLimit(3)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(height: 110)
                .overlay(alignment: .topTrailing) {
                    if button.kind != "group" {
                        Text(button.key?.displayLabel ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    if button.kind != "group" {
                        HStack { Spacer(); Text(button.key?.displayLabel ?? "").font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                    DeckButtonIcon(button: button, presentation: presentation)
                    if !replaceName { Text(button.name).font(.headline).lineLimit(2) }
                    Text(controller.running == button.id ? "Running…" : presentation?.text ?? " ")
                        .font(replaceName ? .headline : .caption)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
