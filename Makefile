GO := $(shell test -x ../go/bin/go && echo ../go/bin/go || echo go)
GH := $(shell test -x ../gh/bin/gh && echo ../gh/bin/gh || echo gh)
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
CLT_DEV       := /Library/Developer/CommandLineTools/Library/Developer
SWIFT_TEST    := swift test $(if $(wildcard $(CLT_DEV)/Frameworks),-Xswiftc -F -Xswiftc $(CLT_DEV)/Frameworks -Xlinker -F -Xlinker $(CLT_DEV)/Frameworks -Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks -Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib)

.PHONY: build build-linux build-darwin-arm64 build-darwin-amd64 install install-service mac-app test test-apple clean release

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

test-apple:
	cd apple && $(SWIFT_TEST)

# Builds build/DiskIndexer.app: a universal SwiftUI app with a universal
# diskindexer binary bundled in Resources for local mode. Needs only the
# Command Line Tools (no Xcode). Ad-hoc signed, so on another Mac the first
# launch needs right-click > Open.
mac-app: build-darwin-arm64 build-darwin-amd64
	cd apple && $(SWIFT_RELEASE) --triple arm64-apple-macosx14.0 --scratch-path .build/arm64
	cd apple && $(SWIFT_RELEASE) --triple x86_64-apple-macosx14.0 --scratch-path .build/x86_64
	rm -rf $(APP) $(APP_ZIP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	lipo -create apple/.build/arm64/release/DiskIndexerMac apple/.build/x86_64/release/DiskIndexerMac \
		-output $(APP)/Contents/MacOS/DiskIndexer
	lipo -create $(BINARY_DARWIN_ARM64) $(BINARY_DARWIN_AMD64) -output $(APP)/Contents/Resources/diskindexer
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
	rm -rf build apple/.build
