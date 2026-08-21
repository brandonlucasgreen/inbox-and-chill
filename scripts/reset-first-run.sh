#!/bin/bash
#
# Put this Mac back to what a brand-new user sees, so first run can be tested
# more than once.
#
# Why a script: the interesting half of first run is a *permission* state, and
# macOS gives you the Automation prompt for a given app→target pair exactly
# once. Deleting the app does not bring it back — TCC keys on the code
# signature, and install-local.sh deliberately signs with a stable Developer ID
# so that permissions *stick* across rebuilds (that is the whole point of it).
# So the only way back to the pre-prompt state is to reset TCC on purpose.
#
# What a fresh install actually consists of, for this app:
#   1. Automation (Apple events) permission for Mail and for terminals — TCC
#   2. ~/Library/Application Support/InboxAndChill/ — the SwiftData store and
#      the local-api.json handshake file
#   3. UserDefaults — journal settings, badge style, hotkey, Sparkle state
#   4. Keychain — every source's tokens, service lol.bgreen.inboxandchill
#   5. ~/.claude/settings.json hooks, if the Claude Code integration was on
#
# Two things it deliberately does NOT reset, because it cannot:
#   - Notification (banner) permission. There is no supported reset for
#     UNUserNotificationCenter; tccutil does not cover it. To see the banner
#     prompt again you need a different bundle id. Test banners on a Mac that
#     has never run the app, or accept that this one state stays granted.
#   - "Launch at login". SMAppService has no CLI. Turn it off in Settings
#     before running this if you want it clean.
#
# Usage:
#   scripts/reset-first-run.sh --dry-run     # show what would happen
#   scripts/reset-first-run.sh               # reset, with a confirmation
#   scripts/reset-first-run.sh --yes         # no confirmation
#   scripts/reset-first-run.sh --remove-app  # also delete /Applications copy
#   scripts/reset-first-run.sh --all-apple-events    # last resort, see below
#
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE_ID="lol.bgreen.inboxandchill"
KEYCHAIN_SERVICE="lol.bgreen.inboxandchill"
APP_NAME="Inbox & Chill.app"
DEST="/Applications/$APP_NAME"
SUPPORT_DIR="$HOME/Library/Application Support/InboxAndChill"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

DRY_RUN=0
ASSUME_YES=0
REMOVE_APP=0
ALL_APPLE_EVENTS=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --remove-app) REMOVE_APP=1 ;;
    --all-apple-events) ALL_APPLE_EVENTS=1 ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# Simple commands only. Anything needing a loop or a pipeline guards on
# DRY_RUN itself, because passing a pipeline through "$@" would run it as
# arguments to the first word.
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '    would run: %s\n' "$*"
  else
    "$@"
  fi
}

say "==> Inbox & Chill: reset to first-run state"
if [ "$DRY_RUN" = "1" ]; then
  note "DRY RUN — nothing will be changed."
else
  say ""
  say "This will permanently delete:"
  say "  - the item store and archive at $SUPPORT_DIR"
  say "  - every saved token in your Keychain for $KEYCHAIN_SERVICE"
  say "  - all app preferences for $BUNDLE_ID"
  say "  - the Automation permission you granted for Mail (you'll be asked again)"
  [ "$REMOVE_APP" = "1" ] && say "  - $DEST"
  say ""
  say "Your actual mail, Linear, GitHub and Slack data are untouched — this app"
  say "only ever held a cache of them. But the tokens are gone and you will"
  say "have to paste them again."
  say ""
  if [ "$ASSUME_YES" != "1" ]; then
    printf 'Type "reset" to continue: '
    read -r REPLY
    if [ "$REPLY" != "reset" ]; then
      say "Aborted."
      exit 1
    fi
  fi
fi

# --- 1. Quit the running copy ------------------------------------------------
# Everything below is a file or a permission the app has open or cached in
# memory; resetting underneath a live process gets you a half-reset app that
# rewrites what you just deleted on quit.
say "==> Quitting the app"
if pgrep -x "Inbox & Chill" >/dev/null 2>&1; then
  if [ "$DRY_RUN" = "1" ]; then
    note "would quit the running copy"
  else
    osascript -e 'quit app id "'"$BUNDLE_ID"'"' 2>/dev/null \
      || pkill -x "Inbox & Chill" || true
    sleep 1
    note "quit"
  fi
else
  note "not running"
fi

# --- 2. Automation permission ------------------------------------------------
say "==> Resetting Automation (Apple events) permission"
if [ "$ALL_APPLE_EVENTS" = "1" ]; then
  # Deliberately behind a flag: this clears Apple-event grants for EVERY app
  # on the Mac, so every scripting tool you own re-prompts. It is here because
  # the per-bundle form is unreliable and sometimes the only way through.
  note "WARNING: resetting Apple events for ALL apps, not just this one."
  run tccutil reset AppleEvents
else
  # Known to fail on some macOS versions with "no such bundle identifier",
  # which is why this is checked rather than assumed. A silent failure here
  # would leave permission granted and make the pre-prompt flow untestable
  # while looking like it had been reset.
  if [ "$DRY_RUN" = "1" ]; then
    note "would run: tccutil reset AppleEvents $BUNDLE_ID"
  elif tccutil reset AppleEvents "$BUNDLE_ID" >/dev/null 2>&1; then
    note "reset for $BUNDLE_ID"
  else
    note "tccutil could not reset AppleEvents for $BUNDLE_ID."
    note "This is a known tccutil limitation, not a sign the app is wrong."
    note "Re-run with --all-apple-events to reset every app's grants instead,"
    note "or clear the row by hand in System Settings > Privacy & Security >"
    note "Automation > Inbox & Chill."
  fi
fi

# --- 3. On-disk state --------------------------------------------------------
say "==> Removing the store and handshake file"
if [ -d "$SUPPORT_DIR" ]; then
  run rm -rf "$SUPPORT_DIR"
  note "removed $SUPPORT_DIR"
else
  note "nothing at $SUPPORT_DIR"
fi

# --- 4. Preferences ----------------------------------------------------------
say "==> Removing preferences"
# `defaults delete` exits non-zero when the domain does not exist, which is a
# perfectly good outcome here and must not trip `set -e`.
if [ "$DRY_RUN" = "1" ]; then
  note "would run: defaults delete $BUNDLE_ID"
else
  defaults delete "$BUNDLE_ID" 2>/dev/null && note "preferences deleted" \
    || note "no preferences to delete"
  # cfprefsd caches the domain in memory and will happily write it back.
  killall cfprefsd 2>/dev/null || true
fi

# --- 5. Keychain -------------------------------------------------------------
say "==> Removing saved tokens"
if [ "$DRY_RUN" = "1" ]; then
  note "would delete every generic password for service $KEYCHAIN_SERVICE"
else
  DELETED=0
  # One call deletes one item, so loop until it reports none left. The counter
  # is a runaway guard, not a real limit.
  while [ "$DELETED" -lt 500 ] \
    && security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; do
    DELETED=$((DELETED + 1))
  done
  note "removed $DELETED keychain item(s)"
fi

# --- 6. Optional: the app itself --------------------------------------------
if [ "$REMOVE_APP" = "1" ]; then
  say "==> Removing the installed app"
  if [ -e "$DEST" ]; then
    # Same guard install-local.sh uses: only ever touch a bundle that really
    # is this app.
    EXISTING_ID=$(defaults read "$DEST/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "")
    if [ "$EXISTING_ID" = "$BUNDLE_ID" ]; then
      run rm -rf "$DEST"
      note "removed $DEST"
    else
      note "refusing to remove $DEST — bundle id is '$EXISTING_ID'"
    fi
  else
    note "not installed at $DEST"
  fi
fi

# --- 7. Claude Code hooks: reported, never edited ---------------------------
# Not scripted, and not offered as a flag either — a flag named --remove-hooks
# that only printed advice would be worse than no flag. $CLAUDE_SETTINGS is the
# user's own file, holds far more than our hooks, and the app already has a
# tested remover that knows the exact shape it wrote.
if [ -f "$CLAUDE_SETTINGS" ] && grep -q "inchill" "$CLAUDE_SETTINGS" 2>/dev/null; then
  say "==> Claude Code hooks"
  note "$CLAUDE_SETTINGS still contains inchill hooks; this script won't touch it."
  note "For a truly clean first run, use Settings > General > Remove Integration"
  note "in the app BEFORE resetting."
fi

# --- What to do next ---------------------------------------------------------
say ""
say "==> Next"
say "  1. scripts/install-local.sh"
say "  2. Open Settings > Sources > Add Source > Apple Mail."
say "     The permission explanation should appear ABOVE the toggles, with an"
say "     \"Allow Mail Access…\" button and no macOS dialog yet."
say ""
say "  Four states worth checking, and how to force each:"
say "    not asked   this reset, before you press anything"
say "    granted     press Allow Mail Access… then Allow — the queue should"
say "                fill without waiting out the 60s poll"
say "    declined    reset again, press the button, then Don't Allow"
say "    Mail closed quit Mail, press Check Again"
say ""
say "  The regression that matters most: after this reset, add a Mail source"
say "  and leave the app alone for two minutes WITHOUT pressing the button."
say "  No dialog should ever appear, and the source should say why it is empty."
say "  A dialog appearing on its own means a poll is prompting again."
say ""
say "  Verify TCC was actually consulted (silence here means the entitlement"
say "  is missing, not that you declined — CLAUDE.md rule 2):"
say "    log stream --predicate 'subsystem == \"com.apple.TCC\"' --info"
