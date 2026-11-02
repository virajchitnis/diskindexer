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
make install             # build-linux + scp (via rename) to enterprise.virajchitnis.com
make install-service     # install + systemd user service running `diskindexer serve`
make mac-app             # build/DiskIndexer.app (universal, bundles diskindexer) + zip
make dmg                 # build/DiskIndexer.dmg (app + Applications link); attached by `make release`
make install-mac         # app → /Applications, CLI symlink → ~/.local/bin/diskindexer
make icon                # render apple/Icon/AppIcon.svg → .icns + 1024px PNG
make test-apple          # Swift tests incl. AppModel tests against a real `serve` (builds the binary first)
make coverage            # Go + Swift coverage gates (fail below COVERAGE_MIN=80)
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

CI (`.github/workflows/ci.yml`) runs on every push to main and every PR:
- Ubuntu: Go vet, race tests, the Go coverage gate, and cross-compiles.
- macOS: `make coverage-apple` and `make mac-app` (uploads the app zip).
- macOS UI tests: generates `apple/Xcode/DiskIndexer.xcodeproj` from `project.yml` with XcodeGen and runs the XCUITest suite in `apple/UITests`. It uploads the `.xcresult` on failure.

Coverage gates are 80%. Go is measured with `-coverpkg=./...` (cross-package); Swift counts `DiskIndexerKit` excluding `Views/` (views are covered by the UI tests). CLI tests in `cmd/cmd_test.go` run commands in-process with a scratch HOME and reset cobra flags between runs (`resetFlags`). New UI-test hooks: accessibility identifiers `index.diskLabel`, `index.mountPath`, `index.start`, `results`, `status.count`, `job.phase`. The UI tests launch the app with `-selectedConnection local` and the `DISKINDEXER_BIN`/`DISKINDEXER_DB` env vars.

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
  serve.go               # serve command: HTTP API for the GUI apps
internal/
  api/                   # JSON wire types + Service (search, manage, index jobs, fs browse)
  server/                # net/http routes over api.Service, SSE job progress, bearer auth
  config/                # TOML config parsing (~/.config/diskindexer/config.toml)
  db/                    # SQLite schema, migrations, all DB operations
  indexer/               # filesystem walk, change detection, incremental logic
  search/                # query building, filter application, multi-DB merge
tui/                     # bubbletea interactive TUI (model, styles, tests)
apple/                   # SwiftPM package: DiskIndexerKit (shared, macOS+iOS) + DiskIndexerMac app
deploy/                  # systemd user unit for `diskindexer serve`
```

## Key Design Decisions

- **Pure-Go SQLite** (`modernc.org/sqlite`): no CGo, no runtime deps, single static binary on Linux and macOS.
- **`.diskindex` extension**: standard SQLite file, custom extension for clarity.
- **Incremental indexing via `(path, size, mtime)`**: no hashing. Fast on 5TB+.
- **Collections = top-level folders** on a disk, auto-detected on index. Manual override via `--collection "Label:/absolute/path"`.
- **Multi-DB search**: each `.diskindex` opened as a separate connection; results merged in Go before display.
- **FTS5 virtual table** on `(name, path)` with triggers to stay in sync — powers fast text search.
- **Directory sizes**: computed in Go at the end of every index run (`ComputeAndUpdateDirSizes`). All file rows are fetched in one query; sizes are accumulated in memory by walking each file's ancestor paths (O(N × depth)); collections are processed in parallel goroutines (disjoint subtrees); results are written back in sequential batched UPDATEs (200/tx) with progress callbacks. Replaces the previous O(N²) correlated SQL subquery.

- **GUI architecture**: the Go binary is the only engine. `diskindexer serve` exposes `internal/api` as JSON over HTTP (`/v1/...`; bump `api.Version` on breaking changes). The macOS app always talks to that API: in local mode it launches its bundled binary with `--listen 127.0.0.1:0 --stdin-watch` and a random token; in remote mode it `ssh -L`-forwards a loopback port to the server's Unix socket. Index jobs run in the server (cancellable via `indexer.RunContext`) and each opens its own DB handle, so searches stay responsive during a run.
- **Results table rebuilds per result set**: `ResultsTable` is keyed with `.id(model.resultsGeneration)`, which `setResults` bumps only when the results actually change. Letting SwiftUI insert hundreds of rows into a live `Table`/`List` makes AppKit log "reentrant operation in its NSTableView delegate" (slated to become an assert). Column widths survive via `TableColumnCustomization` in `@SceneStorage`. Keep this if you touch the table.
- **Connection states**: `ConnectionStatus` is connecting → connected, or `.waiting` (first connect failing transiently; retried with backoff), `.reconnecting` (was connected), `.failed` (needs the user). Transports throw `ConnectionFailure(isTransient:)`; `SSHFailureKind.classify` sorts ssh's stderr into network/hostKey/auth/other, and only hostKey and auth stop retrying. Ordinary requests time out after 15s; progress streams use a separate 120s session.
- **Job recovery**: if a job's progress stream ends while the job is still running and the connection is fine (e.g. the server restarted behind a live tunnel), `AppModel.watch` asks `GET /v1/jobs/{id}`. It re-attaches if the job is still running, marks it `.interrupted` (client-only state) on a 404, or marks it lost after `jobRecheckAttempts`. `refreshJobs` keeps interrupted and orphaned jobs.
- **Child processes must die with the app**: the local server uses `serve --stdin-watch`; the SSH tunnel runs through `diesWithParent` (a `/bin/sh` wrapper that kills ssh when the app's stdin pipe closes). `disconnect()` closes that pipe rather than only terminating the wrapper. Without this, a crash or force quit leaves `ssh -N` tunnels running forever.
- **Swift code layout**: anything needing `Process`/AppKit stays in `DiskIndexerMac`; `DiskIndexerKit` must stay iOS-compatible for the planned iPhone/iPad app (remote-only, SSH via Citadel, sideloaded with AltStore).

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

# Skipped by every index run (CLI and serve), on top of each disk's own excludes.
default_excludes = [".snapshots", "lost+found"]
```

## CLI Commands

```bash
diskindexer index [mount-path] --disk "Label" [--db path] [--collection "Label:/absolute/path"] [--exclude name] [--force]   # mount-path optional with --collection
diskindexer reindex <mount-path> --disk "Label" [--db path] [--exclude name]
diskindexer disks [--db path]
diskindexer delete-disk --disk "Label" [--db path]
diskindexer collections [--disk "Label"] [--db path]
diskindexer rename-collection <new-label> --collection "Label" [--disk "Label"] [--db path]
diskindexer delete-collection --collection "Label" [--disk "Label"] [--db path]
diskindexer move-collection --collection "Label" [--disk "Label"] --to "Label" [--db path]
diskindexer search [query] [--db path]... [--no-tui]
diskindexer serve [--listen unix:/path|host:port]... [--token T] [--db path]...
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
- **Excludes**: patterns match file *and* folder names (`filepath.Match`) at any depth; excluded entries aren't marked seen, so previously indexed copies are removed. Effective excludes = `Options.DefaultExcludes` (config `default_excludes`, unless `--no-default-excludes` / `noDefaultExcludes`) ∪ the disk's own. `Options.Excludes == nil` reuses the disk's saved list (`disks.excludes`, JSON, added by a migration in `db.migrate`); a non-nil slice, even empty, replaces it. The app always sends the field, so clearing it clears the list.
- **Index progress and errors**: `indexer.ProgressUpdate.Phase` runs loading → (clearing) → indexing (per collection) → root → deleting → sizes, and every phase is announced. Walk progress is time-throttled (`progressInterval`, 200ms) rather than per-batch, so runs of unchanged files still report. Walk errors never go to stderr; they're collected in `Stats.ErrorCount`/`Errors` (first 50), and a folder that can't be read is recorded in `run.unreadable` so files previously indexed under it are **not** deleted. Keep both rules: the index must not lose files just because a read failed.
- **Moving collections**: `db.MoveCollection` rewrites only each path's leading disk label (renames don't rewrite paths, so the label part may be stale until a reindex) and the collection's disk; the FTS update trigger keeps search in sync. Same `.diskindex` only. `UpsertCollection` falls back to matching by (disk, label) when the root path is new, so reindexing after a move or after indexing from a copy updates the collection instead of duplicating it.
- **No mount path**: with `--collection` and no mount path, `walkRoot` is skipped and the disk's root-level files (no collection) are never deleted; unlisted collections are preserved as always. This backs the app's "Add Collection…" for disks that aren't plugged in.
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
