# Mission Planner for macOS (Wine bundle)

This app runs the normal Windows version of Mission Planner on a Mac.
It contains Wine (a layer that runs Windows programs on macOS).
On Apple Silicon Macs it also uses Rosetta 2 (Apple's Intel translator).

## Install

1. Download `MissionPlanner-macOS-wine.dmg` from the `macwine-latest` release of this repository.
2. Open the DMG and drag **Mission Planner** to **Applications**.
3. The app has no Apple signature. Remove the download quarantine one time. In Terminal:

   ```
   xattr -dr com.apple.quarantine "/Applications/Mission Planner.app"
   ```

   If you do not do this, macOS blocks the app. You can also use
   System Settings > Privacy & Security > **Open Anyway**.
4. Open **Mission Planner** from Applications.

## First start

- If Rosetta 2 is not installed, the app asks to install it. macOS asks for your password.
- The app installs Microsoft .NET Framework 4.8 into its own Wine folder.
  It downloads about 120 MB from Microsoft. This takes 5 to 20 minutes.
  You get a notice when it is done. Later starts do not do this again.

## Connect the flight controller

- Connect the flight controller with USB. No driver is necessary.
- In Mission Planner, select **COM3** (the first USB device) and click **Connect**.
  A second USB device becomes COM4, and so on, up to COM6.
- You can connect the flight controller before or after you start the app.

## What does not work

- DFU flashing (the first ArduPilot install on a board that has other firmware).
  Do that one time with another tool, for example `dfu-util` or STM32CubeProgrammer.
  After that, firmware updates in Mission Planner work over USB.
- Video, joystick and other Windows-only USB devices.

## Files and logs

| What | Where |
|---|---|
| Wine folder (.NET, Mission Planner copy) | `~/Library/MissionPlannerWine` |
| App logs (send these if something fails) | `~/Library/Logs/MissionPlannerWine` |
| Mission Planner data (logs, params, maps) | `~/Documents/Mission Planner` |

To reset the app, quit it and delete `~/Library/MissionPlannerWine`. The next start sets it up again.

## Limits

- Apple keeps Rosetta 2 for normal apps only through macOS 27.
  This app can stop working on macOS 28 or later.

## Build

`.github/workflows/mac-wine.yml` builds the app:

1. The Windows job builds Mission Planner from this repository.
2. The macOS job runs `MacWine/build-app.sh`, which puts the Windows build, Wine
   (Gcenx macOS build, pinned by SHA-256) and winetricks into `Mission Planner.app`.
3. The smoke test job installs the app on a GitHub macOS machine, runs the first start
   and checks that `MissionPlanner.exe` keeps running.
