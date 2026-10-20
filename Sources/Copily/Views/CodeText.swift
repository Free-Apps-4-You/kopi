import SwiftUI
import CopilyCore

/// Text rendered as code: a monospaced font and the theme's restrained token colours.
/// Only the analysed prefix carries tokens; everything after stays in the text colour.
struct CodeText: View {
    let text: String
    let highlight: CodeHighlight
    var size: CGFloat = 11.5
    var lineSpacing: CGFloat = 2
    var lineLimit: Int?

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(attributed)
            .font(.system(size: size, design: .monospaced))
            .lineSpacing(lineSpacing)
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        Self.attributedString(text: text, highlight: highlight, contrast: contrast)
    }

    static func attributedString(
        text: String,
        highlight: CodeHighlight,
        contrast: ColorSchemeContrast
    ) -> AttributedString {
        let source = text as NSString
        var result = AttributedString()
        for token in highlight.tokens {
            let location = max(0, token.range.lowerBound)
            let length = min(token.range.upperBound, source.length) - location
            guard length > 0 else { continue }
            var fragment = AttributedString(source.substring(with: NSRange(location: location, length: length)))
            if let color = CopilyTheme.Code.tokenColor(token.tokenClass, contrast: contrast) {
                fragment.foregroundColor = color
            }
            result.append(fragment)
        }
        if source.length > highlight.length {
            result.append(AttributedString(source.substring(from: highlight.length)))
        }
        return result
    }
}

/// Small language label of a code card: "Swift", "JSON", "Shell"…
struct CodeLanguageBadge: View {
    let language: CodeLanguage
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(language.displayName)
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(CopilyTheme.accent)
            .background(Capsule().fill(CopilyTheme.accent.opacity(contrast == .increased ? 0.24 : 0.13)))
            .overlay(Capsule().strokeBorder(CopilyTheme.accent.opacity(0.40), lineWidth: 0.5))
            .accessibilityLabel("\(language.displayName) code")
    }
}
