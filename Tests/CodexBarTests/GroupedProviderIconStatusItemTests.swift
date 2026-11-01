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

    @Test func `S5 all providers use equal pills with colored measured quotas and native loading outlines`() throws {
        let (_, store, controller) = self.harness()
        defer { controller.releaseStatusItemsForTesting() }
        let button = try #require(controller.statusItem.button)
        for provider in [UsageProvider.codex, .claude, .grok] {
            let measured = controller.groupedTileImage(provider: provider, button: button)
            #expect(measured.size == NSSize(width: 24, height: 18))
            #expect(!measured.isTemplate)
            store._setSnapshotForTesting(nil, provider: provider)
            let loading = controller.groupedTileImage(provider: provider, button: button)
            #expect(loading.size == measured.size)
            #expect(loading.isTemplate)
        }
    }

    @Test func `S6 brand colors include Claude and worst quota warning tints only its pill`() throws {
        let (settings, store, controller) = self.harness()
        defer { controller.releaseStatusItemsForTesting() }
        let button = try #require(controller.statusItem.button)
        controller.applyIcon(phase: nil)
        #expect(button.image?.isTemplate == false)
        let codex = try self.pixels(controller.groupedTileImage(provider: .codex, button: button))
        let claude = try self.pixels(controller.groupedTileImage(provider: .claude, button: button))
        settings.setQuotaWarningWindowEnabled(.session, enabled: true)
        settings.setQuotaWarningThresholds(.session, thresholds: [50, 20])
        settings.quotaWarningNotificationsEnabled = false
        store._setSnapshotForTesting(self.snapshot(used: 85), provider: .claude)
        #expect(controller.groupedWarning(provider: .claude) == .red)
        #expect(controller.groupedWarning(provider: .codex) == .none)
        controller.applyIcon(phase: nil)
        #expect(button.image?.isTemplate == false)
        #expect(try self.pixels(controller.groupedTileImage(provider: .codex, button: button)) == codex)
        #expect(try self.pixels(controller.groupedTileImage(provider: .claude, button: button)) != claude)
        let warned = try #require(GroupedProviderIconComposer.rasterize(
            controller.groupedTileImage(provider: .claude, button: button)))
        let warningFill = try #require(warned.colorAt(x: 20, y: 20))
        #expect(GroupedProviderIconComposer.deltaE(
            GroupedProviderIconComposer.lab(warningFill), GroupedProviderIconComposer.lab(.systemRed)) < 1)
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)
        settings.setQuotaWarningThresholds(.weekly, thresholds: [50, 20])
        store._setSnapshotForTesting(UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 90, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date()), provider: .claude)
        #expect(controller.groupedWarning(provider: .claude) == .red)
        store._setSnapshotForTesting(self.snapshot(used: 85, synthetic: true), provider: .claude)
        #expect(controller.groupedWarning(provider: .claude) == .none)
        store._setSnapshotForTesting(self.snapshot(used: 85, minutes: 10080), provider: .claude)
        #expect(controller.groupedWarning(provider: .claude) == .none)
    }

    @Test func `warnings follow selected extra long lane and lone weekly quota`() {
        let (settings, store, controller) = self.harness()
        defer { controller.releaseStatusItemsForTesting() }
        settings.setQuotaWarningWindowEnabled(.session, enabled: false)
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)
        settings.setQuotaWarningThresholds(.weekly, thresholds: [50, 20])
        func window(_ used: Double, _ minutes: Int) -> RateWindow {
            RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: nil, resetDescription: nil)
        }
        store._setSnapshotForTesting(UsageSnapshot(
            primary: window(10, 300),
            secondary: window(10, 10080),
            extraRateWindows: [
                NamedRateWindow(id: "long", title: "Monthly", window: window(95, 43200)),
            ],
            updatedAt: Date()), provider: .claude)
        #expect(controller.groupedWarning(provider: .claude) == .red)
        store._setSnapshotForTesting(UsageSnapshot(
            primary: window(85, 10080), secondary: nil, updatedAt: Date()), provider: .grok)
        #expect(controller.groupedWarning(provider: .grok) == .red)
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: false)
        #expect(controller.groupedWarning(provider: .grok) == .none)
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
        #expect(button.toolTip?.contains("Claude") == true)
        #expect(button.toolTip?.contains("80%") == true)
        #expect(button.toolTip?.contains("75%") == true)
    }

    @Test func `cache scan distinguishes missing sources unchanged inputs and read errors`() throws {
        let now = Date(timeIntervalSince1970: 1_793_568_000)
        let calendar = Calendar(identifier: .gregorian)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grouped-grok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let mirrors = CostUsageDailyReport(data: [], summary: nil)
        let first = try GrokDailyCostCache.scan(
            home: home, now: now, calendar: calendar, previousSignature: nil, mirrors: mirrors)
        #expect(first.cost?.usd == 0)
        let unchanged = try GrokDailyCostCache.scan(
            home: home, now: now, calendar: calendar, previousSignature: first.signature, mirrors: mirrors)
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
            home: home, now: now, calendar: calendar, previousSignature: first.signature, mirrors: mirrors)
        #expect(try abs(#require(changed.cost?.usd) - 0.57) < 0.00000001)
        var previous = changed.signature
        for fraction in [0.25, 0.5] {
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(fraction)],
                ofItemAtPath: logs.appendingPathComponent("unified.jsonl").path)
            let modified = try GrokDailyCostCache.scan(
                home: home, now: now, calendar: calendar, previousSignature: previous, mirrors: mirrors)
            #expect(modified.cost != nil)
            previous = modified.signature
        }
        try FileManager.default.removeItem(at: logs.appendingPathComponent("unified.jsonl"))
        try FileManager.default.createDirectory(
            at: logs.appendingPathComponent("unified.jsonl"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try GrokDailyCostCache.scan(
                home: home, now: now, calendar: calendar, previousSignature: nil, mirrors: mirrors)
        }
    }
}
