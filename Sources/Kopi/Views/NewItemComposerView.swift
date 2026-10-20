import SwiftUI
import KopiCore

struct NewItemComposerView: View {
    @ObservedObject var model: PanelViewModel
    @StateObject private var isTargeted = PanelState(false)
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case label, link }

    var body: some View {
        if let draft = model.newItemDraft {
            GeometryReader { proxy in
                ZStack {
                    OverlayBackdrop { model.cancelNewItem() }
                    OverlaySurface {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(KopiTheme.accent)
                                    .frame(width: 36, height: 36)
                                    .background(KopiTheme.accentWash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Add Item").font(.system(size: 15, weight: .semibold))
                                    Text("One item at a time. Choose its type below.")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            Picker("Item type", selection: Binding(get: { model.newItemDraft?.mode ?? .text }, set: { model.selectNewItemMode($0) })) {
                                ForEach(NewItemDraft.Mode.allCases) { mode in
                                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    TextField("Optional label", text: Binding(get: { model.newItemDraft?.label ?? "" }, set: { model.updateNewItemLabel($0) }))
                                        .textFieldStyle(.plain).font(.system(size: 12))
                                        .focused($focusedField, equals: .label)
                                        .padding(.horizontal, 11).padding(.vertical, 9)
                                        .kopiInputSurface(isFocused: focusedField == .label)
                                        .accessibilityLabel("Item label")
                                    fields(draft)
                                }.padding(1)
                            }
                            .frame(height: min(184, max(96, proxy.size.height - 210)))
                            HStack {
                                Button { Task { await model.pasteIntoNewItem() } } label: { Label("Paste from Clipboard", systemImage: "doc.on.clipboard") }
                                    .buttonStyle(KopiActionButtonStyle())
                                    .disabled(draft.hasContent)
                                    .kopiTooltip("Paste one item and detect its type")
                                Spacer(minLength: 4)
                                if draft.isLoading { ProgressView().controlSize(.small) }
                                Text("Saved in Collection").foregroundStyle(.tertiary)
                            }.font(.system(size: 11))
                            if let error = draft.error {
                                Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            }
                            Divider()
                            HStack {
                                if draft.isSaving { ProgressView().controlSize(.small) }
                                Spacer()
                                Button("Cancel") { model.cancelNewItem() }
                                    .buttonStyle(KopiActionButtonStyle())
                                Button("Save") { Task { await model.saveNewItem() } }
                                    .disabled(!draft.hasContent)
                                    .buttonStyle(KopiActionButtonStyle(isPrimary: true))
                                    .keyboardShortcut("s", modifiers: .command)
                            }
                        }
                        .disabled(draft.isLoading || draft.isSaving)
                    }
                    .frame(width: min(560, max(260, proxy.size.width - 48)))
                    .overlay {
                        if isTargeted.value {
                            RoundedRectangle(cornerRadius: KopiTheme.overlayCornerRadius)
                                .strokeBorder(KopiTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                .allowsHitTesting(false)
                        }
                    }
                    .onDrop(of: DroppedContent.supportedTypes, isTargeted: $isTargeted.value) { providers in
                        guard !draft.isLoading, !draft.isSaving else { return false }
                        model.dropIntoNewItem(providers)
                        return true
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .alert("Switch item type?", isPresented: Binding(
                get: { model.pendingNewItemMode != nil },
                set: { if !$0 { model.cancelNewItemModeChange() } }
            ), presenting: model.pendingNewItemMode) { mode in
                Button("Switch Type", role: .destructive) { model.confirmNewItemModeChange(mode) }
                Button("Keep Current", role: .cancel) { model.cancelNewItemModeChange() }
            } message: { _ in
                Text("Switching clears the current content. Your label is kept.")
            }
        }
    }

    @ViewBuilder private func fields(_ draft: NewItemDraft) -> some View {
        if let attachment = draft.attachment {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if let kind = attachment.kind { KindBadge(kind: kind) }
                    Text(attachment.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Spacer(minLength: 0)
                    Button { model.removeNewItemAttachment(attachment.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(KopiIconButtonStyle()).accessibilityLabel("Remove item").kopiTooltip("Remove item")
                }
                if let text = attachment.snapshot.string(for: ClipboardRepresentationKind.plainText.pasteboardType) {
                    Text(String(text.prefix(1000))).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(5)
                }
                Text("Remove this item to choose another.").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .kopiInputSurface()
        } else {
            switch draft.mode {
            case .text:
                RichTextEditorView(document: Binding(
                    get: { model.newItemDraft?.richText ?? RichTextDocument(plainText: "") },
                    set: { model.updateNewItemRichText($0) }
                ))
                .frame(height: 150)
                .kopiInputSurface()
            case .link:
                VStack(alignment: .leading, spacing: 8) {
                    TextField("https://example.com", text: textBinding)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .focused($focusedField, equals: .link)
                        .padding(.horizontal, 11).padding(.vertical, 9)
                        .kopiInputSurface(isFocused: focusedField == .link).accessibilityLabel("Link address")
                    Text("Enter a web address; https:// is added when needed.").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            case .file, .image:
                VStack(spacing: 10) {
                    Image(systemName: draft.mode.symbol).font(.system(size: 24, weight: .light)).foregroundStyle(KopiTheme.accent)
                        .kopiTooltip(draft.mode.title)
                    Text(draft.mode == .image ? "Choose or drop one image" : "Choose or drop one file or folder")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button(draft.mode == .image ? "Choose Image…" : "Choose File…") {
                        model.chooseNewItemFiles(asImages: draft.mode == .image)
                    }
                    .buttonStyle(KopiActionButtonStyle())
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .kopiInputSurface()
            }
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { model.newItemDraft?.text ?? "" }, set: { model.updateNewItemText($0) })
    }
}
