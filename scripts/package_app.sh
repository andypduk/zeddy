#!/usr/bin/env bash
set -euo pipefail

# Package Zeddy.app for testing and distribution

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${PROJECT_DIR}/dist"
APP_DIR="${DIST_DIR}/Zeddy.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "=== Building Release Binaries ==="
cd "${PROJECT_DIR}"
swift build -c release

echo "=== Creating Zeddy.app Bundle Structure ==="
rm -rf "${APP_DIR}"
mkdir -p "${MACOS}" "${RESOURCES}"

echo "=== Copying Binaries ==="
cp "${PROJECT_DIR}/.build/release/zeddy-app" "${MACOS}/zeddy-app"
cp "${PROJECT_DIR}/.build/release/zeddy-daemon" "${MACOS}/zeddy-daemon"
cp "${PROJECT_DIR}/.build/release/zeddy" "${MACOS}/zeddy"
cp "${PROJECT_DIR}/.build/release/zeddy-mcp" "${MACOS}/zeddy-mcp"

echo "=== Copying Resources ==="
if [[ -f "${PROJECT_DIR}/Assets/AppIcon.icns" ]]; then
    cp "${PROJECT_DIR}/Assets/AppIcon.icns" "${RESOURCES}/AppIcon.icns"
fi
cp "${PROJECT_DIR}/Assets/zeddy-logo-manga.svg" "${RESOURCES}/zeddy-logo-manga.svg"

echo "=== Creating Info.plist ==="
cat << 'EOF' > "${CONTENTS}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>zeddy-app</string>
    <key>CFBundleIdentifier</key>
    <string>com.zeddy.zeddy-app</string>
    <key>CFBundleName</key>
    <string>Zeddy</string>
    <key>CFBundleDisplayName</key>
    <string>Zeddy</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "=== Ad-Hoc Signing Zeddy.app ==="
codesign --force --deep --sign - "${APP_DIR}"

echo "✓ Zeddy.app successfully built and signed at:"
echo "  ${APP_DIR}"
echo ""
echo "To test run:"
echo "  open ${APP_DIR}"
