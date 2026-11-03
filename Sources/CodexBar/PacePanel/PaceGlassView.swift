import AppKit

@MainActor
final class PaceGlassView: NSVisualEffectView {
    private let tintView = PaceGlassTintView()
    private static let tint = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.black.withAlphaComponent(0.40)
            : NSColor.white.withAlphaComponent(0.50)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.material = .popover
        self.blendingMode = .behindWindow
        self.state = .active
        self.wantsLayer = true
        self.layer?.cornerRadius = 12
        self.layer?.masksToBounds = true
        self.layer?.borderWidth = 0.5
        self.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        self.tintView.wantsLayer = true
        self.tintView.frame = self.bounds
        self.tintView.autoresizingMask = [.width, .height]
        self.addSubview(self.tintView)
        self.refreshAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.refreshAppearance()
    }

    func refreshAppearance() {
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                ? NSColor.windowBackgroundColor : Self.tint
            self.tintView.layer?.backgroundColor = color.cgColor
        }
    }
}

private final class PaceGlassTintView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
