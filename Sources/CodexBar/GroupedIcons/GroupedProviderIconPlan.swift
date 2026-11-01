import CodexBarCore

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
        windows.sort { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) }
        return Quota(shortest: windows.first, longest: windows.count > 1 ? windows.last : nil)
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
