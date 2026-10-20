import AppKit
import Testing
@testable import Copily

@Suite("Focused preview sizing")
@MainActor
struct FocusPreviewSizingTests {
    let available = CGSize(width: 924, height: 604)

    @Test func shortTextUsesACompactSurface() {
        let size = FocusPreviewSizing.text("A short copied item", available: available)
        #expect(size.width <= 360)
        #expect(size.height <= 132)
        #expect(size.height < available.height / 3)
    }

    @Test func longTextIsBoundedAndMultilineContentGetsMoreRoom() {
        let short = FocusPreviewSizing.text("One line", available: available)
        let multiline = FocusPreviewSizing.text(Array(repeating: "Line of content", count: 8).joined(separator: "\n"), available: available)
        let long = FocusPreviewSizing.text(String(repeating: "Long text with content\n", count: 1000), available: available)
        #expect(multiline.height > short.height)
        #expect(long.width <= 620)
        #expect(long.height <= 430)
        #expect(long.height < available.height - 80)
    }

    @Test(arguments: [CGSize(width: 3000, height: 1000), CGSize(width: 1000, height: 3000), CGSize(width: 120, height: 80)])
    func imagesFitWithoutFillingTheWholePanel(pixels: CGSize) {
        let size = FocusPreviewSizing.image(pixels, available: available)
        #expect(size.width <= 720)
        #expect(size.height <= 460)
        #expect(size.width < available.width - 80)
        #expect(size.height < available.height - 80)
        #expect(size.width >= 220)
    }

    @Test func smallDisplaysAndInvalidImageSizesStayBounded() {
        let small = CGSize(width: 640, height: 460)
        let text = FocusPreviewSizing.text(String(repeating: "Notes ", count: 500), available: small)
        let image = FocusPreviewSizing.image(.zero, available: small)
        #expect(text.width <= small.width - 96)
        #expect(text.height <= small.height - 96)
        #expect(image.width <= small.width - 96)
        #expect(image.height <= small.height - 96)
    }
}
