import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    func attachPacePanelIfActive() -> Bool {
        guard PaceMode.isActive(settings: self.settings, store: self.store) else {
            self.detachPacePanel()
            return false
        }
        guard let button = self.statusItem.button else { return false }
        if let attachment = self.pacePanelAttachment, attachment.button !== button {
            self.detachPacePanel()
        }
        self.statusItem.menu = nil
        self.mergedMenu = nil
        if self.pacePanelAttachment == nil {
            let attachment = PacePanelAttachment(button: button)
            let host = PacePanelHost(content: { [weak self] in
                self?.makePacePanelContent() ?? AnyView(EmptyView())
            }, onClose: { [weak button] in button?.highlight(false) })
            host.shortcuts = { [weak self] in
                self?.settings.providerSwitcherShortcuts ?? ProviderSwitcherShortcuts.defaults
            }
            host.onCommand = { [weak self] command in self?.performPacePanelCommand(command) }
            host.log = { [weak self] message in self?.menuLogger.verbose(message) }
            attachment.host = host
            self.pacePanelAttachment = attachment
        }
        button.target = self
        button.action = #selector(self.togglePacePanel(_:))
        _ = button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        return true
    }

    func detachPacePanel() {
        guard let attachment = self.pacePanelAttachment else { return }
        attachment.host?.close()
        if let button = attachment.button {
            button.target = attachment.previousTarget
            button.action = attachment.previousAction
            _ = button.sendAction(on: attachment.previousEventMask)
            button.highlight(false)
        }
        self.pacePanelAttachment = nil
    }

    @objc private func togglePacePanel(_ sender: NSStatusBarButton) {
        guard self.attachPacePanelIfActive(), let host = self.pacePanelAttachment?.host else { return }
        if !host.isOpen { self.store.noteMenuOpened() }
        host.toggle(anchor: sender)
    }

    func makePacePanelContent() -> AnyView {
        _ = self.store.menuObservationToken
        _ = self.settings.menuObservationToken
        _ = self.store.planUtilizationHistoryRevision
        let input = self.makePacePanelInput(now: Date())
        let model = PacePanelModel.make(input)
        let selection = PacePanelTab.resolve(
            providers: input.providers,
            lastSelectedWasOverview: self.settings.mergedMenuLastSelectedWasOverview,
            selectedProvider: self.settings.selectedMenuProvider?.firstPartyProvider)
        let context = selection.provider.map { provider in
            PaceProviderTabContext(
                card: self.store.menuCardModel(for: provider),
                menu: self.makeMenuDescriptor(provider: provider, includeContextualActions: true),
                accountCount: provider == .codex ? self.settings.codexVisibleAccounts.count
                    : self.settings.tokenAccounts(for: provider).count,
                error: self.store.userFacingError(for: provider))
        }
        return AnyView(PacePanelRootView(
            input: input,
            model: model,
            selection: selection,
            providerContext: context,
            onCommand: { [weak self] in self?.performPacePanelCommand($0) },
            onAction: { [weak self] in self?.performPacePanelAction($0) }))
    }

    func makePacePanelInput(now: Date) -> PacePanelInput {
        let providers = self.groupedProviders ?? []
        var input = PacePanelInput(
            providers: providers,
            todayCostInputs: self.groupedCostInputs(now: now),
            showUsed: self.settings.usageBarsShowUsed,
            costEnabled: self.settings.costUsageEnabled,
            preferredCurrencyCode: self.settings.preferredCurrencyCode,
            dailyBudgetUSD: self.settings.menuBarGroupedDailyBudgetUSD,
            now: now)
        input.isReloading = input.todayCostInputs.contains { $0.value == .loading }
            || providers.contains {
                GroupedProviderIconPlan.quota(snapshot: self.menuBarUsageSource(for: $0).snapshot).shortest == nil
                    || self.isRefreshingLocalMenuBarUsage($0)
            }
        if let button = self.statusItem.button, let owner = GroupedTooltipOwner.attached(to: button) {
            let slot = owner.costSlot.resolve(
                inputs: input.todayCostInputs,
                isReloading: input.isReloading,
                preferredCurrency: input.preferredCurrencyCode,
                now: now)
            if slot.dimmed { input.retainedTodayTotalUSD = slot.totalUSD }
        }
        for provider in providers {
            input.snapshots[provider] = self.store.snapshot(for: provider.instanceID)
            input.histories[provider] = self.store.planUtilizationHistorySelection(
                for: provider, readOnly: true).histories
            if input.costEnabled {
                input.tokenSnapshots[provider] = self.tokenSnapshotForCostHistorySubmenu(provider: provider)
            }
        }
        return input
    }

    func performPacePanelCommand(_ command: PacePanelCommand) {
        switch command {
        case .close:
            self.pacePanelAttachment?.host?.close()
        case .refresh:
            self.refreshNow()
        case .settings:
            self.pacePanelAttachment?.host?.close()
            self.showSettingsGeneral()
        case .quit:
            self.pacePanelAttachment?.host?.close()
            self.quit()
        case let .selectTab(index):
            self.selectPacePanelTab(at: index)
        case .previousTab, .nextTab:
            let providers = self.groupedProviders ?? []
            let selection = PacePanelTab.resolve(
                providers: providers,
                lastSelectedWasOverview: self.settings.mergedMenuLastSelectedWasOverview,
                selectedProvider: self.settings.selectedMenuProvider?.firstPartyProvider)
            let selected = selection.provider.flatMap { providers.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            let count = providers.count + 1
            self.selectPacePanelTab(at: (selected + (command == .nextTab ? 1 : count - 1)) % count)
        }
    }

    func performPacePanelAction(_ action: MenuDescriptor.MenuAction) {
        if case .refresh = action {
            self.refreshNow()
            return
        }
        self.pacePanelAttachment?.host?.close()
        let (selector, representedObject) = self.selector(for: action)
        let item = NSMenuItem()
        item.representedObject = representedObject
        self.lastMenuProvider = self.settings.selectedMenuProvider
        _ = NSApp.sendAction(selector, to: self, from: item)
    }

    private func selectPacePanelTab(at index: Int) {
        let providers = self.groupedProviders ?? []
        guard (0...providers.count).contains(index) else { return }
        self.settings.mergedMenuLastSelectedWasOverview = index == 0
        if index > 0 { self.settings.selectedMenuProvider = providers[index - 1].instanceID }
        self.pacePanelAttachment?.host?.refreshContent()
    }

    private var pacePanelAttachment: PacePanelAttachment? {
        get { objc_getAssociatedObject(self, &PacePanelAttachment.key) as? PacePanelAttachment }
        set { objc_setAssociatedObject(self, &PacePanelAttachment.key, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

@MainActor
private final class PacePanelAttachment {
    static var key: UInt8 = 0
    weak var button: NSStatusBarButton?
    weak var previousTarget: AnyObject?
    let previousAction: Selector?
    let previousEventMask: NSEvent.EventTypeMask
    var host: PacePanelHost<AnyView>?

    init(button: NSStatusBarButton) {
        self.button = button
        self.previousTarget = button.target as AnyObject?
        self.previousAction = button.action
        self.previousEventMask = NSEvent.EventTypeMask(rawValue: UInt64(
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])))
    }
}
