import AppKit

@MainActor
enum GroupedProviderIconComposer {
    static func compose(tiles: [NSImage], backingScale: CGFloat) -> NSImage? {
        guard let first = tiles.first else { return nil }
        guard tiles.count > 1 else { return first }
        var slices: [(NSBitmapImageRep, Range<Int>)] = []
        for image in tiles {
            guard let bitmap = self.rasterize(image), let data = bitmap.bitmapData else { return nil }
            let width = bitmap.pixelsWide
            var left = width
            var right = 0
            for x in 0..<width {
                for y in 0..<36 where data[y * bitmap.bytesPerRow + x * 4 + 3] > 0 {
                    left = min(left, x)
                    right = max(right, x + 1)
                }
            }
            if left == width { left = 0; right = width }
            if backingScale < 2 {
                left = left / 2 * 2
                right = (right + 1) / 2 * 2
            }
            slices.append((bitmap, left..<right))
        }
        let gap = backingScale >= 2 ? 3 : 4
        let width = slices.reduce(0) { $0 + $1.1.count } + gap * (tiles.count - 1)
        guard let bitmap = self.bitmap(width: width), let destination = bitmap.bitmapData else { return nil }
        var offset = 0
        for (source, columns) in slices {
            guard let data = source.bitmapData else { return nil }
            for y in 0..<36 {
                destination.advanced(by: y * bitmap.bytesPerRow + offset * 4)
                    .update(
                        from: data.advanced(by: y * source.bytesPerRow + columns.lowerBound * 4),
                        count: columns.count * 4)
            }
            offset += columns.count + gap
        }
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        image.isTemplate = tiles.allSatisfy(\.isTemplate)
        return image
    }

    static func rasterize(_ image: NSImage) -> NSBitmapImageRep? {
        guard let bitmap = self.bitmap(width: Int((image.size.width * 2).rounded(.up))),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(origin: .zero, size: image.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    static let tileSize = NSSize(width: 24, height: 18)
    static let pillRect = NSRect(x: 0, y: 4, width: 24, height: 10)
    static let grayInk = NSColor(srgbRed: 0.65, green: 0.65, blue: 0.65, alpha: 1)

    static func pill(
        primary: Double?,
        secondary: Double?,
        color: NSColor,
        stale: Bool,
        loading: Bool = false,
        warning: GroupedTileWarning.Level = .none,
        primaryTick: Double? = nil,
        secondaryTick: Double? = nil,
        backingScale: CGFloat = 2) -> NSImage
    {
        let (session, weekly) = self.fillColors(
            for: stale ? self.grayInk : color,
            split: secondary != nil)
        let track = self.trackColor(weekly: weekly, session: session)
        let rect = self.pillRect
        let fillRect = rect.insetBy(dx: 0.5, dy: 0)
        let halfHeight = (rect.height - 0.5) / 2
        let image = NSImage(size: self.tileSize, flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let outline = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            outline.addClip()
            track.setFill()
            rect.fill()
            let fraction = { (percent: Double) in CGFloat(min(100, max(0, percent))) / 100 }
            if let primary {
                let split = secondary != nil
                weekly.setFill()
                if split { session.setFill() }
                NSRect(
                    x: fillRect.minX,
                    y: split ? rect.midY + 0.25 : rect.minY,
                    width: fillRect.width * fraction(primary),
                    height: split ? halfHeight : rect.height).fill()
                if let secondary {
                    weekly.setFill()
                    NSRect(
                        x: fillRect.minX,
                        y: rect.minY,
                        width: fillRect.width * fraction(secondary),
                        height: halfHeight).fill()
                }
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.shouldAntialias = false
            for (usage, percent, ink, lane) in [
                (primary, primaryTick, secondary == nil ? weekly : session, NSRect(
                    x: rect.minX,
                    y: secondary == nil ? rect.minY : rect.midY + 0.25,
                    width: rect.width,
                    height: secondary == nil ? rect.height : halfHeight)),
                (secondary, secondaryTick, weekly, NSRect(
                    x: rect.minX, y: rect.minY, width: rect.width, height: halfHeight)),
            ] {
                guard let usage, let percent,
                      let columns = Self.tickColumns(percent: percent, backingScale: backingScale)
                else { continue }
                let tickX = CGFloat(columns.lowerBound) / backingScale
                let barEnd = fillRect.minX + fillRect.width * fraction(usage)
                if usage < percent, barEnd < tickX {
                    NSGraphicsContext.saveGraphicsState()
                    NSRect(x: barEnd, y: lane.minY, width: tickX - barEnd, height: lane.height).clip()
                    ink.setStroke()
                    let hatch = NSBezierPath()
                    hatch.lineWidth = 0.5
                    for x in stride(from: barEnd - lane.height, through: tickX, by: 2) {
                        hatch.move(to: NSPoint(x: x, y: lane.minY))
                        hatch.line(to: NSPoint(x: x + lane.height, y: lane.maxY))
                    }
                    hatch.stroke()
                    NSGraphicsContext.restoreGraphicsState()
                }
                (stale ? Self.grayInk : .labelColor).setFill()
                NSRect(
                    x: CGFloat(columns.lowerBound) / backingScale,
                    y: lane.minY,
                    width: CGFloat(columns.count) / backingScale,
                    height: lane.height).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            let borderColor: NSColor = switch warning {
            case .none: weekly
            case .amber: .systemOrange
            case .red: .systemRed
            }
            (stale ? weekly : borderColor).setStroke()
            let thick = !stale && primary != nil && warning != .none
            let inset: CGFloat = thick ? 0.5 : 0.25
            let border = NSBezierPath(
                roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: 5 - inset, yRadius: 5 - inset)
            border.lineWidth = thick ? 1 : 0.5
            if !stale, primary != nil, warning == .none, loading {
                border.setLineDash([1, 1], count: 2, phase: 0)
            }
            border.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    nonisolated static func tickColumns(percent: Double, backingScale: CGFloat) -> ClosedRange<Int>? {
        guard percent.isFinite, backingScale.isFinite, backingScale > 0 else { return nil }
        let x = 0.5 + 23 * min(100, max(0, percent)) / 100
        if backingScale <= 1 {
            let column = min(22, max(1, Int(floor(x))))
            return column...column
        }
        let center = Int((x * backingScale).rounded())
        let last = Int(23.5 * backingScale) - 1
        return min(last, max(1, center - 1))...min(last, max(1, center))
    }

    static func fillColors(for color: NSColor, split: Bool = true) -> (session: NSColor, weekly: NSColor) {
        let rgb = color.usingColorSpace(.sRGB)!.withAlphaComponent(1)
        var base = rgb
        if self.lab(base).l > 85 {
            for brightness in stride(from: rgb.brightnessComponent, through: 0, by: -0.025) {
                base = NSColor(
                    colorSpace: .sRGB,
                    hue: rgb.hueComponent,
                    saturation: rgb.saturationComponent,
                    brightness: brightness,
                    alpha: 1)
                if self.lab(base).l <= 85 { break }
            }
        } else if self.lab(base).l < 35 {
            for fraction in stride(from: 0.05, through: 1, by: 0.05) {
                base = rgb.blended(withFraction: fraction, of: .white)!
                if self.lab(base).l >= 35 { break }
            }
        }
        let original = self.lab(base)
        guard split else { return (base, base) }
        if original.l >= 55 {
            for brightness in stride(from: base.brightnessComponent, through: 0, by: -0.025) {
                let candidate = NSColor(
                    colorSpace: .sRGB,
                    hue: base.hueComponent,
                    saturation: base.saturationComponent == 0 ? 0 : max(0.8, base.saturationComponent),
                    brightness: brightness,
                    alpha: 1)
                let measured = self.lab(candidate)
                if original.l - measured.l >= 20.5, self.deltaE(original, measured) >= 15.5 {
                    return (base, candidate)
                }
            }
        }
        for fraction in stride(from: 0.05, through: 1, by: 0.05) {
            let candidate = base.blended(withFraction: fraction, of: .white)!
            let measured = self.lab(candidate)
            if measured.l - original.l >= 20.5, self.deltaE(original, measured) >= 15.5 {
                return (candidate, base)
            }
        }
        preconditionFailure("A normalized provider color must have a distinct quota shade")
    }

    static func trackColor(weekly: NSColor, session: NSColor) -> NSColor {
        let week = self.lab(weekly), short = self.lab(session)
        var selected = NSColor.black
        var separation = -Double.infinity
        for component in stride(from: 0.0, through: 0.25, by: 0.25) {
            let candidate = NSColor(srgbRed: component, green: component, blue: component, alpha: 1)
            let measured = self.lab(candidate)
            let distance = min(self.deltaE(week, measured), self.deltaE(short, measured))
            if distance > separation {
                selected = candidate
                separation = distance
            }
        }
        return selected
    }

    static func lab(_ color: NSColor) -> (l: Double, a: Double, b: Double) {
        let rgb = color.usingColorSpace(.sRGB)!
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func transform(_ value: Double) -> Double {
            value > 216.0 / 24389 ? cbrt(value) : (24389.0 / 27 * value + 16) / 116
        }
        let r = linear(rgb.redComponent), g = linear(rgb.greenComponent), b = linear(rgb.blueComponent)
        let x = transform((0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047)
        let y = transform(0.2126729 * r + 0.7151522 * g + 0.0721750 * b)
        let z = transform((0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883)
        return (116 * y - 16, 500 * (x - y), 200 * (y - z))
    }

    static func deltaE(_ first: (l: Double, a: Double, b: Double), _ second: (l: Double, a: Double, b: Double))
        -> Double
    {
        func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
        func hue(_ a: Double, _ b: Double) -> Double {
            let angle = atan2(b, a) * 180 / .pi
            return angle < 0 ? angle + 360 : angle
        }
        let meanChroma = (hypot(first.a, first.b) + hypot(second.a, second.b)) / 2
        let adjustment = 0.5 * (1 - sqrt(pow(meanChroma, 7) / (pow(meanChroma, 7) + pow(25, 7))))
        let a1 = first.a * (1 + adjustment), a2 = second.a * (1 + adjustment)
        let c1 = hypot(a1, first.b), c2 = hypot(a2, second.b)
        let h1 = hue(a1, first.b), h2 = hue(a2, second.b)
        var deltaHue = h2 - h1
        if c1 * c2 == 0 {
            deltaHue = 0
        } else if deltaHue > 180 {
            deltaHue -= 360
        } else if deltaHue < -180 {
            deltaHue += 360
        }
        let deltaH = 2 * sqrt(c1 * c2) * sin(radians(deltaHue / 2))
        let meanL = (first.l + second.l) / 2, meanC = (c1 + c2) / 2
        var meanH = h1 + h2
        if c1 * c2 != 0 {
            meanH = abs(h1 - h2) <= 180 ? meanH / 2 : (meanH + (meanH < 360 ? 360 : -360)) / 2
        }
        let t = 1 - 0.17 * cos(radians(meanH - 30)) + 0.24 * cos(radians(2 * meanH))
            + 0.32 * cos(radians(3 * meanH + 6)) - 0.20 * cos(radians(4 * meanH - 63))
        let lightness = 1 + 0.015 * pow(meanL - 50, 2) / sqrt(20 + pow(meanL - 50, 2))
        let chroma = 1 + 0.045 * meanC, hueScale = 1 + 0.015 * meanC * t
        let rotation = -2 * sqrt(pow(meanC, 7) / (pow(meanC, 7) + pow(25, 7)))
            * sin(radians(60 * exp(-pow((meanH - 275) / 25, 2))))
        let dl = (second.l - first.l) / lightness, dc = (c2 - c1) / chroma, dh = deltaH / hueScale
        return sqrt(dl * dl + dc * dc + dh * dh + rotation * dc * dh)
    }

    private static func bitmap(width: Int) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: 36,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32),
            let data = bitmap.bitmapData else { return nil }
        bitmap.size = NSSize(width: CGFloat(width) / 2, height: 18)
        data.initialize(repeating: 0, count: bitmap.bytesPerRow * 36)
        return bitmap
    }
}
