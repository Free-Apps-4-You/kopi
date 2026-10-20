import AppKit
import SwiftUI
import CopilyCore

/// Rich-text editor with the basic formatting of the design: bold, italic and
/// underline, applied to the selection.
///
/// The editor works on an attributed string and hands back runs, which is what
/// ``HistoryStore`` rebuilds the HTML and RTF flavours from when the card is saved.
struct RichTextEditorView: NSViewRepresentable {
    @Binding var document: RichTextDocument

    func makeCoordinator() -> Coordinator {
        Coordinator(document: $document)
    }

    func makeNSView(context: Context) -> RichTextEditorHost {
        let host = RichTextEditorHost()
        host.textView.delegate = context.coordinator
        host.setText(RichTextCoding.attributedString(from: document))
        context.coordinator.lastEmitted = document
        return host
    }

    func updateNSView(_ nsView: RichTextEditorHost, context: Context) {
        context.coordinator.document = $document
        guard context.coordinator.lastEmitted != document else { return }
        context.coordinator.lastEmitted = document
        nsView.setText(RichTextCoding.attributedString(from: document))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var document: Binding<RichTextDocument>
        /// Document last exchanged with the text view, so update cycles stop here.
        var lastEmitted: RichTextDocument?

        init(document: Binding<RichTextDocument>) {
            self.document = document
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let document = RichTextCoding.document(from: textView.attributedString())
            lastEmitted = document
            self.document.wrappedValue = document
        }
    }
}

/// Scroll view, toolbar and text view of the rich-text editor.
final class RichTextEditorHost: NSView {
    let textView = FormattingTextView()

    private let scrollView = NSScrollView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
        ]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSStackView(views: [
            toolbarButton(symbol: "bold", action: #selector(FormattingTextView.toggleBold), tooltip: "Bold ⌘B"),
            toolbarButton(symbol: "italic", action: #selector(FormattingTextView.toggleItalic), tooltip: "Italic ⌘I"),
            toolbarButton(symbol: "underline", action: #selector(FormattingTextView.toggleUnderline), tooltip: "Underline ⌘U")
        ])
        toolbar.orientation = .horizontal
        toolbar.spacing = 4
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(toolbar)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RichTextEditorHost is created in code")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.textView)
        }
    }

    func setText(_ attributed: NSAttributedString) {
        textView.textStorage?.setAttributedString(attributed)
    }

    private func toolbarButton(symbol: String, action: Selector, tooltip: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let button = CopilyTooltipButton(image: image, target: textView, action: action)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.hintText = tooltip
        return button
    }
}

/// Text view that owns the ⌘B, ⌘I and ⌘U shortcuts of the editor.
final class FormattingTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "b": toggleBold(); return
            case "i": toggleItalic(); return
            case "u": toggleUnderline(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    @objc func toggleBold() { toggle(.bold) }
    @objc func toggleItalic() { toggle(.italic) }
    @objc func toggleUnderline() { toggle(.underline) }

    /// Toggles one trait over the selection, leaving the rest of the run alone.
    func toggle(_ trait: RichTextDocument.Traits) {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return }
        let adding = !selectionHas(trait, in: range)

        storage.beginEditing()
        if trait == .bold || trait == .italic {
            storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                var symbolic = font.fontDescriptor.symbolicTraits
                switch trait {
                case .bold:
                    if adding { symbolic.formUnion(.bold) } else { symbolic.subtract(.bold) }
                case .italic:
                    if adding { symbolic.formUnion(.italic) } else { symbolic.subtract(.italic) }
                default: break
                }
                let descriptor = font.fontDescriptor.withSymbolicTraits(symbolic)
                let updated = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                storage.addAttribute(.font, value: updated, range: subrange)
            }
        } else {
            if adding {
                storage.addAttribute(.underlineStyle, value: NSNumber(value: NSUnderlineStyle.single.rawValue), range: range)
            } else {
                storage.removeAttribute(.underlineStyle, range: range)
            }
        }
        storage.endEditing()
        didChangeText()
    }

    private func selectionHas(_ trait: RichTextDocument.Traits, in range: NSRange) -> Bool {
        guard let storage = textStorage else { return false }
        var hasTrait = true
        storage.enumerateAttributes(in: range, options: []) { attributes, _, _ in
            switch trait {
            case .bold, .italic:
                guard let font = attributes[.font] as? NSFont else {
                    hasTrait = false
                    return
                }
                let symbolic = font.fontDescriptor.symbolicTraits
                if trait == .bold, !symbolic.contains(.bold) { hasTrait = false }
                if trait == .italic, !symbolic.contains(.italic) { hasTrait = false }
            case .underline:
                let underline = (attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0
                if underline == 0 { hasTrait = false }
            default:
                break
            }
        }
        return hasTrait
    }
}
