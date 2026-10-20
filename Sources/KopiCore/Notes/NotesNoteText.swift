import Foundation

/// Read-only formatting of Apple Notes text for excerpts and previews.
public enum NotesNoteText {
    /// The note text for a title and a body, in the shape Notes stores it.
    /// The body of a note whose first line is its title. A note that does not start
    /// with its title is taken as it is.
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
    /// display, so they are unified before excerpts are prepared.
    static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
