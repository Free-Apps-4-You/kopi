#!/bin/bash
# Package the app produced by build-app.sh as a DMG and an application ZIP.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle="$root/dist/Kopi.app"
if [[ ! -d "$bundle" ]]; then
    echo "error: run scripts/build-app.sh first" >&2
    exit 1
fi
codesign --verify --deep --strict "$bundle"
architecture="$(uname -m)"
image="$root/dist/Kopi-$architecture.dmg"
archive="$root/dist/Kopi-$architecture.zip"
staging="$(mktemp -d "${TMPDIR:-/tmp}/kopi-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto "$bundle" "$staging/Kopi.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Kopi -srcfolder "$staging" -ov -format UDZO "$image"
hdiutil verify "$image"
ditto -c -k --sequesterRsrc --keepParent "$bundle" "$archive"
unzip -tq "$archive"
echo "Built $image"
echo "Built $archive"
