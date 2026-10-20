#if canImport(AppKit)
import AppKit
import Foundation

/// Pasteboard access backed by `NSPasteboard`.
///
/// AppKit is imported for the adapters only: the capture pipeline works with
/// ``PasteboardAccessing`` and immutable snapshots, so capture behaviour is verified
/// without the user's real clipboard.
///
/// The reference to `NSPasteboard` is `@unchecked Sendable` because access is confined
/// to the capture worker: every call reaches it from ``ClipboardService``, which
/// serialises them, and no state is held here beyond the pasteboard itself.
public final class NSPasteboardAccess: @unchecked Sendable, PasteboardAccessing {
    /// The flavours Kopi stores. Everything else is left untouched on the pasteboard.
    public static let supportedTypes: Set<String> = Set(
        ClipboardRepresentationKind.allCases
            .filter { $0 != .pdf }
            .map(\.pasteboardType)
    )

    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    /// Reads the supported flavours of every item.
    ///
    /// macOS 15.4 and later expose the user's clipboard access choice. When it is
    /// `alwaysDeny` the read is refused outright, which the capture loop treats as a
    /// block instead of retrying. A read the user refuses while the system is set to
    /// ask simply returns an empty snapshot.
    public func readSnapshot() throws -> PasteboardSnapshot {
        if #available(macOS 15.4, *), pasteboard.accessBehavior == .alwaysDeny {
            throw PasteboardAccessError.accessDenied
        }
        let start = pasteboard.changeCount
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            PasteboardItemSnapshot(
                flavours: item.types.compactMap { type in
                    guard Self.supportedTypes.contains(type.rawValue), let data = item.data(forType: type) else {
                        return nil
                    }
                    return PasteboardFlavour(type: type.rawValue, data: data)
                }
            )
        }
        return PasteboardSnapshot(changeCount: start, items: items)
    }

    @discardableResult
    public func write(_ request: PasteboardWriteRequest) throws -> Int {
        let items = request.items.map { snapshot in
            let item = NSPasteboardItem()
            for flavour in snapshot.flavours {
                item.setData(flavour.data, forType: NSPasteboard.PasteboardType(flavour.type))
            }
            return item
        }
        guard !items.isEmpty else {
            throw PasteboardAccessError.writeFailed("the request has no pasteboard items")
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else {
            throw PasteboardAccessError.writeFailed("the pasteboard rejected the content")
        }
        return pasteboard.changeCount
    }
}

/// Source application of a copy, from `NSWorkspace`.
public struct WorkspaceFrontmostAppProvider: FrontmostAppProviding {
    public init() {}

    public func frontmostApp() -> SourceAppInfo? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return SourceAppInfo(
            bundleIdentifier: application.bundleIdentifier,
            name: application.localizedName,
            processIdentifier: application.processIdentifier
        )
    }
}

/// System sleep and wake from `NSWorkspace`.
public struct WorkspaceLifecycleObserver: PasteboardLifecycleObserving {
    public init() {}

    public func observe(
        _ handler: @Sendable @escaping (PasteboardLifecycleEvent) async -> Void
    ) async -> any PasteboardLifecycleObservation {
        let center = NSWorkspace.shared.notificationCenter
        let tokens: [any NSObjectProtocol] = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
                Task { await handler(.willSleep) }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
                Task { await handler(.didWake) }
            }
        ]
        return WorkspaceLifecycleObservation(center: center, tokens: tokens)
    }
}

final class WorkspaceLifecycleObservation: PasteboardLifecycleObservation, @unchecked Sendable {
    private let center: NotificationCenter
    private let tokens: [any NSObjectProtocol]

    init(center: NotificationCenter, tokens: [any NSObjectProtocol]) {
        self.center = center
        self.tokens = tokens
    }

    func cancel() {
        for token in tokens {
            center.removeObserver(token)
        }
    }
}
#endif
