#!/usr/bin/env bash
# Build BuildBar, wrap it in a proper .app bundle, and launch it.
# A bundle is required so macOS notifications work (UNUserNotificationCenter
# needs a real bundle identifier - `swift run` on the raw binary aborts).

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"   # ./run.sh release  -> release build
APP="BuildBar.app"
BIN_NAME="BuildBar"
ICON_SOURCE="icon-source.png"      # raw PNG asset from the .icon bundle
ICON_BUNDLE="BuildBar.icon"        # Icon Composer source bundle (optional)
ICNS_NAME="BuildBar"               # produces BuildBar.icns

echo "-> Building (${CONFIG})..."
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/${BIN_NAME}"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "Build succeeded but binary not found at: ${BIN_PATH}" >&2
    exit 1
fi

echo "-> Wrapping into ${APP}..."
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BIN_PATH" "${APP}/Contents/MacOS/${BIN_NAME}"

# --- Icon: build a .icns from the source PNG for Dock/Finder/Launchpad ---
if [[ -f "$ICON_SOURCE" ]]; then
    echo "-> Generating ${ICNS_NAME}.icns from ${ICON_SOURCE}..."
    ICONSET=".build/${ICNS_NAME}.iconset"
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"

    # Standard macOS icon sizes (10 entries, normal + @2x)
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
else
    echo "-> No ${ICON_SOURCE} found; building app without a custom icon."
fi

# --- Also bundle the .icon for macOS Tahoe (26+) Liquid Glass rendering ---
if [[ -d "$ICON_BUNDLE" ]]; then
    cp -R "$ICON_BUNDLE" "${APP}/Contents/Resources/${ICON_BUNDLE}"
fi

cat > "${APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>${BIN_NAME}</string>
<key>CFBundleIdentifier</key><string>app.buildbar</string>
<key>CFBundleName</key><string>BuildBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>${ICNS_NAME}</string>
<key>CFBundleIconName</key><string>${ICNS_NAME}</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

# Kill any previously running instance so we don't end up with two icons.
pkill -x "$BIN_NAME" 2>/dev/null || true

# Refresh icon caches so Finder/Dock pick up the new icon immediately.
touch "$APP"

echo "-> Launching ${APP}..."
# Launch the binary directly to avoid Launch Services error -600
# when the .app bundle was just created/replaced.
"${APP}/Contents/MacOS/${BIN_NAME}" &
disown
echo "Done. Look for BuildBar in your menu bar."
