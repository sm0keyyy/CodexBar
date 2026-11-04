import AppKit
import Testing
@testable import CodexBar

@MainActor
struct GroupedButtonContentTests {
    @Test func `grouped leading inset is native minimum with only trailing cost padding`() throws {
        let image = GroupedProviderIconComposer.pill(
            primary: 50, secondary: nil, color: .systemBlue, stale: false)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        button.isBordered = false
        button.imageScaling = .scaleNone
        let cell = try #require(button.cell)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            button.appearance = try #require(NSAppearance(named: appearanceName))
            for costText in [nil, "$0.00", "$70.61", "$123", "$999k"] {
                let reserved = GroupedDailyCost.reservedDisplayTexts(preferredCurrency: "USD")
                let width = StatusItemController.applyGroupedButtonContent(
                    image: image,
                    costText: costText,
                    reservedCostTexts: reserved,
                    highContrast: false,
                    for: button)
                button.setFrameSize(NSSize(width: width, height: 22))
                #expect(cell.imageRect(forBounds: button.bounds).minX == 2.5)
                let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                let reservedWidth = reserved.map {
                    NSAttributedString(string: " \($0)", attributes: [.font: font]).size().width
                }.max() ?? 0
                #expect(width == ceil(24 + reservedWidth) + 5)
            }
            let width = StatusItemController.applyGroupedButtonContent(
                image: image, costText: nil, reservedCostTexts: [], highContrast: false, for: button)
            button.setFrameSize(NSSize(width: width, height: 22))
            #expect(cell.imageRect(forBounds: button.bounds).minX == 2.5)
            #expect(width == 29)
        }
    }

    @Test func `high contrast keeps the text attachment path at a fixed width`() throws {
        let image = GroupedProviderIconComposer.pill(
            primary: 50, secondary: nil, color: .systemBlue, stale: false)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        button.isBordered = false
        let cell = try #require(button.cell)
        let reserved = GroupedDailyCost.reservedDisplayTexts(preferredCurrency: "USD")
        var widths: Set<CGFloat> = []
        for costText in [nil, "$0.00", "$70.61", "$999k"] {
            let width = StatusItemController.applyGroupedButtonContent(
                image: image,
                costText: costText,
                reservedCostTexts: reserved,
                highContrast: true,
                for: button)
            button.setFrameSize(NSSize(width: width, height: 22))
            widths.insert(width)
            #expect(button.image == nil)
            #expect(button.imagePosition == .noImage)
            let attachment = button.attributedTitle
                .attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
            #expect(attachment?.image === image)
            #expect(cell.titleRect(forBounds: button.bounds).minX == 0)
        }
        #expect(widths.count == 1)
    }

    @Test func `dimmed slot preserves normal or budget ink and exact fixed anchors`() throws {
        let image = GroupedProviderIconComposer.pill(
            primary: 50, secondary: nil, color: .systemBlue, stale: false)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        button.isBordered = false
        for overBudget in [false, true] {
            let width = StatusItemController.applyGroupedButtonContent(
                image: image,
                costText: "$70.61",
                reservedCostTexts: ["$99.99", "$9,999"],
                overBudget: overBudget,
                highContrast: false,
                for: button)
            button.setFrameSize(NSSize(width: width, height: 22))
            let origin = button.cell?.imageRect(forBounds: button.bounds).origin
            let dimmedWidth = StatusItemController.applyGroupedButtonContent(
                image: image,
                costText: "$70.61",
                reservedCostTexts: ["$99.99", "$9,999"],
                overBudget: overBudget,
                dimmed: true,
                highContrast: false,
                for: button)
            let ink = try #require(button.attributedTitle.attribute(
                .foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            #expect(ink.alphaComponent == 0.55)
            #expect(ink == (overBudget ? NSColor.systemOrange : NSColor.labelColor).withAlphaComponent(0.55))
            #expect(width == dimmedWidth)
            #expect(button.cell?.imageRect(forBounds: button.bounds).origin == origin)
        }
    }
}
