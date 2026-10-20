import AppKit
import SwiftUI
import CopilyCore

/// Editor of one card, opened with ⌘E.
///
/// Every kind saves through ``HistoryStore`` only; the pasteboard changes when the user
/// copies or pastes the card, never because of a save. Image and file cards accept a
/// label, and the label never touches the original content.
struct ClipboardEditorView: View {
    @ObservedObject var model: PanelViewModel
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case text, url, label }

    var body: some View {
        if let editor = model.editor {
            ZStack(alignment: .top) {
                OverlayBackdrop { model.cancelEditor() }

                OverlaySurface {
                    VStack(alignment: .leading, spacing: 12) {
                        header(editor)
                        Divider().overlay(CopilyTheme.border(contrast: contrast))
                        fields(editor)
                        if let error = editor.error {
                            Label(error, systemImage: "exclamationmark.triangle").copilyTooltip(error)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Divider().overlay(CopilyTheme.border(contrast: contrast))
                        footer(editor)
                    }
                }
                .frame(maxWidth: 620, maxHeight: 460, alignment: .topLeading)
                .padding(.horizontal, 50)
                .padding(.vertical, 34)
            }
            .onAppear {
                switch editor.kind {
                case .text: focusedField = .text
                case .link: focusedField = .url
                case .labelOnly: focusedField = .label
                case .richText: break // The AppKit host focuses its text view.
                }
            }
        }
    }

    private func header(_ editor: PanelViewModel.EditorState) -> some View {
        HStack(spacing: 10) {
            KindBadge(kind: editor.summary.kind)
            Text(editor.kind.title)
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            if editor.summary.isPinned {
                Label("Pinned", systemImage: "pin.fill").copilyTooltip("Pinned item")
                    .font(.system(size: 10))
                    .foregroundStyle(CopilyTheme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(CopilyTheme.accentWash, in: Capsule())
            }
        }
    }

    @ViewBuilder
    private func fields(_ editor: PanelViewModel.EditorState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch editor.kind {
            case .text:
                labelField(editor)
                VStack(alignment: .leading, spacing: 6) {
                    fieldTitle("Text")
                    TextEditor(text: Binding(
                        get: { editor.text },
                        set: { value in model.updateEditor { $0.text = value } }
                    ))
                    .font(.system(size: 12))
                    .focused($focusedField, equals: .text)
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .copilyInputSurface(isFocused: focusedField == .text)
                }
            case .richText:
                labelField(editor)
                VStack(alignment: .leading, spacing: 6) {
                    fieldTitle("Text")
                    RichTextEditorView(document: Binding(
                        get: { editor.richText },
                        set: { value in model.updateEditor { $0.richText = value } }
                    ))
                    .frame(minHeight: 200)
                    .copilyInputSurface()
                }
            case .link:
                labelField(editor)
                VStack(alignment: .leading, spacing: 6) {
                    fieldTitle("URL")
                    TextField("copily.dev", text: Binding(
                        get: { editor.url },
                        set: { value in model.updateEditor { $0.url = value } }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focusedField, equals: .url)
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .copilyInputSurface(isFocused: focusedField == .url)
                }
            case .labelOnly:
                labelField(editor)
                Text("Changing the label does not rename or modify the original content.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func labelField(_ editor: PanelViewModel.EditorState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldTitle("Label")
            TextField("Optional label", text: Binding(
                get: { editor.label },
                set: { value in model.updateEditor { $0.label = value } }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($focusedField, equals: .label)
            .padding(.horizontal, 11).padding(.vertical, 9)
            .copilyInputSurface(isFocused: focusedField == .label)
        }
    }

    private func fieldTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }

    private func footer(_ editor: PanelViewModel.EditorState) -> some View {
        HStack(spacing: 10) {
            if editor.isSaving {
                ProgressView().controlSize(.small)
                Text(editor.summary.isPinned ? "Saving and preserving content…" : "Saving…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("Saving changes the stored card; the clipboard changes when you copy or paste.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Cancel") { model.cancelEditor() }
                .buttonStyle(CopilyActionButtonStyle())
            Button("Save") { Task { await model.saveEditor() } }
                .buttonStyle(CopilyActionButtonStyle(isPrimary: true))
                .tint(CopilyTheme.accent)
                .disabled(editor.isSaving)
                .keyboardShortcut("s", modifiers: .command)
        }
    }
}
