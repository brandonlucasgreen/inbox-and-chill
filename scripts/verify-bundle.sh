#!/bin/bash
#
# Audit a built .app for the things that break *silently*.
#
# Every check here exists because something once shipped wrong and no build
# failure said so. The Info.plist ones are the sharpest: INFOPLIST_KEY_SUFeedURL
# compiled, linked, signed and shipped a bundle with **no SUFeedURL in it** —
# Sparkle would have had no feed to read, and nothing at any stage warned.
# CLAUDE.md rule 1 is the general form: only the built artifact settles it.
#
# Deliberately signing-agnostic, so CI can run it on an ad-hoc-signed build.
# The release path has a stricter superset in `scripts/notarize.sh` (its
# preflight also demands a Developer ID identity and a secure timestamp, which
# no CI runner can produce). The small overlap is intentional: this one runs on
# every pull request, that one runs once per release.
#
# Usage:
#   scripts/verify-bundle.sh                 # find the Release build and check it
#   scripts/verify-bundle.sh --app <path>    # check a specific .app
#   scripts/verify-bundle.sh --configuration Debug
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP=""
CONFIGURATION="Release"

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --configuration) CONFIGURATION="${2:-}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$APP" ]; then
  # Ask xcodebuild where it put the app rather than guessing a DerivedData
  # path — same reasoning as install-local.sh and notarize.sh. Every worktree
  # has its own, and guessing audits somebody else's build.
  BUILT_PRODUCTS_DIR=$(xcodebuild -project InboxAndChill.xcodeproj \
    -scheme InboxAndChill -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
    | awk -F ' = ' '/^ *BUILT_PRODUCTS_DIR = /{print $2; exit}')
  APP="$BUILT_PRODUCTS_DIR/Inbox & Chill.app"
fi

[ -d "$APP" ] || { echo "No app at: $APP" >&2; exit 1; }
echo "==> Auditing: $APP"

PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || { echo "No Info.plist in the bundle." >&2; exit 1; }

FAIL=0

note() { echo "    $1"; }
bad()  { echo "    $1" >&2; FAIL=1; }

# --- Info.plist -----------------------------------------------------------
# `plutil -extract` exits non-zero for a key that is absent, which is exactly
# the failure being guarded against, so the || is load-bearing rather than
# defensive noise.
plist_value() {
  plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null || true
}

expect_plist() {
  local key="$1" want="$2" got
  got=$(plist_value "$key")
  if [ -z "$got" ]; then
    bad "Info.plist: $key MISSING (expected \"$want\")"
  elif [ "$got" != "$want" ]; then
    bad "Info.plist: $key is \"$got\", expected \"$want\""
  else
    note "Info.plist: $key = $got"
  fi
}

expect_plist_present() {
  local key="$1" got
  got=$(plist_value "$key")
  if [ -z "$got" ]; then
    bad "Info.plist: $key MISSING"
  else
    note "Info.plist: $key present"
  fi
}

# project.yml is the single source of truth for both version numbers, so read
# the expected values from it rather than hardcoding them here — a hardcoded
# copy is one more thing to forget at release time.
yaml_scalar() {
  awk -F': *' -v key="$1" '
    $0 ~ "^[[:space:]]*"key":" { gsub(/^[ \t"]+|[ \t"]+$/, "", $2); print $2; exit }
  ' project.yml
}

MARKETING_VERSION=$(yaml_scalar MARKETING_VERSION)
PROJECT_VERSION=$(yaml_scalar CURRENT_PROJECT_VERSION)
DEPLOYMENT_TARGET=$(yaml_scalar MACOSX_DEPLOYMENT_TARGET)

# XcodeGen's plist defaults are the literals "1.0" and "1". Left unmapped they
# pin every build to 1.0 — which breaks the About pane, the filename
# notarize.sh gives the dist zip, and Sparkle's "is this newer?" comparison,
# so an update would be offered to nobody and nothing would say why.
expect_plist CFBundleShortVersionString "$MARKETING_VERSION"
expect_plist CFBundleVersion "$PROJECT_VERSION"
expect_plist LSMinimumSystemVersion "$DEPLOYMENT_TARGET"

# A menu bar app with no Dock icon. If this ever goes missing the app grows a
# Dock tile and an app switcher entry, which is a visible regression but an
# easy one to merge by accident.
expect_plist LSUIElement true

# Sparkle reads both of these out of the bundle at runtime. Neither absence
# produces an error the user would connect to updates.
expect_plist SUFeedURL "https://raw.githubusercontent.com/brandonlucasgreen/inbox-and-chill/main/appcast.xml"
expect_plist_present SUPublicEDKey

# Supplies the wording of the Automation consent prompt. Without it macOS
# denies the Apple event outright instead of asking, and the denial looks
# exactly like "nothing happened" (CLAUDE.md rule 2).
expect_plist_present NSAppleEventsUsageDescription
# EventKit crashes outright without this, and the Reminders source is dead
# without EventKit. Nothing else in the build would notice it missing.
expect_plist_present NSRemindersFullAccessUsageDescription

# --- Entitlements ---------------------------------------------------------
# Only meaningful on a signed bundle; an unsigned build carries none at all.
ENTITLEMENTS=$(codesign -d --entitlements - "$APP" 2>/dev/null || true)
if [ -z "$ENTITLEMENTS" ]; then
  note "entitlements: bundle is unsigned — skipped"
else
  case "$ENTITLEMENTS" in
    *"com.apple.security.automation.apple-events"*)
      note "entitlements: apple-events present" ;;
    *)
      bad "entitlements: apple-events MISSING — Apple events fail with -1743 and NO consent prompt" ;;
  esac
  # Xcode injects the debugger-attach entitlement unless told not to, and
  # notarization rejects a Developer ID binary carrying it.
  case "$ENTITLEMENTS" in
    *"get-task-allow"*)
      bad "entitlements: get-task-allow PRESENT (needs CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)" ;;
    *)
      note "entitlements: no get-task-allow" ;;
  esac
fi

# --- Hardened runtime -----------------------------------------------------
# Matched on the flags word rather than the literal `flags=0x10000(runtime)`,
# because the flags differ by signer: a Developer ID build reads
# `flags=0x10000(runtime)` and the ad-hoc build CI produces reads
# `flags=0x10002(adhoc,runtime)`. Pinning the literal would have made this
# check pass vacuously in CI — the exact failure mode it exists to catch.
SIGINFO=$(codesign -dvv "$APP" 2>&1 || true)
if [ -z "$SIGINFO" ] || ! printf '%s' "$SIGINFO" | grep -q "flags="; then
  note "hardened runtime: bundle is unsigned — skipped"
elif printf '%s' "$SIGINFO" | grep -qE 'flags=0x[0-9a-f]+\([^)]*runtime'; then
  note "hardened runtime: on"
else
  bad "hardened runtime: MISSING (ENABLE_HARDENED_RUNTIME)"
fi

# --- Nested code, by layout not by signature ------------------------------
# project.yml's "Re-sign Sparkle's nested helpers" phase walks a hardcoded list
# of paths and skips anything it cannot find. That skip is silent, so if
# Sparkle ever moves its helpers the phase passes vacuously and notarization
# is the first thing to object — a long way from the cause. Checking the paths
# exist is what turns that into a pull-request failure instead.
for RELATIVE in \
  "MacOS/inchill" \
  "Frameworks/Sparkle.framework" \
  "Frameworks/Sparkle.framework/Versions/Current/Autoupdate" \
  "Frameworks/Sparkle.framework/Versions/Current/Updater.app" ; do
  if [ -e "$APP/Contents/$RELATIVE" ]; then
    note "nested: $RELATIVE present"
  else
    bad "nested: $RELATIVE MISSING — layout changed; the re-signing phase in project.yml is no longer signing what it thinks"
  fi
done

# --- Signature integrity --------------------------------------------------
# Passes for an ad-hoc signature too (an ad-hoc signature is a valid
# signature), which is why the nested check above is by path and not by
# identity. Still worth running: it catches a broken seal, which is what an
# ExtractAppIntentsMetadata run after codesign produces.
if [ -n "$SIGINFO" ]; then
  if codesign --verify --deep --strict "$APP" 2>/dev/null; then
    note "signature: valid (deep, strict)"
  else
    bad "signature: FAILED --verify --deep --strict"
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  echo "==> Bundle audit FAILED." >&2
  exit 1
fi
echo "==> Bundle audit passed."
