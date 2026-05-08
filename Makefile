GO := $(shell test -x ../go/bin/go && echo ../go/bin/go || echo go)
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
BUILD_DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS := -ldflags "-X github.com/viraj/diskindexer/cmd.version=$(VERSION) -X github.com/viraj/diskindexer/cmd.buildDate=$(BUILD_DATE)"

BINARY := diskindexer
BINARY_LINUX := diskindexer-linux-amd64
SERVER := viraj@enterprise.virajchitnis.com

.PHONY: build build-linux install test clean

build:
	$(GO) build $(LDFLAGS) -o $(BINARY) .

build-linux:
	GOOS=linux GOARCH=amd64 $(GO) build $(LDFLAGS) -o $(BINARY_LINUX) .

install: build-linux
	scp $(BINARY_LINUX) $(SERVER):~/.local/bin/diskindexer

test:
	$(GO) test ./...

clean:
	rm -f $(BINARY) $(BINARY_LINUX)
