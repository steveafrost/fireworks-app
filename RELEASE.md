# Releasing Fireworks

Two signing modes, because they answer different questions. Local development is
deliberately independent of the Apple account; distribution is not.

| | Identity | Entitlements | Needs a profile | What it gets you |
|---|---|---|---|---|
| **Debug** | ad-hoc (`-`) | none | no | Builds and runs on any Mac. What is running today. |
| **Release** | team identity | App Group | yes | The widget is registered, and the app can be distributed. |

## Why the widget needs release signing

Registration alone is not proof of a working widget: on this Mac, `pluginkit`
lists the ad-hoc extension. The installed widget has no App Group entitlement
and its shared container does not exist. A distribution build must authorize
`group.com.whitebox.fireworks` on both app and extension, then the running app
must write a snapshot there. Only seeing that data drawn by the real widget
proves the complete path works.

The extension must also be sandboxed, and a sandboxed extension can only read a
shared **App Group** — which is why the entitlements name
`group.com.whitebox.fireworks` and why the app writes there when it can. That
entitlement has to be authorised by a provisioning profile, which an ad-hoc
signature cannot supply. This is the same wall TestFlight sits behind, so it is
one piece of account work, not two.

## The team, and what is already provisioned

**Team `4QJ25Y85MX`** — the one that has TipTrack deployed. Verified from the App
Store profile on this Mac:

```
$ security cms -D -i "~/Library/Developer/Xcode/UserData/Provisioning Profiles/146b79e6-....mobileprovision" | plutil -extract Name raw -
TipTrack App Store Profile
4QJ25Y85MX
4QJ25Y85MX.com.steveafrost.tiptrack
```

Xcode keeps profiles in `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`
(*not* `~/Library/MobileDevice/`), which is why an earlier check wrongly concluded
there were none. The same team also holds `com.whitebox.fluency`,
`com.steveafrost.TimeShadow`, `PocketAquarium`, `ScreenTimeWrapped`, `knightschool`
and a wildcard `iOS Team Provisioning Profile: *`.

With `-allowProvisioningUpdates`, automatic signing **created the App ID, the App
Group and the profiles**, so the iOS side needs nothing further:

```
$ codesign -d --entitlements - build/ipa/.../Fireworks.app
  application-identifier            4QJ25Y85MX.com.whitebox.fireworks.ios
  com.apple.security.application-groups  group.com.whitebox.fireworks
  beta-reports-active               true
  get-task-allow                    false
```

## iOS: archive and export (works today)

```bash
xcodegen generate
xcodebuild -project Fireworks.xcodeproj -scheme FireworksiOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Fireworks.xcarchive \
  -allowProvisioningUpdates archive

xcodebuild -exportArchive -archivePath build/Fireworks.xcarchive \
  -exportPath build/ipa -exportOptionsPlist Config/ExportOptions.plist -allowProvisioningUpdates
```

Verified: `** ARCHIVE SUCCEEDED **`, `** EXPORT SUCCEEDED **`, producing
`build/ipa/Fireworks.ipa`, signed with *Apple Distribution: STEVEN ALLEN FROST
(4QJ25Y85MX)*, `get-task-allow=false`, `beta-reports-active=true` — a TestFlight
upload payload.

## What remains for TestFlight

1. An App Store Connect app record for `com.whitebox.fireworks.ios` (portrait
   phone app; category Utilities or Developer Tools).
2. An upload credential: an App Store Connect **API key** (`.p8` + key id +
   issuer id, placed in `~/.appstoreconnect/private_keys/`), then:

   ```bash
   xcrun altool --upload-app -f build/ipa/Fireworks.ipa -t ios \
     --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
   ```

   Or open the archive in Xcode's Organizer and press Distribute — two clicks,
   no credential leaves the GUI.
3. TestFlight → internal testing group → install on the phone.

## The Mac widget: what actually blocks it

Not registration, as this file used to say. On macOS 27 the extension *is*
registered by LaunchServices even from the ad-hoc build:

```
$ pluginkit -m -A -D -v -i com.whitebox.fireworks.widgets
     com.whitebox.fireworks.widgets(1.0)  …  /Applications/Fireworks.app/Contents/PlugIns/FireworksWidgets.appex
```

What it cannot do is *read anything*. The widget draws from the App Group
container, and an ad-hoc signed app cannot create one:

```
$ ls ~/Library/Group\ Containers/group.com.whitebox.fireworks/
(no group container — an ad-hoc app cannot create one)
```

`codesign -d --entitlements - FireworksWidgets.appex` confirms why: the ad-hoc
build carries `app-sandbox` and `get-task-allow` and no
`application-groups` entitlement, because no provisioning profile authorises it.
So the widget either does not appear in the gallery or appears and draws its
empty state.

The fix is the same piece of account work as distribution, and the
**Developer ID route needs no device registration** — Developer ID provisioning
profiles are not device-limited, unlike a Mac *development* profile:

```bash
Tools/release-dmg.sh --check     # names exactly what is missing
Tools/release-dmg.sh             # archive → sign → notarize → staple → DMG → cask stanza
```

Registering this Mac as a device is only needed to make a *development* build
team-signed (Xcode → the Fireworks target → Signing & Capabilities → tick
*Automatically manage signing*). The Login Item (`SMAppService`) has the same
requirement, so it stays out until one of the two is done.

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
Tools/release-dmg.sh --check
Tools/release-dmg.sh
```

The script explicitly archives with Developer ID and hardened runtime, exports
with the Developer ID provisioning profile, checks both App Group entitlements,
and notarizes/staples the app **and final DMG**. It computes the SHA-256 only
after stapling, then renders `Tools/fireworks.rb.in` into `build/fireworks.rb`.
The template is intentionally not installable before a real artifact exists.
Copy the generated cask to `Casks/fireworks.rb` in a tap only after publishing
the matching DMG. These post-credential stages still require an end-to-end run;
offline contract tests are not evidence of notarization.

Use `xcrun notarytool store-credentials notary --apple-id <APPLE_ID> --team-id
4QJ25Y85MX` in your own terminal, letting its secure prompt receive the
app-specific password. Never put a password in a command or shell history.
`xcrun notarytool history --keychain-profile notary` must then succeed.

## TestFlight

1. App Store Connect → new app, bundle id `com.whitebox.fireworks.ios`.
2. Archive and upload (`-allowProvisioningUpdates`, `-destination 'generic/platform=iOS'`).
3. TestFlight build for internal testing, install on the phone.

The iOS app currently fetches for itself on launch and on activation, and writes
its own snapshot for the iOS widget — the phone never reads the Mac's files, so
each device needs the key entered once (Settings → API key).
