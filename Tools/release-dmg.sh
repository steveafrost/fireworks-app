#!/bin/bash
# Build, sign, notarize and package the Mac app for people who are not us.
#
#   Tools/release-dmg.sh --check     # what is missing, without building anything
#   Tools/release-dmg.sh             # archive, notarize, staple, DMG, print the cask
#
# The only two things it cannot supply itself are the Developer ID Application
# certificate and a notary credential. Both live in the Apple account; `--check`
# names exactly which is missing. Everything after that is mechanical, and the
# script refuses to start without them rather than producing an unsigned DMG that
# looks finished.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
TEAM="4QJ25Y85MX"
IDENTITY_PREFIX="Developer ID Application"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
ARCHIVE="build/Fireworks-mac.xcarchive"
EXPORT="build/dist"
BUNDLE="com.whitebox.fireworks"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; }
ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- prerequisites

say "Prerequisites"

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "$IDENTITY_PREFIX" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
if [ -n "$IDENTITY" ]; then
  ok "signing identity: $IDENTITY"
else
  fail "no \"$IDENTITY_PREFIX\" certificate in the login keychain"
  echo "     Xcode → Settings → Accounts → (your Apple ID) → Manage Certificates"
  echo "     → + → Developer ID Application.  Then re-run this script."
  echo "     Available today: $(security find-identity -v -p codesigning 2>/dev/null | grep -c '"') identities, none of them Developer ID."
fi

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  ok "notary credential: keychain profile \"$NOTARY_PROFILE\""
else
  fail "no notary credential for keychain profile \"$NOTARY_PROFILE\""
  echo "     One of:"
  echo "       xcrun notarytool store-credentials $NOTARY_PROFILE \\"
  echo "         --apple-id <your Apple ID> --team-id $TEAM --password <app-specific password>"
  echo "       xcrun notarytool store-credentials $NOTARY_PROFILE \\"
  echo "         --key ~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 \\"
  echo "         --key-id XXXX --issuer <issuer id>"
fi

for tool in xcodegen hdiutil ditto shasum; do
  command -v "$tool" >/dev/null || { fail "$tool not found"; exit 1; }
done
ok "tooling present (xcodegen, hdiutil, ditto, shasum)"

if [ "${1:-}" = "--check" ]; then
  say "Check only — nothing built."
  [ -n "$IDENTITY" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    && { ok "ready to release"; exit 0; }
  echo "  Both prerequisites are account actions; see RELEASE.md."
  exit 1
fi

[ -n "$IDENTITY" ] || { fail "refusing to build an unsigned DMG"; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { fail "refusing to build a DMG that cannot be notarized"; exit 1; }

# ------------------------------------------------------------------- build

say "Generating the project"
xcodegen generate >/dev/null

say "Archiving (Release)"
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project Fireworks.xcodeproj -scheme Fireworks -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates archive 2>&1 | tail -3

say "Exporting with the Developer ID profile"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist Config/ExportOptions-developer-id.plist \
  -allowProvisioningUpdates 2>&1 | tail -3

APP="$EXPORT/Fireworks.app"
[ -d "$APP" ] || { fail "no app exported"; exit 1; }

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
say "Exported Fireworks $VERSION ($BUILD)"

# ------------------------------------------------------------------- verify

say "Verifying what was actually signed"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
codesign -dvv "$APP" 2>&1 | grep -E "Authority=|TeamIdentifier=" | sed 's/^/  /'
# The App Group is the whole reason the widget can read the app's data: if the
# entitlement is missing here the DMG ships a widget that draws nothing.
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "application-groups"; then
  ok "App Group entitlement present"
else
  fail "no App Group entitlement — the widget would ship empty"
  exit 1
fi
codesign -d --entitlements - "$APP/Contents/PlugIns/FireworksWidgets.appex" 2>/dev/null \
  | grep -q "application-groups" \
  && ok "widget extension carries the App Group too" \
  || { fail "widget extension has no App Group entitlement"; exit 1; }

# ------------------------------------------------------------------ notarize

say "Notarizing"
ZIP="$EXPORT/Fireworks-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

say "Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv -t install "$APP" 2>&1 | sed 's/^/  /'

# ---------------------------------------------------------------------- dmg

say "Packaging the DMG"
DMG="$REPO/build/Fireworks-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Fireworks" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
ok "$DMG"
echo "  sha256 $SHA"

say "Homebrew cask stanza"
cat <<CASK
cask "fireworks" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/steveafrost/fireworks-app/releases/download/v#{version}/Fireworks-#{version}.dmg"
  name "Fireworks"
  desc "Fireworks AI credit in the menu bar"
  homepage "https://github.com/steveafrost/fireworks-app"

  app "Fireworks.app"
end
CASK

say "Next"
cat <<'NEXT'
  1. gh release create v<version> build/Fireworks-<version>.dmg --notes "…"
  2. Publish the cask (a tap of your own, or a PR to homebrew/cask).
  3. Add the release to docs/appcast.xml so existing installs are offered it:
       Tools/sign_update build/Fireworks-<version>.zip   (Sparkle), then edit the feed.
NEXT
