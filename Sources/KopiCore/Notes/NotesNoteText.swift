import Foundation

/// How Kopi maps between the text of a note and the title and body an editor shows.
///
/// Notes keeps a note's name in its first line: the title a card shows is that first
/// line and the body Kopi edits is everything after it. Composing and splitting here
/// keeps the round trip in one place, so a saved edit reproduces the note's text.
public enum NotesNoteText {
    /// The note text for a title and a body, in the shape Notes stores it.
    public static func compose(title: String, body: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmedTitle.isEmpty, trimmedBody.isEmpty) {
        case (true, true):
            return ""
        case (true, false):
            return trimmedBody
        case (false, true):
            return trimmedTitle
        case (false, false):
            return trimmedTitle + "\n\n" + trimmedBody
        }
    }

    /// The body of a note whose first line is its title. A note that does not start
    /// with its title is taken as it is.
    public static func body(fromPlainText plainText: String, title: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = normalized(plainText).components(separatedBy: "\n")
        if !trimmedTitle.isEmpty,
           let firstLine = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[firstLine].trimmingCharacters(in: .whitespaces) == trimmedTitle {
            lines.removeSubrange(0 ... firstLine)
        }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// One line of note text for a card, with the whitespace runs collapsed.
    public static func excerpt(fromPlainText plainText: String, limit: Int = 220) -> String {
        let collapsed = normalized(plainText)
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Line endings vary between notes and between the scripting interface and the
    /// editor, so they are unified before anything is compared or split.
    static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
