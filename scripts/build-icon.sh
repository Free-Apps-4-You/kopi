#!/bin/bash
#
# Builds the macOS application icon from the project's SVG mark.
#
#   scripts/build-icon.sh            rebuilds Packaging/Kopi.icns from the committed iconset
#   scripts/build-icon.sh --refresh  redraws the iconset from docs/assets/favicon.svg first
#
# The SVG is the single source of truth. It is the mark the website uses as its
# favicon and the mark the menu bar shows, so the application looks the same
# everywhere it appears.
#
# Refreshing needs a renderer that can size SVG output exactly. Google Chrome
# is used when it is installed; the committed iconset means a plain build never
# needs one.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_svg="$root/docs/assets/favicon.svg"
iconset="$root/Packaging/AppIcon.iconset"
icns="$root/Packaging/Kopi.icns"
menu_template="$root/Packaging/MenuBarTemplate.png"

# The icon artwork sits inside the canvas with the margin macOS expects, so the
# icon lines up with the other applications in the Applications folder.
inset=100
canvas=1024

refresh=false
if [[ "${1:-}" == "--refresh" ]]; then
    refresh=true
fi

chrome=""
for candidate in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                   "/Applications/Chromium.app/Contents/MacOS/Chromium" \
                   "$(command -v chromium 2>/dev/null || true)" \
                   "$(command -v google-chrome 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then chrome="$candidate"; break; fi
done

if [[ "$refresh" == true ]]; then
    if [[ -z "$chrome" ]]; then
        echo "error: --refresh needs Google Chrome to size the SVG exactly" >&2
        echo "       the committed iconset can still be rebuilt with: scripts/build-icon.sh" >&2
        exit 1
    fi
    if [[ ! -f "$source_svg" ]]; then
        echo "error: missing $source_svg" >&2
        exit 1
    fi

    echo "Drawing the icon from $source_svg"
    work="$(mktemp -d "${TMPDIR:-/tmp}/kopi-icon.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    rm -rf "$iconset"
    mkdir -p "$iconset"

    # The padded canvas and the menu bar template are derived from the same file.
    ROOT="$root" WORK="$work" INSET="$inset" CANVAS="$canvas" python3 - <<'PY'
import os, re, pathlib

root = pathlib.Path(os.environ["ROOT"])
work = pathlib.Path(os.environ["WORK"])
inset = int(os.environ["INSET"])
canvas = int(os.environ["CANVAS"])

svg = (root / "docs/assets/favicon.svg").read_text()
inner = re.sub(r"^.*?<svg[^>]*>", "", svg, flags=re.S)
inner = re.sub(r"</svg>\s*$", "", inner, flags=re.S)

# The padded icon: the artwork scaled to sit inside the canvas.
scale = (canvas - inset * 2) / 64
padded = (
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {canvas} {canvas}" '
    f'width="{canvas}" height="{canvas}">\n'
    f'  <g transform="translate({inset} {inset}) scale({scale})">\n'
    f'{inner}\n  </g>\n</svg>\n'
)
(work / "padded.svg").write_text(padded)

# The menu bar mark: the same glyph without the rounded background, in black on
# a transparent ground. AppKit turns a template image into a mask, so the menu
# bar draws it in the right colour for the system, like every other menu bar
# item on the Mac.
glyph = inner
glyph = re.sub(r'<rect width="64" height="64"[^/]*/>', "", glyph, count=1)
glyph = re.sub(r'stroke="#62d1c4"', 'stroke="#000000"', glyph)
glyph = re.sub(r'fill="#62d1c4"', 'fill="#000000"', glyph)
glyph = re.sub(r"<defs>.*?</defs>", "", glyph, flags=re.S)
template = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="7 5 50 50" '
    'width="32" height="32">\n'
    f'{glyph}\n</svg>\n'
)
(work / "template.svg").write_text(template)
print("prepared padded canvas and menu bar mark")
PY

    render() {  # render <svg file> <size> <output png>
        local source="$1" size="$2" output="$3" page="$work/page.html"
        cat > "$page" <<HTML
<!doctype html>
<html><head><meta charset="utf-8"><style>
html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
svg { display: block; width: ${size}px; height: ${size}px; }
</style></head><body>
$(cat "$source")
</body></html>
HTML
        "$chrome" --headless --disable-gpu --no-sandbox --hide-scrollbars \
            --default-background-color=00000000 --force-device-scale-factor=1 \
            --virtual-time-budget=4000 --window-size="$size,$size" \
            --screenshot="$output" "file://$page" >/dev/null 2>&1
    }

    while read -r size name; do
        [[ -z "$size" ]] && continue
        render "$work/padded.svg" "$size" "$iconset/$name"
        echo "  $name ($size px)"
    done <<'SIZES'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
1024 icon_1024x1024.png
SIZES

    render "$work/template.svg" 32 "$menu_template"
    echo "  MenuBarTemplate.png (32 px, drawn at 16 points)"
fi

if [[ ! -d "$iconset" ]]; then
    echo "error: missing $iconset" >&2
    exit 1
fi

iconutil -c icns "$iconset" -o "$icns"
echo "Built $icns"
