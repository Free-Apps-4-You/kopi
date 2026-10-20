import Foundation
import CopilyCore

/// Headless entry point of the design: `swift run Copily --selfcheck` exercises the
/// core against a throwaway database and prints a summary, so the storage layer can
/// be verified without a UI.
enum CopilySelfCheck {
    /// Runs the check on a worker and exits the process with its status.
    ///
    /// Nothing in the check needs the main actor, so the main thread can wait here
    /// while the application's own run loop has not started yet.
    static func runHeadless() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        let status = StatusBox()
        Task.detached(priority: .userInitiated) {
            status.store(await run())
            semaphore.signal()
        }
        semaphore.wait()
        exit(status.value)
    }

    /// Prints the summary, returning the process status.
    static func run() async -> Int32 {
        do {
            let summary = try await runChecks()
            print(summary)
            print("Copily core self-check passed.")
            return 0
        } catch {
            let message = "Copily core self-check failed: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            return 1
        }
    }

    private static func runChecks() async throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("copily-selfcheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let assetStore = try AssetStore(rootDirectory: root.appendingPathComponent("Assets", isDirectory: true))
        let store = try HistoryStore(
            path: root.appendingPathComponent("history.sqlite").path,
            assetStore: assetStore
        )

        let now = Date()
        let session = try await store.beginSession(now: now)
        let diagnostics = try await store.diagnostics()

        let firstText = "https://example.com/copily?tab=clipboard&page=2"
        let first = try await store.insert(
            ClipboardItemInsertion(
                kind: .text,
                text: firstText,
                representations: [ClipboardRepresentation(kind: .plainText, payload: .text(firstText))],
                sourceApp: SourceAppInfo(bundleIdentifier: "com.apple.Safari", name: "Safari"),
                origin: .external(changeCount: 1),
                capturedAt: now
            )
        )
        let duplicate = try await store.insert(
            ClipboardItemInsertion(
                kind: .text,
                text: firstText,
                representations: [ClipboardRepresentation(kind: .plainText, payload: .text(firstText))],
                origin: .external(changeCount: 2),
                capturedAt: now
            )
        )

        let code = "let total = items.reduce(0) { $0 + $1.count }"
        _ = try await store.insert(
            ClipboardItemInsertion(
                kind: .text,
                text: code,
                representations: [ClipboardRepresentation(kind: .plainText, payload: .text(code))],
                origin: .external(changeCount: 3),
                capturedAt: now
            )
        )

        let expired = "clipboard text from last week"
        _ = try await store.insert(
            ClipboardItemInsertion(
                kind: .text,
                text: expired,
                representations: [ClipboardRepresentation(kind: .plainText, payload: .text(expired))],
                origin: .external(changeCount: 4),
                capturedAt: now.addingTimeInterval(-8 * 24 * 60 * 60)
            )
        )

        let imageData = Data((0..<4096).map { UInt8($0 % 251) })
        let image = try await assetStore.importData(imageData, kind: .image, fileExtension: "png")
        _ = try await store.insert(
            ClipboardItemInsertion(
                kind: .image,
                label: "Sample capture",
                representations: [ClipboardRepresentation(kind: .png, payload: .asset(image.reference))],
                origin: .external(changeCount: 5),
                capturedAt: now
            )
        )

        let collectedText = "kept on the collection shelf"
        let collected = try await store.insert(
            ClipboardItemInsertion(
                kind: .text,
                text: collectedText,
                representations: [ClipboardRepresentation(kind: .plainText, payload: .text(collectedText))],
                origin: .external(changeCount: 7),
                capturedAt: now.addingTimeInterval(-40 * 24 * 60 * 60),
                destination: .collection
            )
        )

        let originalFile = root.appendingPathComponent("Report.txt")
        try Data("Pinned content that must outlive the original file".utf8).write(to: originalFile)
        let fileInsertion = ClipboardItemInsertion(
            kind: .files,
            representations: [],
            fileReferences: [
                FileReference(path: originalFile.path, displayName: "Report.txt", byteSize: 46)
            ],
            origin: .external(changeCount: 6),
            capturedAt: now
        )
        let fileResult = try await store.insert(fileInsertion)
        let pinnedFile = try await store.setPinned(true, for: fileResult.itemID, now: now)

        let edited = try await store.edit(
            .text("https://example.com/copily?tab=pinned&page=3", label: "Copily plan"),
            for: first.itemID
        )

        let searchHits = try await store.page(HistoryQuery(text: "tab=pinned", page: HistoryPage(limit: 10)))
        let shortQuery = try await store.page(HistoryQuery(text: "ab", page: HistoryPage(limit: 10)))
        let pinnedCards = try await store.page(HistoryQuery(scope: .pinned))
        let cleanup = try await store.runCleanup(trigger: .periodic, now: now)

        // The collected card is older than the retention window, so only the shelf keeps
        // it. A second store over the same file checks that it is there after a relaunch.
        let relaunchedStore = try HistoryStore(path: store.path, assetStore: assetStore)
        _ = try await relaunchedStore.beginSession(now: now)
        let collectionCards = try await relaunchedStore.page(HistoryQuery(scope: .collection))
        guard collectionCards.items.map(\.id) == [collected.itemID] else {
            throw SelfCheckError.failed("the collected card did not survive cleanup and a relaunch")
        }
        try await relaunchedStore.endSession(now: now)

        let snapshot = try await store.detail(for: pinnedFile.id)?.fileSnapshots.first
        try FileManager.default.removeItem(at: originalFile)
        var restored = Data()
        if let snapshot {
            restored = try await assetStore.readData(for: snapshot)
        }
        let statistics = try await store.statistics()

        var lines: [String] = []
        lines.append("Copily core self-check")
        lines.append("  database            \(store.path)")
        lines.append("  journal / sync      \(diagnostics.journalMode) / synchronous=\(diagnostics.synchronous)")
        lines.append("  session             \(session.sessionID) (interrupted: \(session.recoveredFromInterruptedExit))")
        lines.append("  retention           \(statistics.retention.displayName)")
        lines.append("  inserted            \(first.itemID) plus \(statistics.itemCount) stored cards")
        lines.append("  dedupe              \(duplicate.didCreateItem ? "created a new card" : "collapsed onto the existing card")")
        lines.append("  edited              \(edited.displayTitle)")
        lines.append("  search 'tab=pinned' \(searchHits.items.count) hit(s) via \(searchHits.searchMode.rawValue)")
        lines.append("  search 'ab'         \(shortQuery.items.count) hit(s) via \(shortQuery.searchMode.rawValue)")
        lines.append("  pinned cards        \(pinnedCards.items.count)")
        lines.append("  collection          \(collectionCards.items.count) card(s) kept through cleanup and a relaunch")
        lines.append("  retention pass      removed \(cleanup.removedItemCount) card(s), \(cleanup.removedAssetCount) asset(s)")
        lines.append("  preserved file      \(restored.count) bytes readable after deleting the original")
        lines.append("  assets              \(statistics.assetCount) file(s), \(statistics.assetByteCount) bytes")

        try await store.endSession(now: now)
        return lines.joined(separator: "\n")
    }
}

/// A state the design forbids, found by the self check's own assertions.
enum SelfCheckError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let reason): reason
        }
    }
}

/// Status written by the check on a worker and read once it has finished.
private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32 = 1

    func store(_ value: Int32) {
        lock.withLock { status = value }
    }

    var value: Int32 {
        lock.withLock { status }
    }
}
