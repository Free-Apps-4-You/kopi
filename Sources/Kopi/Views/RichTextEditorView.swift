import AppKit
import SwiftUI
import KopiCore

/// Native rich-text editing preserves tables, paragraph styles and inline formatting.
/// Saves carry the full attributed document as HTML and RTF alongside searchable text.
struct RichTextEditorView: NSViewRepresentable {
    @Binding var document: RichTextDocument

    func makeCoordinator() -> Coordinator {
        Coordinator(document: $document)
    }

    func makeNSView(context: Context) -> RichTextEditorHost {
        let host = RichTextEditorHost()
        host.textView.delegate = context.coordinator
        host.setText(RichTextCoding.displayString(from: document))
        context.coordinator.lastEmitted = document
        return host
    }

    func updateNSView(_ nsView: RichTextEditorHost, context: Context) {
        context.coordinator.document = $document
        guard context.coordinator.lastEmitted != document else { return }
        context.coordinator.lastEmitted = document
        nsView.setText(RichTextCoding.displayString(from: document))
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
            toolbarButton(symbol: "underline", action: #selector(FormattingTextView.toggleUnderline), tooltip: "Underline ⌘U"),
            toolbarButton(symbol: "strikethrough", action: #selector(FormattingTextView.toggleStrike), tooltip: "Strikethrough"),
            toolbarButton(symbol: "list.bullet", action: #selector(FormattingTextView.bulletList), tooltip: "Bulleted list"),
            toolbarButton(symbol: "list.number", action: #selector(FormattingTextView.numberedList), tooltip: "Numbered list"),
            toolbarButton(symbol: "checklist", action: #selector(FormattingTextView.checklist), tooltip: "Checklist"),
            toolbarButton(symbol: "tablecells", action: #selector(FormattingTextView.insertTable), tooltip: "Insert 2 × 3 table"),
            toolbarButton(symbol: "paintpalette", action: #selector(FormattingTextView.showColorPicker), tooltip: "Text color")
        ])
        toolbar.orientation = .horizontal
        toolbar.spacing = 4
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let styles = NSPopUpButton()
        styles.addItems(withTitles: ["Body", "Title", "Heading", "Subheading", "Monospaced"])
        styles.target = textView
        styles.action = #selector(FormattingTextView.applyStyle(_:))
        styles.setAccessibilityLabel("Paragraph style")
        toolbar.insertArrangedSubview(styles, at: 0)
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
        let button = KopiTooltipButton(image: image, target: textView, action: action)
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

    @objc func showColorPicker() {
        window?.makeFirstResponder(self)
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(NSTextView.changeColor(_:)))
        panel.orderFront(nil)
    }

    @objc func toggleStrike() {
        if selectedRange().length == 0 {
            typingAttributes[.strikethroughStyle] = (typingAttributes[.strikethroughStyle] as? Int ?? 0) == 0 ? 1 : 0
            return
        }
        transformSelection { text in
            let range = NSRange(location: 0, length: text.length)
            let current = text.length > 0 ? (text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? NSNumber)?.intValue ?? 0 : 0
            text.addAttribute(.strikethroughStyle, value: current == 0 ? 1 : 0, range: range)
        }
    }

    @objc func applyStyle(_ sender: NSPopUpButton) {
        let font: NSFont
        switch sender.indexOfSelectedItem {
        case 1: font = .boldSystemFont(ofSize: 24)
        case 2: font = .boldSystemFont(ofSize: 18)
        case 3: font = .boldSystemFont(ofSize: 15)
        case 4: font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        default: font = .systemFont(ofSize: 13)
        }
        transformSelection(paragraphs: true) { text in
            text.addAttribute(.font, value: font, range: NSRange(location: 0, length: text.length))
        }
        typingAttributes[.font] = font
        window?.makeFirstResponder(self)
    }

    @objc func bulletList() { applyList(marker: .disc) }
    @objc func numberedList() { applyList(marker: .decimal) }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let text = string as NSString
        if index < text.length {
            let marker = text.substring(with: NSRange(location: index, length: 1))
            if marker == "☐" || marker == "☑" {
                insertText(marker == "☐" ? "☑" : "☐", replacementRange: NSRange(location: index, length: 1))
                return
            }
        }
        super.mouseDown(with: event)
    }

    @objc func checklist() {
        if string.isEmpty {
            insertFormatted(NSAttributedString(string: "☐ ", attributes: typingAttributes), replacementRange: selectedRange())
            return
        }
        transformSelection(paragraphs: true) { text in
            var paragraphs: [NSRange] = []
            (text.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { _, range, _, _ in paragraphs.append(range) }
            for paragraph in paragraphs.reversed() {
                let line = (text.string as NSString).substring(with: paragraph)
                if line.hasPrefix("☐ ") || line.hasPrefix("☑ ") {
                    text.deleteCharacters(in: NSRange(location: paragraph.location, length: 2))
                } else {
                    let attributes = text.attributes(at: paragraph.location, effectiveRange: nil)
                    text.insert(NSAttributedString(string: "☐ ", attributes: attributes), at: paragraph.location)
                }
            }
        }
    }

    private func applyList(marker: NSTextList.MarkerFormat) {
        let list = NSTextList(markerFormat: marker, options: 0)
        let range = (string as NSString).paragraphRange(for: selectedRange())
        let style = NSMutableParagraphStyle()
        style.textLists = [list]
        style.headIndent = 24
        if range.length == 0 {
            var attributes = typingAttributes
            attributes[.paragraphStyle] = style
            insertFormatted(NSAttributedString(string: "\t" + list.marker(forItemNumber: 1) + "\t", attributes: attributes), replacementRange: range)
            typingAttributes = attributes
            return
        }
        transformSelection(paragraphs: true) { text in
            var paragraphs: [NSRange] = []
            (text.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { _, range, _, _ in
                paragraphs.append(range)
            }
            for (index, paragraph) in paragraphs.enumerated().reversed() {
                let oldStyle = text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
                let wasList = oldStyle?.textLists.isEmpty == false
                let removing = oldStyle?.textLists.last?.markerFormat == marker
                let paragraphText = (text.string as NSString).substring(with: paragraph)
                let prefixLength = wasList && paragraphText.hasPrefix("\t") ? paragraphText.dropFirst().firstIndex(of: "\t").map { paragraphText.distance(from: paragraphText.startIndex, to: $0) + 1 } ?? 0 : 0
                let updated = oldStyle?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                updated.textLists = removing ? [] : [list]
                updated.headIndent = removing ? 0 : 24
                text.addAttribute(.paragraphStyle, value: updated, range: paragraph)
                var attributes = text.attributes(at: paragraph.location, effectiveRange: nil)
                attributes[.paragraphStyle] = updated
                text.replaceCharacters(in: NSRange(location: paragraph.location, length: prefixLength), with: NSAttributedString(string: removing ? "" : "\t" + list.marker(forItemNumber: index + 1) + "\t", attributes: attributes))
            }
        }
    }

    override func insertNewline(_ sender: Any?) {
        let range = (string as NSString).paragraphRange(for: selectedRange())
        let line = (string as NSString).substring(with: range).trimmingCharacters(in: .newlines)
        let components = line.components(separatedBy: "\t")
        let checklist = line.hasPrefix("☐ ") || line.hasPrefix("☑ ")
        let list = (typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.textLists.last
        guard checklist || (list != nil && components.count >= 3) else { super.insertNewline(sender); return }
        let prefix: String
        let content: String
        if checklist {
            prefix = "☐ "
            content = String(line.dropFirst(2))
        } else {
            let number = Int(components[1].filter(\.isNumber)) ?? 1
            prefix = "\t" + (list?.marker(forItemNumber: number + 1) ?? "•") + "\t"
            content = components.dropFirst(2).joined(separator: "\t")
        }
        if content.isEmpty {
            var attributes = typingAttributes
            attributes[.paragraphStyle] = NSParagraphStyle.default
            insertFormatted(NSAttributedString(string: "", attributes: attributes), replacementRange: range)
            typingAttributes = attributes
        } else {
            // Insert once: older macOS text views also continue lists in super,
            // which would duplicate our marker before this insertion.
            insertFormatted(NSAttributedString(string: "\n" + prefix, attributes: typingAttributes), replacementRange: selectedRange())
        }
    }

    @objc func insertTable() {
        let table = NSTextTable()
        table.numberOfColumns = 2
        table.collapsesBorders = true
        let content = NSMutableAttributedString()
        for row in 0..<3 {
            for column in 0..<2 {
                let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setWidth(1, type: .absoluteValueType, for: .border)
                cell.setWidth(6, type: .absoluteValueType, for: .padding)
                cell.setBorderColor(.separatorColor)
                let style = NSMutableParagraphStyle()
                style.textBlocks = [cell]
                content.append(NSAttributedString(string: "Cell\n", attributes: [.paragraphStyle: style, .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
            }
        }
        content.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
        insertFormatted(content, replacementRange: selectedRange())
    }

    /// Replacing attributed content directly avoids AppKit's input-method insertion
    /// normalizing pasted font sizes to the current typing font.
    private func insertFormatted(_ replacement: NSAttributedString, replacementRange range: NSRange) {
        guard let storage = textStorage,
              shouldChangeText(in: range, replacementString: replacement.string) else { return }
        let old = storage.attributedSubstring(from: range)
        undoManager?.registerUndo(withTarget: self) { view in
            view.insertFormatted(old, replacementRange: NSRange(location: range.location, length: replacement.length))
        }
        storage.replaceCharacters(in: range, with: replacement)
        setSelectedRange(NSRange(location: range.location + replacement.length, length: 0))
        if replacement.length > 0 { typingAttributes = replacement.attributes(at: replacement.length - 1, effectiveRange: nil) }
        didChangeText()
    }

    private func transformSelection(paragraphs: Bool = false, _ transform: (NSMutableAttributedString) -> Void) {
        var range = selectedRange()
        if paragraphs { range = (string as NSString).paragraphRange(for: range) }
        guard range.length > 0, let storage = textStorage else { return }
        let updated = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        transform(updated)
        insertFormatted(updated, replacementRange: range)
        setSelectedRange(NSRange(location: range.location, length: updated.length))
    }

    /// Native insertion participates in undo and preserves unrelated attributes.
    func toggle(_ trait: RichTextDocument.Traits) {
        let range = selectedRange()
        if range.length == 0 {
            let text = FormattingTextView()
            text.textStorage?.setAttributedString(NSAttributedString(string: "x", attributes: typingAttributes))
            text.setSelectedRange(NSRange(location: 0, length: 1))
            text.toggle(trait)
            typingAttributes = text.textStorage?.attributes(at: 0, effectiveRange: nil) ?? typingAttributes
            return
        }
        let adding = !selectionHas(trait, in: range)
        transformSelection { storage in
            let full = NSRange(location: 0, length: storage.length)
            if trait == .bold || trait == .italic {
                storage.enumerateAttribute(.font, in: full) { value, span, _ in
                    let font = value as? NSFont ?? NSFont.systemFont(ofSize: 13)
                    var symbolic = font.fontDescriptor.symbolicTraits
                    let changed: NSFontDescriptor.SymbolicTraits = trait == .bold ? .bold : .italic
                    if adding { symbolic.formUnion(changed) } else { symbolic.subtract(changed) }
                    storage.addAttribute(.font, value: NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(symbolic), size: font.pointSize) ?? font, range: span)
                }
            } else {
                storage.addAttribute(.underlineStyle, value: adding ? 1 : 0, range: full)
            }
        }
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
