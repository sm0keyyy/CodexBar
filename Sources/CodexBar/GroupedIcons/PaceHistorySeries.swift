import CodexBarCore
import Foundation

enum PaceHistorySeries {
    static func name(
        provider: UsageProvider,
        windowID: String,
        window: RateWindow,
        now: Date) -> PlanUtilizationSeriesName
    {
        switch windowID {
        case "primary", "secondary", "tertiary": break
        default: return .init(rawValue: "extra:\(windowID)")
        }
        // Provider-specific by design: C8 names Grok credit cycles by their Weekly or Monthly label.
        if provider == .grok, windowID == "primary" {
            switch GrokProviderDescriptor.displayLabel(window: window, now: now) {
            case "Weekly": return .weekly
            case "Monthly": return .monthly
            default: return "credits"
            }
        }
        let snapshot = UsageSnapshot(
            primary: windowID == "primary" ? window : nil,
            secondary: windowID == "secondary" ? window : nil,
            tertiary: windowID == "tertiary" ? window : nil,
            updatedAt: now)
        let presentation = ProviderDescriptorRegistry.descriptor(for: provider).presentation
        if let series = presentation.planUtilizationSeries(snapshot: snapshot), series.count == 1,
           let name = series.first
        {
            switch presentation.normalizePlanUtilizationSeries(name, windowMinutes: window.windowMinutes ?? 0) {
            case .session: return .session
            case .weekly: return .weekly
            case .tertiary: return .opus
            case .monthly: return .monthly
            }
        }
        if windowID == "tertiary" { return .opus }
        if window.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes { return .monthly }
        return window.windowMinutes.map { $0 <= 1440 ? .session : .weekly }
            ?? (windowID == "primary" ? .session : .weekly)
    }

    static func sampleDurationMinutes(
        window: RateWindow, windowID: String, provider: UsageProvider, now: Date) -> Int?
    {
        // Provider-specific by design: C8 resolves Grok's untyped primary cycle but keeps other durations raw.
        provider == .grok && windowID == "primary"
            ? WindowPace.durationMinutes(window: window, provider: provider, now: now) : window.windowMinutes
    }
}
