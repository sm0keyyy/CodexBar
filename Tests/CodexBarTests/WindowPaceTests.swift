import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct WindowPaceTests {
    private let now = Date(timeIntervalSince1970: 1_793_577_600)

    private func window(
        used: Double = 0,
        minutes: Int? = 300,
        remainingMinutes: Double = 150,
        synthetic: Bool = false) -> RateWindow
    {
        RateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: self.now.addingTimeInterval(remainingMinutes * 60),
            resetDescription: nil,
            isSyntheticPlaceholder: synthetic)
    }

    private var fixture: [(provider: UsageProvider, window: RateWindow, reserve: Double, text: String)] {
        [
            (.codex, self.window(used: 54, minutes: 10080, remainingMinutes: 2888), 17.35, "ahead +17%"),
            (.claude, self.window(used: 6, remainingMinutes: 228), 18, "ahead +18%"),
            (.claude, self.window(used: 42, minutes: 10080, remainingMinutes: 2640), 31.81, "ahead +32%"),
            (.claude, self.window(used: 4, minutes: 10080, remainingMinutes: 2640), 69.81, "ahead +70%"),
            (.grok, self.window(used: 5, minutes: nil, remainingMinutes: 7020), 25.36, "ahead +25%"),
        ]
    }

    @Test func `T1 mockup windows expose reserve text and both tick modes`() throws {
        for row in self.fixture {
            let pace = try #require(WindowPace.make(window: row.window, provider: row.provider, now: self.now))
            #expect(abs(pace.reservePercent - row.reserve) < 0.01)
            #expect(WindowPace.paceText(reservePercent: pace.reservePercent) == row.text)
        }
        let session = try #require(WindowPace.make(
            window: self.window(used: 6, remainingMinutes: 228), provider: .claude, now: self.now))
        #expect(abs(session.fractionElapsed - 0.24) < 0.000001)
        #expect(session.remainingPercent == 94)
        #expect(abs(session.tickPercent(showUsed: false) - 76) < 0.000001)
        #expect(abs(session.tickPercent(showUsed: true) - 24) < 0.000001)
    }

    @Test func `T1b an over pace window has a negative reserve`() throws {
        let pace = try #require(WindowPace.make(
            window: self.window(used: 80, minutes: 10080, remainingMinutes: 2888),
            provider: .codex,
            now: self.now))
        #expect(abs(pace.reservePercent - -8.65) < 0.01)
        #expect(WindowPace.paceText(reservePercent: pace.reservePercent) == "behind −9%")
    }

    @Test(arguments: [
        (0.4, "ahead +0%"), (-0.4, "ahead +0%"), (0, "ahead +0%"),
        (0.5, "ahead +1%"), (-0.5, "behind −1%"), (17.5, "ahead +18%"), (-8.5, "behind −9%"),
    ])
    func `T1c reserve rounds half away from zero`(reserve: Double, text: String) {
        #expect(WindowPace.paceText(reservePercent: reserve) == text)
    }

    @Test(arguments: [300, 1440, 1441, 10080, 43200])
    func `T2 class follows the resolved duration`(minutes: Int) throws {
        let pace = try #require(WindowPace.make(
            window: self.window(minutes: minutes, remainingMinutes: Double(minutes) / 2),
            provider: .codex,
            now: self.now))
        #expect(pace.durationMinutes == minutes)
        #expect(pace.windowClass == (minutes <= 1440 ? .session : .weekly))
    }

    @Test func `T2 Grok weekly duration fallback does not invent other durations`() throws {
        let weekly = self.window(minutes: nil, remainingMinutes: 7020)
        let pace = try #require(WindowPace.make(window: weekly, provider: .grok, now: self.now))
        #expect(pace.durationMinutes == 10080)
        #expect(pace.windowClass == .weekly)
        #expect(WindowPace.durationMinutes(window: weekly, provider: .claude, now: self.now) == nil)
        #expect(WindowPace.durationMinutes(
            window: self.window(minutes: nil, remainingMinutes: 30 * 1440),
            provider: .grok,
            now: self.now) == nil)
        #expect(WindowPace.durationMinutes(
            window: self.window(minutes: 10500, remainingMinutes: 7020),
            provider: .grok,
            now: self.now) == 10500)
    }

    @Test func `descriptor monthly resolution precedes window classification`() throws {
        let resetsAt = try #require(ISO8601DateFormatter().date(from: "2026-03-01T00:00:00Z"))
        let window = RateWindow(
            usedPercent: 20, windowMinutes: 43200, resetsAt: resetsAt, resetDescription: "MCP")
        #expect(WindowPace.durationMinutes(window: window, provider: .zai, now: self.now) == 40320)
        #expect(WindowPace.durationMinutes(window: window, provider: .codex, now: self.now) == 43200)
    }

    @Test func `T3 unavailable synthetic expired and future windows have no pace`() {
        let invalid = [
            RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            self.window(synthetic: true),
            self.window(remainingMinutes: 0),
            self.window(remainingMinutes: -1),
            self.window(remainingMinutes: 301),
            self.window(minutes: 0),
            self.window(minutes: -1),
            self.window(minutes: nil),
            self.window(used: .nan),
            self.window(used: .infinity),
        ]
        for window in invalid {
            #expect(WindowPace.make(window: window, provider: .claude, now: self.now) == nil)
        }
    }

    @Test func `window start is valid and remaining usage clamps to the display range`() throws {
        let start = try #require(WindowPace.make(
            window: self.window(remainingMinutes: 300), provider: .claude, now: self.now))
        #expect(start.fractionElapsed == 0)
        #expect(start.idealRemainingPercent == 100)
        for (used, remaining) in [(-10.0, 100.0), (110, 0)] {
            let pace = try #require(WindowPace.make(
                window: self.window(used: used), provider: .claude, now: self.now))
            #expect(pace.remainingPercent == remaining)
        }
    }

    @Test(arguments: [false, true])
    func `T4 first mockup tick move is the Claude session at 180 seconds`(showUsed: Bool) throws {
        let ticks = try self.fixture.map { row in
            try WindowPace.TickLane(
                pace: #require(WindowPace.make(window: row.window, provider: row.provider, now: self.now)),
                resetsAt: #require(row.window.resetsAt),
                showUsed: showUsed)
        }
        let next = try #require(WindowPace.nextTickPixelMove(ticks: ticks, backingScale: 2, now: self.now))
        #expect(abs(next.timeIntervalSince(self.now) - 180) < 1)
        let later = try #require(WindowPace.nextTickPixelMove(
            ticks: ticks, backingScale: 2, now: self.now.addingTimeInterval(60)))
        #expect(abs(later.timeIntervalSince(next)) < 0.000001)
    }

    @Test func `one scale tick uses floor columns instead of rounded centers`() throws {
        let window = self.window(remainingMinutes: 228)
        let pace = try #require(WindowPace.make(window: window, provider: .claude, now: self.now))
        let tick = try WindowPace.TickLane(pace: pace, resetsAt: #require(window.resetsAt), showUsed: false)
        let next = try #require(WindowPace.nextTickPixelMove(ticks: [tick], backingScale: 1, now: self.now))
        #expect(abs(next.timeIntervalSince(self.now) - 766.956522) < 0.001)
    }

    @Test(arguments: [false, true])
    func `clipped one scale columns wait until a visible pixel moves`(showUsed: Bool) throws {
        let window = self.window(minutes: 23, remainingMinutes: 23)
        let pace = try #require(WindowPace.make(window: window, provider: .claude, now: self.now))
        let tick = try WindowPace.TickLane(pace: pace, resetsAt: #require(window.resetsAt), showUsed: showUsed)
        let next = try #require(WindowPace.nextTickPixelMove(ticks: [tick], backingScale: 1, now: self.now))
        #expect(abs(next.timeIntervalSince(self.now) - 90) < 0.001)
    }

    @Test func `a leftward tick at a boundary schedules just after the boundary`() throws {
        let window = self.window(minutes: 23, remainingMinutes: 11.5)
        let pace = try #require(WindowPace.make(window: window, provider: .claude, now: self.now))
        let tick = try WindowPace.TickLane(pace: pace, resetsAt: #require(window.resetsAt), showUsed: false)
        let next = try #require(WindowPace.nextTickPixelMove(ticks: [tick], backingScale: 1, now: self.now))
        #expect(next > self.now)
        #expect(next.timeIntervalSince(self.now) < 0.001)
        let subsequent = try #require(WindowPace.nextTickPixelMove(ticks: [tick], backingScale: 1, now: next))
        #expect(abs(subsequent.timeIntervalSince(self.now) - 60) < 0.001)
    }

    @Test func `no tick or no future visible move needs no timer`() throws {
        #expect(WindowPace.nextTickPixelMove(ticks: [], backingScale: 2, now: self.now) == nil)
        let window = self.window(minutes: 23, remainingMinutes: 0.01)
        let pace = try #require(WindowPace.make(window: window, provider: .claude, now: self.now))
        let resetsAt = try #require(window.resetsAt)
        for showUsed in [false, true] {
            let tick = WindowPace.TickLane(pace: pace, resetsAt: resetsAt, showUsed: showUsed)
            for scale: CGFloat in [1, 2, 0, .nan] {
                #expect(WindowPace.nextTickPixelMove(ticks: [tick], backingScale: scale, now: self.now) == nil)
            }
            #expect(WindowPace.nextTickPixelMove(ticks: [tick], backingScale: 2, now: resetsAt) == nil)
            #expect(WindowPace.nextTickPixelMove(
                ticks: [tick], backingScale: 2, now: self.now.addingTimeInterval(-2000)) == nil)
        }
    }

    @MainActor @Test func `Pace mode exactly follows grouped tile eligibility`() {
        let settings = testSettingsStore(suiteName: "WindowPaceTests")
        enableTestProviders([.codex, .claude], settings: settings)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        for providers: Set<UsageProvider> in [[], [.codex], [.codex, .claude], [.codex, .claude, .grok]] {
            enableTestProviders(providers, settings: settings)
            for merge in [false, true] {
                for grouped in [false, true] {
                    settings.mergeIcons = merge
                    settings.menuBarGroupsProviderIcons = grouped
                    let tiles = GroupedProviderIconPlan.tiles(
                        enabled: grouped,
                        shouldMergeIcons: merge,
                        providers: store.enabledProvidersForDisplay(),
                        limit: SettingsStore.mergedOverviewProviderLimit)
                    #expect(PaceMode.isActive(settings: settings, store: store) == (tiles != nil))
                }
            }
        }
    }
}
