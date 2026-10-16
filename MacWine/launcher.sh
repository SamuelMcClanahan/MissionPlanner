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
    # Close the setup progress window if it is still open.
    [ -f "$STATE/progress" ] && echo "done" > "$STATE/progress"
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

winedbg_watchdog() {
    # WineHQ bug 57998: on macOS a sub-installer of .NET 4.0 can crash, and Wine's
    # crash handler (winedbg --auto) then waits forever. winedbg is disabled in
    # settings.reg; this kills a winedbg that is still there after 30 s anyway.
    seen=""
    while kill -0 $$ 2>/dev/null; do
        sleep 15
        dbg="$(pgrep -f 'winedbg' | tr '\n' ' ')"
        if [ -n "$dbg" ] && [ "$dbg" = "$seen" ]; then
            log "watchdog: winedbg did not exit, killing it ($dbg)"
            pkill -f winedbg
            dbg=""
        fi
        seen="$dbg"
    done
}

apply_settings() {
    # All Wine settings in one registry import.
    reg="$SUPPORT/settings.reg"
    {
        echo 'REGEDIT4'
        echo
        echo '[HKEY_CURRENT_USER\Software\Wine\DllOverrides]'
        echo '"mshtml"=""'                # no Gecko download dialog
        echo '"winedbg.exe"=""'           # a crash ends the program (bug 57998)
        echo '"winemenubuilder.exe"=""'   # no menu or file association entries
        echo
        echo '[HKEY_CURRENT_USER\Software\Wine\WineDbg]'
        echo '"ShowCrashDialog"=dword:00000000'
        echo
        echo '[HKEY_CURRENT_USER\Software\Wine\Mac Driver]'
        echo '"LeftCommandIsCtrl"="y"'    # Cmd+C, Cmd+V, Cmd+A work like Ctrl
        echo '"RightCommandIsCtrl"="y"'
        echo '"LeftOptionIsAlt"="y"'      # right Option still types accents
        echo '"UsePreciseScrolling"="n"'  # trackpad map zoom in normal steps
        echo
        # .NET background compiler services: they start compiling in the
        # middle of a session. Mission Planner is compiled once at setup (ngen).
        echo '[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\clr_optimization_v4.0.30319_32]'
        echo '"Start"=dword:00000004'
        echo '[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\clr_optimization_v4.0.30319_64]'
        echo '"Start"=dword:00000004'
        echo
        echo '[HKEY_LOCAL_MACHINE\Software\Wine\Ports]'
        for n in $PORT_SLOTS; do
            echo "\"COM$n\"=\"$PORTDIR/com$n\""
        done
    } > "$reg"
    "$WINE" regedit /S "Z:$reg" >> "$WINELOG" 2>&1 || fail "Could not write the Wine settings."
    "$WINESERVER" -w
}

# ---------------------------------------------------------------- progress window

PROGRESS_FILE="$STATE/progress"
PROGRESS_APP="$RES/Setup Progress.app"

progress_start() {
    # $1 = title text for the fallback dialog
    echo "0|Starting" > "$PROGRESS_FILE"
    [ "$NONINTERACTIVE" = 1 ] && return 0
    if [ -d "$PROGRESS_APP" ] && /usr/bin/open "$PROGRESS_APP" 2>/dev/null; then
        return 0
    fi
    show "$(printf '%s\n\nYou can close this message. Mission Planner opens when it is done.\n\nLog files: %s' "$1" "$LOGDIR")" 3600
}

progress() {
    # progress PERCENT TEXT
    log "progress $1%: $2"
    echo "$1|$2" > "$PROGRESS_FILE"
}

progress_end() {
    echo "done" > "$PROGRESS_FILE"
    hide
}

# ---------------------------------------------------------------- setup

install_dotnet() {
    winedbg_watchdog &
    watchdog_pid=$!
    run_winetricks dotnet48
    rc=$?
    kill "$watchdog_pid" 2>/dev/null
    return $rc
}

setup_prefix() {
    log "creating Wine prefix in $WINEPREFIX"
    progress 2 "Creating the Wine folder"
    # Do not install Wine Mono or Gecko. .NET Framework 4.8 replaces Mono.
    WINEDLLOVERRIDES="mscoree=;mshtml=" "$WINE" wineboot --init >> "$WINELOG" 2>&1 || fail "wineboot failed."
    "$WINESERVER" -w
    apply_settings

    progress 8 "Downloading and installing Microsoft .NET Framework 4.8 (the longest step)"
    log "installing .NET Framework 4.8"
    install_dotnet || fail ".NET Framework 4.8 did not install."
    run_winetricks win10 || log "warning: winetricks win10 failed"
    apply_settings
    echo "$BUNDLE_VERSION" > "$STATE/prefix-ok"
    log "prefix ready"
}

install_mp() {
    # Copy Mission Planner into the prefix. A fresh copy (not a merge), so files
    # removed in a newer version do not stay behind.
    progress 75 "Copying Mission Planner"
    log "copying Mission Planner files into the prefix"
    rm -rf "$MP_DIR.new"
    /usr/bin/ditto "$RES/MissionPlanner" "$MP_DIR.new" || fail "Could not copy Mission Planner files."
    rm -rf "$MP_DIR"
    mv "$MP_DIR.new" "$MP_DIR" || fail "Could not install Mission Planner files."

    # Compile Mission Planner and the .NET libraries it uses to native code once
    # (NGen). Without this the JIT compiles them at every start, under Rosetta.
    progress 80 "Optimizing Mission Planner for faster starts"
    log "ngen install MissionPlanner.exe"
    "$WINE" 'C:\windows\Microsoft.NET\Framework64\v4.0.30319\ngen.exe' install \
        'C:\Program Files\Mission Planner\MissionPlanner.exe' /nologo >> "$WINELOG" 2>&1 \
        || log "warning: ngen returned $? (Mission Planner still works, it starts slower)"
    "$WINESERVER" -w
    apply_settings
    echo "$BUNDLE_VERSION" > "$STATE/mp-version"
    progress 100 "Done"
}

NEED_SETUP=0
if [ ! -f "$STATE/prefix-ok" ] || [ ! -f "$WINEPREFIX/system.reg" ]; then NEED_SETUP=1; fi
NEED_MP=0
if [ "$(cat "$STATE/mp-version" 2>/dev/null)" != "$BUNDLE_VERSION" ] || [ ! -f "$MP_DIR/MissionPlanner.exe" ]; then NEED_MP=1; fi

if [ "$NEED_SETUP" = 1 ]; then
    ask "First start: Mission Planner installs Microsoft .NET Framework 4.8 into its own Wine folder. This downloads about 165 MB from Microsoft and takes 10 to 30 minutes." "Continue" || exit 0
    [ -d "$WINEPREFIX" ] && "$WINESERVER" -k 2>/dev/null
    rm -rf "$WINEPREFIX" "$STATE/prefix-ok" "$STATE/mp-version"
    progress_start "Setting up Mission Planner. This takes 10 to 30 minutes."
    setup_prefix
    install_mp
    progress_end
    show "Setup is done. Mission Planner starts now." 10
elif [ "$NEED_MP" = 1 ]; then
    progress_start "Updating Mission Planner. This takes a few minutes."
    install_mp
    progress_end
fi

# ---------------------------------------------------------------- run

update_ports
port_watcher &
WATCHER_PID=$!

# Mission Planner asks Windows not to sleep while it runs. Wine on macOS does not
# pass that on, so keep the Mac awake (no idle sleep in flight) until we exit.
[ -x /usr/bin/caffeinate ] && /usr/bin/caffeinate -i -w $$ &

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
