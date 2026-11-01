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

    @Test func `warning thresholds use worst active window without notification state`() {
        #expect(GroupedTileWarning.level(windows: [(10, [0, 0])]) == .none)
        #expect(GroupedTileWarning.level(windows: [(45, [50, 20])]) == .amber)
        #expect(GroupedTileWarning.level(windows: [(15, [50, 20])]) == .red)
        #expect(GroupedTileWarning.level(windows: [(19, [20])]) == .red)
        #expect(GroupedTileWarning.level(windows: []) == .none)
        #expect(GroupedTileWarning.level(windows: [(45, [50, 20]), (20, [50, 20])]) == .red)
    }
}
