# Mission Planner for macOS (Wine bundle)

This app runs the normal Windows version of Mission Planner on a Mac.
It contains Wine (a layer that runs Windows programs on macOS).
On Apple Silicon Macs it also uses Rosetta 2 (Apple's Intel translator).

## Install

1. Download `MissionPlanner-macOS-wine.dmg` from the `macwine-latest` release of this repository.
2. Open the DMG and drag **Mission Planner** to **Applications**.
3. The app has no Apple signature. Remove the download quarantine. In Terminal:

   ```
   xattr -dr com.apple.quarantine "/Applications/Mission Planner.app"
   ```

   Do this again after each update.
4. Open **Mission Planner** from Applications.

## First start

- If Rosetta 2 is not installed, the app asks to install it. macOS asks for your password.
- The app installs Microsoft .NET Framework 4.8 into its own Wine folder.
  It downloads about 165 MB from Microsoft. Then it compiles Mission Planner to native
  code once, so that later starts are faster. This takes 10 to 30 minutes.
  A window with a progress bar shows while setup runs. Mission Planner opens when setup is done.
  Later starts do not do this again. After an app update, the compile step runs again (a few minutes).
- The app answers Mission Planner's two first-start questions for you: the Altitude Angel
  plugin is off (turn it on later in Mission Planner if you want it), and the Drone ID tab is on.
- macOS can ask whether Mission Planner may use your Documents folder.
  Click **Allow**: Mission Planner keeps its logs, parameters and maps there.

## Connect the flight controller

- Connect the flight controller with USB. No driver is necessary.
- In Mission Planner, select **COM3** (the first USB serial device) and click **Connect**.
  A second USB serial device becomes COM4, and so on, up to COM6.
  Mission Planner always lists COM3 to COM6, also when nothing is connected.
- You can connect the flight controller before or after you start the app.

## Using the app

- **Keyboard:** Cmd works like Ctrl in Mission Planner (Cmd+C, Cmd+V, Cmd+A).
  Left Option works like Alt. Right Option still types accented letters.
- **Quit:** close the Mission Planner main window.
- **Trackpad:** two-finger scrolling zooms the map in normal steps.
- **Sleep:** while Mission Planner is open, the Mac does not go to idle sleep,
  so telemetry is not cut off. (The display can still turn off.)
- **Voice alerts:** they do not work (Wine has no text-to-speech).

## Firmware

- **Install Firmware** cannot detect the board automatically in Wine.
  Download the `.apj` file for your board from https://firmware.ardupilot.org
  and use **Load custom firmware**. This works over USB through the ArduPilot bootloader.
- DFU flashing does not work. You need it only for the first ArduPilot install on a board
  that has other firmware (for example Betaflight). Do that one time with another tool,
  for example `dfu-util` or STM32CubeProgrammer.

## What does not work

- DFU flashing and automatic board detection (see Firmware).
- Video, joystick and other Windows-only USB devices.

## Files and logs

| What | Where |
|---|---|
| App logs (send these if something fails) | `~/Library/Logs/MissionPlannerWine` |
| Mission Planner program log | `~/Library/MissionPlannerWine/prefix/drive_c/ProgramData/Mission Planner/MissionPlanner.log` |
| Mission Planner data (logs, params, maps) | `~/Documents/Mission Planner` |
| Wine folder (.NET, Mission Planner copy) | `~/Library/MissionPlannerWine` |

To reset the app, quit it and delete `~/Library/MissionPlannerWine`. The next start sets it up again.

## Limits

- Apple keeps Rosetta 2 for normal apps only through macOS 27.
  This app can stop working on macOS 28 or later.

## Build

`.github/workflows/mac-wine.yml` builds the app:

1. The Windows job builds Mission Planner from this repository.
2. The macOS job runs `MacWine/build-app.sh`, which puts the Windows build, Wine
   (Gcenx macOS build, pinned by SHA-256) and winetricks into `Mission Planner.app`.
3. The smoke test job installs the app on a GitHub macOS machine (quarantined, without
   the Xcode tools), runs the first start and checks that the Mission Planner main window loads.
4. If the smoke test passes, the publish job updates the `macwine-latest` prerelease.
