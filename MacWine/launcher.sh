#!/bin/bash
# Mission Planner for macOS (Wine bundle) launcher.
# This file is the CFBundleExecutable of "Mission Planner.app". It runs the
# Windows build of Mission Planner with the Wine copy in Contents/Resources/wine.
# macOS ships bash 3.2, so this script avoids bash 4 features.

set -u

CONTENTS="$(cd "$(dirname "$0")/.." && pwd)"
RES="$CONTENTS/Resources"
WINE_ROOT="$RES/wine"
BUNDLE_VERSION="$(cat "$RES/bundle-version.txt" 2>/dev/null || echo unknown)"

# No spaces in these paths: some Wine tools and winetricks handle spaces badly.
SUPPORT="${MPWINE_HOME:-$HOME/Library/MissionPlannerWine}"
LOGDIR="$HOME/Library/Logs/MissionPlannerWine"
PORTDIR="$SUPPORT/ports"
STATE="$SUPPORT/state"

export WINEPREFIX="$SUPPORT/prefix"
export WINE="$WINE_ROOT/bin/wine"
export WINESERVER="$WINE_ROOT/bin/wineserver"
export PATH="$WINE_ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export WINEDEBUG="${WINEDEBUG:--all}"
export W_CACHE="$SUPPORT/cache"
export LANG="${LANG:-en_US.UTF-8}"

# COM port slots. Each slot is a symlink in $PORTDIR that the port watcher
# points at the matching /dev/cu.* device. Wine itself does not detect serial
# ports on macOS, so the slots are registered in HKLM\Software\Wine\Ports.
PORT_SLOTS="3 4 5 6"

MP_DIR="$WINEPREFIX/drive_c/Program Files/Mission Planner"

mkdir -p "$SUPPORT" "$LOGDIR" "$PORTDIR" "$STATE" "$W_CACHE"
LOG="$LOGDIR/launcher.log"
WINELOG="$LOGDIR/wine.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# MPWINE_NONINTERACTIVE=1 (CI smoke test): no dialogs, every question answers yes.
NONINTERACTIVE="${MPWINE_NONINTERACTIVE:-0}"

dialog() {
    # dialog "message" -> shows an OK dialog
    [ "$NONINTERACTIVE" = 1 ] && { log "dialog: $1"; return 0; }
    /usr/bin/osascript -e "display dialog \"$1\" with title \"Mission Planner\" buttons {\"OK\"} default button \"OK\" with icon caution" >/dev/null 2>&1
}

ask() {
    # ask "message" "button" -> returns 0 if the button is clicked
    [ "$NONINTERACTIVE" = 1 ] && { log "ask: $1 -> $2"; return 0; }
    /usr/bin/osascript -e "button returned of (display dialog \"$1\" with title \"Mission Planner\" buttons {\"Quit\", \"$2\"} default button \"$2\")" 2>/dev/null | grep -q "$2"
}

notify() {
    log "notice: $1"
    [ "$NONINTERACTIVE" = 1 ] && return 0
    /usr/bin/osascript -e "display notification \"$1\" with title \"Mission Planner\"" >/dev/null 2>&1
}

fail() {
    log "ERROR: $1"
    dialog "$1\n\nLog files: $LOGDIR"
    exit 1
}

# Old macOS versions pass a -psn_ process serial number argument. Drop it.
if [ "${1:-}" != "${1#-psn_}" ]; then shift; fi

log "=== start, bundle $BUNDLE_VERSION, macOS $(sw_vers -productVersion 2>/dev/null), $(uname -m)"

# Wine in this bundle is x86_64. Apple Silicon Macs run it with Rosetta 2.
if [ "$(uname -m)" = "arm64" ] && ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
    if ask "Mission Planner needs Rosetta 2 (Apple's Intel translator). Install it now? macOS asks for your password." "Install"; then
        /usr/bin/osascript -e 'do shell script "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" with administrator privileges' >> "$LOG" 2>&1
        /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null || fail "Rosetta 2 did not install."
    else
        exit 0
    fi
fi

[ -x "$WINE" ] || fail "Wine is missing from the app bundle."

# ---------------------------------------------------------------- port watcher

is_wanted_port() {
    case "$1" in
        /dev/cu.Bluetooth-Incoming-Port|/dev/cu.debug-console|/dev/cu.wlan-debug) return 1 ;;
        /dev/cu.*) return 0 ;;
    esac
    return 1
}

update_ports() {
    # Remove slots whose device is gone.
    for n in $PORT_SLOTS; do
        link="$PORTDIR/com$n"
        if [ -L "$link" ] && [ ! -e "$link" ]; then
            log "port COM$n: $(readlink "$link") removed"
            rm -f "$link"
        fi
    done
    # Give each new device the lowest free slot.
    for dev in /dev/cu.*; do
        [ -e "$dev" ] || continue
        is_wanted_port "$dev" || continue
        taken=""
        for n in $PORT_SLOTS; do
            if [ "$(readlink "$PORTDIR/com$n" 2>/dev/null)" = "$dev" ]; then taken=1; break; fi
        done
        [ -n "$taken" ] && continue
        for n in $PORT_SLOTS; do
            if [ ! -L "$PORTDIR/com$n" ]; then
                ln -s "$dev" "$PORTDIR/com$n"
                log "port COM$n: $dev"
                break
            fi
        done
    done
}

port_watcher() {
    while :; do
        update_ports
        sleep 1
    done
}

# ---------------------------------------------------------------- first run

register_ports() {
    for n in $PORT_SLOTS; do
        "$WINE" reg add 'HKLM\Software\Wine\Ports' /v "COM$n" /t REG_SZ /d "$PORTDIR/com$n" /f >> "$WINELOG" 2>&1 \
            || fail "Could not register COM$n."
    done
}

setup_prefix() {
    log "creating Wine prefix in $WINEPREFIX"
    # Do not install Wine Mono or Gecko. .NET Framework 4.8 replaces Mono.
    WINEDLLOVERRIDES="mscoree=;mshtml=" "$WINE" wineboot --init >> "$WINELOG" 2>&1 || fail "wineboot failed."
    "$WINESERVER" -w

    log "installing .NET Framework 4.8 (winetricks dotnet48)"
    sh "$RES/winetricks" -q dotnet48 >> "$WINELOG" 2>&1 || fail ".NET Framework 4.8 did not install."
    sh "$RES/winetricks" -q win10 >> "$WINELOG" 2>&1 || log "warning: winetricks win10 failed"

    register_ports
    "$WINESERVER" -w
    echo "$BUNDLE_VERSION" > "$STATE/prefix-ok"
    log "prefix ready"
}

if [ ! -f "$STATE/prefix-ok" ]; then
    ask "First start: Mission Planner installs Microsoft .NET Framework 4.8 into its own Wine folder. This downloads about 120 MB from Microsoft and takes 5 to 20 minutes. You get a notice when it is done." "Continue" || exit 0
    notify "Setting up. This takes 5 to 20 minutes."
    rm -rf "$WINEPREFIX"
    setup_prefix
    notify "Setup is done. Mission Planner starts now."
fi

# Copy Mission Planner into the prefix when the bundle is new or updated.
if [ "$(cat "$STATE/mp-version" 2>/dev/null)" != "$BUNDLE_VERSION" ]; then
    log "copying Mission Planner files into the prefix"
    mkdir -p "$MP_DIR"
    /usr/bin/ditto "$RES/MissionPlanner" "$MP_DIR" || fail "Could not copy Mission Planner files."
    echo "$BUNDLE_VERSION" > "$STATE/mp-version"
fi

# ---------------------------------------------------------------- run

update_ports
port_watcher &
WATCHER_PID=$!
trap 'kill $WATCHER_PID 2>/dev/null' EXIT

log "starting MissionPlanner.exe"
cd "$MP_DIR" || fail "Mission Planner folder is missing."
"$WINE" "$MP_DIR/MissionPlanner.exe" "$@" >> "$WINELOG" 2>&1
STATUS=$?
log "MissionPlanner.exe exited with $STATUS"
"$WINESERVER" -k 2>/dev/null
exit $STATUS
