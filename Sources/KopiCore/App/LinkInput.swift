import Foundation

/// Accepts what a person types into the link editor and turns it into a URL.
public enum LinkInput {
    /// Trims the text, supplies `https://` when no scheme was typed, and rejects
    /// anything that cannot address a resource.
    public static func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate = hasScheme(trimmed) ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return nil
        }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host(), !host.isEmpty else { return nil }
        }
        return url
    }

    private static func hasScheme(_ text: String) -> Bool {
        guard let separator = text.range(of: ":") else { return false }
        let scheme = text[text.startIndex ..< separator.lowerBound]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }
}
