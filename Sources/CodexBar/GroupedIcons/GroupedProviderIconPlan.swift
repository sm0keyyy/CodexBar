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

    static func level(windows: [(remainingPercent: Double, thresholds: [Int])]) -> Level {
        windows.reduce(.none) { worst, window in
            let active = QuotaWarningThresholds.active(window.thresholds)
            guard let low = active.min(), let high = active.max() else { return worst }
            let level: Level = window.remainingPercent <= Double(low) ? .red
                : window.remainingPercent <= Double(high) ? .amber : .none
            return max(worst, level)
        }
    }
}

struct GroupedPillState: Equatable {
    var hasData = false
    var stale = false
    var refreshing = false
    var warning: GroupedTileWarning.Level = .none
    var flash = false
    var updatedAt: Date?
    var failure: String?
    var providerStatus: ProviderStatusIndicator = .none

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
            ? .red : self.warning
    }

    func reason(provider: UsageProvider, now: Date) -> Reason? {
        let name = L(ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName)
        if let failure {
            return Reason(
                text: L("pace_tooltip_unknown_format", name, failure), cue: .error, fix: .retry, dashed: self.flash)
        }
        if self.providerStatus != .none, self.providerStatus != .unknown {
            return Reason(
                text: L("pace_state_provider_down_format", name), cue: .error, fix: .retry, dashed: self.flash)
        }
        if !self.hasData {
            return Reason(text: L("pace_state_no_data_format", name), cue: .noData, fix: .settings)
        }
        switch self.warning {
        case .amber:
            return Reason(
                text: L("pace_state_warning_format", name), cue: .warning, fix: nil, dashed: self.flash)
        case .red:
            return Reason(
                text: L("pace_state_critical_format", name), cue: .error, fix: nil, dashed: self.flash)
        case .none: break
        }
        if self.flash {
            return Reason(text: L("pace_state_warning_format", name), cue: .warning, fix: nil, dashed: true)
        }
        if self.stale {
            let text = self.updatedAt.map {
                L(
                    "pace_state_stale_format",
                    name,
                    UsageFormatter.resetCountdownDuration(from: now, now: min(now, $0)))
            } ?? L("pace_state_refresh_failed_format", name)
            return Reason(text: text, cue: .stale, fix: .retry, dashed: true)
        }
        if self.refreshing {
            return Reason(text: L("pace_state_refreshing_format", name), cue: .refreshing, fix: nil, dashed: true)
        }
        return nil
    }

    func explanation(provider: UsageProvider, now: Date) -> String? {
        self.reason(provider: provider, now: now)?.text
    }
}
