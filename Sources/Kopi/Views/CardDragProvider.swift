import AppKit
import SwiftUI
import KopiCore

/// Everything a card's drag load handlers need: the store is reached directly from background
/// tasks, and only once a drop destination has asked for the content.
struct CardDragSource: Sendable {
    let itemID: ClipboardItemID
    let kind: ClipboardItemKind
    let loadDetail: @Sendable () async -> ClipboardItemDetail?
    let readAsset: @Sendable (AssetReference) async -> Data?
    let assetFileURL: @Sendable (AssetReference) -> URL
}

/// The `NSItemProvider` of one card.
///
/// Registrations happen the moment a drag starts and are decided by the card's kind
/// alone, so creating the provider is cheap and synchronous. The detail and every
/// payload, including an image's stored bytes, are resolved only when a destination
/// asks for them; ``CardDragMapping`` decides which flavour that request receives.
@MainActor
enum CardDrag {
    static func provider(for source: CardDragSource) -> NSItemProvider {
        let provider = NSItemProvider()
        // The card's identifier travels with the drag, so a drop inside Kopi recognises
        // the card it came from; applications that do not know the type ignore it.
        provider.registerDataRepresentation(
            forTypeIdentifier: CardDragMapping.cardIdentifierType,
            visibility: .all
        ) { completion in
            completion(Data(source.itemID.rawValue.utf8), nil)
            return nil
        }
        for registration in CardDragMapping.registrations(for: source.kind) {
            add(registration, to: provider, source: source)
        }
        return provider
    }

    private static func add(
        _ registration: CardDragRegistration,
        to provider: NSItemProvider,
        source: CardDragSource
    ) {
        switch registration {
        case .file(let typeIdentifier):
            provider.registerFileRepresentation(
                forTypeIdentifier: typeIdentifier,
                fileOptions: [],
                visibility: .all
            ) { completion in
                Task.detached {
                    guard case .file(let url)? = await resolve(registration, in: source) else {
                        completion(nil, false, CardDragError.unavailable)
                        return
                    }
                    completion(url, false, nil)
                }
                return nil
            }
        case .data(let typeIdentifier):
            provider.registerDataRepresentation(
                forTypeIdentifier: typeIdentifier,
                visibility: .all
            ) { completion in
                Task.detached {
                    guard case .data(let bytes)? = await resolve(registration, in: source) else {
                        completion(nil, CardDragError.unavailable)
                        return
                    }
                    completion(bytes, nil)
                }
                return nil
            }
        }
    }

    // MARK: - Resolving

    private enum Resolved: Sendable {
        case data(Data)
        case file(URL)
    }

    nonisolated private static func resolve(_ registration: CardDragRegistration, in source: CardDragSource) async -> Resolved? {
        guard let detail = await source.loadDetail(),
              let flavour = CardDragMapping.flavour(
                  for: registration,
                  in: CardDragMapping.flavours(for: detail)
              )
        else { return nil }
        switch flavour.source {
        case .text(let value):
            return .data(Data(value.utf8))
        case .data(let bytes):
            return .data(bytes)
        case .asset(let reference):
            return await source.readAsset(reference).map(Resolved.data)
        case .file(let url):
            return .file(url)
        case .assetFile(let reference):
            return .file(source.assetFileURL(reference))
        }
    }
}

/// A drag whose content could not be resolved when the destination asked for it.
enum CardDragError: Error, Sendable {
    case unavailable
}

/// Text promises resolve off the UI thread, even if the destination waits synchronously.
enum NoteDrag {
    static func provider(client: any NotesClient, id: NotesNoteID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: "public.utf8-plain-text", visibility: .all) { completion in
            Task.detached {
                do {
                    guard let note = try await client.notes(withIDs: [id]).first else {
                        completion(nil, CardDragError.unavailable)
                        return
                    }
                    completion(Data(note.plainText.utf8), nil)
                } catch { completion(nil, error) }
            }
            return nil
        }
        return provider
    }
}
