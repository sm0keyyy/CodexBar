import AppKit

@MainActor
enum PaceChartLabelLayout {
    static let textColor = NSColor.labelColor

    static func size(for text: String) -> CGSize {
        let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold)])
        return CGSize(width: ceil(size.width) + 2, height: ceil(size.height) + 2)
    }

    static func idealFrame(in plot: CGRect) -> CGRect {
        let size = self.size(for: L("pace_ideal"))
        return CGRect(
            x: plot.maxX - size.width - 4,
            y: plot.maxY - size.height - 20,
            width: size.width,
            height: size.height)
    }

    static func place(points: [CGPoint?], sizes: [CGSize], in plot: CGRect, avoiding: [CGRect]) -> [CGRect?] {
        let dots = points.compactMap { point in
            point.map { CGRect(x: $0.x - 5, y: $0.y - 5, width: 10, height: 10) }
        }
        var occupied = avoiding
        return zip(points, sizes).map { point, size in
            guard let point else { return nil }
            let size = CGSize(width: min(size.width, plot.width), height: min(size.height, plot.height))
            func candidate(x: CGFloat, y: CGFloat) -> CGRect {
                CGRect(
                    x: min(plot.maxX - size.width, max(plot.minX, x)),
                    y: min(plot.maxY - size.height, max(plot.minY, y)),
                    width: size.width,
                    height: size.height)
            }
            func isClear(_ frame: CGRect) -> Bool {
                !dots.contains { $0.intersects(frame) }
                    && !occupied.contains { $0.insetBy(dx: -2, dy: -2).intersects(frame) }
            }
            let candidates = [
                candidate(x: point.x + 7, y: point.y - size.height / 2),
                candidate(x: point.x - size.width - 7, y: point.y - size.height / 2),
                candidate(x: point.x - size.width / 2, y: point.y - size.height - 7),
                candidate(x: point.x - size.width / 2, y: point.y + 7),
            ]
            var frame = candidates.first(where: isClear)
            if frame == nil {
                for y in stride(from: plot.minY, through: plot.maxY - size.height, by: size.height + 4) {
                    for x in stride(from: plot.minX, through: plot.maxX - size.width, by: 4) {
                        let fallback = candidate(x: x, y: y)
                        if isClear(fallback) { frame = fallback; break }
                    }
                    if frame != nil { break }
                }
            }
            if let frame { occupied.append(frame) }
            return frame
        }
    }
}
