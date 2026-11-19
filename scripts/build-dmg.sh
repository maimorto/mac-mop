#!/bin/bash
# Build, sign, notarize, and package MacCleaner as a DMG.
#
# Usage:
#   ./scripts/build-dmg.sh                    # Build with ad-hoc signing only
#   ./scripts/build-dmg.sh --notarize         # Sign with Developer ID + notarize + staple
#   ./scripts/build-dmg.sh --app-only         # Stop after the signed .app bundle (no DMG);
#                                             # used by scripts/dev-install.sh for fast local installs
#
# Environment variables for the build:
#   BUILD_ARCHS         — swift build arch flags (default: "--arch arm64 --arch x86_64").
#                         Override with "--arch $(uname -m)" for a fast native-only dev build.
#
# Optional update configuration:
#   BUILD_NUMBER:           monotonically increasing CFBundleVersion (defaults to VERSION's numeric part)
#   SPARKLE_FEED_URL:       HTTPS appcast URL; requires SPARKLE_PUBLIC_ED_KEY
#   SPARKLE_PUBLIC_ED_KEY:  base64 Ed25519 PUBLIC key (never the private key)
#   UPDATE_CHANNEL_NAME:   optional visible channel label for test/distribution builds
#   SWIFT_BUILD_SYSTEM:     optional SwiftPM build system (e.g. native)
#   LOCAL_SIGNING_IDENTITY: optional stable local identity for non-notarized test builds
#   DMG_STAGING_ROOT:       existing parent for a fresh staging dir (e.g. /private/tmp)
#                           to avoid file-provider FinderInfo stamping in synced folders
#
# Environment variables for proper signing/notarization:
#   APPLE_DEVELOPER_ID  — "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE      — Keychain profile name (created via `xcrun notarytool store-credentials`)

set -euo pipefail

APP_NAME="Mac Mop"
BUNDLE_ID="com.maccleaner.app"
VERSION="${VERSION:-$(cat VERSION 2>/dev/null | tr -d '[:space:]' || echo '1.0.0')}"
BUILD_NUMBER="${BUILD_NUMBER:-${VERSION%%-*}}"
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "ERROR: BUILD_NUMBER must have one to three numeric components"
    exit 1
fi
SWIFT_BUILD_OPTIONS=()
if [[ -n "${SWIFT_BUILD_SYSTEM:-}" ]]; then
    SWIFT_BUILD_OPTIONS+=(--build-system "$SWIFT_BUILD_SYSTEM")
fi
# BUILD_DIR is resolved AFTER the build via `swift build --show-bin-path`:
# multi-arch builds emit to .build/apple/Products/Release/ while single-arch
# (BUILD_ARCHS override) emits to .build/<triple>/release/. Hardcoding one of
# them silently bundles stale binaries from the other (a 1.9.0 app shipped in
# a 1.10.0 wrapper during dev-install testing — binary and Info.plist drift).
DMG_DIR=".build/dmg"
if [[ -n "${DMG_STAGING_ROOT:-}" ]]; then
    DMG_DIR=$(mktemp -d "${DMG_STAGING_ROOT%/}/maccleaner-staging.XXXXXX")
fi
DMG_NAME="MacMop-${VERSION}.dmg"

# Detect signing capability
APP_ONLY=false
if [[ "${1:-}" == "--app-only" ]]; then
    APP_ONLY=true
fi
NOTARIZE=false
SIGNING_IDENTITY="${LOCAL_SIGNING_IDENTITY:--}"  # ad-hoc unless explicitly configured
if [[ "${1:-}" == "--notarize" ]]; then
    NOTARIZE=true
    if [[ -z "${APPLE_DEVELOPER_ID:-}" ]]; then
        echo "ERROR: --notarize requires APPLE_DEVELOPER_ID env var"
        echo "Example: export APPLE_DEVELOPER_ID='Developer ID Application: John Doe (ABC123XYZ)'"
        exit 1
    fi
    if [[ -z "${NOTARY_PROFILE:-}" ]]; then
        echo "ERROR: --notarize requires NOTARY_PROFILE env var"
        echo "Set it up first: xcrun notarytool store-credentials 'MacCleaner' --apple-id YOU@example.com --team-id TEAMID"
        exit 1
    fi
    SIGNING_IDENTITY="$APPLE_DEVELOPER_ID"
fi

# Stapling and validating fetch the ticket from Apple's CloudKit service,
# which sometimes drops the connection ("-1005 The network connection was
# lost", error 68) after notarization already succeeded. Retry instead of
# failing the whole release.
stapler_with_retry() {
    local attempt
    for attempt in 1 2 3 4; do
        if xcrun stapler "$@"; then
            return 0
        fi
        if [[ $attempt -lt 4 ]]; then
            echo "  stapler $1 failed (attempt ${attempt}/4), retrying in $((attempt * 15))s..."
            sleep $((attempt * 15))
        fi
    done
    echo "ERROR: stapler $1 failed after 4 attempts"
    return 1
}

echo "=== Building MacCleaner v${VERSION} ==="
echo "Signing identity: $SIGNING_IDENTITY"
echo "Notarize: $NOTARIZE"
echo ""

# Step 1: Build release as a universal (arm64 + x86_64) binary
BUILD_ARCHS="${BUILD_ARCHS:---arch arm64 --arch x86_64}"
echo "[1/7] Building release binaries (${BUILD_ARCHS})..."
# Bash 3.2 treats an empty array as unset under nounset; expand it only when set.
swift build ${SWIFT_BUILD_OPTIONS[@]+"${SWIFT_BUILD_OPTIONS[@]}"} -c release ${BUILD_ARCHS} --product MacCleaner
swift build ${SWIFT_BUILD_OPTIONS[@]+"${SWIFT_BUILD_OPTIONS[@]}"} -c release ${BUILD_ARCHS} --product MacCleanerMenu
BUILD_DIR=$(swift build ${SWIFT_BUILD_OPTIONS[@]+"${SWIFT_BUILD_OPTIONS[@]}"} -c release ${BUILD_ARCHS} --product MacCleaner --show-bin-path)
echo "  → Binaries: ${BUILD_DIR}"

# Step 2: Create .app bundle
echo "[2/7] Creating app bundle..."
APP_BUNDLE="${DMG_DIR}/${APP_NAME}.app"
rm -rf "${DMG_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/MacCleaner" "${APP_BUNDLE}/Contents/MacOS/"
# MacCleaner: SwiftPM + Command Line Tools stamp "sdk 14.0" into the binary,
# which puts the app in pre-Tahoe compatibility appearance. Re-stamp with the
# SDK it was really built against (KMR_SDK_VERSION, default 26.5).
vtool -set-build-version macos 14.0 "${KMR_SDK_VERSION:-26.5}" -replace -output "${APP_BUNDLE}/Contents/MacOS/MacCleaner" "${APP_BUNDLE}/Contents/MacOS/MacCleaner" >/dev/null 2>&1 || true

cat > "${APP_BUNDLE}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>ru</string>
        <string>de</string>
        <string>zh-Hans</string>
        <string>zh-Hant</string>
        <string>fr</string>
        <string>it</string>
        <string>es</string>
        <string>pt-BR</string>
        <string>ja</string>
        <string>ko</string>
        <string>tr</string>
        <string>fa</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>MacCleaner</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.maccleaner.deeplink</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>maccleaner</string>
            </array>
        </dict>
    </array>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>Uninstall with ${APP_NAME}</string>
            </dict>
            <key>NSMessage</key>
            <string>uninstallApp</string>
            <key>NSPortName</key>
            <string>MacCleaner</string>
            <key>NSRequiredContext</key>
            <dict/>
            <key>NSSendFileTypes</key>
            <array>
                <string>com.apple.application-bundle</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Finder › Services title in each interface language (key = the English default above).
while IFS='|' read -r LPROJ TITLE; do
    mkdir -p "${APP_BUNDLE}/Contents/Resources/${LPROJ}.lproj"
    printf '"Uninstall with %s" = "%s";\n' "${APP_NAME}" "${TITLE}" > "${APP_BUNDLE}/Contents/Resources/${LPROJ}.lproj/ServicesMenu.strings"
done << 'SERVICES'
en|Uninstall with Mac Mop
it|Disinstalla con Mac Mop
de|Mit Mac Mop deinstallieren
es|Desinstalar con Mac Mop
fr|Désinstaller avec Mac Mop
pt-BR|Desinstalar com o Mac Mop
ja|Mac Mopでアンインストール
ko|Mac Mop으로 제거
ru|Удалить с помощью Mac Mop
tr|Mac Mop ile Kaldır
fa|حذف با Mac Mop
zh-Hans|使用 Mac Mop 卸载
zh-Hant|使用 Mac Mop 解除安裝
SERVICES
python3 scripts/configure-updates.py "${APP_BUNDLE}/Contents/Info.plist"
SPARKLE_SOURCE="${BUILD_DIR}/Sparkle.framework"
if [[ ! -d "$SPARKLE_SOURCE" ]]; then
    SPARKLE_SOURCE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi
if [[ ! -d "$SPARKLE_SOURCE" ]]; then
    echo "ERROR: Sparkle.framework missing after build"
    exit 1
fi
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
ditto "$SPARKLE_SOURCE" "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"

cp LICENSE "${APP_BUNDLE}/Contents/Resources/LICENSE"   # shown in Settings > Informazioni
cp THIRD_PARTY_NOTICES.md "${APP_BUNDLE}/Contents/Resources/THIRD_PARTY_NOTICES.md"
# Third-party YARA rules (ESET malware-ioc, BSD-2-Clause) + their licence.
if [ -d "Resources/YARA" ]; then
    ditto "Resources/YARA" "${APP_BUNDLE}/Contents/Resources/YARA"
fi
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/"
fi

# Step 2.5: Nest the menu bar widget inside the main app as a LoginItem.
# SMAppService.loginItem(identifier:) expects the helper at this exact path
# (Contents/Library/LoginItems/<helper>.app), and the helper's bundle id
# is what gets passed to register(). LSUIElement=true keeps it off the
# Dock; it lives in the menu bar only.
echo "[2.5/7] Bundling MacCleanerMenu widget..."
MENU_APP="${APP_BUNDLE}/Contents/Library/LoginItems/MacCleanerMenu.app"
mkdir -p "${MENU_APP}/Contents/MacOS"
mkdir -p "${MENU_APP}/Contents/Resources"

cp "${BUILD_DIR}/MacCleanerMenu" "${MENU_APP}/Contents/MacOS/"
# MacCleaner: SwiftPM + Command Line Tools stamp "sdk 14.0" into the binary,
# which puts the app in pre-Tahoe compatibility appearance. Re-stamp with the
# SDK it was really built against (KMR_SDK_VERSION, default 26.5).
vtool -set-build-version macos 14.0 "${KMR_SDK_VERSION:-26.5}" -replace -output "${MENU_APP}/Contents/MacOS/MacCleanerMenu" "${MENU_APP}/Contents/MacOS/MacCleanerMenu" >/dev/null 2>&1 || true

cat > "${MENU_APP}/Contents/Info.plist" << MENU_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>ru</string>
        <string>de</string>
        <string>zh-Hans</string>
        <string>zh-Hant</string>
        <string>fr</string>
        <string>it</string>
        <string>es</string>
        <string>pt-BR</string>
        <string>ja</string>
        <string>ko</string>
        <string>tr</string>
        <string>fa</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>MacCleanerMenu</string>
    <key>CFBundleIdentifier</key>
    <string>com.maccleaner.menu</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Mac Mop Menu</string>
    <key>CFBundleDisplayName</key>
    <string>Mac Mop Menu</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
MENU_PLIST

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${MENU_APP}/Contents/Resources/"
fi
# Menu-bar mop glyph (template) and the plate-less colour mop for the popup header.
for menu_png in Resources/MenuBarMop*.png Resources/MenuMopColor*.png; do
    if [ -f "$menu_png" ]; then cp "$menu_png" "${MENU_APP}/Contents/Resources/"; fi
done

# Step 3: Entitlements (needed for notarization with hardened runtime).
# Keep this OUTSIDE the DMG staging folder — it is codesign input only and
# must not appear as a loose file on the mounted disk image.
echo "[3/7] Creating entitlements..."
ENTITLEMENTS_FILE=".build/entitlements.plist"
mkdir -p .build
cat > "${ENTITLEMENTS_FILE}" << ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

# Step 4: Sign the app
echo "[4/7] Signing app bundle..."
# Only remove resource-fork/Finder metadata from our generated staging copy.
# Never remove quarantine from downloads or modify the installed application.
xattr -r -d com.apple.FinderInfo "${APP_BUNDLE}" 2>/dev/null || true
xattr -r -d com.apple.ResourceFork "${APP_BUNDLE}" 2>/dev/null || true
SIGN_OPTIONS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$NOTARIZE" == "true" ]]; then
    SIGN_OPTIONS+=(--options runtime --timestamp)
fi
SPARKLE_BUNDLE="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="${SPARKLE_BUNDLE}/Versions/B"
# Sign nested executable bundles inside out. Do not rely on --deep to infer
# entitlements or the identity of Sparkle's installer components.
for component in \
    "${SPARKLE_VERSION}/Autoupdate" \
    "${SPARKLE_VERSION}/Updater.app" \
    "${SPARKLE_VERSION}/XPCServices/Installer.xpc" \
    "${SPARKLE_VERSION}/XPCServices/Downloader.xpc" \
    "${SPARKLE_BUNDLE}" \
    "${MENU_APP}"; do
    codesign "${SIGN_OPTIONS[@]}" "$component"
done
codesign "${SIGN_OPTIONS[@]}" --entitlements "${ENTITLEMENTS_FILE}" "${APP_BUNDLE}"

# Verify signature
codesign --verify --deep --strict --verbose=1 "${APP_BUNDLE}" 2>&1 | head -3
# Inspect the packaged app and every nested Sparkle/menu executable, rather
# than trusting a scan of the main SwiftPM product alone.
bash scripts/check-network-surface.sh "${APP_BUNDLE}"

# --app-only: stop here with the signed bundle (dev-install path).
if [[ "$APP_ONLY" == "true" ]]; then
    echo ""
    echo "=== App bundle ready (skipped DMG/notarization) ==="
    echo "App: ${APP_BUNDLE}"
    printf '%s\n' "${APP_BUNDLE}" > .build/last-app-path
    exit 0
fi

# Step 4.5: Notarize + STAPLE the app itself, BEFORE packaging it into the DMG.
# Stapling embeds the notarization ticket in the app bundle, so the copied-out
# app (Homebrew/DMG installs put a fresh copy in /Applications) verifies
# OFFLINE. Previously only the DMG was stapled and the app relied on an online
# Gatekeeper check on first launch; when that check didn't complete, macOS
# showed "Apple could not verify MacCleaner..." and blocked it. Stapling the app
# removes that online dependency. This is a separate submission from the DMG
# below, but it is the only way to ship a DMG that contains a stapled app.
if [[ "$NOTARIZE" == "true" ]]; then
    echo "[5/7] Notarizing + stapling the app bundle..."
    # Keep the zip outside the DMG staging folder so it can never leak into
    # the image even if a later step forgets to delete it.
    APP_ZIP=".build/${APP_NAME}-notarize.zip"
    ditto -c -k --keepParent "${APP_BUNDLE}" "${APP_ZIP}"
    xcrun notarytool submit "${APP_ZIP}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait
    rm -f "${APP_ZIP}"
    stapler_with_retry staple "${APP_BUNDLE}"
    stapler_with_retry validate "${APP_BUNDLE}"
    echo "  → App notarized and stapled (verifies offline)"
fi

# Step 6: Create DMG (now containing the stapled app + Applications link).
# Strip build-only junk and add the /Applications drop target first so the
# mounted image is a normal drag-to-install disk.
echo "[6/7] Creating DMG..."
bash "$(dirname "$0")/prepare-dmg-staging.sh" "${DMG_DIR}"
# Designed window (background, icon positions, volume icon) written straight
# into the image's .DS_Store; falls back to the plain image on any failure.
if ! python3 "$(dirname "$0")/make-dmg.py" "${DMG_DIR}" "${APP_NAME}" ".build/${DMG_NAME}" > /dev/null; then
    echo "  ! Designed DMG layout failed; building the plain DMG instead"
    rm -rf "${DMG_DIR}/.background" "${DMG_DIR}/.VolumeIcon.icns"
    hdiutil create -volname "${APP_NAME}" \
        -srcfolder "${DMG_DIR}" \
        -ov -format UDZO \
        ".build/${DMG_NAME}" > /dev/null
fi

# Sign the DMG
if [[ "$NOTARIZE" == "true" ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp ".build/${DMG_NAME}"
    echo "  → DMG signed with Developer ID"
fi

# Step 7: Notarize + staple the DMG so opening the downloaded disk image itself
# is clean. The app inside was already notarized AND stapled in Step 5, so it
# verifies offline once copied out; this step just covers the DMG wrapper.
if [[ "$NOTARIZE" == "true" ]]; then
    echo "[7/7] Notarizing DMG..."
    xcrun notarytool submit ".build/${DMG_NAME}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait
    stapler_with_retry staple ".build/${DMG_NAME}"
    stapler_with_retry validate ".build/${DMG_NAME}"
    echo "  → Notarization complete (DMG stapled; app inside stapled too)"
else
    echo "[7/7] Skipping notarization (no --notarize flag)"
fi

# Compute SHA256 for Homebrew Cask
SHA256=$(shasum -a 256 ".build/${DMG_NAME}" | awk '{print $1}')

echo ""
echo "=== Build complete ==="
echo "DMG:    .build/${DMG_NAME}"
echo "Size:   $(du -h ".build/${DMG_NAME}" | cut -f1)"
echo "SHA256: ${SHA256}"
