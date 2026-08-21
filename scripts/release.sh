#!/bin/bash
#
# Cut a release: notarize the current source, tag it, publish a GitHub release
# with both artifacts attached, and regenerate the Sparkle update feed.
#
# Two artifacts, because they have different jobs: the .zip is what Sparkle
# downloads to update an existing install, and the .dmg is what a person
# downloads the first time. Both are notarized and stapled.
#
# Why this exists: before it, "releasing" meant running notarize.sh and then
# hand-sending `dist/InboxAndChill-<version>.zip` to someone. There were no
# git tags and no GitHub releases at all, so nothing recorded which source a
# given zip was built from — and `dist/` held a 0.3.1 zip that predated two
# commits on main. A downloader had no way to tell, and neither did we.
#
# The one rule worth knowing: **this always rebuilds and re-notarizes.** It
# never attaches a zip that happens to be sitting in dist/, because the whole
# point is that the tag and the artifact describe the same code. Notarization
# costs a few minutes; shipping a mystery build costs more.
#
# The version comes from MARKETING_VERSION in project.yml, which is the single
# source of truth — bump it there and commit before running this.
#
# Usage:
#   scripts/release.sh              # confirm, then notarize + tag + publish + feed
#   scripts/release.sh --dry-run    # show exactly what would happen, do nothing
#   scripts/release.sh --yes        # skip the confirmation prompt
#
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

# --- Preconditions --------------------------------------------------------
# Every one of these has a specific failure it prevents; none is ceremony.

command -v gh >/dev/null 2>&1 || die "the GitHub CLI (gh) is not installed."
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = "main" ] || die "on branch '$BRANCH'; releases are cut from main.
    (A worktree session can land you elsewhere without noticing — see CLAUDE.md.)"

[ -z "$(git status --porcelain)" ] || die "working tree is dirty.
    A release must describe a commit, so commit or stash first:
$(git status --short | sed 's/^/      /')"

git fetch --quiet origin main
BEHIND=$(git rev-list --count HEAD..origin/main)
AHEAD=$(git rev-list --count origin/main..HEAD)
[ "$BEHIND" -eq 0 ] || die "local main is $BEHIND commit(s) behind origin/main — pull first."
[ "$AHEAD"  -eq 0 ] || die "local main is $AHEAD commit(s) ahead of origin/main.
    Push first, or the tag will point at a commit nobody else can fetch:
      git push origin main"

VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')
[ -n "$VERSION" ] || die "could not read MARKETING_VERSION from project.yml."
TAG="v$VERSION"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  die "tag $TAG already exists — bump MARKETING_VERSION in project.yml and commit."
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  die "a GitHub release $TAG already exists."
fi

# CFBundleVersion is what Sparkle actually compares to decide whether a
# release is newer — not the marketing version. If it does not increase, every
# existing install looks at the feed, concludes it is already current, and
# never updates: a silent no-op release, which is precisely the failure this
# project keeps having to design against.
BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')
[ -n "$BUILD" ] || die "could not read CURRENT_PROJECT_VERSION from project.yml."
PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -n "$PREV_TAG" ]; then
  PREV_BUILD=$(git show "$PREV_TAG:project.yml" 2>/dev/null \
    | grep -m1 'CURRENT_PROJECT_VERSION:' | sed 's/.*"\(.*\)".*/\1/')
  if [ -n "$PREV_BUILD" ] && [ "$BUILD" -le "$PREV_BUILD" ]; then
    die "CURRENT_PROJECT_VERSION is $BUILD, but $PREV_TAG already shipped $PREV_BUILD.
    Sparkle compares this number, so an update that does not raise it is
    invisible to everyone already running the app. Bump it in project.yml."
  fi
fi

ZIP="dist/InboxAndChill-$VERSION.zip"
DMG="dist/dmg/InboxAndChill-$VERSION.dmg"
COMMIT=$(git rev-parse --short HEAD)
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
VISIBILITY=$(gh repo view --json visibility -q .visibility)

cat <<EOF
==> Release plan
    repo        $REPO ($VISIBILITY)
    version     $VERSION  (build $BUILD)
    tag         $TAG  ->  $COMMIT
    artifacts   $ZIP  (Sparkle downloads this)
                $DMG  (what a person downloads)
                both rebuilt and notarized now, never reused
    feed        appcast.xml, regenerated and committed after publishing
EOF

if [ "$DRY_RUN" -eq 1 ]; then
  echo "==> --dry-run: stopping before any change."
  exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
  # The tag push and the release are the outward-facing steps, so the
  # confirmation sits before both rather than before the build.
  printf "==> Notarize, tag, publish and update the feed for %s? [y/N] " "$TAG"
  read -r reply
  case "$reply" in [yY]*) ;; *) echo "    aborted."; exit 1 ;; esac
fi

# --- Build the artifact the tag will describe -----------------------------
echo "==> Notarizing (this rebuilds Release from the current source)"
scripts/notarize.sh
[ -f "$ZIP" ] || die "notarize.sh finished but $ZIP is missing.
    Its version comes from the built Info.plist; if that disagrees with
    project.yml's MARKETING_VERSION, regenerate the project: xcodegen generate"
[ -f "$DMG" ] || die "notarize.sh finished but $DMG is missing."

# --- Tag, then publish ----------------------------------------------------
echo "==> Tagging $TAG"
git tag -a "$TAG" -m "Inbox & Chill $VERSION"
git push origin "$TAG"

echo "==> Publishing the GitHub release"
NOTES_FLAG=(--generate-notes)
if PREV=$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null); then
  NOTES_FLAG=(--generate-notes --notes-start-tag "$PREV")
fi
gh release create "$TAG" "$ZIP" "$DMG" --title "Inbox & Chill $VERSION" "${NOTES_FLAG[@]}"

# --- Publish the update feed ---------------------------------------------
# Strictly after the release exists, because the feed's enclosure URL points
# at that release's asset. Generating it first would publish a feed naming a
# URL that 404s, and Sparkle's report for that reads like a network fault.
echo "==> Regenerating appcast.xml"
scripts/appcast.sh

if [ -n "$(git status --porcelain appcast.xml)" ]; then
  git add appcast.xml
  git commit -q -m "Publish appcast for $VERSION"
  git push -q origin main
  echo "    appcast.xml committed and pushed"
else
  echo "    appcast.xml unchanged (nothing to commit)"
fi

cat <<EOF
==> Done
    $(gh release view "$TAG" --json url -q .url)

    Both artifacts are notarized and stapled, so they open on a Mac that has
    never seen this app — the only test that means anything (CLAUDE.md).
EOF

if [ "$VISIBILITY" != "PUBLIC" ]; then
  cat <<EOF
    WARNING: this repo is $VISIBILITY, so the release assets 404 for everyone
    but you. In-app updates cannot work until it is public — Sparkle fetches
    appcast.xml and the zip with no credentials at all.
EOF
else
  cat <<EOF
    Existing installs will see this within a day, or immediately via
    Settings -> Check Now. raw.githubusercontent caches appcast.xml for about
    five minutes, so it is not offered the very second this finishes.
EOF
fi
