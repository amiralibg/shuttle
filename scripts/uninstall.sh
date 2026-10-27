#!/usr/bin/env bash
set -e

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

APP_DIR="$HOME/Applications/Shuttle.app"
USER_BIN="$HOME/.local/bin"
SYS_BIN="/usr/local/bin"
CONFIG_DIR="$HOME/.config/shuttle"
PLIST_PATH="$HOME/Library/LaunchAgents/com.amiralibg.shuttle.plist"
SOCKET_PATH="/tmp/shuttle-$USER.sock"

echo -e "${BOLD}${RED}======================================================${NC}"
echo -e "${BOLD}${RED}  🗑️  Fully Uninstalling Shuttle Window Manager        ${NC}"
echo -e "${BOLD}${RED}======================================================${NC}"

# 1. Stop Daemon
echo -e "\n${YELLOW}▶ Stopping running Shuttle daemon...${NC}"
if [ -S "$SOCKET_PATH" ]; then
    "$USER_BIN/shuttlectl" stop 2>/dev/null || true
    sleep 0.5
fi
killall shuttled 2>/dev/null || true
pkill -f "$APP_DIR/Contents/MacOS/shuttled" 2>/dev/null || true
sleep 0.5

# 2. Unload LaunchAgent if active
if [ -f "$PLIST_PATH" ]; then
    echo -e "${YELLOW}▶ Unloading and removing LaunchAgent service...${NC}"
    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
fi

# 3. Remove App Bundle
if [ -d "$APP_DIR" ]; then
    echo -e "${YELLOW}▶ Removing Shuttle.app from ~/Applications...${NC}"
    rm -rf "$APP_DIR"
fi

# 4. Remove Binaries
echo -e "${YELLOW}▶ Removing binaries from ~/.local/bin and /usr/local/bin...${NC}"
rm -f "$USER_BIN/shuttled" "$USER_BIN/shuttlectl"
if [ -w "$SYS_BIN" ]; then
    rm -f "$SYS_BIN/shuttled" "$SYS_BIN/shuttlectl" 2>/dev/null || true
elif [ -f "$SYS_BIN/shuttled" ] || [ -f "$SYS_BIN/shuttlectl" ]; then
    echo -e "${YELLOW}Note: Run with sudo if you wish to remove $SYS_BIN/shuttled${NC}"
fi

# 5. Clean Unix Domain Socket
rm -f "$SOCKET_PATH"

# 6. Configuration files
if [ "$1" == "--purge" ] || [ "$1" == "-p" ]; then
    echo -e "${YELLOW}▶ Purging configuration directory (~/.config/shuttle)...${NC}"
    rm -rf "$CONFIG_DIR"
else
    if [ -d "$CONFIG_DIR" ]; then
        echo -e "${BLUE}ℹ️  Config directory preserved at $CONFIG_DIR.${NC}"
        echo -e "   (To remove configs as well, run: ./scripts/uninstall.sh --purge)"
    fi
fi

echo -e "\n${BOLD}${GREEN}✅ Shuttle has been completely uninstalled from your system.${NC}\n"
