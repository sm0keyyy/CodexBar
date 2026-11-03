import AppKit
import CodexBarCore

extension StatusItemController {
    private struct GroupedTile {
        let provider: UsageProvider
        let quota: GroupedProviderIconPlan.Quota
        let stale: Bool
        let loading: Bool
        let warning: GroupedTileWarning.Level
        let tint: NSColor
        let flash: Bool

        var signature: String {
            "\(self.provider.rawValue),quota=\(self.quota.signature),stale=\(self.stale)"
                + ",loading=\(self.loading),warning=\(self.warning.rawValue),tint=\(self.tint),flash=\(self.flash)"
        }
    }

    var groupedProviders: [UsageProvider]? {
        GroupedProviderIconPlan.tiles(
            enabled: self.settings.menuBarGroupsProviderIcons,
            shouldMergeIcons: self.shouldMergeIcons,
            providers: self.store.enabledFirstPartyProvidersForDisplay().map(\.instanceID),
            limit: SettingsStore.mergedOverviewProviderLimit)
    }

    func applyGroupedIconIfEnabled(button: NSStatusBarButton, phase _: Double?) -> Bool? {
        guard let providers = self.groupedProviders else {
            if button.toolTip != nil {
                button.alignment = .center
                button.font = NSFont.menuBarFont(ofSize: 0)
                button.toolTip = nil
                self.lastAppliedMergedIconRenderSignature = nil
            }
            return nil
        }
        self.updateMenuBarSourceDescription(for: button, providers: providers)
        let tiles = providers.map { self.groupedTile(provider: $0, button: button) }
        let now = Date()
        let costInputs = self.groupedCostInputs(now: now)
        let summary = GroupedDailyCost.summary(
            inputs: costInputs, preferredCurrency: self.settings.preferredCurrencyCode)
        let overBudget = summary.isOverBudget(self.settings.menuBarGroupedDailyBudgetUSD)
        var lines = tiles.map { self.groupedQuotaDescription($0) } + summary.lines
        if self.settings.costUsageEnabled, self.settings.menuBarGroupedDailyBudgetUSD > 0 {
            let budgetText = UsageFormatter.convertedCostString(
                self.settings.menuBarGroupedDailyBudgetUSD,
                preferredCurrency: self.settings.preferredCurrencyCode,
                providerCurrency: "USD")
            lines.append(L("grouped_icons_tooltip_budget", budgetText))
        }
        let hidden = self.store.enabledFirstPartyProvidersForDisplay().count - providers.count
        if hidden > 0 { lines.append(L("grouped_icons_tooltip_more", hidden)) }
        let tooltip = lines.joined(separator: "\n")
        let signature = ([
            "mode=grouped",
            "cost=\(summary.displayText ?? "nil")",
            "budget=\(overBudget)",
            "currency=\(self.settings.preferredCurrencyCode)",
            "costEnabled=\(self.settings.costUsageEnabled)",
            "appearance=\(button.effectiveAppearance.name.rawValue)",
            "contrast=\(self.shouldUseHighContrastStatusItemContent)",
            "scale=\(button.window?.backingScaleFactor ?? 2)",
        ] + tiles.map(\.signature))
            .joined(separator: "|")
        if signature == self.lastAppliedMergedIconRenderSignature {
            if button.toolTip != tooltip { button.toolTip = tooltip }
            self.noteIconPerfRender(skipped: true)
            return true
        }
        var composite: NSImage?
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            composite = GroupedProviderIconComposer.compose(
                tiles: tiles.map { self.renderGroupedTile($0) },
                backingScale: button.window?.backingScaleFactor ?? 2)
        }
        guard let composite else { return false }
        self.setGroupedButtonContent(
            image: composite,
            costText: summary.displayText,
            overBudget: overBudget,
            for: button)
        button.toolTip = tooltip
        if self.settings.isVerboseLoggingEnabled {
            let readiness = costInputs.map { "\($0.name)=\($0.value.usd == nil ? 0 : 1)" }.joined(separator: " ")
            self.menuLogger.verbose("[perf] grouped-cost-ready \(readiness)")
        }
        self.lastAppliedMergedIconRenderSignature = signature
        self.noteIconPerfRender(skipped: false)
        return false
    }

    func groupedTileImage(provider: UsageProvider, button: NSStatusBarButton) -> NSImage {
        self.renderGroupedTile(self.groupedTile(provider: provider, button: button))
    }

    private func groupedTile(provider: UsageProvider, button: NSStatusBarButton) -> GroupedTile {
        let quota = GroupedProviderIconPlan.quota(snapshot: self.menuBarUsageSource(for: provider).snapshot)
        let stale = self.menuBarIsStale(for: provider)
        let accent = ProviderAccentPalette.color(for: provider)
        let tint = NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)
        return GroupedTile(
            provider: provider,
            quota: quota,
            stale: stale,
            loading: quota.shortest == nil || self.isRefreshingLocalMenuBarUsage(provider),
            warning: self.groupedWarning(provider: provider),
            tint: tint,
            flash: self.quotaWarningFlashActive(provider: provider))
    }

    private func renderGroupedTile(_ tile: GroupedTile) -> NSImage {
        GroupedProviderIconComposer.pill(
            primary: tile.quota.shortest?.remainingPercent,
            secondary: tile.quota.longest?.remainingPercent,
            color: tile.tint,
            stale: tile.stale,
            loading: tile.loading,
            warning: tile.warning,
            flash: tile.flash)
    }

    private func groupedQuotaDescription(_ tile: GroupedTile) -> String {
        let name = ProviderRegistry.shared.metadata[tile.provider]?.displayName ?? tile.provider.rawValue
        func describe(_ window: RateWindow) -> String {
            let label = window.title ?? ((window.windowMinutes ?? 0) >= 10080 ? L("Weekly") : L("Session"))
            let percent = (window.remainingPercent / 100).formatted(.percent.precision(.fractionLength(0...6)))
            return "\(label) \(percent)"
        }
        let values = [tile.quota.shortest, tile.quota.longest].compactMap { $0.map(describe) }
        return "\(name): \(values.isEmpty ? L("Unknown") : values.joined(separator: " · "))"
    }

    func groupedWarning(provider: UsageProvider) -> GroupedTileWarning.Level {
        guard let snapshot = self.menuBarUsageSource(for: provider).snapshot else { return .none }
        let quota = GroupedProviderIconPlan.quota(snapshot: snapshot)
        let weeklyOnly = quota.longest == nil && (quota.shortest?.windowMinutes ?? 0) >= 10080
        let session = weeklyOnly ? nil : quota.shortest
        let weekly = weeklyOnly ? quota.shortest : quota.longest
        var windows: [(remainingPercent: Double, thresholds: [Int])] = []
        for (kind, window) in [(QuotaWarningWindow.session, session), (.weekly, weekly)] {
            guard self.settings.quotaWarningEnabled(provider: provider, window: kind),
                  let window, !window.isSyntheticPlaceholder else { continue }
            // Provider-specific by design: Claude's short lane must represent a session to warn as one.
            if provider == .claude, kind == .session, !UsageStore.isSessionWindow(window) { continue }
            windows.append((
                window.remainingPercent,
                self.settings.resolvedQuotaWarningThresholds(provider: provider.instanceID, window: kind)))
        }
        return GroupedTileWarning.level(windows: windows)
    }

    func groupedCostInputs(now: Date) -> [GroupedDailyCost.ProviderCostInput] {
        guard self.settings.costUsageEnabled else { return [] }
        return self.store.enabledFirstPartyProvidersForDisplay().compactMap { provider in
            guard !self.menuBarUsageSource(for: provider).isFleet else { return nil }
            let value: GroupedDailyCost.Value
                // Provider-specific by design: Grok combines native requests, session rollups, and mirrored usage.
                = if provider == .grok
            {
                GrokDailyCostCache.shared.today.map { cost in
                    if cost.estimated || !cost.unpricedModels.isEmpty {
                        GroupedDailyCost.Value.estimate(cost.usd, unpricedModels: cost.unpricedModels)
                    } else {
                        .exact(cost.usd)
                    }
                } ?? .loading
            } else if let snapshot = self.store.tokenSnapshotForCurrentProviderConfig(for: provider)?.snapshot {
                if let usd = self.menuBarLayoutCosts(provider: provider, now: now).todayUSD {
                    .exact(usd)
                } else if CostUsageTokenSnapshot.entry(in: snapshot.daily, forLocalDayContaining: now) == nil {
                    .zero
                } else {
                    .unpriced
                }
            } else {
                .loading
            }
            return .init(
                name: ProviderRegistry.shared.metadata[provider]?.displayName ?? provider.rawValue,
                value: value)
        }
    }

    private func groupedCostSummary(now: Date) -> GroupedDailyCost.Summary {
        GroupedDailyCost.summary(
            inputs: self.groupedCostInputs(now: now),
            preferredCurrency: self.settings.preferredCurrencyCode)
    }

    func groupedStoreIconObservationSignatureIfActive() -> String? {
        guard let providers = self.groupedProviders else { return nil }
        let now = Date()
        // Provider-specific by design: refresh Grok local usage even when its tile is beyond the visible cap.
        if self.settings.costUsageEnabled, self.store.enabledFirstPartyProvidersForDisplay().contains(.grok) {
            GrokDailyCostCache.shared.refreshIfNeeded(now: now)
        }
        let costs = self.groupedCostInputs(now: now).map {
            "\($0.name)=\(String(describing: $0.value))"
        }.joined(separator: ",")
        return ([
            "grouped=1",
            "visible=\(self.store.enabledProvidersForDisplay().map(\.rawValue).joined(separator: ","))",
            "costs=\(costs)",
            "grok=\(String(describing: GrokDailyCostCache.shared.today))",
            "day=\(Calendar.current.startOfDay(for: now).timeIntervalSince1970)",
            "budget=\(self.settings.menuBarGroupedDailyBudgetUSD)",
            "costEnabled=\(self.settings.costUsageEnabled)",
            "currency=\(self.settings.preferredCurrencyCode)",
        ] + providers.map {
            let quota = GroupedProviderIconPlan.quota(snapshot: self.menuBarUsageSource(for: $0).snapshot)
            return self.providerStoreIconObservationSignature(for: $0.instanceID, showBrandPercent: false)
                + "quota=\(quota.signature)"
                + "warning=\(self.groupedWarning(provider: $0).rawValue)"
        }).joined(separator: "|")
    }

    func setGroupedButtonContent(image: NSImage, costText: String?, overBudget: Bool, for button: NSStatusBarButton) {
        let width = Self.applyGroupedButtonContent(
            image: image,
            costText: costText,
            reservedCostTexts: self.settings.costUsageEnabled
                ? GroupedDailyCost.reservedDisplayTexts(preferredCurrency: self.settings.preferredCurrencyCode) : [],
            overBudget: overBudget,
            highContrast: self.shouldUseHighContrastStatusItemContent,
            isDebugApp: Self.isDebugApp(bundleIdentifier: Bundle.main.bundleIdentifier),
            for: button)
        self.statusItem.length = self.settings.costUsageEnabled ? width : NSStatusItem.variableLength
    }

    static func applyGroupedButtonContent(
        image: NSImage,
        costText: String?,
        reservedCostTexts: [String],
        overBudget: Bool = false,
        highContrast: Bool,
        isDebugApp: Bool = false,
        for button: NSButton) -> CGFloat
    {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = Self.buttonTitle(costText, hasImage: true, isDebugApp: isDebugApp)
        let visibleTitle = title.isEmpty && !reservedCostTexts.isEmpty ? " " : title
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: overBudget ? NSColor.systemOrange : NSColor.labelColor,
        ]
        let attributed = highContrast
            ? NSMutableAttributedString(attributedString: Self.highContrastButtonTitle(
                image: image, title: visibleTitle))
            : NSMutableAttributedString(string: visibleTitle, attributes: attributes)
        if highContrast, attributed.length > 1 {
            attributed.addAttributes(attributes, range: NSRange(location: 1, length: attributed.length - 1))
        }
        button.attributedTitle = attributed
        button.image = highContrast ? nil : image
        button.imagePosition = highContrast ? .noImage : (visibleTitle.isEmpty ? .imageOnly : .imageLeft)
        // Anchor the image at the leading edge, not the center of the changing title.
        button.alignment = .left
        button.lineBreakMode = .byClipping
        let reservedWidth = reservedCostTexts.map {
            NSAttributedString(
                string: Self.buttonTitle($0, hasImage: true, isDebugApp: isDebugApp),
                attributes: attributes).size().width
        }.max() ?? NSAttributedString(string: title, attributes: attributes).size().width
        return ceil(image.size.width + reservedWidth) + 10
    }
}
