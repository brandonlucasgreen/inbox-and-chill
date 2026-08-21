#!/bin/bash
#
# Put Sparkle's command-line tools (generate_appcast, generate_keys,
# sign_update) on disk and print the directory holding them.
#
#   BIN=$(scripts/sparkle-tools.sh)   # progress goes to stderr, path to stdout
#
# Why download them rather than use the copy SPM already fetched: that one
# lives under a DerivedData path that differs per worktree and vanishes on a
# clean, and scraping DerivedData paths has silently used the wrong build in
# this repo before (CLAUDE.md, install-local.sh). This pulls the identical
# artifact from the identical URL Sparkle's own Package.swift uses, and
# verifies the identical checksum, so there is nothing to guess.
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Pinned deliberately. Keep in step with the framework version resolved for
# the app — the script warns below if they drift.
SPARKLE_VERSION="2.9.6"
SPARKLE_SHA256="8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"

DEST=".sparkle/$SPARKLE_VERSION"
BIN="$DEST/bin"

if [ ! -x "$BIN/generate_appcast" ]; then
  echo "==> Fetching Sparkle $SPARKLE_VERSION tools" >&2
  mkdir -p "$DEST"
  ZIP="$DEST/sparkle.zip"
  URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip"
  curl -fsSL -o "$ZIP" "$URL" || {
    echo "error: could not download $URL" >&2
    exit 1
  }
  ACTUAL=$(shasum -a 256 "$ZIP" | awk '{print $1}')
  if [ "$ACTUAL" != "$SPARKLE_SHA256" ]; then
    # This is the signing toolchain for every update you will ever ship, so a
    # mismatch is fatal rather than a warning.
    echo "error: checksum mismatch for Sparkle $SPARKLE_VERSION" >&2
    echo "       expected $SPARKLE_SHA256" >&2
    echo "       got      $ACTUAL" >&2
    rm -f "$ZIP"
    exit 1
  fi
  unzip -oq "$ZIP" -d "$DEST"
  rm -f "$ZIP"
fi

[ -x "$BIN/generate_appcast" ] || {
  echo "error: $BIN/generate_appcast missing after extraction." >&2
  exit 1
}

# Warn if the app links a different Sparkle than these tools came from. The
# appcast format is stable across 2.x so this is not fatal, but a surprise
# here is worth a sentence.
RESOLVED=$(find . -name Package.resolved -path "*swiftpm*" -print -quit 2>/dev/null || true)
if [ -n "$RESOLVED" ] && command -v python3 >/dev/null; then
  LINKED=$(python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit()
pins = d.get("pins") or d.get("object",{}).get("pins",[])
for p in pins:
    name = (p.get("identity") or p.get("package") or "").lower()
    if "sparkle" in name:
        st = p.get("state",{})
        print(st.get("version") or "")
' "$RESOLVED" 2>/dev/null || true)
  if [ -n "$LINKED" ] && [ "$LINKED" != "$SPARKLE_VERSION" ]; then
    echo "warning: app links Sparkle $LINKED but these tools are $SPARKLE_VERSION." >&2
    echo "         Update SPARKLE_VERSION/SPARKLE_SHA256 in scripts/sparkle-tools.sh" >&2
    echo "         (the checksum is the one in Sparkle's own Package.swift)." >&2
  fi
fi

echo "$BIN"
