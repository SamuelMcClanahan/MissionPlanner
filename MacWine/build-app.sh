#!/bin/bash
# Assembles "Mission Planner.app" (Wine bundle) from:
#   - a Windows build of Mission Planner (folder with MissionPlanner.exe)
#   - a macOS Wine build tarball from https://github.com/Gcenx/macOS_Wine_builds
#   - winetricks
# Runs on macOS (CI) and on Linux (for a layout check; no icon or signature there).
set -euo pipefail

usage() {
    echo "Usage: $0 --mp DIR --wine WINE.tar.xz --winetricks FILE --version VERSION --out DIR [--icon PNG]" >&2
    exit 1
}

MP_SRC="" WINE_TAR="" WINETRICKS="" VERSION="" OUT="" ICON=""
while [ $# -gt 0 ]; do
    case "$1" in
        --mp) MP_SRC="$2"; shift 2 ;;
        --wine) WINE_TAR="$2"; shift 2 ;;
        --winetricks) WINETRICKS="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --icon) ICON="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$MP_SRC" ] && [ -n "$WINE_TAR" ] && [ -n "$WINETRICKS" ] && [ -n "$VERSION" ] && [ -n "$OUT" ] || usage
[ -f "$MP_SRC/MissionPlanner.exe" ] || { echo "No MissionPlanner.exe in $MP_SRC" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$OUT/Mission Planner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "== Info.plist"
sed "s/@VERSION@/$VERSION/g" "$HERE/Info.plist.in" > "$APP/Contents/Info.plist"

echo "== launcher"
cp "$HERE/launcher.sh" "$APP/Contents/MacOS/MissionPlanner"
chmod 755 "$APP/Contents/MacOS/MissionPlanner"
echo "$VERSION" > "$APP/Contents/Resources/bundle-version.txt"

echo "== winetricks"
cp "$WINETRICKS" "$APP/Contents/Resources/winetricks"
chmod 755 "$APP/Contents/Resources/winetricks"

echo "== Wine"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -xJf "$WINE_TAR" -C "$TMP" 2>/dev/null
WINE_APP="$(find "$TMP" -maxdepth 1 -name '*.app' | head -1)"
[ -d "$WINE_APP/Contents/Resources/wine/bin" ] || { echo "Unexpected Wine tarball layout" >&2; exit 1; }
mv "$WINE_APP/Contents/Resources/wine" "$APP/Contents/Resources/wine"
# Wine Mono and Gecko are not used: .NET Framework 4.8 is installed on first start.
rm -rf "$APP/Contents/Resources/wine/share/wine/mono" "$APP/Contents/Resources/wine/share/wine/gecko"

echo "== Mission Planner"
mkdir -p "$APP/Contents/Resources/MissionPlanner"
cp -R "$MP_SRC/." "$APP/Contents/Resources/MissionPlanner/"

if [ -n "$ICON" ] && command -v sips >/dev/null && command -v iconutil >/dev/null; then
    echo "== icon"
    SET="$TMP/AppIcon.iconset"
    mkdir -p "$SET"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$ICON" --out "$SET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d "$ICON" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

if command -v codesign >/dev/null; then
    echo "== ad hoc signature"
    codesign --force --deep --sign - "$APP" || echo "warning: ad hoc signing failed" >&2
fi

echo "Built: $APP"
du -sh "$APP"
