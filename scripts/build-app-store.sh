#!/bin/bash
#
# Build the Mac App Store target locally, audit the bundle, and put it
# somewhere it can be run — sandboxed, with the real entitlements, signed
# with Developer ID so the container and TCC grants stick between rebuilds.
#
# Not scripts/install-local.sh, on purpose. That installs to /Applications
# and would REPLACE the direct build you use every day with one that has no
# Mail, no journal and no coding-agent source (same bundle ID, same name).
# This copies to dist/app-store/ instead, and you launch it from there.
#
# Own derived data (build/AppStore): both targets produce `Inbox & Chill.app`,
# so built into the same DerivedData they would overwrite each other. Keep
# this path in step with scripts/verify-bundle.sh, which looks in the same
# place when --app-store is given without --app.
#
# Usage:
#   scripts/build-app-store.sh              # Release build → dist/app-store/
#   scripts/build-app-store.sh --launch     # …and open it
#   scripts/build-app-store.sh --debug
#   scripts/build-app-store.sh --no-copy    # build and audit only (CI)
#   scripts/build-app-store.sh -- <xcodebuild args>   # e.g. CODE_SIGN_IDENTITY=-
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="Release"
COPY=1
LAUNCH=0
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIGURATION="Debug"; shift ;;
    --release) CONFIGURATION="Release"; shift ;;
    --no-copy) COPY=0; shift ;;
    --launch) LAUNCH=1; shift ;;
    --) shift; EXTRA=("$@"); break ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

APP_NAME="Inbox & Chill.app"
SCHEME="InboxAndChill-AppStore"
DERIVED="build/AppStore"
LOG="/tmp/inchill-appstore-build.log"

echo "==> Generating Xcode project"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi
xcodegen generate >/dev/null

echo "==> Building $SCHEME ($CONFIGURATION) into $DERIVED"
# The `+` form is the bash 3.2 empty-array rule (CLAUDE.md rule 3): with
# `set -u`, expanding an empty array any other way is a fatal error.
xcodebuild -project InboxAndChill.xcodeproj -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED" \
  ${EXTRA[@]+"${EXTRA[@]}"} build >"$LOG" 2>&1 || {
    echo "Build failed. Last 40 lines of $LOG:" >&2
    tail -40 "$LOG" >&2
    exit 1
  }

# Ask xcodebuild where it put the app rather than guessing (install-local.sh
# has the story: guessing resolves to another checkout's stale build).
BUILT_PRODUCTS_DIR=$(xcodebuild -project InboxAndChill.xcodeproj \
  -scheme "$SCHEME" -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED" \
  -showBuildSettings 2>/dev/null \
  | awk -F ' = ' '/^ *BUILT_PRODUCTS_DIR = /{print $2; exit}')
BUILT="$BUILT_PRODUCTS_DIR/$APP_NAME"
[ -n "$BUILT_PRODUCTS_DIR" ] && [ -d "$BUILT" ] || {
  echo "Couldn't locate the built app (BUILT_PRODUCTS_DIR='$BUILT_PRODUCTS_DIR')." >&2
  exit 1
}
echo "    built at $BUILT"

echo "==> Auditing the bundle"
scripts/verify-bundle.sh --app-store --app "$BUILT"

if [ "$COPY" = "1" ]; then
  DEST_DIR="dist/app-store"
  DEST="$DEST_DIR/$APP_NAME"
  echo "==> Copying to $DEST"
  mkdir -p "$DEST_DIR"
  rm -rf "$DEST"
  ditto "$BUILT" "$DEST"
  cat <<MSG

Done. This is the sandboxed store build, signed with your Developer ID so it
runs here without App Store Connect being involved.

  open "$DEST"

Two things to know before launching it:

  - It shares the bundle ID with the direct build in /Applications, so quit
    that one first: both register the same global hotkey, and two menu bar
    icons look like one app misbehaving.
  - It starts from nothing. The sandbox gives it its own container —
    ~/Library/Containers/lol.bgreen.inboxandchill/ — so it has no sources,
    no items and no preferences from the direct build. That is the first-run
    experience a store customer gets, which is the thing worth testing.

To watch it run:

  /usr/bin/log stream --predicate 'subsystem == "lol.bgreen.inboxandchill"' --style compact
  /usr/bin/log stream --predicate 'process == "Inbox & Chill" AND sender == "Sandbox"' --style compact

MSG
  if [ "$LAUNCH" = "1" ]; then
    open "$DEST"
  fi
fi
