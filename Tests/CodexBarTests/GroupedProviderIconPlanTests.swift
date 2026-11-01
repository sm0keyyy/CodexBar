import CodexBarCore
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

    @Test func `warning thresholds use worst active window without notification state`() {
        #expect(GroupedTileWarning.level(windows: [(10, [0, 0])]) == .none)
        #expect(GroupedTileWarning.level(windows: [(45, [50, 20])]) == .amber)
        #expect(GroupedTileWarning.level(windows: [(15, [50, 20])]) == .red)
        #expect(GroupedTileWarning.level(windows: [(19, [20])]) == .red)
        #expect(GroupedTileWarning.level(windows: []) == .none)
        #expect(GroupedTileWarning.level(windows: [(45, [50, 20]), (20, [50, 20])]) == .red)
    }
}
