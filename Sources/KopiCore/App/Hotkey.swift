import Foundation

/// Modifier keys of a shortcut, described without Carbon or AppKit so shortcuts can
/// be stored, compared and printed on their own.
public struct HotkeyModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Stored as the bare raw value, and read from either that form or the keyed form
    /// an intermediate build wrote, so archived settings stay readable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let rawValue = try? container.decode(Int.self) {
            self.init(rawValue: rawValue)
            return
        }
        struct Keyed: Decodable { let rawValue: Int }
        self.init(rawValue: try container.decode(Keyed.self).rawValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    public static let control = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift = HotkeyModifiers(rawValue: 1 << 3)

    /// Bit mask `RegisterEventHotKey` expects. The values are the stable Carbon
    /// constants `cmdKey`, `shiftKey`, `optionKey` and `controlKey`.
    public var carbonValue: UInt32 {
        var value: UInt32 = 0
        if contains(.command) { value |= 1 << 8 }
        if contains(.shift) { value |= 1 << 9 }
        if contains(.option) { value |= 1 << 11 }
        if contains(.control) { value |= 1 << 12 }
        return value
    }

    /// Modifiers in the order macOS writes them: control, option, shift, command.
    public var displayString: String {
        var text = String()
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

/// A global keyboard shortcut.
public struct HotkeyDefinition: Sendable, Hashable, Codable {
    /// Virtual key code, which is what a hot key registration uses.
    public var keyCode: UInt16
    public var modifiers: HotkeyModifiers
    /// Key label from the user's keyboard layout: "V", "1", "F5", "Space".
    public var keyLabel: String

    public init(keyCode: UInt16, modifiers: HotkeyModifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// The shortcut of the design: ⌥⌘V.
    public static let `default` = HotkeyDefinition(keyCode: 9, modifiers: [.option, .command], keyLabel: "V")

    public var displayString: String { modifiers.displayString + keyLabel }

    /// A shortcut without a modifier would swallow ordinary typing, and a modifier
    /// pressed on its own is not a shortcut.
    public var isValid: Bool {
        !modifiers.isEmpty && !keyLabel.isEmpty && !Self.isModifierKeyCode(keyCode)
    }

    /// Virtual key codes that are modifier keys themselves.
    public static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    public static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    /// Label shown for key codes that carry no printable character.
    public static let specialKeyNames: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 71: "⌧", 76: "⌤",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12", 114: "Help", 115: "↖", 116: "⇞",
        117: "⌦", 118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    /// Shortcut for a captured key press, or `nil` when the press cannot be one.
    public static func captured(keyCode: UInt16, modifiers: HotkeyModifiers, characters: String) -> HotkeyDefinition? {
        guard !isModifierKeyCode(keyCode), !modifiers.isEmpty else { return nil }
        guard let label = keyLabel(keyCode: keyCode, characters: characters), !label.isEmpty else { return nil }
        return HotkeyDefinition(keyCode: keyCode, modifiers: modifiers, keyLabel: label)
    }

    /// Label of a key press: the typed character, or the name of a key without one.
    public static func keyLabel(keyCode: UInt16, characters: String) -> String? {
        let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
        if let character = trimmed.first, !character.isNewline, character != "\u{7F}" {
            if character == " " { return "Space" }
            return String(character).uppercased()
        }
        return specialKeyNames[keyCode]
    }
}
