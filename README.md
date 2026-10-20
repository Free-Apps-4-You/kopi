# Copily

Copily is a native macOS clipboard manager that lives in the menu bar. It opens a
panel directly beneath the MacBook notch, or at the top centre of a display
without one. The captured window contains no artificial camera-housing extension.
It includes a searchable grid of content cards, editable text, links, images, and files, persistent pins,
and a tab connected to the user's real Apple Notes.

Copily is built with Swift 6, SwiftUI and AppKit, stores its history in SQLite
through [GRDB](https://github.com/groue/GRDB.swift), and talks to Apple Notes
through ScriptingBridge. It targets macOS 14 and later.

## Requirements

- macOS 14 (Sonoma) or later.
- A Swift 6 toolchain. The Swift Command Line Tools are enough
  (`xcode-select --install`); a full Xcode installation is not required.
  `Package.swift` adds the Swift Testing macro plugin path that Command Line
  Tools installs in a non-standard location on machines without Xcode.
- Network access on the first build, to fetch the GRDB package.

The Apple Notes scripting interface is generated from Notes' scripting dictionary
with Xcode's `sdef` and `sdp` tools and checked in at `Sources/NotesScripting/`,
so building Copily does not need Xcode; only regenerating it does
(`scripts/generate-notes-scripting-header.sh`).

## Build, run and test

All commands run from the project root.

GitHub Actions uses Xcode 26.3 and runs the serial regression suite, isolated storage self-check,
release app build, signature verification, and DMG packaging on macOS for pushes
to `main` and pull requests. Each successful run provides a `Copily-macOS`
artifact containing the disk image and SHA-256 checksum. Build outputs and local
review captures are excluded from Git.

| Command | What it does |
|---|---|
| `swift build` | Builds `CopilyCore` and the `Copily` executable (debug). |
| `swift test --no-parallel` | Runs the core and app regression suites: storage, retention, search, capture, assets, panel layout, preview memory and observation, editor contrast, shutdown deadlines, and Notes against fakes. |
| `swift run Copily` | Starts Copily as a menu bar app. Press ⌥⌘V, or use the menu bar icon, to open the panel. |
| `swift run Copily --selfcheck` | Headless self-check against a throwaway database. Prints diagnostics (journal mode, dedupe, search, retention, asset preservation) and exits 0 on success, 1 on failure. |
| `scripts/build-app.sh` | Release build assembled into a runnable `dist/Copily.app`, ad-hoc signed, and prints the path. |
| `scripts/build-dmg.sh` | Packages that bundle as `dist/Copily-<version>-<architecture>.dmg` with an Applications shortcut and checksum. |

`swift run Copily` starts an accessory application: it has no Dock icon, so quit
it from the menu bar item or with `Ctrl+C` in the terminal that launched it.
**Launch at Login** works from the packaged build, which is a real bundle; the
command line build reports that the option is available in the packaged app.

## Permissions

### Clipboard access

Copily polls `NSPasteboard.changeCount` roughly every 250 ms and reads content
only when the count changed, so idle CPU stays low. On macOS 15.4 and later,
macOS exposes the user's clipboard access behaviour
([`NSPasteboard.accessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum)):

- When access is set to **Always Deny**, Copily's read is refused. Copily reports
  it ("macOS is not allowing Copily to read the clipboard."), stops the capture
  loop instead of retrying in a tight loop, and leaves the rest of the app
  usable. Grant access in System Settings and relaunch Copily to resume capture.
- When macOS is set to **Ask** and the user declines a read, the read comes back
  empty and is treated as unsupported content; the next copy is read normally.
- On earlier macOS versions, pasteboard reads do not need consent.

Copily reads only the flavours it can store (text, RTF, HTML, links, images,
file references) and never writes to the pasteboard except when you copy or
paste a card.

### Apple Events and Apple Notes

Nothing is requested until you choose **Connect Apple Notes** in the Notes tab.
Copily then asks macOS for automation consent through
`AEDeterminePermissionToAutomateTarget`, which is what puts up the standard
consent dialog. The dialog's explanation comes from `NSAppleEventsUsageDescription`
in the bundle. Notes must be running for a meaningful answer, so Copily opens it
once (without bringing it forward) if needed.

- Consent is recorded by macOS in System Settings ▸ Privacy & Security ▸
  Automation, per application. Denial is a distinct state: the Notes tab
  explains it and points to System Settings. Granting it there takes effect on
  the next connection attempt.
- The packaged bundle carries the `com.apple.security.automation.apple-events`
  entitlement (`Packaging/Copily.entitlements`) as the plan requires.
- When run through `swift run Copily`, consent is attributed to the terminal
  that launched it. Launch `dist/Copily.app` to see the real behaviour.
- Copily never touches Notes' private database or frameworks; every request is a
  normal Apple Event against the scriptable interface, sent through
  ScriptingBridge.

### Accessibility and auto-paste

Pressing **Return** on a card copies it and asks Copily to post ⌘V into the
application you came from. macOS only allows a process to inject keyboard
events when it is trusted for accessibility
(`CGPreflightPostEventAccess`). Without that trust Copily degrades gracefully:
the card is still written to the clipboard and a toast tells you
**"Copied — press ⌘V to paste"**. Copy-only use of Copily never requires
Accessibility. To enable auto-paste, add Copily in System Settings ▸ Privacy &
Security ▸ Accessibility.

### Panel interactions

- **All Apps** filters the entire clipboard history by source application, together
  with search, content tabs, Pinned, and Collection. Home clears this filter. Earlier
  Copily identities appear together under the current app name.
- Explicit **HEX and RGB colors** show a swatch and normalized values. Space opens
  a color inspector with HEX/RGB copy controls; the card menu offers the same
  conversions. The original clipboard item remains text and is never rewritten.
- **Settings ▸ Privacy ▸ Import the current clipboard when Copily starts** opts into
  importing pre-launch content. It defaults off and applies at the next launch.
  An imported pre-launch item has an unknown source, so source-app exclusions cannot
  be applied to it. Pause capture continues to prevent reads.
- A **single click** on a card copies it straight away — the same path as **⌘C**,
  including the "Copied to clipboard" status — and moves the selection to the
  card clicked, so **Return** still pastes it. The panel stays open, so several
  cards can be copied in a row.
- Every card is **draggable**: text drags as `public.utf8-plain-text`, rich text
  as RTF, HTML, and plain text, a link as `public.url` plus its label or URL, an
  image as a file of the stored asset plus its image data, and a file card as
  the file itself, falling back to Copily's snapshot once the original is gone.
  A drag carries one item, so a card holding several files does not drag; the
  drag preview shows the full card, using the same native snapshot behavior as Notes.
  Every card has a visible **…** actions menu and maximise arrow.
- The **maximise arrow** (or Space) opens a content-sized focus preview over a
  blurred app. Short text stays compact; long text scrolls within readable bounds.
  Images keep their aspect ratio, with Fit and zoom controls. Escape closes it.
- The compact search field shares a row with icon-labelled Pinned and Collection
  filters, with **+** and then Home to the left of search. Search takes
  two thirds of its former width. Card selection borders change immediately when switching tabs.
- Hover and menu-bar openings use a short native magnification, fade and slide without resizing the card grid. Clicking
  the menu-bar icon again hides the panel, including during an in-flight opening.
  Each opening explicitly restores keyboard focus to the native search field.
  Opening Settings hides the panel before showing or focusing the Settings window,
  including when that window is already open.
  Secondary-click, Control-click, or double-click opens the standard status-item
  menu directly beneath the icon; clicking elsewhere or Escape dismisses that menu.
- The panel also opens by **hover**: rest the pointer inside the physical notch
  for the delay set in Settings ▸ Opening. The target uses macOS camera-housing
  geometry in logical screen coordinates, with no extra activation margin.
  Movement inside the notch preserves the dwell; leaving it cancels the dwell.
  Dismissal uses the same measured target, including the physical top screen edge,
  so moving farther into the housing cannot immediately dismiss a hover reveal.
  Displays without a notch use the menu bar or keyboard shortcut instead.
- A **click outside** the panel dismisses it, whether it lands in another
  application or in the transparent margin the panel keeps around its surface
  for the shadow. **Close when clicking outside the panel** in Settings ▸
  Opening turns that off, which leaves the panel open when you switch to another
  application and puts a close button in the panel's header; Escape and pasting
  a card always dismiss it.

### The collection

The **Collection** chip holds cards that are kept for good: retention, Clear
History, session cleanup and interrupted-exit recovery all leave them alone, and
they survive quitting, force quitting and relaunching. Only an explicit Delete
removes a collected card.

- **New Item** — **+** to the left of search, or the empty state's action — opens
  a staged composer over the current screen. Add one item at a time: text or a link,
  pasted clipboard content, one file/folder or image, or one dropped item. Explicit
  Text, Link, File and Image modes show only the relevant input. Changing type asks
  before clearing entered content. An optional
  label is saved with that item and is searchable. Content types cannot be mixed.
  Save adds the content to Collection using the normal capture pipeline.
  Cancel closes untouched empty drafts immediately. Discard keeps the previous tab, filter,
  search, and selection, without leaving temporary cards behind. Importing files
  and converting image formats happens off the main actor.
- **Paste** copies the current clipboard into the collection with **⌘V** while
  the Collection view is on show and the search field is not being typed in. It
  reuses the capture pipeline, so text, rich text, links, images and Finder file
  copies are stored in the same shapes an ordinary copy produces, and adding the
  same content twice collapses onto the collected card rather than piling up
  duplicates. The clipboard observation state — own-copy suppression and the
  remembered change count — is left exactly as it was by this path.
- **Drop** content from another application or Finder anywhere in the Collection
  view, or drop a card of another chip onto the **Collection** chip. A
  multi-file drop stays one card in drop order. Dropping one of Copily's own cards
  stores a collection copy and leaves the history card exactly as it is;
  identical content already on the shelf collapses onto one card.
- Collected cards behave like every other card: click copies, Return pastes, drag
  drags out, Space previews, the arrow maximises, ⌘E edits, and the right-click
  menu offers Copy, Edit and Delete. **Pinning is not offered on a collected
  card**, because the collection already keeps it for good; ⌘P says so instead of
  pinning.

## Architecture

Copily is one application target with small components and explicit dependencies:

| Component | Responsibility | Source |
|---|---|---|
| `PanelController` | Panel placement, activation, focus restoration, shortcuts, and dismissal | `Sources/Copily/Panel/PanelController.swift` |
| `ClipboardService` | Clipboard observation, supported-content snapshots, copy/paste, and own-write suppression | `Sources/CopilyCore/Capture/ClipboardService.swift` |
| `CaptureProcessor` | Content fingerprints, text extraction, thumbnails, and asset preparation | `Sources/CopilyCore/Capture/CaptureProcessor.swift` |
| `HistoryStore` | Persistence, search, transactional edits, pins, deletion, and retention | `Sources/CopilyCore/Persistence/HistoryStore.swift` |
| `NotesClient` | Apple Notes automation, refresh, creation, editing, and connection state | `Sources/CopilyCore/Notes/NotesAutomationClient.swift` |
| Feature view models | UI state, selection, loading, search requests, and user-visible errors | `Sources/Copily/ViewModels/` |

UI updates stay on the main actor. Clipboard access, database work, and Notes
automation each run on their own serialized worker (actors), and only immutable
snapshots cross between them. Views never see database records or scripting
objects.

### Persistence, assets, and retention

- Upgrading from the earlier app name moves the existing Application Support folder
  and migrates its metadata table to `copily_metadata`, preserving history, pins,
  collected cards, search data, and retention settings. Databases already created
  under Copily remain compatible.
- **SQLite via GRDB** at `~/Library/Application Support/Copily/history.sqlite`,
  in WAL mode with `synchronous=FULL`, so pins and edits are acknowledged only
  after a durable commit.
- **Assets** live under `~/Library/Application Support/Copily/Assets`, content
  addressed by SHA-256 digest: the same bytes are stored once. Images are
  imported during capture; pinning a file card copies the original into the
  store, so a pinned card keeps working if the original is moved or deleted.
  A failed copy leaves the existing card untouched and reports that pinning did
  not complete, and assets still referenced by a pinned card are never deleted.
- **Retention** applies only to unpinned items: **Current session** clears on a
  normal quit and removes the previous session's items after an interrupted
  exit; **7 days** (default) and **30 days** expire items from their last
  external copy time. Unpinning starts a fresh period. Cleanup runs at startup,
  after retention changes, and periodically while Copily runs. Pins survive
  quitting, force quitting, restarts, and retention changes; they are excluded
  from Clear History and can only be removed one at a time.
- **Upgrading from an earlier build:** the first launch moves the earlier
  Application Support folder to `~/Library/Application Support/Copily` once,
  before any store opens, so clipboard history, assets and the password vault
  keep their relative paths. Settings are copied from the earlier preferences
  suite on the same launch. Later launches use only the Copily locations.

### Search and rendering

- SQLite **FTS5 trigram** indexing serves substring searches of three or more
  characters — URL and code fragments without needing whole words — with a
  bounded database scan as the fallback for shorter queries. Indexes are
  updated transactionally with content changes.
- Search is debounced by 120 ms; superseded requests are cancelled and stale
  responses discarded. Cards are fetched in pages of 60 lightweight records.
- Thumbnails are generated off the main actor behind a bounded 32 MB cache;
  original images and large payloads load only for preview, copy, or paste.
- UI previews have their own 32 MB / 120-entry budget. Each card observes its
  own preview entry, so a thumbnail arriving does not redraw every other card.
  Editing invalidates the saved preview, and cancelled loads cannot publish stale
  content. The panel's AppKit frame owns its size, including empty Notes states.

### Passwords and draft protection

Passwords are entered manually in their own tab. Titles are list metadata; usernames
and passwords are AES-256-GCM encrypted, with each record ID authenticated to prevent
payload swapping. There is one vault location,
`~/Library/Application Support/Copily/Passwords/vault.json`, with its random encryption
key beside it in `vault-key` (mode 0600 inside a 0700 directory) rather than in the
Keychain: a Keychain item's access control list trusts the exact code signature that
created it, so an ad-hoc-signed development build would be asked for the login keychain
password again after every rebuild. View uses only macOS LocalAuthentication; when
system authentication is unavailable, the list and composer explain that a Mac login
password must be configured.

Earlier builds kept the vault key in the Keychain, in the archived item
`com.velpy.app.password-vault-key`. Copily never asks for the login keychain password on
its own. Launch does not query the Keychain, even when an archived vault has no local
key. The archived service name is kept solely to recover existing passwords; changing
that identifier to match the new app name would make the old key undiscoverable.
Only an explicit **Migrate** action reads it, so a recovery prompt may still show the
archived item's old name.

A vault from such a build — records exist and no `vault-key` file does — is still shown in
the Passwords tab, with a banner above its entries:

- **Migrate** reads the archived keychain key with interaction allowed. That is the single
  system prompt, and it appears only because the user clicked Migrate; the key is written
  to `vault-key` and the entries open as usual. macOS does not ask again afterwards.
- **Start Fresh** asks for confirmation in an alert, then discards the old entry and
  creates an empty vault with a fresh key. It never reads the Keychain and never prompts.

While the key is missing, revealing or adding a password fails with a message naming
Migrate and Start Fresh, before any Keychain access, decryption, or system authentication,
and the encrypted file is left byte for byte as it was. A missing key never generates a
replacement for existing entries. A new installation with no records creates its key
without touching the Keychain at all. Password payloads are never put in clipboard history,
preferences, search indexes, or logs. The encrypted vault is written atomically with
owner-only permissions.

Every Show invokes a fresh LocalAuthentication device-owner check before decryption.
Touch ID is optional: macOS provides the Mac login-password fallback. If system
authentication is unavailable, saving/revealing is blocked and the UI explains that
a Mac login password must be configured. Revealed values hide after 20 seconds, on
leaving Passwords, on panel dismissal, on app deactivation, and on sleep/session lock.
Tests use isolated temporary vaults, keys, archived-key fakes, and authentication fakes,
so no test reads the real Keychain; real system password/Touch ID consent must be
completed by the user.

The header and navigation row remain interactive while a preview is focused; switching
tabs closes it. All previews, including Notes, share a red macOS-style close control
at top left. Images have Fit/zoom controls at the footer's right. App-owned tooltips use a 100 ms delay,
including the menu-bar icon and native rich-text formatting controls.
Home returns to All and clears Pinned/Collection. The + action adds a manual clipboard
item or password according to the current tab; Notes has no Add control. Leaving an editor with changes, closing the
panel, or quitting offers Save, Discard Changes, and Keep Editing. A failed save leaves
the draft open and prevents the pending navigation.

### Settings and motion

Settings uses separate Opening, History, Privacy, Notes, and Shortcuts tabs, with
Open at Login and confirmed Reset Settings always available in the footer.
Opening offers hover delay, Fast/Normal/Relaxed animation speed, appearance, and
compact cards. Compact mode applies to clipboard, Notes, passwords, and loading
skeletons. History includes Pause Saving Copies, backed by the capture service:
pausing cancels its timer, while saved cards and explicit additions remain usable.
These preferences persist and default safely when loading older settings.

The panel expands from a notch-sized shape at the top centre into its full size,
with a short settle. A dedicated compositor surface animates the complete panel;
the card grid keeps its final layout throughout. The origin uses the measured
notch width, with a top-centred fallback on displays without a notch. Settings
opens at 600 × 540 points and uses a subtle scale, fade, and slide after the panel
finishes hiding. Both follow the animation speed and macOS Reduce Motion.

The panel background uses a single opaque graphite fill in SwiftUI's render tree,
with a separate noninteractive shadow. It does not embed a live AppKit backdrop
blur inside the scaled compositor surface; that combination produced rectangular
repaint patches when moving the pointer after opening. Light/dark appearance,
rounded edges, card hover effects, and the expansion animation remain supported.

Settings handoffs invalidate pending reveals and continue to order the panel out
while the existing Settings window activates. Application reopen callbacks during
that handoff cannot bring it back. Explicit menu-bar, shortcut, and hover actions
can still open Copily while Settings exists. Unsaved edits pass through one shared
save guard before Settings is shown.

With outside-click dismissal enabled, clicking anywhere in the Settings window
hides the clipboard panel and leaves Settings open. These same-process clicks use
the local event monitor, preserve the click for Settings controls, and do not
restore focus to a different application. Unsaved edits still prompt before hiding.

The panel's hosting layers and native Settings gear accept the first mouse click,
including when hover reveals the panel while Settings owns window focus. This is
explicit because AppKit's default `NSView.acceptsFirstMouse(for:)` rejects it.
Regression tests check this input contract as well as repeated gear actions;
accessibility activation alone does not exercise first-mouse delivery.

The Notes checkbox represents the actual Apple Notes connection. Unchecking clears
the in-memory cards, bodies, previews, and selection and disconnects the client;
returning to Notes shows Connect Apple Notes. No Apple Notes data is deleted.
Connection generations invalidate in-flight automation reads so a late refresh
cannot repopulate a disconnected index. Reconnecting migrates an old empty-folder
selection to the default scope. Finish a note edit before disconnecting.

### Apple Notes client

`Sources/CopilyCore/Notes/` drives the real client through ScriptingBridge:
`ScriptingBridgeNotesRunner` sends the requests defined by the generated
scripting header (`Sources/NotesScripting/Notes.h`, generated from Notes'
dictionary and checked in), with a finite reply timeout on its own serial
worker, and captures failed events through the application's ScriptingBridge
delegate, mapping the Apple Event status to the Notes tab's connection states.
Metadata is fetched first so note cards appear before indexing finishes;
changed bodies are indexed in bounded batches, and the tab shows indexing
progress while search coverage is incomplete. Notes remains the source of
truth: nothing is copied into Copily's database. The tab quietly checks for additions,
edits, and deletions every three seconds while visible, and refreshes when reopened.
Sync pauses while the panel is hidden or a draft is open; unchanged note bodies are
reused. Notes use the same adaptive card grid as clipboard items, with click-to-preview
and an actions menu for copying, editing, and opening in Apple Notes. Like clipboard
cards, Notes cards copy on click, paste with Return, maximise with the arrow or Space,
and drag their complete text to other applications. Drag promises resolve on background
tasks without requiring the UI thread, including when AppKit waits synchronously. A Notes failure leaves
Clipboard and Pinned fully usable. Before saving, Copily re-reads the note's
modification date; if it changed externally the draft is preserved and offered
**Reload** instead of overwriting. Copily edits existing notes but does not create new
Apple Notes; create notes in Apple Notes itself. Inline editing is
allowed only for content that passes a conservative text-only check; rich
content opens in Apple Notes.

Folder checkboxes allow every folder to be unchecked. This explicit empty selection
persists across reconnects; the default folder is used only before a choice is made.
Changes made during a sync queue another refresh, and stale results cannot restore
notes from an excluded folder.

Notes search uses the complete indexed body rather than just its card excerpt.
All included notes are available through pagination; there is no 180-note cutoff.
When an indexed note becomes protected, its cached body and excerpt are removed.
Preview and editor requests carry identities so a slow response cannot replace a
newer one. Notes overlays observe the Notes model directly and Escape closes the
active overlay before dismissing the panel.

Regenerating the scripting interface after a macOS update needs Xcode — the
build itself does not:

```sh
scripts/generate-notes-scripting-header.sh
```

The script finds Xcode through `DEVELOPER_DIR`, `xcode-select -p`, or the usual
`/Applications` and `~/Desktop` locations, regenerates `Notes.h` and `Notes.m`,
and explains what to install when it cannot find one.

## Packaging and distribution

- `Packaging/Info.plist` — app bundle metadata: `LSUIElement` (menu bar app,
  no Dock icon), bundle identifier `com.copily.app`, minimum system version
  14.0, the Apple Events usage description, and version 0.1.0 (build 1).
- `Packaging/Copily.entitlements` — the
  `com.apple.security.automation.apple-events` entitlement. No sandbox keys:
  Copily is distributed directly, not through the App Store.
- `scripts/build-app.sh` — builds `swift build -c release`, assembles
  `dist/Copily.app` (binary in `Contents/MacOS`, `Info.plist`, `PkgInfo`), and
  ad-hoc signs it (`codesign --force --sign -`) with the entitlements, so TCC
  can attribute clipboard, automation, and accessibility choices to the bundle
  rather than to a terminal process. The script is idempotent and prints the
  bundle path; `open dist/Copily.app` launches it.

The plan assumes **direct, signed and notarized distribution**. An ad-hoc
signature is fine for local runs, but a distributed copy must be signed with a
Developer ID Application certificate (with the hardened runtime) and notarized:

```sh
codesign --force --options runtime --timestamp \
    --sign "Developer ID Application: <Team Name> (<TEAMID>)" \
    --entitlements Packaging/Copily.entitlements dist/Copily.app
ditto -c -k --keepParent dist/Copily.app dist/Copily-0.1.0.zip
xcrun notarytool submit dist/Copily-0.1.0.zip --keychain-profile <profile> --wait
xcrun stapler staple dist/Copily.app
```

Note that ad-hoc builds get a new code hash on every rebuild, so macOS may ask
for automation or accessibility consent again, and Gatekeeper blocks them on
other Macs.

## Verification and acceptance

This is the implementation acceptance checklist. A checked box means `swift
test` (or `swift run Copily --selfcheck`) already verifies the behaviour at the
component level; unchecked boxes need a person, the real Notes app, or real
hardware. Run `swift test` to reproduce the automated half.

- [x] Pin and edit an item, force-quit immediately after the successful save,
      and verify both survive relaunch — `HistoryStorePersistenceTests` reopens
      the store without ending the session, exactly as a force quit leaves it.
- [ ] The same end to end in the launched app: force-quit `Copily.app` right
      after pinning, relaunch, and confirm the pinned card and edit are shown.
- [x] Exercise every retention setting and Clear History with mixed
      pinned/unpinned content — `RetentionTests`.
- [x] Delete or move an original pinned file and verify Copily's saved copy still
      works — `AssetStoreTests`, and the `--selfcheck` run deletes the original
      and re-reads the snapshot.
- [x] Confirm an own-copy operation creates no duplicate and the next external
      copy is captured — `ClipboardServiceTests`.
- [x] Test Unicode, URL fragments, punctuation, rapid search changes, and
      stale-result cancellation — `SearchTests` and its "Search delivery" suite.
- [ ] Verify edited rich text pastes its updated content into both plain-text
      and rich-text applications — the rebuilt HTML/RTF flavours are automated
      (`RichTextTests`); pasting into a real text editor and a word processor
      needs manual verification.
- [x] Verify Notes creation/editing, external-edit conflicts, denied permission,
      and timeouts against the client boundary — `NotesAutomationClientTests`
      and `NotesScriptingRunnerTests` drive them through scripted runners.
- [ ] Verify the same Notes flows in the real Notes app: connect and
      edit a note, change a note in Notes while a draft is open, deny
      automation in System Settings, and exercise a timeout.
- [ ] Test notchless displays, multiple monitors, Spaces, full-screen
      applications, and keyboard accessibility — needs real displays and
      hardware.

Performance targets on an **M1 MacBook Air with 8 GB RAM** (all manual):

- [ ] Warm panel opening: p95 below 150 ms.
- [ ] Search across 10,000 representative text clips: p95 below 100 ms,
      excluding the 120 ms debounce.
- [ ] Ordinary copied text visible within 750 ms.
- [ ] Closed-panel idle CPU: below 0.5% averaged over five minutes.
- [ ] Repeated image scrolling reaches a stable memory level.
