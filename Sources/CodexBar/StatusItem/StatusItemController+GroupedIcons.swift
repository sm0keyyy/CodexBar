import AppKit
import CodexBarCore

extension StatusItemController {
    private struct GroupedTile {
        let provider: UsageProvider
        let quota: GroupedProviderIconPlan.Quota
        let state: GroupedPillState
        let tint: NSColor
        let primaryTick: WindowPace.TickLane?
        let secondaryTick: WindowPace.TickLane?

        func signature(backingScale: CGFloat) -> String {
            let columns = [self.primaryTick, self.secondaryTick].map { tick in
                tick.flatMap {
                    GroupedProviderIconComposer.tickColumns(
                        percent: $0.pace.tickPercent(showUsed: $0.showUsed), backingScale: backingScale)
                }.map(String.init(describing:)) ?? "nil"
            }
            return "\(self.provider.rawValue),quota=\(self.quota.signature),stale=\(self.state.stale)"
                + ",loading=\(self.state.refreshing),warning=\(self.state.outlineWarning.rawValue)"
                + ",tint=\(self.tint),flash=\(self.state.flash)"
                + ",ticks=\(columns.joined(separator: ","))"
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
        guard PaceMode.isActive(settings: self.settings, store: self.store),
              let providers = self.groupedProviders
        else {
            if GroupedTooltipOwner.attached(to: button) != nil {
                GroupedTooltipOwner.detach(from: button)
                button.alignment = .center
                button.font = NSFont.menuBarFont(ofSize: 0)
                self.lastAppliedMergedIconRenderSignature = nil
            }
            return nil
        }
        self.updateMenuBarSourceDescription(for: button, providers: providers)
        let now = Date()
        let scale = button.window?.backingScaleFactor ?? 2
        let tiles = providers.map { self.groupedTile(provider: $0, now: now) }
        let owner = GroupedTooltipOwner.attach(to: button) { [weak self] in self?.groupedTooltip(now: Date()) }
        let ticks = tiles.flatMap { [$0.primaryTick, $0.secondaryTick].compactMap(\.self) }
        owner
            .scheduleTick(
                at: WindowPace.nextTickPixelMove(ticks: ticks, backingScale: scale, now: now),
                now: now)
            { [weak self] in
                guard let self, !self.hasPreparedForAppShutdown else { return }
                self.updateIcons()
            }
        owner.refresh()
        let costInputs = self.groupedCostInputs(now: now)
        let slot = owner.costSlot.resolve(
            inputs: costInputs,
            isReloading: tiles.contains { !$0.state.hasData || $0.state.refreshing },
            preferredCurrency: self.settings.preferredCurrencyCode,
            now: now)
        let overBudget = self.settings.menuBarGroupedDailyBudgetUSD > 0
            && slot.totalUSD.map { $0 > self.settings.menuBarGroupedDailyBudgetUSD } == true
        let signature = ([
            "mode=grouped",
            "cost=\(slot.text ?? "nil")",
            "dimmed=\(slot.dimmed)",
            "showUsed=\(self.settings.usageBarsShowUsed)",
            "budget=\(overBudget)",
            "currency=\(self.settings.preferredCurrencyCode)",
            "costEnabled=\(self.settings.costUsageEnabled)",
            "appearance=\(button.effectiveAppearance.name.rawValue)",
            "contrast=\(self.shouldUseHighContrastStatusItemContent)",
            "scale=\(button.window?.backingScaleFactor ?? 2)",
        ] + tiles.map { $0.signature(backingScale: scale) })
            .joined(separator: "|")
        if signature == self.lastAppliedMergedIconRenderSignature {
            self.noteIconPerfRender(skipped: true)
            return true
        }
        var composite: NSImage?
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            composite = GroupedProviderIconComposer.compose(
                tiles: tiles.map { self.renderGroupedTile($0, backingScale: scale) },
                backingScale: scale)
        }
        guard let composite else { return false }
        self.setGroupedButtonContent(
            image: composite,
            costText: slot.text,
            overBudget: overBudget,
            dimmed: slot.dimmed,
            for: button)
        if self.settings.isVerboseLoggingEnabled {
            let readiness = costInputs.map { "\($0.name)=\($0.value.usd == nil ? 0 : 1)" }.joined(separator: " ")
            self.menuLogger.verbose("[perf] grouped-cost-ready \(readiness)")
        }
        self.lastAppliedMergedIconRenderSignature = signature
        self.noteIconPerfRender(skipped: false)
        return false
    }

    func groupedTileImage(provider: UsageProvider, button: NSStatusBarButton) -> NSImage {
        self.renderGroupedTile(
            self.groupedTile(provider: provider, now: Date()), backingScale: button.window?.backingScaleFactor ?? 2)
    }

    private func groupedTile(provider: UsageProvider, now: Date) -> GroupedTile {
        let quota = GroupedProviderIconPlan.quota(snapshot: self.menuBarUsageSource(for: provider).snapshot)
        let accent = ProviderAccentPalette.color(for: provider)
        let tint = NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)
        func tick(_ window: RateWindow?) -> WindowPace.TickLane? {
            guard !self.shouldUseHighContrastStatusItemContent, let window, let reset = window.resetsAt,
                  let pace = WindowPace.make(window: window, provider: provider, now: now) else { return nil }
            return .init(pace: pace, resetsAt: reset, showUsed: self.settings.usageBarsShowUsed)
        }
        return GroupedTile(
            provider: provider,
            quota: quota,
            state: self.groupedPillState(provider: provider, now: now),
            tint: tint,
            primaryTick: tick(quota.shortest),
            secondaryTick: tick(quota.longest))
    }

    func groupedPillState(provider: UsageProvider, now: Date = Date()) -> GroupedPillState {
        let snapshot = self.menuBarUsageSource(for: provider).snapshot
        let warning = self.groupedWarningDetail(provider: provider, now: now)
        return GroupedPillState(
            hasData: GroupedProviderIconPlan.quota(snapshot: snapshot).shortest != nil,
            stale: self.menuBarIsStale(for: provider),
            refreshing: self.isRefreshingLocalMenuBarUsage(provider),
            warning: warning,
            flash: warning != nil && self.quotaWarningFlashActive(provider: provider),
            updatedAt: snapshot?.updatedAt,
            failure: self.store.errors[provider.instanceID].flatMap { _ in
                self.store.userFacingErrorPresentation(for: provider)?.message
            },
            providerStatus: self.store.statusIndicator(for: provider))
    }

    private func renderGroupedTile(_ tile: GroupedTile, backingScale: CGFloat) -> NSImage {
        GroupedProviderIconComposer.pill(
            primary: tile.quota.shortest.map { self.settings.usageBarsShowUsed ? $0.usedPercent : $0.remainingPercent },
            secondary: tile.quota.longest
                .map { self.settings.usageBarsShowUsed ? $0.usedPercent : $0.remainingPercent },
            color: tile.tint,
            stale: tile.state.stale,
            loading: !tile.state.hasData || tile.state.refreshing,
            warning: tile.state.outlineWarning,
            flash: tile.state.flash,
            primaryTick: tile.primaryTick.map { $0.pace.tickPercent(showUsed: $0.showUsed) },
            secondaryTick: tile.secondaryTick.map { $0.pace.tickPercent(showUsed: $0.showUsed) },
            backingScale: backingScale)
    }

    func groupedTooltip(now: Date) -> String? {
        guard PaceMode.isActive(settings: self.settings, store: self.store), let providers = self.groupedProviders
        else { return nil }
        let budgetText = self.settings.costUsageEnabled && self.settings.menuBarGroupedDailyBudgetUSD > 0
            ? UsageFormatter.convertedCostString(
                self.settings.menuBarGroupedDailyBudgetUSD,
                preferredCurrency: self.settings.preferredCurrencyCode,
                providerCurrency: "USD") : nil
        var additionalLines = budgetText.map { [L("grouped_icons_tooltip_budget", $0)] } ?? []
        let hidden = self.store.enabledFirstPartyProvidersForDisplay().count - providers.count
        if hidden > 0 { additionalLines.append(L("grouped_icons_tooltip_more", hidden)) }
        return GroupedTooltipOwner.tooltip(
            providers: providers.map {
                .init(
                    provider: $0,
                    snapshot: self.menuBarUsageSource(for: $0).snapshot,
                    state: self.groupedPillState(provider: $0, now: now))
            },
            showUsed: self.settings.usageBarsShowUsed,
            costs: self.groupedCostSummary(now: now),
            additionalLines: additionalLines,
            now: now)
    }

    func groupedWarning(provider: UsageProvider, now: Date = Date()) -> GroupedTileWarning.Level {
        self.groupedWarningDetail(provider: provider, now: now) == nil ? .none : .amber
    }

    private func groupedWarningDetail(provider: UsageProvider, now: Date) -> GroupedTileWarning.Detail? {
        guard let snapshot = self.menuBarUsageSource(for: provider).snapshot else { return nil }
        let quota = GroupedProviderIconPlan.quota(snapshot: snapshot)
        let minutes = quota.shortest.flatMap {
            WindowPace.durationMinutes(window: $0, provider: provider, now: now)
        }
        let weeklyOnly = quota.longest == nil && minutes.map {
            WindowPace(durationMinutes: $0, fractionElapsed: 0, remainingPercent: 0).windowClass == .weekly
        } == true
        let session = weeklyOnly ? nil : quota.shortest
        let weekly = weeklyOnly ? quota.shortest : quota.longest
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let labels = descriptor.presentation.rateWindowLabels(
            metadata: descriptor.metadata, snapshot: snapshot, now: now)
        var warning: GroupedTileWarning.Detail?
        for (kind, window) in [(QuotaWarningWindow.session, session), (.weekly, weekly)] {
            guard self.settings.quotaWarningEnabled(provider: provider, window: kind),
                  let window, !window.isSyntheticPlaceholder else { continue }
            // Provider-specific by design: Claude's short lane must represent a session to warn as one.
            if provider == .claude, kind == .session, !UsageStore.isSessionWindow(window) { continue }
            let label = window.title
                ?? snapshot.extraRateWindows?.first(where: { $0.window == window })?.title
                ?? (window == snapshot.primary ? labels.primary : labels.secondary)
            guard let candidate = GroupedTileWarning.make(
                window: window,
                provider: provider,
                thresholds: self.settings.resolvedQuotaWarningThresholds(provider: provider.instanceID, window: kind),
                label: label,
                now: now) else { continue }
            if warning.map({ candidate.remainingPercent < $0.remainingPercent }) ?? true {
                warning = candidate
            }
        }
        return warning
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
        guard PaceMode.isActive(settings: self.settings, store: self.store),
              let providers = self.groupedProviders
        else {
            if let button = self.statusItem.button, GroupedTooltipOwner.attached(to: button) != nil {
                GroupedTooltipOwner.detach(from: button)
                self.lastAppliedMergedIconRenderSignature = nil
            }
            return nil
        }
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
            "showUsed=\(self.settings.usageBarsShowUsed)",
            "currency=\(self.settings.preferredCurrencyCode)",
        ] + providers.map {
            let quota = GroupedProviderIconPlan.quota(snapshot: self.menuBarUsageSource(for: $0).snapshot)
            return self.providerStoreIconObservationSignature(for: $0.instanceID, showBrandPercent: false)
                + "quota=\(quota.signature)"
                + "warning=\(self.groupedWarning(provider: $0).rawValue)"
                + "resets=\([quota.shortest, quota.longest].map { String(describing: $0?.resetsAt) })"
                + "durations=\([quota.shortest, quota.longest].map { String(describing: $0?.windowMinutes) })"
        }).joined(separator: "|")
    }

    func setGroupedButtonContent(
        image: NSImage, costText: String?, overBudget: Bool, dimmed: Bool, for button: NSStatusBarButton)
    {
        let width = Self.applyGroupedButtonContent(
            image: image,
            costText: costText,
            reservedCostTexts: self.settings.costUsageEnabled
                ? GroupedDailyCost.reservedDisplayTexts(preferredCurrency: self.settings.preferredCurrencyCode) : [],
            overBudget: overBudget,
            dimmed: dimmed,
            highContrast: self.shouldUseHighContrastStatusItemContent,
            isDebugApp: Self.isDebugApp(bundleIdentifier: Bundle.main.bundleIdentifier),
            for: button)
        self.statusItem.length = width
    }

    static func applyGroupedButtonContent(
        image: NSImage,
        costText: String?,
        reservedCostTexts: [String],
        overBudget: Bool = false,
        dimmed: Bool = false,
        highContrast: Bool,
        isDebugApp: Bool = false,
        for button: NSButton) -> CGFloat
    {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = Self.buttonTitle(costText, hasImage: true, isDebugApp: isDebugApp)
        let visibleTitle = title.isEmpty && !reservedCostTexts.isEmpty ? " " : title
        let ink: NSColor = overBudget ? .systemOrange : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: dimmed ? ink.withAlphaComponent(0.55) : ink,
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
        button.imagePosition = highContrast ? .noImage : .imageLeft
        // Anchor the image at the leading edge, not the center of the changing title.
        button.alignment = .left
        button.lineBreakMode = .byClipping
        let reservedWidth = reservedCostTexts.map {
            NSAttributedString(
                string: Self.buttonTitle($0, hasImage: true, isDebugApp: isDebugApp),
                attributes: attributes).size().width
        }.max() ?? NSAttributedString(string: title, attributes: attributes).size().width
        return ceil(image.size.width + reservedWidth) + 5
    }
}
