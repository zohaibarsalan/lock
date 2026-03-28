# Lock

`Lock` is a native macOS menu bar app for protecting selected apps with your own password.

## Run

Do not use `swift run` as the normal app workflow. It keeps the process attached to Terminal.

Use the bundle script instead:

```bash
cd /Users/zohaibarsalan/Developer/lock
chmod +x scripts/run_app.sh
./scripts/run_app.sh
```

That builds a local app bundle at `dist/Lock.app` and opens it as a proper menu bar app.

## Features

- Menu bar app with a small panel for `Add Apps`, `Settings`, and `Quit`
- Sidebar-based main window for `App List` and `Settings`
- Password stored in Keychain
- Accessibility and Screen Recording permission management
- Launch-at-login toggle backed by a LaunchAgent
- Runtime app monitoring with a lock prompt when a protected app opens

## Notes

- If a protected app is already open when `Lock` starts, it will also be hidden and challenged.
- Launch at login works best when you run the packaged app bundle instead of the raw executable.
