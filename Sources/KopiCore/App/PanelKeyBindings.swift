import Foundation

/// What is on screen in the panel, which decides what a key press means.
public enum PanelPresentation: Sendable, Hashable {
    /// The tab content: grid of cards, search field, filters.
    case grid
    /// A larger preview of one card.
    case preview
    /// An open editor. Text input belongs to the editor, so only Escape is a command.
    case editor
}

/// A key press reduced to the facts the panel reacts to.
public struct PanelKeyEvent: Sendable, Hashable {
    public var keyCode: UInt16
    /// Characters the key produces, ignoring modifiers.
    public var characters: String
    public var modifiers: HotkeyModifiers
    public var presentation: PanelPresentation
    /// A text field or text view has the keyboard focus.
    public var isTextEditing: Bool
    /// There is a selected card, or at least one visible card to fall back on.
    public var hasVisibleCard: Bool
    /// Cards currently on screen, which bounds the ⌘1–9 shortcuts.
    public var visibleCardCount: Int
    /// The collection shelf is the section on show.
    public var isCollectionShown: Bool

    public init(
        keyCode: UInt16,
        characters: String = "",
        modifiers: HotkeyModifiers = [],
        presentation: PanelPresentation = .grid,
        isTextEditing: Bool = false,
        hasVisibleCard: Bool = false,
        visibleCardCount: Int = 0,
        isCollectionShown: Bool = false
    ) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
        self.presentation = presentation
        self.isTextEditing = isTextEditing
        self.hasVisibleCard = hasVisibleCard
        self.visibleCardCount = visibleCardCount
        self.isCollectionShown = isCollectionShown
    }
}

/// What a key press asks the panel to do.
public enum PanelKeyAction: Sendable, Hashable {
    case dismiss
    case closePreview
    case cancelEditor
    case pasteSelection
    case copySelection
    case togglePreview
    case editSelection
    case togglePin
    /// Cards are numbered from one, in grid order.
    case pasteVisibleCard(Int)
    /// Adds the current clipboard to the collection shelf.
    case pasteIntoCollection
    case none
}

/// Keyboard interaction of the panel: Return pastes, ⌘C copies, Space previews,
/// ⌘E edits, ⌘P pins and, on the collection shelf, ⌘V collects a copy.
///
/// Kept apart from AppKit so every key the panel reacts to can be checked as data.
public enum PanelKeyBindings {
    public static let escapeKeyCode: UInt16 = 53
    public static let returnKeyCode: UInt16 = 36
    public static let keypadEnterKeyCode: UInt16 = 76
    public static let spaceKeyCode: UInt16 = 49
    public static let cKeyCode: UInt16 = 8
    public static let eKeyCode: UInt16 = 14
    public static let pKeyCode: UInt16 = 35
    public static let vKeyCode: UInt16 = 9
    /// Virtual key codes of the top-row digits "1" … "9".
    public static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    public static func action(for event: PanelKeyEvent) -> PanelKeyAction {
        if event.presentation == .editor {
            return event.keyCode == escapeKeyCode ? .cancelEditor : .none
        }
        if event.presentation == .preview {
            if event.keyCode == escapeKeyCode { return .closePreview }
            if event.keyCode == returnKeyCode || event.keyCode == keypadEnterKeyCode {
                return event.hasVisibleCard ? .pasteSelection : .none
            }
            return .none
        }

        if event.keyCode == escapeKeyCode {
            return .dismiss
        }
        if event.keyCode == returnKeyCode || event.keyCode == keypadEnterKeyCode {
            return event.hasVisibleCard ? .pasteSelection : .none
        }
        if event.modifiers == [.command] {
            switch event.keyCode {
            case cKeyCode: return event.hasVisibleCard ? .copySelection : .none
            case eKeyCode: return event.hasVisibleCard ? .editSelection : .none
            case pKeyCode: return event.hasVisibleCard ? .togglePin : .none
            case vKeyCode: return event.isCollectionShown && !event.isTextEditing ? .pasteIntoCollection : .none
            default:
                if let index = digitKeyCodes.firstIndex(of: event.keyCode), index < event.visibleCardCount {
                    return .pasteVisibleCard(index + 1)
                }
                return .none
            }
        }
        if event.keyCode == spaceKeyCode {
            // A space belongs to whatever the user is typing.
            return event.isTextEditing || !event.hasVisibleCard ? .none : .togglePreview
        }
        return .none
    }
}
