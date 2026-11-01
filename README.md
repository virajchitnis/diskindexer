# Disk Indexer

A CLI tool for creating and searching offline metadata indexes of large external hard disks. Index a disk once while it is plugged in; search it any time without the disk present.

Built for disks full of photos and videos — fast on 5 TB+, no file hashing, incremental by default.

## Features

- **Offline search** — indexes file metadata (name, path, size, date, type) into a portable `.diskindex` file
- **Incremental indexing** — only processes changed, new, or deleted files on subsequent runs
- **Directory sizes** — computed automatically at the end of every index run; no re-scan needed
- **Collections** — top-level directories are auto-detected as collections; manual override supported
- **Interactive TUI** — live search with disk, collection, and type filters, sorting, browser panel, detail panel, and one-key clipboard copy
- **Exclude directories** — skip directories by name or glob at any depth during indexing (`--exclude`)
- **Duplicate highlighting** — files and directories sharing the same name and size are highlighted across all disks
- **Text/pipe mode** — plain tabular output when piped or with `--no-tui`, suitable for scripting
- **Multi-disk search** — search across multiple `.diskindex` files in a single query
- **Static binary** — no runtime dependencies; single binary for Linux and macOS
- **macOS app** — a native SwiftUI app that indexes and searches on your Mac, or acts as the GUI for diskindexer running on a server (over SSH)

## Installation

### Prerequisites

Go 1.21 or later is required to build from source.

### Build from source

```bash
git clone https://github.com/virajchitnis/diskindexer
cd diskindexer
make build
```

### Cross-compile for Linux (from macOS)

```bash
make build-linux
```

The resulting binary is statically linked and requires no runtime dependencies on the target machine.

### Available make targets

| Target | Description |
|---|---|
| `make build` | Build for the current platform |
| `make build-linux` | Cross-compile for Linux AMD64 |
| `make test` | Run all Go tests |
| `make test-apple` | Run the Swift tests for the macOS app, including end-to-end tests of the app logic against a real `diskindexer serve` |
| `make mac-app` | Build `build/DiskIndexer.app` (and a `.zip` of it) |
| `make icon` | Render `apple/Icon/AppIcon.svg` into the macOS `.icns` and a 1024 px PNG |
| `make install` | Build for Linux and copy to the server |
| `make install-service` | `install`, then set up and restart the `diskindexer serve` systemd user service on the server |
| `make clean` | Remove build artifacts |

## Quick Start

```bash
# Index a disk
diskindexer index /Volumes/MyDisk --disk "My Disk"

# Search interactively (TUI launches automatically in a terminal)
diskindexer search

# Search with a query
diskindexer search vacation

# Search without TUI (for scripting)
diskindexer search vacation --no-tui
```

## Index File

Indexes are stored as `.diskindex` files — standard SQLite databases with a custom extension. They are fully portable and can be copied between machines.

**Default location:** `~/.config/diskindexer/global.diskindex`

Override with `--db`:

```bash
diskindexer index /Volumes/MyDisk --disk "My Disk" --db ~/my-disk.diskindex
diskindexer search --db ~/my-disk.diskindex
```

## Configuration

`~/.config/diskindexer/config.toml` is created automatically on first run.

```toml
default_db = "~/.config/diskindexer/global.diskindex"

known_dbs = [
  "~/.config/diskindexer/global.diskindex",
  "~/external-disk.diskindex",
]
```

`known_dbs` lists all indexes that `diskindexer search` queries by default. Add a path here to include it in every search automatically.

## Commands

### `index`

Walk a mounted disk and record file metadata.

```bash
diskindexer index <mount-path> --disk "Label" [flags]
diskindexer index --disk "Label" --collection "Label:/path" [flags]   # no mount path
```

| Flag | Description |
|---|---|
| `--disk` | Disk label (required) |
| `--description` | Optional description |
| `--collection "Label:/path"` | Manually specify a collection (repeatable; disables auto-detection) |
| `--exclude name` | Directory name or glob to skip at any depth (repeatable) |
| `--force` | Wipe and re-index from scratch |
| `--db` | Path to `.diskindex` file |

Collections are auto-detected as top-level directories. Use `--collection` to override — for example when a collection lives on a different mount point, or to index only a subset of directories.

Use `--exclude` to skip directories by name at any depth. Glob patterns are supported (`*`, `?`, `[range]`). Excluded directories and all their contents are omitted from the index.

```bash
# Auto-detect collections (top-level dirs become collections)
diskindexer index /Volumes/Seagate --disk "Seagate 4TB"

# Manually specify collections (disables auto-detection for this run)
diskindexer index /Volumes/Seagate --disk "Seagate 4TB" \
  --collection "Photos:/Volumes/Seagate/Photos" \
  --collection "Archive:/Volumes/OtherDisk/Archive"

# Exclude snapshot and cache directories at any depth
diskindexer index /Volumes/Seagate --disk "Seagate 4TB" \
  --exclude .snapshots \
  --exclude "*.cache"

# Force a full re-index
diskindexer index /Volumes/Seagate --disk "Seagate 4TB" --force

# Add a copy of a collection stored elsewhere to a disk that isn't plugged in
diskindexer index --disk "Seagate 4TB" --collection "Photos:/srv/copies/Photos"
```

The mount path can be left out when `--collection` is given. This is for adding a collection to an existing disk without the disk itself, for example from a copy of the folder kept on a server. Only the listed collections are indexed. Files are stored as if they were on the disk (`Seagate 4TB/Photos/…`), and the disk's other collections and root-level files are left untouched.

Each subsequent `index` run is incremental — only changed, new, or deleted files are processed.

### `reindex`

Alias for `index`. Useful in scripts and cron jobs to make the intent explicit.

```bash
diskindexer reindex /Volumes/Seagate --disk "Seagate 4TB"
```

### `search`

Search across all indexed disks.

```bash
diskindexer search [query] [flags]
```

When run in an interactive terminal, the full TUI launches. When piped or called with `--no-tui`, plain tabular output is printed.

**Text mode flags:**

| Flag | Description |
|---|---|
| `--disk` | Filter results to a specific disk |
| `--ext jpg` | Filter by file extension |
| `--files-only` | Show files only |
| `--dirs-only` | Show directories only |
| `--min-size 100MB` | Minimum file size (B, KB, MB, GB, TB) |
| `--max-size 10GB` | Maximum file size |
| `--after 2023-01-01` | Modified after date |
| `--before 2024-01-01` | Modified before date |
| `--limit 100` | Maximum results (default 50) |
| `--no-tui` | Force text output even in a terminal |
| `--db` | One or more `.diskindex` files to search |

**Searching multiple indexes:**

```bash
# Search two specific index files
diskindexer search --db ~/disk1.diskindex --db ~/disk2.diskindex

# Or configure known_dbs in config.toml to search all automatically
diskindexer search
```

### `disks`

List all indexed disks.

```bash
diskindexer disks
```

### `delete-disk`

Remove a disk and all its files from the index. The actual files on disk are not affected.

```bash
diskindexer delete-disk --disk "Seagate 4TB"
```

### `collections`

List collections, optionally filtered to a disk.

```bash
diskindexer collections
diskindexer collections --disk "Seagate 4TB"
```

### `rename-collection`

Rename a collection by its label. Use `--disk` to disambiguate if the same collection name exists on more than one disk.

```bash
diskindexer rename-collection "Holiday Photos" --collection "Photos"
diskindexer rename-collection "Holiday Photos" --collection "Photos" --disk "Seagate 4TB"
```

### `delete-collection`

Remove a collection and all its files from the index. The actual files on disk are not affected.

```bash
diskindexer delete-collection --collection "Photos"
diskindexer delete-collection --collection "Photos" --disk "Seagate 4TB"
```

### `serve`

Runs the JSON API that the macOS app talks to. You normally don't run this by hand: the app starts its own copy for local use, and `make install-service` sets it up as a service on a server.

```bash
diskindexer serve                                   # Unix socket at ~/.config/diskindexer/server.sock
diskindexer serve --listen 127.0.0.1:7878 --token s3cret
```

| Flag | Description |
|---|---|
| `--listen` | `unix:/path/to.sock` or `host:port`; repeatable. Default: `unix:~/.config/diskindexer/server.sock` (mode 0600, so only your user can connect) |
| `--token` | Require `Authorization: Bearer <token>` on every request (default `$DISKINDEXER_TOKEN`). Required for TCP listeners not on loopback |
| `--db` | Index file to write to and search; repeatable, as for `search` |

Searches use the indexes in `known_dbs`, and index runs write to `default_db`, the same as the CLI. Index runs happen inside the server, so they keep going if the app disconnects.

## macOS App

`DiskIndexer.app` is a native SwiftUI app with the same features as the TUI:
- live search;
- a disk/collection sidebar;
- sortable columns;
- duplicate highlighting;
- a details inspector.

It also manages indexes from the GUI:
- index and reindex disks with live progress and Cancel;
- add a collection to an existing disk without the disk plugged in (right-click the disk → **Add Collection…**), e.g. from a copy of the folder on the server;
- rename and delete collections;
- delete disks.

The toolbar's connection menu switches between two modes:

- **This Mac.** The app runs its bundled `diskindexer` in the background and uses your normal `~/.config/diskindexer` config and indexes.
- **A server.** The app connects over SSH to `diskindexer serve` running on another machine, such as an Ubuntu box with your disks attached. You search that machine's indexes and start index runs there; Browse… shows the server's folders.

### Build

Building needs only the Xcode Command Line Tools (`xcode-select --install`), not full Xcode.

```bash
make mac-app
open build/DiskIndexer.app
```

The app is ad-hoc signed. On a Mac other than the one that built it, open it the first time with right-click → Open.

### Set up a server

1. Install the binary and the systemd user service:

   ```bash
   make install-service
   ```

   To install by hand instead, copy `deploy/diskindexer.service` to `~/.config/systemd/user/` and run `systemctl --user enable --now diskindexer`.

2. Once on the server, let the service run while you are logged out:

   ```bash
   sudo loginctl enable-linger $USER
   ```

3. In the app, choose **Add Server…** from the connection menu and enter the SSH host. A `~/.ssh/config` alias works.

How the connection works:
- The app runs `/usr/bin/ssh` with your ssh-agent and `~/.ssh/config` and forwards a local port to the server's socket. No port is opened on the server.
- It can't answer password or host-key prompts, so `ssh <host>` must already work from Terminal without prompting.
- If the connection drops, for example when the Mac sleeps, the app reconnects on its own. Index jobs keep running on the server, and their progress reappears once the app reconnects.

## TUI Controls

| Key | Action |
|---|---|
| Type | Live search (150ms debounce) |
| `↑` / `↓` or `j` / `k` | Navigate results |
| `PgUp` / `PgDn` | Page through results |
| `Enter` | Copy file path to clipboard |
| `Tab` | Move focus to results |
| `/` or `Esc` | Move focus back to search bar |
| `d` / `D` | Cycle disk filter forward / backward |
| `c` / `C` | Cycle collection filter forward / backward (list narrows when a disk is selected) |
| `t` | Cycle type filter (All → Files → Dirs) |
| `s` | Cycle sort (NAME ▲▼ → SIZE ▲▼ → MODIFIED ▲▼) |
| `i` | Toggle detail panel (full path, size, date, disk, collection) |
| `b` | Toggle disk/collection browser panel (open/close from any zone) |
| `↑` / `↓` or `j` / `k` (browser) | Navigate browser panel |
| `→` / `←` (browser) | Expand / collapse a disk node |
| `Enter` or `Space` (browser) | Apply selected disk or collection as filter |
| `Esc` (browser) | Unfocus browser, return to search bar (panel stays open) |
| `q` or `Ctrl+C` | Quit |

## Path Format

File paths in the index are stored as `DiskLabel/Collection/path/to/file`. This makes copied paths self-describing — you always know which disk a file belongs to without looking at a separate column.

## How It Works

- **Index format** — `.diskindex` files are standard SQLite databases. They can be opened with any SQLite tool.
- **FTS5** — a full-text search virtual table on `(name, path)` powers fast text queries.
- **Incremental detection** — files are compared by `(path, size, mtime)`. No hashing. A 5 TB disk with unchanged files reindexes in seconds.
- **Directory sizes** — computed at the end of every index or reindex run by summing all non-directory file sizes beneath each directory. Re-indexing an existing disk populates sizes for directories that were previously recorded with a size of 0.
- **Collections** — top-level directories on a disk. Files at the disk root (not inside any directory) are indexed without a collection.
- **Multi-DB search** — each `.diskindex` is queried independently; results are merged and sorted in memory.
- **Duplicate highlighting** — the TUI marks files and directories that share the same name and size (across all indexed disks) in amber.

## License

MIT
