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
#   scripts/notarize.sh --skip-dmg         # zip only; skip the DMG and its extra round trip
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Inbox & Chill.app"
PROFILE="${NOTARY_PROFILE:-inbox-and-chill}"
APP=""
PREFLIGHT_ONLY=0
SKIP_DMG=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --preflight-only) PREFLIGHT_ONLY=1; shift ;;
    --skip-dmg) SKIP_DMG=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# --- Credentials, checked before spending a build -------------------------
# Skipped for --preflight-only so a build can be checked for submittability
# without any credentials in play.
# "Couldn't read it" and "it isn't there" are the same message from notarytool
# ("No Keychain password item found for profile"), and the difference matters:
# store-credentials defaults to the iCloud "Local Items" keychain, which is
# unlocked independently of the login keychain and answers itemNotFound while
# it is unavailable. That message has twice been read as "the credentials were
# deleted" when they were sitting there the whole time. So: retry once, and if
# it still fails, say what is actually known rather than asserting deletion.
CREDS_OK=0
if [ "$PREFLIGHT_ONLY" -eq 0 ]; then
  for attempt in 1 2; do
    if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
      CREDS_OK=1; break
    fi
    [ "$attempt" -eq 1 ] && sleep 2
  done
fi

if [ "$PREFLIGHT_ONLY" -eq 0 ] && [ "$CREDS_OK" -eq 0 ]; then
  cat >&2 <<EOF
Could not read notarization credentials for the profile "$PROFILE".

This does NOT necessarily mean they are gone. notarytool says the same thing
whether the item is missing or merely unreadable, and by default the item
lives in the iCloud "Local Items" keychain, which:

  - the \`security\` command cannot list at all, so "security find-generic-password
    finds nothing" is NOT evidence of deletion, and
  - locks when the Mac SLEEPS, and a DarkWake does not unlock it, so an
    unattended run answers "not found" through no fault of yours.

If the Mac has been idle, wake it and run this again — that alone usually
fixes it.

Check what is really there before re-creating anything:

  xcrun notarytool history --keychain-profile "$PROFILE" --verbose

A line reading 'Found Keychain password item' means the credentials exist and
this was a transient read failure — just run this script again.

If it genuinely reports no item, re-create them. Consider pinning them to the
file-based login keychain, which is visible to \`security\`, backed up by Time
Machine, and not subject to Local Items locking:

  xcrun notarytool store-credentials "$PROFILE" --team-id CV926C8KS8 \\
    --keychain "\$HOME/Library/Keychains/login.keychain-db"


Either way it needs your Apple ID and an app-specific password from
appleid.apple.com → Sign-In and Security → App-Specific Passwords:

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
  # `clean` is deliberate. An incremental Release build can run
  # ExtractAppIntentsMetadata *after* the app is signed, which rewrites
  # Contents/Resources/Metadata.appintents/extract.actionsdata and breaks the
  # seal — the preflight below then refuses to submit, a long way from the
  # cause. Observed 2026-08-21. A release is rare and has to describe one
  # known state anyway, so it pays the few extra minutes.
  echo "==> Building (Release, clean)"
  xcodebuild -project InboxAndChill.xcodeproj -scheme InboxAndChill \
    -configuration Release clean build >/tmp/inchill-notarize-build.log 2>&1 || {
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

# Nested code, one item at a time.
#
# This exists for a specific trap. Sparkle.framework carries Autoupdate,
# Updater.app and two XPC services *inside* it, and Xcode's embed step
# re-signs only the framework bundle — leaving those four **ad-hoc signed
# with no secure timestamp**. Nothing above catches that: an ad-hoc signature
# is a valid signature, so `--verify --deep --strict` is perfectly happy, and
# the app runs and self-updates fine on this machine. Notarization is the
# first thing that says no, and it says it a long way from the cause.
# project.yml's "Re-sign Sparkle's nested helpers" phase is the fix; this is
# the regression guard for it. Verified broken-then-fixed 2026-08-21.
NESTED=()
[ -f "$APP/Contents/MacOS/inchill" ] && NESTED+=("$APP/Contents/MacOS/inchill")
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  SPARKLE_DIR="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
  NESTED+=(
    "$APP/Contents/Frameworks/Sparkle.framework"
    "$SPARKLE_DIR/Autoupdate"
    "$SPARKLE_DIR/Updater.app"
    "$SPARKLE_DIR/XPCServices/Downloader.xpc"
    "$SPARKLE_DIR/XPCServices/Installer.xpc"
  )
fi

for ITEM in ${NESTED[@]+"${NESTED[@]}"}; do
  if [ ! -e "$ITEM" ]; then
    # A guard that skips what it cannot find passes vacuously — which is how
    # this whole class of bug got here. Autoupdate and Updater.app have shipped
    # in every Sparkle 2.x, so their absence means the layout moved and this
    # check is no longer looking at the right places. Say so and fail; the XPC
    # services are genuinely optional, so they only get a note.
    case "$ITEM" in
      *XPCServices*)
        echo "    nested: ${ITEM#"$APP/Contents/"} absent (optional)" ;;
      *)
        echo "    nested: ${ITEM#"$APP/Contents/"} MISSING — Sparkle's layout changed;" >&2
        echo "            this preflight is no longer checking what it thinks." >&2
        FAIL=1 ;;
    esac
    continue
  fi
  LABEL="${ITEM#"$APP/Contents/"}"
  ITEM_INFO=$(codesign -dvv "$ITEM" 2>&1 || true)
  PROBLEMS=""
  case "$ITEM_INFO" in *adhoc*) PROBLEMS="$PROBLEMS ad-hoc-signed" ;; esac
  case "$ITEM_INFO" in *"Developer ID Application"*) ;; *) PROBLEMS="$PROBLEMS not-Developer-ID" ;; esac
  case "$ITEM_INFO" in *"flags=0x10000(runtime)"*) ;; *) PROBLEMS="$PROBLEMS no-hardened-runtime" ;; esac
  case "$ITEM_INFO" in *Timestamp=*) ;; *) PROBLEMS="$PROBLEMS no-secure-timestamp" ;; esac
  if [ -n "$PROBLEMS" ]; then
    echo "    nested: $LABEL —$PROBLEMS" >&2
    FAIL=1
  else
    echo "    nested: $LABEL ok"
  fi
done

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

# --- DMG, for people rather than for Sparkle ------------------------------
# Sparkle updates from the zip — nothing to mount, no user interaction. A
# human downloading the app for the first time gets the DMG, which is the
# format a Mac user expects and which carries the drag-to-Applications window.
#
# The DMG is notarized and stapled in its own right. The app inside it already
# is, which is what makes the *app* open cleanly, but the disk image is itself
# the quarantined thing that gets double-clicked first, so it needs its own
# ticket to be trusted with no network.
if [ "$SKIP_DMG" -eq 0 ]; then
  # Deliberately a subdirectory rather than beside the zip: generate_appcast
  # treats every archive in its source directory as a release, so a .dmg and a
  # .zip of the same version side by side would yield two feed entries for one
  # release.
  DMG_DIR="$OUT_DIR/dmg"
  mkdir -p "$DMG_DIR"
  DMG="$DMG_DIR/InboxAndChill-$VERSION.dmg"
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  echo "==> Building $DMG"
  hdiutil create -volname "Inbox & Chill" -srcfolder "$STAGE" \
    -ov -quiet -format UDZO "$DMG"
  rm -rf "$STAGE"

  echo "==> Notarizing the DMG (a second round trip)"
  DMG_OUT="$WORK/submit-dmg.txt"
  set +e
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$DMG_OUT"
  DMG_RC=${PIPESTATUS[0]}
  set -e
  DMG_ID=$(awk '/^  id: /{print $2; exit}' "$DMG_OUT")
  if [ "$DMG_RC" -ne 0 ] || ! grep -q "status: Accepted" "$DMG_OUT"; then
    echo "==> The DMG was not notarized." >&2
    [ -n "$DMG_ID" ] && xcrun notarytool log "$DMG_ID" --keychain-profile "$PROFILE" >&2 || true
    exit 1
  fi
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

echo "==> Done"
echo "    notarized and stapled: $APP"
echo "    for Sparkle:           $OUT"
[ "$SKIP_DMG" -eq 0 ] && echo "    for people:            $DMG"
