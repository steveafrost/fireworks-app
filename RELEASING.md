# Releasing Fireworks

The Mac app updates itself with [Sparkle](https://sparkle-project.org/): it reads
an appcast feed, and verifies each release's signature against the Ed25519 public
key compiled into it. Nothing here needs an App Store account, but nothing here
can be undone either — a release signed with a key that does not match
`SUPublicEDKey` is a release nobody can install.

## What is already set up

| Piece | Where |
|---|---|
| Feed URL | `SUFeedURL` in `Mac/Info.plist` → `https://steveafrost.github.io/fireworks-app/appcast.xml` |
| Public key | `SUPublicEDKey` in `Mac/Info.plist` → `7XYFIMpgTrJrclrx/iIiVK8pH1l5oz7WRnEEZS59Nqg=` |
| Private key | The login Keychain, item `https://sparkle-project.org` (written by `generate_keys`) |
| Feed | `docs/appcast.xml`, served by GitHub Pages from this repo's `docs/` folder |

**Back the private key up.** It lives only in this Mac's login Keychain, and every
future release must be signed with it. To export a copy (treat it like a
password — 1Password, not a repo):

```sh
cd ~/.hermes/cache/scratch/fw/sparkle-tools   # or wherever Sparkle's bin/ lives
./bin/generate_keys -x ~/Desktop/fireworks-sparkle-private-key.txt
# restore it on another machine with: ./bin/generate_keys -f <file>
```

Losing it means shipping a new public key inside the app — which only reaches
people who already have the app if the *next* release is signed with the old key.
Practically: keep the backup.

## Notarized DMG release (preferred)

Use `Tools/release-dmg.sh --check`, then `Tools/release-dmg.sh`. The script
archives with Developer ID and hardened runtime, notarizes/staples the app and
DMG, and writes the final cask to `build/fireworks.rb`. A missing certificate or
notary credential stops it before building. Do not substitute an ad-hoc archive.

Only after that script succeeds (replace `1.0` with the actual release version):

```sh
SPARKLE=build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin
xcrun stapler validate build/Fireworks-1.0.dmg
"$SPARKLE/sign_update" --account ed25519 build/Fireworks-1.0.dmg
mkdir -p build/publish
cp build/Fireworks-1.0.dmg build/publish/
"$SPARKLE/generate_appcast" --account ed25519 \
  --download-url-prefix "https://github.com/steveafrost/fireworks-app/releases/download/v1.0/" \
  -o build/publish/appcast.xml build/publish
```

Use a staging directory containing only verified release artifacts. The tools
read the existing login-Keychain signing key; do not export or regenerate it.
Publish the DMG, read back the release asset and verify its hash, then copy the
staged appcast to `docs/appcast.xml` and publish the feed. Copy the generated
cask to `Casks/fireworks.rb` in your tap. Until notarization succeeds, leave the
feed empty: no fabricated signature, checksum, or placeholder release entry.
For already-installed builds to receive an update, the release build number
must be higher than theirs; a same-number first release will not be offered.

## Cutting a release

1. **Bump the version.** Both numbers, in `project.yml`:

   ```yaml
   MARKETING_VERSION: "1.1"      # what people see
   CURRENT_PROJECT_VERSION: "2"  # what Sparkle compares — must increase
   ```

   `CFBundleVersion` (`CURRENT_PROJECT_VERSION`) is the one that matters: Sparkle
   offers an update when the feed's is *higher*, and ignores a rebuild of the same
   number.

2. **Build and archive the Release configuration**, which is the one that carries
   a real signing identity and the App Group entitlement:

   ```sh
   xcodegen generate
   xcodebuild -project Fireworks.xcodeproj -scheme Fireworks -configuration Release \
     -destination 'platform=macOS' -archivePath build/Fireworks.xcarchive archive
   ```

   Export a signed copy, then zip it (Sparkle updates a `.zip` or a `.dmg`; the zip
   preserves the signature and is what the app has always used):

   ```sh
   ditto -c -k --sequesterRsrc --keepParent \
     build/export/Fireworks.app build/releases/Fireworks-1.1.zip
   ```

3. **Generate the feed.** `generate_appcast` signs the archive with the Keychain
   key and writes the appcast; it refuses to publish an unsigned one:

   ```sh
   SPARKLE=~/.hermes/cache/scratch/fw/sparkle-tools/bin
   $SPARKLE/generate_appcast \
     --download-url-prefix "https://github.com/steveafrost/fireworks-app/releases/download/v1.1/" \
     --output docs/appcast.xml build/releases
   ```

   Sanity-check that the item carries `<sparkle:edSignature>` and
   `<enclosure ... length=...>`; without both, the app rejects it.

4. **Publish the archive**, as a GitHub release tagged `v1.1`, and attach
   `build/releases/Fireworks-1.1.zip` (the URL must match the prefix in step 3).

5. **Publish the feed:** commit `docs/appcast.xml` and push. Pages serves it
   within a minute or so:

   ```sh
   curl -sI https://steveafrost.github.io/fireworks-app/appcast.xml | head -1
   ```

6. **Verify from an old copy**, which is the only test that counts. Keep the
   previous version installed somewhere, launch it, and use **Check Now** in
   Settings → Updates (or wait for the daily check). It should offer the new
   version, download it, verify the signature, and relaunch.

## Testing without shipping

Sparkle's own tools can sign a throwaway build, and the app will happily offer it
if the feed's build number is higher than the installed one. That is exactly how
to prove the whole path works before a real release — but publish such a feed only
to a test repo, or every copy of the app will be offered the test build.

## Turning updates off

Settings → Updates has "Check for updates automatically"; Sparkle remembers the
choice per user. `SUEnableAutomaticChecks` in `Mac/Info.plist` is only the
*initial* default, so a fresh install checks once a day without being asked.
