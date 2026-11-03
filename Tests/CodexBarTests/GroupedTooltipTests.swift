import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct GroupedTooltipTests {
    private let now = Date(timeIntervalSince1970: 1_793_620_800)

    private func window(_ used: Double, _ minutes: Int?, _ remaining: Int) -> RateWindow {
        RateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: self.now.addingTimeInterval(Double(remaining) * 60),
            resetDescription: nil)
    }

    private var providers: [GroupedTooltipOwner.ProviderWindows] {
        [
            .init(provider: .codex, snapshot: UsageSnapshot(
                primary: nil, secondary: self.window(54, 10080, 2888), updatedAt: self.now)),
            .init(provider: .claude, snapshot: UsageSnapshot(
                primary: self.window(6, 300, 228),
                secondary: self.window(42, 10080, 2640),
                extraRateWindows: [NamedRateWindow(
                    id: "claude-weekly-scoped-fable", title: "Fable", window: self.window(4, 10080, 2640))],
                updatedAt: self.now)),
            .init(provider: .grok, snapshot: UsageSnapshot(
                primary: self.window(5, nil, 7020), secondary: nil, updatedAt: self.now)),
        ]
    }

    private func tooltip(showUsed: Bool = false, now: Date? = nil) -> String {
        GroupedTooltipOwner.tooltip(
            providers: self.providers,
            showUsed: showUsed,
            costs: GroupedDailyCost.summary(inputs: [
                .init(name: "Codex", value: .exact(37.54)),
                .init(name: "Claude", value: .exact(25.11)),
                .init(name: "Grok", value: .exact(7.96)),
            ]), now: now ?? self.now)
    }

    @Test func `F1 tooltip lists drawn windows pace countdowns and one exact today line`() {
        #expect(self.tooltip() == """
        Codex Weekly 46% left · ahead +17% · resets 2d 8m
        Claude Session 94% left · ahead +18% · resets 3h 48m
        Claude Weekly 58% left · ahead +32% · resets 1d 20h
        Grok Weekly 95% left · ahead +25% · resets 4d 21h
        Today: $70.61 · Codex $37.54 · Claude $25.11 · Grok $7.96
        """)
        #expect(!self.tooltip().contains("Fable"))
        #expect(self.tooltip(showUsed: true).hasPrefix("Codex Weekly 54% used · ahead +17% · resets 2d 8m"))
        #expect(self.tooltip(now: self.now.addingTimeInterval(60)).contains("resets 2d 7m"))
    }

    @Test func `missing pace keeps usage and budget unpriced and overflow lines`() {
        let text = GroupedTooltipOwner.tooltip(
            providers: [.init(provider: .codex, snapshot: nil), .init(provider: .grok, snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 5, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: self.now))],
            showUsed: false,
            costs: GroupedDailyCost.summary(inputs: [
                .init(name: "Grok", value: .estimate(0, unpricedModels: ["unknown-model"])),
            ]),
            additionalLines: [L("grouped_icons_tooltip_budget", "$100.00"), L("grouped_icons_tooltip_more", 2)],
            now: self.now)
        #expect(text.contains("Codex: Unknown"))
        #expect(text.contains("95% left"))
        #expect(!text.contains("ahead"))
        #expect(!text.contains("resets"))
        #expect(text.contains("Grok: unpriced"))
        #expect(text.contains("Grok: no price for unknown-model"))
        #expect(text.hasSuffix("Budget $100.00\n+2 more"))
        #expect(!text.contains("$0"))
    }

    @Test(arguments: [
        (GroupedPillState(), "Codex: no usage data; 0 measured windows"),
        (
            .init(hasData: true, refreshing: true),
            "Codex: refreshing; capture time unavailable"),
        (
            .init(
                hasData: true,
                warning: .init(remainingPercent: 37, threshold: 50, windowLabel: "Weekly", cause: .behind(9))),
            "Codex: Weekly has 37% left, behind pace by 9%; warning level 50%"),
        (
            .init(
                hasData: true,
                warning: .init(remainingPercent: 15, threshold: 20, windowLabel: "Weekly", cause: .low)),
            "Codex: Weekly has 15% left, at or below your 20% warning level"),
        (
            .init(
                hasData: true,
                warning: .init(remainingPercent: 15, threshold: 20, windowLabel: "Weekly", cause: .low),
                flash: true),
            "Codex: Weekly has 15% left, at or below your 20% warning level"),
        (.init(hasData: true, stale: true), "Codex: couldn't refresh; capture time unavailable"),
        (
            .init(
                hasData: true,
                stale: true,
                updatedAt: Date(timeIntervalSince1970: 1_793_610_000)),
            "Codex: couldn't refresh; showing data from 3h ago"),
        (.init(failure: "Sign in required"), "Codex: Sign in required; no usage data shown"),
        (.init(failure: "Keychain access denied"), "Codex: Keychain access denied; no usage data shown"),
        (.init(failure: "Rate limited; retry later"), "Codex: Rate limited; retry later; no usage data shown"),
        (
            .init(hasData: true, providerStatus: .major),
            "Codex: provider reports a service problem; capture time unavailable"),
    ])
    func `every pill state outline produces a strip row and matching tooltip and provider text`(
        state: GroupedPillState, expected: String) throws
    {
        let snapshot = state.hasData ? self.providers[0].snapshot : nil
        let tooltip = GroupedTooltipOwner.tooltip(
            providers: [.init(provider: .codex, snapshot: snapshot, state: state)],
            showUsed: false,
            costs: GroupedDailyCost.summary(inputs: []),
            now: self.now)
        let input = PacePanelInput(
            providers: [.codex],
            snapshots: snapshot.map { [.codex: $0] } ?? [:],
            pillStates: [.codex: state],
            now: self.now)
        #expect(tooltip.components(separatedBy: "\n").contains(expected))
        #expect(try #require(PacePanelModel.make(input).providers.first).stateExplanation == expected)
        let warning = try #require(PacePanelModel.make(input).warnings.first)
        #expect(warning.provider == .codex)
        #expect(warning.stateReason?.text == expected)
        #expect(warning.stateReason == state.reason(provider: .codex, now: self.now))
    }

    @Test func `warning explanation takes precedence over stale and refresh just like the outline`() {
        let state = GroupedPillState(
            hasData: true, stale: true, refreshing: true,
            warning: .init(remainingPercent: 37, threshold: 50, windowLabel: "Weekly", cause: .behind(9)),
            flash: true, updatedAt: self.now)
        #expect(state.explanation(provider: .codex, now: self.now)
            == "Codex: Weekly has 37% left, behind pace by 9%; warning level 50%")
        #expect(GroupedPillState(hasData: true).explanation(provider: .codex, now: self.now) == nil)
        let normal = PacePanelInput(
            providers: [.codex], pillStates: [.codex: .init(hasData: true)], now: self.now)
        #expect(PacePanelModel.make(normal).warnings.isEmpty)
    }

    @Test func `fallback tooltip reads fresh values only while hovered and detaches all resources`() throws {
        let item = testStatusBar().statusItem(withLength: 100)
        defer { testStatusBar().removeStatusItem(item) }
        let button = try #require(item.button)
        let originalAreas = button.trackingAreas.count
        var now = self.now
        let owner = GroupedTooltipOwner.attach(to: button) { self.tooltip(now: now) }
        defer { GroupedTooltipOwner.detach(from: button) }
        owner.refresh()
        #expect(button.toolTip?.contains("resets 2d 8m") == true)
        #expect(owner.hoverTimer == nil)
        let event = NSEvent()
        now = now.addingTimeInterval(60)
        owner.mouseEntered(with: event)
        #expect(button.toolTip?.contains("resets 2d 7m") == true)
        let hoverTimer = try #require(owner.hoverTimer)
        #expect(hoverTimer.timeInterval <= 60)
        now = now.addingTimeInterval(60)
        hoverTimer.fire()
        #expect(button.toolTip?.contains("resets 2d 6m") == true)
        owner.mouseExited(with: event)
        #expect(!hoverTimer.isValid)
        #expect(owner.hoverTimer == nil)
        owner.mouseEntered(with: event)
        let activeHoverTimer = try #require(owner.hoverTimer)
        owner.scheduleTick(at: self.now.addingTimeInterval(180), now: self.now) {}
        let tickTimer = try #require(owner.tickTimer)
        #expect(tickTimer.timeInterval == 0)
        #expect(abs(tickTimer.tolerance - 18) < 0.001)
        GroupedTooltipOwner.detach(from: button)
        #expect(!activeHoverTimer.isValid && !tickTimer.isValid)
        #expect(button.toolTip == nil)
        #expect(GroupedTooltipOwner.attached(to: button) == nil)
        #expect(button.trackingAreas.count == originalAreas)
    }

    @Test func `pixel timer coalesces cancels absent ticks and calls the update path`() throws {
        let owner = GroupedTooltipOwner()
        var updates = 0
        let fire = Date().addingTimeInterval(180)
        owner.scheduleTick(at: fire, now: Date()) { updates += 1 }
        let timer = try #require(owner.tickTimer)
        owner.scheduleTick(at: fire, now: Date()) { updates += 1 }
        #expect(owner.tickTimer === timer)
        timer.fire()
        #expect(updates == 1)
        #expect(owner.tickTimer == nil)
        owner.scheduleTick(at: fire, now: Date()) { updates += 1 }
        let replacement = try #require(owner.tickTimer)
        owner.scheduleTick(at: nil, now: Date()) { updates += 1 }
        #expect(!replacement.isValid)
        #expect(owner.tickTimer == nil)
        #expect(updates == 1)
    }
}
