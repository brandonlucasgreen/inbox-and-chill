# The canonical copy of the Homebrew cask. `scripts/homebrew-cask.sh` rewrites
# the version and sha256 from the notarized DMG at release time and copies this
# file into the tap repo, which is where `brew` actually reads it from.
#
# Edit this file, never the copy in the tap.
cask "inbox-and-chill" do
  version "0.3.5"
  sha256 "1f6e76a052c2e8b22d21f2b384f44cdedd42d893bca611215ea8259ba22b25eb"

  url "https://github.com/brandonlucasgreen/inbox-and-chill/releases/download/v#{version}/InboxAndChill-#{version}.dmg"
  name "Inbox & Chill"
  desc "Menu bar triage queue for Slack, Linear, GitHub and terminal notifications"
  homepage "https://github.com/brandonlucasgreen/inbox-and-chill"

  # The app ships a Sparkle feed, so the cask reads its version from the same
  # place the app does. `&:short_version` takes CFBundleShortVersionString
  # alone; without it livecheck answers "0.3.4,7" (short,build) and `brew
  # audit` rejects a version carrying a component the download URL never uses.
  livecheck do
    url "https://raw.githubusercontent.com/brandonlucasgreen/inbox-and-chill/main/appcast.xml"
    strategy :sparkle, &:short_version
  end

  # Sparkle updates the app in place, and brew knows what that means: for an
  # `auto_updates true` cask it compares the *installed bundle's* Info.plist
  # rather than its own install record, so whichever updater gets there first
  # wins and the other does nothing.
  auto_updates true
  depends_on macos: :sequoia

  app "Inbox & Chill.app"
  # The CLI the Claude Code / Codex / Gemini hooks call, and the one a person
  # runs as `inchill notify`. It lives inside the bundle, so this is the whole
  # shell integration for a brew install.
  binary "#{appdir}/Inbox & Chill.app/Contents/MacOS/inchill"

  zap trash: [
    "~/Library/Application Support/InboxAndChill",
    "~/Library/Caches/lol.bgreen.inboxandchill",
    "~/Library/HTTPStorages/lol.bgreen.inboxandchill",
    "~/Library/Preferences/lol.bgreen.inboxandchill.plist",
  ]

  caveats <<~EOS
    Secrets live in the login keychain and agent hooks live in your own
    config files, so neither `brew uninstall` nor `--zap` removes them.
    Turn hooks off in Settings before uninstalling, and delete the
    "lol.bgreen.inboxandchill" keychain items by hand if you want them gone.
  EOS
end
