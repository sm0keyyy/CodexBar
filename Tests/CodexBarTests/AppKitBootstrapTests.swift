import AppKit
import CodexBarTestBootstrap
import Testing

@MainActor
struct AppKitBootstrapTests {
    @Test func `test host prohibits activation before creating its application`() {
        #expect(codexbar_test_bootstrap_preceded_application())
        #expect(codexbar_test_bootstrap_applied_policy())
        #expect(NSApplication.shared.activationPolicy() != .regular)
    }

    @Test func `offscreen bitmap rendering works without a Dock application`() throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 8,
            bitsPerPixel: 32))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        let pixel = try #require(bitmap.colorAt(x: 0, y: 0))
        #expect(pixel.redComponent == 1)
        #expect(pixel.alphaComponent == 1)
        #expect(NSApplication.shared.activationPolicy() != .regular)
    }
}
