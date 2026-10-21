import AppKit
import SwiftUI
import KopiCore

/// Renders Kopi's own interface into images for the project website.
///
/// The renderer draws the real views inside an off-screen window that stays
/// invisible: nothing appears on screen, the keyboard and the pointer are never
/// touched, and the clipboard is never observed. Every card comes from a throwaway
/// database that is filled with sample content, so the pictures always match what
/// the application really shows.
@MainActor
enum ShowcaseRenderer {
    /// Failures the renderer reports instead of writing a broken picture.
    enum ShowcaseError: Error, LocalizedError {
        case captureFailed(String)
        case missingContent(String)

        var errorDescription: String? {
            switch self {
            case .captureFailed(let name): "Could not draw \(name)."
            case .missingContent(let name): "The showcase is missing \(name)."
            }
        }
    }

    /// The panel at the size the application prefers, plus the room its shadow needs.
    static var panelSize: CGSize {
        CGSize(width: PanelGeometry.preferredSize.width + KopiTheme.shadowInset * 2,
               height: PanelGeometry.preferredSize.height + KopiTheme.shadowInset * 2)
    }

    /// Draws every showcase picture into `outputDirectory`.
    static func run(outputDirectory: URL) async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kopi-showcase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = try AppEnvironment.showcase(rootDirectory: root)
        let cards = try await seed(environment)
        await environment.panelModel.reloadAll()

        try await renderPanel(environment, cards: cards, into: outputDirectory)
        try await renderRadial(environment, cards: cards, into: outputDirectory)
        try await renderSettings(environment, into: outputDirectory)
    }

    // MARK: - The panel

    private static func renderPanel(_ environment: AppEnvironment, cards: [ShowcaseCard], into directory: URL) async throws {
        let model = environment.panelModel
        let commands = PanelCommands(copy: { _ in }, dismiss: {}, openSettings: {})

        // The cards load their own previews when they appear. Loading them here as
        // well means the pictures are complete the moment they are drawn.
        for card in cards {
            await environment.previews.load(card.summary, maxPixelSize: 640)
        }

        // The All tab, with every kind of content in one grid.
        model.setSection(.all)
        model.setSource(nil)
        model.queryText = ""
        await model.reload(.allClipboard)
        try capture(PanelRootView(model: model, commands: commands),
                    size: panelSize, name: "panel-clipboard", into: directory)

        // The same grid in the light appearance.
        NSApp.appearance = NSAppearance(named: .aqua)
        try capture(PanelRootView(model: model, commands: commands),
                    size: panelSize, name: "panel-light", into: directory)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // A search that narrows the history down to a few cards.
        model.queryText = "showcase"
        await model.reload(.allClipboard)
        try capture(PanelRootView(model: model, commands: commands),
                    size: panelSize, name: "panel-search", into: directory)
        model.queryText = ""
        await model.reload(.allClipboard)

        // The collection shelf: snippets the user keeps for good.
        model.setSource(.collection)
        await model.reload(.collection)
        try capture(PanelRootView(model: model, commands: commands),
                    size: panelSize, name: "panel-collection", into: directory)
        model.setSource(nil)
        await model.reload(.allClipboard)

        // A card opened for a closer look.
        if let codeCard = cards.first(where: { $0.kind == .code }) {
            await model.openPreview(codeCard.id)
            try capture(PanelRootView(model: model, commands: commands),
                        size: panelSize, name: "panel-preview", into: directory)
            model.closePreview()
        }

        // The colour inspector, with its HEX and RGB copy controls.
        if let colorCard = cards.first(where: { $0.kind == .color }) {
            await model.openPreview(colorCard.id)
            try capture(PanelRootView(model: model, commands: commands),
                        size: panelSize, name: "panel-colors", into: directory)
            model.closePreview()
        }

        // The Notes tab, reading from the scripted client.
        await environment.notesModel.activate()
        model.setSection(.notes)
        try capture(PanelRootView(model: model, commands: commands),
                    size: panelSize, name: "panel-notes", into: directory)
        model.setSection(.all)
        await model.reload(.allClipboard)
    }

    // MARK: - The radial picker

    private static func renderRadial(_ environment: AppEnvironment, cards: [ShowcaseCard], into directory: URL) async throws {
        let state = RadialState()
        state.items = cards.filter { $0.kind != .files }.map(\.summary)
        state.totalCount = state.items.count
        state.selected = 1
        state.presented = true
        state.trigger = .optionSpace
        state.controlsY = RadialGeometry.dockCenterY

        // The wheel is translucent: on a Mac it takes the colour of the desktop
        // behind it. The backdrop is the page background, so the picture reads
        // as the picker floating over the desktop rather than as a box.
        try capture(
            ZStack {
                Color(red: 0.051, green: 0.063, blue: 0.078)
                RadialView(state: state, previews: environment.previews,
                           choose: { _ in }, page: { _ in }, cancel: {})
            },
            size: CGSize(width: RadialGeometry.windowWidth, height: RadialGeometry.windowHeight),
            name: "radial", into: directory
        )
    }

    // MARK: - Settings

    private static func renderSettings(_ environment: AppEnvironment, into directory: URL) async throws {
        let model = SettingsViewModel(environment: environment)
        await model.load()
        try capture(SettingsView(model: model),
                    size: CGSize(width: 760, height: 560), name: "settings", into: directory)
    }

    // MARK: - Sample content

    /// One seeded card, kept so a picture can be pointed at a specific card.
    private struct ShowcaseCard {
        enum Kind { case code, color, link, text, richText, image, files }
        let id: ClipboardItemID
        let kind: Kind
        let summary: ClipboardItemSummary
    }

    private static func seed(_ environment: AppEnvironment) async throws -> [ShowcaseCard] {
        let store = environment.store
        let assetStore = environment.assetStore
        let now = Date()
        var cards: [ShowcaseCard] = []

        // A snippet of code, highlighted on its card.
        let code = """
        const idea = { title: "Make something useful", worthKeeping: true };
        console.log(idea.title);
        """
        let codeResult = try await store.insert(ClipboardItemInsertion(
            kind: .text,
            label: "Showcase",
            text: code,
            representations: [ClipboardRepresentation(kind: .plainText, payload: .text(code))],
            sourceApp: SourceAppInfo(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode"),
            capturedAt: now.addingTimeInterval(-260)
        ))
        cards.append(ShowcaseCard(id: codeResult.summary.id, kind: .code, summary: codeResult.summary))

        // A link with its own label.
        let linkURL = URL(string: "https://github.com/Free-Apps-4-You/kopi")!
        let linkResult = try await store.insert(ClipboardItemInsertion(
            kind: .link,
            label: "Showcase · Free & open source",
            text: linkURL.absoluteString,
            url: linkURL,
            representations: [
                ClipboardRepresentation(kind: .link, payload: .text(linkURL.absoluteString)),
                ClipboardRepresentation(kind: .plainText, payload: .text(linkURL.absoluteString))
            ],
            sourceApp: SourceAppInfo(bundleIdentifier: "com.apple.Safari", name: "Safari"),
            capturedAt: now.addingTimeInterval(-900)
        ))
        cards.append(ShowcaseCard(id: linkResult.summary.id, kind: .link, summary: linkResult.summary))

        // A thought worth keeping.
        let thought = "A thought worth keeping. A link worth revisiting. A little less retyping. Your clipboard, ready when you need it."
        let thoughtResult = try await store.insert(ClipboardItemInsertion(
            kind: .text,
            label: "Showcase · Keep the good stuff close",
            text: thought,
            representations: [ClipboardRepresentation(kind: .plainText, payload: .text(thought))],
            sourceApp: SourceAppInfo(bundleIdentifier: "com.apple.Notes", name: "Notes"),
            capturedAt: now.addingTimeInterval(-1_500)
        ))
        cards.append(ShowcaseCard(id: thoughtResult.summary.id, kind: .text, summary: thoughtResult.summary))

        // A colour value, shown as a swatch with its HEX and RGB forms.
        let colour = "#5E7CF8"
        let colourResult = try await store.insert(ClipboardItemInsertion(
            kind: .text,
            label: "Showcase · Brand blue",
            text: colour,
            representations: [ClipboardRepresentation(kind: .plainText, payload: .text(colour))],
            sourceApp: SourceAppInfo(bundleIdentifier: "com.apple.Preview", name: "Preview"),
            capturedAt: now.addingTimeInterval(-3_600)
        ))
        cards.append(ShowcaseCard(id: colourResult.summary.id, kind: .color, summary: colourResult.summary))

        // Rich text, with the formatting it was copied with.
        let document = RichTextDocument(runs: [
            RichTextDocument.Run(text: "Keep the good stuff close", traits: [.bold]),
            RichTextDocument.Run(text: "\n"),
            RichTextDocument.Run(text: "Headings, lists and tables travel with the card."),
            RichTextDocument.Run(text: "\n", traits: []),
            RichTextDocument.Run(text: "✔ Preview and copy Apple Notes with formatting", traits: []),
            RichTextDocument.Run(text: "\n"),
            RichTextDocument.Run(text: "✔ Edit text without leaving the panel", traits: [])
        ])
        let richResult = try await store.insert(ClipboardItemInsertion(
            kind: .richText,
            label: "Showcase · Formatted",
            text: document.plainText,
            representations: [
                ClipboardRepresentation(kind: .plainText, payload: .text(document.plainText)),
                ClipboardRepresentation(kind: .html, payload: .text(document.html())),
                ClipboardRepresentation(kind: .rtf, payload: .data(document.rtf()))
            ],
            sourceApp: SourceAppInfo(bundleIdentifier: "com.apple.Notes", name: "Notes"),
            capturedAt: now.addingTimeInterval(-7_200)
        ))
        cards.append(ShowcaseCard(id: richResult.summary.id, kind: .richText, summary: richResult.summary))

        // A picture, stored the way the application stores a captured image.
        if let imageData = ShowcaseImage.make() {
            let snapshot = try await assetStore.importData(imageData, kind: .image, fileExtension: "png")
            let imageResult = try await store.insert(ClipboardItemInsertion(
                kind: .image,
                label: "Showcase · Design",
                representations: [ClipboardRepresentation(kind: .png, payload: .asset(snapshot.reference))],
                sourceApp: SourceAppInfo(bundleIdentifier: "com.apple.screencapture", name: "Screenshot"),
                capturedAt: now.addingTimeInterval(-14_400)
            ))
            cards.append(ShowcaseCard(id: imageResult.summary.id, kind: .image, summary: imageResult.summary))
        }

        // Files copied from the Finder.
        let filesResult = try await store.insert(ClipboardItemInsertion(
            kind: .files,
            label: "Showcase · Assets",
            representations: [],
            fileReferences: [
                FileReference(path: "/Users/mac/Design/Assets/icon-grid.svg",
                              displayName: "icon-grid.svg", byteSize: 18_432),
                FileReference(path: "/Users/mac/Design/Assets/hero.png",
                              displayName: "hero.png", byteSize: 284_100),
                FileReference(path: "/Users/mac/Design/Assets/palette.json",
                              displayName: "palette.json", byteSize: 2_048)
            ],
            sourceApp: SourceAppInfo(bundleIdentifier: "com.apple.finder", name: "Finder"),
            capturedAt: now.addingTimeInterval(-28_800)
        ))
        cards.append(ShowcaseCard(id: filesResult.summary.id, kind: .files, summary: filesResult.summary))

        // A card on the collection shelf, kept for good.
        let collectionText = "A reusable snippet that stays on the collection shelf until it is removed."
        let collectionResult = try await store.insert(ClipboardItemInsertion(
            kind: .text,
            label: "Showcase · Reusable snippet",
            text: collectionText,
            representations: [ClipboardRepresentation(kind: .plainText, payload: .text(collectionText))],
            sourceApp: SourceAppInfo(bundleIdentifier: "com.kopi.app", name: "Kopi"),
            capturedAt: now.addingTimeInterval(-43_200),
            destination: .collection
        ))
        cards.append(ShowcaseCard(id: collectionResult.summary.id, kind: .text, summary: collectionResult.summary))

        // One pinned card, which retention and Clear History leave alone.
        if let link = cards.first(where: { $0.kind == .link }) {
            _ = try await store.setPinned(true, for: link.id, now: now.addingTimeInterval(-600))
        }

        return cards
    }

    // MARK: - Drawing

    /// Draws one view into a PNG file.
    ///
    /// The window is transparent, sits far off screen and is never made key, so the
    /// render cannot be seen and cannot take the keyboard away from the user.
    private static func capture<Content: View>(
        _ content: Content,
        size: CGSize,
        scale: CGFloat = 2,
        settle: TimeInterval = 0.5,
        name: String,
        into directory: URL
    ) throws {
        let hosting = NSHostingView(rootView: content)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = ShowcaseWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        window.appearance = NSApp.effectiveAppearance
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -40_000, y: -40_000))
        window.orderFront(nil)

        // SwiftUI lays out and finishes its first pass on the run loop, and the
        // cards load their previews in tasks. Both need the loop to turn.
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle / 3))

        let pixelsWide = Int(size.width * scale)
        let pixelsHigh = Int(size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixelsWide,
                                         pixelsHigh: pixelsHigh,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else {
            throw ShowcaseError.captureFailed(name)
        }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ShowcaseError.captureFailed(name)
        }
        try data.write(to: directory.appendingPathComponent("\(name).png"))

        window.orderOut(nil)
        window.contentView = nil
    }
}

/// A window that can never take the keyboard.
///
/// The renderer draws into a window that sits far off screen and stays
/// transparent. Refusing to become key keeps the user's own application in front,
/// with its text field and its cursor exactly where they were.
private final class ShowcaseWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The picture used by the image card: a small abstract render, drawn rather than
/// shipped, so the showcase carries no third-party artwork.
enum ShowcaseImage {
    static func make() -> Data? {
        let size = CGSize(width: 960, height: 600)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let colors = [
            CGColor(red: 0.10, green: 0.45, blue: 0.52, alpha: 1),
            CGColor(red: 0.25, green: 0.72, blue: 0.66, alpha: 1),
            CGColor(red: 0.37, green: 0.49, blue: 0.95, alpha: 1)
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: size.width, y: size.height),
                                       options: [])
        }

        // Soft overlapping shapes, so the thumbnail reads as a real picture.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
        context.fillEllipse(in: CGRect(x: 120, y: 90, width: 420, height: 420))
        context.setFillColor(CGColor(red: 0.05, green: 0.12, blue: 0.18, alpha: 0.28))
        context.fillEllipse(in: CGRect(x: 430, y: 210, width: 520, height: 520))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
        context.fill(CGRect(x: 90, y: 430, width: 300, height: 16))

        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}
