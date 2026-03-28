# Lock

`Lock` is a native macOS menu bar app that lets you protect selected apps with your own password.

When a protected app launches or becomes active, `Lock` hides that app and shows a lock overlay in its place. The app stays unusable until the correct password or Touch ID is used.

## What It Does

- Runs as a menu bar utility instead of a Dock app
- Lets you choose which installed apps are protected
- Stores the password in Keychain
- Supports password unlock and Touch ID unlock
- Requests and checks the macOS permissions needed for monitoring apps
- Can launch at login through a LaunchAgent
- Builds into a real macOS app bundle at `dist/Lock.app`

## Requirements

- macOS 14 or later
- Xcode or Command Line Tools with a working Swift toolchain
- Accessibility permission
- Screen Recording permission

Without Accessibility and Screen Recording, the app cannot reliably detect, hide, and overlay other apps.

## Project Structure

- `Sources/Lock` - Swift source for the menu bar app
- `scripts/build_app.sh` - builds a release `.app` bundle
- `scripts/run_app.sh` - builds the app bundle and opens it
- `scripts/install_app.sh` - builds the app bundle and installs it to `/Applications`
- `dist/Lock.app` - generated local app bundle output

## Build

Build the local app bundle:

```bash
cd /Users/zohaibarsalan/Developer/lock
./scripts/build_app.sh
```

This creates:

```text
/Users/zohaibarsalan/Developer/lock/dist/Lock.app
```

## Run

For local development, build and open the app bundle:

```bash
cd /Users/zohaibarsalan/Developer/lock
./scripts/run_app.sh
```

Do not use `swift run` as the normal workflow. It keeps the app attached to Terminal and does not reflect how the menu bar app should behave in real use.

## Install As a Normal App

Install `Lock.app` into `/Applications`:

```bash
cd /Users/zohaibarsalan/Developer/lock
./scripts/install_app.sh
```

After that, launch it like any other macOS app:

```bash
open /Applications/Lock.app
```

Because `Lock` is a menu bar app, it does not stay in the Dock after launch. Look for its icon in the menu bar.

## First-Time Setup

1. Launch `Lock`.
2. Open the main window from the menu bar icon.
3. Go to `Settings`.
4. Grant Accessibility permission.
5. Grant Screen Recording permission.
6. Set your password.
7. Go to `App List` and enable protection for the apps you want locked.

## How Locking Works

At a high level:

1. `Lock` watches running applications.
2. When a protected app opens or becomes active, `Lock` captures that app's window frame.
3. The protected app is hidden.
4. A lock overlay is shown in the same position.
5. On successful unlock, the app is unhidden and brought back.

This is implemented with:

- `AppMonitor.swift` for runtime app observation
- `OverlayCoordinator.swift` for lock overlay presentation and unlock flow
- `LockOverlayView.swift` for the lock UI
- `LockStore.swift` for protected app state and password verification

## Permissions

`Lock` depends on two macOS permissions:

- Accessibility: used to inspect app windows and manage lock behavior
- Screen Recording: used so macOS allows the app to work reliably with other app windows

If the app stops behaving correctly after permission changes, reopen `Settings` and re-check both permissions.

## Launch At Login

The app can install a LaunchAgent so it starts when you sign in.

This works best when you are running the packaged app bundle from `/Applications/Lock.app`, not the raw Swift executable.

## Troubleshooting

### The lock overlay does not appear

- Make sure a password has been set
- Make sure the target app is marked as protected
- Re-check Accessibility and Screen Recording permissions
- Quit and relaunch `Lock`

### The protected app shows briefly before the lock overlay

Some apps and some macOS permission flows can still cause short visual transitions. The current implementation hides the target app as early as possible, but app activation timing is controlled partly by macOS.

### The main `Lock` window goes behind another app

The app now promotes itself to a regular foreground app while the settings/main window is open, then returns to menu-bar-only behavior when that window closes. If this still happens in a specific system prompt flow, test that path again after reinstalling the latest build.

### Build fails with Swift or SDK errors

That usually means the active Swift compiler and macOS SDK do not match. Update Xcode or Command Line Tools and make sure `xcode-select` points to the toolchain you want to use.

## Rebuild From a Clean Slate

If you want to remove the installed app and local build artifacts before rebuilding:

- delete `/Applications/Lock.app`
- delete `dist`
- delete `.build`

Then rebuild:

```bash
cd /Users/zohaibarsalan/Developer/lock
./scripts/install_app.sh
```

## Notes

- Password data is stored in Keychain under the app's service name, not in plain text.
- Protected app selections are stored in the app defaults domain.
- The generated app bundle is ad-hoc signed for local use.
- This project is currently set up for local installation, not App Store distribution.
