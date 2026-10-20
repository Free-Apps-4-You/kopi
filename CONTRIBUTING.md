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
Package that bundle with `scripts/build-dmg.sh`.
These scripts build for the current Mac. Installer filenames follow the
application's actual architecture; release builds run on each processor natively.

By submitting a contribution, you agree to license it under the project's MIT license.

## Publishing a release

Update the version and build number in `Packaging/Info.plist`, commit the change,
and push an annotated version tag such as `v0.3.3`. The tag must match the app version.
GitHub Actions runs the tests and packaged-app self-check on both Apple Silicon
and Intel macOS 15 runners. After both pass, it publishes separate DMG and application
ZIP downloads for each processor under Releases. Both builds require macOS 14+.
Use the tag annotation for the release notes.

The offscreen panel pixel snapshot runs on Apple Silicon. It is excluded on the
Intel CI virtual machine because its virtual Metal device aborts in SwiftUI's
`ImageRenderer`; all other tests and the packaged executable self-check run on both.
Radial geometry tests check the drawn contours with Core Graphics, which avoids
SwiftUI `Path.contains` misclassifying the center during scaling on Intel.

Main-branch builds remain available as Actions artifacts. The README's download
links always point to the latest published installers.
