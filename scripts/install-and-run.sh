#!/usr/bin/env bash
set -e

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$HOME/Applications/Shuttle.app"
USER_BIN="$HOME/.local/bin"
SYS_BIN="/usr/local/bin"
CONFIG_DIR="$HOME/.config/shuttle"

echo -e "${BOLD}${BLUE}======================================================${NC}"
echo -e "${BOLD}${BLUE}  🚀 Installing and Running Shuttle Window Manager    ${NC}"
echo -e "${BOLD}${BLUE}======================================================${NC}"

# 1. Stop any currently running instance
echo -e "\n${YELLOW}▶ Stopping existing Shuttle daemon instances...${NC}"
if [ -S "/tmp/shuttle-$USER.sock" ]; then
    "$REPO_DIR/.build/release/shuttlectl" stop 2>/dev/null || true
    sleep 0.5
fi
killall shuttled 2>/dev/null || true
sleep 0.5

# 2. Build release binaries
echo -e "\n${YELLOW}▶ Building release binaries with Swift Package Manager...${NC}"
cd "$REPO_DIR"
swift build -c release

RELEASE_DIR="$REPO_DIR/.build/release"
if [ ! -f "$RELEASE_DIR/shuttled" ] || [ ! -f "$RELEASE_DIR/shuttlectl" ]; then
    echo -e "${RED}❌ Build failed: binaries not found in $RELEASE_DIR${NC}"
    exit 1
fi

# 3. Create Shuttle.app Bundle
echo -e "\n${YELLOW}▶ Packaging Shuttle.app bundle in ~/Applications...${NC}"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp -f "$RELEASE_DIR/shuttled" "$APP_DIR/Contents/MacOS/shuttled"
cp -f "$REPO_DIR/extra/Info.plist" "$APP_DIR/Contents/Info.plist"

# Ad-hoc codesign
echo -e "${YELLOW}▶ Applying ad-hoc codesignature to Shuttle.app...${NC}"
codesign --force --deep --sign - "$APP_DIR"

# 4. Install command line tools
echo -e "\n${YELLOW}▶ Installing CLI tools (shuttlectl, shuttled)...${NC}"
mkdir -p "$USER_BIN"
cp -f "$RELEASE_DIR/shuttled" "$USER_BIN/shuttled"
cp -f "$RELEASE_DIR/shuttlectl" "$USER_BIN/shuttlectl"
chmod +x "$USER_BIN/shuttled" "$USER_BIN/shuttlectl"

# Try installing to /usr/local/bin if writable
if [ -w "$SYS_BIN" ]; then
    cp -f "$RELEASE_DIR/shuttled" "$SYS_BIN/shuttled" 2>/dev/null || true
    cp -f "$RELEASE_DIR/shuttlectl" "$SYS_BIN/shuttlectl" 2>/dev/null || true
    chmod +x "$SYS_BIN/shuttled" "$SYS_BIN/shuttlectl" 2>/dev/null || true
fi

# Ensure ~/.local/bin is in PATH tip
if [[ ":$PATH:" != *":$USER_BIN:"* ]]; then
    echo -e "${YELLOW}💡 Tip: Add $USER_BIN to your PATH by adding this to ~/.zshrc:${NC}"
    echo -e "   export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# 5. Ensure Configuration directory exists
mkdir -p "$CONFIG_DIR"

# 6. Launch Shuttle.app
echo -e "\n${YELLOW}▶ Launching Shuttle.app...${NC}"
open -a "$APP_DIR"

# 7. Verify Daemon is running
echo -e "\n${YELLOW}▶ Verifying daemon startup...${NC}"
CONNECTED=false
for i in {1..10}; do
    if [ -S "/tmp/shuttle-$USER.sock" ]; then
        STATUS=$("$USER_BIN/shuttlectl" status 2>/dev/null || true)
        if [[ "$STATUS" == *"activeSpaceID"* ]]; then
            CONNECTED=true
            break
        fi
    fi
    sleep 0.4
done

if [ "$CONNECTED" = true ]; then
    echo -e "\n${BOLD}${GREEN}✅ Shuttle is now running!${NC}"
    echo -e "${GREEN}• Check your top macOS Menu Bar for the 🚀 Shuttle icon.${NC}"
    echo -e "${GREEN}• Alt + H/L to scroll ribbon columns.${NC}"
    echo -e "${GREEN}• Alt + R to cycle column width presets.${NC}"
    echo -e "${GREEN}• Alt + F to toggle full screen column.${NC}"
    echo -e "${GREEN}• Run 'shuttlectl status' anytime to inspect active state.${NC}"
else
    echo -e "\n${YELLOW}⚠️  Shuttle launched, but waiting for Accessibility permission.${NC}"
    echo -e "${YELLOW}Please ensure Shuttle.app is enabled in:${NC}"
    echo -e "${BOLD}System Settings -> Privacy & Security -> Accessibility${NC}"
    echo -e "Then re-run this script or launch with: open -a ~/Applications/Shuttle.app"
fi
