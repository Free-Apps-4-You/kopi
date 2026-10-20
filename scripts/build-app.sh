#!/bin/bash
#
# Assembles dist/Copily.app from a release build so the bundle can be launched
# from Finder, register a login item, and receive Automation consent as a bundle
# rather than as a terminal process. The bundle is ad-hoc signed, which is enough
# for a local run; see README.md for the signing a distributed copy needs.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
product="Copily"
bundle="$root/dist/$product.app"
configuration="release"

swift build --configuration "$configuration" --product "$product" --package-path "$root"

binPath="$(swift build --configuration "$configuration" --show-bin-path --package-path "$root")"
executable="$binPath/$product"
if [[ ! -x "$executable" ]]; then
    echo "error: $executable was not built" >&2
    exit 1
fi

# Rebuild from an empty output directory so an artifact from an earlier product
# name cannot survive beside the current bundle.
rm -rf "$root/dist"
mkdir -p "$bundle/Contents/MacOS"

cp "$executable" "$bundle/Contents/MacOS/$product"
cp "$root/Packaging/Info.plist" "$bundle/Contents/Info.plist"
printf 'APPL????' > "$bundle/Contents/PkgInfo"

codesign --force --sign - --entitlements "$root/Packaging/Copily.entitlements" "$bundle"

echo "Built $bundle"
