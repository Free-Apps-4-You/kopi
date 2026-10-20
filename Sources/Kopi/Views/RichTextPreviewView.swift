import AppKit
import SwiftUI
import KopiCore

/// TextKit draws tables, lists and paragraph styles that SwiftUI Text cannot lay out.
struct RichTextPreviewView: NSViewRepresentable {
    let document: RichTextDocument
    var selectable = true

    func makeNSView(context: Context) -> PreviewTextView {
        let view = PreviewTextView()
        view.isEditable = false
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: PreviewTextView, context: Context) {
        view.isSelectable = selectable
        view.ignoresPointer = !selectable
        guard view.document != document else { return }
        view.document = document
        view.textStorage?.setAttributedString(RichTextCoding.displayString(from: document))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PreviewTextView, context: Context) -> CGSize? {
        let width = max(40, proposal.width ?? 400)
        nsView.textContainer?.containerSize = NSSize(width: width - 8, height: .greatestFiniteMagnitude)
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: proposal.height ?? ceil(layout.usedRect(for: container).height + 8))
    }
}

final class PreviewTextView: NSTextView {
    var document: RichTextDocument?
    var ignoresPointer = false
    override func hitTest(_ point: NSPoint) -> NSView? { ignoresPointer ? nil : super.hitTest(point) }
}
