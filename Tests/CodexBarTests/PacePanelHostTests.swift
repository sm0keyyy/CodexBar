import AppKit
import CodexBarCore
import Observation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct PacePanelHostTests {
    private let itemFrame = NSRect(x: 1200, y: 878, width: 60, height: 22)
    private let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 875)

    @MainActor
    private final class EventSources {
        var global: (@MainActor () -> Void)?
        var local: (@MainActor (Int, NSPoint) -> Void)?
        var removed: [Int] = []
        let application = NotificationCenter()
        let workspace = NotificationCenter()

        var sources: PacePanelEventSources {
            PacePanelEventSources(
                applicationCenter: self.application,
                workspaceCenter: self.workspace,
                addGlobalMouseDown: { self.global = $0; return 1 },
                addLocalMouseDown: { self.local = $0; return 2 },
                removeMonitor: { if let token = $0 as? Int { self.removed.append(token) } })
        }
    }

    @MainActor
    @Observable
    final class ContentState {
        var text = "Fixture"
    }

    @Test func `T16 panel clamps right edge and keeps four point top gap`() {
        #expect(PacePanelPlacement.frame(
            itemScreenFrame: self.itemFrame,
            visibleFrame: self.visibleFrame,
            contentSize: NSSize(width: 360, height: 640)) == NSRect(x: 1072, y: 231, width: 360, height: 640))
        #expect(PacePanelPlacement.frame(
            itemScreenFrame: self.itemFrame,
            visibleFrame: self.visibleFrame,
            contentSize: NSSize(width: 360, height: 1000)) == NSRect(x: 1072, y: 8, width: 360, height: 863))
    }

    @Test func `placement supports negative screen coordinates and left inset`() {
        let frame = PacePanelPlacement.frame(
            itemScreenFrame: NSRect(x: -1919, y: 1058, width: 60, height: 22),
            visibleFrame: NSRect(x: -1920, y: 0, width: 1920, height: 1055),
            contentSize: NSSize(width: 360, height: 640))
        #expect(frame == NSRect(x: -1912, y: 411, width: 360, height: 640))
    }

    @Test func `T16b tall hosting content scrolls within the visible frame`() throws {
        _ = NSApplication.shared
        let events = EventSources()
        let host = PacePanelHost(sources: events.sources, content: { Text("Fixture").frame(height: 1000) }, onClose: {})
        host.show(itemScreenFrame: self.itemFrame, visibleFrame: self.visibleFrame)
        defer { host.close() }
        let panel = try #require(host.panel)
        let hosting = try #require(host.hostingView)
        #expect(panel.frame == NSRect(x: 1072, y: 8, width: 360, height: 863))
        #expect(hosting.frame.height == 1000)
        let scroll = try #require(hosting.enclosingScrollView)
        #expect(scroll.hasVerticalScroller)
        #expect(scroll.documentView === hosting)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.level == .popUpMenu)
        #expect(panel.collectionBehavior == [.transient, .fullScreenAuxiliary, .ignoresCycle])
        let glass = try #require(panel.contentView as? PaceGlassView)
        #expect(glass.material == .popover)
        #expect(glass.blendingMode == .behindWindow)
        #expect(glass.state == .active)
        #expect(glass.layer?.cornerRadius == 12)
        #expect(glass.layer?.borderWidth == 0.5)
    }

    @Test(arguments: ["close", "escape", "resign", "global", "local", "space", "screen", "sleep", "toggle"])
    func `T17 each dismissal removes sources and releases hosting content`(_ trigger: String) throws {
        _ = NSApplication.shared
        let events = EventSources()
        var closed = 0
        let host = PacePanelHost(sources: events.sources, content: { Text("Fixture") }, onClose: { closed += 1 })
        weak var hosting: NSHostingView<AnyView>?
        weak var panel: NSPanel?
        try autoreleasepool {
            host.show(itemScreenFrame: self.itemFrame, visibleFrame: self.visibleFrame)
            hosting = host.hostingView
            panel = host.panel
            #expect(host.isOpen)
            switch trigger {
            case "close": host.close()
            case "escape": host.panel?.cancelOperation(nil)
            case "resign": host.panel?.resignKey()
            case "global": events.global?()
            case "local": events.local?(0, NSPoint(x: 10, y: 10))
            case "space": events.workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            case "screen": events.application.post(
                    name: NSApplication.didChangeScreenParametersNotification,
                    object: nil)
            case "sleep": events.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
            case "toggle":
                let item = testStatusBar().statusItem(withLength: NSStatusItem.variableLength)
                defer { testStatusBar().removeStatusItem(item) }
                try host.toggle(anchor: #require(item.button))
            default: Issue.record("Unknown fixture")
            }
        }
        #expect(!host.isOpen)
        #expect(events.removed == [1, 2])
        let hostingReleased = hosting == nil
        let panelReleased = panel == nil
        #expect(hostingReleased)
        #expect(panelReleased)
        #expect(closed == 1)
        host.close()
        events.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(closed == 1)
    }

    @Test func `local monitor preserves panel and item clicks`() throws {
        _ = NSApplication.shared
        let events = EventSources()
        let host = PacePanelHost(sources: events.sources, content: { Text("Fixture") }, onClose: {})
        host.show(itemScreenFrame: self.itemFrame, visibleFrame: self.visibleFrame)
        defer { host.close() }
        events.local?(0, NSPoint(x: 1230, y: 888))
        #expect(host.isOpen)
        let panel = try #require(host.panel)
        events.local?(panel.windowNumber, NSPoint(x: 10, y: 10))
        #expect(host.isOpen)
    }

    @Test func `host deinitialization closes its panel and sources`() {
        _ = NSApplication.shared
        let events = EventSources()
        var host: PacePanelHost<Text>? = PacePanelHost(
            sources: events.sources, content: { Text("Fixture") }, onClose: {})
        weak var hosting: NSHostingView<AnyView>?
        autoreleasepool {
            host?.show(itemScreenFrame: self.itemFrame, visibleFrame: self.visibleFrame)
            hosting = host?.hostingView
            host = nil
        }
        let hostingReleased = hosting == nil
        #expect(hostingReleased)
        #expect(events.removed == [1, 2])
    }

    @Test func `T17b grouped refresh never creates a native merged menu and detach restores click`() throws {
        let settings = testSettingsStore(suiteName: "PacePanelHostTests")
        enableTestProviders([.codex, .claude], settings: settings)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.mergeIcons = true
        settings.menuBarGroupsProviderIcons = true
        settings.randomBlinkEnabled = false
        let fetcher = UsageFetcher(environment: [:])
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar(),
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false,
            observeProviderConfigNotifications: false)
        defer { controller.releaseStatusItemsForTesting() }
        let button = try #require(controller.statusItem.button)
        controller.detachPacePanel()
        let originalTarget = button.target
        let originalAction = button.action
        #expect(controller.attachPacePanelIfActive())
        for _ in 0..<3 {
            controller.handleObservedStoreMenuChange()
            controller.updateIcons()
            #expect(controller.mergedMenu == nil)
            #expect(controller.statusItem.menu == nil)
        }
        controller.detachPacePanel()
        #expect(button.target === originalTarget)
        #expect(button.action == originalAction)
        settings.menuBarGroupsProviderIcons = false
        controller.updateIcons()
        #expect(controller.mergedMenu != nil)
        #expect(controller.statusItem.menu === controller.mergedMenu)
    }

    @Test func `tab commands preserve merged selection and wrap around overview`() {
        let settings = testSettingsStore(suiteName: "PacePanelTabCommands")
        enableTestProviders([.codex, .claude], settings: settings)
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.menuBarGroupsProviderIcons = true
        let fetcher = UsageFetcher(environment: [:])
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar(),
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false,
            observeProviderConfigNotifications: false)
        defer { controller.releaseStatusItemsForTesting() }
        controller.performPacePanelCommand(.selectTab(0))
        #expect(settings.mergedMenuLastSelectedWasOverview)
        controller.performPacePanelCommand(.nextTab)
        #expect(settings.selectedMenuProvider == controller.groupedProviders?.first?.instanceID)
        #expect(!settings.mergedMenuLastSelectedWasOverview)
        controller.performPacePanelCommand(.previousTab)
        #expect(settings.mergedMenuLastSelectedWasOverview)
        controller.performPacePanelCommand(.previousTab)
        #expect(settings.selectedMenuProvider == controller.groupedProviders?.last?.instanceID)
    }

    @Test func `T18 keys route standard commands and configured provider shortcuts`() throws {
        let rows: [(String, UInt16, NSEvent.ModifierFlags, PacePanelCommand)] = [
            ("\u{1b}", 53, [], .close), ("r", 15, .command, .refresh),
            (",", 43, .command, .settings), ("q", 12, .command, .quit),
            ("1", 18, .command, .selectTab(0)), ("2", 19, .command, .selectTab(1)),
            ("", 123, [], .previousTab), ("", 124, [], .nextTab),
        ]
        for (characters, keyCode, flags, expected) in rows {
            #expect(try PacePanelKeyMap.command(
                for: self.keyEvent(characters, code: keyCode, flags: flags),
                shortcuts: ProviderSwitcherShortcuts.defaults) == expected)
        }
        let mapping = try ProviderSwitcherShortcuts.validated(["select1": "ctrl+alt+a", "next": "none"])
        #expect(try PacePanelKeyMap.command(
            for: self.keyEvent("a", code: 0, flags: [.control, .option]),
            shortcuts: mapping) == .selectTab(0))
        #expect(try PacePanelKeyMap.command(for: self.keyEvent("", code: 124, flags: []), shortcuts: mapping) == nil)
        #expect(try PacePanelKeyMap.command(
            for: self.keyEvent("r", code: 15, flags: [.command, .shift]),
            shortcuts: mapping) == nil)
        for code in [UInt16(48), 36, 49] {
            #expect(try PacePanelKeyMap.command(
                for: self.keyEvent("", code: code, flags: []),
                shortcuts: mapping) == nil)
        }
    }

    @Test func `countdown rebuilds keep one observation and closed panels do no work`() async {
        _ = NSApplication.shared
        let events = EventSources()
        let state = ContentState()
        var builds = 0
        let host = PacePanelHost(
            sources: events.sources,
            content: {
                builds += 1
                return Text(state.text)
            },
            onClose: {})
        host.show(itemScreenFrame: self.itemFrame, visibleFrame: self.visibleFrame)
        for _ in 0..<3 {
            host.refreshContent()
        }
        #expect(builds == 4)
        state.text = "Updated"
        for _ in 0..<30 {
            await Task.yield()
        }
        #expect(builds == 5)
        host.close()
        state.text = "Closed"
        for _ in 0..<30 {
            await Task.yield()
        }
        #expect(builds == 5)
    }

    private func keyEvent(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code))
    }
}
