#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Scriptoria"
SCHEME="Scriptoria"
BUILD_DIR="${PROJECT_DIR}/.build/app"
DESTINATION="/Applications/${APP_NAME}.app"

echo "=============================="
echo "  Scriptoria Build & Install"
echo "=============================="
echo ""
echo "Project: ${PROJECT_DIR}"
echo ""

# Step 1: Build the CLI
echo "→ Building CLI..."
cd "${PROJECT_DIR}"
swift build -c release --product scriptoria 2>&1 | tail -3
CLI_BIN="${PROJECT_DIR}/.build/release/scriptoria"
echo "  CLI: ${CLI_BIN}"

# Step 2: Build the App (clean first to ensure latest code)
echo ""
echo "→ Cleaning previous build..."
xcodebuild \
    -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    clean 2>&1 | tail -1

echo "→ Building ${APP_NAME}.app (Release)..."
xcodebuild \
    -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES \
    ONLY_ACTIVE_ARCH=NO \
    build 2>&1 | grep -E '(Build Succeeded|error:|BUILD FAILED)' || true

# Find the built .app
APP_PATH=$(find "${BUILD_DIR}" -name "${APP_NAME}.app" -type d | head -1)

if [ -z "${APP_PATH}" ]; then
    echo "❌ Build failed: ${APP_NAME}.app not found"
    exit 1
fi

echo "  App: ${APP_PATH}"

# Step 3: Install to /Applications
echo ""
echo "→ Installing to /Applications..."

# Remove old version if it exists
if [ -d "${DESTINATION}" ]; then
    # Quit the app if running
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
    sleep 1
    rm -rf "${DESTINATION}"
fi

cp -R "${APP_PATH}" "${DESTINATION}"
echo "  Installed: ${DESTINATION}"

# Step 4: Install CLI symlink
echo ""
echo "→ Installing CLI to /usr/local/bin..."
if ln -sf "${CLI_BIN}" /usr/local/bin/scriptoria 2>/dev/null; then
    echo "  Symlink: /usr/local/bin/scriptoria → ${CLI_BIN}"
else
    # Need elevated privileges
    osascript -e "do shell script \"mkdir -p /usr/local/bin && ln -sf '${CLI_BIN}' /usr/local/bin/scriptoria\" with administrator privileges"
    echo "  Symlink: /usr/local/bin/scriptoria → ${CLI_BIN}"
fi

echo ""
echo "=============================="
echo "  ✅ Installation Complete"
echo "=============================="
echo ""
echo "  App:  ${DESTINATION}"
echo "  CLI:  /usr/local/bin/scriptoria"
echo ""
echo "  Launch: open -a ${APP_NAME}"
echo ""
