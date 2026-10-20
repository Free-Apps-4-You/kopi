import Combine
import Foundation

/// Why clipboard observation is switched off.
public enum ClipboardCapturePause: String, Sendable, Hashable, Codable, CaseIterable {
    /// The user turned capture off in Settings.
    case captureDisabled
    /// The Mac is asleep. Observation resumes after wake.
    case systemSleep

    public var displayName: String {
        switch self {
        case .captureDisabled: "Capture paused"
        case .systemSleep: "Mac asleep"
        }
    }
}

/// Why clipboard observation cannot continue.
public enum ClipboardCaptureBlock: String, Sendable, Hashable, Codable, CaseIterable {
    /// macOS reports that Copily may not read the pasteboard. Repeating the read is
    /// pointless, so observation stops until the block is cleared.
    case pasteboardAccessDenied

    public var displayName: String {
        switch self {
        case .pasteboardAccessDenied: "Clipboard access is denied"
        }
    }
}

/// What the capture loop is doing.
public enum ClipboardCaptureState: Sendable, Hashable, Codable {
    /// Not observing: capture has not been started, or has been stopped.
    case idle
    /// Polling, and reading content whenever the clipboard changes.
    case running
    /// Switched off deliberately, by the user or by system sleep.
    case paused(ClipboardCapturePause)
    /// Reading is refused by the system.
    case blocked(ClipboardCaptureBlock)

    public var isRunning: Bool { self == .running }

    public var pause: ClipboardCapturePause? {
        if case .paused(let pause) = self { return pause }
        return nil
    }

    public var block: ClipboardCaptureBlock? {
        if case .blocked(let block) = self { return block }
        return nil
    }

    public var isIdle: Bool { self == .idle }

    public var displayName: String {
        switch self {
        case .idle: "Not observing"
        case .running: "Observing the clipboard"
        case .paused(let pause): pause.displayName
        case .blocked(let block): block.displayName
        }
    }
}

/// What one polling tick did.
///
/// No case carries clipboard content: outcomes are for the UI and for diagnostics.
public enum ClipboardCaptureOutcome: Sendable, Hashable {
    /// The loop is not running.
    case idle
    /// The clipboard did not change since the previous tick.
    case unchanged(changeCount: Int)
    /// The change is Copily's own write, so it created no card.
    case ownCopy(itemID: ClipboardItemID, changeCount: Int)
    /// Capture was switched off, so the change was left for the next run.
    case paused(ClipboardCapturePause)
    /// Reading is refused by the system.
    case blocked(ClipboardCaptureBlock)
    /// The clipboard changed while the snapshot was being prepared; the next tick
    /// starts over with the newer content.
    case rejectedSnapshot(changeCount: Int)
    /// The source application is on the exclusion list.
    case excludedApp(changeCount: Int)
    /// The pasteboard held nothing Copily understands.
    case unsupported(changeCount: Int)
    /// Content preparation or storage failed. The failed generation is not retried.
    case failed(changeCount: Int, reason: String)
    /// A card was stored, or an existing card was refreshed.
    case captured(ClipboardItemInsertion, HistoryInsertionResult)

    /// The card this tick stored or refreshed, when there was one.
    public var summary: ClipboardItemSummary? {
        insertionResult?.summary
    }

    public var insertionResult: HistoryInsertionResult? {
        if case .captured(_, let result) = self { return result }
        return nil
    }

    /// The prepared capture, when a card was stored.
    public var insertion: ClipboardItemInsertion? {
        if case .captured(let insertion, _) = self { return insertion }
        return nil
    }

    /// The pasteboard generation this tick settled on, when it looked at one.
    public var changeCount: Int? {
        switch self {
        case .unchanged(let changeCount),
             .ownCopy(_, let changeCount),
             .rejectedSnapshot(let changeCount),
             .excludedApp(let changeCount),
             .unsupported(let changeCount),
             .failed(let changeCount, _):
            changeCount
        case .captured(let insertion, _):
            insertion.origin.changeCount
        case .idle, .paused, .blocked:
            nil
        }
    }
}

/// A card that has just been stored, carried to the main actor so an open panel can
/// show it without being reopened.
public struct ClipboardCaptureSignal: Sendable, Hashable {
    public let summary: ClipboardItemSummary
    public let timestamp: Date

    public init(summary: ClipboardItemSummary, timestamp: Date) {
        self.summary = summary
        self.timestamp = timestamp
    }
}

/// Main-actor mirror of the capture state, for the UI.
///
/// Clipboard access stays on the capture worker; views observe this object instead of
/// reaching into ``ClipboardService``.
@MainActor
public final class ClipboardCaptureStatus: ObservableObject {
    /// Where the capture loop is.
    @Published public private(set) var state: ClipboardCaptureState = .idle
    /// Bumped whenever ``state`` changes, so observers can spot updates cheaply.
    @Published public private(set) var revision = 0
    /// The most recent capture. Unlike ``state``, this changes on every stored card.
    @Published public private(set) var latestCapture: ClipboardCaptureSignal?

    public nonisolated init() {}

    /// Applies a state published by ``ClipboardService``.
    func apply(_ state: ClipboardCaptureState, revision: Int) {
        guard self.revision != revision else { return }
        self.state = state
        self.revision = revision
    }

    /// Records a capture that landed, waking observers even when ``state`` did not change.
    func applyCapture(_ signal: ClipboardCaptureSignal) {
        latestCapture = signal
    }
}
