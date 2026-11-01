import AppKit
import CodexBarCore

extension StatusItemController {
    private struct GroupedTile {
        let provider: UsageProvider
        let snapshot: UsageSnapshot?
        let style: IconStyle
        var primary: Double?
        var weekly: Double?
        var credits: Double?
        var stale: Bool
        var morph: Double?
        let blink: CGFloat
        let wiggle: CGFloat
        let tilt: CGFloat
        let status: ProviderStatusIndicator
        let warning: GroupedTileWarning.Level
        let tint: NSColor?
        let flash: Bool

        var signature: String {
            [
                self.provider.rawValue,
                self.style.rawValue,
                "primary=\(self.primary.map { String($0) } ?? "nil")",
                "weekly=\(self.weekly.map { String($0) } ?? "nil")",
                "credits=\(self.credits.map { String($0) } ?? "nil")",
                "stale=\(self.stale)",
                "morph=\(self.morph.map { String($0) } ?? "nil")",
                "blink=\(self.blink)",
                "wiggle=\(self.wiggle)",
                "tilt=\(self.tilt)",
                "status=\(self.status.rawValue)",
                "warning=\(self.warning.rawValue)",
                "tint=\(self.tint?.description ?? "template")",
                "flash=\(self.flash)",
                "measured=\(self.snapshot?.primary?.measured != nil)",
            ]
                .joined(separator: ",")
        }
    }

    private var groupedProviders: [UsageProvider]? {
        GroupedProviderIconPlan.tiles(
            enabled: self.settings.menuBarGroupsProviderIcons,
            shouldMergeIcons: self.shouldMergeIcons,
            providers: self.store.enabledFirstPartyProvidersForDisplay().map(\.instanceID),
            limit: SettingsStore.mergedOverviewProviderLimit)
    }

    func applyGroupedIconIfEnabled(button: NSStatusBarButton, phase: Double?) -> Bool? {
        guard let providers = self.groupedProviders else {
            if button.toolTip != nil {
                button.toolTip = nil
                self.lastAppliedMergedIconRenderSignature = nil
            }
            return nil
        }
        self.updateMenuBarSourceDescription(for: button, providers: providers)
        self.statusItem.length = NSStatusItem.variableLength
        let tiles = providers.map { self.groupedTile(provider: $0, phase: phase, button: button) }
        let now = Date()
        let summary = self.groupedCostSummary(now: now)
        let overBudget = summary.isOverBudget(self.settings.menuBarGroupedDailyBudgetUSD)
        var lines = summary.lines
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
            "hideCritters=\(self.settings.menuBarHidesCritters)",
            "appearance=\(button.effectiveAppearance.name.rawValue)",
            "contrast=\(self.shouldUseHighContrastStatusItemContent)",
            "scale=\(button.window?.backingScaleFactor ?? 2)",
        ] + tiles.map(\.signature))
            .joined(separator: "|")
        if signature == self.lastAppliedMergedIconRenderSignature, button.toolTip == tooltip {
            self.noteIconPerfRender(skipped: true)
            return true
        }
        var composite: NSImage?
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            var images = tiles.map { self.renderGroupedTile($0) }
            let colored = self.shouldUseHighContrastStatusItemContent || images.contains { !$0.isTemplate }
            if colored {
                let color: NSColor = self.shouldUseHighContrastStatusItemContent ? .labelColor : .controlTextColor
                images = images.map { MenuBarLayoutRenderer.attachmentImage($0, tint: color, isMonochrome: false) }
            }
            composite = GroupedProviderIconComposer.compose(
                tiles: images, backingScale: button.window?.backingScaleFactor ?? 2)
            composite?.isTemplate = !colored
        }
        guard let composite else { return false }
        self.setGroupedButtonContent(
            image: composite,
            costText: summary.displayText,
            overBudget: overBudget,
            for: button)
        button.toolTip = tooltip
        self.lastAppliedMergedIconRenderSignature = signature
        self.noteIconPerfRender(skipped: false)
        return false
    }

    func groupedTileImage(provider: UsageProvider, phase: Double?, button: NSStatusBarButton) -> NSImage {
        self.renderGroupedTile(self.groupedTile(provider: provider, phase: phase, button: button))
    }

    private func groupedTile(provider: UsageProvider, phase: Double?, button: NSStatusBarButton) -> GroupedTile {
        let snapshot = self.menuBarUsageSource(for: provider).snapshot
        let style = self.store.style(for: provider)
        let resolved = self.resolvedMenuBarIconPercents(
            provider: provider, snapshot: snapshot, style: style, showUsed: self.settings.usageBarsShowUsed)
        let loading = phase != nil && self.shouldAnimate(provider: provider)
        var tile = GroupedTile(
            provider: provider,
            snapshot: snapshot,
            style: style,
            primary: resolved?.primary,
            weekly: resolved?.secondary,
            credits: self.menuBarCreditsRemainingForIcon(provider: provider, snapshot: snapshot),
            stale: self.menuBarIsStale(for: provider),
            morph: nil,
            blink: self.loadingBlinkAmount(for: provider, style: style, phase: loading ? phase : nil),
            wiggle: self.wiggleAmount(for: provider),
            tilt: self.tiltAmount(for: provider) * .pi / 28,
            status: self.store.statusIndicator(for: provider),
            warning: self.groupedWarning(provider: provider),
            tint: self.providerTintColor(for: provider, button: button),
            flash: self.quotaWarningFlashActive(provider: provider))
        if let phase, loading {
            var pattern = self.animationPattern
            // Provider-specific by design: Claude cannot render the icon-only unbraid transition.
            if pattern == .unbraid, provider == .claude { pattern = .cylon }
            if pattern == .unbraid {
                tile.morph = pattern.value(phase: phase) / 100
                tile.primary = nil
                tile.weekly = nil
            } else {
                tile.primary = max(pattern.value(phase: phase), Self.loadingPercentEpsilon)
                tile.weekly = max(pattern.value(phase: phase + pattern.secondaryOffset), Self.loadingPercentEpsilon)
            }
            tile.credits = nil
            tile.stale = false
        }
        return tile
    }

    private func renderGroupedTile(_ tile: GroupedTile) -> NSImage {
        let image: NSImage = if let morph = tile.morph {
            IconRenderer.makeMorphIcon(
                progress: morph,
                style: tile.style,
                hideCritters: self.settings.menuBarHidesCritters)
        } else {
            IconRenderer.makeIcon(
                primaryRemaining: tile.primary,
                weeklyRemaining: tile.weekly,
                creditsRemaining: tile.credits,
                stale: tile.stale,
                style: tile.style,
                blink: tile.blink,
                wiggle: tile.wiggle,
                tilt: tile.tilt,
                statusIndicator: tile.status,
                hideCritters: self.settings.menuBarHidesCritters,
                quotaLayoutPolicy: .provider(tile.provider, snapshot: tile.snapshot))
        }
        let tint: NSColor? = switch tile.warning {
        case .red: .systemRed
        case .amber: .systemOrange
        case .none: tile.tint
        }
        let tinted = tint.map { MenuBarLayoutRenderer.attachmentImage(image, tint: $0, isMonochrome: false) } ?? image
        return tile.flash ? Self.quotaWarningFlashImage(base: tinted) : tinted
    }

    func groupedWarning(provider: UsageProvider) -> GroupedTileWarning.Level {
        guard let snapshot = self.menuBarUsageSource(for: provider).snapshot else { return .none }
        var windows: [(remainingPercent: Double, thresholds: [Int])] = []
        for (kind, window) in [(QuotaWarningWindow.session, snapshot.primary), (.weekly, snapshot.secondary)] {
            guard self.settings.quotaWarningEnabled(provider: provider, window: kind),
                  let window, !window.isSyntheticPlaceholder else { continue }
            // Provider-specific by design: Claude's primary must represent a session to warn as one.
            if provider == .claude, kind == .session, !UsageStore.isSessionWindow(window) { continue }
            windows.append((
                window.remainingPercent,
                self.settings.resolvedQuotaWarningThresholds(provider: provider.instanceID, window: kind)))
        }
        return GroupedTileWarning.level(windows: windows)
    }

    private func groupedCostInputs(now: Date) -> [GroupedDailyCost.ProviderCostInput] {
        guard self.settings.costUsageEnabled else { return [] }
        return self.store.enabledFirstPartyProvidersForDisplay().compactMap { provider in
            guard !self.menuBarUsageSource(for: provider).isFleet else { return nil }
            let value: GroupedDailyCost.Value
                // Provider-specific by design: Grok cost follows CodeBurn's method.
                = if provider == .grok
            {
                GrokDailyCostCache.shared.today.map {
                    .estimate($0.usd, unpricedModels: $0.unpricedModels)
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
        // Provider-specific by design: Grok alone needs the CodeBurn log scan, including beyond the tile cap.
        if self.settings.costUsageEnabled, self.store.enabledFirstPartyProvidersForDisplay().contains(.grok) {
            GrokDailyCostCache.shared.refreshIfNeeded(now: now)
        }
        let costs = self.groupedCostInputs(now: now).map {
            "\($0.name)=\(String(describing: $0.value))"
        }.joined(separator: ",")
        return ([
            "grouped=1",
            "visible=\(self.store.enabledProvidersForDisplay().map(\.rawValue).joined(separator: ","))",
            "showUsed=\(self.settings.usageBarsShowUsed)",
            "hideCritters=\(self.settings.menuBarHidesCritters)",
            "colorByProvider=\(self.settings.menuBarColorByProvider)",
            "needsAnimation=\(self.needsMenuBarIconAnimation())",
            "costs=\(costs)",
            "grok=\(String(describing: GrokDailyCostCache.shared.today))",
            "day=\(Calendar.current.startOfDay(for: now).timeIntervalSince1970)",
            "budget=\(self.settings.menuBarGroupedDailyBudgetUSD)",
            "costEnabled=\(self.settings.costUsageEnabled)",
            "currency=\(self.settings.preferredCurrencyCode)",
        ] + providers.map {
            self.providerStoreIconObservationSignature(for: $0.instanceID, showBrandPercent: false)
                + "warning=\(self.groupedWarning(provider: $0).rawValue)"
        }).joined(separator: "|")
    }

    func setGroupedButtonContent(image: NSImage, costText: String?, overBudget: Bool, for button: NSStatusBarButton) {
        // Clear a previous amber attributed title before returning to native system text.
        button.attributedTitle = NSAttributedString()
        self.setButtonContent(image: image, title: costText, tint: nil, for: button)
        guard overBudget, let costText else { return }
        let title = Self.buttonTitle(
            costText,
            hasImage: true,
            isDebugApp: Self.isDebugApp(bundleIdentifier: Bundle.main.bundleIdentifier))
        if self.shouldUseHighContrastStatusItemContent {
            let attributed = NSMutableAttributedString(attributedString: Self.highContrastButtonTitle(
                image: image,
                title: title))
            attributed.addAttribute(
                .foregroundColor,
                value: NSColor.systemOrange,
                range: NSRange(location: 1, length: attributed.length - 1))
            button.attributedTitle = attributed
        } else {
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.systemOrange, .font: NSFont.menuBarFont(ofSize: 0),
            ])
        }
    }
}
