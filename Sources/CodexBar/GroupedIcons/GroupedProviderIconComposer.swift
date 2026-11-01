import AppKit

@MainActor
enum GroupedProviderIconComposer {
    static func compose(tiles: [NSImage], backingScale: CGFloat) -> NSImage? {
        guard let first = tiles.first else { return nil }
        guard tiles.count > 1 else { return first }
        var slices: [(NSBitmapImageRep, Range<Int>)] = []
        for image in tiles {
            guard let bitmap = self.rasterize(image), let data = bitmap.bitmapData else { return nil }
            var left = 36
            var right = 0
            for x in 0..<36 {
                for y in 0..<36 where data[y * bitmap.bytesPerRow + x * 4 + 3] > 0 {
                    left = min(left, x)
                    right = max(right, x + 1)
                }
            }
            if left == 36 { left = 0; right = 36 }
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
        guard let bitmap = self.bitmap(width: 36), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: 18, height: 18),
            from: .zero,
            operation: .sourceOver,
            fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
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
