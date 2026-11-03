import Foundation
import Testing
@testable import CodexBar

struct PacePanelLocalizationTests {
    static let localizationKeys: Set<String> = [
        "pace_ahead_format",
        "pace_all_other_models",
        "pace_all_windows_ahead",
        "pace_behind_format",
        "pace_burndown_legend",
        "pace_chart_guidance",
        "pace_chart_label_format",
        "pace_chart_point_format",
        "pace_cost_with_unpriced_format",
        "pace_current_weekly_window",
        "pace_estimated_cost_format",
        "pace_every_provider",
        "pace_fill_remaining",
        "pace_fill_used",
        "pace_fraction_elapsed",
        "pace_history_chart_format",
        "pace_history_empty",
        "pace_history_opus",
        "pace_history_point_format",
        "pace_history_series_format",
        "pace_history_used",
        "pace_history_used_format",
        "pace_ideal",
        "pace_ideal_now",
        "pace_last_capture_format",
        "pace_login",
        "pace_model_share",
        "pace_models_thirty_days",
        "pace_no_cost_history",
        "pace_no_windows",
        "pace_not_captured",
        "pace_official_xai_rates",
        "pace_partial_cost_format",
        "pace_partly_unpriced",
        "pace_remaining_vs_ideal",
        "pace_reserve",
        "pace_reset",
        "pace_resets",
        "pace_resets_in_format",
        "pace_row_remaining_format",
        "pace_row_used_format",
        "pace_seven_day_cost",
        "pace_shared_chart_summary",
        "pace_stacked_by_provider",
        "pace_thirty_day_cost_chart",
        "pace_thirty_days",
        "pace_tick_legend",
        "pace_tooltip_resets_format",
        "pace_tooltip_unknown_format",
        "pace_tooltip_window_format",
        "pace_unpriced",
        "pace_weekly_cost_tokens_format",
        "pace_window_class",
        "pace_window_start",
        "pace_windows_behind_format",
    ]

    /// Pure formats and the model name do not need translation.
    static let intentionallyUnchangedKeys: Set<String> = [
        "pace_chart_label_format",
        "pace_history_opus",
        "pace_partial_cost_format",
        "pace_tooltip_unknown_format",
        "pace_tooltip_window_format",
    ]

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test
    func `Pace keys match source use and all 23 catalogs without duplicates`() throws {
        let sources = Self.root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var usedKeys: Set<String> = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            try usedKeys.formUnion(Self.matches(#""(pace_[a-z0-9_]+)""#, in: source, group: 1))
        }
        #expect(usedKeys == Self.localizationKeys)
        let resources = sources.appendingPathComponent("CodexBar/Resources")
        let catalogs = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
        #expect(catalogs.count == 23)
        for url in catalogs {
            let strings = url.appendingPathComponent("Localizable.strings")
            let catalog = try #require(NSDictionary(contentsOf: strings) as? [String: String])
            let contents = try String(contentsOf: strings, encoding: .utf8)
            let declaredKeys = try Self.matches(
                #"(?m)^\s*"(pace_[a-z0-9_]+)"\s*="#,
                in: contents,
                group: 1)
            #expect(declaredKeys.count == Set(declaredKeys).count, "Duplicate Pace key in \(url.lastPathComponent)")
            #expect(
                Set(catalog.keys.filter { $0.hasPrefix("pace_") }) == usedKeys,
                "Missing or unused Pace key in \(url.lastPathComponent)")
        }
    }

    @Test
    func `Pace translations preserve placeholders and do not fall back to English`() throws {
        let resources = Self.root.appendingPathComponent("Sources/CodexBar/Resources")
        let english = try #require(NSDictionary(contentsOf: resources
                .appendingPathComponent("en.lproj/Localizable.strings")) as? [String: String])
        for language in AppLanguage.allCases where language != .system {
            let url = resources.appendingPathComponent("\(language.rawValue).lproj/Localizable.strings")
            let catalog = try #require(NSDictionary(contentsOf: url) as? [String: String])
            for key in Self.localizationKeys {
                let phrase = try #require(catalog[key], "Missing \(language.rawValue): \(key)")
                let original = try #require(english[key])
                #expect(!phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(!phrase.contains("CodeBurn"))
                let pattern = #"%%|%(?:[1-9][0-9]*\$)?(?:\.[0-9]+)?[@df]"#
                #expect(
                    try Self.matches(pattern, in: phrase).sorted() == Self.matches(pattern, in: original).sorted(),
                    "Placeholder mismatch \(language.rawValue): \(key)")
                if language != .english, !Self.intentionallyUnchangedKeys.contains(key) {
                    #expect(phrase != original, "Untranslated \(language.rawValue): \(key)")
                }
            }
        }
    }

    private static func matches(_ pattern: String, in text: String, group: Int = 0) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: group), in: text).map { String(text[$0]) }
        }
    }
}
