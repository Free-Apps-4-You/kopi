import Foundation

/// One flavour a card offers to a drop destination: the pasteboard type identifier it
/// answers to and where its bytes or file come from.
public struct CardDragFlavour: Sendable, Hashable {
    public let typeIdentifier: String
    public let source: CardDragFlavourSource

    public init(typeIdentifier: String, source: CardDragFlavourSource) {
        self.typeIdentifier = typeIdentifier
        self.source = source
    }
}

/// Where the content of a drag flavour lives.
public enum CardDragFlavourSource: Sendable, Hashable {
    /// Text handed to the destination as UTF-8 bytes.
    case text(String)
    /// Bytes already in memory.
    case data(Data)
    /// Bytes held by the asset store, read when the destination asks for them.
    case asset(AssetReference)
    /// A file outside the store, handed over by URL.
    case file(URL)
    /// A file held by the asset store, handed over by URL.
    case assetFile(AssetReference)

    public var isFile: Bool {
        switch self {
        case .file, .assetFile: true
        case .text, .data, .asset: false
        }
    }
}

/// How an item provider advertises a card before any of its content is loaded.
public enum CardDragRegistration: Sendable, Hashable {
    /// A file-backed representation, handed over as the file at its URL.
    case file(String)
    /// A data-backed representation for one pasteboard type.
    case data(String)
}

/// The drag of a card, as pure mapping.
///
/// A provider has to be built before anything is dragged, so ``registrations(for:)``
/// is decided by the card's kind alone. The flavours themselves are resolved from the
/// stored detail, and only once a drop destination asks for one, so a card's payloads
/// are never loaded just because a pointer moved across it.
public enum CardDragMapping {
    /// Pasteboard type of a file handed over by URL.
    public static let fileURLTypeIdentifier = ClipboardRepresentationKind.fileURL.pasteboardType

    /// Type identifier Copily's own card drags carry, with the card's identifier as its
    /// bytes. It lets a drop inside Copily recognise the card a drag came from, which is
    /// how another chip's card is collected; other applications ignore it.
    public static let cardIdentifierType = "com.copily.app.clipboard-card"

    /// Type identifiers an item provider registers for a card, highest fidelity first.
    ///
    /// An image card registers every image type it could carry: the stored type only
    /// becomes known once the content is loaded, and ``flavour(for:in:)`` then maps a
    /// request for another image type onto the flavour the card actually has.
    public static func registrations(for kind: ClipboardItemKind) -> [CardDragRegistration] {
        switch kind {
        case .text:
            [.data(ClipboardRepresentationKind.plainText.pasteboardType)]
        case .richText:
            [
                .data(ClipboardRepresentationKind.rtf.pasteboardType),
                .data(ClipboardRepresentationKind.html.pasteboardType),
                .data(ClipboardRepresentationKind.plainText.pasteboardType)
            ]
        case .link:
            [
                .data(ClipboardRepresentationKind.link.pasteboardType),
                .data(ClipboardRepresentationKind.plainText.pasteboardType)
            ]
        case .image:
            [.file(fileURLTypeIdentifier)] + imageKinds.map { .data($0.pasteboardType) }
        case .files:
            [.file(fileURLTypeIdentifier)]
        }
    }

    /// The flavours a card carries, resolved from its stored detail.
    public static func flavours(for detail: ClipboardItemDetail) -> [CardDragFlavour] {
        switch detail.summary.kind {
        case .text:
            textFlavours(detail)
        case .richText:
            richTextFlavours(detail)
        case .link:
            linkFlavours(detail)
        case .image:
            imageFlavours(detail)
        case .files:
            fileFlavours(detail)
        }
    }

    /// The flavour a destination asking for `registration` receives, or `nil` when the
    /// card does not carry one. An image destination asking for an image type the card
    /// does not store falls back to the image flavour the card does carry.
    public static func flavour(
        for registration: CardDragRegistration,
        in flavours: [CardDragFlavour]
    ) -> CardDragFlavour? {
        switch registration {
        case .file(let typeIdentifier):
            if let exact = flavours.first(where: { $0.typeIdentifier == typeIdentifier && $0.source.isFile }) {
                return exact
            }
            return flavours.first { $0.source.isFile }
        case .data(let typeIdentifier):
            if let exact = flavours.first(where: { $0.typeIdentifier == typeIdentifier && !$0.source.isFile }) {
                return exact
            }
            guard imageTypeIdentifiers.contains(typeIdentifier) else { return nil }
            return flavours.first { imageTypeIdentifiers.contains($0.typeIdentifier) && !$0.source.isFile }
        }
    }

    // MARK: - Per kind

    private static func textFlavours(_ detail: ClipboardItemDetail) -> [CardDragFlavour] {
        guard let plain = flavour(.plainText, of: detail) else { return [] }
        return [plain]
    }

    private static func richTextFlavours(_ detail: ClipboardItemDetail) -> [CardDragFlavour] {
        var flavours = [flavour(.rtf, of: detail), flavour(.html, of: detail)].compactMap { $0 }
        if let plain = flavour(.plainText, of: detail) {
            flavours.append(plain)
        } else if let derived = derivedPlainText(of: detail) {
            flavours.append(
                CardDragFlavour(
                    typeIdentifier: ClipboardRepresentationKind.plainText.pasteboardType,
                    source: .text(derived)
                )
            )
        }
        return flavours
    }

    private static func linkFlavours(_ detail: ClipboardItemDetail) -> [CardDragFlavour] {
        let urlString = detail.summary.primaryURL?.absoluteString
        var flavours: [CardDragFlavour] = []
        if let link = flavour(.link, of: detail) {
            flavours.append(link)
        } else if let urlString {
            flavours.append(
                CardDragFlavour(
                    typeIdentifier: ClipboardRepresentationKind.link.pasteboardType,
                    source: .text(urlString)
                )
            )
        }
        if let plain = flavour(.plainText, of: detail) {
            flavours.append(plain)
        } else if let urlString {
            flavours.append(
                CardDragFlavour(
                    typeIdentifier: ClipboardRepresentationKind.plainText.pasteboardType,
                    source: .text(urlString)
                )
            )
        }
        return flavours
    }

    private static func imageFlavours(_ detail: ClipboardItemDetail) -> [CardDragFlavour] {
        let images = detail.representations.filter { $0.kind.isImage }
        var flavours: [CardDragFlavour] = []
        if let asset = images.compactMap(\.asset).first {
            flavours.append(CardDragFlavour(typeIdentifier: fileURLTypeIdentifier, source: .assetFile(asset)))
        }
        flavours.append(contentsOf: images.compactMap(flavour(from:)))
        return flavours
    }

    /// Whether a card has something sensible to hand to a drag. A drag carries one
    /// item, so a card holding several files does not start one.
    public static func isDraggable(_ summary: ClipboardItemSummary) -> Bool {
        summary.kind != .files || summary.fileCount == 1
    }

    /// SwiftUI drags carry one item, so only a card whose content is a single file can
    /// be dragged. A card whose original moved away drags Copily's snapshot instead.
    private static func fileFlavours(_ detail: ClipboardItemDetail) -> [CardDragFlavour] {
        guard detail.fileReferences.count == 1, let file = detail.fileReferences.first else {
            return []
        }
        if file.isOriginalAvailable {
            return [CardDragFlavour(typeIdentifier: fileURLTypeIdentifier, source: .file(file.url))]
        }
        if let snapshot = file.snapshot {
            return [CardDragFlavour(typeIdentifier: fileURLTypeIdentifier, source: .assetFile(snapshot))]
        }
        return []
    }

    // MARK: - Building blocks

    private static func flavour(
        _ kind: ClipboardRepresentationKind,
        of detail: ClipboardItemDetail
    ) -> CardDragFlavour? {
        detail.representation(kind).flatMap(flavour(from:))
    }

    private static func flavour(from representation: ClipboardRepresentation) -> CardDragFlavour? {
        let typeIdentifier = representation.kind.pasteboardType
        switch representation.payload {
        case .text(let value):
            return CardDragFlavour(typeIdentifier: typeIdentifier, source: .text(value))
        case .data(let bytes):
            return CardDragFlavour(typeIdentifier: typeIdentifier, source: .data(bytes))
        case .asset(let reference):
            return CardDragFlavour(typeIdentifier: typeIdentifier, source: .asset(reference))
        }
    }

    private static func derivedPlainText(of detail: ClipboardItemDetail) -> String? {
        if let html = detail.representation(.html)?.text {
            return PlainTextExtraction.plainText(fromHTML: html)
        }
        if let rtf = detail.representation(.rtf)?.data {
            return PlainTextExtraction.plainText(fromRTF: rtf)
        }
        return nil
    }

    /// Image flavours in fidelity order: lossless first, then the rest.
    private static let imageKinds: [ClipboardRepresentationKind] = [.png, .tiff, .jpeg, .heic, .gif, .webP]

    private static let imageTypeIdentifiers = Set(imageKinds.map(\.pasteboardType))
}
