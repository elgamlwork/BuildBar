#!/usr/bin/env bash
# Build BuildBar in release mode, wrap in .app, and package as .dmg.
# Usage:
#   ./create-dmg.sh                # Build + DMG, version from git tag or "0.1.0"
#   ./create-dmg.sh 0.2.0          # Build + DMG with explicit version
#   ./create-dmg.sh --no-build     # Skip build, just re-package existing .app as DMG
#   ./create-dmg.sh --no-build 0.2.0

set -euo pipefail
cd "$(dirname "$0")"

NO_BUILD=false
VERSION=""

for arg in "$@"; do
    case "$arg" in
        --no-build) NO_BUILD=true ;;
        -*) echo "Unknown flag: $arg" >&2; exit 1 ;;
        *) VERSION="$arg" ;;
    esac
done

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")}"
APP="BuildBar.app"
BIN_NAME="BuildBar"
BUNDLE_ID="app.buildbar"
DMG_NAME="BuildBar-${VERSION}.dmg"
DMG_TMP="BuildBar-${VERSION}.tmp.dmg"
PKG_NAME="BuildBar-${VERSION}.pkg"
PKG_STAGING=".build/pkg-root"
STAGING=".build/dmg-staging"
ICON_SOURCE="icon-source.png"
ICNS_NAME="BuildBar"

echo "=== $( [[ "$NO_BUILD" == true ]] && echo "Packaging" || echo "Building" ) BuildBar ${VERSION} ==="

# --- Build (unless --no-build) --------------------------------------
if [[ "$NO_BUILD" == false ]]; then
    echo "-> Building (release)..."
    swift build -c release --arch arm64 --arch x86_64 2>/dev/null || {
        echo "-> Universal build failed, trying single-arch..."
        swift build -c release
    }

    BIN_PATH="$(swift build -c release --show-bin-path)/${BIN_NAME}"
    if [[ ! -x "$BIN_PATH" ]]; then
        echo "Build succeeded but binary not found at: ${BIN_PATH}" >&2
        exit 1
    fi

    # --- Wrap into .app bundle -----------------------------------------
    echo "-> Wrapping into ${APP}..."
    rm -rf "$APP"
    mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

    cp "$BIN_PATH" "${APP}/Contents/MacOS/${BIN_NAME}"

    # Generate .icns from source PNG
    if [[ -f "$ICON_SOURCE" ]]; then
        echo "-> Generating ${ICNS_NAME}.icns..."
        ICONSET=".build/${ICNS_NAME}.iconset"
        rm -rf "$ICONSET" && mkdir -p "$ICONSET"

        sips -z 16   16   "$ICON_SOURCE" --out "${ICONSET}/icon_16x16.png"     > /dev/null
        sips -z 32   32   "$ICON_SOURCE" --out "${ICONSET}/icon_16x16@2x.png"  > /dev/null
        sips -z 32   32   "$ICON_SOURCE" --out "${ICONSET}/icon_32x32.png"     > /dev/null
        sips -z 64   64   "$ICON_SOURCE" --out "${ICONSET}/icon_32x32@2x.png"  > /dev/null
        sips -z 128  128  "$ICON_SOURCE" --out "${ICONSET}/icon_128x128.png"   > /dev/null
        sips -z 256  256  "$ICON_SOURCE" --out "${ICONSET}/icon_128x128@2x.png"> /dev/null
        sips -z 256  256  "$ICON_SOURCE" --out "${ICONSET}/icon_256x256.png"   > /dev/null
        sips -z 512  512  "$ICON_SOURCE" --out "${ICONSET}/icon_256x256@2x.png"> /dev/null
        sips -z 512  512  "$ICON_SOURCE" --out "${ICONSET}/icon_512x512.png"   > /dev/null
        sips -z 1024 1024 "$ICON_SOURCE" --out "${ICONSET}/icon_512x512@2x.png"> /dev/null

        iconutil -c icns -o "${APP}/Contents/Resources/${ICNS_NAME}.icns" "$ICONSET"
        rm -rf "$ICONSET"
    fi

    cat > "${APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>${BIN_NAME}</string>
<key>CFBundleIdentifier</key><string>app.buildbar</string>
<key>CFBundleName</key><string>BuildBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>${ICNS_NAME}</string>
<key>CFBundleIconName</key><string>${ICNS_NAME}</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
else
    if [[ ! -d "$APP" ]]; then
        echo "Error: ${APP} not found. Run without --no-build first." >&2
        exit 1
    fi
    echo "-> Using existing ${APP} (skipping build)"
fi

# --- Create DMG ----------------------------------------------------
echo "-> Creating ${DMG_NAME}..."
rm -f "$DMG_NAME" "$DMG_TMP"
rm -rf "$STAGING"
mkdir -p "$STAGING"

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Create a temporary r/w image for layout
hdiutil create -srcfolder "$STAGING" -volname "BuildBar" -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" -format UDRW -size 100m "$DMG_TMP" > /dev/null

# Mount and set layout
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_TMP" | \
    egrep '^/dev/' | sed 1q | awk '{print $1}')

# Set icon positions and window size
echo '
   tell application "Finder"
     tell disk "BuildBar"
       open
       set current view of container window to icon view
       set toolbar visible of container window to false
       set statusbar visible of container window to false
       set the bounds of container window to {400, 200, 900, 520}
       set theViewOptions to the icon view options of container window
       set arrangement of theViewOptions to not arranged
       set icon size of theViewOptions to 96
       set position of item "BuildBar.app" of container window to {150, 155}
       set position of item "Applications" of container window to {350, 155}
       update without registering applications
       delay 1
       close
     end tell
   end tell
' | osascript

# Finalize: convert to compressed read-only
hdiutil detach "$DEVICE" -force > /dev/null
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_NAME" > /dev/null
rm -f "$DMG_TMP"
rm -rf "$STAGING"

# --- Create .pkg installer ----------------------------------------
echo "-> Creating ${PKG_NAME}..."
rm -f "$PKG_NAME"
rm -rf "$PKG_STAGING"
mkdir -p "${PKG_STAGING}/Applications"
cp -R "$APP" "${PKG_STAGING}/Applications/"

pkgbuild \
    --root "$PKG_STAGING" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --install-location "/" \
    "$PKG_NAME" > /dev/null

rm -rf "$PKG_STAGING"

echo "=== Done: ${DMG_NAME} + ${PKG_NAME} ==="
