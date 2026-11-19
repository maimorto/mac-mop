cask "maccleaner" do
  version "1.9.0"
  # Set to the published DMG's hash at release time. build-dmg.sh prints
  # "SHA256:" at the end; the release workflow fills this in automatically.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  # Homebrew dropped the optional URL hostname check (Homebrew/brew#23280);
  # keeping it only produced a brew-update warning. url and
  # homepage already share github.com/maimorto/mac-mop.
  url "https://github.com/maimorto/mac-mop/releases/download/v#{version}/MacCleaner-#{version}.dmg"
  name "MacCleaner"
  desc "Open-source Mac cleaner, optimizer, and malware scanner"
  homepage "https://github.com/maimorto/mac-mop"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Symbol form means "this release or newer"; the old comparison-string
  # form (">= :sonoma") is deprecated by Homebrew and warns on every install.
  depends_on macos: :sonoma

  app "MacCleaner.app"

  # Quit a running MacCleaner before upgrading/uninstalling so the old copy is
  # cleanly replaced instead of lingering (macOS can't swap a running app).
  uninstall quit: "com.maccleaner.app"

  zap trash: [
    "~/Library/Application Support/MacCleaner",
    "~/Library/Caches/com.maccleaner.app",
    "~/Library/HTTPStorages/com.maccleaner.app",
    "~/Library/Logs/MacCleaner",
    "~/Library/Preferences/com.maccleaner.app.plist",
    "~/Library/Preferences/com.maccleaner.shared.plist",
    "~/Library/Saved Application State/com.maccleaner.app.savedState",
  ]

  caveats <<~EOS
    Some features (Mail, Safari, Privacy scans) require Full Disk Access:
      System Settings → Privacy & Security → Full Disk Access
  EOS
end
