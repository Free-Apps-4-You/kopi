import Foundation

/// Identifies one search request so stale answers can be dropped.
public struct SearchRequestToken: Sendable, Hashable {
    public let generation: Int

    public init(generation: Int) {
        self.generation = generation
    }
}

/// What a search request produced.
public enum SearchDelivery: Sendable, Hashable {
    case results(HistoryPageResult, generation: Int)
    /// A newer request replaced this one; the caller must discard it.
    case superseded(generation: Int)

    public var page: HistoryPageResult? {
        if case .results(let page, _) = self { return page }
        return nil
    }

    public var items: [ClipboardItemSummary] {
        page?.items ?? []
    }

    public var generation: Int {
        switch self {
        case .results(_, let generation), .superseded(let generation): generation
        }
    }

    public var isSuperseded: Bool {
        if case .superseded = self { return true }
        return false
    }
}

/// Debounces searches, cancels superseded requests and discards stale responses.
///
/// The controller is the search entry point for the UI: typing quickly leaves only
/// the newest query standing, and an answer that arrives after the query changed is
/// reported as `.superseded` instead of being shown.
public actor ClipboardSearchController {
    /// Debounce interval required by the interaction design.
    public static let defaultDebounceInterval = Duration.milliseconds(120)

    private let store: HistoryStore
    private let debounceInterval: Duration
    private var generation = 0
    private var latestGeneration = 0
    private var pending: [Int: HistoryQuery] = [:]

    public init(
        store: HistoryStore,
        debounceInterval: Duration = ClipboardSearchController.defaultDebounceInterval
    ) {
        self.store = store
        self.debounceInterval = debounceInterval
    }

    /// Registers a request and returns the token whose answer matters.
    public func submit(_ query: HistoryQuery) -> SearchRequestToken {
        generation += 1
        latestGeneration = generation
        pending = [generation: query]
        return SearchRequestToken(generation: generation)
    }

    /// Waits out the debounce interval and returns results, or `.superseded` when a
    /// newer request was submitted meanwhile.
    ///
    /// Debouncing is what typing needs; programmatic loads pass `debounce: false` so
    /// they answer immediately.
    public func results(for token: SearchRequestToken, debounce: Bool = true) async throws -> SearchDelivery {
        defer { pending[token.generation] = nil }
        try Task.checkCancellation()
        guard token.generation == latestGeneration, pending[token.generation] != nil else {
            pending[token.generation] = nil
            return .superseded(generation: token.generation)
        }
        if debounce, debounceInterval > .zero {
            try await Task.sleep(for: debounceInterval)
        }
        guard let query = pending[token.generation], token.generation == latestGeneration else {
            pending[token.generation] = nil
            return .superseded(generation: token.generation)
        }
        let page = try await store.page(query)
        try Task.checkCancellation()
        pending[token.generation] = nil
        guard token.generation == latestGeneration else {
            return .superseded(generation: token.generation)
        }
        return .results(page, generation: token.generation)
    }

    /// Submits and answers in one step.
    public func search(_ query: HistoryQuery, debounce: Bool = true) async throws -> SearchDelivery {
        let token = submit(query)
        return try await results(for: token, debounce: debounce)
    }

    /// Invalidates everything in flight, for example when the panel closes.
    public func cancel() {
        generation += 1
        latestGeneration = generation
        pending.removeAll()
    }

    public var latestRequestGeneration: Int {
        latestGeneration
    }

    public var pendingRequestCount: Int {
        pending.count
    }
}
