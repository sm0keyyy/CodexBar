import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class PacePanelRenderProofTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_620_800)

    func test_overviewDefaultsToWeeklyAndKeepsChartsInRemainingMode() {
        var input = self.fixture
        XCTAssertFalse(input.isReloading)
        XCTAssertNil(input.retainedTodayTotalUSD)
        input.showUsed = true
        let model = PacePanelModel.make(input)
        let weekly = PaceOverviewView(model: model, input: input, onAction: { _ in })
        let session = PaceOverviewView(model: model, input: input, onAction: { _ in }, showsWeekly: false)
        XCTAssertTrue(weekly.showsWeekly)
        XCTAssertEqual(weekly.chartSeries.map(\.provider), [.codex, .claude, .grok])
        XCTAssertEqual(weekly.chartSeries.compactMap { $0.samples.last?.remainingPercent }, [46, 58, 95])
        XCTAssertEqual(session.chartSeries.map(\.provider), [.claude])
        XCTAssertEqual(session.chartSeries.last?.samples.last?.remainingPercent, 94)
        XCTAssertEqual(model.providers.first?.windows.first?.fillPercent, 54)
    }

    func test_reloadRetainsTheSameDayTotalAndDimsOnlyTheTotal() throws {
        var input = self.fixture
        var slot = GroupedDailyCost.Slot()
        _ = slot.resolve(
            inputs: input.todayCostInputs, isReloading: false, preferredCurrency: "USD", now: input.now)
        input.isReloading = true
        input.todayCostInputs[2] = .init(name: "Grok", value: .loading)
        let retained = slot.resolve(
            inputs: input.todayCostInputs, isReloading: true, preferredCurrency: "USD", now: input.now)
        input.retainedTodayTotalUSD = retained.dimmed ? retained.totalUSD : nil
        let view = PaceOverviewView(model: .make(input), input: input, onAction: { _ in })
        XCTAssertEqual(try XCTUnwrap(view.todayTotalUSD), 70.61, accuracy: 0.000001)
        XCTAssertTrue(view.isTodayTotalDimmed)
        XCTAssertEqual(view.costText(for: .exact(25.11)), "$25.11")
        XCTAssertEqual(view.costText(for: .loading), "loading")
        let nextDay = try XCTUnwrap(input.calendar.date(byAdding: .day, value: 1, to: input.now))
        let expired = slot.resolve(
            inputs: input.todayCostInputs, isReloading: true, preferredCurrency: "USD", now: nextDay)
        XCTAssertFalse(expired.dimmed)
        input.retainedTodayTotalUSD = nil
        let incomplete = PaceOverviewView(model: .make(input), input: input, onAction: { _ in })
        XCTAssertFalse(incomplete.isTodayTotalDimmed)
        input.isReloading = false
        input.todayCostInputs[2] = .init(name: "Grok", value: .exact(9))
        let complete = PaceOverviewView(model: .make(input), input: input, onAction: { _ in })
        XCTAssertEqual(try XCTUnwrap(complete.todayTotalUSD), 71.65, accuracy: 0.000001)
        XCTAssertFalse(complete.isTodayTotalDimmed)
    }

    func test_unpricedAndEmptyValuesNeverBecomeZero() {
        let input = self.fixture
        let view = PaceOverviewView(model: .make(input), input: input, onAction: { _ in })
        XCTAssertEqual(view.costText(for: .unpriced), "unpriced")
        XCTAssertEqual(view.costText(for: .estimate(0, unpricedModels: ["unknown-fixture"])), "unpriced")
        XCTAssertEqual(view.costText(for: .estimate(2.50, unpricedModels: ["unknown-fixture"])), "≈$2.50")
        XCTAssertEqual(view.costText(for: .zero), "$0.00")
        let empty = PacePanelInput(providers: [], now: self.now)
        let emptyView = PaceOverviewView(model: .make(empty), input: empty, onAction: { _ in })
        XCTAssertTrue(emptyView.chartSeries.isEmpty)
        XCTAssertNil(emptyView.todayTotalUSD)
        XCTAssertFalse(emptyView.isTodayTotalDimmed)
    }

    func test_timelineAndSharedChartHaveOneCompleteSpokenSummary() throws {
        let model = PacePanelModel.make(self.fixture)
        let claude = try XCTUnwrap(model.providers.first { $0.provider == .claude })
        let row = try XCTUnwrap(claude.windows.first { $0.id == "secondary" })
        XCTAssertEqual(
            PaceTimelineRow(provider: .claude, row: row, showUsed: false).summary,
            "Claude Weekly, 58 percent remaining, ahead +32%, resets in 1d 20h")
        let chart = PaceSharedChart(series: model.weeklySeries, windowClass: .weekly, providers: model.providers)
        XCTAssertTrue(chart.summary.contains("Remaining quota by fraction of window elapsed"))
        XCTAssertTrue(chart.summary.contains("Codex: 46 percent remaining at 71 percent of the window elapsed"))
        XCTAssertTrue(chart.summary.contains("Claude: 58 percent remaining at 74 percent of the window elapsed"))
        XCTAssertTrue(chart.summary.contains("Grok: 95 percent remaining at 30 percent of the window elapsed"))
        XCTAssertEqual(claude.windows.map(\.label), ["Session", "Weekly", "Fable"])
    }

    func test_closeChartLabelsAvoidEveryDotEachOtherAndThePlotEdges() throws {
        let plot = CGRect(x: 0, y: 0, width: 298, height: 108)
        let points: [CGPoint?] = [CGPoint(x: 213, y: 58), CGPoint(x: 220, y: 45), CGPoint(x: 298, y: 0)]
        let sizes = ["Codex 46%", "Claude 58%", "Grok 95%"].map { PaceChartLabelLayout.size(for: $0) }
        let ideal = PaceChartLabelLayout.idealFrame(in: plot)
        let frames = PaceChartLabelLayout.place(points: points, sizes: sizes, in: plot, avoiding: [ideal])
        XCTAssertEqual(frames, PaceChartLabelLayout.place(points: points, sizes: sizes, in: plot, avoiding: [ideal]))
        for (index, placement) in frames.enumerated() {
            let frame = try XCTUnwrap(placement)
            XCTAssertTrue(plot.contains(frame))
            XCTAssertFalse(frame.intersects(ideal))
            for point in points.compactMap(\.self) {
                XCTAssertFalse(frame.intersects(CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)))
            }
            for other in frames.dropFirst(index + 1) {
                XCTAssertFalse(try frame.intersects(XCTUnwrap(other)))
            }
        }
        XCTAssertLessThan(ideal.maxY, plot.height * ideal.minX / plot.width - 4)
    }

    func test_chartLabelTextHasContrastInBothAppearances() throws {
        func luminance(_ color: NSColor) throws -> Double {
            let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
            let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
                $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var resolvedInk: NSColor?
            var resolvedBackground: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolvedInk = PaceChartLabelLayout.textColor.usingColorSpace(.sRGB)
                resolvedBackground = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
            }
            let ink = try luminance(XCTUnwrap(resolvedInk))
            let background = try luminance(XCTUnwrap(resolvedBackground))
            let ratio = (max(ink, background) + 0.05) / (min(ink, background) + 0.05)
            XCTAssertGreaterThanOrEqual(ratio, 4.5)
        }
    }

    func test_syntheticOverviewAndEveryPillState() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_PACE_PANEL_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_PACE_PANEL_PROOF_DIR for synthetic offscreen rendering")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let input = self.fixture
        for (name, scheme, appearance) in [
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
        ] {
            let view = PacePanelRootView(
                input: input,
                model: .make(input),
                selection: .overview,
                providerContext: nil,
                onCommand: { _ in },
                onAction: { _ in })
                .background(PaceProofGlass())
                .environment(\.colorScheme, scheme)
                .fixedSize(horizontal: false, vertical: true)
            try self.render(
                view,
                width: 360,
                appearance: appearance,
                to: output.appendingPathComponent("overview-\(name).png"))
        }
        try self.render(
            self.pillMatrix,
            width: 640,
            appearance: .darkAqua,
            to: output.appendingPathComponent("pill-states.png"))
        print("PACE_PANEL_PROOFS overview-dark.png overview-light.png pill-states.png")
    }

    func test_warningStripProofsAndFirstFrameLatency() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_PACE_PANEL_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_PACE_PANEL_PROOF_DIR for synthetic offscreen rendering")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for hasWarnings in [false, true] {
            var input = self.fixture
            if hasWarnings {
                input.pillStates[.codex] = .init(hasData: true, warning: .amber)
                input.pillStates[.claude] = .init(
                    hasData: true, stale: true, updatedAt: self.now.addingTimeInterval(-10800))
            }
            XCTAssertEqual(PacePanelModel.make(input).warnings.count, hasWarnings ? 2 : 0)
            for (name, scheme, appearance) in [
                ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
                ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ] {
                let view = PacePanelRootView(
                    input: input,
                    model: .make(input),
                    selection: .overview,
                    providerContext: nil,
                    onCommand: { _ in },
                    onAction: { _ in })
                    .background(PaceProofGlass())
                    .environment(\.colorScheme, scheme)
                    .fixedSize(horizontal: false, vertical: true)
                let filename = "overview-\(hasWarnings ? "two-warnings" : "no-warnings")-\(name).png"
                try self.render(view, width: 360, appearance: appearance, to: output.appendingPathComponent(filename))
                print("PACE_WARNING_PROOF \(output.appendingPathComponent(filename).path)")
            }
        }
    }

    private var fixture: PacePanelInput {
        func window(_ used: Double, _ minutes: Int?, _ remaining: Double) -> RateWindow {
            RateWindow(
                usedPercent: used,
                windowMinutes: minutes,
                resetsAt: self.now.addingTimeInterval(remaining * 60),
                resetDescription: nil)
        }
        var input = PacePanelInput(
            providers: [.codex, .claude, .grok],
            snapshots: [
                .codex: UsageSnapshot(primary: nil, secondary: window(54, 10080, 2888), updatedAt: self.now),
                .claude: UsageSnapshot(
                    primary: window(6, 300, 228),
                    secondary: window(42, 10080, 2640),
                    extraRateWindows: [.init(
                        id: "claude-weekly-scoped-fable",
                        title: "Fable",
                        window: window(4, 10080, 2640))],
                    updatedAt: self.now),
                .grok: UsageSnapshot(primary: window(5, nil, 7020), secondary: nil, updatedAt: self.now),
            ],
            todayCostInputs: [
                .init(name: "Codex", value: .exact(37.54)),
                .init(name: "Claude", value: .exact(25.11)),
                .init(name: "Grok", value: .exact(7.96)),
            ],
            now: self.now)
        let costs: [(UsageProvider, [Double])] = [
            (.codex, [22, 48, 31, 60, 18, 9, 37.54]),
            (.claude, [40, 95, 70, 110, 55, 20, 25.11]),
            (.grok, [3, 6, 4, 9, 2, 1, 7.96]),
        ]
        let formatter = DateFormatter()
        formatter.calendar = input.calendar
        formatter.timeZone = input.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        for (provider, values) in costs {
            let daily = values.enumerated().map { index, cost in
                CostUsageDailyReport.Entry(
                    date: formatter.string(from: input.calendar.date(byAdding: .day, value: index - 6, to: self.now)!),
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 100,
                    costUSD: cost,
                    modelsUsed: [],
                    modelBreakdowns: nil)
            }
            input.tokenSnapshots[provider] = CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                daily: daily,
                updatedAt: self.now)
        }
        return input
    }

    private var pillMatrix: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Synthetic pill states · 1× and 2×").font(.headline)
            HStack {
                Text("State").frame(width: 120, alignment: .leading)
                Text("1×").frame(width: 140)
                Text("2×").frame(width: 280)
            }
            ForEach(0..<11) { state in
                HStack {
                    Text([
                        "Normal",
                        "Behind pace",
                        "Far ahead",
                        "Warning",
                        "Critical",
                        "No data",
                        "Reload with data",
                        "Stale",
                        "Over budget",
                        "Used mode",
                        "High contrast",
                    ][state])
                        .frame(width: 120, alignment: .leading)
                    self.pillItem(state: state, scale: 1).frame(width: 140)
                    self.pillItem(state: state, scale: 2).frame(width: 280)
                }
                .frame(height: 40)
            }
        }
        .font(.system(size: 11))
        .padding(16)
        .foregroundStyle(.white)
        .background(Color(white: 0.09))
        .environment(\.colorScheme, .dark)
    }

    private func pillItem(state: Int, scale: CGFloat) -> some View {
        HStack(spacing: 6 * scale) {
            if state == 10 {
                Text("Codex 46% · Claude 94/58% · Grok 95%")
                    .font(.system(size: 6 * scale))
            } else {
                ForEach([UsageProvider.codex, .claude, .grok], id: \.self) { provider in
                    Image(nsImage: self.pill(provider: provider, state: state, scale: scale))
                        .resizable().interpolation(.none)
                        .frame(width: 24 * scale, height: 18 * scale)
                }
            }
            Text("$70.61")
                .font(.system(size: 11 * scale).monospacedDigit())
                .foregroundStyle(state == 8 ? Color(nsColor: .systemOrange) : .white)
                .opacity(state == 5 || state == 6 ? 0.55 : 1)
        }
    }

    private func pill(provider: UsageProvider, state: Int, scale: CGFloat) -> NSImage {
        let accent = ProviderAccentPalette.color(for: provider)
        let color = NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)
        let primary: Double = provider == .codex ? (state == 1 ? 20 : 46) : (provider == .claude ? 94 : 95)
        let tick: Double = provider == .codex ? 28.65 : (provider == .claude ? 76 : 69.64)
        return GroupedProviderIconComposer.pill(
            primary: state == 5 && provider == .grok ? nil : (state == 9 ? 100 - primary : primary),
            secondary: provider == .claude ? (state == 9 ? 42 : 58) : nil,
            color: color,
            stale: state == 7,
            loading: state == 6,
            warning: state == 3 ? .amber : (state == 4 ? .red : .none),
            primaryTick: state == 9 ? 100 - tick : tick,
            secondaryTick: provider == .claude ? (state == 9 ? 73.81 : 26.19) : nil,
            backingScale: scale)
    }

    private func render(_ view: some View, width: CGFloat, appearance: NSAppearance.Name, to url: URL) throws {
        let start = CFAbsoluteTimeGetCurrent()
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame.size = NSSize(width: width, height: hosting.fittingSize.height)
        hosting.layoutSubtreeIfNeeded()
        let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("PACE_OFFSCREEN_FIRST_FRAME \(url.lastPathComponent) latency_ms=\(milliseconds)")
        if url.lastPathComponent.contains("warnings") { XCTAssertLessThanOrEqual(milliseconds, 100) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}

private struct PaceProofGlass: NSViewRepresentable {
    func makeNSView(context _: Context) -> PaceGlassView { PaceGlassView(frame: .zero) }
    func updateNSView(_: PaceGlassView, context _: Context) {}
}
