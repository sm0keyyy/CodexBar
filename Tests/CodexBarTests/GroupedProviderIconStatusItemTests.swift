import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct GroupedProviderIconStatusItemTests {
    private func harness() -> (SettingsStore, UsageStore, StatusItemController) {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let settings = testSettingsStore(suiteName: "GroupedProviderIconStatusItemTests")
        enableTestProviders([.codex, .claude, .grok], settings: settings)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.mergeIcons = true
        settings.menuBarGroupsProviderIcons = true
        settings.menuBarShowsBrandIconWithPercent = false
        settings.menuBarColorByProvider = false
        settings.menuBarHighContrastOnInactiveDisplays = false
        settings.randomBlinkEnabled = false
        settings.setQuotaWarningWindowEnabled(.session, enabled: false)
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: false)
        settings.selectedMenuProvider = .codex
        settings.unifiedIconSource = .currentSelection
        settings.costUsageEnabled = false
        let fetcher = UsageFetcher(environment: [:])
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        for provider in [UsageProvider.codex, .claude, .grok] {
            store._setSnapshotForTesting(self.snapshot(used: 20), provider: provider)
        }
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return (settings, store, controller)
    }

    private func snapshot(used: Double, synthetic: Bool = false, minutes: Int = 300) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: used,
                windowMinutes: minutes,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: synthetic),
            secondary: RateWindow(
                usedPercent: 25,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            updatedAt: Date())
    }

    private func pixels(_ image: NSImage) throws -> Data {
        let bitmap = try #require(GroupedProviderIconComposer.rasterize(image))
        let bytes = try #require(bitmap.bitmapData)
        return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    @Test func `S1 S2 grouped hook widens one item and repaints non primary usage`() throws {
        let (_, store, controller) = self.harness()
        defer { controller.releaseStatusItemsForTesting() }
        controller.applyIcon(phase: nil)
        let button = try #require(controller.statusItem.button)
        #expect(try #require(button.image).size.width > 18)
        #expect(controller.statusItem.length == NSStatusItem.variableLength)
        #expect(controller.statusItems.isEmpty)
        let signature = controller.storeIconObservationSignature()
        let image = button.image
        store._setSnapshotForTesting(self.snapshot(used: 70), provider: .claude)
        #expect(controller.storeIconObservationSignature() != signature)
        controller.applyIcon(phase: nil)
        #expect(button.image !== image)
        #expect(controller.applyIcon(phase: nil))
    }

    @Test func `S3 S4 toggling restores upstream and merge off restores separate items`() async throws {
        let (settings, _, controller) = self.harness()
        defer { controller.releaseStatusItemsForTesting() }
        controller.applyIcon(phase: nil)
        let button = try #require(controller.statusItem.button)
        #expect(button.toolTip != nil)
        settings.menuBarGroupsProviderIcons = false
        for _ in 0..<30 where button.toolTip != nil {
            await Task.yield()
        }
        #expect(button.toolTip == nil)
        #expect(button.image?.size.width == 18)
        settings.menuBarGroupsProviderIcons = true
        settings.mergeIcons = false
        controller.handleProviderConfigChange(reason: "test")
        #expect(!controller.statusItem.isVisible)
        #expect(controller.statusItems.count == 3)
    }

    @Test func `S5 split critters match grouped tile mirror including loading and hidden critters`() throws {
        let (settings, store, controller) = self.harness()
        defer { controller.releaseStatusItemsForTesting() }
        settings.mergeIcons = false
        controller.handleProviderConfigChange(reason: "test")
        for hidden in [false, true] {
            settings.menuBarHidesCritters = hidden
            for provider in [UsageProvider.codex, .claude, .grok] {
                for phase: Double? in [nil, 0.4] {
                    store._setSnapshotForTesting(phase == nil ? self.snapshot(used: 20) : nil, provider: provider)
                    controller.applyIcon(for: provider, phase: phase)
                    let button = try #require(controller.statusItems[provider.instanceID]?.button)
                    let split = try #require(button.image)
                    let grouped = controller.groupedTileImage(provider: provider, phase: phase, button: button)
                    #expect(try self.pixels(split) == self.pixels(grouped))
                }
            }
        }
    }

    @Test func `S6 provider tint and stateless warnings affect only their own tile`() throws {
        let (settings, store, controller) = self.harness()
        defer { controller.releaseStatusItemsForTesting() }
        let button = try #require(controller.statusItem.button)
        controller.applyIcon(phase: nil)
        #expect(button.image?.isTemplate == true)
        settings.menuBarColorByProvider = true
        controller.applyIcon(phase: nil)
        #expect(button.image?.isTemplate == false)
        settings.menuBarColorByProvider = false
        settings.setQuotaWarningWindowEnabled(.session, enabled: true)
        settings.setQuotaWarningThresholds(.session, thresholds: [50, 20])
        settings.quotaWarningNotificationsEnabled = false
        store._setSnapshotForTesting(self.snapshot(used: 85), provider: .claude)
        #expect(controller.groupedWarning(provider: .claude) == .red)
        #expect(controller.groupedWarning(provider: .codex) == .none)
        controller.applyIcon(phase: nil)
        #expect(button.image?.isTemplate == false)
        store._setSnapshotForTesting(self.snapshot(used: 85, synthetic: true), provider: .claude)
        #expect(controller.groupedWarning(provider: .claude) == .none)
        store._setSnapshotForTesting(self.snapshot(used: 85, minutes: 10080), provider: .claude)
        #expect(controller.groupedWarning(provider: .claude) == .none)
    }

    @Test func `S7 S8 Grok cache moves title signature and strict budget tint`() throws {
        let (settings, _, controller) = self.harness()
        let old = GrokDailyCostCache.shared.today
        defer { controller.releaseStatusItemsForTesting(); GrokDailyCostCache.shared.today = old }
        settings.costUsageEnabled = true
        settings.menuBarGroupedDailyBudgetUSD = 10
        GrokDailyCostCache.shared.today = GrokDayCost(usd: 10)
        let button = try #require(controller.statusItem.button)
        controller.applyIcon(phase: nil)
        let signature = controller.storeIconObservationSignature()
        let title = button.title
        #expect(button.attributedTitle
            .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor != .systemOrange)
        GrokDailyCostCache.shared.today = GrokDayCost(usd: 10.01)
        #expect(controller.storeIconObservationSignature() != signature)
        controller.applyIcon(phase: nil)
        #expect(button.title != title)
        #expect(button.attributedTitle
            .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemOrange)
        GrokDailyCostCache.shared.today = GrokDayCost(usd: 1)
        controller.applyIcon(phase: nil)
        #expect(button.attributedTitle
            .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor != .systemOrange)
        settings.costUsageEnabled = false
        controller.applyIcon(phase: nil)
        #expect(button.title.isEmpty)
        #expect(button.toolTip?.isEmpty == true)
    }

    @Test func `cache scan distinguishes missing sources unchanged inputs and read errors`() throws {
        let now = Date(timeIntervalSince1970: 1_793_568_000)
        let calendar = Calendar(identifier: .gregorian)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grouped-grok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try GrokDailyCostCache.scan(home: home, now: now, calendar: calendar, previousSignature: nil)
        #expect(first.cost?.usd == 0)
        let unchanged = try GrokDailyCostCache.scan(
            home: home, now: now, calendar: calendar, previousSignature: first.signature)
        #expect(unchanged.cost == nil)
        let logs = home.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = """
        {"msg":"model changed","sid":"s1","ctx":{"model":"grok-4.6"}}
        {"msg":"shell.turn.inference_done","sid":"s1","ts":"2026-11-01T18:00:00Z",\
        "ctx":{"prompt_tokens":300000,"cached_prompt_tokens":250000,"completion_tokens":10000}}
        """
        try log.write(to: logs.appendingPathComponent("unified.jsonl"), atomically: true, encoding: .utf8)
        let changed = try GrokDailyCostCache.scan(
            home: home, now: now, calendar: calendar, previousSignature: first.signature)
        #expect(try abs(#require(changed.cost?.usd) - 0.57) < 0.00000001)
        var previous = changed.signature
        for fraction in [0.25, 0.5] {
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(fraction)],
                ofItemAtPath: logs.appendingPathComponent("unified.jsonl").path)
            let modified = try GrokDailyCostCache.scan(
                home: home, now: now, calendar: calendar, previousSignature: previous)
            #expect(modified.cost != nil)
            previous = modified.signature
        }
        try FileManager.default.removeItem(at: logs.appendingPathComponent("unified.jsonl"))
        try FileManager.default.createDirectory(
            at: logs.appendingPathComponent("unified.jsonl"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try GrokDailyCostCache.scan(home: home, now: now, calendar: calendar, previousSignature: nil)
        }
    }
}
