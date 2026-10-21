# Contributing to Kopi

Bug reports, ideas, and pull requests are welcome.

- For a bug, include your macOS version, Kopi version, steps to reproduce, and expected behavior. Remove personal clipboard content from screenshots and logs.
- For a feature, describe the task you want to make easier. Discuss substantial changes in an issue first.
- Keep pull requests focused and explain how you checked the change.

To work locally, use macOS 14+ and a Swift 6 toolchain (CI uses Xcode 26.3):

```sh
swift build
swift test --no-parallel
swift run Kopi --selfcheck
```

Run the app with `swift run Kopi`, or create a bundle with `scripts/build-app.sh`.
Install that bundle to `/Applications` with `scripts/install-app.sh`, which quits
the running copy and removes the `dist` bundle so macOS sees only one Kopi; add
`--no-launch` to skip reopening it. Package the bundle with `scripts/build-dmg.sh`.
These scripts build for the current Mac. Downloads are named `Kopi-Intel-Mac`
or `Kopi-Apple-Silicon-Mac` to match the application's actual architecture;
release builds run on each processor natively.

## The application icon

The mark in `docs/assets/favicon.svg` is the one source of truth for the icon.
`scripts/build-icon.sh` turns it into everything macOS needs:

```sh
scripts/build-icon.sh            # rebuilds Packaging/Kopi.icns from the committed iconset
scripts/build-icon.sh --refresh  # redraws the iconset from the SVG first
```

Refreshing needs Google Chrome, which can size SVG output exactly. The iconset in
`Packaging/AppIcon.iconset` is committed, so a plain build never needs a renderer
and never depends on one being installed.

The result is the application icon in the bundle, the mark in the menu bar and the
favicon on the website. Keep the SVG as the source and refresh the iconset when the
mark changes, so they cannot drift apart.

## The project website

The site in `docs/` is published by GitHub Pages from the `main` branch. It is
plain HTML, CSS and one small script, with no build step and no dependencies.

The screenshots it uses are drawn by the application itself:

```sh
swift run Kopi --render-showcase docs/assets/images
```

The command fills a throwaway database with sample content, draws the real views
into an off-screen window and writes the PNG files. Nothing appears on screen, the
clipboard is never observed, and no window takes the keyboard, so it is safe to run
while the Mac is in use. Keep the file names stable: the page refers to them.

By submitting a contribution, you agree to license it under the project's MIT license.

Apple Notes integration is intentionally read-only. Keep create, update, delete,
and move commands out of the Notes client and scripting bridge. macOS still uses
its broad Automation permission dialog for reading Notes; it has no separate
read-only permission for this interface.

## Publishing a release

Update the version and build number in `Packaging/Info.plist`, commit the change,
and push an annotated version tag such as `v0.3.3`. The tag must match the app version.
GitHub Actions runs the tests and packaged-app self-check on both Apple Silicon
and Intel macOS 15 runners. After both pass, it publishes separate DMG and application
ZIP downloads for each processor under Releases. Both builds require macOS 14+.
Use the tag annotation for the app's release notes. The workflow adds a processor
selection table and descriptive labels to the downloads automatically.

The offscreen panel pixel snapshot runs on Apple Silicon. It is excluded on the
Intel CI virtual machine because its virtual Metal device aborts in SwiftUI's
`ImageRenderer`; all other tests and the packaged executable self-check run on both.
Radial geometry tests check the drawn contours with Core Graphics, which avoids
SwiftUI `Path.contains` misclassifying the center during scaling on Intel.

Main-branch builds remain available as Actions artifacts. The README's download
links always point to the latest published installers.
