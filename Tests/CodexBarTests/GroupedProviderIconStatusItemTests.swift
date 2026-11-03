import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct GroupedProviderIconStatusItemTests {
    private final class TooltipProbeOwner: NSObject {
        var requests = 0

        @objc func view(
            _: NSView,
            stringForToolTip _: NSView.ToolTipTag,
            point _: NSPoint,
            userData _: UnsafeMutableRawPointer?) -> String
        {
            self.requests += 1
            return "Pace tooltip owner"
        }
    }

    @Test func `tooltip owner registers on a native status button`() async throws {
        let item = testStatusBar().statusItem(withLength: 80)
        defer { testStatusBar().removeStatusItem(item) }
        let button = try #require(item.button)
        let owner = TooltipProbeOwner()
        let tag = button.addToolTip(button.bounds, owner: owner, userData: nil)
        defer { button.removeToolTip(tag) }
        #expect(owner.view(button, stringForToolTip: tag, point: .zero, userData: nil) == "Pace tooltip owner")
        owner.requests = 0
        let window = try #require(button.window)
        window.acceptsMouseMovedEvents = true
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: center,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0))
        NSApplication.shared.sendEvent(event)
        try await Task.sleep(for: .seconds(2))
        print("PACE_TOOLTIP_PROBE syntheticHoverRequests=\(owner.requests) frame=\(window.frame)")
        #expect(button.responds(to: #selector(NSView.addToolTip(_:owner:userData:))))
    }

    @MainActor
    private final class NativeProofState {
        var previous = ""
        var previousFrame = NSRect.zero
        var completed = false
        var finished = false
        var announced = false
        var failure: (any Error)?
    }

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
        #expect(try controller.statusItem.length == ceil(#require(button.image).size.width) + 5)
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

    @Test func `S5 all providers keep colored pills including cold loading outlines`() throws {
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
            #expect(!loading.isTemplate)
        }
    }

    @Test func `S6 warnings mark the outline without replacing provider fill colors`() throws {
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
            GroupedProviderIconComposer.lab(warningFill),
            GroupedProviderIconComposer.lab(NSColor(srgbRed: 0.6, green: 0.2509090909, blue: 0.12, alpha: 1))) < 1)
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
        store._setSnapshotForTesting(UsageSnapshot(
            primary: RateWindow(
                usedPercent: 85,
                windowMinutes: nil,
                resetsAt: Date().addingTimeInterval(7 * 86400),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date()), provider: .grok)
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

    @Test func `cost sweep fixes status width and every pill anchor with exact tooltips`() throws {
        let image = try #require(GroupedProviderIconComposer.compose(
            tiles: [NSColor.red, .green, .blue].map {
                GroupedProviderIconComposer.pill(primary: 50, secondary: 75, color: $0, stale: false)
            }, backingScale: 2))
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        button.isBordered = false
        button.imageScaling = .scaleNone
        let cell = try #require(button.cell)
        let reserved = GroupedDailyCost.reservedDisplayTexts(preferredCurrency: "USD")
        var cents = Set(stride(from: 0, through: 99999, by: 7))
        for dollar in 0...999 {
            for offset in -1...1 where (0...99999).contains(dollar * 100 + offset) {
                cents.insert(dollar * 100 + offset)
            }
        }
        cents.formUnion([9998, 9999, 10000, 10001, 99999])
        cents.formUnion([999_899, 999_900, 999_999, 1_000_000, 1_000_001, 1_099_999, 1_234_567, 99_999_999])
        for highContrast in [false, true] {
            var expectedWidth: CGFloat?
            var expectedPillPositions: [CGFloat]?
            for value in cents.sorted() {
                let summary = GroupedDailyCost.summary(inputs: [
                    .init(name: "Codex", value: .exact(Double(value) / 100)),
                ])
                let width = StatusItemController.applyGroupedButtonContent(
                    image: image,
                    costText: summary.displayText,
                    reservedCostTexts: reserved,
                    overBudget: value > 10000,
                    highContrast: highContrast,
                    for: button)
                button.setFrameSize(NSSize(width: width, height: 22))
                let origin = highContrast
                    ? cell.titleRect(forBounds: button.bounds).minX
                    : cell.imageRect(forBounds: button.bounds).minX
                let positions = [origin, origin + 25.5, origin + 51]
                if let expectedWidth, let expectedPillPositions {
                    #expect(width == expectedWidth)
                    #expect(positions == expectedPillPositions)
                } else {
                    expectedWidth = width
                    expectedPillPositions = positions
                }
                let exact = UsageFormatter.usdString(Double(value) / 100)
                #expect(summary.lines.first?.contains(exact) == true)
                #expect(summary.totalUSD == Double(value) / 100)
                if value < 10000 { #expect(summary.displayText == exact) }
                if value >= 10000 { #expect(summary.displayText?.contains(".") == false) }
            }
        }
    }

    @Test func `whole dollar tooltip updates do not redraw unchanged pills`() throws {
        let (settings, _, controller) = self.harness()
        let old = GrokDailyCostCache.shared.today
        defer { controller.releaseStatusItemsForTesting(); GrokDailyCostCache.shared.today = old }
        settings.costUsageEnabled = true
        GrokDailyCostCache.shared.today = GrokDayCost(usd: 123.01)
        let button = try #require(controller.statusItem.button)
        controller.applyIcon(phase: nil)
        let image = button.image
        let width = controller.statusItem.length
        #expect(button.title.contains("$123"))
        #expect(button.toolTip?.contains("$123.01") == true)
        GrokDailyCostCache.shared.today = GrokDayCost(usd: 123.02)
        #expect(controller.applyIcon(phase: nil))
        #expect(button.image === image)
        #expect(controller.statusItem.length == width)
        #expect(button.toolTip?.contains("$123.02") == true)
    }

    @Test func `Claude brand survives stale refreshing highlight and inactive contrast composition`() throws {
        let (settings, store, controller) = self.harness()
        defer { controller.releaseStatusItemsForTesting() }
        let button = try #require(controller.statusItem.button)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            button.appearance = try #require(NSAppearance(named: appearanceName))
            for state in ["ready", "stale", "refreshing", "highlighted", "inactive-contrast"] {
                store._setErrorForTesting(state == "stale" ? "Credentials changed" : nil, provider: .claude)
                store.refreshingProviders = state == "refreshing" ? [.claude] : []
                button.highlight(state == "highlighted")
                settings.menuBarIconStyle = .iconAndPercent
                settings.menuBarHighContrastOnInactiveDisplays = state == "inactive-contrast"
                controller.applyIcon(phase: nil)
                let attachment = button.attributedTitle.length > 0
                    ? button.attributedTitle
                    .attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment : nil
                let image = try #require(button.image ?? attachment?.image)
                #expect(!image.isTemplate, "\(state) \(appearanceName.rawValue)")
                let bitmap = try #require(GroupedProviderIconComposer.rasterize(image))
                let week = try #require(bitmap.colorAt(x: 63, y: 20)?.usingColorSpace(.sRGB))
                let session = try #require(bitmap.colorAt(x: 63, y: 16)?.usingColorSpace(.sRGB))
                let track = try #require(bitmap.colorAt(x: 95, y: 20))
                #expect(week.alphaComponent == 1)
                #expect(session.alphaComponent == 1)
                #expect(week.saturationComponent >= 0.5)
                #expect(week.hueComponent < 0.1)
                #expect(GroupedProviderIconComposer.deltaE(
                    GroupedProviderIconComposer.lab(week), GroupedProviderIconComposer.lab(session)) >= 15)
                let weekLab = GroupedProviderIconComposer.lab(week)
                let sessionLab = GroupedProviderIconComposer.lab(session)
                let trackLab = GroupedProviderIconComposer.lab(track)
                #expect(abs(session.redComponent - 204 / 255) < 1.0 / 255)
                #expect(abs(session.greenComponent - 124 / 255) < 1.0 / 255)
                #expect(abs(session.blueComponent - 94 / 255) < 1.0 / 255)
                #expect(sessionLab.l - weekLab.l >= 20)
                #expect(weekLab.l <= 85 && sessionLab.l <= 85)
                #expect(trackLab.l <= 30)
                #expect(GroupedProviderIconComposer.deltaE(weekLab, trackLab) >= 15)
                #expect(GroupedProviderIconComposer.deltaE(sessionLab, trackLab) >= 15)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_GROUPED_COLOR_PROOF_DIR"] != nil))
    func `native grouped color proof through the real status bar`() throws {
        let environment = ProcessInfo.processInfo.environment
        try #require(SettingsStore.isRunningTests && environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1")
        let directory = try URL(fileURLWithPath: #require(environment["CODEXBAR_GROUPED_COLOR_PROOF_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        let oldPolicy = app.activationPolicy()
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let (settings, store, controller) = self.harness()
        let label = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer {
            controller.releaseStatusItemsForTesting()
            NSStatusBar.system.removeStatusItem(label)
            _ = app.setActivationPolicy(oldPolicy)
        }
        let button = try #require(controller.statusItem.button)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 5, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 38, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        let deadline = Date().addingTimeInterval(300)
        let proof = NativeProofState()
        let tick: @MainActor @Sendable () -> Void = {
            guard !proof.finished else { return }
            defer {
                if proof.finished {
                    app.stop(nil)
                    if let wake = NSEvent.otherEvent(
                        with: .applicationDefined,
                        location: .zero,
                        modifierFlags: [],
                        timestamp: 0,
                        windowNumber: 0,
                        context: nil,
                        subtype: 0,
                        data1: 0,
                        data2: 0)
                    {
                        app.postEvent(wake, atStart: false)
                    }
                }
            }
            do {
                let state = (try? String(contentsOf: directory.appendingPathComponent("state.txt"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "ready"
                if state == "done" {
                    proof.completed = true
                    proof.finished = true
                    return
                }
                guard Date() < deadline else { proof.finished = true; return }
                if state != proof.previous || button.window?.frame != proof.previousFrame {
                    proof.previous = state
                    controller.statusItem.isVisible = true
                    label.isVisible = true
                    proof.previousFrame = button.window?.frame ?? .zero
                    store._setSnapshotForTesting(state == "cold" ? nil : snapshot, provider: .claude)
                    store._setErrorForTesting(state == "stale" ? "Synthetic stale credentials" : nil, provider: .claude)
                    store.refreshingProviders = state == "refreshing" || state == "cold" ? [.claude] : []
                    button.highlight(state == "highlighted")
                    settings.menuBarIconStyle = .iconAndPercent
                    settings.menuBarHighContrastOnInactiveDisplays = state == "inactive-contrast"
                    controller.applyIcon(phase: nil)
                    label.button?.title = "Synthetic color proof: \(state)"
                    button.window?.displayIfNeeded()
                    let receipt: [String: Any] = [
                        "pid": ProcessInfo.processInfo.processIdentifier,
                        "state": state, "window": button.window?.windowNumber ?? -1,
                        "frame": NSStringFromRect(button.window?.frame ?? .zero),
                        "appRunning": app.isRunning,
                        "appActive": app.isActive, "policy": app.activationPolicy().rawValue,
                        "stale": store.isStale(provider: .claude),
                        "refreshing": store.refreshingProviders.contains(.claude),
                    ]
                    try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                        .write(to: directory.appendingPathComponent("receipt.json"), options: .atomic)
                    if !proof.announced, (button.window?.frame.height ?? 0) > 0 {
                        proof.announced = true
                        print("GROUPED_COLOR_PROOF_READY")
                    }
                }
            } catch {
                proof.failure = error
                proof.finished = true
            }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        defer { timer.invalidate() }
        app.run()
        if let failure = proof.failure { throw failure }
        #expect(proof.completed, "Native color proof timed out before receiving done.")
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

    @Test func `grouped leading inset is native minimum with only trailing cost padding`() throws {
        let image = GroupedProviderIconComposer.pill(
            primary: 50, secondary: nil, color: .systemBlue, stale: false)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        button.isBordered = false
        button.imageScaling = .scaleNone
        let cell = try #require(button.cell)
        for highContrast in [false, true] {
            for costText in [nil, "$0.00", "$70.61", "$123", "$999k"] {
                let reserved = GroupedDailyCost.reservedDisplayTexts(preferredCurrency: "USD")
                let width = StatusItemController.applyGroupedButtonContent(
                    image: image,
                    costText: costText,
                    reservedCostTexts: reserved,
                    highContrast: highContrast,
                    for: button)
                button.setFrameSize(NSSize(width: width, height: 22))
                let leading = highContrast
                    ? cell.titleRect(forBounds: button.bounds).minX
                    : cell.imageRect(forBounds: button.bounds).minX
                #expect(leading == 0)
                let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                let reservedWidth = reserved.map {
                    NSAttributedString(string: " \($0)", attributes: [.font: font]).size().width
                }.max() ?? 0
                #expect(width == ceil(24 + reservedWidth) + 5)
            }
            let width = StatusItemController.applyGroupedButtonContent(
                image: image, costText: nil, reservedCostTexts: [], highContrast: highContrast, for: button)
            button.setFrameSize(NSSize(width: width, height: 22))
            let leading = highContrast
                ? cell.titleRect(forBounds: button.bounds).minX
                : cell.imageRect(forBounds: button.bounds).minX
            #expect(leading == 0)
            #expect(width == 29)
        }
    }

    @Test func `dimmed slot preserves normal or budget ink and exact fixed anchors`() throws {
        let image = GroupedProviderIconComposer.pill(
            primary: 50, secondary: nil, color: .systemBlue, stale: false)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        button.isBordered = false
        for overBudget in [false, true] {
            let width = StatusItemController.applyGroupedButtonContent(
                image: image,
                costText: "$70.61",
                reservedCostTexts: ["$99.99", "$9,999"],
                overBudget: overBudget,
                highContrast: false,
                for: button)
            button.setFrameSize(NSSize(width: width, height: 22))
            let origin = button.cell?.imageRect(forBounds: button.bounds).origin
            let dimmedWidth = StatusItemController.applyGroupedButtonContent(
                image: image,
                costText: "$70.61",
                reservedCostTexts: ["$99.99", "$9,999"],
                overBudget: overBudget,
                dimmed: true,
                highContrast: false,
                for: button)
            let ink = try #require(button.attributedTitle.attribute(
                .foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            #expect(ink.alphaComponent == 0.55)
            #expect(ink == (overBudget ? NSColor.systemOrange : NSColor.labelColor).withAlphaComponent(0.55))
            #expect(width == dimmedWidth)
            #expect(button.cell?.imageRect(forBounds: button.bounds).origin == origin)
        }
    }

    @Test func `used fill repaints and grouped exit cancels the pixel timer`() throws {
        let (settings, store, controller) = self.harness()
        defer { controller.releaseStatusItemsForTesting() }
        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(228 * 60),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .claude)
        settings.usageBarsShowUsed = false
        controller.applyIcon(phase: nil)
        let button = try #require(controller.statusItem.button)
        let remaining = try self.pixels(#require(button.image))
        let timer = try #require(GroupedTooltipOwner.attached(to: button)?.tickTimer)
        let signature = controller.storeIconObservationSignature()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 301,
                    resetsAt: now.addingTimeInterval(228 * 60),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .claude)
        #expect(controller.storeIconObservationSignature() != signature)
        settings.usageBarsShowUsed = true
        controller.applyIcon(phase: nil)
        #expect(try self.pixels(#require(button.image)) != remaining)
        let activeTimer = try #require(GroupedTooltipOwner.attached(to: button)?.tickTimer)
        settings.mergeIcons = false
        _ = controller.storeIconObservationSignature()
        #expect(!activeTimer.isValid)
        #expect(!timer.isValid)
        #expect(button.alignment == .center)
        #expect(GroupedTooltipOwner.attached(to: button) == nil)
    }
}
