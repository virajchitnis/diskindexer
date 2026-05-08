# Disk Indexer

A CLI tool for creating and searching offline metadata indexes of large external hard disks. Index a disk once while it is plugged in; search it any time without the disk present.

Built for disks full of photos and videos — fast on 5 TB+, no file hashing, incremental by default.

## Features

- **Offline search** — indexes file metadata (name, path, size, date, type) into a portable `.diskindex` file
- **Incremental indexing** — only processes changed, new, or deleted files on subsequent runs
- **Directory sizes** — computed automatically at the end of every index run; no re-scan needed
- **Collections** — top-level directories are auto-detected as collections; manual override supported
- **Interactive TUI** — live search with filters, sorting, detail panel, and one-key clipboard copy
- **Duplicate highlighting** — files sharing the same name and size are highlighted across all disks
- **Text/pipe mode** — plain tabular output when piped or with `--no-tui`, suitable for scripting
- **Multi-disk search** — search across multiple `.diskindex` files in a single query
- **Static binary** — no runtime dependencies; single binary for Linux and macOS

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
| `make test` | Run all tests |
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
```

| Flag | Description |
|---|---|
| `--disk` | Disk label (required) |
| `--description` | Optional description |
| `--collection "Label:/path"` | Manually specify a collection (repeatable; disables auto-detection) |
| `--force` | Wipe and re-index from scratch |
| `--db` | Path to `.diskindex` file |

Collections are auto-detected as top-level directories. Use `--collection` to override — for example when a collection lives on a different mount point, or to index only a subset of directories.

```bash
# Auto-detect collections (top-level dirs become collections)
diskindexer index /Volumes/Seagate --disk "Seagate 4TB"

# Manually specify collections (disables auto-detection for this run)
diskindexer index /Volumes/Seagate --disk "Seagate 4TB" \
  --collection "Photos:/Volumes/Seagate/Photos" \
  --collection "Archive:/Volumes/OtherDisk/Archive"

# Force a full re-index
diskindexer index /Volumes/Seagate --disk "Seagate 4TB" --force
```

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

Rename a collection by its numeric ID (shown in `collections` output).

```bash
diskindexer rename-collection 3 "Holiday Photos"
```

### `delete-collection`

Remove a collection and all its files from the index. The actual files on disk are not affected.

```bash
diskindexer delete-collection 3
```

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
| `t` | Cycle type filter (All → Files → Dirs) |
| `s` | Cycle sort (NAME ▲▼ → SIZE ▲▼ → MODIFIED ▲▼) |
| `i` | Toggle detail panel (full path, size, date, disk, collection) |
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
- **Duplicate highlighting** — the TUI marks files that share the same name and size (across all indexed disks) in amber.

## License

MIT
