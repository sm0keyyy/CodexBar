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
        let unknown = GroupedProviderIconComposer.pill(primary: nil, secondary: nil, color: color, stale: false)
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
        let fills = GroupedProviderIconComposer.fillColors(for: color)
        let week = GroupedProviderIconComposer.lab(fills.weekly)
        let session = GroupedProviderIconComposer.lab(fills.session)
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
        #expect(!unknown.isTemplate)
    }

    @Test func `Claude weekly62 percent remains62 percent of the inner pill despite full alternative caps`() throws {
        func window(_ remaining: Double, _ minutes: Int) -> RateWindow {
            RateWindow(
                usedPercent: 100 - remaining, windowMinutes: minutes, resetsAt: nil, resetDescription: nil)
        }
        let quota = GroupedProviderIconPlan.quota(snapshot: UsageSnapshot(
            primary: window(95, 300),
            secondary: window(62, 10080),
            tertiary: window(100, 10080),
            extraRateWindows: [
                NamedRateWindow(id: "extra-weekly", title: "Weekly", window: window(100, 10080)),
            ],
            updatedAt: Date()))
        #expect(quota.shortest?.remainingPercent == 95)
        #expect(quota.longest?.remainingPercent == 62)
        let accent = ProviderDescriptorRegistry.descriptor(for: .claude).branding.color
        let color = NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)
        let fills = GroupedProviderIconComposer.fillColors(for: color)
        let week = GroupedProviderIconComposer.lab(fills.weekly)
        let short = GroupedProviderIconComposer.lab(fills.session)
        var measurements: [[String: Any]] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var rendered: NSBitmapImageRep?
            appearance.performAsCurrentDrawingAppearance {
                rendered = GroupedProviderIconComposer.rasterize(GroupedProviderIconComposer.pill(
                    primary: quota.shortest?.remainingPercent,
                    secondary: quota.longest?.remainingPercent,
                    color: color,
                    stale: false))
            }
            let bitmap = try #require(rendered)
            let track = try GroupedProviderIconComposer.lab(#require(bitmap.colorAt(x: 42, y: 20)))
            func ratio(row: Int, fill: (l: Double, a: Double, b: Double)) throws -> Double {
                var filled = 0
                for x in 1..<47 {
                    let pixel = try GroupedProviderIconComposer.lab(#require(bitmap.colorAt(x: x, y: row)))
                    guard GroupedProviderIconComposer.deltaE(pixel, fill)
                        < GroupedProviderIconComposer.deltaE(pixel, track) else { break }
                    filled += 1
                }
                return Double(filled) / 46
            }
            let weeklyRatio = try ratio(row: 20, fill: week)
            let sessionRatio = try ratio(row: 16, fill: short)
            let weeklyTrack = GroupedProviderIconComposer.deltaE(week, track)
            let sessionTrack = GroupedProviderIconComposer.deltaE(short, track)
            #expect(abs(weeklyRatio - 0.62) <= 1.0 / 46)
            #expect(abs(sessionRatio - 0.95) <= 1.0 / 46)
            #expect(weeklyTrack >= 15)
            #expect(sessionTrack >= 15)
            measurements.append([
                "appearance": name.rawValue, "weeklyRatio": weeklyRatio, "sessionRatio": sessionRatio,
                "weeklyTrack": weeklyTrack, "sessionTrack": sessionTrack,
            ])
        }
        let json = try JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys])
        try print("GROUPED_PILL_WEEKLY_WIDTH_METRICS \(#require(String(bytes: json, encoding: .utf8)))")
    }

    @Test func `state cues never change opaque orange fills or their contrast`() throws {
        let accent = ProviderDescriptorRegistry.descriptor(for: .claude).branding.color
        let color = NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            for state in 0..<6 {
                var rendered: NSBitmapImageRep?
                appearance.performAsCurrentDrawingAppearance {
                    rendered = GroupedProviderIconComposer.rasterize(GroupedProviderIconComposer.pill(
                        primary: 95,
                        secondary: 62,
                        color: color,
                        stale: state == 1,
                        loading: state == 2,
                        warning: state == 3 ? .amber : state >= 4 ? .red : .none,
                        flash: state == 5))
                }
                let bitmap = try #require(rendered)
                let week = try #require(bitmap.colorAt(x: 12, y: 20)?.usingColorSpace(.sRGB))
                let session = try #require(bitmap.colorAt(x: 12, y: 16))
                let track = try #require(bitmap.colorAt(x: 42, y: 20))
                #expect(week.alphaComponent == 1)
                #expect(session.alphaComponent == 1)
                #expect(track.alphaComponent == 1)
                #expect(week.saturationComponent >= 0.5)
                #expect(week.hueComponent < 0.1)
                let weekLab = GroupedProviderIconComposer.lab(week)
                let sessionLab = GroupedProviderIconComposer.lab(session)
                let trackLab = GroupedProviderIconComposer.lab(track)
                #expect(GroupedProviderIconComposer.deltaE(sessionLab, GroupedProviderIconComposer.lab(color)) < 1)
                #expect(abs(weekLab.l - sessionLab.l) >= 20)
                #expect(weekLab.l < sessionLab.l)
                #expect(weekLab.l <= 85 && sessionLab.l <= 85)
                #expect(trackLab.l <= 30)
                let sessionRGB = try #require(session.usingColorSpace(.sRGB))
                #expect(abs(week.hueComponent - sessionRGB.hueComponent) < 0.01)
                #expect(week.saturationComponent >= 0.79)
                #expect(GroupedProviderIconComposer.deltaE(weekLab, sessionLab) >= 15)
                #expect(GroupedProviderIconComposer.deltaE(weekLab, trackLab) >= 15)
                #expect(GroupedProviderIconComposer.deltaE(sessionLab, trackLab) >= 15)
            }
        }
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
                let color = NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)
                appearance.performAsCurrentDrawingAppearance {
                    let fills = GroupedProviderIconComposer.fillColors(for: color)
                    let week = GroupedProviderIconComposer.lab(fills.weekly)
                    let short = GroupedProviderIconComposer.lab(fills.session)
                    #expect(week.l <= 85, "\(provider.rawValue) \(name.rawValue)")
                    #expect(short.l <= 85, "\(provider.rawValue) \(name.rawValue)")
                    let deltaL = abs(short.l - week.l)
                    let deltaE = GroupedProviderIconComposer.deltaE(short, week)
                    #expect(deltaL >= 20, "\(provider.rawValue) \(name.rawValue)")
                    #expect(deltaE >= 15, "\(provider.rawValue) \(name.rawValue)")
                    let image = GroupedProviderIconComposer.pill(
                        primary: 50,
                        secondary: 50,
                        color: color,
                        stale: false)
                    if let bitmap = GroupedProviderIconComposer.rasterize(image),
                       let empty = bitmap.colorAt(x: 40, y: 20)
                    {
                        let track = GroupedProviderIconComposer.lab(empty)
                        #expect(track.l <= 30)
                        let sessionTrack = GroupedProviderIconComposer.deltaE(short, track)
                        let weeklyTrack = GroupedProviderIconComposer.deltaE(week, track)
                        #expect(sessionTrack >= 15)
                        #expect(weeklyTrack >= 15)
                        measurements.append([
                            "provider": provider.rawValue, "appearance": name.rawValue,
                            "deltaL": deltaL, "deltaE2000": deltaE,
                            "sessionTrack": sessionTrack, "weeklyTrack": weeklyTrack,
                            "sessionL": short.l, "weeklyL": week.l,
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

    @Test(arguments: [false, true], 0..<6)
    func `all provider rendered fills avoid near white in every state`(split: Bool, state: Int) throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for provider in UsageProvider.allCases {
                let accent = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
                let color = NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)
                var rendered: NSBitmapImageRep?
                appearance.performAsCurrentDrawingAppearance {
                    rendered = GroupedProviderIconComposer.rasterize(GroupedProviderIconComposer.pill(
                        primary: 50,
                        secondary: split ? 50 : nil,
                        color: color,
                        stale: state == 1,
                        loading: state == 2,
                        warning: state == 3 ? .amber : state >= 4 ? .red : .none,
                        flash: state == 5))
                }
                let bitmap = try #require(rendered)
                let session = try GroupedProviderIconComposer.lab(#require(bitmap.colorAt(x: 12, y: 16)))
                let weekly = try GroupedProviderIconComposer.lab(#require(bitmap.colorAt(x: 12, y: 20)))
                let track = try GroupedProviderIconComposer.lab(#require(bitmap.colorAt(x: 40, y: 20)))
                #expect(session.l <= 85, "\(provider.rawValue) \(name.rawValue) \(state)")
                #expect(weekly.l <= 85, "\(provider.rawValue) \(name.rawValue) \(state)")
                #expect(track.l <= 30)
                #expect(GroupedProviderIconComposer.deltaE(session, track) >= 15)
                #expect(GroupedProviderIconComposer.deltaE(weekly, track) >= 15)
                if split {
                    #expect(abs(session.l - weekly.l) >= 20, "\(provider.rawValue) \(name.rawValue) \(state)")
                    #expect(GroupedProviderIconComposer.deltaE(session, weekly) >= 15)
                }
            }
        }
    }

    @Test func `render Claude pill proof at native size`() throws {
        let directory = ProcessInfo.processInfo.environment["CODEXBAR_GROUPED_PILL_PROOF_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let color = NSColor(srgbRed: 204 / 255, green: 124 / 255, blue: 94 / 255, alpha: 1)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var rendered: NSBitmapImageRep?
            appearance.performAsCurrentDrawingAppearance {
                rendered = GroupedProviderIconComposer.rasterize(GroupedProviderIconComposer.pill(
                    primary: 95, secondary: 62, color: color, stale: false))
            }
            let bitmap = try #require(rendered)
            #expect(bitmap.size == NSSize(width: 24, height: 18))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            if let directory { try png.write(to: directory.appendingPathComponent("claude-\(name.rawValue).png")) }
        }
    }
}
