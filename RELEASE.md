# Releasing Fireworks

Two signing modes, because they answer different questions. Local development is
deliberately independent of the Apple account; distribution is not.

| | Identity | Entitlements | Needs a profile | What it gets you |
|---|---|---|---|---|
| **Debug** | ad-hoc (`-`) | none | no | Builds and runs on any Mac. What is running today. |
| **Release** | team identity | App Group | yes | The widget is registered, and the app can be distributed. |

## Why the widget needs release signing

A widget is an app extension, and app extensions are loaded by a plugin host
that insists on a sandboxed, *team-signed* extension. An ad-hoc signature reports
`TeamIdentifier=not set`, and an unsandboxed extension is rejected outright — so
on a Debug build `pluginkit -m -p com.apple.widgetkit-extension` never lists
`com.whitebox.fireworks.widgets`, and the widget cannot appear in the gallery, no
matter what the code does.

The extension must also be sandboxed, and a sandboxed extension can only read a
shared **App Group** — which is why the entitlements name
`group.com.whitebox.fireworks` and why the app writes there when it can. That
entitlement has to be authorised by a provisioning profile, which an ad-hoc
signature cannot supply. This is the same wall TestFlight sits behind, so it is
one piece of account work, not two.

## Account work (needs the Apple ID — cannot be automated)

Xcode on this Mac has signing identities but **no provisioning profiles at all**
(`~/Library/MobileDevice/Provisioning Profiles/` does not exist), so automatic
signing has nothing to fetch:

```
error: No profiles for 'com.whitebox.fireworks' were found: Xcode couldn't find
any Mac App Development provisioning profiles matching 'com.whitebox.fireworks'
error: Device "F12057 Laptop" isn't registered in your developer account.
```

In order:

1. **Pick the team.** Two are visible on this Mac and the project currently
   assumes the second:
   - `M3HCQ2Y3RS` — the team on *Apple Development: hello@steveafrost.com*
   - `4QJ25Y85MX` — the team on *Apple Distribution: STEVEN ALLEN FROST*
   Set it in `project.yml` → `settings.base.DEVELOPMENT_TEAM`.
2. **Sign in.** Xcode → Settings → Accounts → add the Apple ID for that team.
   This is what lets profiles be created at all.
3. **Register the App Group** `group.com.whitebox.fireworks` (developer.apple.com
   → Identifiers → App Groups), and attach it to three App IDs:
   `com.whitebox.fireworks`, `com.whitebox.fireworks.widgets`,
   `com.whitebox.fireworks.ios`, `com.whitebox.fireworks.ios.widgets`.
4. **Register this Mac** as a development device if the Mac profile asks for it.

Then release signing works:

```bash
xcodegen generate
xcodebuild -project Fireworks.xcodeproj -scheme Fireworks -configuration Release \
  -allowProvisioningUpdates build            # macOS
xcodebuild -project Fireworks.xcodeproj -scheme FireworksiOS -configuration Release \
  -allowProvisioningUpdates -destination 'generic/platform=iOS' build
```

## Install the running app

```bash
xcodebuild -project Fireworks.xcodeproj -scheme Fireworks -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/dd build
rm -rf /Applications/Fireworks.app
cp -R build/dd/Build/Products/Debug/Fireworks.app /Applications/
open -a /Applications/Fireworks.app
```

The app has no Dock icon and no window: it is the menu-bar item and its popover.

## Verifying the UI without a screenshot

Screen Recording permission is denied on this Mac, so `screencapture` returns an
empty image. The app can render its own panels offscreen instead:

```bash
/Applications/Fireworks.app/Contents/MacOS/Fireworks --render-ui /tmp/fireworks-ui --render-ui-sample
```

That writes `popover.png`, `popover-empty.png`, `settings.png` and `probe.png`
(`probe` lays the components out in isolation, so a rendering fault can be told
apart from a layout one). `--render-ui-sample` swaps in a synthetic reading so
low, critical and over-anchor states can be looked at without waiting for them.

Two limits, both of which have already been mistaken for app bugs: text drawn
directly onto the transparent canvas is dropped (every panel is therefore drawn
over an opaque fill), and `Toggle`/`Button`/`Link` come out as a placeholder
glyph. Use this for the numbers and the arrangement; check controls on screen.

## Settings and data

- Data folder: `~/Library/Application Support/Fireworks/` — `config.json`,
  `state.json` (the same shape the SwiftBar plugin used), `snapshot.json` (what
  the widget renders), `diagnostics.log`.
- On first run the app *copies* the SwiftBar plugin's `config.json` and
  `api_key` from `~/.config/fireworks-menubar/` if they exist, so the anchor and
  thresholds carry over. The originals are left untouched.
- The API key is read from the Keychain first (services `fireworks-menubar`,
  then `fireworks-app`), then `api_key` in the data folder, then
  `FIREWORKS_API_KEY`.

`diagnostics.log` is the first thing to read when a number does not appear:

```
2026-09-29T18:07:27Z  launch: data=… migrated=config.json,api_key anchored=true anchor=11.21@2026-09-25T17:30:00Z
2026-09-29T18:07:33Z  refresh: ok remaining=$9.69 spend=$1.52 today=$1.32 account=f12057 events=0
```

## Notarized distribution (outside the App Store)

Not possible yet: this Mac has no **Developer ID Application** certificate
(only Apple Development and Apple Distribution). Once it exists:

```bash
codesign --deep --force --options runtime --sign "Developer ID Application: …" Fireworks.app
ditto -c -k --keepParent Fireworks.app Fireworks.zip
xcrun notarytool submit Fireworks.zip --keychain-profile notary --wait
xcrun stapler staple Fireworks.app
hdiutil create -volname Fireworks -srcfolder Fireworks.app -ov -format UDZO Fireworks.dmg
```

Then a Homebrew cask pointing at the DMG.

## TestFlight

1. App Store Connect → new app, bundle id `com.whitebox.fireworks.ios`.
2. Archive and upload (`-allowProvisioningUpdates`, `-destination 'generic/platform=iOS'`).
3. TestFlight build for internal testing, install on the phone.

The iOS app currently fetches for itself on launch and on activation, and writes
its own snapshot for the iOS widget — the phone never reads the Mac's files, so
each device needs the key entered once (Settings → API key).
