#!/usr/bin/env bash
set -e

APP_NAME="NewsTimer"
APP_BUNDLE="${APP_NAME}.app"
AUDIO_SRC="$(dirname "$0")/Resources/countdown.mp3"

echo "==> Building ${APP_NAME}..."

# Clean previous build
rm -rf "${APP_BUNDLE}"

# Create bundle structure
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Compile Swift
swiftc Sources/main.swift \
    -framework AppKit \
    -framework AVFoundation \
    -O \
    -o "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

echo "    Swift compiled OK"

# Copy Info.plist
cp Info.plist "${APP_BUNDLE}/Contents/Info.plist"

# Copy audio file (not included in repo — bring your own ~14s MP3)
if [ -f "${AUDIO_SRC}" ]; then
    cp "${AUDIO_SRC}" "${APP_BUNDLE}/Contents/Resources/countdown.mp3"
    echo "    Audio file copied OK"
else
    echo "    WARNING: Audio not found at: ${AUDIO_SRC}"
    echo "    Place a ~14s MP3 at that path, or copy it manually to:"
    echo "    ${APP_BUNDLE}/Contents/Resources/countdown.mp3"
fi

echo ""
echo "==> Done! App is at: $(pwd)/${APP_BUNDLE}"
echo ""
echo "    To run:    open ${APP_BUNDLE}"
echo "    To install: cp -r ${APP_BUNDLE} /Applications/"
