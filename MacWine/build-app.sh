#!/bin/bash
# Assembles "Mission Planner.app" (Wine bundle) from:
#   - a Windows build of Mission Planner (folder with MissionPlanner.exe)
#   - a macOS Wine build tarball from https://github.com/Gcenx/macOS_Wine_builds
# Runs on macOS (CI) and on Linux (for a layout check; no icon or signature there).
set -euo pipefail

usage() {
    echo "Usage: $0 --mp DIR --wine WINE.tar.xz --version VERSION --out DIR [--icon PNG]" >&2
    exit 1
}

MP_SRC="" WINE_TAR="" VERSION="" OUT="" ICON=""
while [ $# -gt 0 ]; do
    case "$1" in
        --mp) MP_SRC="$2"; shift 2 ;;
        --wine) WINE_TAR="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --icon) ICON="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$MP_SRC" ] && [ -n "$WINE_TAR" ] && [ -n "$VERSION" ] && [ -n "$OUT" ] || usage
[ -f "$MP_SRC/MissionPlanner.exe" ] || { echo "No MissionPlanner.exe in $MP_SRC" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$OUT/Mission Planner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "== Info.plist"
sed "s/@VERSION@/$VERSION/g" "$HERE/Info.plist.in" > "$APP/Contents/Info.plist"

echo "== launcher"
cp "$HERE/launcher.sh" "$APP/Contents/Resources/launcher.sh"
chmod 755 "$APP/Contents/Resources/launcher.sh"
# The main executable is a small compiled program that runs launcher.sh, so that
# macOS treats Mission Planner (not /bin/bash) as the app for privacy prompts.
if [ "$(uname -s)" = Darwin ]; then
    clang -O2 -Wall -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
        -o "$APP/Contents/MacOS/MissionPlanner" "$HERE/stub.c"
else
    # Layout check on Linux: a script that does the same.
    # shellcheck disable=SC2016  # $0 and $@ belong to the generated script
    printf '#!/bin/sh\nexec /bin/bash "$(dirname "$(dirname "$0")")/Resources/launcher.sh" "$@"\n' > "$APP/Contents/MacOS/MissionPlanner"
    chmod 755 "$APP/Contents/MacOS/MissionPlanner"
fi
echo "$VERSION" > "$APP/Contents/Resources/bundle-version.txt"

echo "== Wine"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -xJf "$WINE_TAR" -C "$TMP" 2>/dev/null
WINE_APP="$(find "$TMP" -maxdepth 1 -name '*.app' | head -1)"
[ -d "$WINE_APP/Contents/Resources/wine/bin" ] || { echo "Unexpected Wine tarball layout" >&2; exit 1; }
mv "$WINE_APP/Contents/Resources/wine" "$APP/Contents/Resources/wine"
# Wine Mono and Gecko are not used: .NET Framework 4.8 is installed on first start.
rm -rf "$APP/Contents/Resources/wine/share/wine/mono" "$APP/Contents/Resources/wine/share/wine/gecko"
# Fix a wineserver crash on file systems with a negative device number (see
# patch-wineserver.py). Without it, Mission Planner can stop at every start.
python3 "$HERE/patch-wineserver.py" "$APP/Contents/Resources/wine/bin/wineserver"
if command -v codesign >/dev/null; then
    codesign --force --sign - "$APP/Contents/Resources/wine/bin/wineserver"
    codesign --verify "$APP/Contents/Resources/wine/bin/wineserver"
fi

echo "== Mission Planner"
mkdir -p "$APP/Contents/Resources/MissionPlanner"
cp -R "$MP_SRC/." "$APP/Contents/Resources/MissionPlanner/"
# Defaults that Mission Planner reads from its program folder (the user's own
# config.xml overrides them). They answer the two first-start questions so the
# first start does not stop at modal dialogs: Altitude Angel off, and the
# default tab list (the Drone ID plugin asks for a restart while it is unset).
cp "$HERE/custom.config.xml" "$APP/Contents/Resources/MissionPlanner/custom.config.xml"

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

if command -v osacompile >/dev/null; then
    echo "== setup progress window"
    osacompile -o "$APP/Contents/Resources/Setup Progress.app" "$HERE/progress.applescript"
    [ -f "$APP/Contents/Resources/AppIcon.icns" ] && \
        cp "$APP/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/Setup Progress.app/Contents/Resources/applet.icns"
    # The icon change breaks the applet's signature: sign it again.
    command -v codesign >/dev/null && codesign --force --sign - "$APP/Contents/Resources/Setup Progress.app"
fi

LOADER="$APP/Contents/Resources/wine/lib/wine/x86_64-unix/wine"
if command -v codesign >/dev/null && [ -f "$LOADER" ]; then
    # The Dock shows the name in the Wine loader's embedded Info.plist ("Wine").
    # Replace it with "Mission Planner" in place (same length), then re-sign the
    # loader. If anything goes wrong, keep the original loader.
    echo "== Dock name"
    cp "$LOADER" "$TMP/wine-loader.orig"
    if perl -0777 -i -pe 'BEGIN{$n="Mission Planner"} s{(<\?xml.*?</plist>)}{ my $o=$1; (my $p=$o)=~s/>\s+</></g; $p=~s{(<key>CFBundleName</key><string>)[^<]*(</string>)}{$1$n$2}; die "too long\n" if length($p)>length($o); $p.(" " x (length($o)-length($p))) }se' "$LOADER" \
        && codesign --force --sign - "$LOADER" && codesign --verify "$LOADER"; then
        echo "loader renamed"
    else
        echo "warning: could not rename the Wine loader, keeping the original" >&2
        cp "$TMP/wine-loader.orig" "$LOADER"
    fi
fi

if command -v codesign >/dev/null; then
    echo "== ad hoc signature"
    codesign --force --deep --sign - "$APP" || echo "warning: ad hoc signing failed" >&2
fi

echo "Built: $APP"
du -sh "$APP"
