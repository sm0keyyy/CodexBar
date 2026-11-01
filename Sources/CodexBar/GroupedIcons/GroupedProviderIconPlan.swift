import CodexBarCore

enum GroupedProviderIconPlan {
    static func tiles(enabled: Bool, shouldMergeIcons: Bool, providers: [ProviderInstanceID], limit: Int = 6)
        -> [UsageProvider]?
    {
        guard enabled, shouldMergeIcons else { return nil }
        let tiles = Array(providers.compactMap(\.firstPartyProvider).prefix(limit))
        return tiles.count >= 2 ? tiles : nil
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
