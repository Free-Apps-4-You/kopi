#!/bin/bash
#
# Assembles dist/Kopi.app from a release build so the bundle can be launched
# from Finder, register a login item, and receive Automation consent as a bundle
# rather than as a terminal process. The bundle is ad-hoc signed, which is enough
# for a local run; see README.md for the signing a distributed copy needs.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
product="Kopi"
bundle="$root/dist/$product.app"
configuration="release"
architecture="$(uname -m)"
case "$architecture" in
    arm64|x86_64) ;;
    *) echo "error: unsupported architecture: $architecture" >&2; exit 1 ;;
esac

swift build --configuration "$configuration" --product "$product" --package-path "$root"

binPath="$(swift build --configuration "$configuration" --show-bin-path --package-path "$root")"
executable="$binPath/$product"
if [[ ! -x "$executable" ]]; then
    echo "error: $executable was not built" >&2
    exit 1
fi
if [[ "$(lipo -archs "$executable")" != "$architecture" ]]; then
    echo "error: executable architecture does not match $architecture" >&2
    exit 1
fi

minimumOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$root/Packaging/Info.plist")"
binaryMinimumOS="$(xcrun vtool -show-build "$executable" | awk '$1 == "minos" { print $2 }')"
if [[ "$binaryMinimumOS" != "$minimumOS" ]]; then
    echo "error: executable requires macOS $binaryMinimumOS; bundle declares $minimumOS" >&2
    exit 1
fi

# Rebuild from an empty output directory so an artifact from an earlier product
# name cannot survive beside the current bundle.
rm -rf "$root/dist"
mkdir -p "$bundle/Contents/MacOS"

cp "$executable" "$bundle/Contents/MacOS/$product"
cp "$root/Packaging/Info.plist" "$bundle/Contents/Info.plist"
printf 'APPL????' > "$bundle/Contents/PkgInfo"

codesign --force --sign - --entitlements "$root/Packaging/Kopi.entitlements" "$bundle"

echo "Built $bundle ($architecture, macOS $minimumOS+)"
