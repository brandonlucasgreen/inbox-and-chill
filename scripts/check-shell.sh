#!/bin/bash
#
# Static checks for everything in scripts/, run in CI on a Linux runner
# because it needs no Xcode and Linux minutes are a tenth the price.
#
# Two things happen here.
#
# 1. shellcheck, if it is installed. Ordinary lint: unquoted expansions,
#    unused variables, misused test syntax.
#
# 2. The bash 3.2 empty-array trap, which shellcheck does not know about.
#    macOS still ships bash 3.2.57, where expanding an EMPTY array under
#    `set -u` is an "unbound variable" *error* rather than an empty
#    expansion:
#
#        ARGS=()
#        cmd "${ARGS[@]}"                  # bash 3.2 + set -u: fatal
#        cmd ${ARGS[@]+"${ARGS[@]}"}       # correct
#
#    This shipped broken in appcast.sh on 2026-08-21 and would have failed
#    EVERY real release: the array was only non-empty when an env var supplied
#    a key file, which is the path used while testing — so the tested path
#    worked and the default one died. Every script here starts
#    `set -euo pipefail`, so it is not hypothetical.
#
# Usage: scripts/check-shell.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

FAIL=0
SCRIPTS=$(find scripts -maxdepth 1 -name '*.sh' | sort)

echo "==> Syntax"
for FILE in $SCRIPTS; do
  if bash -n "$FILE" 2>/tmp/shellsyntax.txt; then
    echo "    $FILE ok"
  else
    echo "    $FILE FAILED to parse" >&2
    cat /tmp/shellsyntax.txt >&2
    FAIL=1
  fi
done

echo "==> shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # --severity=warning, not the default. The remaining style-level findings in
  # these scripts are SC2015 (`A && B || C` is not if-then-else) and SC2001
  # (prefer parameter expansion to sed) — both deliberate in code that works,
  # and neither worth a cleanup pass to make a new check go green.
  #
  # SC1091: don't chase `source`d files that only exist on a Mac.
  # shellcheck disable=SC2086
  if shellcheck --severity=warning --exclude=SC1091 $SCRIPTS; then
    echo "    clean"
  else
    FAIL=1
  fi
else
  echo "    not installed — skipped" >&2
fi

echo "==> bash 3.2 array expansion"
# Strip the CORRECT form before looking for what is left. Without that step the
# guarded form matches its own remedy and every fixed line reports as broken.
#
# Comment lines are skipped, and a line carrying `bash32-ok` (on itself or the
# line above) is exempt — for an array that provably always has at least one
# element, where the guard would be noise. Same shape as a shellcheck disable:
# an escape hatch you have to write down and justify.
for FILE in $SCRIPTS; do
  HITS=$(awk '
    { raw[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        line = raw[i]
        if (line ~ /^[ \t]*#/) continue
        if (line ~ /bash32-ok/) continue
        # Walk back over the comment block immediately above, so the
        # exemption can be written as a sentence rather than crammed onto
        # the end of the line it excuses.
        exempt = 0
        for (j = i - 1; j >= 1 && raw[j] ~ /^[ \t]*#/; j--)
          if (raw[j] ~ /bash32-ok/) exempt = 1
        if (exempt) continue
        stripped = line
        gsub(/\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\+[^}]*\}\}?/, "", stripped)
        if (stripped ~ /"\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}"/) printf "%d:%s\n", i, line
      }
    }
  ' "$FILE")
  if [ -n "$HITS" ]; then
    echo "    $FILE — unguarded array expansion:" >&2
    echo "$HITS" | sed 's/^/        /' >&2
    echo "        Use \${NAME[@]+\"\${NAME[@]}\"} — bash 3.2 + set -u treats an" >&2
    echo "        empty array as an unbound variable and aborts the script." >&2
    echo "        If the array can never be empty, append a  # bash32-ok  comment." >&2
    FAIL=1
  fi
done
if [ "$FAIL" -eq 0 ]; then echo "    clean"; fi

if [ "$FAIL" -ne 0 ]; then
  echo "==> Shell checks FAILED." >&2
  exit 1
fi
echo "==> Shell checks passed."
