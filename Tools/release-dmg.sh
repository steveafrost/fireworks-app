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
  echo "         --apple-id <your Apple ID> --team-id $TEAM"
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
mkdir -p build/release-evidence
rm -rf "$ARCHIVE" "$EXPORT"
# Sign nothing at archive time. Two separate reasons, both hit for real:
#   1. Forcing CODE_SIGN_IDENTITY on top of the project's automatic signing is
#      refused outright ("conflicting provisioning settings").
#   2. Letting Xcode sign the archive automatically demands a Mac App
#      *development* provisioning profile, and this team has no registered Mac
#      devices, so Xcode fails with "Your team has no devices from which to
#      generate a provisioning profile".
# The archive is therefore built unsigned and ALL signing happens in the export
# below, where the Developer ID profile applies. Developer ID profiles are not
# device-limited, so this route needs no device registration.
if ! xcodebuild -project Fireworks.xcodeproj -scheme Fireworks -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=YES \
  archive > build/release-evidence/archive.log 2>&1; then
  fail "archive failed:"
  grep -E "error:" build/release-evidence/archive.log | sort -u | head -10 | sed 's/^/  /'
  echo "     full log: build/release-evidence/archive.log"
  exit 1
fi
ok "archived unsigned → $ARCHIVE (signing happens at export)"

say "Exporting with the Developer ID profile"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist Config/ExportOptions-developer-id.plist \
  -allowProvisioningUpdates > build/release-evidence/export.log 2>&1; then
  fail "export failed:"
  grep -E "error:" build/release-evidence/export.log | sort -u | head -10 | sed 's/^/  /'
  echo "     full log: build/release-evidence/export.log"
  exit 1
fi
ok "exported, signed with: $IDENTITY"

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
# Staple the deliverable itself, not only the app inside it. Hash after stapling.
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
ok "$DMG"
echo "  sha256 $SHA"

say "Homebrew cask (build/fireworks.rb)"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@SHA256@/$SHA/g" \
  Tools/fireworks.rb.in | tee build/fireworks.rb

say "Next"
cat <<'NEXT'
  1. gh release create v<version> build/Fireworks-<version>.dmg --notes "…"
  2. Copy build/fireworks.rb into Casks/fireworks.rb in your Homebrew tap.
  3. Sign the final stapled DMG with Sparkle using the existing login-Keychain key:
       build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update build/Fireworks-<version>.dmg
     Then generate the feed entry for that same DMG; see RELEASING.md.
     Never publish an appcast item before its notarized artifact is available.
NEXT
