#!/bin/bash
#
# Builds dist/Kopi.app (via scripts/build-app.sh) and installs it to
# /Applications, so the copy you run is always the tree you just built.
#
# Two details keep macOS from showing more than one Kopi. The running
# instance is quit by its exact executable path before the bundle is
# replaced, because macOS activates apps by bundle identifier and would
# otherwise leave the old process serving "com.kopi.app". The dist
# bundle is removed afterwards: LaunchServices indexes application
# bundles by path, so a second copy on the Desktop shows up in Spotlight
# and can steal launches even though it shares the bundle identifier.
#
# The login item and ~/Library/Application Support/Kopi are left alone.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
product="Kopi"
bundle="$root/dist/$product.app"
destination="/Applications/$product.app"
launch=true

for argument in "$@"; do
    case "$argument" in
        --no-launch) launch=false ;;
        *) echo "error: unknown argument: $argument" >&2; exit 1 ;;
    esac
done

if [[ ! -w "/Applications" ]]; then
    echo "error: /Applications is not writable by $(whoami)" >&2
    exit 1
fi

"$root/scripts/build-app.sh"
codesign --verify --deep --strict "$bundle"

# Quit only the installed copy; a debug build from .build must not be hit.
if pgrep -f "$destination/Contents/MacOS/$product" >/dev/null 2>&1; then
    echo "Quitting the running $product"
    pkill -f "$destination/Contents/MacOS/$product"
    for _ in {1..20}; do
        pgrep -f "$destination/Contents/MacOS/$product" >/dev/null 2>&1 || break
        sleep 0.25
    done
fi

# Replace rather than merge, so a stale Resources or signature cannot
# survive beside the new build.
rm -rf "$destination"
ditto "$bundle" "$destination"

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$lsregister" -f "$destination"

# Drop the build artifact and its registration so the installed bundle is
# the only Kopi macOS knows about. scripts/build-app.sh recreates it.
"$lsregister" -u "$bundle" >/dev/null 2>&1 || true
rm -rf "$bundle"
rmdir "$root/dist" 2>/dev/null || true

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$destination/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$destination/Contents/Info.plist")"
echo "Installed $destination ($version, build $build)"

if $launch; then
    open -a "$destination"
fi
