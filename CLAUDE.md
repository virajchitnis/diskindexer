# Disk Indexer

A CLI tool for creating and searching offline indexes of large external hard disks.

## Purpose

Indexes external disks so they can be searched without the disk being plugged in. Indexes are stored as `.diskindex` files (standard SQLite with a custom extension). Supports a single global index or per-disk indexes that can be searched together.

## Build & Run

```bash
# Mac (ARM64) — uses the local Go toolchain extracted under go/
../go/bin/go build -ldflags "-X github.com/viraj/diskindexer/cmd.version=$(git describe --tags --always --dirty)" -o diskindexer .
./diskindexer --version

# Cross-compile for Linux AMD64 (e.g. Ubuntu server)
GOOS=linux GOARCH=amd64 ../go/bin/go build -ldflags "-X github.com/viraj/diskindexer/cmd.version=$(git describe --tags --always --dirty)" -o diskindexer-linux-amd64 .

# Install to server (enterprise.virajchitnis.com, user: viraj)
scp diskindexer-linux-amd64 viraj@enterprise.virajchitnis.com:~/.local/bin/diskindexer
```

## Test

```bash
../go/bin/go test ./...
../go/bin/go test ./internal/... -v        # verbose unit tests
../go/bin/go test ./internal/db/... -run TestSchema  # specific test
```

## Project Structure

```
main.go                  # entry point
cmd/                     # cobra commands (one file per command)
  root.go                # root command, persistent flags (--db)
  index.go               # index + reindex commands
  disks.go               # disks list command
  collections.go         # collections list + rename commands
  search.go              # search command (launches TUI)
internal/
  config/                # TOML config parsing (~/.config/diskindexer/config.toml)
  db/                    # SQLite schema, migrations, all DB operations
  indexer/               # filesystem walk, change detection, incremental logic
  search/                # query building, filter application, multi-DB merge
tui/                     # bubbletea interactive TUI (model, styles, tests)
testdata/                # synthetic file trees for integration tests
```

## Key Design Decisions

- **Pure-Go SQLite** (`modernc.org/sqlite`): no CGo, no runtime deps, single static binary on Linux and macOS.
- **`.diskindex` extension**: standard SQLite file, custom extension for clarity.
- **Incremental indexing via `(path, size, mtime)`**: no hashing. Fast on 5TB+.
- **Collections = top-level folders** on a disk, auto-detected on index. Manual override via `--collection "Label:/absolute/path"`.
- **Multi-DB search**: each `.diskindex` opened as a separate connection; results merged in Go before display.
- **FTS5 virtual table** on `(name, path)` with triggers to stay in sync — powers fast text search.

## Index File Location

- Default global index: `~/.config/diskindexer/global.diskindex`
- Config file: `~/.config/diskindexer/config.toml`
- Override per-command with `--db <path>`

## Config Format

```toml
default_db = "~/.config/diskindexer/global.diskindex"

known_dbs = [
  "~/.config/diskindexer/global.diskindex",
]
```

## CLI Commands

```bash
diskindexer index <mount-path> --disk "Label" [--db path] [--collection "Label:/absolute/path"] [--force]
diskindexer reindex <mount-path> --disk "Label" [--db path]
diskindexer disks [--db path]
diskindexer collections --disk "Label" [--db path]
diskindexer rename-collection <id> <new-label> [--db path]
diskindexer search [--db path]...
```

## Libraries

| Library | Purpose |
|---|---|
| `modernc.org/sqlite` | Pure-Go SQLite driver |
| `spf13/cobra` | CLI commands and flags |
| `charmbracelet/bubbletea` | TUI framework |
| `charmbracelet/bubbles` | TUI components (text input) |
| `charmbracelet/lipgloss` | TUI styling |
| `charmbracelet/x/term` | TTY detection for TUI vs text output |
| `atotto/clipboard` | Clipboard write on Enter in TUI |
| `BurntSushi/toml` | Config file parsing |
| `stretchr/testify` | Test assertions |
