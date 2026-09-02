# Toggle Local Network

An AppleScript utility to fix the M4 Mac mini local network bug that prevents apps from accessing the local network after a reboot. This script automatically toggles local network permissions off and back on for all enabled apps.

## The Problem

M4 Mac minis have a bug where apps lose their local network access after a reboot, even though the permissions remain enabled in System Settings. A known workaround is to manually toggle the local network permission for each affected app off and back on.

## The Solution

This AppleScript automates the tedious process of toggling local network permissions for all apps. It opens System Settings, navigates to Privacy & Security > Local Network, and toggles the permission for each enabled app.

## Installation

### Option 1: Use the Pre-Built App (Recommended)

1. Download the `.zip` file from the [latest release](https://github.com/HAGerox/Toggle-Local-Network/releases)
2. Extract the `Toggle Local Network.app` from the zip file
3. Move it to your Applications folder (optional)
4. Run the app
5. Grant Accessibility permissions when prompted (it will show as "Toggle Local Network")
6. Run the app again
7. Click "Allow" on the popup to let it control System Settings

The pre-built app uses the executable name `Toggle Local Network` and the stable
bundle identifier `com.hagerox.ToggleLocalNetwork`, so macOS can display and
retain the correct Accessibility entry.

### Option 2: Build From Source

1. Open `toggle_local_network.applescript` in Script Editor
2. Export as an Application:
   - File > Export
   - File Format: Application
   - Save as: `Toggle Local Network`
3. Run the newly created app
4. Grant Accessibility permissions when prompted (it will show as "applet")
5. Run the app again
6. Click "Allow" on the popup

### Option 3: Build and Rename for Better Accessibility Label

If you build from source, the app will show up as "applet" in the Accessibility permissions list. To give it a more descriptive name:

1. Build the app following Option 2
2. Right-click the app and select "Show Package Contents"
3. Navigate to `Contents/MacOS/`
4. Rename the `applet` executable to something descriptive (e.g., `Toggle Local Network`)
5. Open `Contents/Info.plist` in a text editor
6. Change the `CFBundleExecutable` value to match your new executable name:
   ```xml
   <key>CFBundleExecutable</key>
   <string>Toggle Local Network</string>
   ```
7. Re-sign the app:
   ```bash
   codesign --force --deep --sign - "/path/to/Toggle Local Network.app"
   ```
8. Now when you grant Accessibility permissions, it will show up with your chosen name

## Usage

Simply run the app whenever you need to reset local network permissions (e.g., after a reboot). The script will:

1. Open System Settings
2. Navigate to Privacy & Security > Local Network
3. Toggle all enabled app permissions off and back on
4. Close System Settings

The process normally takes less than a second per enabled app, plus the time
System Settings needs to load its Accessibility hierarchy.

### Run Automatically on Startup

To have the app run automatically after each reboot (when the network bug would occur):

1. Open System Settings > General > Login Items
2. Click the "+" button under "Open at Login"
3. Select the `Toggle Local Network.app`
4. The app will now run automatically when you log in

## Requirements

- macOS Sequoia (tested specifically for this version)
- Accessibility permissions for the app

**Note:** This script uses semantic Accessibility identifiers exposed by System
Settings on macOS Sequoia. It does not rely on group or button positions. If Apple
changes those identifiers in a future macOS release, the script stops with an
error instead of risking a click on the wrong permission category.

## How It Works

The script uses AppleScript and UI automation to:

- Wait for any previous System Settings process to finish closing
- Open the modern Privacy & Security extension URL
- Find `Local Network_Navigator` by its `AXIdentifier`
- Wait for the window to be renamed to `Local Network` before reading its UI tree
- Find checkbox identifiers ending in `_Toggle`
- Toggle enabled checkboxes off and on, confirming both state changes
- Close System Settings and wait for it to terminate

Local Network does not have a working direct deep-link anchor on the tested
Sequoia builds, so the semantic Accessibility navigation step is intentional.

## Tests

The test suite compiles the AppleScript, checks that positional and stale named
window lookups are absent, and performs one live toggle round trip.

Run the non-UI compile, static, and helper tests from the repository root:

```bash
tests/run_tests.sh
```

When the Mac can be left alone, explicitly run the complete UI suite:

```bash
RUN_UI_TESTS=1 tests/run_tests.sh integration
```

The integration tests control System Settings and therefore require Accessibility
permission for the terminal or test runner. They are opt-in because they activate
and close System Settings. The toggle round-trip test temporarily changes every
enabled Local Network switch and verifies that it returns to enabled.

## Notes

- If Accessibility is unavailable, the app asks macOS for access and shows an
  explanation with a button to open the Accessibility settings page.
- You only need to grant permissions once
- The pre-built release already has the descriptive name configured
