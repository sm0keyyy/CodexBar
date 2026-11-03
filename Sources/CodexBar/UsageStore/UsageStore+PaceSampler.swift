import CodexBarCore
import Foundation

extension UsageStore {
    var isPaceSamplerActive: Bool {
        PaceMode.isActive(settings: self.settings, store: self)
    }

    func paceSamplerSamples(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        capturedAt: Date,
        excluding existing: [PlanUtilizationSeriesSample]) -> [PlanUtilizationSeriesSample]
    {
        guard self.isPaceSamplerActive else { return [] }
        var samples: [PlanUtilizationSeriesSample] = []

        func append(_ window: RateWindow?, name: PlanUtilizationSeriesName, minutes: Int? = nil) {
            guard let window, !window.isSyntheticPlaceholder, window.usedPercent.isFinite,
                  let minutes = minutes ?? window.windowMinutes, minutes > 0
            else { return }
            let canonicalMinutes = name.canonicalWindowMinutes(minutes)
            guard !existing.contains(where: {
                $0.name == name && name.canonicalWindowMinutes($0.windowMinutes) == canonicalMinutes
            }), !samples.contains(where: { $0.name == name && $0.windowMinutes == canonicalMinutes })
            else { return }
            samples.append(PlanUtilizationSeriesSample(
                name: name,
                windowMinutes: canonicalMinutes,
                entry: PlanUtilizationHistoryEntry(
                    capturedAt: capturedAt,
                    usedPercent: UsagePercent(raw: window.usedPercent).displayClamped,
                    resetsAt: window.resetsAt)))
        }

        if provider == .grok {
            let name: PlanUtilizationSeriesName = switch GrokProviderDescriptor.displayLabel(
                window: snapshot.primary, now: capturedAt)
            {
            case "Weekly": .weekly
            case "Monthly": .monthly
            default: "credits"
            }
            if let primary = snapshot.primary {
                append(primary, name: name, minutes: WindowPace.durationMinutes(
                    window: primary, provider: provider, now: capturedAt))
            }
        } else {
            append(snapshot.primary, name: self.paceSamplerSeries(
                provider: provider, window: snapshot.primary, fallback: .session))
        }
        append(snapshot.secondary, name: self.paceSamplerSeries(
            provider: provider, window: snapshot.secondary, fallback: .weekly))
        append(snapshot.tertiary, name: provider == .opencodego ? .monthly : .opus)
        for extra in snapshot.extraRateWindows ?? [] where extra.usageKnown {
            append(extra.window, name: PlanUtilizationSeriesName(rawValue: "extra:\(extra.id)"))
        }
        return samples
    }

    nonisolated static func updatedPaceSamplerHistories(
        existingHistories: [PlanUtilizationSeriesHistory],
        samples: [PlanUtilizationSeriesSample]) -> [PlanUtilizationSeriesHistory]?
    {
        var histories = self.updatedPlanUtilizationHistories(
            existingHistories: existingHistories, samples: samples) ?? existingHistories
        for index in histories.indices {
            let history = histories[index]
            guard let duplicate = history.entries.indices.dropFirst().first(where: {
                self.planUtilizationHourBucket(for: history.entries[$0 - 1].capturedAt)
                    == self.planUtilizationHourBucket(for: history.entries[$0].capturedAt)
            }) else { continue }
            var entries = Array(history.entries[..<duplicate])
            for entry in history.entries[duplicate...] {
                if let last = entries.last,
                   self.planUtilizationHourBucket(for: last.capturedAt)
                   == self.planUtilizationHourBucket(for: entry.capturedAt)
                {
                    entries[entries.count - 1] = entry
                } else {
                    entries.append(entry)
                }
            }
            histories[index] = PlanUtilizationSeriesHistory(
                name: history.name, windowMinutes: history.windowMinutes, entries: entries)
        }
        return histories == existingHistories ? nil : histories
    }

    private func paceSamplerSeries(
        provider: UsageProvider,
        window: RateWindow?,
        fallback: PlanUtilizationSeriesName) -> PlanUtilizationSeriesName
    {
        if provider == .claude || provider == .opencodego { return fallback }
        guard let minutes = window?.windowMinutes, minutes > 0 else { return fallback }
        if minutes == ProviderPaceCapability.monthlyWindowSentinelMinutes { return .monthly }
        return minutes <= 1440 ? .session : .weekly
    }
}
