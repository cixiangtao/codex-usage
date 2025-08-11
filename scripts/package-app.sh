#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexUsage"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.anys.codexusage}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/dist}"
APP_PATH="${OUTPUT_DIR}/${APP_NAME}.app"

usage() {
  cat <<EOF
Usage: scripts/package-app.sh

Environment:
  BUNDLE_IDENTIFIER   Bundle identifier. Default: ${BUNDLE_IDENTIFIER}
  VERSION             CFBundleShortVersionString. Default: ${VERSION}
  BUILD_NUMBER        CFBundleVersion. Default: ${BUILD_NUMBER}
  OUTPUT_DIR          Output directory. Default: ${OUTPUT_DIR}
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

cd "${ROOT_DIR}"

printf '[package] Building release executable...\n'
swift build -c release --product "${APP_NAME}"

BIN_DIR="$(swift build -c release --show-bin-path)"
EXECUTABLE_PATH="${BIN_DIR}/${APP_NAME}"
RESOURCE_BUNDLE="${BIN_DIR}/${APP_NAME}_${APP_NAME}.bundle"

if [[ ! -x "${EXECUTABLE_PATH}" ]]; then
  printf 'error: release executable not found at %s\n' "${EXECUTABLE_PATH}" >&2
  exit 1
fi

rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"

cp "${EXECUTABLE_PATH}" "${APP_PATH}/Contents/MacOS/${APP_NAME}"

if [[ -d "${RESOURCE_BUNDLE}" ]]; then
  cp -R "${RESOURCE_BUNDLE}" "${APP_PATH}/Contents/Resources/"
fi

if [[ -f "Sources/CodexUsage/Resources/AppIcon.icns" ]]; then
  cp "Sources/CodexUsage/Resources/AppIcon.icns" "${APP_PATH}/Contents/Resources/AppIcon.icns"
fi

cat > "${APP_PATH}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_IDENTIFIER}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 anys.</string>
</dict>
</plist>
EOF

codesign --force --sign - "${APP_PATH}" >/dev/null

printf '[package] Created %s\n' "${APP_PATH}"
