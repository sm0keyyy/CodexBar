import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct GroupedProviderIconPlanTests {
    @Test func `grouping requires both toggles and two first party providers`() throws {
        let providers: [ProviderInstanceID] = [.codex, .claude]
        #expect(GroupedProviderIconPlan.tiles(enabled: false, shouldMergeIcons: true, providers: providers) == nil)
        #expect(GroupedProviderIconPlan.tiles(enabled: true, shouldMergeIcons: false, providers: providers) == nil)
        #expect(GroupedProviderIconPlan.tiles(enabled: true, shouldMergeIcons: true, providers: [.codex]) == nil)
        let plugin = try #require(ProviderInstanceID(rawValue: "test-plugin"))
        #expect(GroupedProviderIconPlan.tiles(
            enabled: true,
            shouldMergeIcons: true,
            providers: [.codex, plugin]) == nil)
        let many = Array(UsageProvider.allCases.prefix(8))
        #expect(GroupedProviderIconPlan.tiles(
            enabled: true,
            shouldMergeIcons: true,
            providers: [plugin] + many.map(\.instanceID)) == Array(many.prefix(6)))
    }

    @Test func `quota selects shortest and longest measured windows and keeps one weekly lane whole`() {
        func window(_ used: Double, _ minutes: Int, synthetic: Bool = false) -> RateWindow {
            RateWindow(
                usedPercent: used,
                windowMinutes: minutes,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: synthetic)
        }
        let weekly = window(25, 10080)
        let session = window(80, 300)
        let one = GroupedProviderIconPlan.quota(snapshot: UsageSnapshot(
            primary: weekly, secondary: nil, updatedAt: Date()))
        #expect(one.shortest == weekly)
        #expect(one.longest == nil)
        let split = GroupedProviderIconPlan.quota(snapshot: UsageSnapshot(
            primary: weekly, secondary: session, tertiary: window(40, 1440), updatedAt: Date()))
        #expect(split.shortest == session)
        #expect(split.longest == weekly)
        let placeholder = GroupedProviderIconPlan.quota(snapshot: UsageSnapshot(
            primary: window(0, 300, synthetic: true), secondary: weekly, updatedAt: Date()))
        #expect(placeholder.shortest == weekly)
        #expect(placeholder.longest == nil)
        let unknown = GroupedProviderIconPlan.quota(snapshot: nil)
        #expect(unknown.shortest == nil)
        #expect(unknown.longest == nil)
        let extra = GroupedProviderIconPlan.quota(snapshot: UsageSnapshot(
            primary: session,
            secondary: weekly,
            extraRateWindows: [
                NamedRateWindow(id: "monthly", title: "Monthly", window: window(10, 43200)),
                NamedRateWindow(id: "unknown", title: "Unknown", window: window(100, 1), usageKnown: false),
            ],
            updatedAt: Date()))
        #expect(extra.shortest == session)
        #expect(extra.longest?.windowMinutes == 43200)
    }

    @Test func `authoritative weekly lane wins ties against full model specific weekly lanes`() {
        func window(_ remaining: Double, _ minutes: Int) -> RateWindow {
            RateWindow(
                usedPercent: 100 - remaining, windowMinutes: minutes, resetsAt: nil, resetDescription: nil)
        }
        let session = window(95, 300)
        let weekly = window(62, 10080)
        let alternative = window(100, 10080)
        let quota = GroupedProviderIconPlan.quota(snapshot: UsageSnapshot(
            primary: session,
            secondary: weekly,
            tertiary: alternative,
            extraRateWindows: [NamedRateWindow(id: "extra-weekly", title: "Weekly", window: alternative)],
            updatedAt: Date()))
        #expect(quota.shortest == session)
        #expect(quota.longest == weekly)
        let samePeriod = GroupedProviderIconPlan.quota(snapshot: UsageSnapshot(
            primary: weekly, secondary: alternative, updatedAt: Date()))
        #expect(samePeriod.shortest == weekly)
        #expect(samePeriod.longest == alternative)
    }

    @Test(arguments: [
        (37.0, 20.0, [50, 20], false),
        (37.0, 46.0, [50, 20], true),
        (15.0, 5.0, [50, 20], true),
        (20.0, 5.0, [50, 20], true),
        (50.0, 50.0, [50, 20], false),
        (37.0, 46.0, [60, 10], true),
        (15.0, 5.0, [60, 10], false),
        (10.0, 90.0, [0, 0], false),
        (19.0, 5.0, [20], true),
    ])
    func `quota warnings use configured thresholds and actual window pace`(
        remaining: Double, ideal: Double, thresholds: [Int], warns: Bool)
    {
        let now = Date(timeIntervalSince1970: 1_793_620_800)
        let window = RateWindow(
            usedPercent: 100 - remaining,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(604_800 * ideal / 100),
            resetDescription: nil)
        let detail = GroupedTileWarning.make(
            window: window, provider: .codex, thresholds: thresholds, label: "Weekly", now: now)
        #expect((detail != nil) == warns)
        #expect(detail?.remainingPercent == (warns ? remaining : nil))
        if remaining == 37, warns {
            #expect(detail?.threshold == thresholds.max())
            if case let .behind(deficit) = detail?.cause {
                #expect(abs(deficit - 9) < 0.001)
            } else {
                Issue.record("Expected the actual 9 percent pace deficit")
            }
        }
    }

    @Test func `missing pace metadata only permits the lower threshold warning`() {
        let now = Date()
        for (remaining, warns) in [(37.0, false), (15.0, true)] {
            let window = RateWindow(
                usedPercent: 100 - remaining, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
            #expect((GroupedTileWarning.make(
                window: window, provider: .codex, thresholds: [50, 20], label: "Weekly", now: now) != nil) == warns)
        }
    }
}
