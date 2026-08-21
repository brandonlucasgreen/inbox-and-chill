#!/bin/bash
#
# Regenerate appcast.xml — the feed Sparkle reads to discover new versions —
# from the notarized zips in dist/.
#
# Normally you don't run this by hand: scripts/release.sh calls it after the
# GitHub release exists, because the feed points at that release's asset and a
# feed naming a URL that 404s is worse than no feed at all.
#
# Usage:
#   scripts/appcast.sh              # regenerate from dist/, verify, write appcast.xml
#   SPARKLE_ED_KEY_FILE=<path> …    # sign with a key file instead of the Keychain
#
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_SLUG="${REPO_SLUG:-brandonlucasgreen/inbox-and-chill}"
# Overridable so the pipeline can be exercised against a scratch copy of the
# zips without touching dist/ or the real feed.
ARCHIVES="${ARCHIVES:-dist}"
FEED="${FEED:-appcast.xml}"
DOWNLOAD_PREFIX="https://github.com/$REPO_SLUG/releases/download/"
PROJECT_URL="https://github.com/$REPO_SLUG"

die() { echo "error: $*" >&2; exit 1; }

BIN=$(scripts/sparkle-tools.sh)

ls "$ARCHIVES"/InboxAndChill-*.zip >/dev/null 2>&1 \
  || die "no notarized zips in $ARCHIVES/ — run scripts/notarize.sh first."

# generate_appcast re-uses an appcast already sitting in the ARCHIVES dir and
# adds to it, which is the only thing that keeps entries for versions whose
# zips are no longer on this machine (dist/ is gitignored, so a fresh clone has
# none). The canonical copy lives at the repo root because that is the path
# raw.githubusercontent serves, so it gets copied in and back out again.
[ -f "$FEED" ] && cp "$FEED" "$ARCHIVES/appcast.xml"

KEY_ARGS=()
if [ -n "${SPARKLE_ED_KEY_FILE:-}" ]; then
  KEY_ARGS=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
fi

echo "==> Generating appcast from $ARCHIVES/"
# --maximum-deltas 0: delta files would have to be uploaded and hosted
#   alongside each release, and the whole app is under 3 MB. Not worth the
#   moving parts.
# --maximum-versions 0: keep every entry. Costs a few lines of XML and means
#   the feed still describes older releases.
"$BIN/generate_appcast" \
  "${KEY_ARGS[@]}" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --maximum-deltas 0 \
  --maximum-versions 0 \
  --link "$PROJECT_URL" \
  --full-release-notes-url "$PROJECT_URL/releases" \
  "$ARCHIVES" \
  || die "generate_appcast failed.
    If it could not find a signing key, you have not created one yet:
      scripts/sparkle-keys.sh"

[ -f "$ARCHIVES/appcast.xml" ] || die "generate_appcast wrote no appcast.xml."

# GitHub release assets live under .../releases/download/<tag>/<file>, and
# generate_appcast can only prepend one fixed prefix — it has no way to know
# the tag differs per item. So the tag directory is inserted here, once per
# enclosure. Idempotent: the pattern only matches a filename sitting directly
# after download/, which a previously-rewritten URL does not.
python3 - "$ARCHIVES/appcast.xml" "$DOWNLOAD_PREFIX" <<'PY'
import re, sys

path, prefix = sys.argv[1], sys.argv[2]
text = open(path).read()

pattern = re.compile(re.escape(prefix) + r'(InboxAndChill-([0-9][^"/]*)\.zip)')
text, count = pattern.subn(lambda m: f"{prefix}v{m.group(2)}/{m.group(1)}", text)

# Anything still pointing straight at download/<file> would be a 404 for every
# user who tried to update, so refuse to write a feed containing one.
leftover = re.findall(re.escape(prefix) + r'(?!v)[^"]+', text)
if leftover:
    sys.exit("error: enclosure URLs missing their tag: " + ", ".join(leftover))

open(path, "w").write(text)
print(f"    rewrote {count} enclosure URL(s) to include their tag")
PY

cp "$ARCHIVES/appcast.xml" "$FEED"

# --- Verify what we are about to serve ------------------------------------
command -v xmllint >/dev/null && { xmllint --noout "$FEED" || die "$FEED is not well-formed XML."; }

echo "==> Feed contents"
python3 - "$FEED" <<'FEEDCHECK'
import sys, xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
def s(tag): return "{%s}%s" % (SPARKLE, tag)

items = ET.parse(sys.argv[1]).getroot().findall(".//item")
if not items:
    sys.exit("error: the feed has no <item>, so Sparkle would see no versions at all.")

unsigned = []
for index, item in enumerate(items):
    enclosure = item.find("enclosure")
    version = item.findtext(s("shortVersionString"), "?")
    build = item.findtext(s("version"), "?")
    minimum = item.findtext(s("minimumSystemVersion"), "-")
    # generate_appcast signs an enclosure only when the app inside the archive
    # declares SUPublicEDKey. An unsigned entry therefore means that build
    # predates Sparkle, or was built before the key reached project.yml -- it
    # does not mean signing is broken.
    signed = enclosure is not None and enclosure.get(s("edSignature"))
    url = enclosure.get("url") if enclosure is not None else "(no enclosure!)"
    print("    %s (build %s)  macOS %s+  %s" % (version, build, minimum, "signed" if signed else "UNSIGNED"))
    print("      %s" % url)
    if not signed:
        unsigned.append((index, version))

if any(i == 0 for i, _ in unsigned):
    sys.exit(
        "error: the newest entry (%s) is unsigned, so Sparkle will refuse it and\n"
        "       nobody will ever update. The app in that zip carries no SUPublicEDKey:\n"
        "       run scripts/sparkle-keys.sh, paste the key into project.yml,\n"
        "       `xcodegen generate`, and rebuild." % unsigned[0][1]
    )
if unsigned:
    print("    note: older unsigned entries: %s" % ", ".join(v for _, v in unsigned))
    print("          Those builds predate Sparkle. It only ever installs the newest, so")
    print("          they are harmless; to drop them, move their zips out of the archives")
    print("          directory and delete appcast.xml, then re-run.")
FEEDCHECK

# A feed is only as good as the URLs in it, and the failure mode of a wrong one
# is an update that silently never installs. Check them for real.
echo "==> Checking enclosure URLs resolve"
python3 -c '
import re,sys
print("\n".join(re.findall(r"<enclosure[^>]*url=\"([^\"]+)\"", open(sys.argv[1]).read())))
' "$FEED" | while read -r url; do
  [ -n "$url" ] || continue
  CODE=$(curl -sSL -o /dev/null -w '%{http_code}' --max-time 30 "$url" || echo "000")
  if [ "$CODE" = "200" ]; then
    echo "    200  $url"
  else
    # Not fatal: the repo may still be private, or the release may be seconds
    # old. But say it out loud rather than shipping a feed nobody can use.
    echo "    $CODE  $url" >&2
    echo "         ^ not downloadable right now. If the repo is still private," >&2
    echo "           this is expected — Sparkle needs it public to update." >&2
  fi
done

echo "==> Wrote $FEED"
