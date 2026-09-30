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

## What the first real Developer ID run actually hit (2026-09-30)

With the certificate and the notary credential in place, the script reached a
Developer ID-signed export and then refused to ship — correctly:

```
✓ archived unsigned → build/Fireworks-mac.xcarchive (signing happens at export)
✓ exported, signed with: Developer ID Application: Steve Frost (4QJ25Y85MX)
  Authority=Developer ID Application: Steve Frost (4QJ25Y85MX)
  TeamIdentifier=4QJ25Y85MX
✗ no App Group entitlement — the widget would ship empty
```

Four findings, each of which cost a run to learn:

1. **The archive must not be signed by Xcode's automatic signing.** Doing so
   demands a Mac App *development* profile, and this team has no registered Mac
   devices, so Xcode refuses: *"Your team has no devices from which to generate a
   provisioning profile."* The archive is therefore built with
   `CODE_SIGNING_ALLOWED=NO` and every signature is applied at export.
2. **Do not force `CODE_SIGN_IDENTITY` on top of automatic signing** — Xcode
   refuses the archive outright with *"conflicting provisioning settings"*.
3. **The Developer ID export signs with the bare certificate and silently strips
   the App Group entitlement** when no profile authorises it: the exported app has
   no `embedded.provisionprofile` and an empty entitlements dict, and the export
   still prints `** EXPORT SUCCEEDED **`. Nothing warns you. That is why the
   script verifies the *exported* entitlements instead of trusting the export.
4. **The App Group ID is registered, and the iOS side is already authorised.**
   The iOS profiles on this Mac do carry `com.apple.security.application-groups`,
   and the TestFlight IPA's app *and* widget both carry it. What is missing is the
   **macOS App IDs** (`com.whitebox.fireworks`, `com.whitebox.fireworks.widgets`)
   with the App Groups capability: no Mac profile exists at all, which is why the
   Mac export cannot authorise the claim.

An ad-hoc archive cannot carry the entitlement either — Xcode rejects it with
*"requires a provisioning profile"*, because App Groups is a restricted
entitlement. `group.`-prefixed IDs are valid on macOS (Apple Developer Forums,
Feb 2025), so the identifier itself needs no change.

Registering this Mac as a device (`00006040-001A41141EF8801C`, done 2026-09-30)
fixed most of it: Xcode now provisions the Mac targets, creates the two macOS App
IDs and mints `Mac Team Direct Provisioning Profile: com.whitebox.fireworks` and
`…widgets`. The pipeline then ran end to end — signed archive, Developer ID export
carrying the App Group on the app *and* the widget, notarized and stapled app,
signed notarized stapled DMG, rendered cask:

```
✓ App Group entitlement present
✓ widget extension carries the App Group too
  status: Accepted                      (notary service)
build/Fireworks-1.0.dmg: accepted       (spctl, source=Notarized Developer ID)
```

**One thing device registration did not do: enable the App Groups capability on
the macOS App IDs.** Both Mac profiles carried only `application-identifier`,
`team-identifier` and `keychain-access-groups` — no `application-groups`. The
entitlement is therefore *unauthorised*, which macOS tolerates in the signature
and then refuses at runtime: `containerURL(forSecurityApplicationGroupIdentifier:)`
returns nil, so the app writes to Application Support instead and the widget has
nothing to read. The symptom reads like an app bug; the cause is a missing
capability on the App ID.

Fixed by hand in the portal (2026-09-30): App Groups on both macOS App IDs with
`group.com.whitebox.fireworks` assigned. The regenerated profiles then authorise
it, and the installed app moved its data into the shared container on its next
launch:

```
com.apple.security.application-groups => [ "group.com.whitebox.fireworks", "4QJ25Y85MX.*" ]
launch: data=/Users/stevefrost/Library/Group Containers/group.com.whitebox.fireworks/Fireworks
```

**Verifying that is harder than it looks.** macOS 15+ protects app group
containers from processes outside the group, so listing one fails with *"Operation
not permitted"* — and with stderr suppressed that looks exactly like an empty
container, which is the wrong conclusion to draw. Read the app's own os_log
instead (it logs `launch: data=…` as public):

```bash
log show --predicate 'subsystem == "com.whitebox.fireworks"' --last 10m --style compact | grep -E "launch:|refresh:"
```

A signed probe works too: compile a small binary, sign it with
`Mac/Fireworks.entitlements`, and `containerURL(…)` resolves — but enumeration is
still denied, so a probe can prove authorisation, never contents. What proves the
app can write is its own `isUsable` probe (create, write, remove), which is what
chose the container in the first place. The Login Item (`SMAppService`) needs the
same team-signed footing.

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
