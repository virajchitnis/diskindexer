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

.PHONY: build build-linux build-darwin-arm64 build-darwin-amd64 install test clean release

build:
	$(GO) build $(LDFLAGS) -o $(BINARY) .

build-linux:
	GOOS=linux GOARCH=amd64 $(GO) build $(LDFLAGS) -o $(BINARY_LINUX) .

build-darwin-arm64:
	GOOS=darwin GOARCH=arm64 $(GO) build $(LDFLAGS) -o $(BINARY_DARWIN_ARM64) .

build-darwin-amd64:
	GOOS=darwin GOARCH=amd64 $(GO) build $(LDFLAGS) -o $(BINARY_DARWIN_AMD64) .

install: build-linux
	scp $(BINARY_LINUX) $(SERVER):~/.local/bin/diskindexer

test:
	$(GO) test ./...

release: build-linux build-darwin-arm64 build-darwin-amd64
	$(GH) release create $(VERSION) \
		$(BINARY_LINUX) \
		$(BINARY_DARWIN_ARM64) \
		$(BINARY_DARWIN_AMD64) \
		--title "$(VERSION)" \
		--notes-file RELEASE_NOTES.md

clean:
	rm -f $(BINARY) $(BINARY_LINUX) $(BINARY_DARWIN_ARM64) $(BINARY_DARWIN_AMD64)
