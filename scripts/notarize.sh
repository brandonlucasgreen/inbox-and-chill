#!/bin/bash
#
# Notarize and staple a Release build, then emit a distributable zip.
#
# Notarization is the last step before Inbox & Chill can run on a Mac that
# isn't this one. Gatekeeper only evaluates *quarantined* apps — anything
# downloaded — so an unnotarized build works fine locally and is refused the
# moment someone else opens it. `spctl -a` saying "rejected — Unnotarized
# Developer ID" before this runs is expected, not a fault.
#
# One-time credential setup (Apple requires a person for this; it is not
# something this script can do):
#
#   xcrun notarytool store-credentials "inbox-and-chill" \
#     --apple-id "you@example.com" --team-id CV926C8KS8 \
#     --password "<app-specific password from appleid.apple.com>"
#
# An App Store Connect API key works too (--key/--key-id/--issuer). Either
# way the secret lands in your login keychain under the profile name, and
# nothing here ever sees it.
#
# Usage:
#   scripts/notarize.sh                    # build Release, notarize, staple
#   scripts/notarize.sh --app <path>       # notarize an app that already exists
#   scripts/notarize.sh --profile <name>   # keychain profile (default below)
#   scripts/notarize.sh --preflight-only   # check a build is submittable, no credentials needed
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Inbox & Chill.app"
PROFILE="${NOTARY_PROFILE:-inbox-and-chill}"
APP=""
PREFLIGHT_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --preflight-only) PREFLIGHT_ONLY=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# --- Credentials, checked before spending a build -------------------------
# Skipped for --preflight-only so a build can be checked for submittability
# without any credentials in play.
if [ "$PREFLIGHT_ONLY" -eq 0 ] && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
No notarization credentials stored under the profile "$PROFILE".

Create them once (this needs your Apple ID and an app-specific password
from appleid.apple.com → Sign-In and Security → App-Specific Passwords):

  xcrun notarytool store-credentials "$PROFILE" \\
    --apple-id "you@example.com" --team-id CV926C8KS8 \\
    --password "<app-specific password>"

Then run this script again. Override the profile name with --profile or
NOTARY_PROFILE if you already use a different one.
EOF
  exit 1
fi

# --- Build ----------------------------------------------------------------
if [ -z "$APP" ]; then
  echo "==> Building (Release)"
  xcodebuild -project InboxAndChill.xcodeproj -scheme InboxAndChill \
    -configuration Release build >/tmp/inchill-notarize-build.log 2>&1 || {
      echo "Build failed. Last 40 lines:" >&2
      tail -40 /tmp/inchill-notarize-build.log >&2
      exit 1
    }
  # Same reasoning as install-local.sh: ask xcodebuild, never guess. Every
  # worktree has its own DerivedData, and guessing notarizes the wrong build.
  BUILT_PRODUCTS_DIR=$(xcodebuild -project InboxAndChill.xcodeproj \
    -scheme InboxAndChill -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F ' = ' '/^ *BUILT_PRODUCTS_DIR = /{print $2; exit}')
  APP="$BUILT_PRODUCTS_DIR/$APP_NAME"
fi

[ -d "$APP" ] || { echo "No app at: $APP" >&2; exit 1; }
echo "    app: $APP"

# --- Preflight ------------------------------------------------------------
# Every one of these is a documented notarization rejection. Checking them
# here costs milliseconds; finding out from Apple costs a round trip and
# returns an error a long way from its cause.
echo "==> Preflight"
FAIL=0

SIGINFO=$(codesign -dvv "$APP" 2>&1 || true)
case "$SIGINFO" in
  *"flags=0x10000(runtime)"*) echo "    hardened runtime: on" ;;
  *) echo "    hardened runtime: MISSING (ENABLE_HARDENED_RUNTIME)" >&2; FAIL=1 ;;
esac
case "$SIGINFO" in
  *Timestamp=*) echo "    secure timestamp: present" ;;
  *) echo "    secure timestamp: MISSING (OTHER_CODE_SIGN_FLAGS=--timestamp)" >&2; FAIL=1 ;;
esac
case "$SIGINFO" in
  *"Developer ID Application"*) echo "    identity: Developer ID" ;;
  *) echo "    identity: NOT Developer ID — ad-hoc or development signing" >&2; FAIL=1 ;;
esac

if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  echo "    entitlements: get-task-allow PRESENT (CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)" >&2
  FAIL=1
else
  echo "    entitlements: no get-task-allow"
fi

codesign --verify --deep --strict "$APP" 2>/dev/null \
  && echo "    signature: valid (deep)" \
  || { echo "    signature: FAILED --verify --deep --strict" >&2; FAIL=1; }

[ "$FAIL" -eq 0 ] || { echo "Preflight failed; not submitting." >&2; exit 1; }

if [ "$PREFLIGHT_ONLY" -eq 1 ]; then
  echo "==> Preflight passed; build is submittable."
  exit 0
fi

# --- Submit ---------------------------------------------------------------
# notarytool takes an archive, not a bundle. ditto's --keepParent keeps the
# .app wrapper, which the service requires.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ZIP="$WORK/upload.zip"
echo "==> Submitting (this usually takes a few minutes)"
ditto -c -k --keepParent "$APP" "$ZIP"

SUBMIT_OUT="$WORK/submit.txt"
set +e
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$SUBMIT_OUT"
SUBMIT_RC=${PIPESTATUS[0]}
set -e

ID=$(awk '/^  id: /{print $2; exit}' "$SUBMIT_OUT")
if [ "$SUBMIT_RC" -ne 0 ] || ! grep -q "status: Accepted" "$SUBMIT_OUT"; then
  echo "==> Notarization did not succeed." >&2
  # The submission log is the only place that says *why*. "Invalid" on its
  # own is useless, so always fetch it.
  [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
  exit 1
fi

# --- Staple ---------------------------------------------------------------
# Stapling attaches the ticket to the bundle so it validates offline. The
# ticket goes on the .app — you cannot staple a zip — so this happens before
# the distributable archive is made.
echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Gatekeeper assessment"
spctl -a -vvv --type execute "$APP" 2>&1 | sed 's/^/    /'

# --- Distributable archive ------------------------------------------------
OUT_DIR="dist"
mkdir -p "$OUT_DIR"
VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.0.0")
OUT="$OUT_DIR/InboxAndChill-$VERSION.zip"
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"

echo "==> Done"
echo "    notarized and stapled: $APP"
echo "    distributable:         $OUT"
