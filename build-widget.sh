#!/bin/zsh
set -euo pipefail

APP_NAME="VibeGauge"
APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
EXECUTABLE_NAME="CodexCreditsWidget"
ICON_FILE="AppIcon.icns"

mkdir -p .build
mkdir -p .build/module-cache
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

swiftc \
  -target arm64-apple-macosx15.0 \
  -module-cache-path .build/module-cache \
  CodexCreditsWidget.swift \
  -o "${MACOS_DIR}/${EXECUTABLE_NAME}" \
  -framework AppKit

cp "${ICON_FILE}" "${RESOURCES_DIR}/${ICON_FILE}"

/usr/libexec/PlistBuddy -c "Clear dict" "${CONTENTS_DIR}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleName string ${APP_NAME}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${APP_NAME}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string local.vibegauge.widget" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ${EXECUTABLE_NAME}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 15.0" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "${CONTENTS_DIR}/Info.plist"

echo "Built ${APP_DIR}"
