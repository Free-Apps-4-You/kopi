import SwiftUI
import KopiCore

/// The Notes tab: read-only connection, cards and previews, all against the
/// ``NotesClient`` protocol.
struct NotesTabView: View {
    @Environment(\.kopiCompactCards) private var compactCards
    @Environment(\.kopiCardHeight) private var cardHeight
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
            message: "Kopi reads the notes you choose and keeps them searchable here. Notes stay in Apple Notes; Kopi cannot create, edit, or delete them. macOS asks for Automation access to read them.",
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
                .padding(.horizontal, KopiTheme.contentPadding)
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
        .padding(.horizontal, KopiTheme.contentPadding)
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
                        ? model.emptySourceMessage
                        : "No note matches “\(model.searchText)”."
                )
            } else {
                GeometryReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: ClipboardTabView.columns(for: proxy.size.width, compact: compactCards), spacing: KopiTheme.cardSpacing) {
                            ForEach(model.filteredNotes) { note in
                                NoteCardView(note: note, model: model, commands: commands)
                                    .id(note.id)
                            }
                        }
                        .padding(.horizontal, KopiTheme.contentPadding)
                        .padding(.top, 4)
                        .padding(.bottom, 10)
                    }
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("Notes source", selection: $model.sourceFilter) {
                ForEach(NotesSourceFilter.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .accessibilityLabel("Filter notes by account location")
            Spacer(minLength: 8)
            if let status = model.statusMessage {
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(KopiTheme.accent)
                    .lineLimit(1)
            }
            Label("Read only", systemImage: "eye")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
            Label("Auto-sync", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(KopiTheme.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(KopiTheme.accentWash))
                .kopiTooltip("Changes in Apple Notes appear automatically while this tab is open.")
        }
        .padding(.horizontal, KopiTheme.contentPadding)
        .padding(.top, 6)
        .padding(.bottom, 6)
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
    @Environment(\.kopiCardHeight) private var cardHeight
    let note: NotesNoteMetadata
    @ObservedObject var model: NotesTabViewModel
    let commands: PanelCommands
    @StateObject private var hover = PanelState(false)
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHovering: Bool { hover.value }

    var body: some View {
        interactiveCard
        .accessibilityElement(children: .contain)
        .accessibilityLabel(note.title.isEmpty ? "Untitled note" : note.title)
        .accessibilityAction { Task { await model.copyText(of: note) } }
        .accessibilityAction(named: "Maximise") { Task { await model.preparePreview(note) } }
        .accessibilityAction(named: "Copy Text") { Task { await model.copyText(of: note) } }
        .accessibilityAction(named: "Open in Apple Notes") { Task { await model.openInNotes(note) } }
    }

    private var interactiveCard: some View {
        styledCard
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
        .animation(KopiMotion.animation(KopiMotion.hover, reduceMotion: reduceMotion), value: isHovering)
    }

    private var styledCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardContent
            cardFooter
        }
        .frame(height: cardHeight)
        .background {
            (isHovering ? KopiTheme.hoverCardSurface : KopiTheme.cardSurface)
                .overlay {
                    LinearGradient(
                        colors: [KopiTheme.surfaceHighlight, .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .allowsHitTesting(false)
                }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(KopiTheme.cardBorder(isSelected: model.selection == note.id, isHovering: isHovering, contrast: contrast), lineWidth: 1))
        .background {
            if isHovering {
                shape.fill(KopiTheme.cardSurface)
                    .shadow(color: KopiTheme.Elevation.cardColor(contrast: contrast),
                            radius: KopiTheme.Elevation.cardRadius, y: KopiTheme.Elevation.cardY)
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: note.isProtected ? "lock.fill" : "note.text")
                    .kopiTooltip(note.isProtected ? "Locked note" : "Apple Notes")
                    .foregroundStyle(note.isProtected ? Color.orange : KopiTheme.accent)
                    .frame(width: 20, height: 20)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(KopiTheme.accentWash)
                    }
                Text("Apple Notes")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if note.isShared { Image(systemName: "person.2.fill").accessibilityLabel("Shared").kopiTooltip("Shared note") }
                if note.hasRichContent || note.attachmentCount > 0 {
                    Image(systemName: "paperclip").accessibilityLabel("Rich content").kopiTooltip("Rich content")
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
    .padding(KopiTheme.cardPadding)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .frame(height: cardHeight - KopiTheme.cardFooterHeight, alignment: .topLeading)
    .clipped()
    }

    private var cardFooter: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder").kopiTooltip("Notes folder")
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
    .padding(.horizontal, KopiTheme.cardPadding)
    .frame(height: KopiTheme.cardFooterHeight)
    .background(KopiTheme.insetSurface.opacity(0.42))
    .overlay(alignment: .top) {
        Rectangle()
            .fill(KopiTheme.border(contrast: contrast).opacity(0.55))
            .frame(height: 0.5)
            .allowsHitTesting(false)
    }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: KopiTheme.cardCornerRadius, style: .continuous)
    }

    @ViewBuilder private var actions: some View {
        Button("Maximise", systemImage: "arrow.up.left.and.arrow.down.right") { Task { await model.preparePreview(note) } }
        Button("Copy Text", systemImage: "doc.on.doc") { Task { await model.copyText(of: note) } }
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
                            Divider().overlay(KopiTheme.border(contrast: contrast))
                            HStack(spacing: 14) {
                                Button { Task { await model.copyText(of: preview.metadata) } } label: { Label("Copy Text", systemImage: "doc.on.doc") }
                                    .kopiTooltip("Copy Text")
                                Button { Task { await model.openInNotes(preview.metadata) } } label: { Label("Open in Apple Notes", systemImage: "arrow.up.forward.app") }
                                    .kopiTooltip("Open in Apple Notes")
                                Spacer(minLength: 4)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(KopiIconButtonStyle())
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
