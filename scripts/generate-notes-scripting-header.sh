#!/usr/bin/env bash
set -euo pipefail

# Regenerates the checked-in Apple Notes scripting interface from the application's
# scripting dictionary with Xcode's sdef and sdp tools. The generated files are
# committed, so Copily builds with the Command Line Tools alone; Xcode is needed only
# to run this script.

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
notes_app="${NOTES_APP:-/System/Applications/Notes.app}"
destination="$project_root/Sources/NotesScripting"

candidates=(
    "${DEVELOPER_DIR:-}"
    "$(xcode-select -p 2>/dev/null || true)"
    /Applications/Xcode.app/Contents/Developer
    "$HOME/Desktop/Xcode.app/Contents/Developer"
)

developer_directory=""
for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate/usr/bin/sdef" && -x "$candidate/usr/bin/sdp" ]]; then
        developer_directory="$candidate"
        break
    fi
done

if [[ -z "$developer_directory" ]]; then
    cat >&2 <<'MESSAGE'
Xcode is required to regenerate the Notes scripting interface: sdef and sdp are
Xcode tools. Install Xcode, select it with `xcode-select -s`, or point DEVELOPER_DIR
at it, for example:

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/generate-notes-scripting-header.sh

Copily itself builds without Xcode: the generated files are checked in.
MESSAGE
    exit 1
fi

if [[ ! -d "$notes_app" ]]; then
    echo "Apple Notes was not found at $notes_app." >&2
    exit 1
fi

echo "Using Xcode at $developer_directory"
export DEVELOPER_DIR="$developer_directory"

staging_directory="$(mktemp -d)"
trap 'rm -rf "$staging_directory"' EXIT

"$developer_directory/usr/bin/sdef" "$notes_app" \
    | "$developer_directory/usr/bin/sdp" -fhm --basename Notes -o "$staging_directory"

cp "$staging_directory/Notes.h" "$destination/include/Notes.h"
cp "$staging_directory/Notes.m" "$destination/Notes.m"
echo "Regenerated $destination/include/Notes.h and $destination/Notes.m"
