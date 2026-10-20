import SwiftUI
import CopilyCore

/// The Notes tab: connection, cards, previews and the composer, all against the
/// ``NotesClient`` protocol.
struct NotesTabView: View {
    @Environment(\.copilyCompactCards) private var compactCards
    @Environment(\.copilyCardHeight) private var cardHeight
    @ObservedObject var model: NotesTabViewModel
    let commands: PanelCommands
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            switch model.state {
            case .disconnected:
                disconnected
            case .connecting:
                loading("Connecting to Apple Notes…")
            case .permissionDenied:
                permissionDenied
            case .unavailable(let message):
                unavailable(message)
            case .empty:
                list
            case .error(let message):
                StatePanel(
                    symbol: "exclamationmark.triangle",
                    title: "Apple Notes could not be read",
                    message: message,
                    actionTitle: "Try Again"
                ) {
                    Task { await model.refresh() }
                }
            case .indexing(let progress):
                VStack(spacing: 0) {
                    indexing(progress)
                    list
                }
            case .loaded:
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Connection states

    private var disconnected: some View {
        StatePanel(
            symbol: "note.text",
            title: "Connect Apple Notes",
            message: "Copily reads the notes you choose and keeps them searchable here. Notes stay in Apple Notes; Copily never changes them without asking.",
            actionTitle: "Connect Apple Notes"
        ) {
            Task { await model.connect() }
        }
    }

    private var permissionDenied: some View {
        StatePanel(
            symbol: "hand.raised",
            title: "Permission denied",
            message: NotesClientError.permissionDenied.userMessage,
            actionTitle: "Open System Settings"
        ) {
            NotesTabView.openAutomationSettings()
            Task { await model.connect() }
        }
    }

    private func unavailable(_ message: String) -> some View {
        StatePanel(
            symbol: "wand.and.stars",
            title: "Apple Notes automation is not in this build",
            message: message,
            actionTitle: "Open Settings"
        ) {
            commands.openSettings()
        }
    }

    private func loading(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, CopilyTheme.contentPadding)
            GeometryReader { proxy in
                SkeletonCardGrid(columns: ClipboardTabView.columns(for: proxy.size.width, compact: compactCards))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 8)
        .accessibilityElement()
        .accessibilityLabel(message)
    }

    private func indexing(_ progress: NotesIndexingProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress.fractionCompleted)
                .controlSize(.small)
            Text("Indexing notes … \(progress.indexedNoteCount) of \(progress.totalNoteCount)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, CopilyTheme.contentPadding)
        .padding(.top, 8)
    }

    // MARK: - Notes

    private var list: some View {
        VStack(spacing: 0) {
            toolbar
            if model.filteredNotes.isEmpty {
                StatePanel(
                    symbol: "magnifyingglass",
                    title: model.searchText.isEmpty ? "No notes yet" : "No matching notes",
                    message: model.searchText.isEmpty
                        ? "New notes in the included folders will appear automatically."
                        : "No note matches “\(model.searchText)”."
                )
            } else {
                GeometryReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: ClipboardTabView.columns(for: proxy.size.width, compact: compactCards), spacing: CopilyTheme.cardSpacing) {
                            ForEach(model.filteredNotes) { note in
                                NoteCardView(note: note, model: model, commands: commands)
                                    .id(note.id)
                            }
                        }
                        .padding(.horizontal, CopilyTheme.contentPadding)
                        .padding(.top, 4)
                        .padding(.bottom, 10)
                    }
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if !model.folders.isEmpty {
                Label("Included: \(includedNames)", systemImage: "folder").copilyTooltip("Included folders")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let status = model.statusMessage {
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CopilyTheme.accent)
                    .lineLimit(1)
            }
            Label("Auto-sync", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(CopilyTheme.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(CopilyTheme.accentWash))
                .copilyTooltip("Changes in Apple Notes appear automatically while this tab is open.")
        }
        .padding(.horizontal, CopilyTheme.contentPadding)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private var includedNames: String {
        let names = model.folders.filter { model.isIncluded($0) }.map(\.name)
        guard !names.isEmpty else { return model.folders.count == 1 ? model.folders[0].name : "All folders" }
        return names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) folders"
    }

    private static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// One note: title, excerpt, folder and modification date.
struct NoteCardView: View {
    @Environment(\.copilyCardHeight) private var cardHeight
    let note: NotesNoteMetadata
    @ObservedObject var model: NotesTabViewModel
    let commands: PanelCommands
    @StateObject private var hover = PanelState(false)
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHovering: Bool { hover.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardContent
            cardFooter
        }
        .frame(height: cardHeight)
        .background {
            (isHovering ? CopilyTheme.hoverCardSurface : CopilyTheme.cardSurface)
                .overlay {
                    LinearGradient(
                        colors: [CopilyTheme.surfaceHighlight, .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .allowsHitTesting(false)
                }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(CopilyTheme.cardBorder(isSelected: model.selection == note.id, isHovering: isHovering, contrast: contrast), lineWidth: 1))
        .background {
            if isHovering {
                shape.fill(CopilyTheme.cardSurface)
                    .shadow(color: CopilyTheme.Elevation.cardColor(contrast: contrast),
                            radius: CopilyTheme.Elevation.cardRadius, y: CopilyTheme.Elevation.cardY)
            }
        }
        .contentShape(shape)
        .contentShape(.dragPreview, shape)
        .onTapGesture { Task { await model.copyText(of: note) } }
        .onDrag { model.dragProvider(for: note) }
        .overlay(alignment: .topTrailing) {
            MaximiseCardButton(action: { Task { await model.preparePreview(note) } }, isFocused: model.selection == note.id || isHovering)
            .padding(6)
        }
        .contextMenu { actions }
        .onHover { hover.value = $0 }
        .animation(CopilyMotion.animation(CopilyMotion.hover, reduceMotion: reduceMotion), value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(note.title.isEmpty ? "Untitled note" : note.title)
        .accessibilityAction { Task { await model.copyText(of: note) } }
        .accessibilityAction(named: "Paste") { commands.pasteNote(note) }
        .accessibilityAction(named: "Maximise") { Task { await model.preparePreview(note) } }
        .accessibilityAction(named: "Copy Text") { Task { await model.copyText(of: note) } }
        .accessibilityAction(named: "Open in Apple Notes") { Task { await model.openInNotes(note) } }
    }

    private var cardContent: some View {
    VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 5) {
            Image(systemName: note.isProtected ? "lock.fill" : "note.text")
                .copilyTooltip(note.isProtected ? "Locked note" : "Apple Notes")
                .foregroundStyle(note.isProtected ? Color.orange : CopilyTheme.accent)
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(CopilyTheme.accentWash)
                }
            Text("Apple Notes")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if note.isShared { Image(systemName: "person.2.fill").accessibilityLabel("Shared").copilyTooltip("Shared note") }
            if note.hasRichContent || note.attachmentCount > 0 {
                Image(systemName: "paperclip").accessibilityLabel("Rich content").copilyTooltip("Rich content")
            }
        }
        .font(.system(size: 9.5, weight: .medium))
        .padding(.trailing, 24)
        Text(note.title.isEmpty ? "Untitled" : note.title)
            .font(.system(size: 13, weight: .semibold))
            .lineSpacing(1)
            .lineLimit(2)
        Text(note.isProtected ? "Unlock this note in Apple Notes." : note.excerpt)
            .font(.system(size: 11))
            .lineSpacing(1.5)
            .foregroundStyle(.secondary)
            .lineLimit(4)
        Spacer(minLength: 0)
    }
    .padding(CopilyTheme.cardPadding)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .frame(height: cardHeight - CopilyTheme.cardFooterHeight, alignment: .topLeading)
    .clipped()
    }

    private var cardFooter: some View {
    HStack(spacing: 5) {
        Image(systemName: "folder").copilyTooltip("Notes folder")
        Text(note.folderName ?? model.folderName(for: note.folderID) ?? "Notes")
            .lineLimit(1)
        Spacer(minLength: 4)
        Text(CardTimestamp.description(for: note.modificationDate))
            .font(.system(size: 9, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
        CardActionsMenu(title: "Note actions") {
            actions
        }
    }
    .font(.system(size: 9.5, weight: .medium))
    .foregroundStyle(.secondary)
    .padding(.horizontal, CopilyTheme.cardPadding)
    .frame(height: CopilyTheme.cardFooterHeight)
    .background(CopilyTheme.insetSurface.opacity(0.42))
    .overlay(alignment: .top) {
        Rectangle()
            .fill(CopilyTheme.border(contrast: contrast).opacity(0.55))
            .frame(height: 0.5)
            .allowsHitTesting(false)
    }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CopilyTheme.cardCornerRadius, style: .continuous)
    }

    @ViewBuilder private var actions: some View {
        Button("Paste", systemImage: "doc.on.clipboard") { commands.pasteNote(note) }
        Button("Maximise", systemImage: "arrow.up.left.and.arrow.down.right") { Task { await model.preparePreview(note) } }
        Button("Copy Text", systemImage: "doc.on.doc") { Task { await model.copyText(of: note) } }
        if note.supportsInlineEditing {
            Button("Edit", systemImage: "pencil") { Task { await model.beginEdit(note) } }
        }
        Button("Open in Apple Notes", systemImage: "arrow.up.forward.app") { Task { await model.openInNotes(note) } }
    }

}

/// Larger preview of one note, with its body.
struct NotesPreviewView: View {
    @ObservedObject var model: NotesTabViewModel
    let commands: PanelCommands
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if let preview = model.preview {
            GeometryReader { proxy in
                let text = preview.error ?? preview.note?.plainText ?? preview.metadata.excerpt
                let size = FocusPreviewSizing.text(text, available: proxy.size)
                ZStack {
                    OverlayBackdrop { model.closePreview() }
                    OverlaySurface {
                        VStack(alignment: .leading, spacing: 10) {
                            PreviewCloseBar { model.closePreview() }
                            ScrollView {
                                if preview.isLoading {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text(text)
                                        .font(.system(size: 13))
                                        .lineSpacing(2)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            Divider().overlay(CopilyTheme.border(contrast: contrast))
                            HStack(spacing: 14) {
                                Button { commands.pasteNote(preview.metadata) } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                                    .copilyTooltip("Paste into the previous app")
                                Button { Task { await model.copyText(of: preview.metadata) } } label: { Label("Copy Text", systemImage: "doc.on.doc") }
                                    .copilyTooltip("Copy Text")
                                if preview.metadata.supportsInlineEditing {
                                    Button { Task { await model.beginEdit(preview.metadata) } } label: { Label("Edit", systemImage: "pencil") }
                                        .copilyTooltip("Edit")
                                }
                                Button { Task { await model.openInNotes(preview.metadata) } } label: { Label("Open in Apple Notes", systemImage: "arrow.up.forward.app") }
                                    .copilyTooltip("Open in Apple Notes")
                                Spacer(minLength: 4)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(CopilyIconButtonStyle())
                            .font(.system(size: 12))
                            .frame(height: 28)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

}

/// Creates a note, or edits a simple text one, with an explicit Save and Cancel.
struct NotesComposerView: View {
    @ObservedObject var model: NotesTabViewModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if let composer = model.composer {
            ZStack(alignment: .top) {
                OverlayBackdrop { model.cancelComposer() }

                OverlaySurface {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(composer.session.isNew ? "New Note" : "Edit Note")
                            .font(.system(size: 13, weight: .semibold))
                        if let conflict = composer.session.conflict {
                            conflictBanner(conflict)
                        }
                        TextField("Title", text: Binding(
                            get: { composer.session.title },
                            set: { value in model.updateComposer { $0.title = value } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .font(.system(size: 12))
                        .tint(CopilyTheme.accent)
                        TextEditor(text: Binding(
                            get: { composer.session.body },
                            set: { value in model.updateComposer { $0.body = value } }
                        ))
                        .font(.system(size: 12))
                        .lineSpacing(2)
                        .padding(8)
                        .frame(minHeight: 170)
                        .scrollContentBackground(.hidden)
                        .background(
                            RoundedRectangle(cornerRadius: CopilyTheme.controlCornerRadius, style: .continuous)
                                .fill(CopilyTheme.insetSurface)
                                .overlay {
                                    RoundedRectangle(cornerRadius: CopilyTheme.controlCornerRadius, style: .continuous)
                                        .strokeBorder(CopilyTheme.border(contrast: contrast), lineWidth: 1)
                                }
                        )
                        .tint(CopilyTheme.accent)
                        if !model.folders.isEmpty {
                            Picker("Folder", selection: Binding(
                                get: { composer.session.folderID ?? model.folders.first?.id ?? NotesFolderID(rawValue: "") },
                                set: { value in model.updateComposer { $0.folderID = value } }
                            )) {
                                ForEach(model.folders) { folder in
                                    Text(folder.name).tag(folder.id)
                                }
                            }
                            .controlSize(.small)
                        }
                        if let error = composer.session.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle").copilyTooltip(error)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Divider().overlay(CopilyTheme.border(contrast: contrast))
                        HStack(spacing: 8) {
                            if composer.isSaving {
                                ProgressView().controlSize(.small)
                                Text("Saving to Apple Notes…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Cancel") { model.cancelComposer() }
                                .controlSize(.regular)
                            Button("Save") { Task { await model.saveComposer() } }
                                .buttonStyle(.borderedProminent)
                                .tint(CopilyTheme.accent)
                                .disabled(composer.isSaving)
                                .keyboardShortcut("s", modifiers: .command)
                        }
                    }
                }
                .frame(maxWidth: 600, maxHeight: 480, alignment: .topLeading)
                .padding(.horizontal, 50)
                .padding(.vertical, 26)
            }
        }
    }

    private func conflictBanner(_ conflict: NotesNoteMetadata) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This note changed in Apple Notes", systemImage: "arrow.triangle.2.circlepath").copilyTooltip("This note changed in Apple Notes")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Last changed \(CardTimestamp.detailed(conflict.modificationDate)). Copily keeps your draft.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Reload") { Task { await model.reloadConflict() } }
                    .controlSize(.small)
            }
        }
        .padding(CopilyTheme.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: CopilyTheme.controlCornerRadius, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }
}
