#!/bin/bash
# lil agents — build & install script for Intel + Apple Silicon Macs
# Run this AFTER installing Xcode from the App Store.
# Usage: bash build-and-install.sh

set -e

echo ""
echo "🏗  lil agents — build & install"
echo "================================="

# Check Xcode
if ! command -v xcodebuild &> /dev/null; then
    echo ""
    echo "❌  Xcode not found."
    echo ""
    echo "    1. Open App Store"
    echo "    2. Search for 'Xcode'"
    echo "    3. Install (free, ~8GB)"
    echo "    4. Open Xcode once so it finishes setup"
    echo "    5. Run this script again"
    echo ""
    exit 1
fi

XCODE_VER=$(xcodebuild -version | head -1)
echo "✅  $XCODE_VER found"

# Accept license if needed
sudo xcodebuild -license accept 2>/dev/null || true

# Build Release (universal binary: arm64 + x86_64)
echo ""
echo "⚙️   Building universal binary (arm64 + x86_64)..."
echo "    This takes 1-2 minutes on first build..."
echo ""

BUILD_DIR="$(pwd)/.build/xcode"
mkdir -p "$BUILD_DIR"

xcodebuild \
    -project lil-agents.xcodeproj \
    -scheme "lil agents" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    build \
    2>&1 | grep -E "error:|warning:|Build succeeded|Build FAILED|Compiling|Linking" | tail -30

# Find built app
APP_PATH=$(find "$BUILD_DIR" -name "lil agents.app" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo ""
    echo "❌  Build failed — app not found."
    echo "    Try opening lil-agents.xcodeproj in Xcode and hitting ▶ Run."
    exit 1
fi

# Check architecture
echo ""
ARCHS=$(lipo -info "$APP_PATH/Contents/MacOS/lil agents" 2>/dev/null || echo "unknown")
echo "✅  Built: $ARCHS"

# Install to /Applications
echo ""
echo "📦  Installing to /Applications..."
if [ -d "/Applications/lil agents.app" ]; then
    rm -rf "/Applications/lil agents.app"
fi
cp -R "$APP_PATH" "/Applications/lil agents.app"
echo "✅  Installed to /Applications/lil agents.app"

# Remove quarantine flag (so macOS doesn't block it)
echo ""
echo "🔓  Removing quarantine flag..."
xattr -cr "/Applications/lil agents.app" 2>/dev/null || true
echo "✅  Done"

echo ""
echo "🎉  lil agents is installed!"
echo ""
echo "    Open it:  open '/Applications/lil agents.app'"
echo "    Or:       find it in Launchpad / Applications folder"
echo ""
echo "    First run: look for the lil agents icon in your menu bar"
echo "    then watch Bruce & Jazz appear above your dock!"
echo ""

# Offer to open it now
read -p "Open lil agents now? (y/n): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    open "/Applications/lil agents.app"
fi
