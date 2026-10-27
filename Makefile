PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
APP_DIR ?= $(HOME)/Applications/Shuttle.app
LAUNCH_AGENTS_DIR ?= $(HOME)/Library/LaunchAgents

.PHONY: all build release test clean install uninstall run app

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
	@codesign --force --deep --sign - "$(APP_DIR)"
	@echo "✅ Shuttle.app created and ad-hoc signed at $(APP_DIR)"

install: release app
	@echo "🚀 Installing shuttled and shuttlectl..."
	@./scripts/install-and-run.sh

run:
	@./scripts/install-and-run.sh

uninstall:
	@./scripts/uninstall.sh
