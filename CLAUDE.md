# Disk Indexer

A CLI tool for creating and searching offline indexes of large external hard disks.

## Purpose

Indexes external disks so they can be searched without the disk being plugged in. Indexes are stored as `.diskindex` files (standard SQLite with a custom extension). Supports a single global index or per-disk indexes that can be searched together.

## Build & Run

The Makefile auto-detects the Go binary: uses `../go/bin/go` if present
(local toolchain), otherwise falls back to `go` on PATH.

```bash
make build               # build for current platform
make build-linux         # cross-compile for Linux AMD64
make build-darwin-arm64  # cross-compile for macOS Apple Silicon
make build-darwin-amd64  # cross-compile for macOS Intel
make install             # build-linux + scp to enterprise.virajchitnis.com
make release             # build all three platform binaries + gh release create
make test                # run all tests
make clean               # remove build artifacts
```

The Makefile auto-detects the `gh` CLI at `../gh/bin/gh` (falling back to `gh` on PATH), mirroring the Go binary detection pattern.

Raw commands (if not using make):
```bash
go build -ldflags "-X github.com/viraj/diskindexer/cmd.version=$(git describe --tags --always --dirty) -X github.com/viraj/diskindexer/cmd.buildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ)" -o diskindexer .
```

## Test

```bash
make test
# or verbose:
../go/bin/go test ./internal/... -v
../go/bin/go test ./internal/db/... -run TestSchema
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
- **Directory sizes**: computed in Go at the end of every index run (`ComputeAndUpdateDirSizes`). All file rows are fetched in one query; sizes are accumulated in memory by walking each file's ancestor paths (O(N × depth)); collections are processed in parallel goroutines (disjoint subtrees); results are written back in sequential batched UPDATEs (200/tx) with progress callbacks. Replaces the previous O(N²) correlated SQL subquery.

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
diskindexer index <mount-path> --disk "Label" [--db path] [--collection "Label:/absolute/path"] [--exclude name] [--force]
diskindexer reindex <mount-path> --disk "Label" [--db path] [--exclude name]
diskindexer disks [--db path]
diskindexer delete-disk --disk "Label" [--db path]
diskindexer collections [--disk "Label"] [--db path]
diskindexer rename-collection <new-label> --collection "Label" [--disk "Label"] [--db path]
diskindexer delete-collection --collection "Label" [--disk "Label"] [--db path]
diskindexer search [query] [--db path]... [--no-tui]
diskindexer --version
```

## TUI Features

- **Live search**: 150ms debounce on every keystroke; no explicit submit needed.
- **Result cap**: TUI fetches at most 500 results; a `500+` indicator appears in the status bar when the cap is hit. Narrowing the query reveals more results.
- **Search spinner**: A spinner animates in the search bar while a query is in flight.
- **Sorting**: `s` cycles NAME ▲▼ → SIZE ▲▼ → MODIFIED ▲▼ using `sort.SliceStable`.
- **Type filter**: `t` cycles All → Files → Dirs.
- **Disk filter**: `d`/`D` cycles forward/backward through indexed disks.
- **Collection filter**: `c`/`C` cycles forward/backward through collections. Coupled to the disk filter: selecting a disk narrows the collection list to only that disk's collections, and changing the disk resets the collection to "(all)". When disk is "(all)", all unique collection names across all disks are shown.
- **Browser panel**: `b` toggles a 28-char sidebar on the left showing all disks and their collections as an expandable tree. Navigating the panel with `↑`/`↓` and pressing `Enter` sets the disk/collection filter (synced with the `d`/`c` chips at the top). `→`/`←` expand or collapse disk nodes. `Esc` or `b` while panel is focused returns focus to the search bar without closing the panel.
- **Detail panel**: `i` toggles a 3-line panel below the selected row showing full path, size (with commas), modified date, type, disk, and collection.
- **Duplicate highlighting**: entries sharing the same `name|size` across all results are rendered in amber. This applies to both files and directories; zero-size directories are excluded (empty or not yet sized).
- **Clipboard**: `Enter` copies the full path to the system clipboard.

## Potential Future Features

### Browse directory contents
When a directory is selected in the TUI, allow the user to "enter" it and view its descendants — turning the tool into a navigable file browser in addition to a search tool.

**Design notes:**
- A new key (`→` or `l`) enters a directory; `←` or `h` navigates back up a level.
- A browse stack (`[]string`) is maintained in the model. The tip of the stack becomes a path-prefix filter on every search (`AND f.path LIKE ? || '/%'`).
- A breadcrumb row shows the current location below the search bar.
- The existing search bar continues to work within the directory context.
- `Enter` on a file still copies to clipboard; the new key is solely for navigation.
- Needs a new `PathPrefix string` field in `db.SearchParams` and a corresponding SQL filter.
- The simplest implementation shows all descendants (not just immediate children), which avoids the need for SQL path-depth logic.
- Immediate-children-only mode would require stripping trailing path components, which SQLite cannot do natively and would need application-level post-filtering.

## Development Conventions

- **Keep README.md in sync**: any change that affects user-facing behaviour (new commands, changed flags, TUI controls, etc.) must also update `README.md` in the same PR/commit.
- **Versioning**: the binary version is embedded at build time via `-ldflags`. Use `git describe --tags --always --dirty` as the value. Falls back to `"dev"` when built without ldflags.
- **Path format**: file paths are stored as `DiskLabel/Collection/path/to/file` — the disk label is always the first component.
- **Collections outside mount**: `--collection` paths do not need to be under the mount path; they are indexed relative to the collection root.
- **Install target**: `make install` cross-compiles for Linux AMD64 and deploys to `~/.local/bin/diskindexer` on `enterprise.virajchitnis.com` via `scp`.

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
