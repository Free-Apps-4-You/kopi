import Foundation

/// An explicitly formatted color value. Bare numbers and fragments of prose are
/// deliberately left as text, so ordinary clipboard content is never reclassified.
public struct ClipboardColor: Sendable, Hashable {
    public let red: Int
    public let green: Int
    public let blue: Int
    public let alpha: Double

    public static func parse(_ input: String) -> ClipboardColor? {
        guard input.utf8.count <= 80 else { return nil }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") {
            let digits = String(text.dropFirst())
            guard [3, 4, 6, 8].contains(digits.count),
                  digits.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else { return nil }
            let expanded = digits.count <= 4 ? digits.map { "\($0)\($0)" }.joined() : digits
            let bytes = stride(from: 0, to: expanded.count, by: 2).compactMap { offset -> Int? in
                let start = expanded.index(expanded.startIndex, offsetBy: offset)
                let end = expanded.index(start, offsetBy: 2)
                return Int(expanded[start..<end], radix: 16)
            }
            return ClipboardColor(red: bytes[0], green: bytes[1], blue: bytes[2],
                                  alpha: bytes.count == 4 ? Double(bytes[3]) / 255 : 1)
        }
        let lower = text.lowercased()
        let hasAlpha = lower.hasPrefix("rgba(")
        guard (hasAlpha || lower.hasPrefix("rgb(")), lower.hasSuffix(")") else { return nil }
        let components = lower.dropFirst(hasAlpha ? 5 : 4).dropLast()
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard components.count == (hasAlpha ? 4 : 3) else { return nil }
        let channels = components.prefix(3).compactMap { value -> Int? in
            guard !value.isEmpty, value.allSatisfy({ "0123456789".contains($0) }),
                  let channel = Int(value), (0...255).contains(channel) else { return nil }
            return channel
        }
        guard channels.count == 3 else { return nil }
        let opacity = hasAlpha ? Double(components[3]) : 1
        guard let opacity, opacity.isFinite, (0...1).contains(opacity) else { return nil }
        return ClipboardColor(red: channels[0], green: channels[1], blue: channels[2], alpha: opacity)
    }

    public var hexString: String {
        let rgb = String(format: "#%02X%02X%02X", red, green, blue)
        return alpha == 1 ? rgb : rgb + String(format: "%02X", Int((alpha * 255).rounded()))
    }

    public var rgbString: String {
        if alpha == 1 { return "rgb(\(red), \(green), \(blue))" }
        let opacity = String(format: "%.4g", locale: Locale(identifier: "en_US_POSIX"), alpha)
        return "rgba(\(red), \(green), \(blue), \(opacity))"
    }
}
