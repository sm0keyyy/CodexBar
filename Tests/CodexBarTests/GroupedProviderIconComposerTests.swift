import AppKit
import CodexBarCore
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

    @Test func `uniform pills keep weekly single lane and independently fill split halves`() throws {
        let color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let single = GroupedProviderIconComposer.pill(primary: 50, secondary: nil, color: color, stale: false)
        let split = GroupedProviderIconComposer.pill(primary: 50, secondary: 75, color: color, stale: false)
        let unknown = GroupedProviderIconComposer.pill(primary: nil, secondary: nil, color: nil, stale: false)
        for image in [single, split, unknown] {
            #expect(image.size == NSSize(width: 24, height: 18))
            let bitmap = try #require(GroupedProviderIconComposer.rasterize(image))
            #expect(bitmap.pixelsWide == 48)
            #expect(bitmap.pixelsHigh == 36)
            #expect(bitmap.colorAt(x: 0, y: 18)?.alphaComponent ?? 0 > 0)
            #expect(bitmap.colorAt(x: 47, y: 18)?.alphaComponent ?? 0 > 0)
            #expect(bitmap.colorAt(x: 24, y: 0)?.alphaComponent == 0)
            #expect(bitmap.colorAt(x: 0, y: 8)?.alphaComponent == 0)
        }
        let one = try #require(GroupedProviderIconComposer.rasterize(single))
        let two = try #require(GroupedProviderIconComposer.rasterize(split))
        let week = GroupedProviderIconComposer.lab(color)
        let session = GroupedProviderIconComposer.lab(GroupedProviderIconComposer.sessionColor(for: color))
        func measured(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> (l: Double, a: Double, b: Double) {
            try GroupedProviderIconComposer.lab(#require(bitmap.colorAt(x: x, y: y)))
        }
        #expect(try GroupedProviderIconComposer.deltaE(measured(one, 20, 16), week) < 1)
        #expect(try GroupedProviderIconComposer.deltaE(measured(one, 20, 20), week) < 1)
        #expect(try GroupedProviderIconComposer.deltaE(measured(two, 20, 16), session) < 1)
        #expect(try GroupedProviderIconComposer.deltaE(measured(two, 30, 20), week) < 1)
        #expect(try GroupedProviderIconComposer.deltaE(measured(two, 30, 16), session) > 5)
        #expect(try GroupedProviderIconComposer.deltaE(measured(two, 40, 20), week) > 5)
        #expect(try GroupedProviderIconComposer.deltaE(measured(two, 20, 18), session) > 5)
        #expect(try self.compose([single, split]).pixelsWide == 99)
        #expect(try self.compose([single, split], scale: 1).pixelsWide == 100)
        let joined = try self.compose([single, split])
        for x in 48..<51 {
            #expect(joined.colorAt(x: x, y: 18)?.alphaComponent == 0)
        }
        #expect(!single.isTemplate)
        #expect(unknown.isTemplate)
    }

    @Test func `perceptual color distance matches published CIEDE2000 reference pairs`() {
        #expect(abs(GroupedProviderIconComposer.deltaE((50, 2.6772, -79.7751), (50, 0, -82.7485)) - 2.0425) < 0.0001)
        #expect(abs(GroupedProviderIconComposer.deltaE((50, 3.1571, -77.2803), (50, 0, -82.7485)) - 2.8615) < 0.0001)
        #expect(abs(GroupedProviderIconComposer.deltaE((50, 0, 0), (50, -1, 2)) - 2.3669) < 0.0001)
    }

    @Test func `every provider palette distinguishes both quota fills and empty tracks in both appearances`() throws {
        var measurements: [[String: Any]] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for provider in UsageProvider.allCases {
                let accent = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
                let weekly = NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)
                appearance.performAsCurrentDrawingAppearance {
                    let session = GroupedProviderIconComposer.sessionColor(for: weekly)
                    let week = GroupedProviderIconComposer.lab(weekly)
                    let short = GroupedProviderIconComposer.lab(session)
                    let deltaL = abs(short.l - week.l)
                    let deltaE = GroupedProviderIconComposer.deltaE(short, week)
                    #expect(deltaL >= 20, "\(provider.rawValue) \(name.rawValue)")
                    #expect(deltaE >= 15, "\(provider.rawValue) \(name.rawValue)")
                    let image = GroupedProviderIconComposer.pill(
                        primary: 50,
                        secondary: 50,
                        color: weekly,
                        stale: false)
                    if let bitmap = GroupedProviderIconComposer.rasterize(image),
                       let empty = bitmap.colorAt(x: 40, y: 20)
                    {
                        let track = GroupedProviderIconComposer.lab(empty)
                        let sessionTrack = GroupedProviderIconComposer.deltaE(short, track)
                        let weeklyTrack = GroupedProviderIconComposer.deltaE(week, track)
                        #expect(sessionTrack > 5)
                        #expect(weeklyTrack > 5)
                        measurements.append([
                            "provider": provider.rawValue, "appearance": name.rawValue,
                            "deltaL": deltaL, "deltaE2000": deltaE,
                            "sessionTrack": sessionTrack, "weeklyTrack": weeklyTrack,
                            "darkerSession": short.l < week.l,
                        ])
                    } else {
                        Issue.record("Missing pill pixels for \(provider.rawValue)")
                    }
                }
            }
        }
        #expect(measurements.count == UsageProvider.allCases.count * 2)
        let json = try JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys])
        try print("GROUPED_PILL_COLOR_METRICS \(#require(String(bytes: json, encoding: .utf8)))")
    }
}
