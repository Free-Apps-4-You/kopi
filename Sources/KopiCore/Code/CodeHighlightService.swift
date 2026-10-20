import Foundation

/// Highlights clipboard text off the caller's actor and caches the outcome.
///
/// Scrollling cards never run the detector or the tokeniser on the main actor: a card
/// asks this actor once per visible piece of content, the answer is keyed by the
/// content's digest and the source app that helped decide it, and repeated requests —
/// scroll passes, expansions, the preview overlay — hit the cache. The cache is
/// bounded and evicts in insertion order, matching the store and thumbnail caches.
public actor CodeHighlightService {
    public static let defaultCacheLimit = 256

    private enum Entry {
        case code(CodeHighlight)
        case notCode
    }

    private let detector: CodeDetector
    private let cacheLimit: Int
    private var storage: [String: Entry] = [:]
    private var order: [String] = []

    public init(detector: CodeDetector = CodeDetector(), cacheLimit: Int = CodeHighlightService.defaultCacheLimit) {
        self.detector = detector
        self.cacheLimit = max(1, cacheLimit)
    }

    /// The highlight of `text` when it reads as code, `nil` when it should stay plain.
    public func highlight(text: String, sourceApp: SourceAppInfo? = nil) -> CodeHighlight? {
        let key = cacheKey(text: text, sourceApp: sourceApp)
        if let entry = storage[key] {
            touch(key)
            switch entry {
            case .code(let highlight): return highlight
            case .notCode: return nil
            }
        }

        let result: CodeHighlight?
        if let language = detector.detect(text, sourceApp: sourceApp) {
            result = CodeTokenizer.highlight(text, language: language)
        } else {
            result = nil
        }
        store(key, result)
        return result
    }

    /// Number of cached outcomes, for tests and diagnostics.
    var cachedEntryCount: Int { storage.count }

    private func cacheKey(text: String, sourceApp: SourceAppInfo?) -> String {
        let digest = ContentHasher.sha256Hex(text: text)
        return "\(digest):\(sourceApp?.bundleIdentifier ?? "-")"
    }

    private func store(_ key: String, _ result: CodeHighlight?) {
        storage[key] = result.map(Entry.code) ?? .notCode
        order.append(key)
        while order.count > cacheLimit, let oldest = order.first {
            order.removeFirst()
            if oldest != key {
                storage.removeValue(forKey: oldest)
            }
        }
    }

    private func touch(_ key: String) {
        guard let index = order.firstIndex(of: key), index != order.count - 1 else { return }
        order.remove(at: index)
        order.append(key)
    }
}
