import AppKit
import CodexBarCore
import SwiftUI

@MainActor
enum PacePalette {
    private static var cache: [UsageProvider: [PaceWindowRow.ColorRole: (fill: Color, track: Color)]] = [:]

    static func colors(for provider: UsageProvider, role: PaceWindowRow.ColorRole = .single)
        -> (fill: Color, track: Color)
    {
        if let colors = self.cache[provider]?[role] { return colors }
        let accent = ProviderAccentPalette.color(for: provider)
        let base = NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)
        let pair = GroupedProviderIconComposer.fillColors(for: base, split: role != .single)
        let colors = (
            Color(nsColor: role == .weekly ? pair.weekly : pair.session),
            Color(nsColor: GroupedProviderIconComposer.trackColor(weekly: pair.weekly, session: pair.session)))
        self.cache[provider, default: [:]][role] = colors
        return colors
    }
}

struct PaceTimelineBar: View {
    let percent: Double
    let tickPercent: Double?
    let color: Color
    let track: Color

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size)
            ZStack(alignment: .leading) {
                Path(roundedRect: rect, cornerRadius: 4).fill(self.track)
                Path(roundedRect: CGRect(
                    x: 0, y: 0, width: rect.width * self.percent / 100, height: rect.height), cornerRadius: 4)
                    .fill(self.color)
                if let tickPercent = self.tickPercent {
                    Path { path in
                        let x = min(rect.maxX - 0.75, max(0.75, rect.width * tickPercent / 100))
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: rect.height))
                    }
                    .stroke(Color(nsColor: .labelColor), lineWidth: 1.5)
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

struct PaceTimelineRow: View {
    let provider: UsageProvider
    let row: PaceWindowRow
    let showUsed: Bool

    var body: some View {
        let colors = PacePalette.colors(for: self.provider, role: self.row.role)
        HStack(spacing: 10) {
            Text(self.row.label)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            PaceTimelineBar(
                percent: self.row.fillPercent,
                tickPercent: self.row.tickPercent,
                color: colors.fill,
                track: colors.track)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 3) {
                    Text(self.row.fillPercent.formatted(.number.precision(.fractionLength(0))) + "%")
                        .fontWeight(.semibold)
                    if let countdown = self.row.countdown { Text("· " + countdown).foregroundStyle(.secondary) }
                }
                if let pace = self.row.pace {
                    Text(WindowPace.paceText(reservePercent: pace.reservePercent))
                        .font(.system(size: 10))
                        .foregroundStyle(pace.reservePercent.rounded() < 0 ? Color(nsColor: .systemOrange) : .secondary)
                }
            }
            .frame(minWidth: 92, alignment: .trailing)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.summary)
    }

    var summary: String {
        let usage = L(
            self.showUsed ? "pace_row_used_format" : "pace_row_remaining_format",
            ProviderDescriptorRegistry.descriptor(for: self.provider).metadata.displayName,
            self.row.label,
            self.row.fillPercent)
        let pace = self.row.pace.map { WindowPace.paceText(reservePercent: $0.reservePercent) }
        let reset = self.row.countdown.map { L("pace_resets_in_format", $0) }
        return [usage, pace, reset].compactMap(\.self).joined(separator: ", ")
    }
}

struct PaceSharedChart: View {
    let series: [PaceChartSeries]
    let windowClass: WindowPace.WindowClass
    let providers: [PaceProviderBlock]

    var body: some View {
        PaceChartPlot(
            series: self.series,
            colors: self.series.map { series in
                let row = self.providers.first(where: { $0.provider == series.provider })?.windows
                    .first(where: { $0.pace?.windowClass == self.windowClass })
                return PacePalette.colors(for: series.provider, role: row?.role ?? .single).fill
            },
            showsAxes: true,
            showsLabels: true)
            .frame(height: 124)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(self.summary)
    }

    var summary: String {
        let values = self.series.compactMap { series -> String? in
            guard let point = series.samples.last else { return nil }
            return L("pace_chart_point_format", series.label, point.remainingPercent, point.x * 100)
        }
        return ([L("pace_shared_chart_summary")] + values).joined(separator: ". ")
    }
}

struct PaceBurndownChart: View {
    let provider: UsageProvider
    let samples: [PaceChartPoint]
    let color: Color
    let accessibilitySummary: String
    var showsAxes = true

    var body: some View {
        PaceChartPlot(
            series: [PaceChartSeries(provider: self.provider, samples: self.samples, label: "")],
            colors: [self.color],
            showsAxes: self.showsAxes,
            showsLabels: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(self.accessibilitySummary)
    }
}

private struct PaceChartPlot: View {
    let series: [PaceChartSeries]
    let colors: [Color]
    let showsAxes: Bool
    let showsLabels: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - (self.showsAxes ? 30 : 0))
            let height = max(1, geometry.size.height - (self.showsAxes ? 16 : 0))
            let labelFrames = self.labelFrames(width: width, height: height)
            ZStack(alignment: .topLeading) {
                self.grid(width: width, height: height)
                Path { path in
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: width, y: height))
                }
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ForEach(self.series.indices, id: \.self) { index in
                    let samples = self.series[index].samples
                    Path { path in
                        for (offset, sample) in samples.enumerated() {
                            let point = self.position(sample, width: width, height: height)
                            if offset == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }
                    .stroke(self.colors[index], lineWidth: 1.5)
                    if let sample = samples.last {
                        let point = self.position(sample, width: width, height: height)
                        Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
                            .fill(self.colors[index])
                        if self.showsLabels, let frame = labelFrames[index] {
                            Text(L("pace_chart_label_format", self.series[index].label, sample.remainingPercent))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color(nsColor: PaceChartLabelLayout.textColor))
                                .lineLimit(1)
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                if self.showsAxes { self.axes(width: width, height: height) }
            }
        }
    }

    private func position(_ point: PaceChartPoint, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(x: width * point.x, y: height * (1 - point.remainingPercent / 100))
    }

    private func labelFrames(width: CGFloat, height: CGFloat) -> [CGRect?] {
        guard self.showsLabels else { return [] }
        let plot = CGRect(x: 0, y: 0, width: width, height: height)
        return PaceChartLabelLayout.place(
            points: self.series.map { series in
                series.samples.last.map { self.position($0, width: width, height: height) }
            },
            sizes: self.series.map { series in
                PaceChartLabelLayout.size(for: L(
                    "pace_chart_label_format", series.label, series.samples.last?.remainingPercent ?? 0))
            },
            in: plot,
            avoiding: self.showsAxes ? [PaceChartLabelLayout.idealFrame(in: plot)] : [])
    }

    private func grid(width: CGFloat, height: CGFloat) -> some View {
        Path { path in
            for fraction in [0.0, 0.5, 1.0] {
                path.move(to: CGPoint(x: 0, y: height * fraction))
                path.addLine(to: CGPoint(x: width, y: height * fraction))
            }
            if self.showsAxes {
                for fraction in [0.25, 0.5, 0.75] {
                    path.move(to: CGPoint(x: width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: width * fraction, y: height))
                }
            }
        }
        .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
    }

    private func axes(width: CGFloat, height: CGFloat) -> some View {
        Group {
            ForEach([100, 50, 0], id: \.self) { value in
                Text(value.formatted())
                    .position(x: width + 17, y: max(5, height * (1 - Double(value) / 100)))
            }
            let ideal = PaceChartLabelLayout.idealFrame(in: CGRect(x: 0, y: 0, width: width, height: height))
            Text(L("pace_ideal"))
                .foregroundStyle(Color(nsColor: PaceChartLabelLayout.textColor))
                .position(x: ideal.midX, y: ideal.midY)
            HStack(spacing: 0) {
                Text(L("pace_window_start"))
                Spacer(minLength: 0)
                Text(L("pace_fraction_elapsed"))
                Spacer(minLength: 0)
                Text(L("pace_reset"))
            }
            .frame(width: width)
            .offset(y: height + 4)
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }
}

struct PaceCostSegment: Equatable {
    let provider: UsageProvider
    let usd: Double
}

struct PaceStackedBar: View {
    let segments: [PaceCostSegment]

    var body: some View {
        GeometryReader { geometry in
            let total = self.segments.reduce(0) { $0 + $1.usd }
            ZStack(alignment: .leading) {
                if let first = self.segments.first {
                    Path(roundedRect: CGRect(origin: .zero, size: geometry.size), cornerRadius: 3)
                        .fill(PacePalette.colors(for: first.provider).track)
                }
                ForEach(self.segments.indices, id: \.self) { index in
                    let segment = self.segments[index]
                    let preceding = self.segments.prefix(index).reduce(0) { $0 + $1.usd }
                    if total > 0 {
                        Path(CGRect(
                            x: geometry.size.width * preceding / total,
                            y: 0,
                            width: geometry.size.width * segment.usd / total,
                            height: geometry.size.height))
                            .fill(PacePalette.colors(for: segment.provider).fill)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

struct PaceDailyBars: View {
    let days: [PaceDayStack]
    let providers: [UsageProvider]
    var preferredCurrencyCode = "USD"
    var providerCurrencyCode = "USD"

    var body: some View {
        GeometryReader { geometry in
            let chartHeight = max(1, geometry.size.height - 14)
            let maximum = self.days.compactMap(\.totalUSD).max() ?? 0
            let step = geometry.size.width / CGFloat(max(1, self.days.count))
            let barWidth = step * (self.days.count > 7 ? 0.8 : 0.64)
            ZStack(alignment: .topLeading) {
                ForEach(self.providers, id: \.self) { provider in
                    Path { path in
                        for (index, day) in self.days.enumerated() {
                            guard maximum > 0, let value = day.costsUSD[provider] else { continue }
                            let preceding = self.providers.prefix(while: { $0 != provider })
                                .reduce(0) { $0 + (day.costsUSD[$1] ?? 0) }
                            path.addRect(CGRect(
                                x: step * (CGFloat(index) + 0.5) - barWidth / 2,
                                y: chartHeight * (1 - (preceding + value) / maximum),
                                width: barWidth,
                                height: chartHeight * value / maximum))
                        }
                    }
                    .fill(PacePalette.colors(for: provider).fill)
                }
                Path { path in
                    path.move(to: CGPoint(x: 0, y: chartHeight))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: chartHeight))
                }
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                ForEach(Array(self.days.enumerated()), id: \.element.id) { index, day in
                    if self.days.count <= 7 || index == 0 || index == self.days.count - 1 {
                        Text(self.axisLabel(for: day.date))
                            .position(x: step * (CGFloat(index) + 0.5), y: chartHeight + 9)
                    }
                    if !day.unpricedProviders.isEmpty {
                        Text("?").position(x: step * (CGFloat(index) + 0.5), y: chartHeight - 5)
                    }
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.summary)
    }

    func axisLabel(for date: Date) -> String {
        let format: Date.FormatStyle = self.days.count > 7 ? .dateTime.month(.abbreviated).day() : .dateTime.day()
        return date.formatted(format.locale(codexBarLocalizedLocale()))
    }

    private var summary: String {
        self.days.map { day in
            let date = day.date.formatted(.dateTime.month(.abbreviated).day().locale(codexBarLocalizedLocale()))
            let amounts = self.providers.compactMap { provider -> String? in
                let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
                if let usd = day.costsUSD[provider] {
                    let value = UsageFormatter.convertedCostString(
                        usd, preferredCurrency: self.preferredCurrencyCode, providerCurrency: self.providerCurrencyCode)
                    return name + " " + value
                }
                return day.unpricedProviders.contains(provider) ? name + " " + L("pace_unpriced") : nil
            }
            return ([date] + amounts).joined(separator: ", ")
        }.joined(separator: ". ")
    }
}

struct PaceChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Text(self.title)
                .font(.system(size: 11))
                .foregroundStyle(self.isSelected ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(self.isSelected ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }
}

struct PaceKeyValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(self.title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(self.value).fontWeight(.semibold).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

struct PaceFooter: View {
    let onAction: (MenuDescriptor.MenuAction) -> Void

    var body: some View {
        HStack(spacing: 4) {
            self.button(L("Refresh"), shortcut: "⌘R", action: .refresh)
            self.button(L("Settings..."), shortcut: "⌘,", action: .settings)
            self.button(L("About"), action: .about)
            self.button(L("Quit"), shortcut: "⌘Q", action: .quit)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func button(_ title: String, shortcut: String? = nil, action: MenuDescriptor.MenuAction) -> some View {
        Button { self.onAction(action) } label: {
            HStack(spacing: 3) {
                Text(title).lineLimit(1).fixedSize()
                if let shortcut { Text(shortcut).foregroundStyle(.tertiary).lineLimit(1).fixedSize() }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
