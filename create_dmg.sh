#!/usr/bin/env bash
set -e

APP_NAME="NewsTimer"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
TMP_DMG="tmp_${DMG_NAME}"
VOLUME_NAME="News Timer"

if [ ! -d "${APP_BUNDLE}" ]; then
    echo "ERROR: ${APP_BUNDLE} not found. Run build.sh first."
    exit 1
fi

echo "==> Creating DMG: ${DMG_NAME}..."

rm -f "${DMG_NAME}" "${TMP_DMG}"

hdiutil create -size 80m -fs HFS+ -volname "${VOLUME_NAME}" "${TMP_DMG}" -quiet
hdiutil attach "${TMP_DMG}" -mountpoint "/Volumes/${VOLUME_NAME}" -quiet

cp -r "${APP_BUNDLE}" "/Volumes/${VOLUME_NAME}/"
ln -s /Applications "/Volumes/${VOLUME_NAME}/Applications"

hdiutil detach "/Volumes/${VOLUME_NAME}" -quiet
hdiutil convert "${TMP_DMG}" -format UDZO -o "${DMG_NAME}" -quiet
rm -f "${TMP_DMG}"

echo ""
echo "==> Done! DMG created: $(pwd)/${DMG_NAME}"
echo "    Upload this file to GitHub Releases."
