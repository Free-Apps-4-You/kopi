import Foundation
import ImageIO
import UniformTypeIdentifiers
import KopiCore

/// Content remains in memory until Save. Cancelling never creates a temporary card
/// or changes the section, source, search, or selection behind the composer.
struct NewItemDraft: Identifiable {
    enum Mode: String, CaseIterable, Identifiable {
        case text, link, file, image
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .text: "text.alignleft"
            case .link: "link"
            case .file: "doc"
            case .image: "photo"
            }
        }
    }
    let id = UUID()
    var mode: Mode = .text
    var text = ""
    var richText = RichTextDocument(plainText: "")
    var label = ""
    var attachment: NewItemAttachment?
    var isLoading = false
    var isSaving = false
    var error: String?

    var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil }
    var hasChanges: Bool { hasContent || !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct NewItemAttachment: Identifiable, Sendable {
    let id = UUID()
    let snapshot: PasteboardSnapshot
    let title: String
    var kind: ClipboardItemKind? { CaptureProcessor.kind(of: snapshot) }

    init(snapshot: PasteboardSnapshot, title: String? = nil) {
        self.snapshot = snapshot
        let files = snapshot.strings(for: ClipboardRepresentationKind.fileURL.pasteboardType)
            .compactMap(URL.init(string:)).map(\.lastPathComponent)
        self.title = title ?? (files.isEmpty ? (CaptureProcessor.kind(of: snapshot)?.displayName ?? "Content") : files.joined(separator: ", "))
    }
}

enum NewItemImport {
    static func text(_ text: String, detectsLinks: Bool = true) -> PasteboardSnapshot {
        var flavours = [PasteboardFlavour(type: ClipboardRepresentationKind.plainText.pasteboardType, string: text)]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if detectsLinks, let url = URL(string: trimmed), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? ""),
           (url.scheme?.lowercased() == "mailto" ? !url.path.isEmpty : url.host?.isEmpty == false),
           !trimmed.contains(where: \.isWhitespace) {
            flavours.append(PasteboardFlavour(type: ClipboardRepresentationKind.link.pasteboardType, string: trimmed))
        }
        return PasteboardSnapshot(changeCount: 0, items: [PasteboardItemSnapshot(flavours: flavours)])
    }

    /// Image bytes are imported as image cards; any file or folder can be a file card.
    /// Reads and format conversion run away from the main actor.
    static func files(_ urls: [URL], asImages: Bool) async throws -> [NewItemAttachment] {
        try await Task.detached(priority: .userInitiated) {
            try urls.map { url in
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let snapshot: PasteboardSnapshot
                if asImages {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let type = CGImageSourceGetType(source) else { throw NewItemImportError.invalidImage }
                    let kind = ClipboardRepresentationKind.allCases.first { $0.isImage && $0.pasteboardType == type as String }
                    let flavour: PasteboardFlavour
                    if let kind {
                        flavour = PasteboardFlavour(type: kind.pasteboardType, data: try Data(contentsOf: url))
                    } else {
                        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw NewItemImportError.invalidImage }
                        let bytes = NSMutableData()
                        guard let target = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { throw NewItemImportError.invalidImage }
                        CGImageDestinationAddImage(target, image, nil)
                        guard CGImageDestinationFinalize(target) else { throw NewItemImportError.invalidImage }
                        flavour = PasteboardFlavour(type: UTType.png.identifier, data: bytes as Data)
                    }
                    snapshot = PasteboardSnapshot(changeCount: 0, items: [PasteboardItemSnapshot(flavours: [flavour])])
                } else {
                    guard FileManager.default.fileExists(atPath: url.path) else { throw NewItemImportError.missingFile }
                    snapshot = PasteboardSnapshot(changeCount: 0, items: [PasteboardItemSnapshot(flavours: [
                        PasteboardFlavour(type: ClipboardRepresentationKind.fileURL.pasteboardType, string: url.absoluteString)
                    ])])
                }
                return NewItemAttachment(snapshot: snapshot, title: url.lastPathComponent)
            }
        }.value
    }
}

enum NewItemImportError: LocalizedError {
    case invalidImage, missingFile, unsupported, oneItemOnly
    var errorDescription: String? {
        switch self {
        case .invalidImage: "This image could not be read. Try another image, or add it as a file."
        case .missingFile: "The selected file is no longer available."
        case .unsupported: "No supported content was found. Add text, a link, an image, or a file."
        case .oneItemOnly: "Add one item at a time. Clear the current content before choosing another item."
        }
    }
}
