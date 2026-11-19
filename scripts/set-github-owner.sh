#!/bin/bash
# Point every MacCleaner link (README, website, app, Homebrew cask) at your GitHub
# account. Usage: ./scripts/set-github-owner.sh <github-username>
set -euo pipefail
cd "$(dirname "$0")/.."
OWNER="${1:?usage: set-github-owner.sh <github-username>}"
grep -rIl --exclude-dir=.build --exclude-dir=.git --exclude-dir=node_modules 'YOUR-GITHUB-USERNAME' . \
  | while read -r f; do sed -i '' "s/YOUR-GITHUB-USERNAME/${OWNER}/g" "$f"; done
echo "Links now point to github.com/${OWNER}/MacCleaner"
