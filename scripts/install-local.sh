#!/bin/bash
#
# Build Inbox & Chill and install it to /Applications like a real user would
# have it — signed with Developer ID, in a stable location.
#
# Why not just run it from DerivedData? macOS ties Keychain ACLs, TCC
# permissions, and firewall decisions to a binary's code signature *and*
# path. A DerivedData path contains a random hash and changes whenever
# DerivedData is cleaned, so every rebuild looks like a different app and
# re-prompts for everything. /Applications + Developer ID = decisions stick.
#
# Usage:
#   scripts/install-local.sh            # Release build (the real thing)
#   scripts/install-local.sh --debug    # Debug build (adds the fake connector)
#   scripts/install-local.sh --no-launch
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="Release"
LAUNCH=1
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIGURATION="Debug" ;;
    --release) CONFIGURATION="Release" ;;
    --no-launch) LAUNCH=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="Inbox & Chill.app"
BUNDLE_ID="lol.bgreen.inboxandchill"
INSTALL_DIR="/Applications"
DEST="$INSTALL_DIR/$APP_NAME"

echo "==> Generating Xcode project"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi
xcodegen generate >/dev/null

echo "==> Building ($CONFIGURATION)"
xcodebuild -project InboxAndChill.xcodeproj -scheme InboxAndChill \
  -configuration "$CONFIGURATION" build >/tmp/inchill-build.log 2>&1 || {
    echo "Build failed. Last 40 lines:" >&2
    tail -40 /tmp/inchill-build.log >&2
    exit 1
  }

# Ask xcodebuild where it put the app rather than scraping the log or
# globbing DerivedData. Both of those pick by *text order* or *name order*,
# and every git worktree gets its own DerivedData directory — so from a
# worktree they happily resolve to another checkout's stale build and
# `ditto` installs an app that does not contain your changes.
BUILT_PRODUCTS_DIR=$(xcodebuild -project InboxAndChill.xcodeproj \
  -scheme InboxAndChill -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
  | awk -F ' = ' '/^ *BUILT_PRODUCTS_DIR = /{print $2; exit}')
BUILT="$BUILT_PRODUCTS_DIR/$APP_NAME"
[ -n "$BUILT_PRODUCTS_DIR" ] && [ -d "$BUILT" ] || {
  echo "Couldn't locate the built app (BUILT_PRODUCTS_DIR='$BUILT_PRODUCTS_DIR')." >&2
  exit 1
}
echo "    built at $BUILT"

echo "==> Verifying signature"
codesign --verify --deep --strict "$BUILT"
# Capture once rather than piping codesign into `grep -m1`: grep exits at the
# first match, codesign takes SIGPIPE, and `set -o pipefail` would kill us.
SIGINFO=$(codesign -dvv "$BUILT" 2>&1 || true)
IDENTITY=$(printf '%s\n' "$SIGINFO" | grep '^Authority=' | head -1 | cut -d= -f2-)
TEAM=$(printf '%s\n' "$SIGINFO" | grep '^TeamIdentifier=' | head -1 | cut -d= -f2)
echo "    $IDENTITY (team $TEAM)"
if [ "$TEAM" = "not set" ]; then
  echo "    WARNING: ad-hoc signed — macOS will re-prompt for permissions on every build." >&2
fi

# Quit a running copy so we're not overwriting a live bundle.
if pgrep -x "Inbox & Chill" >/dev/null 2>&1; then
  echo "==> Quitting the running copy"
  osascript -e 'quit app id "'"$BUNDLE_ID"'"' 2>/dev/null || pkill -x "Inbox & Chill" || true
  sleep 1
fi

# Only ever replace a bundle that is actually this app.
if [ -e "$DEST" ]; then
  EXISTING_ID=$(defaults read "$DEST/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "")
  if [ "$EXISTING_ID" != "$BUNDLE_ID" ]; then
    echo "Refusing to replace $DEST — its bundle id is '$EXISTING_ID', not '$BUNDLE_ID'." >&2
    exit 1
  fi
  rm -rf "$DEST"
fi

echo "==> Installing to $DEST"
ditto "$BUILT" "$DEST"
# Locally built apps aren't quarantined, but strip it if anything set one.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> Installed"
codesign --verify --deep --strict "$DEST" && echo "    signature valid at the install location"

if [ "$LAUNCH" = "1" ]; then
  echo "==> Launching"
  open "$DEST"
  echo "    Look for the tray icon in the menu bar (this is an LSUIElement app —"
  echo "    no Dock icon until you open the ⌘0 window)."
fi
