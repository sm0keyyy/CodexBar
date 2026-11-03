import CodexBarCore
import Foundation

struct WindowPace: Equatable, Sendable {
    enum WindowClass: Sendable {
        case session, weekly
    }

    struct TickLane: Equatable, Sendable {
        let pace: WindowPace
        let resetsAt: Date
        let showUsed: Bool
    }

    let durationMinutes: Int
    let fractionElapsed: Double
    let remainingPercent: Double

    var idealRemainingPercent: Double {
        100 * (1 - self.fractionElapsed)
    }

    var reservePercent: Double {
        self.remainingPercent - self.idealRemainingPercent
    }

    var windowClass: WindowClass {
        self.durationMinutes <= 1440 ? .session : .weekly
    }

    static func make(window: RateWindow, provider: UsageProvider, now: Date) -> WindowPace? {
        guard !window.isSyntheticPlaceholder, window.usedPercent.isFinite,
              let resetsAt = window.resetsAt,
              let minutes = self.durationMinutes(window: window, provider: provider, now: now)
        else { return nil }
        let duration = Double(minutes) * 60
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0, remaining <= duration else { return nil }
        return WindowPace(
            durationMinutes: minutes,
            fractionElapsed: 1 - remaining / duration,
            remainingPercent: UsagePercent(raw: 100 - window.usedPercent).displayClamped)
    }

    static func durationMinutes(window: RateWindow, provider: UsageProvider, now: Date) -> Int? {
        let resolved = ProviderDescriptorRegistry.descriptor(for: provider).pace.resolvedResetWindowForPace(window)
        if let minutes = resolved.windowMinutes, minutes > 0 { return minutes }
        // Provider-specific by design: C2 fixes an untyped Grok Weekly cycle at 10,080 minutes.
        if provider == .grok, GrokProviderDescriptor.displayLabel(window: window, now: now) == "Weekly" {
            return 10080
        }
        return nil
    }

    func tickPercent(showUsed: Bool) -> Double {
        showUsed ? 100 * self.fractionElapsed : self.idealRemainingPercent
    }

    static func paceText(reservePercent: Double) -> String {
        let rounded = reservePercent.rounded(.toNearestOrAwayFromZero)
        return rounded < 0 ? L("pace_behind_format", abs(rounded)) : L("pace_ahead_format", abs(rounded))
    }

    static func nextTickPixelMove(ticks: [TickLane], backingScale: CGFloat, now: Date) -> Date? {
        guard backingScale.isFinite, backingScale > 0 else { return nil }
        let scale = Double(backingScale)
        var earliest: Date?
        for tick in ticks {
            let duration = Double(tick.pace.durationMinutes) * 60
            let remaining = tick.resetsAt.timeIntervalSince(now)
            guard duration > 0, remaining > 0, remaining <= duration else { continue }
            let fraction = tick.showUsed ? 1 - remaining / duration : remaining / duration
            let position = (0.5 + 23 * fraction) * scale
            let boundary: Double
            if scale <= 1 {
                let column = min(22, max(1, floor(position)))
                guard tick.showUsed ? column < 22 : column > 1 else { continue }
                boundary = tick.showUsed ? column + 1 : column
            } else {
                let center = min(ceil(23.5 * scale), max(ceil(0.5 * scale), position.rounded()))
                guard tick.showUsed ? center < ceil(23.5 * scale) : center > ceil(0.5 * scale)
                else { continue }
                boundary = center + (tick.showUsed ? 0.5 : -0.5)
            }
            let targetFraction = (boundary / scale - 0.5) / 23
            let remainingFraction = tick.showUsed ? 1 - targetFraction : targetFraction
            let boundaryDate = tick.resetsAt.addingTimeInterval(-remainingFraction * duration)
            // A leftward tick changes columns just after the rounding boundary, not at the tie.
            let next = Date(timeIntervalSinceReferenceDate: boundaryDate.timeIntervalSinceReferenceDate.nextUp)
            guard next > now, next < tick.resetsAt else { continue }
            earliest = min(earliest ?? next, next)
        }
        return earliest
    }
}
