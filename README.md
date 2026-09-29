# Fireworks

Remaining Fireworks AI credit in your menu bar, in a widget, and on your iPhone.

Fireworks is prepaid, and its **REST** API returns rated **cost**, not
**balance** — every balance-shaped route answers 404 (`billing/summary`,
`billing/balance`, `balance`, `credits`, `billing/usage` were each re-measured
against the live API).

The balance does exist, though, on the *control-plane gateway*: Fireworks' own
CLI is a gRPC client, and `firectl account get` prints `Balance: USD 7.75` from
`gateway.Gateway/GetBalance` on `gateway.fireworks.ai` — authenticated with the
same API key, in an `x-api-key` header rather than a bearer token. That call is
HTTP/2, which `URLSession` already speaks, and the message is two fields wide, so
the app reads the real figure with no gRPC library and no generated protos (see
`Core/Sources/FireworksCore/Balance.swift`).

```
remaining = the account's real balance          # preferred
remaining = anchor_balance − rated spend        # fallback, and all there used to be
```

So the number is now the one Fireworks reports, and the anchor is only what
stands in when the gateway cannot be reached — a distinction the popover makes
explicit (`live balance` vs `anchor estimate` in the line under the credit bar).
A first run adopts the live balance as its anchor, so a fresh install no longer
has to be taught a figure the API will hand over, and the anchor is never
overwritten once it exists. Turning the call off in Settings leaves the old
subtraction and makes no request to the gateway.

Credit *added* is available too, from the same gateway (`ListInvoices` returns the
prepaid top-ups: they are what `firectl billing list-invoices` prints). Not read
yet — the balance alone is enough to stop guessing.

## Layout

| Path | What it is |
|---|---|
| `Core/` | Swift package: the whole engine, no UI, no third-party dependencies |
| `Core/Sources/FireworksCore/` | API client, balance gateway call, config, anchor math, day series, alert planning, key handling |
| `Core/Tests/FireworksCoreTests/` | 68 tests, no network, no simulator (`swift test`) |
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

To look at the UI without screen-recording permission (which this Mac denies):

```bash
/Applications/Fireworks.app/Contents/MacOS/Fireworks --render-ui /tmp/fireworks-ui --render-ui-sample
```

Add `--render-ui-dark` to render every panel in both appearances. The renderer
pins the content to its ideal height and the appearance is injected into the
environment, so the images match the popover rather than the harness.

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
- [x] iOS app builds, launches and measures (verified in the simulator against
      the live API: `remaining=$9.47 spend=$1.74 today=$1.54 account=f12057`)
- [x] Release signing: team `4QJ25Y85MX`, App Group granted, `Fireworks.ipa`
      exported with an Apple Distribution certificate
- [ ] TestFlight upload — needs the App Store Connect record and an upload key
- [ ] Widget *visible on the Mac* — needs this Mac registered as a device
- [ ] Notarized DMG + Homebrew cask — needs a Developer ID certificate

[RELEASE.md](RELEASE.md) has the commands, the verified output, and exactly what
still needs the Apple account.

The SwiftBar plugin lives at
[steveafrost/fireworks-menubar](https://github.com/steveafrost/fireworks-menubar)
and stays the reference implementation while the app is built.
