#!/bin/bash
# Mission Planner for macOS (Wine bundle) launcher.
# Contents/MacOS/MissionPlanner (stub.c) runs this file from Contents/Resources. It runs the
# Windows build of Mission Planner with the Wine copy in Contents/Resources/wine.
# macOS ships bash 3.2, so this script avoids bash 4 features.

set -u

CONTENTS="$(cd "$(dirname "$0")/.." && pwd)"
RES="$CONTENTS/Resources"
WINE_ROOT="$RES/wine"
BUNDLE_VERSION="$(cat "$RES/bundle-version.txt" 2>/dev/null || echo unknown)"

# No spaces in these paths: some Wine tools handle spaces badly.
SUPPORT="${MPWINE_HOME:-$HOME/Library/MissionPlannerWine}"
LOGDIR="$HOME/Library/Logs/MissionPlannerWine"
PORTDIR="$SUPPORT/ports"
STATE="$SUPPORT/state"

export WINEPREFIX="$SUPPORT/prefix"
export WINE="$WINE_ROOT/bin/wine"
export WINESERVER="$WINE_ROOT/bin/wineserver"
export PATH="$WINE_ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export WINEDEBUG="${WINEDEBUG:--all}"
CACHE="$SUPPORT/cache"
export LANG="${LANG:-en_US.UTF-8}"

# COM port slots. Each slot is a symlink in $PORTDIR that the port watcher
# points at the matching /dev/cu.* device. Wine itself does not detect serial
# ports on macOS, so the slots are registered in HKLM\Software\Wine\Ports.
PORT_SLOTS="3 4 5 6"

MP_DIR="$WINEPREFIX/drive_c/Program Files/Mission Planner"
MP_LOG="$WINEPREFIX/drive_c/ProgramData/Mission Planner/MissionPlanner.log"

mkdir -p "$SUPPORT" "$LOGDIR" "$PORTDIR" "$STATE" "$CACHE"
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
    # Only kill the PID if it is still our own child (PIDs are reused).
    if [ -n "$SHOW_PID" ] && [ "$(ps -o ppid= -p "$SHOW_PID" 2>/dev/null | tr -d ' ')" = "$$" ]; then
        kill "$SHOW_PID" 2>/dev/null
    fi
    SHOW_PID=""
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
    [ -n "${CANCEL_WATCH_PID:-}" ] && kill "$CANCEL_WATCH_PID" 2>/dev/null
    hide
    # Close the setup progress window if it is still open.
    [ -f "$STATE/progress" ] && echo "done" > "$STATE/progress"
    rm -rf "$LOCK"
}
if ! mkdir "$LOCK" 2>/dev/null; then
    other="$(cat "$LOCK/pid" 2>/dev/null)"
    # The PID must still be a launcher (after a crash or reboot it can be reused).
    if [ -n "$other" ] && ps -p "$other" -o command= 2>/dev/null | grep -q 'Resources/launcher.sh'; then
        dialog "Mission Planner is already running or is still setting up."
        exit 0
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK" || exit 1
fi
echo $$ > "$LOCK/pid"
trap cleanup EXIT

# Keep the Mac awake (no idle sleep) during setup and while Mission Planner runs:
# Mission Planner asks Windows not to sleep, but Wine on macOS does not pass that on.
[ -x /usr/bin/caffeinate ] && /usr/bin/caffeinate -i -w $$ &

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

wine_wait() {
    # Waits until all Windows processes of the prefix end, at most $1 seconds,
    # then stops the rest. On macOS a conhost.exe or a service can stay after the
    # .NET installer ends, and "wineserver -w" alone then waits forever.
    # wineserver -k saves the registry before it exits.
    "$WINESERVER" -w &
    ww_pid=$!
    ww_n=0
    while kill -0 "$ww_pid" 2>/dev/null; do
        if [ "$ww_n" -ge "$1" ]; then
            # shellcheck disable=SC2009  # ps prints the full command lines on macOS and Linux
            log "Windows processes still running after $1 s, stopping them: $(ps ax -o pid= -o command= | grep -i '\.exe' | grep -v grep | tr -s ' \n' ' ' | cut -c1-400)"
            "$WINESERVER" -k 2>/dev/null
            ww_n=0
            while kill -0 "$ww_pid" 2>/dev/null && [ "$ww_n" -lt 20 ]; do sleep 1; ww_n=$((ww_n + 1)); done
            kill "$ww_pid" 2>/dev/null
            break
        fi
        sleep 1
        ww_n=$((ww_n + 1))
    done
    wait "$ww_pid" 2>/dev/null
    return 0
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

ngen32_guard() {
    # On macOS the 32-bit .NET NGen worker (run by the .NET installers to
    # precompile the framework) runs for more than 30 minutes under Rosetta.
    # Mission Planner runs as a 64-bit process and does not use 32-bit native
    # images, so stop 32-bit ngen/mscorsvw while .NET installs.
    while kill -0 $$ 2>/dev/null; do
        sleep 5
        if pgrep -f 'Microsoft\.NET\\Framework\\v4\.0\.30319\\(ngen|mscorsvw)\.exe' >/dev/null; then
            log "ngen32 guard: stopping 32-bit ngen/mscorsvw"
            pkill -f 'Microsoft\.NET\\Framework\\v4\.0\.30319\\(ngen|mscorsvw)\.exe'
        fi
    done
}

apply_settings() {
    # All Wine settings in one registry import.
    reg="$SUPPORT/settings.reg"
    {
        printf '%s\n' 'REGEDIT4'
        printf '\n'
        printf '%s\n' '[HKEY_CURRENT_USER\Software\Wine\DllOverrides]'
        printf '%s\n' '"mshtml"=""'                # no Gecko download dialog
        printf '%s\n' '"winedbg.exe"=""'           # a crash ends the program (bug 57998)
        printf '%s\n' '"winemenubuilder.exe"=""'   # no menu or file association entries
        printf '\n'
        printf '%s\n' '[HKEY_CURRENT_USER\Software\Wine\WineDbg]'
        printf '%s\n' '"ShowCrashDialog"=dword:00000000'
        printf '\n'
        printf '%s\n' '[HKEY_CURRENT_USER\Software\Wine\Mac Driver]'
        printf '%s\n' '"LeftCommandIsCtrl"="y"'    # Cmd+C, Cmd+V, Cmd+A work like Ctrl
        printf '%s\n' '"RightCommandIsCtrl"="y"'
        printf '%s\n' '"LeftOptionIsAlt"="y"'      # right Option still types accents
        printf '%s\n' '"UsePreciseScrolling"="n"'  # trackpad map zoom in normal steps
        printf '\n'
        # .NET background compiler services: they start compiling in the
        # middle of a session. Mission Planner is compiled once at setup (ngen).
        printf '%s\n' '[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\clr_optimization_v4.0.30319_32]'
        printf '%s\n' '"Start"=dword:00000004'
        printf '%s\n' '[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\clr_optimization_v4.0.30319_64]'
        printf '%s\n' '"Start"=dword:00000004'
        printf '\n'
        # Without this, the first start after a Wine update can show two .NET
        # error dialogs (Wine re-registers its own mscoree during the update).
        printf '%s\n' '[HKEY_LOCAL_MACHINE\Software\Microsoft\.NETFramework]'
        printf '%s\n' '"OnlyUseLatestCLR"=dword:00000001'
        printf '%s\n' '[HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\.NETFramework]'
        printf '%s\n' '"OnlyUseLatestCLR"=dword:00000001'
        printf '\n'
        printf '%s\n' '[HKEY_LOCAL_MACHINE\Software\Wine\Ports]'
        for n in $PORT_SLOTS; do
            printf '"COM%s"="%s"\n' "$n" "$PORTDIR/com$n"
        done
    } > "$reg"
    "$WINE" regedit /S "Z:$reg" >> "$WINELOG" 2>&1
    # regedit always exits with 0: check that a value arrived.
    "$WINE" reg query 'HKLM\Software\Wine\Ports' /v COM3 >> "$WINELOG" 2>&1 || fail "Could not write the Wine settings."
    wine_wait 60
}

# ---------------------------------------------------------------- progress window

PROGRESS_FILE="$STATE/progress"
PROGRESS_APP="$RES/Setup Progress.app"

CANCEL_WATCH_PID=""
cancel_watch() {
    # The progress window writes "cancel" when the user clicks Stop: end setup.
    while kill -0 $$ 2>/dev/null; do
        sleep 2
        if [ "$(cat "$PROGRESS_FILE" 2>/dev/null)" = "cancel" ]; then
            log "setup cancelled by the user"
            "$WINESERVER" -k 2>/dev/null
            kill -TERM $$ 2>/dev/null
            return 0
        fi
    done
}

progress_start() {
    # $1 = title text for the fallback dialog
    echo "0|Starting" > "$PROGRESS_FILE"
    [ "$NONINTERACTIVE" = 1 ] && return 0
    cancel_watch &
    CANCEL_WATCH_PID=$!
    if [ -d "$PROGRESS_APP" ] && /usr/bin/open "$PROGRESS_APP" 2>/dev/null; then
        return 0
    fi
    show "$(printf '%s\n\nYou can close this message. Mission Planner opens when it is done.\n\nLog files: %s' "$1" "$LOGDIR")" 3600
}

progress() {
    # progress PERCENT TEXT
    log "progress $1%: $2"
    [ "$(cat "$PROGRESS_FILE" 2>/dev/null)" = "cancel" ] && return 0
    echo "$1|$2" > "$PROGRESS_FILE"
}

progress_end() {
    [ -n "$CANCEL_WATCH_PID" ] && kill "$CANCEL_WATCH_PID" 2>/dev/null
    CANCEL_WATCH_PID=""
    echo "done" > "$PROGRESS_FILE"
    hide
}

# ---------------------------------------------------------------- setup

DOTNET40_URL="https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe"
DOTNET40_SHA256="65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f"
DOTNET48_URL="https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe"
DOTNET48_SHA256="95889d6de3f2070c07790ad6cf2000d33d9a1bdfc6a381725ab82ab1c314fd53"

download() {
    # download URL SHA256 FILE -> keeps a verified copy in the cache
    if [ -f "$3" ] && echo "$2  $3" | /usr/bin/shasum -a 256 -c - >/dev/null 2>&1; then return 0; fi
    mkdir -p "$(dirname "$3")"
    /usr/bin/curl -fL --connect-timeout 30 --speed-limit 2000 --speed-time 60 \
        --retry 5 --retry-delay 5 -o "$3.part" "$1" >> "$WINELOG" 2>&1 || return 1
    echo "$2  $3.part" | /usr/bin/shasum -a 256 -c - >> "$WINELOG" 2>&1 || { rm -f "$3.part"; return 1; }
    mv -f "$3.part" "$3"
}

install_dotnet() {
    # Installs .NET Framework 4.8 without running the .NET 4.0 installer.
    # winetricks dotnet48 runs the 4.0 installer first, and on macOS that hangs
    # (WineHQ bug 57998). The 4.0 step is only needed for mscoree.dll and
    # mscorees.dll (the .NET 4.8 installer does not install them), so they are
    # taken from the 4.0 package directly. This is also about 2.5x faster.
    f40="$CACHE/dotnet40/dotNetFx40_Full_x86_x64.exe"
    f48="$CACHE/dotnet48/ndp48-x86-x64-allos-enu.exe"
    download "$DOTNET40_URL" "$DOTNET40_SHA256" "$f40" || return 1
    download "$DOTNET48_URL" "$DOTNET48_SHA256" "$f48" || return 1
    progress 25 "Installing Microsoft .NET Framework 4.8 (the longest step)"

    win="$WINEPREFIX/drive_c/windows"
    tmp="$WINEPREFIX/drive_c/mpwine-dn40"
    rm -rf "$tmp"
    mkdir -p "$tmp/core"
    # Extract the 4.0 package (no install), then its core cabinet.
    (cd "$(dirname "$f40")" && "$WINE" "$(basename "$f40")" '/x:C:\mpwine-dn40' /q) >> "$WINELOG" 2>&1
    "$WINE" extrac32 /Y /E /L 'C:\mpwine-dn40\core' 'C:\mpwine-dn40\netfx_Core.mzz' >> "$WINELOG" 2>&1
    for f in _003_mscoree_dll_amd64 _003_mscoree_dll_x86 _017_mscorees_dll_amd64 _017_mscorees_dll_x86; do
        [ -f "$tmp/core/$f" ] || { log "missing $f in the .NET 4.0 package"; return 1; }
    done
    cp "$tmp/core/_003_mscoree_dll_amd64" "$win/system32/mscoree.dll"
    cp "$tmp/core/_003_mscoree_dll_x86" "$win/syswow64/mscoree.dll"
    cp "$tmp/core/_017_mscorees_dll_amd64" "$win/system32/mscorees.dll"
    cp "$tmp/core/_017_mscorees_dll_x86" "$win/syswow64/mscorees.dll"
    rm -rf "$tmp"
    {
        printf '%s\n' 'REGEDIT4'
        printf '\n'
        printf '%s\n' '[HKEY_LOCAL_MACHINE\Software\Microsoft\.NETFramework]'
        printf '%s\n' '"InstallRoot"="C:\\windows\\Microsoft.NET\\Framework64\\"'
        printf '%s\n' '[HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\.NETFramework]'
        printf '%s\n' '"InstallRoot"="C:\\windows\\Microsoft.NET\\Framework\\"'
        printf '%s\n' '[HKEY_CURRENT_USER\Software\Wine\DllOverrides]'
        printf '%s\n' '"mscoree"="native"'
    } > "$SUPPORT/dotnet.reg"
    "$WINE" regedit /S "Z:$SUPPORT/dotnet.reg" >> "$WINELOG" 2>&1
    "$WINE" reg query 'HKCU\Software\Wine\DllOverrides' /v mscoree >> "$WINELOG" 2>&1 || return 1
    "$WINE" winecfg -v win7 >> "$WINELOG" 2>&1   # the .NET 4.8 installer wants Windows 7 or later

    winedbg_watchdog &
    watchdog_pid=$!
    ngen32_guard &
    guard_pid=$!
    (cd "$(dirname "$f48")" && WINEDLLOVERRIDES=fusion=b "$WINE" "$(basename "$f48")" /sfxlang:1027 /q /norestart) >> "$WINELOG" 2>&1
    rc=$?
    kill "$watchdog_pid" "$guard_pid" 2>/dev/null
    wine_wait 120
    log ".NET 4.8 installer exit code $rc"
    [ -f "$win/Microsoft.NET/Framework64/v4.0.30319/clr.dll" ] || return 1
    # The .NET 4.0 installer also registers the symbol writer COM server. Without
    # it, Mission Planner cannot compile its .cs plugins (17 of 27 do not load).
    {
        "$WINE" regsvr32 /s 'C:\windows\Microsoft.NET\Framework64\v4.0.30319\diasymreader.dll'
        "$WINE" 'C:\windows\syswow64\regsvr32.exe' /s 'C:\windows\Microsoft.NET\Framework\v4.0.30319\diasymreader.dll'
        "$WINE" winecfg -v win10
    } >> "$WINELOG" 2>&1
    # Success: 0, 3010 (reboot required) and 1641 (reboot started). A Unix exit
    # status has 8 bits, so 3010 and 1641 arrive as 194 and 105. clr.dll was
    # checked above.
    case "$rc" in 0|194|105) return 0 ;; esac
    return 1
}

setup_prefix() {
    log "creating Wine prefix in $WINEPREFIX"
    progress 2 "Creating the Wine folder"
    # Do not install Wine Mono or Gecko. .NET Framework 4.8 replaces Mono.
    WINEDLLOVERRIDES="mscoree=;mshtml=" "$WINE" wineboot --init >> "$WINELOG" 2>&1 || fail "wineboot failed."
    wine_wait 120
    apply_settings

    progress 8 "Downloading Microsoft .NET Framework 4.8 (about 120 MB)"
    log "installing .NET Framework 4.8"
    install_dotnet || fail ".NET Framework 4.8 did not install."
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
    wine_wait 120
    apply_settings
    echo "$BUNDLE_VERSION" > "$STATE/mp-version"
    progress 100 "Done"
}

NEED_SETUP=0
if [ ! -f "$STATE/prefix-ok" ] || [ ! -f "$WINEPREFIX/system.reg" ]; then NEED_SETUP=1; fi
NEED_MP=0
if [ "$(cat "$STATE/mp-version" 2>/dev/null)" != "$BUNDLE_VERSION" ] || [ ! -f "$MP_DIR/MissionPlanner.exe" ]; then NEED_MP=1; fi

if [ "$NEED_SETUP" = 1 ]; then
    ask "First start: Mission Planner installs Microsoft .NET Framework 4.8 into its own Wine folder. This downloads about 120 MB from Microsoft and takes about 15 minutes." "Continue" || exit 0
    [ -d "$WINEPREFIX" ] && "$WINESERVER" -k 2>/dev/null
    rm -rf "$WINEPREFIX" "$STATE/prefix-ok" "$STATE/mp-version"
    progress_start "Setting up Mission Planner. This takes about 15 minutes."
    setup_prefix
    install_mp
    progress_end
    show "Setup is done. Mission Planner starts now." 10
elif [ "$NEED_MP" = 1 ]; then
    progress_start "Updating Mission Planner. This takes about 7 minutes."
    install_mp
    progress_end
fi

# ---------------------------------------------------------------- run

update_ports
port_watcher &
WATCHER_PID=$!

[ -f "$WINELOG" ] && mv -f "$WINELOG" "$WINELOG.1"
log "starting MissionPlanner.exe"
cd "$MP_DIR" || fail "Mission Planner folder is missing."
STARTED=$(date +%s)
START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
# stdin is not a terminal, so Wine starts no console for Mission Planner.
"$WINE" "$MP_DIR/MissionPlanner.exe" "$@" < /dev/null >> "$WINELOG" 2>&1
STATUS=$?
log "MissionPlanner.exe exited with $STATUS after $(( $(date +%s) - STARTED )) s"
# A start that ends with an error before the main window loads is a crash. Tell the user.
loaded_since_start() {
    # Did the main window load in this run? Mission Planner's log rolls over at
    # 1 MB into MissionPlanner.log.1, so read both and compare timestamps.
    cat "$MP_LOG.1" "$MP_LOG" 2>/dev/null | grep "appload time" | cut -c1-19 \
        | awk -v t="$START_TS" '$0 >= t { found = 1 } END { exit !found }'
}
if [ "$STATUS" -ne 0 ] && ! loaded_since_start; then
    "$WINESERVER" -k 2>/dev/null
    fail "Mission Planner stopped while it was starting (exit code $STATUS)."
fi
# Wait for other Windows processes (for example Mission Planner's updater).
# A process that stays would keep the launcher (and its lock) alive.
wine_wait 60
hide
exit $STATUS
