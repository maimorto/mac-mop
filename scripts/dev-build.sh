#!/bin/bash
# Build + install MacCleaner, then snapshot pages. Usage: dev-build.sh [module-id ...]
set -e
cd "$(dirname "$0")/.."
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
ERR=$(swift build -c release --product MacCleaner --disable-keychain 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^/.*error:' | sed "s|$PWD/Sources/MacCleaner/||" | sort -u | head -20 || true)
if [ -n "$ERR" ]; then echo "$ERR"; exit 1; fi
LOG=$(BUILD_ARCHS=" " ./scripts/build-dmg.sh --app-only 2>&1 || true)
if ! grep -q 'App bundle ready' <<<"$LOG"; then echo "$LOG" | grep -iE 'error|fail' | tail -15; echo "BUNDLE FAILED - not installed"; exit 1; fi
echo "App bundle ready"
osascript -e 'quit app "Mac Mop"' 2>/dev/null || true; pkill -x MacCleanerMenu || true; pkill -x com.maccleaner.menu || true; pkill -x MacCleaner || true; sleep 2
rm -rf "/Applications/Mac Mop.app"; ditto ".build/dmg/Mac Mop.app" "/Applications/Mac Mop.app"
S="${KMR_SNAP_DIR:-${TMPDIR:-/tmp}/maccleaner-snaps}"
mkdir -p "$S"
for m in "$@"; do
  KMR_SNAPSHOT="$S/kmr-$m.png" KMR_MODULE="$m" "/Applications/Mac Mop.app/Contents/MacOS/MacCleaner" >/dev/null 2>&1 || true
  echo "snapshot $m: $(ls "$S/kmr-$m.png" 2>/dev/null | wc -l)"
done
