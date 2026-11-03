import AppKit
import CodexBarCore
import Observation
import QuartzCore
import SwiftUI

@MainActor
final class PacePanelHost<Content: View> {
    private let content: @MainActor () -> Content
    private let onClose: @MainActor () -> Void
    private let sources: PacePanelEventSources
    private(set) var panel: NSPanel?
    private(set) var hostingView: NSHostingView<AnyView>?
    private var glass: PaceGlassView?
    private var scrollView: NSScrollView?
    private weak var anchor: NSStatusBarButton?
    private var itemScreenFrame = NSRect.zero
    private var visibleFrame = NSRect.zero
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var appearanceObservation: NSKeyValueObservation?
    private var countdownTimer: Timer?
    private var generation = 0
    private var loggedKeyFailure = false
    private var isObservingContent = false
    var shortcuts: @MainActor () -> [String: String] = { ProviderSwitcherShortcuts.defaults }
    var onCommand: @MainActor (PacePanelCommand) -> Void = { _ in }
    var log: @MainActor (String) -> Void = { _ in }

    init(content: @escaping @MainActor () -> Content, onClose: @escaping @MainActor () -> Void) {
        self.content = content
        self.onClose = onClose
        self.sources = PacePanelEventSources()
    }

    init(
        sources: PacePanelEventSources,
        content: @escaping @MainActor () -> Content,
        onClose: @escaping @MainActor () -> Void)
    {
        self.content = content
        self.onClose = onClose
        self.sources = sources
    }

    isolated deinit {
        self.close()
    }

    var isOpen: Bool {
        self.panel != nil
    }

    func toggle(anchor: NSStatusBarButton) {
        if self.isOpen {
            self.close()
            return
        }
        guard let window = anchor.window, let screen = window.screen else { return }
        self.anchor = anchor
        self.show(
            itemScreenFrame: window.convertToScreen(anchor.convert(anchor.bounds, to: nil)),
            visibleFrame: screen.visibleFrame)
    }

    func show(itemScreenFrame: NSRect, visibleFrame: NSRect) {
        guard !self.isOpen else { return }
        let started = CACurrentMediaTime()
        self.generation += 1
        self.itemScreenFrame = itemScreenFrame
        self.visibleFrame = visibleFrame
        let panel = PaceKeyPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.isExcludedFromWindowsMenu = true
        panel.autorecalculatesKeyViewLoop = true
        panel.appearance = NSApp.effectiveAppearance
        panel.onClose = { [weak self] in self?.close() }
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        let glass = PaceGlassView(frame: .zero)
        let scroll = NSScrollView(frame: .zero)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        glass.addSubview(scroll)
        panel.contentView = glass
        self.panel = panel
        self.glass = glass
        self.scrollView = scroll
        self.refreshContent()
        self.anchor?.highlight(true)
        self.startSources()
        panel.makeKeyAndOrderFront(nil)
        panel.recalculateKeyViewLoop()
        panel.selectNextKeyView(nil)
        panel.displayIfNeeded()
        let generation = self.generation
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, self.generation == generation, let panel, self.panel === panel else { return }
            self.log("[perf] pace-panel open latency_ms=\((CACurrentMediaTime() - started) * 1000)")
            if !panel.isKeyWindow, !self.loggedKeyFailure {
                self.loggedKeyFailure = true
                self.log("pace-panel key focus unavailable")
            }
        }
    }

    func refreshContent() {
        guard let panel else { return }
        let generation = self.generation
        let update: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.generation == generation else { return }
            self.isObservingContent = false
            self.refreshContent()
        }
        let makeRoot = {
            AnyView(self.content().frame(width: 360).fixedSize(horizontal: false, vertical: true))
        }
        let root: AnyView
        if self.isObservingContent {
            root = makeRoot()
        } else {
            self.isObservingContent = true
            root = withObservationTracking(makeRoot, onChange: {
                Task { @MainActor in update() }
            })
        }
        let hosting: NSHostingView<AnyView>
        if let existing = self.hostingView {
            existing.rootView = root
            hosting = existing
        } else {
            hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = [.intrinsicContentSize]
            self.hostingView = hosting
            self.scrollView?.documentView = hosting
        }
        hosting.setFrameSize(NSSize(width: 360, height: max(1, hosting.fittingSize.height)))
        hosting.layoutSubtreeIfNeeded()
        let height = max(1, hosting.fittingSize.height)
        hosting.setFrameSize(NSSize(width: 360, height: height))
        let frame = PacePanelPlacement.frame(
            itemScreenFrame: self.itemScreenFrame,
            visibleFrame: self.visibleFrame,
            contentSize: NSSize(width: 360, height: height))
        panel.setFrame(frame, display: self.isOpen)
        self.scrollView?.frame = NSRect(origin: .zero, size: frame.size)
        self.scrollView?.hasVerticalScroller = height > frame.height
    }

    func close() {
        guard let panel else { return }
        self.generation += 1
        self.panel = nil
        self.isObservingContent = false
        self.monitors.forEach(self.sources.removeMonitor)
        self.monitors.removeAll()
        for (center, observer) in self.observers {
            center.removeObserver(observer)
        }
        self.observers.removeAll()
        self.appearanceObservation?.invalidate()
        self.appearanceObservation = nil
        self.countdownTimer?.invalidate()
        self.countdownTimer = nil
        (panel as? PaceKeyPanel)?.onClose = nil
        (panel as? PaceKeyPanel)?.onKey = nil
        panel.makeFirstResponder(nil)
        panel.initialFirstResponder = nil
        panel.orderOut(nil)
        self.scrollView?.documentView = nil
        panel.contentView = nil
        panel.close()
        self.hostingView = nil
        self.scrollView = nil
        self.glass = nil
        self.anchor?.highlight(false)
        self.anchor = nil
        self.log("[perf] pace-panel close")
        self.onClose()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let command = PacePanelKeyMap.command(for: event, shortcuts: self.shortcuts()) else { return false }
        if command == .close { self.close() } else { self.onCommand(command) }
        return true
    }

    private func startSources() {
        if let monitor = self.sources.addGlobalMouseDown({ [weak self] in self?.close() }) {
            self.monitors.append(monitor)
        }
        if let monitor = self.sources.addLocalMouseDown({ [weak self] windowNumber, location in
            guard let self, let panel = self.panel else { return }
            let window = NSApp.window(withWindowNumber: windowNumber)
            let point = window?.convertPoint(toScreen: location) ?? location
            if window !== panel, !self.itemScreenFrame.contains(point) { self.close() }
        }) {
            self.monitors.append(monitor)
        }
        self.observe(NSWorkspace.activeSpaceDidChangeNotification, center: self.sources.workspaceCenter)
        self.observe(NSWorkspace.willSleepNotification, center: self.sources.workspaceCenter)
        self.observe(NSApplication.didChangeScreenParametersNotification, center: self.sources.applicationCenter)
        self.observe(
            NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            center: self.sources.workspaceCenter,
            closes: false)
        let updateAppearance: @MainActor @Sendable () -> Void = { [weak self] in self?.refreshAppearance() }
        self.appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in updateAppearance() }
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshContent() }
        }
        timer.tolerance = 6
        RunLoop.main.add(timer, forMode: .common)
        self.countdownTimer = timer
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter, closes: Bool = true) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if closes {
                    self?.close()
                } else {
                    self?.refreshAppearance()
                }
            }
        }
        self.observers.append((center, token))
    }

    private func refreshAppearance() {
        self.panel?.appearance = NSApp.effectiveAppearance
        self.glass?.refreshAppearance()
    }
}

@MainActor
struct PacePanelEventSources {
    var applicationCenter: NotificationCenter = .default
    var workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    var addGlobalMouseDown: (@escaping @MainActor () -> Void) -> Any? = { handler in
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    var addLocalMouseDown: (@escaping @MainActor (Int, NSPoint) -> Void) -> Any? = { handler in
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            let windowNumber = event.windowNumber
            let location = event.locationInWindow
            MainActor.assumeIsolated { handler(windowNumber, location) }
            return event
        }
    }

    var removeMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }
}

enum PacePanelPlacement {
    static func frame(itemScreenFrame: NSRect, visibleFrame: NSRect, contentSize: NSSize) -> NSRect {
        let width = min(360, max(0, visibleFrame.width - 16))
        let top = min(itemScreenFrame.minY - 4, visibleFrame.maxY - 4)
        let height = min(contentSize.height, max(0, top - visibleFrame.minY - 8))
        let x = max(visibleFrame.minX + 8, min(itemScreenFrame.minX, visibleFrame.maxX - 8 - width))
        return NSRect(x: x, y: top - height, width: width, height: height)
    }
}

enum PacePanelCommand: Equatable {
    case close, refresh, settings, quit, selectTab(Int), previousTab, nextTab
}

enum PacePanelKeyMap {
    static func command(for event: NSEvent, shortcuts: [String: String]) -> PacePanelCommand? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if event.keyCode == 53, flags.isEmpty { return .close }
        let key: String = switch event.keyCode {
        case 123: "left"
        case 124: "right"
        default: event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
        if flags == .command {
            switch key {
            case "r": return .refresh
            case ",": return .settings
            case "q": return .quit
            default: break
            }
        }
        let modifierNames: [(NSEvent.ModifierFlags, String)] = [
            (.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "cmd"),
        ]
        let modifiers = modifierNames.compactMap { flags.contains($0.0) ? $0.1 : nil }
        switch ProviderSwitcherShortcuts.action(key: key, modifiers: modifiers, mapping: shortcuts) {
        case "previous": return .previousTab
        case "next": return .nextTab
        case let action?:
            guard let number = Int(action.dropFirst("select".count)) else { return nil }
            return .selectTab(number - 1)
        case nil: return nil
        }
    }
}

private final class PaceKeyPanel: NSPanel {
    var onClose: (@MainActor () -> Void)?
    var onKey: (@MainActor (NSEvent) -> Bool)?
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func cancelOperation(_ sender: Any?) { self.onClose?() }
    override func resignKey() {
        super.resignKey()
        self.onClose?()
    }

    override func keyDown(with event: NSEvent) {
        if self.onKey?(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        self.onKey?(event) == true || super.performKeyEquivalent(with: event)
    }
}
