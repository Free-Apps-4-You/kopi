import Foundation

/// Builds the text Copily searches and the patterns it searches with.
///
/// Folded text (lowercased, Unicode aware) is what is stored and matched, so the
/// FTS5 trigram index and the fallback scan agree on case insensitivity for every
/// script, not just ASCII.
public enum ClipboardSearchText {
    /// Longest searchable text stored per item, so a pathological clip cannot
    /// bloat the index.
    public static let indexedCharacterLimit = 32_768
    /// Length of the excerpt shown on a card.
    public static let excerptCharacterLimit = 240
    /// Below this many characters the trigram index cannot answer a substring
    /// search, and the store scans instead.
    public static let fullTextIndexMinimumLength = 3

    public static func folded(_ text: String) -> String {
        text.lowercased()
    }

    /// Whether a query is long enough for the trigram index.
    public static func usesFullTextIndex(_ query: String) -> Bool {
        folded(query).count >= fullTextIndexMinimumLength
    }

    /// FTS5 phrase query giving substring semantics, or `nil` when the query is
    /// too short for the index. Quoting and doubling the phrase separator means
    /// punctuation, URLs and code fragments never turn into query syntax.
    public static func fullTextPattern(for query: String) -> String? {
        let folded = folded(query)
        guard folded.count >= fullTextIndexMinimumLength else { return nil }
        return "\"" + folded.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Substitute pattern for the bounded scan used by short queries. The scan
    /// uses `instr`, so no escaping is required.
    public static func scanNeedle(for query: String) -> String {
        folded(query)
    }

    /// Text indexed for an item: content, URL, user label and file names.
    public static func searchText(text: String?, url: URL?, label: String?, fileNames: [String]) -> String {
        var components: [String] = []
        if let text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                components.append(String(trimmed.prefix(indexedCharacterLimit)))
            }
        }
        if let url, !url.absoluteString.isEmpty {
            components.append(url.absoluteString)
        }
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components.append(label.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !fileNames.isEmpty {
            components.append(fileNames.joined(separator: "\n"))
        }
        return components.joined(separator: "\n")
    }

    /// Card excerpt: collapsed whitespace, trimmed, truncated.
    public static func excerpt(from text: String, limit: Int = excerptCharacterLimit) -> String {
        var collapsed = String()
        collapsed.reserveCapacity(min(text.count, limit + 16))
        var previousWasWhitespace = false
        for character in text.prefix(indexedCharacterLimit) {
            if character.isWhitespace {
                if !previousWasWhitespace, !collapsed.isEmpty {
                    collapsed.append(" ")
                }
                previousWasWhitespace = true
            } else {
                collapsed.append(character)
                previousWasWhitespace = false
            }
        }
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
