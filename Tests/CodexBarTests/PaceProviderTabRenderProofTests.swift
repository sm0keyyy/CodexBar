import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class PaceProviderTabRenderProofTests: XCTestCase {
    func test_providerTabs() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_PACE_PANEL_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_PACE_PANEL_PROOF_DIR for synthetic offscreen rendering")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = try self.populatedInput()
        for block in PacePanelModel.make(input).providers {
            let model = PaceProviderTabModel.make(block: block, input: input, context: nil)
            XCTAssertTrue(model.burndowns.allSatisfy { $0.samples.count >= 7 })
            XCTAssertEqual(model.histories.count, block.windows.count)
            XCTAssertTrue(model.histories.allSatisfy { $0.chart.points.filter(\.isObserved).count >= 6 })
            XCTAssertEqual(model.daily.compactMap(\.totalUSD).count, 30)
        }
        for (provider, dark) in [
            (UsageProvider.claude, true),
            (.claude, false),
            (.grok, true),
            (.grok, false),
            (.codex, true),
        ] {
            try self.render(provider: provider, dark: dark, input: input, directory: directory)
        }
    }

    func test_longestLocalizedCostStat() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_PACE_PANEL_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_PACE_PANEL_PROOF_DIR for synthetic offscreen rendering")
        }
        let bundle = codexBarLocalizationResourceBundle()
        let locales = bundle.localizations.filter { $0 != "Base" }
        let captions = try locales.map { locale in
            let url = try XCTUnwrap(bundle.url(
                forResource: "Localizable", withExtension: "strings", subdirectory: "\(locale).lproj"))
            let catalog = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), format: nil) as? [String: String])
            return try XCTUnwrap(catalog["pace_partly_unpriced"])
        }
        XCTAssertEqual(captions.count, 23)
        let captionFont = NSFont.systemFont(ofSize: 10)
        let caption = try XCTUnwrap(captions.max {
            $0.size(withAttributes: [.font: captionFont]).width < $1.size(withAttributes: [.font: captionFont]).width
        })
        let amounts = locales.map {
            99999.99.formatted(.currency(code: "USD").locale(Locale(identifier: $0)))
        }
        let amountFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let amount = try XCTUnwrap(amounts.max {
            $0.size(withAttributes: [.font: amountFont]).width < $1.size(withAttributes: [.font: amountFont]).width
        })
        let view = HStack(alignment: .top, spacing: 10) {
            PaceProviderCostStat(title: L("Today"), amount: amount, caption: nil)
            PaceProviderCostStat(title: L("7 days"), amount: amount, caption: caption)
            PaceProviderCostStat(title: L("pace_thirty_days"), amount: amount, caption: caption)
        }
        .padding(16)
        .frame(width: 360)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 120)
        hosting.layoutSubtreeIfNeeded()
        hosting.frame.size.height = ceil(hosting.fittingSize.height)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("grok-cost-localization.png"))
        print("Pace localized cost proof: 23 catalogs, longest amount \(amount), caption \(caption), width 360 pt")
    }

    private func populatedInput() throws -> PacePanelInput {
        var input = PaceProviderTabModelTests.fixture()
        input.calendar = .current
        for block in PacePanelModel.make(input).providers {
            input.histories[block.provider] = try block.windows.map {
                try self.history(row: $0, now: input.now)
            }
            input.tokenSnapshots[block.provider] = try PaceProviderTabModelTests.costSnapshot(
                now: input.now,
                daily: self.dailyCosts(block: block, input: input))
        }
        return input
    }

    private func history(row: PaceWindowRow, now: Date) throws -> PlanUtilizationSeriesHistory {
        let pace = try XCTUnwrap(row.pace)
        let name = try XCTUnwrap(row.series)
        let duration = Double(pace.durationMinutes) * 60
        let reset = Date(timeIntervalSince1970:
            (now.timeIntervalSince1970 + duration * (1 - pace.fractionElapsed)).rounded())
        let start = reset.addingTimeInterval(-duration)
        let used = 100 - row.fillPercent
        var entries = [0.03, 0.15, 0.30, 0.5, 0.7, 0.85, 1].map { progress in
            PlanUtilizationHistoryEntry(
                capturedAt: progress == 1 ? now
                    : start.addingTimeInterval(duration * pace.fractionElapsed * progress),
                usedPercent: used * progress * progress,
                resetsAt: reset)
        }
        for (index, peak) in [76.0, 52, 88, 41, 64].enumerated() {
            entries.append(.init(
                capturedAt: now.addingTimeInterval(-duration * Double(index + 1)),
                usedPercent: peak,
                resetsAt: reset.addingTimeInterval(-duration * Double(index + 1))))
        }
        return PlanUtilizationSeriesHistory(
            name: name,
            windowMinutes: pace.durationMinutes,
            entries: entries.sorted { $0.capturedAt < $1.capturedAt })
    }

    private func dailyCosts(block: PaceProviderBlock, input: PacePanelInput) throws -> [CostUsageDailyReport.Entry] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = input.calendar
        formatter.timeZone = input.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = input.calendar.startOfDay(for: input.now)
        let todayCost = try XCTUnwrap(block.today.usd)
        let topModel = block.provider == .grok ? "grok-4-0709"
            : (block.provider == .claude ? "claude-opus-4-1" : "gpt-5")
        let names = [topModel, "fixture-model-b", "fixture-model-c", "fixture-model-d"]
        let weights = [0.6, 0.25, 0.1, 0.05]
        let multiplier = block.provider == .grok ? 0.22 : (block.provider == .claude ? 2.2 : 1.2)
        return try (0..<30).map { index in
            let date = try XCTUnwrap(input.calendar.date(byAdding: .day, value: index - 29, to: today))
            let cost = index == 29 ? todayCost : Double((index * 7) % 23 + 4) * multiplier
            var models = zip(names, weights).map {
                CostUsageDailyReport.ModelBreakdown(modelName: $0, costUSD: cost * $1)
            }
            if block.provider == .grok, index == 29 {
                models.append(.init(modelName: "fixture-unknown", costUSD: nil))
            }
            return PaceProviderTabModelTests.entry(date: formatter.string(from: date), cost: cost, models: models)
        }
    }

    private func render(provider: UsageProvider, dark: Bool, input: PacePanelInput, directory: URL) throws {
        let root = PacePanelRootView(
            input: input,
            model: .make(input),
            selection: .provider(provider),
            providerContext: PaceProviderTabModelTests.context(provider: provider, input: input),
            onCommand: { _ in },
            onAction: { _ in })
            .environment(\.colorScheme, dark ? .dark : .light)
            .fixedSize(horizontal: false, vertical: true)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 800)
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(width: 360, height: ceil(hosting.fittingSize.height))
        XCTAssertGreaterThan(size.height, 400)
        hosting.frame.size = size
        let glass = PaceGlassView(frame: NSRect(origin: .zero, size: size))
        glass.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        glass.addSubview(hosting)
        glass.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let bitmap = try XCTUnwrap(glass.bitmapImageRepForCachingDisplay(in: glass.bounds))
        glass.cacheDisplay(in: glass.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 10000)
        let name = "\(provider.rawValue)-\(dark ? "dark" : "light").png"
        try data.write(to: directory.appendingPathComponent(name))
        print("Pace provider proof: \(name), \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
    }
}
