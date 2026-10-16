#!/bin/bash
# CI experiment: ways to install .NET Framework 4.8 into a Wine prefix on macOS.
# Usage: dotnet-exp.sh VARIANT WINE_ROOT WINETRICKS OUTDIR
# VARIANT: A (winetricks dotnet48), B (direct ndp48, no dotnet40),
#          C (winetricks, Direct3D renderer gdi), E (direct ndp48 + gdi)
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

# Run a command with a time limit; on timeout capture diagnostics.
limit() {
    secs="$1"; shift
    "$@" >> "$OUT/wine.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 "$secs"); do
        kill -0 "$pid" 2>/dev/null || { wait "$pid"; return $?; }
        sleep 1
    done
    t "TIMEOUT after $secs s: $*"
    ps -axo pid,ppid,etime,%cpu,command | grep -iE 'wine|\.exe' | grep -v grep > "$OUT/ps-at-timeout.txt"
    screencapture -x "$OUT/timeout.png" 2>/dev/null
    "$WINE" winedbg --command "info process" > "$OUT/winedbg-proc.txt" 2>&1 &
    sleep 20
    "$WINESERVER" -k 2>/dev/null
    kill "$pid" 2>/dev/null
    return 124
}

set_gdi() {
    "$WINE" reg add 'HKCU\Software\Wine\Direct3D' /v renderer /t REG_SZ /d gdi /f >> "$OUT/wine.log" 2>&1
}

direct_ndp48() {
    f="$W_CACHE/dotnet48/ndp48-x86-x64-allos-enu.exe"
    if [ ! -f "$f" ]; then
        mkdir -p "$W_CACHE/dotnet48"
        curl -fsSL -o "$f" https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe
    fi
    echo "95889d6de3f2070c07790ad6cf2000d33d9a1bdfc6a381725ab82ab1c314fd53  $f" | shasum -a 256 -c - >> "$LOG" || return 1
    "$WINE" winecfg -v win7 >> "$OUT/wine.log" 2>&1
    WINEDLLOVERRIDES=fusion=b limit 1500 "$WINE" "$f" /q /norestart
    rc=$?
    "$WINE" reg add 'HKCU\Software\Wine\DllOverrides' /v '*mscoree' /t REG_SZ /d native /f >> "$OUT/wine.log" 2>&1
    "$WINE" reg add 'HKCU\Software\Wine\DllOverrides' /v mscoree /t REG_SZ /d native /f >> "$OUT/wine.log" 2>&1
    return $rc
}

T0=$(date +%s)
t "variant $VARIANT, $("$WINE" --version)"
WINEDLLOVERRIDES="mscoree=;mshtml=" "$WINE" wineboot --init >> "$OUT/wine.log" 2>&1; "$WINESERVER" -w
t "prefix created"
case "$VARIANT" in
    C|E) set_gdi; t "renderer=gdi set" ;;
esac
case "$VARIANT" in
    A|C|D) PATH="$SHIM:$PATH" WINE64="$WINE" WINETRICKS_LATEST_VERSION_CHECK=disabled limit 1800 sh "$WINETRICKS" -q dotnet48; RC=$? ;;
    B|E) direct_ndp48; RC=$? ;;
esac
t "dotnet install rc=$RC after $(( $(date +%s) - T0 )) s"
"$WINE" winecfg -v win10 >> "$OUT/wine.log" 2>&1
"$WINESERVER" -w
ls "$WINEPREFIX/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/" > "$OUT/fw64.txt" 2>&1
grep -q '^clr.dll$' "$OUT/fw64.txt" && t "clr.dll present (64-bit .NET 4.x installed)" || t "clr.dll MISSING"

# Run Mission Planner (release build) and wait for the main window.
MP="$WINEPREFIX/drive_c/MP"
mkdir -p "$MP" && ditto -x -k "$HOME/mp.zip" "$MP"
mkdir -p "$WINEPREFIX/drive_c/users/$USER/Documents/Mission Planner"
cat > "$WINEPREFIX/drive_c/users/$USER/Documents/Mission Planner/config.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<Config>
  <AA_CheckEnableAltitudeAngel>False</AA_CheckEnableAltitudeAngel>
  <tabcontrolactions>tabQuick;tabActions;tabPagemessages;tabActionsSimple;tabPagePreFlight;tabGauges;tabTransponder;tabStatus;tabServo;tabAuxFunction;tabScripts;tabPayload;tabTLogs;tablogbrowse;</tabcontrolactions>
</Config>
XML
MPLOG="$WINEPREFIX/drive_c/ProgramData/Mission Planner/MissionPlanner.log"
T1=$(date +%s)
(cd "$MP" && "$WINE" MissionPlanner.exe >> "$OUT/mp-stdout.log" 2>&1 &)
for _ in $(seq 1 300); do
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
