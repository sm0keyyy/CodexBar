import Foundation
import Observation
import os
import Testing
@testable import CodexBar

@MainActor
struct SettingsStoreGroupedIconTests {
    nonisolated static let localizationKeys: Set<String> = [
        "grouped_icons_title",
        "grouped_icons_subtitle",
        "grouped_icons_cost_off_hint",
        "grouped_icons_budget_title",
        "grouped_icons_budget_subtitle",
        "grouped_icons_tooltip_today",
        "grouped_icons_tooltip_estimate",
        "grouped_icons_tooltip_no_price",
        "grouped_icons_tooltip_loading",
        "grouped_icons_tooltip_unpriced",
        "grouped_icons_tooltip_budget",
        "grouped_icons_tooltip_more",
    ]

    @Test func `grouped defaults persist and sanitize budget input`() throws {
        let suite = "GroupedIconSettings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = testSettingsStore(suiteName: suite, userDefaults: defaults)
        #expect(!settings.menuBarGroupsProviderIcons)
        #expect(settings.menuBarGroupedDailyBudgetUSD == 0)
        settings.menuBarGroupsProviderIcons = true
        settings.menuBarGroupedDailyBudgetUSD = 20
        let second = testSettingsStore(suiteName: suite, userDefaults: defaults)
        #expect(second.menuBarGroupsProviderIcons)
        #expect(second.menuBarGroupedDailyBudgetUSD == 20)
        second.menuBarGroupedDailyBudgetUSD = -1
        #expect(second.menuBarGroupedDailyBudgetUSD == 0)
        second.menuBarGroupedDailyBudgetUSD = .infinity
        #expect(second.menuBarGroupedDailyBudgetUSD == 0)
    }

    @Test func `both keys invalidate menu observation`() {
        let settings = testSettingsStore(suiteName: "GroupedIconObservation")
        for update in [
            { settings.menuBarGroupsProviderIcons = true },
            { settings.menuBarGroupedDailyBudgetUSD = 10 },
        ] {
            let changed = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking { _ = settings.menuObservationToken } onChange: {
                changed.withLock { $0 = true }
            }
            update()
            #expect(changed.withLock { $0 })
        }
    }

    @Test func `H3 keeps both grouped keys in the menu observer`() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/CodexBar/Settings/SettingsStore+MenuObservation.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("_ = self.menuBarGroupsProviderIcons"))
        #expect(source.contains("_ = self.menuBarGroupedDailyBudgetUSD"))
    }

    @Test func `all 23 catalogs expose the same grouped key set`() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexBar/Resources")
        let catalogs = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
        #expect(catalogs.count == 23)
        let english =
            try #require(NSDictionary(contentsOf: resources.appendingPathComponent("en.lproj/Localizable.strings"))
                as? [String: String])
        let keys = Set(english.keys.filter { $0.hasPrefix("grouped_icons_") })
        #expect(keys == Self.localizationKeys)
        for url in catalogs {
            let catalog = try #require(NSDictionary(contentsOf: url.appendingPathComponent("Localizable.strings"))
                as? [String: String])
            #expect(Set(catalog.keys.filter { $0.hasPrefix("grouped_icons_") }) == keys)
        }
    }
}
