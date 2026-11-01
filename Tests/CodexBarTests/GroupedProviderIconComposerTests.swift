import AppKit
import Testing
@testable import CodexBar

@MainActor
struct GroupedProviderIconComposerTests {
    private func tile(columns: Range<Int>, color: NSColor = .red, alpha: CGFloat = 1) throws -> NSImage {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 36,
            pixelsHigh: 36,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 144,
            bitsPerPixel: 32))
        bitmap.size = NSSize(width: 18, height: 18)
        let data = try #require(bitmap.bitmapData)
        data.initialize(repeating: 0, count: 144 * 36)
        let rgb = try #require(color.usingColorSpace(.deviceRGB))
        for y in 0..<36 {
            for x in columns {
                let offset = y * 144 + x * 4
                data[offset] = UInt8((rgb.redComponent * alpha * 255).rounded())
                data[offset + 1] = UInt8((rgb.greenComponent * alpha * 255).rounded())
                data[offset + 2] = UInt8((rgb.blueComponent * alpha * 255).rounded())
                data[offset + 3] = UInt8((alpha * 255).rounded())
            }
        }
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func compose(_ tiles: [NSImage], scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let image = try #require(GroupedProviderIconComposer.compose(tiles: tiles, backingScale: scale))
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
        #expect(bitmap.pixelsHigh == 36)
        #expect(image.size.height == 18)
        #expect(image.size.width == CGFloat(bitmap.pixelsWide) / 2)
        return bitmap
    }

    @Test func `trim and gap preserve exact alpha bounds`() throws {
        let tile = try self.tile(columns: 5..<31)
        let bitmap = try self.compose([tile, tile])
        #expect(bitmap.pixelsWide == 55)
        for x in 0..<55 {
            let alpha = try #require(bitmap.colorAt(x: x, y: 18)).alphaComponent
            #expect((alpha > 0) == !(26..<29).contains(x))
        }
    }

    @Test func `faint edges blank tiles and one scale geometry stay intact`() throws {
        let faint = try self.tile(columns: 0..<36, alpha: 1 / 255)
        #expect(try self.compose([faint, faint]).pixelsWide == 75)
        let blank = try self.tile(columns: 0..<0)
        #expect(try self.compose([blank, blank]).pixelsWide == 75)
        let narrow = try self.tile(columns: 5..<31)
        let bitmap = try self.compose([narrow, narrow], scale: 1)
        #expect(bitmap.pixelsWide == 60)
        for x in 28..<32 {
            #expect(bitmap.colorAt(x: x, y: 18)?.alphaComponent == 0)
        }
    }

    @Test func `template color order and total edge cases`() throws {
        let red = try self.tile(columns: 5..<31)
        let green = try self.tile(columns: 5..<31, color: .green)
        let blue = try self.tile(columns: 5..<31, color: .blue)
        let bitmap = try self.compose([red, green, blue])
        #expect(bitmap.colorAt(x: 10, y: 18)?.redComponent == 1)
        #expect(bitmap.colorAt(x: 40, y: 18)?.greenComponent == 1)
        #expect(bitmap.colorAt(x: 70, y: 18)?.blueComponent == 1)
        red.isTemplate = true
        green.isTemplate = true
        #expect(GroupedProviderIconComposer.compose(tiles: [red, green], backingScale: 2)?.isTemplate == true)
        #expect(GroupedProviderIconComposer.compose(tiles: [red, blue], backingScale: 2)?.isTemplate == false)
        #expect(GroupedProviderIconComposer.compose(tiles: [], backingScale: 2) == nil)
        #expect(GroupedProviderIconComposer.compose(tiles: [red], backingScale: 2) === red)
    }
}
