#!/bin/bash
# Completely remove MacCleaner and its support files.
# Usage: curl -fsSL https://raw.githubusercontent.com/maimorto/mac-mop/main/scripts/uninstall.sh | bash
#
# Homebrew users can instead run:  brew uninstall --zap --cask maccleaner
# (the --zap flag removes the same support files via the cask's zap stanza).

set -euo pipefail

APP_NAME="MacCleaner.app"
INSTALL_DIR="/Applications"

cyan() { printf "\033[36m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }
red() { printf "\033[31m%s\033[0m\n" "$1"; }

# Guard: HOME must be set so the explicit paths below never expand to "/...".
if [ -z "${HOME:-}" ]; then
  red "HOME is not set; aborting to avoid removing unintended paths."
  exit 1
fi

# Exact, explicit paths only (no globs, no wildcards) so this can never delete
# more than MacCleaner's own files.
SUPPORT_PATHS=(
  "$HOME/Library/Application Support/MacCleaner"
  "$HOME/Library/Caches/com.maccleaner.app"
  "$HOME/Library/HTTPStorages/com.maccleaner.app"
  "$HOME/Library/Logs/MacCleaner"
  "$HOME/Library/Preferences/com.maccleaner.app.plist"
  "$HOME/Library/Preferences/com.maccleaner.shared.plist"
  "$HOME/Library/Saved Application State/com.maccleaner.app.savedState"
)

cyan "Quitting MacCleaner if it is running..."
osascript -e 'tell application "MacCleaner" to quit' >/dev/null 2>&1 || true
# The menu-bar helper is a separate process.
pkill -f "MacCleanerMenu" >/dev/null 2>&1 || true

# Prefer Homebrew's own uninstall when the cask is installed, so brew's receipt
# stays consistent. --zap removes the support files too, so we're done after it.
if command -v brew >/dev/null 2>&1 && brew list --cask maccleaner >/dev/null 2>&1; then
  cyan "Removing the Homebrew cask (with --zap to clear support files)..."
  brew uninstall --zap --cask maccleaner
  green "✓ MacCleaner and its support files were removed via Homebrew."
  exit 0
fi

cyan "Removing $INSTALL_DIR/$APP_NAME..."
rm -rf "$INSTALL_DIR/$APP_NAME"

cyan "Removing support files..."
for path in "${SUPPORT_PATHS[@]}"; do
  if [ -e "$path" ]; then
    rm -rf "$path"
    echo "  removed $path"
  fi
done

# Clear any cached preferences held by cfprefsd so they don't get rewritten.
defaults delete com.maccleaner.app >/dev/null 2>&1 || true
defaults delete com.maccleaner.shared >/dev/null 2>&1 || true

green ""
green "✓ MacCleaner has been uninstalled."
echo ""
echo "If MacCleaner still appears under System Settings → General → Login Items,"
echo "remove the leftover entry there; macOS clears it once the app is gone."
