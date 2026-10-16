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
MP_LOG="$WINEPREFIX/drive_c/ProgramData/Mission Planner/MissionPlanner.log"

mkdir -p "$SUPPORT" "$LOGDIR" "$PORTDIR" "$STATE" "$W_CACHE"
LOG="$LOGDIR/launcher.log"
WINELOG="$LOGDIR/wine.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# MPWINE_NONINTERACTIVE=1 (CI smoke test): no dialogs, every question answers yes.
NONINTERACTIVE="${MPWINE_NONINTERACTIVE:-0}"

# The message text is passed as an argument, not pasted into the AppleScript
# source, so quotes and backslashes in it cannot break the script.
dialog() {
    # dialog TEXT -> modal OK dialog
    log "dialog: $1"
    [ "$NONINTERACTIVE" = 1 ] && return 0
    /usr/bin/osascript -e 'on run argv' -e 'activate' \
        -e 'display dialog (item 1 of argv) with title "Mission Planner" buttons {"OK"} default button "OK" with icon caution' \
        -e 'end run' "$1" >/dev/null 2>&1
}

ask() {
    # ask TEXT BUTTON -> returns 0 if BUTTON is clicked
    log "ask: $1"
    [ "$NONINTERACTIVE" = 1 ] && return 0
    [ "$(/usr/bin/osascript -e 'on run argv' -e 'activate' \
        -e 'button returned of (display dialog (item 1 of argv) with title "Mission Planner" buttons {"Quit", item 2 of argv} default button (item 2 of argv))' \
        -e 'end run' "$1" "$2" 2>/dev/null)" = "$2" ]
}

SHOW_PID=""
show() {
    # show TEXT SECONDS -> non-blocking dialog that closes itself.
    # (Notifications from osascript are often not shown, so a dialog is used.)
    log "show: $1"
    hide
    [ "$NONINTERACTIVE" = 1 ] && return 0
    /usr/bin/osascript -e 'on run argv' -e 'activate' \
        -e 'display dialog (item 1 of argv) with title "Mission Planner" buttons {"OK"} default button "OK" giving up after ((item 2 of argv) as integer)' \
        -e 'end run' "$1" "$2" >/dev/null 2>&1 &
    SHOW_PID=$!
}

hide() {
    if [ -n "$SHOW_PID" ]; then kill "$SHOW_PID" 2>/dev/null; SHOW_PID=""; fi
}

fail() {
    log "ERROR: $1"
    hide
    dialog "$(printf '%s\n\nLog files: %s' "$1" "$LOGDIR")"
    exit 1
}

# Old macOS versions pass a -psn_ process serial number argument. Drop it.
case "${1:-}" in -psn_*) shift ;; esac

log "=== start, bundle $BUNDLE_VERSION, macOS $(sw_vers -productVersion 2>/dev/null), $(uname -m)"

# ---------------------------------------------------------------- single instance

LOCK="$STATE/lock"
WATCHER_PID=""
cleanup() {
    [ -n "$WATCHER_PID" ] && kill "$WATCHER_PID" 2>/dev/null
    hide
    rm -rf "$LOCK"
}
if ! mkdir "$LOCK" 2>/dev/null; then
    other="$(cat "$LOCK/pid" 2>/dev/null)"
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
        dialog "Mission Planner is already running or is still setting up."
        exit 0
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK" || exit 1
fi
echo $$ > "$LOCK/pid"
trap cleanup EXIT

# ---------------------------------------------------------------- checks

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

# A downloaded app keeps the com.apple.quarantine attribute on every file.
# Wine's own binaries and libraries are then blocked one by one, so remove it.
if /usr/bin/xattr -p com.apple.quarantine "$WINE" >/dev/null 2>&1; then
    log "removing quarantine attribute from the app bundle"
    /usr/bin/xattr -dr com.apple.quarantine "$CONTENTS/.." 2>/dev/null \
        || fail "macOS quarantine is still set. Move Mission Planner to Applications and run the xattr command in READ ME FIRST."
fi

# ---------------------------------------------------------------- port watcher

is_wanted_port() {
    case "$1" in
        /dev/cu.usbmodem*|/dev/cu.usbserial*|/dev/cu.SLAB_USBtoUART*|/dev/cu.wchusbserial*) return 0 ;;
    esac
    return 1
}

update_ports() {
    # Remove slots whose device is gone.
    for n in $PORT_SLOTS; do
        link="$PORTDIR/com$n"
        if [ -L "$link" ] && [ ! -e "$link" ]; then
            log "port COM$n removed"
            rm -f "$link"
        fi
    done
    # Give each new device the lowest free slot.
    for dev in /dev/cu.*; do
        is_wanted_port "$dev" || continue
        [ -e "$dev" ] || continue
        taken=""
        for n in $PORT_SLOTS; do
            if [ "$PORTDIR/com$n" -ef "$dev" ]; then taken=1; break; fi
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
    # Stops by itself when the launcher is gone, also after Force Quit (SIGKILL).
    while kill -0 $$ 2>/dev/null; do
        update_ports
        sleep 1
    done
}

# ---------------------------------------------------------------- first run

# winetricks runs `lipo -archs` on wine. /usr/bin/lipo is an Xcode stub that opens
# an "install developer tools" dialog on Macs without the Command Line Tools.
# This Wine is x86_64 only, so a shim gives the answer.
SHIM="$SUPPORT/shim"
mkdir -p "$SHIM"
printf '#!/bin/sh\necho x86_64\n' > "$SHIM/lipo"
chmod 755 "$SHIM/lipo"

run_winetricks() {
    PATH="$SHIM:$PATH" WINE64="$WINE" WINETRICKS_LATEST_VERSION_CHECK=disabled \
        sh "$RES/winetricks" -q "$@" >> "$WINELOG" 2>&1
}

register_ports() {
    for n in $PORT_SLOTS; do
        "$WINE" reg add 'HKLM\Software\Wine\Ports' /v "COM$n" /t REG_SZ /d "$PORTDIR/com$n" /f >> "$WINELOG" 2>&1 \
            || fail "Could not register COM$n."
    done
}

seed_mp_config() {
    # Answer Mission Planner's two first-start questions in advance, so the
    # first start does not stop at modal dialogs:
    #  - Altitude Angel plugin: off (it can be enabled later in Mission Planner)
    #  - Drone ID plugin: the default tab list (else it asks for a restart)
    docs_win="$("$WINE" cmd /c 'echo %USERPROFILE%\Documents' 2>/dev/null | tr -d '\r')"
    docs="$("$WINE" winepath -u "$docs_win" 2>/dev/null | tr -d '\r')"
    [ -n "$docs" ] || { log "warning: could not find the Documents folder"; return 0; }
    cfg="$docs/Mission Planner/config.xml"
    [ -f "$cfg" ] && return 0
    mkdir -p "$docs/Mission Planner"
    cat > "$cfg" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<Config>
  <AA_CheckEnableAltitudeAngel>False</AA_CheckEnableAltitudeAngel>
  <tabcontrolactions>tabQuick;tabActions;tabPagemessages;tabActionsSimple;tabPagePreFlight;tabGauges;tabTransponder;tabStatus;tabServo;tabAuxFunction;tabScripts;tabPayload;tabTLogs;tablogbrowse;</tabcontrolactions>
</Config>
EOF
    log "wrote default Mission Planner settings to $cfg"
}

setup_prefix() {
    log "creating Wine prefix in $WINEPREFIX"
    # Do not install Wine Mono or Gecko. .NET Framework 4.8 replaces Mono.
    WINEDLLOVERRIDES="mscoree=;mshtml=" "$WINE" wineboot --init >> "$WINELOG" 2>&1 || fail "wineboot failed."
    "$WINESERVER" -w
    # Keep Gecko off permanently, also when a newer Wine updates the prefix.
    "$WINE" reg add 'HKCU\Software\Wine\DllOverrides' /v mshtml /t REG_SZ /d '' /f >> "$WINELOG" 2>&1

    log "installing .NET Framework 4.8 (winetricks dotnet48)"
    run_winetricks dotnet48 || fail ".NET Framework 4.8 did not install."
    run_winetricks win10 || log "warning: winetricks win10 failed"

    register_ports
    seed_mp_config
    "$WINESERVER" -w
    echo "$BUNDLE_VERSION" > "$STATE/prefix-ok"
    log "prefix ready"
}

if [ ! -f "$STATE/prefix-ok" ] || [ ! -f "$WINEPREFIX/system.reg" ]; then
    ask "First start: Mission Planner installs Microsoft .NET Framework 4.8 into its own Wine folder. This downloads about 165 MB from Microsoft and takes 5 to 20 minutes." "Continue" || exit 0
    [ -d "$WINEPREFIX" ] && "$WINESERVER" -k 2>/dev/null
    rm -rf "$WINEPREFIX" "$STATE/prefix-ok" "$STATE/mp-version"
    show "$(printf 'Setting up Mission Planner. This takes 5 to 20 minutes.\n\nYou can close this message. Mission Planner opens when setup is done.\n\nLog files: %s' "$LOGDIR")" 3600
    setup_prefix
    show "Setup is done. Mission Planner starts now." 10
fi

# Copy Mission Planner into the prefix when the bundle is new or updated.
# A fresh copy (not a merge) so files removed in a newer version do not stay.
if [ "$(cat "$STATE/mp-version" 2>/dev/null)" != "$BUNDLE_VERSION" ] || [ ! -f "$MP_DIR/MissionPlanner.exe" ]; then
    log "copying Mission Planner files into the prefix"
    rm -rf "$MP_DIR.new"
    /usr/bin/ditto "$RES/MissionPlanner" "$MP_DIR.new" || fail "Could not copy Mission Planner files."
    rm -rf "$MP_DIR"
    mv "$MP_DIR.new" "$MP_DIR" || fail "Could not install Mission Planner files."
    echo "$BUNDLE_VERSION" > "$STATE/mp-version"
fi

# ---------------------------------------------------------------- run

update_ports
port_watcher &
WATCHER_PID=$!

[ -f "$WINELOG" ] && mv -f "$WINELOG" "$WINELOG.1"
log "starting MissionPlanner.exe"
cd "$MP_DIR" || fail "Mission Planner folder is missing."
STARTED=$(date +%s)
LOADS_BEFORE=$(grep -c "appload time" "$MP_LOG" 2>/dev/null); LOADS_BEFORE=${LOADS_BEFORE:-0}
"$WINE" "$MP_DIR/MissionPlanner.exe" "$@" >> "$WINELOG" 2>&1
STATUS=$?
log "MissionPlanner.exe exited with $STATUS after $(( $(date +%s) - STARTED )) s"
# A start that ends with an error before the main window loads is a crash. Tell the user.
LOADS_AFTER=$(grep -c "appload time" "$MP_LOG" 2>/dev/null); LOADS_AFTER=${LOADS_AFTER:-0}
if [ "$STATUS" -ne 0 ] && [ "$LOADS_AFTER" -le "$LOADS_BEFORE" ]; then
    "$WINESERVER" -k 2>/dev/null
    fail "Mission Planner stopped while it was starting (exit code $STATUS)."
fi
# Wait for other Windows processes (for example Mission Planner's updater).
"$WINESERVER" -w
hide
exit $STATUS
