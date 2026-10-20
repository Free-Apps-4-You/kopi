import AppKit
import Foundation
import UniformTypeIdentifiers
import KopiCore

/// Turns the item providers of a drop into the snapshot the capture pipeline stores.
///
/// All of it is loading: which flavours to read, and what a snapshot becomes, live in
/// ``DropCaptureMapping`` and ``CaptureProcessor``.
@MainActor
enum DroppedContent {
    /// Types a drop may offer, for the collection grid and the collection chip.
    static let supportedTypes: [UTType] = DropCaptureMapping.supportedKinds
        .compactMap { UTType($0.pasteboardType) }

    /// The card a Kopi drag carries, so dropping one of our own cards onto the
    /// collection collects that card instead of reading its flavours back.
    static func cardIdentifier(in provider: NSItemProvider) async -> ClipboardItemID? {
        guard provider.registeredTypeIdentifiers.contains(CardDragMapping.cardIdentifierType),
              let data = await loadData(from: provider, type: CardDragMapping.cardIdentifierType),
              let rawValue = String(data: data, encoding: .utf8),
              !rawValue.isEmpty
        else { return nil }
        return ClipboardItemID(rawValue: rawValue)
    }

    /// One snapshot item per dropped thing, in drop order, so a multi-file drop stays
    /// one card ordered the way it was dropped.
    static func snapshot(from providers: [NSItemProvider]) async -> PasteboardSnapshot {
        var items: [PasteboardItemSnapshot] = []
        for provider in providers {
            var flavours: [PasteboardFlavour] = []
            for kind in DropCaptureMapping.readableKinds(among: provider.registeredTypeIdentifiers) {
                guard let data = await data(of: kind, from: provider), !data.isEmpty else { continue }
                flavours.append(PasteboardFlavour(type: kind.pasteboardType, data: data))
            }
            items.append(PasteboardItemSnapshot(flavours: flavours))
        }
        return PasteboardSnapshot(changeCount: 0, items: items)
    }

    /// A file URL arrives as a URL, a path or the URL's bytes depending on the source
    /// application; all of them are stored as the URL string a Finder copy carries.
    private static func data(of kind: ClipboardRepresentationKind, from provider: NSItemProvider) async -> Data? {
        guard kind == .fileURL else {
            return await loadData(from: provider, type: kind.pasteboardType)
        }
        guard let item = await loadItem(from: provider, type: kind.pasteboardType) else { return nil }
        switch item {
        case let url as URL:
            return Data(url.absoluteString.utf8)
        case let url as NSURL:
            return url.absoluteString.map { Data($0.utf8) }
        case let text as String:
            return Data(text.utf8)
        case let data as Data:
            return data
        default:
            return nil
        }
    }

    private static func loadData(from provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func loadItem(from provider: NSItemProvider, type: String) async -> NSSecureCoding? {
        let loaded: LoadedItem = await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                continuation.resume(returning: LoadedItem(value: item))
            }
        }
        return loaded.value
    }
}

/// Carries a loaded item from an item provider's completion handler to the main actor.
private struct LoadedItem: @unchecked Sendable {
    let value: NSSecureCoding?
}
