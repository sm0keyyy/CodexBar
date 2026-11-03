import AppKit
import CodexBarCore
import ObjectiveC

@MainActor
final class GroupedTooltipOwner: NSObject {
    struct ProviderWindows {
        let provider: UsageProvider
        let snapshot: UsageSnapshot?
    }

    private static var associationKey: UInt8 = 0
    private weak var button: NSStatusBarButton?
    private var trackingArea: NSTrackingArea?
    private var text: (@MainActor () -> String?)?
    private(set) var hoverTimer: Timer?
    private(set) var tickTimer: Timer?
    var costSlot = GroupedDailyCost.Slot()

    static func attached(to button: NSStatusBarButton) -> GroupedTooltipOwner? {
        objc_getAssociatedObject(button, &self.associationKey) as? GroupedTooltipOwner
    }

    static func attach(to button: NSStatusBarButton, text: @escaping @MainActor () -> String?) -> GroupedTooltipOwner {
        if let owner = self.attached(to: button) { return owner }
        let owner = GroupedTooltipOwner()
        owner.button = button
        owner.text = text
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: owner, userInfo: nil)
        owner.trackingArea = area
        button.addTrackingArea(area)
        objc_setAssociatedObject(button, &self.associationKey, owner, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return owner
    }

    static func detach(from button: NSStatusBarButton) {
        guard let owner = self.attached(to: button) else { return }
        owner.tickTimer?.invalidate()
        owner.hoverTimer?.invalidate()
        if let area = owner.trackingArea { button.removeTrackingArea(area) }
        button.toolTip = nil
        button.alignment = .center
        button.font = NSFont.menuBarFont(ofSize: 0)
        objc_setAssociatedObject(button, &self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func refresh() {
        let tooltip = self.text?()
        if self.button?.toolTip != tooltip { self.button?.toolTip = tooltip }
        if tooltip == nil { self.hoverTimer?.invalidate(); self.hoverTimer = nil }
    }

    @objc func mouseEntered(with _: NSEvent) {
        self.refresh()
        guard self.button?.toolTip != nil else { return }
        self.hoverTimer?.invalidate()
        self.hoverTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    @objc func mouseExited(with _: NSEvent) {
        self.hoverTimer?.invalidate()
        self.hoverTimer = nil
    }

    func scheduleTick(at date: Date?, now: Date, update: @escaping @MainActor () -> Void) {
        if self.tickTimer?.fireDate == date { return }
        self.tickTimer?.invalidate()
        self.tickTimer = nil
        guard let date else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickTimer = nil
                update()
            }
        }
        timer.tolerance = max(0, date.timeIntervalSince(now)) * 0.1
        self.tickTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit {
        MainActor.assumeIsolated {
            self.tickTimer?.invalidate()
            self.hoverTimer?.invalidate()
        }
    }

    static func tooltip(
        providers: [ProviderWindows],
        showUsed: Bool,
        costs: GroupedDailyCost.Summary,
        additionalLines: [String] = [],
        now: Date) -> String
    {
        var lines: [String] = []
        for entry in providers {
            let descriptor = ProviderDescriptorRegistry.descriptor(for: entry.provider)
            let name = L(descriptor.metadata.displayName)
            guard let snapshot = entry.snapshot else {
                lines.append(L("pace_tooltip_unknown_format", name, L("Unknown")))
                continue
            }
            let labels = descriptor.presentation.rateWindowLabels(
                metadata: descriptor.metadata,
                snapshot: snapshot,
                now: now)
            let quota = GroupedProviderIconPlan.quota(snapshot: snapshot)
            for window in [quota.shortest, quota.longest].compactMap(\.self) {
                let label: String = if let title = window.title {
                    title
                } else if window == snapshot.primary {
                    labels.primary
                } else if window == snapshot.secondary {
                    labels.secondary
                } else if window == snapshot.tertiary {
                    labels.tertiary
                } else {
                    snapshot.extraRateWindows?.first(where: { $0.window == window })?.title ?? labels.secondary
                }
                let usage = UsageFormatter.usageLine(
                    remaining: window.remainingPercent, used: window.usedPercent, showUsed: showUsed)
                var parts = [L("pace_tooltip_window_format", name, L(label), usage)]
                if let pace = WindowPace.make(window: window, provider: entry.provider, now: now) {
                    parts.append(WindowPace.paceText(reservePercent: pace.reservePercent))
                }
                if let reset = window.resetsAt {
                    parts.append(L(
                        "pace_tooltip_resets_format",
                        UsageFormatter.resetCountdownDuration(from: reset, now: now)))
                }
                lines.append(parts.joined(separator: " · "))
            }
            if quota.shortest == nil { lines.append(L("pace_tooltip_unknown_format", name, L("Unknown"))) }
        }
        lines += costs.lines
        lines += additionalLines
        return lines.joined(separator: "\n")
    }
}
