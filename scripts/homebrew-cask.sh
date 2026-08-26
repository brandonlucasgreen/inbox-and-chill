#!/bin/bash
#
# Point the Homebrew cask at the release that was just published.
#
# `brew install --cask brandonlucasgreen/tap/inbox-and-chill` reads a file in a
# separate repo — the tap. This script rewrites that file's version and sha256
# from the notarized DMG in dist/, checks the two against what GitHub is
# actually serving, and pushes it.
#
# Normally you don't run it by hand: scripts/release.sh calls it after the
# GitHub release exists, for the same reason it calls appcast.sh there — a cask
# whose URL 404s is worse than a cask that is one version behind.
#
# The failure this exists to prevent: a sha256 that does not match the bytes
# GitHub serves. Homebrew refuses the download and reports a checksum mismatch,
# which reads like a corrupted file or a MITM rather than a stale cask, and it
# fails for every user at once. So the checksum is never typed by a person, and
# it is verified against the published asset before the cask is pushed.
#
# Usage:
#   scripts/homebrew-cask.sh              # rewrite, verify against GitHub, push to the tap
#   scripts/homebrew-cask.sh --local-only # rewrite only: no download, no tap, no push
#   scripts/homebrew-cask.sh --dry-run    # say what would happen, change nothing
#   TAP_REPO=<owner>/<repo> …             # publish somewhere other than the default tap
#
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_SLUG="${REPO_SLUG:-brandonlucasgreen/inbox-and-chill}"
TAP_REPO="${TAP_REPO:-brandonlucasgreen/homebrew-tap}"
CASK="packaging/homebrew/inbox-and-chill.rb"
CASK_IN_TAP="Casks/inbox-and-chill.rb"

DRY_RUN=0
LOCAL_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --local-only) LOCAL_ONLY=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

[ -f "$CASK" ] || die "$CASK is missing."

VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')
[ -n "$VERSION" ] || die "could not read MARKETING_VERSION from project.yml."

# The DMG's name carries no version — one link, `releases/latest/download/
# InboxAndChill.dmg`, keeps working across releases. Which means this path
# alone no longer proves the DMG is *this* version: before, a stale one simply
# did not match the path and the check below said so.
#
# The backstop is the published-asset comparison further down, which compares
# actual bytes and is the thing that has to be right anyway. It runs on every
# path that publishes. `--local-only` skips it and would happily write the
# checksum of a stale DMG into the cask — harmless, because it pushes nothing,
# but re-run without the flag before believing that cask.
DMG="dist/dmg/InboxAndChill.dmg"
[ -f "$DMG" ] || die "$DMG is missing — the cask's checksum comes from the
    notarized DMG, so run scripts/notarize.sh (or scripts/release.sh) first."

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
[ -n "$SHA" ] || die "could not checksum $DMG."
URL="https://github.com/$REPO_SLUG/releases/download/v$VERSION/InboxAndChill.dmg"

echo "==> Cask plan"
echo "    version     $VERSION"
echo "    sha256      $SHA"
echo "    url         $URL"
echo "    tap         $TAP_REPO ($CASK_IN_TAP)"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "==> --dry-run: stopping before any change."
  exit 0
fi

# --- Rewrite the two lines that change per release ------------------------
# Everything else in the cask is hand-edited; only these are generated.
TMP=$(mktemp)
sed -E \
  -e "s/^  version \".*\"$/  version \"$VERSION\"/" \
  -e "s/^  sha256 \".*\"$/  sha256 \"$SHA\"/" \
  "$CASK" > "$TMP"
mv "$TMP" "$CASK"

grep -q "^  version \"$VERSION\"$" "$CASK" \
  || die "the version line in $CASK did not take the rewrite — has its shape changed?"
grep -q "^  sha256 \"$SHA\"$" "$CASK" \
  || die "the sha256 line in $CASK did not take the rewrite — has its shape changed?"
echo "==> $CASK updated"

if [ "$LOCAL_ONLY" -eq 1 ]; then
  echo "==> --local-only: not verifying against GitHub and not touching the tap."
  exit 0
fi

# --- Check it against what a stranger will actually download --------------
# Not a formality: this is the only step that can tell the difference between
# "the asset is there" and "the asset is there and is these exact bytes".
echo "==> Verifying the published asset"
ASSET=$(mktemp)
curl -fsSL "$URL" -o "$ASSET" || die "could not download $URL.
    The cask points at a release asset that is not reachable without
    credentials. Check the release exists and the repo is public."
PUBLISHED_SHA=$(shasum -a 256 "$ASSET" | awk '{print $1}')
rm -f "$ASSET"
[ "$PUBLISHED_SHA" = "$SHA" ] || die "checksum mismatch — not pushing the cask.
    local  $DMG
           $SHA
    github $URL
           $PUBLISHED_SHA
    The DMG in dist/ is not the one that was uploaded. Every install would
    fail its checksum. Two causes now that the name carries no version: the
    release was cut from different bytes, or dist/dmg/InboxAndChill.dmg is
    left over from an earlier version. Re-run scripts/notarize.sh."
echo "    match: the DMG in dist/ is byte-for-byte what GitHub serves"

# --- Push it to the tap ---------------------------------------------------
command -v gh >/dev/null 2>&1 || die "the GitHub CLI (gh) is not installed."
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"
gh repo view "$TAP_REPO" >/dev/null 2>&1 || die "the tap repo $TAP_REPO does not
    exist, or you cannot see it. Create it once, public, then re-run this:
      gh repo create $TAP_REPO --public --add-readme \\
        --description 'Homebrew tap for Inbox & Chill'
    The name must start with 'homebrew-' or brew will not resolve it."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$TAP_REPO" "$WORK/tap" -- --quiet >/dev/null 2>&1 \
  || die "could not clone $TAP_REPO."
mkdir -p "$WORK/tap/$(dirname "$CASK_IN_TAP")"
cp "$CASK" "$WORK/tap/$CASK_IN_TAP"

if [ -z "$(git -C "$WORK/tap" status --porcelain)" ]; then
  echo "==> The tap already carries this cask — nothing to push."
else
  git -C "$WORK/tap" add "$CASK_IN_TAP"
  git -C "$WORK/tap" commit -q -m "inbox-and-chill $VERSION"
  # -u origin HEAD, not a bare push: a tap created empty has an unborn branch
  # with no upstream, and a bare push there fails with "no upstream branch".
  git -C "$WORK/tap" push -q -u origin HEAD
  echo "==> Pushed inbox-and-chill $VERSION to $TAP_REPO"
fi

cat <<EOF
==> Done
    brew install --cask $(echo "$TAP_REPO" | sed 's|/homebrew-|/|')/inbox-and-chill

    Existing brew installs get it on their next \`brew upgrade\`: the cask sets
    \`auto_updates true\`, and brew compares the installed bundle's Info.plist,
    so it upgrades an app Sparkle has not already moved past.
EOF
