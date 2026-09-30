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
remaining = the balance Fireworks reports                  # the figure
credited  = the account's paid invoices, added up          # what it is out of
```

Nothing is subtracted, and nothing is typed in. The balance comes from
`gateway.Gateway/GetBalance`; the total it is out of comes from
`gateway.Gateway/ListInvoices`, which returns the same three paid prepaid top-ups
`firectl billing list-invoices` prints (`$5 + $5 + $10 = $20.00` for this account).
An invoice that has been raised but not paid is excluded — it has no amount on it,
and an open invoice is not money in.

`credited` is what the percentages mean. The menu-bar dial's arc, the "% of the
credit" figure on the gauge and the warn-at-70/90% alerts are all measured against
what was paid in, so a top-up moves the denominator by itself instead of making the
remaining figure read too low. There is no balance field in Settings and no
balance toggle: the figure and the invoices behind it both come from Fireworks.
When the gateway cannot be reached the last balance it reported is shown, marked
`stale` under the bar, and the previous denominator is carried forward so an outage
does not empty the dial.

## Layout

| Path | What it is |
|---|---|
| `Core/` | Swift package: the whole engine, no UI, no third-party dependencies |
| `Core/Sources/FireworksCore/` | API client, balance + invoice gateway calls, config, credit ledger, day series, alert planning, key handling |
| `Core/Tests/FireworksCoreTests/` | 86 tests, no network, no simulator (`swift test`) |
| `project.yml` | XcodeGen spec for the app + widget targets (the `.xcodeproj` is generated, never committed) |
| `Mac/` | menu-bar app (no Dock icon, popover UI) |
| `iOS/` | iPhone/iPad app |
| `Shared/` | the app-side half: `AppModel`, notifications, diagnostics, views |
| `Widgets/` | WidgetKit extensions for both platforms |
| `RELEASE.md` | signing, App Group, notarization, TestFlight |
| `docs/appcast.xml` | the update feed the app reads (GitHub Pages, `docs/`) |
| `RELEASING.md` | how to cut an update: bump, archive, sign, generate the feed |

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
  that ran the plugin first, the app picks up the existing balance, thresholds and alert
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

The Mac app also updates itself, through [Sparkle](https://sparkle-project.org/):
it reads `docs/appcast.xml`, and verifies each release against the Ed25519 key in
`Mac/Info.plist` before offering it. Daily checks are on by default and can be
turned off in Settings → Updates. [RELEASING.md](RELEASING.md) is the runbook,
including where the signing key lives and why it needs backing up.

## Status

- [x] Engine: client, config, anchor math, day series, alerts, Keychain, snapshots
- [x] 76 engine tests (`swift test`)
- [x] Mac menu-bar app (running on a real Mac against the live API)
- [x] Settings as a sidebar of six panes (Account, Balance, Alerts, General,
      Updates, About) instead of one flat list of sections
- [x] Notifications via `UNUserNotificationCenter`
- [x] Self-updating via Sparkle: feed live on GitHub Pages, offer path verified
      from a 1.0 copy against a 1.1 feed, quiet by default (no window raised)
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
