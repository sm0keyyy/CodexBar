import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct PacePanelModelTests {
    private let now = Date(timeIntervalSince1970: 1_793_577_600)

    private func window(used: Double, minutes: Int?, remainingMinutes: Double) -> RateWindow {
        RateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: self.now.addingTimeInterval(remainingMinutes * 60),
            resetDescription: nil)
    }

    private var fixture: PacePanelInput {
        let codex = self.window(used: 54, minutes: 10080, remainingMinutes: 2888)
        let session = self.window(used: 6, minutes: 300, remainingMinutes: 228)
        let weekly = self.window(used: 42, minutes: 10080, remainingMinutes: 2640)
        let fable = self.window(used: 4, minutes: 10080, remainingMinutes: 2640)
        let grok = self.window(used: 5, minutes: nil, remainingMinutes: 7020)
        return PacePanelInput(
            providers: [.codex, .claude, .grok],
            snapshots: [
                .codex: UsageSnapshot(primary: nil, secondary: codex, updatedAt: self.now),
                .claude: UsageSnapshot(
                    primary: session,
                    secondary: weekly,
                    extraRateWindows: [.init(id: "claude-weekly-scoped-fable", title: "Fable", window: fable)],
                    updatedAt: self.now),
                .grok: UsageSnapshot(primary: grok, secondary: nil, updatedAt: self.now),
            ],
            todayCostInputs: [
                .init(name: "Codex", value: .exact(37.54)),
                .init(name: "Claude", value: .exact(25.11)),
                .init(name: "Grok", value: .exact(7.96)),
            ],
            now: self.now)
    }

    @Test func `T19 today amounts and normalized pace points match the tooltip fixture`() throws {
        let model = PacePanelModel.make(self.fixture)
        #expect(model.today.displayText == "$70.61")
        #expect(model.today.lines == ["Today: $70.61", "Codex $37.54 · Claude $25.11 · Grok $7.96"])
        #expect(model.providers.map(\.today) == [.exact(37.54), .exact(25.11), .exact(7.96)])
        #expect(model.providers.map(\.provider) == [.codex, .claude, .grok])
        #expect(model.weeklySeries.map(\.provider) == [.codex, .claude, .grok])
        for (series, expected) in zip(model.weeklySeries, [(0.7135, 46.0), (0.7381, 58.0), (0.3036, 95.0)]) {
            let point = try #require(series.samples.last)
            #expect(abs(point.x - expected.0) < 0.00005)
            #expect(point.remainingPercent == expected.1)
        }
        let session = try #require(model.sessionSeries.first)
        #expect(session.provider == .claude)
        let point = try #require(session.samples.last)
        #expect(abs(point.x - 0.24) < 0.000001)
        #expect(point.remainingPercent == 94)
        let claude = try #require(model.providers.first(where: { $0.provider == .claude }))
        #expect(claude.windows.map(\.id) == ["primary", "secondary", "claude-weekly-scoped-fable"])
        #expect(claude.windows.map(\.countdown) == ["3h 48m", "1d 20h", "1d 20h"])
        #expect(claude.windows.map(\.role) == [.session, .weekly, .weekly])
        #expect(claude.windows.last?.series == "extra:claude-weekly-scoped-fable")
        #expect(model.providers.first?.windows.first?.role == .single)
        #expect(model.providers.first?.windows.first?.countdown == "2d 8m")
    }

    @Test func `T20 empty Grok history gives only its current point`() throws {
        var input = self.fixture
        input.histories[.grok] = []
        let series = try #require(PacePanelModel.make(input).weeklySeries.first(where: { $0.provider == .grok }))
        #expect(series.samples.count == 1)
        let point = try #require(series.samples.first)
        #expect(abs(point.x - 0.3035714286) < 0.0000001)
        #expect(point.remainingPercent == 95)
        #expect(point.x > 0)
    }

    @Test func `burndown trails use captured samples from the matching reset only`() throws {
        var input = self.fixture
        let reset = try #require(input.snapshots[.grok]?.primary?.resetsAt)
        input.histories[.grok] = [.init(name: .weekly, windowMinutes: 10080, entries: [
            .init(
                capturedAt: self.now.addingTimeInterval(-7200),
                usedPercent: 1,
                resetsAt: reset.addingTimeInterval(-86400)),
            .init(capturedAt: self.now.addingTimeInterval(-3600), usedPercent: 3, resetsAt: reset),
        ])]
        let series = try #require(PacePanelModel.make(input).weeklySeries.first(where: { $0.provider == .grok }))
        #expect(series.samples.count == 2)
        #expect(series.samples.map(\.remainingPercent) == [97, 95])
        #expect(try abs(#require(series.samples.first).x - 0.2976190476) < 0.0000001)
    }

    @Test func `countdown updates do not move the last capture along the chart`() {
        let original = self.fixture
        let later = PacePanelInput(
            providers: original.providers,
            snapshots: original.snapshots,
            todayCostInputs: original.todayCostInputs,
            now: self.now.addingTimeInterval(120))
        let first = PacePanelModel.make(original)
        let second = PacePanelModel.make(later)
        #expect(first.weeklySeries == second.weeklySeries)
        #expect(first.sessionSeries == second.sessionSeries)
        #expect(first.providers[1].windows[0].tickPercent != second.providers[1].windows[0].tickPercent)
    }

    @Test func `used mode changes timeline fills and ticks but never the remaining charts`() throws {
        let remaining = PacePanelModel.make(self.fixture)
        var input = self.fixture
        input.showUsed = true
        let used = PacePanelModel.make(input)
        #expect(used.showUsed)
        #expect(used.weeklySeries == remaining.weeklySeries)
        #expect(used.sessionSeries == remaining.sessionSeries)
        let codex = try #require(used.providers.first?.windows.first)
        #expect(codex.fillPercent == 54)
        #expect(try abs(#require(codex.tickPercent) - 71.34920635) < 0.000001)
        #expect(remaining.providers.first?.windows.first?.fillPercent == 46)
    }

    @Test func `missing snapshots and reset metadata do not invent usage or pace`() throws {
        var input = self.fixture
        input.snapshots[.grok] = nil
        input.snapshots[.claude] = UsageSnapshot(
            primary: .init(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: .init(
                usedPercent: 0,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            extraRateWindows: [.init(
                id: "unknown",
                title: "Unknown",
                window: self.window(used: 100, minutes: 300, remainingMinutes: 30),
                usageKnown: false)],
            updatedAt: self.now)
        let model = PacePanelModel.make(input)
        let grok = try #require(model.providers.first(where: { $0.provider == .grok }))
        #expect(grok.windows.isEmpty)
        #expect(grok.today == .exact(7.96))
        let claude = try #require(model.providers.first(where: { $0.provider == .claude }))
        #expect(claude.windows.count == 1)
        let row = try #require(claude.windows.first)
        #expect(row.fillPercent == 80)
        #expect(row.pace == nil)
        #expect(row.tickPercent == nil)
        #expect(row.countdown == nil)
        #expect(model.sessionSeries.isEmpty)
        #expect(model.weeklySeries.count == 1)
    }

    @Test func `daily stacks retain local days and unpriced values without zero fabrication`() throws {
        var input = self.fixture
        input.calendar = Calendar(identifier: .gregorian)
        input.calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let key = "2026-11-01"
        input.tokenSnapshots[.grok] = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [.init(
                date: key,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 100,
                costUSD: nil,
                modelsUsed: ["unpriced-fixture"],
                modelBreakdowns: nil)],
            updatedAt: self.now)
        let days = PacePanelModel.make(input).last7Days
        #expect(days.count == 7)
        let last = try #require(days.last)
        #expect(last.date == input.calendar.startOfDay(for: self.now))
        #expect(last.unpricedProviders == [.grok])
        #expect(last.costsUSD[.grok] == nil)
        #expect(last.totalUSD == nil)
        for (left, right) in zip(days, days.dropFirst()) {
            #expect(input.calendar.dateComponents([.day], from: left.date, to: right.date).day == 1)
        }
    }

    @Test func `last tab resolution preserves the merged switcher selection`() {
        let providers: [UsageProvider] = [.codex, .claude, .grok]
        #expect(PacePanelTab.resolve(
            providers: providers, lastSelectedWasOverview: true, selectedProvider: .claude) == .overview)
        #expect(PacePanelTab.resolve(
            providers: providers, lastSelectedWasOverview: false, selectedProvider: .grok) == .provider(.grok))
        #expect(PacePanelTab.resolve(
            providers: providers, lastSelectedWasOverview: false, selectedProvider: .kiro) == .overview)
        #expect(PacePanelTab.resolve(
            providers: [], lastSelectedWasOverview: false, selectedProvider: nil) == .overview)
    }

    @Test func `T21 model strings and every English Pace value exclude the forbidden product name`() throws {
        let forbidden = "Code" + "Burn"
        let modelStrings = self.strings(in: PacePanelModel.make(self.fixture))
        #expect(!modelStrings.isEmpty)
        #expect(modelStrings.allSatisfy { !$0.localizedCaseInsensitiveContains(forbidden) })
        let url = try #require(codexBarLocalizationResourceBundle().url(
            forResource: "Localizable", withExtension: "strings", subdirectory: "en.lproj"))
        let dictionary = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil) as? [String: String])
        let paceValues = dictionary.filter { $0.key.hasPrefix("pace_") }.values
        #expect(!paceValues.isEmpty)
        #expect(paceValues.allSatisfy { !$0.localizedCaseInsensitiveContains(forbidden) })
    }

    private func strings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        return Mirror(reflecting: value).children.flatMap { self.strings(in: $0.value) }
    }
}
