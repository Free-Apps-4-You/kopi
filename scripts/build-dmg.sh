#!/bin/bash
# Package the app produced by build-app.sh into a read-only drag-to-install image.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle="$root/dist/Copily.app"
if [[ ! -d "$bundle" ]]; then
    echo "error: run scripts/build-app.sh first" >&2
    exit 1
fi
codesign --verify --deep --strict "$bundle"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")
architecture="$(uname -m)"
image="$root/dist/Copily-$version-$architecture.dmg"
staging="$(mktemp -d "${TMPDIR:-/tmp}/copily-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto "$bundle" "$staging/Copily.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Copily -srcfolder "$staging" -ov -format UDZO "$image"
hdiutil verify "$image"
shasum -a 256 "$image" > "$image.sha256"
echo "Built $image"
