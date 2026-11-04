import CodexBarCore
import Foundation

enum GroupedProviderIconPlan {
    static func tiles(enabled: Bool, shouldMergeIcons: Bool, providers: [ProviderInstanceID], limit: Int = 6)
        -> [UsageProvider]?
    {
        guard enabled, shouldMergeIcons else { return nil }
        let tiles = Array(providers.compactMap(\.firstPartyProvider).prefix(limit))
        return tiles.count >= 2 ? tiles : nil
    }

    struct Quota {
        let shortest: RateWindow?
        let longest: RateWindow?

        var signature: String {
            (self.shortest?.remainingPercent.description ?? "nil")
                + "/" + (self.longest?.remainingPercent.description ?? "nil")
        }
    }

    static func quota(snapshot: UsageSnapshot?) -> Quota {
        guard let snapshot else { return Quota(shortest: nil, longest: nil) }
        var windows = [snapshot.primary, snapshot.secondary, snapshot.tertiary].compactMap { $0?.measured }
        for extra in snapshot.extraRateWindows ?? [] where extra.usageKnown {
            if let window = extra.window.measured { windows.append(window) }
        }
        windows.removeAll { !$0.usedPercent.isFinite }
        guard let first = windows.first else { return Quota(shortest: nil, longest: nil) }
        var shortest = first
        var longest = first
        if let secondary = snapshot.secondary?.measured, secondary.usedPercent.isFinite {
            longest = secondary
        }
        // Equal-duration model-specific lanes must not replace the authoritative provider windows.
        for window in windows {
            if (window.windowMinutes ?? 0) < (shortest.windowMinutes ?? 0) { shortest = window }
            if (window.windowMinutes ?? 0) > (longest.windowMinutes ?? 0) { longest = window }
        }
        return Quota(shortest: shortest, longest: windows.count > 1 ? longest : nil)
    }
}

enum GroupedTileWarning {
    enum Level: Int, Comparable {
        case none, amber, red
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Detail: Equatable {
        enum Cause: Equatable {
            case low
            case behind(Double)
        }

        let remainingPercent: Double
        let threshold: Int
        let windowLabel: String
        let cause: Cause
    }

    static func make(
        window: RateWindow, provider: UsageProvider, thresholds: [Int], label: String, now: Date) -> Detail?
    {
        guard !window.isSyntheticPlaceholder, window.usedPercent.isFinite else { return nil }
        let active = QuotaWarningThresholds.active(thresholds)
        guard let low = active.min(), let high = active.max() else { return nil }
        if window.remainingPercent <= Double(low) {
            return Detail(
                remainingPercent: window.remainingPercent, threshold: low, windowLabel: label, cause: .low)
        }
        guard window.remainingPercent <= Double(high),
              let pace = WindowPace.make(window: window, provider: provider, now: now),
              pace.reservePercent < 0 else { return nil }
        return Detail(
            remainingPercent: window.remainingPercent,
            threshold: high,
            windowLabel: label,
            cause: .behind(-pace.reservePercent))
    }
}

struct GroupedPillState: Equatable {
    var hasData = false
    var stale = false
    var refreshing = false
    var warning: GroupedTileWarning.Detail?
    var updatedAt: Date?
    var failure: String?
    var providerStatus: ProviderStatusIndicator = .none
    var authenticationFailed = false

    func usageIsTooOld(now: Date) -> Bool {
        self.hasData && self.updatedAt.map { now.timeIntervalSince($0) > 3600 } == true
    }

    func isGray(now: Date) -> Bool {
        self.authenticationFailed || self.usageIsTooOld(now: now)
    }

    var staleDeadline: Date? {
        guard self.hasData, !self.authenticationFailed, let updatedAt else { return nil }
        return updatedAt.addingTimeInterval(3600.05)
    }

    enum Cue: Equatable {
        case warning, error, stale, refreshing, noData
    }

    struct Reason: Equatable {
        let text: String
        let cue: Cue
        let fix: Fix?
        var dashed = false
    }

    enum Fix: Equatable {
        case retry, settings

        var title: String {
            switch self {
            case .retry: L("codex_workspaces_retry")
            case .settings: L("pace_open_settings")
            }
        }
    }

    var outlineWarning: GroupedTileWarning.Level {
        self.failure != nil || (self.providerStatus != .none && self.providerStatus != .unknown)
            ? .red : (self.warning == nil ? .none : .amber)
    }

    private func captureDescription(now: Date) -> String {
        guard self.hasData else { return L("pace_state_no_usage_shown") }
        guard let updatedAt else { return L("pace_state_capture_unknown") }
        let duration = UsageFormatter.resetCountdownDuration(from: now, now: min(now, updatedAt))
        return L("pace_state_capture_age_format", duration == "now" ? L("%@m", "0") : duration)
    }

    func reason(provider: UsageProvider, now: Date) -> Reason? {
        let name = L(ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName)
        if let failure {
            return Reason(
                text: L("pace_state_error_format", name, failure, self.captureDescription(now: now)),
                cue: .error,
                fix: .retry)
        }
        if self.providerStatus != .none, self.providerStatus != .unknown {
            return Reason(
                text: L("pace_state_provider_down_format", name, self.captureDescription(now: now)),
                cue: .error,
                fix: .retry)
        }
        if !self.hasData {
            return Reason(text: L("pace_state_no_data_format", name), cue: .noData, fix: .settings)
        }
        if self.usageIsTooOld(now: now) {
            return Reason(
                text: L("pace_state_old_format", name, self.captureDescription(now: now)),
                cue: .stale,
                fix: .retry,
                dashed: true)
        }
        if let warning {
            let text = switch warning.cause {
            case .low:
                L(
                    "pace_state_low_format",
                    name,
                    L(warning.windowLabel),
                    warning.remainingPercent,
                    warning.threshold)
            case let .behind(deficit):
                L(
                    "pace_state_warning_format",
                    name,
                    L(warning.windowLabel),
                    warning.remainingPercent,
                    (deficit / 100).formatted(.percent.precision(.significantDigits(1...3))
                        .locale(codexBarLocalizedLocale())),
                    warning.threshold)
            }
            return Reason(text: text, cue: .warning, fix: nil)
        }
        if self.stale {
            return Reason(
                text: L("pace_state_refresh_failed_format", name, self.captureDescription(now: now)),
                cue: .stale,
                fix: .retry,
                dashed: true)
        }
        if self.refreshing {
            return Reason(
                text: L("pace_state_refreshing_format", name, self.captureDescription(now: now)),
                cue: .refreshing,
                fix: nil,
                dashed: true)
        }
        return nil
    }

    func explanation(provider: UsageProvider, now: Date) -> String? {
        self.reason(provider: provider, now: now)?.text
    }
}
