import SwiftUI
import KopiCore

/// Task-based preferences with a stable navigation bar and a shared footer.
struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject private var settings: KopiSettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @StateObject private var selectedTab = PanelState<SettingsTab>(.opening)
    @FocusState private var focusedField: Field?
    private var tab: SettingsTab { selectedTab.value }

    private enum Field: Hashable { case bundleID }

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case opening = "Opening", history = "History", privacy = "Privacy", notes = "Notes", shortcuts = "Shortcuts"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .opening: "macwindow"
            case .history: "clock.arrow.circlepath"
            case .privacy: "hand.raised"
            case .notes: "apple.logo"
            case .shortcuts: "keyboard"
            }
        }
    }

    init(model: SettingsViewModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        VStack(spacing: 0) {
            navigation
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .opening: radialSection; openingSection; appearanceSection
                    case .history: historySection
                    case .privacy: privacySection; captureSection
                    case .notes: NotesSettingsSection(notes: model.notes)
                    case .shortcuts: shortcutSection; shortcutReference
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(tab)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: tab)
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 460)
        .background(KopiTheme.surface)
        .tint(KopiTheme.accent)
        .confirmationDialog("Clear clipboard history?", isPresented: $model.isConfirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { Task { await model.clearHistory() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unpinned cards and their stored assets are removed. Pinned and collected cards are kept.")
        }
        .alert("Reset settings?", isPresented: $model.isConfirmingReset) {
            Button("Reset Settings", role: .destructive) { model.resetSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores Kopi preferences to their defaults. Clipboard cards, pins, collected items, passwords, and Apple Notes are kept.")
        }
    }

    private var navigation: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.allCases) { destination in
                Button {
                    model.setRecordingShortcut(false)
                    selectedTab.value = destination
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: destination.symbol).font(.system(size: 19, weight: .medium))
                        Text(destination.rawValue).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(tab == destination ? KopiTheme.accent : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(tab == destination ? KopiTheme.accentWash : .clear,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tab == destination ? KopiTheme.accent.opacity(0.24) : .clear, lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(KopiPressStyle())
                .accessibilityAddTraits(tab == destination ? [.isSelected] : [])
                .kopiTooltip(destination.rawValue + " settings")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(KopiTheme.controlSurface)
    }

    private var radialSection: some View {
        SectionBox("Radial clipboard") {
            Toggle("Enable radial clipboard", isOn: Binding(
                get: { settings.settings.radialEnabled },
                set: { enabled in settings.update { $0.radialEnabled = enabled } }
            ))
            Picker("Hold shortcut", selection: Binding(
                get: { settings.settings.radialTrigger },
                set: { trigger in settings.update { $0.radialTrigger = trigger } }
            )) {
                ForEach(RadialTrigger.allCases) { Text($0.title).tag($0) }
            }.disabled(!settings.settings.radialEnabled)
            detail("Hold \(settings.settings.radialTrigger.title) to open at your pointer. Move toward a card and release the key to copy. Return to the center or press Esc to cancel.")
            detail("Recent clips only. Scroll or use ← → for older clips. Use ↑ ↓, Tab, or 1–8 to select, and Return to confirm. Images include previews.")
            Button("Open radial clipboard") { model.showRadial() }
                .disabled(!settings.settings.radialEnabled)
        }
    }

    private var openingSection: some View {
        SectionBox("Opening & closing") {
            Toggle("Open from the notch or top-center edge", isOn: Binding(
                get: { settings.settings.hoverReveal.isEnabled },
                set: { model.setHoverReveal(HoverReveal(isEnabled: $0, delay: settings.settings.hoverReveal.delay)) }
            ))
            detail("Rest the pointer on the notch, or the top-center edge of any display, to open Kopi.")
            HStack(spacing: 12) {
                Text("Wait before opening").frame(width: 135, alignment: .leading)
                Slider(value: Binding(
                    get: { settings.settings.hoverReveal.delay },
                    set: { model.setHoverReveal(HoverReveal(isEnabled: settings.settings.hoverReveal.isEnabled, delay: $0)) }
                ), in: HoverReveal.delayRange, step: 0.05)
                .accessibilityLabel("Wait before opening")
                Text(String(format: "%.2f s", settings.settings.hoverReveal.delay))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 52)
            }
            .disabled(!settings.settings.hoverReveal.isEnabled)
            Divider().padding(.vertical, 3)
            Picker("Animation speed", selection: Binding(
                get: { settings.settings.animationSpeed }, set: { model.setAnimationSpeed($0) }
            )) {
                ForEach(AnimationSpeed.allCases) { Text($0.displayName).tag($0) }
            }.pickerStyle(.segmented)
            detail("Applies to the panel and Settings. Reduce Motion in macOS takes priority.")
            Toggle("Close when clicking outside the panel", isOn: Binding(
                get: { settings.settings.dismissesOnOutsideClick }, set: { model.setDismissesOnOutsideClick($0) }
            ))
        }
    }

    private var appearanceSection: some View {
        SectionBox("Appearance") {
            Picker("Appearance", selection: Binding(
                get: { settings.settings.appearance }, set: { model.setAppearance($0) }
            )) {
                ForEach(AppearancePreference.allCases) { Text($0.displayName).tag($0) }
            }.pickerStyle(.segmented)
            Toggle("Compact cards", isOn: Binding(
                get: { settings.settings.usesCompactCards }, set: { model.setCompactCards($0) }
            ))
            detail("Smaller cards fit more items in every tab. Previews stay full size.")
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let statistics = model.statistics {
                HStack(spacing: 12) {
                    statistic("Cards", value: "\(statistics.itemCount)", symbol: "square.stack")
                    statistic("Pinned", value: "\(statistics.pinnedCount)", symbol: "pin.fill")
                    statistic("Stored assets", value: ByteCountFormatter.string(fromByteCount: Int64(statistics.assetByteCount), countStyle: .file), symbol: "internaldrive")
                }
            }
            SectionBox("Clipboard history") {
                Picker("Keep history for", selection: Binding(
                    get: { model.retention }, set: { value in Task { await model.setRetention(value) } }
                )) {
                    ForEach(HistoryRetention.allCases) { Text($0.displayName).tag($0) }
                }.pickerStyle(.segmented)
                detail("Current session clears on quit. Pinned and collected cards always stay.")
                Divider().padding(.vertical, 3)
                Toggle("Pause saving copies", isOn: Binding(
                    get: { settings.settings.isCapturePaused }, set: { model.setCapturePaused($0) }
                ))
                detail("Stops automatic capture. Your saved cards, manual additions, and copy actions remain available.")
                Divider().padding(.vertical, 3)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Clear clipboard history").fontWeight(.medium)
                        detail("Pinned and collected cards are kept.")
                    }
                    Spacer()
                    if model.isClearingHistory { ProgressView().controlSize(.small) }
                    Button("Clear…") { model.isConfirmingClear = true }.disabled(model.isClearingHistory)
                        .buttonStyle(KopiActionButtonStyle())
                }
            }
        }
    }

    private func statistic(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(KopiTheme.accent).kopiTooltip(title)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(KopiTheme.cardSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(KopiTheme.border(contrast: contrast), lineWidth: 1))
    }

    private var privacySection: some View {
        SectionBox("Your data stays on this Mac") {
            Toggle("Import the current clipboard when Kopi starts", isOn: Binding(
                get: { settings.settings.capturesClipboardOnLaunch },
                set: { model.setCapturesClipboardOnLaunch($0) }
            ))
            detail("Off by default. Applies on the next launch. Content copied before launch has an unknown source, so app exclusions cannot be applied to it.")
            Divider()
            Label("Clipboard history is stored locally", systemImage: "internaldrive").kopiTooltip("Stored on this Mac")
            Label("Passwords are encrypted and require macOS authentication to view", systemImage: "lock.shield").kopiTooltip("Encrypted password vault")
            detail("Apple Notes connects only when you choose to connect it. Disconnecting removes its cached cards from Kopi and leaves your original notes intact.")
        }
    }

    private var captureSection: some View {
        SectionBox("Never save copies from") {
            if settings.settings.excludedApplications.isEmpty {
                detail("No applications excluded.")
            } else {
                ForEach(settings.settings.excludedApplications, id: \.self) { identifier in
                    HStack(spacing: 8) {
                        Text(identifier).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Button { model.removeExcludedApplication(identifier) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(KopiIconButtonStyle()).accessibilityLabel("Stop excluding \(identifier)").kopiTooltip("Stop excluding \(identifier)")
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Application bundle ID", text: $model.newExcludedApplication)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .bundleID)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .kopiInputSurface(isFocused: focusedField == .bundleID)
                Button("Add") { model.addExcludedApplication(model.newExcludedApplication) }
                    .buttonStyle(KopiActionButtonStyle())
                    .disabled(model.newExcludedApplication.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Menu("Choose Running App") {
                    ForEach(model.runningApplications, id: \.bundleIdentifier) { application in
                        Button(application.displayName ?? "Unknown") {
                            if let identifier = application.bundleIdentifier { model.addExcludedApplication(identifier) }
                        }
                    }
                }.frame(width: 165)
            }
            detail("Copies from excluded applications never enter clipboard history.")
        }
    }

    private var shortcutSection: some View {
        SectionBox("Global shortcut") {
            HStack(spacing: 16) {
                ShortcutRecorderView(hotkey: settings.settings.hotkey,
                    isRecording: Binding(get: { model.isRecordingShortcut }, set: { model.setRecordingShortcut($0) }),
                    onChange: { model.setHotkey($0) })
                    .frame(width: 190, height: 28)
                Toggle("Enabled", isOn: Binding(get: { settings.settings.isHotkeyEnabled }, set: { model.setHotkeyEnabled($0) }))
                Spacer()
            }
            detail("Press the shortcut once to open Kopi and again to close it. Click the shortcut to record a new one.")
        }
    }

    private var shortcutReference: some View {
        SectionBox("In Kopi") {
            shortcut("Copy selected card", "⌘C")
            shortcut("Copy selected card", "↩")
            shortcut("Preview selected card", "Space")
            shortcut("Edit selected card", "⌘E")
            shortcut("Pin selected clipboard card", "⌘P")
            shortcut("Copy a numbered card", "⌘1–9")
            shortcut("Close preview or panel", "Esc")
            detail("While editing, shortcuts stay with the editor. Unsaved changes are protected before leaving.")
        }
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(keys).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(KopiTheme.insetSurface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(KopiTheme.border(contrast: contrast), lineWidth: 1))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.message { Text(message).font(.system(size: 11)).foregroundStyle(KopiTheme.accent) }
            HStack {
                Toggle("Open at login", isOn: Binding(get: { settings.settings.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .kopiTooltip(model.launchAtLoginStatus.displayName)
                Spacer()
                Text("Kopi").fontWeight(.semibold).foregroundStyle(.secondary)
                Button("Reset Settings…") { model.isConfirmingReset = true }
                    .buttonStyle(KopiActionButtonStyle())
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(KopiTheme.controlSurface)
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold)).padding(.bottom, 3)
            content
        }
        .font(.system(size: 12))
        .toggleStyle(.checkbox)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KopiTheme.cardSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KopiTheme.border(contrast: contrast), lineWidth: 1))
    }
}

private struct NotesSettingsSection: View {
    @ObservedObject var notes: NotesTabViewModel

    var body: some View {
        SectionBox("Apple Notes") {
            HStack(spacing: 10) {
                Toggle(notes.state.isConnected ? "Connected to Apple Notes" : "Connect Apple Notes", isOn: Binding(
                    get: { notes.state.isConnected },
                    set: { connected in Task { await notes.setConnected(connected) } }
                ))
                .disabled(notes.isChangingConnection)
                .kopiTooltip(notes.state.isConnected ? "Uncheck to disconnect Apple Notes" : "Connect Apple Notes")
                Spacer()
                if notes.isChangingConnection { ProgressView().controlSize(.small) }
            }
            Text(notes.state.isConnected
                 ? "Uncheck to disconnect. Kopi stops syncing and removes its cached note cards. Your notes stay in Apple Notes."
                 : "Read-only: browse, search, and copy notes after connecting. macOS calls this Automation access; Kopi cannot create, edit, or delete notes.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = notes.state.unavailableMessage ?? notes.state.errorMessage {
                Text(message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if notes.state == .permissionDenied {
                Text(NotesClientError.permissionDenied.userMessage).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if notes.state.isConnected {
                Divider()
                Label("Changes in Apple Notes appear automatically while the Notes tab is open", systemImage: "arrow.triangle.2.circlepath")
                    .kopiTooltip("Automatic Notes sync")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
