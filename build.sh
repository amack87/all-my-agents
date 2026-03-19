#!/bin/bash
set -euo pipefail

APP_NAME="AllMyAgents"
BUILD_CONFIG="${1:-release}"
BUILD_DIR=".build/${BUILD_CONFIG}"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"

echo "==> Building ${APP_NAME} (${BUILD_CONFIG})..."
swift build -c "${BUILD_CONFIG}"

echo "==> Assembling .app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${CONTENTS}/MacOS"
mkdir -p "${CONTENTS}/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${CONTENTS}/MacOS/${APP_NAME}"
cp "Info.plist" "${CONTENTS}/Info.plist"

echo "==> Compiling tmux-attach-helper..."
cc -o "${CONTENTS}/MacOS/tmux-attach-helper" Sources/tmux-attach-helper.c

if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${CONTENTS}/Resources/AppIcon.icns"
fi

echo "==> Signing (ad-hoc)..."
codesign --force --deep --sign - \
    --entitlements "AllMyAgents.entitlements" \
    "${APP_BUNDLE}"

echo "==> Done: ${APP_BUNDLE}"
echo ""
echo "To run:     open ${APP_BUNDLE}"
echo "To install: cp -R ${APP_BUNDLE} /Applications/"
