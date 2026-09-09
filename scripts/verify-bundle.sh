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
# Two flavours of bundle, one script. The direct build (default) must carry
# Sparkle, the inchill CLI and the apple-events entitlement; the App Store
# build (--app-store) must carry NONE of those and the sandbox instead. Each
# absence on one side is a presence on the other, so the two lists are kept
# next to each other here rather than in two scripts that drift apart.
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
#   scripts/verify-bundle.sh --app-store     # the store target's build (build/AppStore)
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP=""
CONFIGURATION="Release"
FLAVOR="direct"

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --configuration) CONFIGURATION="${2:-}"; shift 2 ;;
    --app-store) FLAVOR="store"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$APP" ]; then
  # Ask xcodebuild where it put the app rather than guessing a DerivedData
  # path — same reasoning as install-local.sh and notarize.sh. Every worktree
  # has its own, and guessing audits somebody else's build.
  #
  # The store target builds into its own derived data (build/AppStore, the
  # path scripts/build-app-store.sh uses) because both targets produce an
  # `Inbox & Chill.app` and would otherwise overwrite each other.
  if [ "$FLAVOR" = "store" ]; then
    SCHEME="InboxAndChill-AppStore"
    DERIVED=(-derivedDataPath build/AppStore)
  else
    SCHEME="InboxAndChill"
    DERIVED=()
  fi
  BUILT_PRODUCTS_DIR=$(xcodebuild -project InboxAndChill.xcodeproj \
    -scheme "$SCHEME" -configuration "$CONFIGURATION" \
    ${DERIVED[@]+"${DERIVED[@]}"} -showBuildSettings 2>/dev/null \
    | awk -F ' = ' '/^ *BUILT_PRODUCTS_DIR = /{print $2; exit}')
  APP="$BUILT_PRODUCTS_DIR/Inbox & Chill.app"
fi

[ -d "$APP" ] || { echo "No app at: $APP" >&2; exit 1; }
echo "==> Auditing ($FLAVOR build): $APP"

PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || { echo "No Info.plist in the bundle." >&2; exit 1; }
BINARY="$APP/Contents/MacOS/Inbox & Chill"
[ -f "$BINARY" ] || { echo "No executable at Contents/MacOS/Inbox & Chill." >&2; exit 1; }

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

expect_plist_absent() {
  local key="$1" why="$2" got
  got=$(plist_value "$key")
  if [ -n "$got" ]; then
    bad "Info.plist: $key PRESENT — $why"
  else
    note "Info.plist: $key absent"
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

# App Store Connect refuses an upload with no category; the encryption answer
# saves a question per upload. Both builds carry both, so the two plists
# differ only where the sandbox forces them to.
expect_plist LSApplicationCategoryType public.app-category.productivity
expect_plist ITSAppUsesNonExemptEncryption false

# EventKit crashes outright without this, and the Reminders source is dead
# without EventKit. Nothing else in the build would notice it missing.
expect_plist_present NSRemindersFullAccessUsageDescription

if [ "$FLAVOR" = "direct" ]; then
  # Sparkle reads both of these out of the bundle at runtime. Neither absence
  # produces an error the user would connect to updates.
  expect_plist SUFeedURL "https://raw.githubusercontent.com/brandonlucasgreen/inbox-and-chill/main/appcast.xml"
  expect_plist_present SUPublicEDKey
  # Supplies the wording of the Automation consent prompt. Without it macOS
  # denies the Apple event outright instead of asking, and the denial looks
  # exactly like "nothing happened" (CLAUDE.md rule 2).
  expect_plist_present NSAppleEventsUsageDescription
else
  # The store delivers updates (2.4.5(vii)); a feed URL in the plist would
  # say the build still thinks otherwise. Nothing in this build sends Apple
  # events, so the usage string would promise a prompt that can never come.
  expect_plist_absent SUFeedURL "the store build must not carry a Sparkle feed"
  expect_plist_absent SUPublicEDKey "the store build must not carry a Sparkle key"
  expect_plist_absent NSAppleEventsUsageDescription "nothing in the store build sends Apple events"
fi

# The welcome window's typefaces. AppKit registers whatever this key names
# at launch and says nothing if the folder is missing — the window would
# quietly render in SF. Both fonts are SIL OFL 1.1 and ship with their
# licence text, which is the condition the licence puts on bundling them.
expect_plist ATSApplicationFontsPath Fonts
for font in Syne-Variable.ttf SpaceGrotesk-Variable.ttf OFL-Syne.txt OFL-SpaceGrotesk.txt; do
  if [ -f "$APP/Contents/Resources/Fonts/$font" ]; then
    note "fonts: $font present"
  else
    bad "fonts: Resources/Fonts/$font MISSING — the welcome falls back to SF and no build step says so"
  fi
done

# The privacy manifest. App Store Connect rejects an upload that calls a
# "required reason" API (UserDefaults, file timestamps — both used here)
# without one, and the rejection arrives by e-mail after the upload. Both
# builds ship it; a resource that fails to copy produces no build error.
if [ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ]; then
  if plutil -lint "$APP/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null 2>&1; then
    note "privacy: PrivacyInfo.xcprivacy present and well-formed"
  else
    bad "privacy: PrivacyInfo.xcprivacy is not a valid plist"
  fi
else
  bad "privacy: Resources/PrivacyInfo.xcprivacy MISSING — App Store Connect rejects the upload, by e-mail, later"
fi

# --- Entitlements ---------------------------------------------------------
# Only meaningful on a signed bundle; an unsigned build carries none at all.
ENTITLEMENTS=$(codesign -d --entitlements - "$APP" 2>/dev/null || true)
if [ -z "$ENTITLEMENTS" ]; then
  note "entitlements: bundle is unsigned — skipped"
else
  expect_entitlement() {
    local key="$1" why="$2"
    case "$ENTITLEMENTS" in
      *"$key"*) note "entitlements: $key present" ;;
      *) bad "entitlements: $key MISSING — $why" ;;
    esac
  }
  expect_no_entitlement() {
    local key="$1" why="$2"
    case "$ENTITLEMENTS" in
      *"$key"*) bad "entitlements: $key PRESENT — $why" ;;
      *) note "entitlements: no $key" ;;
    esac
  }

  if [ "$FLAVOR" = "direct" ]; then
    expect_entitlement "com.apple.security.automation.apple-events" \
      "Apple events fail with -1743 and NO consent prompt"
    # A sandboxed direct build would lose Mail, the CLI listener and the
    # journal at once, and every symptom would point somewhere else.
    expect_no_entitlement "com.apple.security.app-sandbox" \
      "the direct build must not be sandboxed; that is the store target"
    # Xcode injects the debugger-attach entitlement unless told not to, and
    # notarization rejects a Developer ID binary carrying it.
    expect_no_entitlement "get-task-allow" \
      "needs CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"
  else
    # Guideline 2.4.5(i). Every one of these is a runtime denial with no
    # dialog if it goes missing: the sandbox refusal is silent by design.
    expect_entitlement "com.apple.security.app-sandbox" \
      "App Review rejects an unsandboxed app, and every cut in this target exists for the sandbox"
    expect_entitlement "com.apple.security.network.client" \
      "every remaining source is a network client; without this each one fails to connect"
    expect_entitlement "com.apple.security.personal-information.calendars" \
      "Reminders (EventKit) is denied under the sandbox without it"
    expect_entitlement "com.apple.security.files.user-selected.read-write" \
      "Export Diagnostics… cannot write where the save panel points"
    expect_no_entitlement "com.apple.security.automation.apple-events" \
      "nothing in the store build sends Apple events, and the sandbox makes Mail compose-only regardless"
    # Informational for a local build: Xcode injects get-task-allow into a
    # locally signed store build and strips it at archive time, so its
    # presence here is not a verdict on the upload.
    case "$ENTITLEMENTS" in
      *"get-task-allow"*) note "entitlements: get-task-allow present (local build; the archive step removes it)" ;;
      *) note "entitlements: no get-task-allow" ;;
    esac
  fi
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
if [ "$FLAVOR" = "direct" ]; then
  # project.yml's "Re-sign Sparkle's nested helpers" phase walks a hardcoded
  # list of paths and skips anything it cannot find. That skip is silent, so
  # if Sparkle ever moves its helpers the phase passes vacuously and
  # notarization is the first thing to object — a long way from the cause.
  # Checking the paths exist is what turns that into a pull-request failure.
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
else
  # Every executable in a store bundle must be sandboxed, and Sparkle's four
  # helpers plus the CLI are exactly the executables this build must not
  # have. Their presence means the target's dependency list regressed.
  for RELATIVE in "MacOS/inchill" "Frameworks/Sparkle.framework"; do
    if [ -e "$APP/Contents/$RELATIVE" ]; then
      bad "nested: $RELATIVE PRESENT — the store target must not embed it"
    else
      note "nested: no $RELATIVE"
    fi
  done
  # Nothing else executable should be in there either: one binary, no
  # helpers, no XPC services. Counted rather than listed so a new one fails.
  EXTRA=$(find "$APP/Contents/MacOS" -mindepth 1 ! -name "Inbox & Chill" | wc -l | tr -d ' ')
  NESTED_BUNDLES=$(find "$APP/Contents" \( -name "*.xpc" -o -name "*.app" \) | wc -l | tr -d ' ')
  if [ "$EXTRA" = "0" ] && [ "$NESTED_BUNDLES" = "0" ]; then
    note "nested: single executable, no helper bundles"
  else
    bad "nested: $EXTRA extra file(s) in Contents/MacOS and $NESTED_BUNDLES nested bundle(s) — each would need its own sandbox entitlement"
  fi

  # Weak evidence, kept because a URL literal is the one string shape that
  # survives optimisation: the Lemon Squeezy checkout and the Sparkle feed
  # are 3.1.1 / 2.4.5(vii) rejections if they are in the binary at all.
  # (Absence proves little in general — CLAUDE.md rule 1 — but presence
  # here is a real finding.)
  for LITERAL in "lemonsqueezy.com" "brandonlucasgreen/inbox-and-chill/main/appcast.xml"; do
    HITS=$(strings -a "$BINARY" | grep -c "$LITERAL" || true)
    if [ "$HITS" = "0" ]; then
      note "strings: no \"$LITERAL\""
    else
      bad "strings: \"$LITERAL\" appears $HITS time(s) — a cut feature is compiled into the store build"
    fi
  done
fi

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
