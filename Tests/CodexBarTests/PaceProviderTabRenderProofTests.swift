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
        var input = PaceProviderTabModelTests.fixture()
        input.calendar = .current
        for block in PacePanelModel.make(input).providers {
            input.histories[block.provider] = input.histories[block.provider]?.map { history in
                guard let row = block.windows.first(where: { $0.series == history.name }),
                      let pace = row.pace else { return history }
                let reset = input.now.addingTimeInterval(
                    Double(pace.durationMinutes) * 60 * (1 - pace.fractionElapsed))
                return PlanUtilizationSeriesHistory(
                    name: history.name,
                    windowMinutes: history.windowMinutes,
                    entries: history.entries + [.init(
                        capturedAt: input.now, usedPercent: 100 - row.fillPercent, resetsAt: reset)])
            }
        }
        input.tokenSnapshots[.grok] = PaceProviderTabModelTests.costSnapshot(now: input.now, daily: [
            PaceProviderTabModelTests.entry(date: "2026-11-01", cost: 4),
            PaceProviderTabModelTests.entry(date: "2026-11-02", cost: 7.96, models: [
                .init(modelName: "grok-4-0709", costUSD: 7.96),
                .init(modelName: "fixture-unknown", costUSD: nil),
            ]),
        ])
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
