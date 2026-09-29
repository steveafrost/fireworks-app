# Fireworks

Remaining Fireworks AI credit in your menu bar, in a widget, and on your iPhone.

Fireworks is prepaid. Their API returns rated **cost**, not **balance** — every
balance-shaped endpoint answers 404 (`billing/summary`, `billing/balance`,
`balance`, `credits`, `billing/usage` were each re-measured against the live API).
So the app does the only honest thing available:

```
remaining = anchor_balance − rated spend from anchor_time → now
```

You tell it the balance you hold (once, from the billing page or a top-up), and
everything after that anchor is measured spend. The anchor is always shown
alongside the figure, so a subtraction is never mistaken for something Fireworks
reported.

## Layout

| Path | What it is |
|---|---|
| `Core/` | Swift package: the whole engine, no UI, no third-party dependencies |
| `Core/Sources/FireworksCore/` | API client, config, anchor math, day series, alert planning, key handling |
| `Core/Tests/FireworksCoreTests/` | 45 tests, no network, no simulator (`swift test`) |
| `project.yml` | XcodeGen spec for the app + widget targets (the `.xcodeproj` is generated, never committed) |
| `Mac/` | menu-bar app (no Dock icon, popover UI) |
| `iOS/` | iPhone/iPad app |
| `Shared/` | the app-side half: `AppModel`, notifications, diagnostics, views |
| `Widgets/` | WidgetKit extensions for both platforms |
| `RELEASE.md` | signing, App Group, notarization, TestFlight |

One engine, three surfaces. Nothing about "what the number is" is allowed to
exist twice, which is why the engine has no AppKit/UIKit/SwiftUI import: the Mac
app, the iOS app and every widget compile the same source.

## Why an engine package and not "logic in the app"

- Every rule that matters — the subtraction, the alert crossings, the local-day
  boundaries, the key validation — is testable with `swift test` in under a
  second, with no simulator and no network.
- A widget extension cannot make network calls on a useful schedule and cannot
  read the app's container. The app writes a small snapshot (remaining, today,
  rate, days left, the daily series) into the App Group container
  (`group.com.whitebox.fireworks`); widgets render that and never fetch.
- The settings and cache file names match the SwiftBar plugin's, so on a Mac
  that ran the plugin first, the app picks up the existing anchor and alert
  history instead of starting over.

## Building

```bash
# the engine
cd Core && swift test

# the Mac app, and run it
xcodegen generate
xcodebuild -project Fireworks.xcodeproj -scheme Fireworks -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/dd build
cp -R build/dd/Build/Products/Debug/Fireworks.app /Applications/ && open -a /Applications/Fireworks.app
```

Debug builds are ad-hoc signed, so they run on any Mac with no Apple account;
Release builds carry the App Group entitlements the widget and TestFlight need.

## Distribution

Signed with the Developer ID and notarized, shipped as a DMG and a Homebrew cask.
No sandbox on the Mac build (it reads a key from the Keychain and talks to one
API); the iOS build is App Store-bound and sandboxed, as iOS requires.

## Status

- [x] Engine: client, config, anchor math, day series, alerts, Keychain, snapshots
- [x] 45 engine tests (`swift test`)
- [x] Mac menu-bar app (running on a real Mac against the live API)
- [x] Notifications via `UNUserNotificationCenter`
- [x] WidgetKit extension written and embedded for macOS and iOS
- [x] iOS app target written
- [ ] Widget *visible* — needs release signing, see RELEASE.md
- [ ] iOS build + TestFlight — needs the Apple account, see RELEASE.md
- [ ] Notarized DMG + Homebrew cask — needs a Developer ID certificate

Signing, the App Group registration and TestFlight are documented step by step in
[RELEASE.md](RELEASE.md); each needs the Apple ID, so none of it is automatic.

The SwiftBar plugin lives at
[steveafrost/fireworks-menubar](https://github.com/steveafrost/fireworks-menubar)
and stays the reference implementation while the app is built.
