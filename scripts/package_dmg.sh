#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/Zeddy.app"
DMG_PATH="${DIST_DIR}/Zeddy.dmg"
STAGING_DIR="$(mktemp -d -t zeddy_dmg_staging.XXXXXX)"

trap 'rm -rf "${STAGING_DIR}"' EXIT

if [ ! -d "${APP_DIR}" ]; then
  "${SCRIPT_DIR}/package_app.sh"
fi

echo "=== Staging DMG contents ==="
cp -R "${APP_DIR}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

rm -f "${DMG_PATH}"

echo "=== Creating DMG image ==="
hdiutil create \
  -volname "Zeddy" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

echo "✓ Zeddy.dmg created at: ${DMG_PATH}"
