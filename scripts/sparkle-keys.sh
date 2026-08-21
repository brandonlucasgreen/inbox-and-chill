#!/bin/bash
#
# One-time setup: create the EdDSA keypair Sparkle uses to sign updates, and
# print the line to paste into project.yml.
#
# Like `notarytool store-credentials`, a person has to do this once — it puts a
# private key in your login keychain, and the Keychain will ask permission.
#
# Good news, given how much trouble the notary credentials have caused: this
# lands in the **file-based login keychain**, not the iCloud "Local Items"
# keychain. `security` can see it, Time Machine backs it up, and it does not
# lock itself when the Mac sleeps.
#
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=$(scripts/sparkle-tools.sh)

# -p prints the existing public key without creating anything, so a re-run is
# safe and idempotent — you only ever want one key, and replacing it would
# strand everyone already running a build that trusts the old one.
if PUB=$("$BIN/generate_keys" -p 2>/dev/null) && [ -n "$PUB" ]; then
  echo "==> A signing key already exists in your login keychain. Reusing it."
else
  echo "==> No signing key yet — creating one."
  echo "    The Keychain will ask for permission; you must Allow."
  "$BIN/generate_keys"
  PUB=$("$BIN/generate_keys" -p 2>/dev/null || true)
fi

[ -n "$PUB" ] || {
  echo "error: could not read the public key back out of the keychain." >&2
  echo "       Run '$BIN/generate_keys' directly to see what it says." >&2
  exit 1
}

CURRENT=$(grep -m1 'SUPublicEDKey:' project.yml | sed 's/.*SUPublicEDKey: *//' || true)

cat <<EOF

==> Your public key

    $PUB

EOF

if [ "$CURRENT" = "$PUB" ]; then
  echo "    project.yml already carries this key. Nothing to do."
else
  cat <<EOF
    Paste this into project.yml, in the InboxAndChill target's
    info.properties block, right under SUFeedURL:

        SUPublicEDKey: $PUB

    then:

        xcodegen generate

EOF
fi

cat <<'EOF'
==> Back up the PRIVATE key

    It is in your login keychain as "Private key for signing Sparkle
    updates". Lose it and you cannot sign an update that existing installs
    will accept — they only trust the public key baked into the build they
    are running. Export a copy somewhere safe:

        .sparkle/<version>/bin/generate_keys -x sparkle-private-key.txt

    Treat that file like a certificate: it is the one secret that must never
    reach this repo. (dist/ and .sparkle/ are gitignored; the repo root is
    not — do not leave it there.)
EOF
