PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
APP_DIR ?= $(HOME)/Applications/Shuttle.app
LAUNCH_AGENTS_DIR ?= $(HOME)/Library/LaunchAgents

.PHONY: all build release test clean install uninstall app

all: build

build:
	swift build

release:
	swift build -c release

test:
	swift test

clean:
	swift package clean
	rm -rf .build

app: release
	@echo "📦 Creating Shuttle.app wrapper for macOS Accessibility..."
	@mkdir -p "$(APP_DIR)/Contents/MacOS"
	@mkdir -p "$(APP_DIR)/Contents/Resources"
	@cp -f .build/release/shuttled "$(APP_DIR)/Contents/MacOS/shuttled"
	@cp -f extra/Info.plist "$(APP_DIR)/Contents/Info.plist"
	@echo "✅ Shuttle.app created at $(APP_DIR)"

install: release app
	@echo "🚀 Installing shuttled and shuttlectl to $(BINDIR)..."
	@mkdir -p $(BINDIR)
	@cp -f .build/release/shuttled $(BINDIR)/shuttled
	@cp -f .build/release/shuttlectl $(BINDIR)/shuttlectl
	@chmod +x $(BINDIR)/shuttled $(BINDIR)/shuttlectl
	@mkdir -p $(HOME)/.config/shuttle
	@echo "✅ Binaries installed."
	@echo "To grant Accessibility permissions:"
	@echo "  Open 'System Settings' -> 'Privacy & Security' -> 'Accessibility'"
	@echo "  Add and toggle ON '$(APP_DIR)' (or your terminal application)."

uninstall:
	@echo "🗑️  Uninstalling Shuttle..."
	@rm -f $(BINDIR)/shuttled
	@rm -f $(BINDIR)/shuttlectl
	@rm -rf "$(APP_DIR)"
	@rm -f "$(LAUNCH_AGENTS_DIR)/com.amiralibg.shuttle.plist"
	@echo "✅ Uninstalled successfully."
