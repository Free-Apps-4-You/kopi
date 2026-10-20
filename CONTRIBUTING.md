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

By submitting a contribution, you agree to license it under the project's MIT license.
