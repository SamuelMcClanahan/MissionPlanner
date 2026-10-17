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
  It downloads about 120 MB from Microsoft. Then it compiles Mission Planner to native
  code once, so that later starts are faster. This takes about 15 minutes
  (measured on a GitHub macOS test machine: 4.5 minutes for .NET, 7 minutes to compile).
  A window with a progress bar shows while setup runs. Mission Planner opens when setup is done.
  Later starts do not do this again. After an app update, the compile step runs again (about 7 minutes).
- The app answers Mission Planner's two first-start questions for you: the Altitude Angel
  plugin is off (turn it on later in Mission Planner if you want it), and the Drone ID tab is on.
- macOS can ask whether Mission Planner may use your Documents folder.
  Click **Allow**: Mission Planner keeps its logs, parameters and maps there.
- macOS can ask whether Mission Planner may find devices on local networks.
  Click **Allow** if you use UDP or Wi-Fi telemetry. USB does not need it.

## Connect the flight controller

- Connect the flight controller with USB. No driver is necessary.
- In Mission Planner, select **COM3** (the first USB serial device) and click **Connect**.
  A second USB serial device becomes COM4, and so on, up to COM6.
  Mission Planner always lists COM3 to COM6, also when nothing is connected.
  It can also list names that start with `/dev/`. Do not select them: they do not work in Wine.
- You can connect the flight controller before or after you start the app.

## Using the app

- **Keyboard:** Cmd works like Ctrl in Mission Planner (Cmd+C, Cmd+V, Cmd+A).
  Left Option works like Alt. Right Option still types accented letters.
- **Quit:** close the Mission Planner main window.
- **Trackpad:** two-finger scrolling zooms the map in normal steps.
- **Sleep:** while Mission Planner is open, the Mac does not go to idle sleep,
  so telemetry is not cut off. (The display can still turn off.)
- **Voice alerts:** they do not work (Wine has no text-to-speech).
- **HUD:** the app draws the HUD with GDI+, because the OpenGL HUD does not draw in Wine
  on macOS. (Config > Planner > "GDI+ HUD" changes this.)

## Firmware

- **Install Firmware** cannot detect the board automatically in Wine.
  Download the `.apj` file for your board from https://firmware.ardupilot.org
  and use **Load custom firmware**. This works over USB through the ArduPilot bootloader.
- DFU flashing does not work. You need it only for the first ArduPilot install on a board
  that has other firmware (for example Betaflight). Do that one time with another tool,
  for example `dfu-util` or STM32CubeProgrammer.

## What does not work

- DFU flashing and automatic board detection (see Firmware).
- Serial speeds above 230400 baud can fail (for example 460800 for ExpressLRS MAVLink).
  Wine on macOS cannot set them. A flight controller on USB is not affected.
- Video, joystick and other Windows-only USB devices.

## Files and logs

| What | Where |
|---|---|
| App logs (send these if something fails) | `~/Library/Logs/MissionPlannerWine` |
| Mission Planner program log | `~/Library/MissionPlannerWine/prefix/drive_c/ProgramData/Mission Planner/MissionPlanner.log` |
| Mission Planner settings and logs (config.xml, tlogs, DataFlash logs) | `~/Documents/Mission Planner` |
| Map tile cache, elevation data, parameter descriptions | `~/Library/MissionPlannerWine/prefix/drive_c/ProgramData/Mission Planner` |
| Wine folder (.NET, Mission Planner copy) | `~/Library/MissionPlannerWine` |

To reset the app, quit it and delete `~/Library/MissionPlannerWine`. The next start sets it up again.
This also deletes the map cache and elevation data. Your settings and logs in Documents stay.

## Limits

- Apple keeps Rosetta 2 for normal apps only through macOS 27.
  This app can stop working on macOS 28 or later.

## Build

`.github/workflows/mac-wine.yml` builds the app:

1. The Windows job builds Mission Planner from this repository.
2. The macOS job runs `MacWine/build-app.sh`, which puts the Windows build and Wine
   (Gcenx macOS build, pinned by SHA-256) into `Mission Planner.app`.
   It also patches one bug in the Wine server (`MacWine/patch-wineserver.py`): on macOS the
   server crashed when a program opened a file on a file system with a device number above
   0x7fffffff. The device number of `/dev` is different on each Mac and looks random (in the CI
   tests, about 1 machine in 4 had such a number), and Mission Planner opens `/dev` when it
   lists serial ports.
3. The smoke test job installs the app on three GitHub macOS machines at the same time
   (quarantined, without the Xcode tools). It runs the first start and a second start, and
   checks that the Mission Planner main window loads each time.
4. If the smoke test passes, the publish job updates the `macwine-latest` prerelease.
