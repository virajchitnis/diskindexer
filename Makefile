# Local toolchains live next to the checkout (../go, ../gh). In a git worktree
# that's next to the main checkout instead, so look there too. Paths are
# resolved to absolute ones (the main checkout's path has a space in it).
MAIN_ROOT := $(shell dirname "$$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" 2>/dev/null)
find_tool = $(shell for d in ../$(1)/bin "$(MAIN_ROOT)/../$(1)/bin"; do if [ -x "$$d/$(1)" ]; then echo "$$(cd "$$d" && pwd -P)/$(1)"; exit 0; fi; done; echo $(1))
GO := $(call find_tool,go)
GH := $(call find_tool,gh)
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
BUILD_DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS := -ldflags "-X github.com/viraj/diskindexer/cmd.version=$(VERSION) -X github.com/viraj/diskindexer/cmd.buildDate=$(BUILD_DATE)"

BINARY              := diskindexer
BINARY_LINUX        := diskindexer-linux-amd64
BINARY_DARWIN_ARM64 := diskindexer-darwin-arm64
BINARY_DARWIN_AMD64 := diskindexer-darwin-amd64
SERVER              := viraj@enterprise.virajchitnis.com

APP           := build/DiskIndexer.app
APP_ZIP       := build/DiskIndexer-macOS.zip
SWIFT_RELEASE := swift build -c release --product DiskIndexerMac
# Command Line Tools ship swift-testing but not on the default search path.
# Only add it when CLT is the active toolchain; full Xcode finds its own.
CLT_DEV       := /Library/Developer/CommandLineTools/Library/Developer
CLT_ACTIVE    := $(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null))
SWIFT_TEST    := swift test $(if $(CLT_ACTIVE),-Xswiftc -F -Xswiftc $(CLT_DEV)/Frameworks -Xlinker -F -Xlinker $(CLT_DEV)/Frameworks -Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks -Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib)

.PHONY: build build-linux build-darwin-arm64 build-darwin-amd64 install install-service icon mac-app test test-apple coverage coverage-go coverage-apple clean release

build:
	$(GO) build $(LDFLAGS) -o $(BINARY) .

build-linux:
	GOOS=linux GOARCH=amd64 $(GO) build $(LDFLAGS) -o $(BINARY_LINUX) .

build-darwin-arm64:
	GOOS=darwin GOARCH=arm64 $(GO) build $(LDFLAGS) -o $(BINARY_DARWIN_ARM64) .

build-darwin-amd64:
	GOOS=darwin GOARCH=amd64 $(GO) build $(LDFLAGS) -o $(BINARY_DARWIN_AMD64) .

# Upload then rename: overwriting a binary the service is running fails with
# "Text file busy" on Linux, but replacing it via rename is fine.
install: build-linux
	scp $(BINARY_LINUX) $(SERVER):~/.local/bin/diskindexer.new
	ssh $(SERVER) 'mv ~/.local/bin/diskindexer.new ~/.local/bin/diskindexer'

# Installs the binary plus a systemd user service running `diskindexer serve`,
# which the macOS app reaches over an SSH tunnel. Restarts it to pick up the
# new binary. Run `sudo loginctl enable-linger $$USER` once on the server so
# the service keeps running while you're logged out.
install-service: install
	ssh $(SERVER) 'mkdir -p ~/.config/systemd/user'
	scp deploy/diskindexer.service $(SERVER):~/.config/systemd/user/diskindexer.service
	ssh $(SERVER) 'systemctl --user daemon-reload && systemctl --user enable diskindexer && systemctl --user restart diskindexer && systemctl --user --no-pager status diskindexer | head -5'

test:
	$(GO) test ./...

# The app-model tests drive a real `diskindexer serve`, so build it first.
test-apple: build
	cd apple && DISKINDEXER_BIN="$(CURDIR)/$(BINARY)" $(SWIFT_TEST)

# Coverage gates (CI runs both). Go counts every package, across package
# boundaries; Swift counts the app logic in DiskIndexerKit (views are
# exercised by the UI tests instead).
COVERAGE_MIN ?= 80

coverage: coverage-go coverage-apple

# Cross-package coverage shells out to `go`, so make sure it's on PATH.
coverage-go:
	PATH="$(dir $(GO)):$$PATH" $(GO) test -coverpkg=./... -coverprofile=coverage.out ./...
	PATH="$(dir $(GO)):$$PATH" scripts/check-coverage.sh go coverage.out $(COVERAGE_MIN)

coverage-apple: build
	cd apple && DISKINDEXER_BIN="$(CURDIR)/$(BINARY)" $(SWIFT_TEST) --enable-code-coverage
	scripts/check-coverage.sh swift apple $(COVERAGE_MIN)

# Renders apple/Icon/AppIcon.svg into build/icon/AppIcon.icns (macOS) and
# build/icon/AppIcon-1024.png (for the future iOS app).
icon:
	rm -rf build/icon
	swift apple/Icon/render.swift apple/Icon/AppIcon.svg build/icon
	iconutil -c icns build/icon/AppIcon.iconset -o build/icon/AppIcon.icns

# Builds build/DiskIndexer.app: a universal SwiftUI app with a universal
# diskindexer binary bundled in Resources for local mode. Needs only the
# Command Line Tools (no Xcode). Ad-hoc signed, so on another Mac the first
# launch needs right-click > Open.
mac-app: build-darwin-arm64 build-darwin-amd64 icon
	cd apple && $(SWIFT_RELEASE) --triple arm64-apple-macosx14.0 --scratch-path .build/arm64
	cd apple && $(SWIFT_RELEASE) --triple x86_64-apple-macosx14.0 --scratch-path .build/x86_64
	rm -rf $(APP) $(APP_ZIP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	lipo -create apple/.build/arm64/release/DiskIndexerMac apple/.build/x86_64/release/DiskIndexerMac \
		-output $(APP)/Contents/MacOS/DiskIndexer
	lipo -create $(BINARY_DARWIN_ARM64) $(BINARY_DARWIN_AMD64) -output $(APP)/Contents/Resources/diskindexer
	cp build/icon/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	sed 's/__VERSION__/$(patsubst v%,%,$(VERSION))/g' apple/Info.plist > $(APP)/Contents/Info.plist
	codesign --force --deep --sign - $(APP)
	cd build && ditto -c -k --keepParent DiskIndexer.app DiskIndexer-macOS.zip

release: build-linux build-darwin-arm64 build-darwin-amd64 mac-app
	$(GH) release create $(VERSION) \
		$(BINARY_LINUX) \
		$(BINARY_DARWIN_ARM64) \
		$(BINARY_DARWIN_AMD64) \
		$(APP_ZIP) \
		--title "$(VERSION)" \
		--notes-file RELEASE_NOTES.md

clean:
	rm -f $(BINARY) $(BINARY_LINUX) $(BINARY_DARWIN_ARM64) $(BINARY_DARWIN_AMD64)
	rm -rf build apple/.build coverage.out
