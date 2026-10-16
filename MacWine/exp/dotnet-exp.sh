#!/bin/bash
# CI experiment: ways to install .NET Framework 4.8 with Wine on macOS.
# Usage: dotnet-exp.sh VARIANT WINE_ROOT WINETRICKS OUTDIR
# All variants run `winetricks -q dotnet48`. Differences:
#   A  as is (diagnostics only: process list every 30 s)
#   F  winedbg.exe disabled + ShowCrashDialog=0 (crashing sub-installer exits)
#   G  F + watchdog that kills a winedbg that stays more than 30 s
#   H  watchdog only
#   D  same as G (run with a different Wine build)
# WineHQ bug 57998: on macOS the dotnet40 step hangs in `winedbg --auto`.
set -u
VARIANT="$1" WINE_ROOT="$2" WINETRICKS="$3" OUT="$4"
mkdir -p "$OUT"
export WINEPREFIX="$HOME/exp-prefix-$VARIANT"
export WINE="$WINE_ROOT/bin/wine" WINESERVER="$WINE_ROOT/bin/wineserver"
export PATH="$WINE_ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export WINEDEBUG="${WINEDEBUG:--all}" W_CACHE="$HOME/exp-cache"
SHIM="$HOME/exp-shim"; mkdir -p "$SHIM" "$W_CACHE"
printf '#!/bin/sh\necho x86_64\n' > "$SHIM/lipo"; chmod 755 "$SHIM/lipo"
LOG="$OUT/run.log"
t() { echo "$(date +%H:%M:%S) $*" | tee -a "$LOG"; }

case "$VARIANT" in G|H|D) WATCHDOG=1 ;; *) WATCHDOG=0 ;; esac
case "$VARIANT" in F|G|D) NODBG=1 ;; *) NODBG=0 ;; esac

# Background: process list every 30 s; with WATCHDOG, kill winedbg seen twice.
monitor() {
    seen=""
    while :; do
        sleep 30
        { echo "=== $(date +%H:%M:%S)"; ps -axo pid,ppid,etime,%cpu,command | grep -iE 'wine|\.exe' | grep -v grep; } >> "$OUT/ps.log"
        dbg="$(pgrep -f 'winedbg' | tr '\n' ' ')"
        if [ -n "$dbg" ]; then
            if [ "$WATCHDOG" = 1 ] && [ "$dbg" = "$seen" ]; then
                t "watchdog: killing winedbg ($dbg)"
                pkill -f winedbg
                seen=""
                continue
            fi
            t "winedbg running: $dbg"
        fi
        seen="$dbg"
    done
}

T0=$(date +%s)
t "variant $VARIANT (watchdog=$WATCHDOG nodbg=$NODBG), $("$WINE" --version)"
WINEDLLOVERRIDES="mscoree=;mshtml=" "$WINE" wineboot --init >> "$OUT/wine.log" 2>&1; "$WINESERVER" -w
t "prefix created"
if [ "$NODBG" = 1 ]; then
    "$WINE" reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f >> "$OUT/wine.log" 2>&1
    "$WINE" reg add 'HKCU\Software\Wine\DllOverrides' /v winedbg.exe /t REG_SZ /d '' /f >> "$OUT/wine.log" 2>&1
    "$WINESERVER" -w
    t "winedbg disabled"
fi
monitor & MON=$!
PATH="$SHIM:$PATH" WINE64="$WINE" WINETRICKS_LATEST_VERSION_CHECK=disabled sh "$WINETRICKS" -q dotnet48 >> "$OUT/wine.log" 2>&1 &
WT=$!
RC=124
for _ in $(seq 1 2400); do
    if ! kill -0 "$WT" 2>/dev/null; then wait "$WT"; RC=$?; break; fi
    sleep 1
done
kill "$MON" 2>/dev/null
if [ "$RC" = 124 ]; then
    t "TIMEOUT"; screencapture -x "$OUT/timeout.png" 2>/dev/null
    ps -axo pid,ppid,etime,%cpu,command | grep -iE 'wine|\.exe' | grep -v grep > "$OUT/ps-at-timeout.txt"
    "$WINESERVER" -k; kill "$WT" 2>/dev/null
fi
t "winetricks dotnet48 rc=$RC after $(( $(date +%s) - T0 )) s"
"$WINE" winecfg -v win10 >> "$OUT/wine.log" 2>&1
"$WINESERVER" -w
FW="$WINEPREFIX/drive_c/windows"
ls -la "$FW/system32/mscoree.dll" "$FW/syswow64/mscoree.dll" "$FW/Microsoft.NET/Framework64/v4.0.30319/clr.dll" > "$OUT/files.txt" 2>&1
cat "$OUT/files.txt" >> "$LOG"

# Run Mission Planner (release build) and wait for the main window.
MP="$WINEPREFIX/drive_c/MP"
mkdir -p "$MP" && ditto -x -k "$HOME/mp.zip" "$MP"
DOCS="$WINEPREFIX/drive_c/users/$USER/Documents/Mission Planner"
mkdir -p "$DOCS"
cat > "$DOCS/config.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<Config>
  <AA_CheckEnableAltitudeAngel>False</AA_CheckEnableAltitudeAngel>
  <tabcontrolactions>tabQuick;tabActions;tabPagemessages;tabActionsSimple;tabPagePreFlight;tabGauges;tabTransponder;tabStatus;tabServo;tabAuxFunction;tabScripts;tabPayload;tabTLogs;tablogbrowse;</tabcontrolactions>
</Config>
XML
MPLOG="$WINEPREFIX/drive_c/ProgramData/Mission Planner/MissionPlanner.log"
T1=$(date +%s)
(cd "$MP" && "$WINE" MissionPlanner.exe >> "$OUT/mp-stdout.log" 2>&1 &)
for _ in $(seq 1 150); do
    grep -q "appload time" "$MPLOG" 2>/dev/null && break
    sleep 2
done
if grep -q "appload time" "$MPLOG" 2>/dev/null; then
    t "MP main window loaded after $(( $(date +%s) - T1 )) s"; echo PASS > "$OUT/result.txt"
else
    t "MP did not load"; echo FAIL > "$OUT/result.txt"
fi
sleep 20
screencapture -x "$OUT/mp.png" 2>/dev/null
cp "$MPLOG" "$OUT/" 2>/dev/null
"$WINESERVER" -k 2>/dev/null
t "total $(( $(date +%s) - T0 )) s"
