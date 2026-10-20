import SwiftUI
import KopiCore

struct PasswordsTabView: View {
    @Environment(\.kopiCompactCards) private var compactCards
    @Environment(\.kopiCardHeight) private var cardHeight
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject var model: PasswordsViewModel
    let query: String
    @StateObject private var deleteCandidate = PanelState<PasswordRecord?>(nil)
    private var filtered: [PasswordRecord] { model.records.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.needsKeyMigration {
                VaultMigrationBanner(model: model)
            }
            HStack {
                Label("Encrypted locally · authentication required to show", systemImage: "lock.shield").kopiTooltip("Encrypted vault")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { model.lock() } label: { Label("Lock", systemImage: "lock.fill") }
                    .buttonStyle(KopiActionButtonStyle())
                    .disabled(model.revealed == nil).kopiTooltip("Hide all passwords")
            }
            if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if filtered.isEmpty {
                StatePanel(symbol: "key.fill", title: model.records.isEmpty ? "Your private passwords" : "No matching passwords",
                           message: "Add entries manually with +. Passwords stay masked until Touch ID or your Mac login password approves Show.",
                           actionTitle: "Add Password") { model.beginCreate() }
            } else {
                GeometryReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: ClipboardTabView.columns(for: proxy.size.width, compact: compactCards), spacing: KopiTheme.cardSpacing) {
                            ForEach(filtered) { record in
                                VStack(alignment: .leading, spacing: 10) {
                                    Label {
                                        Text(record.title).foregroundStyle(.primary)
                                    } icon: {
                                        Image(systemName: "key.fill").foregroundStyle(KopiTheme.accent)
                                    }
                                    .kopiTooltip("Saved password").font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                    Spacer(minLength: 0)
                                    if model.revealedID == record.id, let secret = model.revealed {
                                        Text(secret.username).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                                        Text(secret.password).font(.system(size: 13, design: .monospaced)).lineLimit(3).privacySensitive()
                                    } else {
                                        Text("********").font(.system(size: 15, design: .monospaced)).tracking(3)
                                            .foregroundStyle(.secondary).accessibilityLabel("Password hidden")
                                    }
                                    Spacer(minLength: 0)
                                    HStack {
                                        Button(model.revealedID == record.id ? "Hide" : "Show") {
                                            if model.revealedID == record.id { model.lock() }
                                            else { Task { await model.reveal(record) } }
                                        }
                                        .buttonStyle(KopiActionButtonStyle())
                                        .disabled(model.isBusy || model.authenticationUnavailable)
                                        Spacer()
                                        CardActionsMenu(title: "Password actions") {
                                            Button(model.revealedID == record.id ? "Hide" : "Show", systemImage: "eye") {
                                                if model.revealedID == record.id { model.lock() }
                                                else { Task { await model.reveal(record) } }
                                            }.disabled(model.isBusy || model.authenticationUnavailable)
                                            Divider()
                                            Button("Delete", systemImage: "trash", role: .destructive) { deleteCandidate.value = record }
                                                .disabled(model.isBusy || model.authenticationUnavailable)
                                        }
                                    }
                                }
                                .padding(KopiTheme.cardPadding)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: cardHeight)
                                .background(KopiTheme.cardSurface, in: RoundedRectangle(cornerRadius: KopiTheme.cardCornerRadius))
                                .overlay {
                                    RoundedRectangle(cornerRadius: KopiTheme.cardCornerRadius, style: .continuous)
                                        .strokeBorder(KopiTheme.border(contrast: contrast), lineWidth: 1)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, KopiTheme.contentPadding)
        .padding(.vertical, 8)
        .alert("Delete password?", isPresented: Binding(get: { deleteCandidate.value != nil }, set: { if !$0 { deleteCandidate.value = nil } })) {
            Button("Delete", role: .destructive) {
                if let record = deleteCandidate.value { Task { await model.delete(record) } }
                deleteCandidate.value = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate.value = nil }
        } message: { Text("This removes the encrypted entry from Kopi. macOS authentication is required.") }
    }
}

/// Explains the vault an earlier build left behind, and the two ways forward.
private struct VaultMigrationBanner: View {
    @ObservedObject var model: PasswordsViewModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").kopiTooltip("Older vault key")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("This vault needs its key from an earlier app version. Choose Migrate to recover it; macOS may show the archived key’s old app name. Once recovered, the key is stored locally. Start Fresh discards the old entries.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Migrate") { Task { await model.migrate() } }
                    .buttonStyle(KopiActionButtonStyle(isPrimary: true)).kopiTooltip("Ask macOS for the earlier keychain key once")
                Button("Start Fresh") { Task { await model.startFresh() } }
                    .buttonStyle(KopiActionButtonStyle()).kopiTooltip("Discard the old entry and start a new vault")
                Spacer()
            }
            .disabled(model.isBusy)
        }
        .padding(10)
        .background(Color.orange.opacity(contrast == .increased ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: KopiTheme.controlCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: KopiTheme.controlCornerRadius, style: .continuous)
                .strokeBorder(Color.orange.opacity(contrast == .increased ? 0.65 : 0.35), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

struct PasswordComposerView: View {
    @ObservedObject var model: PasswordsViewModel
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case title, username, password }

    var body: some View {
        if model.draft != nil {
            ZStack {
                OverlayBackdrop { model.cancel() }
                OverlaySurface {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(KopiTheme.accent)
                                .frame(width: 36, height: 36)
                                .background(KopiTheme.accentWash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .accessibilityHidden(true)
                            Text("Add Password").kopiTooltip("Add password").font(.system(size: 15, weight: .semibold))
                        }
                        TextField("Title, e.g. Personal email", text: field(\.title))
                            .focused($focusedField, equals: .title)
                            .padding(.horizontal, 11).padding(.vertical, 9)
                            .kopiInputSurface(isFocused: focusedField == .title)
                        TextField("Username or email", text: field(\.username))
                            .focused($focusedField, equals: .username)
                            .padding(.horizontal, 11).padding(.vertical, 9)
                            .kopiInputSurface(isFocused: focusedField == .username)
                        SecureField("Password", text: field(\.password))
                            .focused($focusedField, equals: .password)
                            .padding(.horizontal, 11).padding(.vertical, 9)
                            .kopiInputSurface(isFocused: focusedField == .password)
                            .privacySensitive()
                        Text("Saved encrypted. Show always asks macOS for Touch ID or your Mac login password. Without either, set a Mac login password first.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let message = model.message { Text(message).font(.system(size: 11)).foregroundStyle(.orange) }
                        HStack {
                            Spacer()
                            Button("Cancel") { model.cancel() }.disabled(model.isBusy)
                                .buttonStyle(KopiActionButtonStyle())
                            Button("Save") { Task { await model.save() } }.disabled(model.isBusy || model.authenticationUnavailable)
                                .buttonStyle(KopiActionButtonStyle(isPrimary: true)).keyboardShortcut("s", modifiers: .command)
                        }
                    }.textFieldStyle(.plain).font(.system(size: 12))
                }.frame(width: 380)
            }
        }
    }
    private func field(_ key: WritableKeyPath<PasswordsViewModel.Draft, String>) -> Binding<String> {
        Binding(get: { model.draft?[keyPath: key] ?? "" }, set: { model.draft?[keyPath: key] = $0 })
    }
}

