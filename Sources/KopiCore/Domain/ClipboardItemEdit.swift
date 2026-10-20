import Foundation

/// A user edit of a stored card.
///
/// Fields left `nil` keep their stored value. Images and file copies accept a
/// label change only: their content is never rewritten.
public struct ClipboardItemEdit: Sendable, Hashable, Codable {
    /// `nil` keeps the current label, an empty string clears it.
    public var label: String?
    /// Replacement plain text. For rich text it becomes the new plain flavour.
    public var plainText: String?
    /// Replacement URL of a link card.
    public var url: URL?
    /// Replacement rich text; its plain text is used when `plainText` is `nil`.
    public var richText: RichTextDocument?
    public var editedAt: Date

    public init(
        label: String? = nil,
        plainText: String? = nil,
        url: URL? = nil,
        richText: RichTextDocument? = nil,
        editedAt: Date = Date()
    ) {
        self.label = label
        self.plainText = plainText
        self.url = url
        self.richText = richText
        self.editedAt = editedAt
    }

    /// Label-only edit, for images, file copies and quick renames.
    public static func label(_ label: String, editedAt: Date = Date()) -> ClipboardItemEdit {
        ClipboardItemEdit(label: label, editedAt: editedAt)
    }

    /// Edit of the stored text content.
    public static func text(_ plainText: String, label: String? = nil, editedAt: Date = Date()) -> ClipboardItemEdit {
        ClipboardItemEdit(label: label, plainText: plainText, editedAt: editedAt)
    }

    /// Edit of a link, optionally changing its display label.
    public static func link(_ url: URL, label: String? = nil, editedAt: Date = Date()) -> ClipboardItemEdit {
        ClipboardItemEdit(label: label, url: url, editedAt: editedAt)
    }

    public var isEmpty: Bool {
        label == nil && plainText == nil && url == nil && richText == nil
    }

    public var changesContent: Bool {
        plainText != nil || url != nil || richText != nil
    }

    /// New plain text implied by the edit, if any.
    public var resolvedPlainText: String? {
        plainText ?? richText?.plainText
    }
}
