#!/usr/bin/env bash
#
# Builds, signs, notarises, staples and zips Paint.app for distribution.
#
#   ./Scripts/package-release.sh                # sign + notarise + staple
#   ./Scripts/package-release.sh --skip-notarize  # sign only, for a quick check
#
# Notary credentials are read from the environment, or from a gitignored
# .env.release.local next to this repo:
#
#   APPLE_ID=you@example.com
#   APPLE_TEAM_ID=AUNK4Y4APT
#   APPLE_APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx   # appleid.apple.com
#
# The app-specific password is never echoed and never leaves this machine.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEFAULT_TEAM_ID="AUNK4Y4APT"
SCHEME="Paint"
APP_NAME="Paint.app"
SKIP_NOTARIZE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

for env_file in "$ROOT_DIR/.env" "$ROOT_DIR/.env.release" "$ROOT_DIR/.env.release.local"; do
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
  fi
done

TEAM_ID="${APPLE_TEAM_ID:-${DEVELOPMENT_TEAM:-$DEFAULT_TEAM_ID}}"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight

command -v xcodegen >/dev/null || fail "xcodegen not found — brew install xcodegen"

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM_ID)"; then
  fail "No 'Developer ID Application' certificate for team $TEAM_ID in the keychain."
fi

BUILD_DIR="$ROOT_DIR/.build"
ARCHIVE="$BUILD_DIR/Paint.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DIST_DIR="$ROOT_DIR/dist"
APP="$EXPORT_DIR/$APP_NAME"

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# ------------------------------------------------------------------- build

step "Generating the Xcode project"
xcodegen generate >/dev/null

step "Archiving (Release)"
# Signing is deliberately left off the archive: Xcode treats automatic signing
# as *development* signing, so a Developer ID identity set here fights the
# project. The export step below applies it instead.
xcodebuild archive \
  -project Paint.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  | grep -E "^(===|\*\*)" || true

[[ -d "$ARCHIVE" ]] || fail "Archive was not produced."

step "Exporting with Developer ID"
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  | grep -E "^(===|\*\*|Exported)" || true

[[ -d "$APP" ]] || fail "Export did not produce $APP_NAME."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

# ------------------------------------------------------------------ verify

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

SIGN_INFO="$(codesign -dvv "$APP" 2>&1)"
grep -q "Authority=Developer ID Application" <<<"$SIGN_INFO" \
  || fail "Not signed with a Developer ID Application certificate."
grep -qE "flags=.*runtime" <<<"$SIGN_INFO" \
  || fail "Hardened runtime is off; the notary service will reject this build."
echo "  Authority: $(grep -m1 'Authority=' <<<"$SIGN_INFO" | cut -d= -f2-)"
echo "  Hardened runtime: on"
echo "  Version: $VERSION"

# --------------------------------------------------------------- notarize

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
  step "Skipping notarisation (--skip-notarize)"
else
  APPLE_ID_VALUE="${APPLE_ID:-${APPLE_NOTARY_APPLE_ID:-}}"
  APP_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-${APPLE_NOTARY_PASSWORD:-}}"

  if [[ -z "$APPLE_ID_VALUE" || -z "$APP_PASSWORD" ]]; then
    cat >&2 <<'MISSING'

✗ Notary credentials missing. Create .env.release.local with:

    APPLE_ID=you@example.com
    APPLE_TEAM_ID=AUNK4Y4APT
    APPLE_APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx

  Generate the app-specific password at appleid.apple.com ▸ Sign-In and
  Security ▸ App-Specific Passwords. The file is gitignored.

  Or re-run with --skip-notarize to produce a signed-but-unnotarised build.
MISSING
    exit 1
  fi

  step "Submitting to the Apple notary service (this takes a few minutes)"
  # notarytool rejects bare .app bundles, so submit a zip and staple the app.
  NOTARY_ZIP="$BUILD_DIR/notary-submit.zip"
  rm -f "$NOTARY_ZIP"
  ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"

  NOTARY_LOG="$BUILD_DIR/notary.json"
  set +e
  xcrun notarytool submit "$NOTARY_ZIP" \
    --apple-id "$APPLE_ID_VALUE" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD" \
    --wait \
    --output-format json > "$NOTARY_LOG"
  NOTARY_RC=$?
  set -e

  STATUS="$(/usr/bin/plutil -extract status raw -o - "$NOTARY_LOG" 2>/dev/null || echo unknown)"
  SUBMISSION_ID="$(/usr/bin/plutil -extract id raw -o - "$NOTARY_LOG" 2>/dev/null || echo '')"

  if [[ "$NOTARY_RC" -ne 0 || "$STATUS" != "Accepted" ]]; then
    echo "  Notarisation status: $STATUS" >&2
    if [[ -n "$SUBMISSION_ID" ]]; then
      echo "  Apple's log for submission $SUBMISSION_ID:" >&2
      xcrun notarytool log "$SUBMISSION_ID" \
        --apple-id "$APPLE_ID_VALUE" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" >&2 || true
    fi
    fail "Notarisation failed."
  fi
  echo "  Accepted (submission $SUBMISSION_ID)"

  step "Stapling the ticket"
  xcrun stapler staple "$APP" | sed 's/^/  /'

  step "Checking Gatekeeper"
  # This is the check a user's Mac performs on first launch.
  spctl --assess --type execute --verbose=4 "$APP" 2>&1 | sed 's/^/  /'
fi

# ------------------------------------------------------------------ package

step "Packaging"
ZIP="$DIST_DIR/Paint.zip"
rm -rf "$DIST_DIR/$APP_NAME" "$ZIP"
ditto "$APP" "$DIST_DIR/$APP_NAME"
ditto -c -k --keepParent "$DIST_DIR/$APP_NAME" "$ZIP"

printf '\n\033[32m✓ %s\033[0m\n' "dist/Paint.zip — version $VERSION, $(du -h "$ZIP" | cut -f1)"
if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  echo "  Signed, notarised and stapled: it opens with a double-click on any Mac."
  echo
  echo "  Publish it with:"
  echo "    gh release create v$VERSION dist/Paint.zip --title v$VERSION --notes-file <notes.md>"
else
  echo "  Signed but NOT notarised — Gatekeeper will still warn on other Macs."
fi
