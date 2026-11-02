# Disk Indexer

A CLI tool for creating and searching offline metadata indexes of large external hard disks. Index a disk once while it is plugged in; search it any time without the disk present.

Built for disks full of photos and videos — fast on 5 TB+, no file hashing, incremental by default.

## Features

- **Offline search** — indexes file metadata (name, path, size, date, type) into a portable `.diskindex` file
- **Incremental indexing** — only processes changed, new, or deleted files on subsequent runs
- **Directory sizes** — computed automatically at the end of every index run; no re-scan needed
- **Collections** — top-level directories are auto-detected as collections; manual override supported
- **Interactive TUI** — live search with disk, collection, and type filters, sorting, browser panel, detail panel, and one-key clipboard copy
- **Excludes** — skip files and folders by name or glob at any depth. Set defaults once in the config; each disk also remembers its own excludes
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
| `make coverage` | Run the Go and Swift tests with coverage, and fail if either is below 80% (`COVERAGE_MIN`) |
| `make mac-app` | Build `build/DiskIndexer.app` (and a `.zip` of it) |
| `make dmg` | Build `build/DiskIndexer.dmg`, a drag-to-install disk image |
| `make install-mac` | Install the app to `/Applications` and link its CLI to `~/.local/bin/diskindexer` |
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

`default_excludes` lists files and folders that every index run skips, on any disk, from the CLI or the app:

```toml
default_excludes = [".snapshots", ".addition", ".incomplete", ".stfolder", ".stignore", "lost+found", ".AppleDouble"]
```

On a server running `diskindexer serve`, restart the service after editing it:

```bash
systemctl --user restart diskindexer
```

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
| `--exclude name` | File or folder name, or a glob, to skip at any depth (repeatable). Saved with the disk |
| `--no-default-excludes` | Don't apply the config's `default_excludes` for this run |
| `--force` | Wipe and re-index from scratch |
| `--db` | Path to `.diskindex` file |

Collections are auto-detected as top-level directories. Each `--collection` needs its own name and its own folder; a run that lists either twice is refused, since the collections would overwrite each other in the index. Use `--collection` to override — for example when a collection lives on a different mount point, or to index only a subset of directories.

Use `--exclude` to skip files and folders by name at any depth. Glob patterns are supported (`*`, `?`, `[range]`). An excluded folder is skipped with everything in it. A file or folder that was indexed before and is now excluded is removed from the index.

Excludes come from two places:
- **`default_excludes` in the config file** apply to every run.
- **Each disk's own excludes** are remembered from its last run. A run without `--exclude` reuses them; a run with `--exclude` replaces them. In the app, the Index sheet shows the server's defaults and pre-fills the disk's own list.

The run's output lists everything it skipped.

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

### `move-collection`

Move a collection and all its files to another disk in the index, after you've physically moved the folder. Nothing is read from either disk, so it takes seconds even for very large collections.

```bash
diskindexer move-collection --collection "Photos" --disk "Disk One" --to "Seagate PB A"
```

- Each path's disk name is swapped (`Disk One/Photos/…` becomes `Seagate PB A/Photos/…`); the rest is kept as indexed.
- The collection's saved folder location moves under the target disk's mount point when it can be worked out, so a later reindex of the target updates the collection instead of re-adding it.
- Both disks must be in the same index file. The move is refused if the target already has a collection with that name.
- Reindex the target disk afterwards to pick up any other changes.

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
- a details inspector;
- column widths and order that are remembered between launches.

It also manages indexes from the GUI:
- index and reindex disks with live progress through each step (loading, indexing, removing deleted files, folder sizes), Cancel, and a list of anything that couldn't be read;
- move a collection to another disk by dragging it onto the disk in the sidebar, or with **Move to** in its right-click menu. A move asks for confirmation and can be undone with ⌘Z;
- add a collection to an existing disk without the disk plugged in (right-click the disk → **Add Collection…**), e.g. from a copy of the folder on the server;
- rename and delete collections;
- delete disks.

The toolbar's connection menu switches between two modes:

- **This Mac.** The app runs its bundled `diskindexer` in the background and uses your normal `~/.config/diskindexer` config and indexes.
- **A server.** The app connects over SSH to `diskindexer serve` running on another machine, such as an Ubuntu box with your disks attached. You search that machine's indexes and start index runs there; Browse… shows the server's folders.

### Install

Building needs only the Xcode Command Line Tools (`xcode-select --install`), though full Xcode works too.

To install on this Mac:

```bash
make install-mac
```

This puts `DiskIndexer.app` in `/Applications` and links the `diskindexer` command bundled inside it to `~/.local/bin/diskindexer`, so the CLI updates whenever the app does. Override the locations with `MAC_APP_DIR` and `MAC_BIN_DIR`. A running copy of the app is quit first.

To make a disk image for another Mac:

```bash
make dmg
```

`build/DiskIndexer.dmg` shows the app next to an Applications shortcut to drag it onto. CI builds one for every pull request, and `make release` attaches it to the GitHub release.

The app is ad-hoc signed, not signed with an Apple Developer ID, so a copy **downloaded** from GitHub is blocked the first time. Open it via **System Settings ▸ Privacy & Security ▸ Open Anyway**. A copy you build yourself isn't affected.

### Set up a server

**From the app:**
1. Choose **Add Server…** in the connection menu and enter its address.
2. If diskindexer isn't installed there, the "Waiting for …" screen offers **Set Up diskindexer on …**. It copies the right binary over SSH to `~/.local/bin/diskindexer`: Linux amd64 or arm64, or macOS, all bundled in the app.
   - **On Linux with systemd,** it also installs and starts a systemd user service.
   - **On other servers** (macOS, or Linux without systemd), there's no service. The app starts `diskindexer serve` over SSH each time it connects, and it exits when the app disconnects.

**Background running (optional).** Without it, the service on a Linux server runs only while you're logged in, and the app's SSH connection counts as being logged in. So diskindexer starts when the app connects and stops shortly after it disconnects. That's fine for searching and short index runs, but a long run stops if your Mac disconnects or sleeps. Files indexed so far are kept.

To let runs finish on their own, enable lingering on the server once:

```bash
sudo loginctl enable-linger $USER
```

Setup turns this on itself if `sudo` works without a password; otherwise it offers the command. When a server doesn't keep running after the app disconnects, the Index sheet says so before you start a run.

**Updating:** when the server runs an older diskindexer than the app includes, a banner offers **Update…**. It asks first, warns if index runs are in progress (restarting stops them), and then replaces the binary and restarts the service. Your indexes and config aren't touched. The app never downgrades a newer server.

**From a terminal instead:**

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

**Several addresses:** a server can have more than one address, tried in order, for example its home-network IP first and its Tailscale name second. The first one that answers is used, and every reconnect starts again from the top. So the app connects directly at home and over Tailscale elsewhere without you changing anything. The window subtitle shows which address is in use. Addresses that aren't last get a short timeout, so failing over is quick. (Tailscale alone often manages this too: between two machines on the same LAN, it connects them directly.)

How the connection works:
- The app runs `/usr/bin/ssh` with your ssh-agent and `~/.ssh/config` and forwards a local port to the server's socket. No port is opened on the server.
- It can't answer password prompts, so `ssh <host>` must log in from Terminal without asking for one.
- **Host keys:** the first time you connect to an address, the app shows the server's key fingerprint and asks whether to trust it. If an address's key has changed, the app shows the old and new fingerprints:
  - When the new key is one you already trust for another address of the same server (for example its LAN IP and its hostname), it says so and offers **Replace Key and Connect**.
  - Otherwise it warns that the connection may be intercepted and asks again before replacing the key.
  - The app removes only the conflicting line from `~/.ssh/known_hosts` and keeps the previous file as `known_hosts.old`. ssh itself then adds the new key.
- If the server can't be reached when the app opens, for example because the server is off or Tailscale isn't connected yet, the app shows **Waiting for …** with ssh's error and keeps retrying, with a **Try Now** button. Problems only you can fix, such as an untrusted host key or a refused login, stop and ask instead of retrying.
- If the connection drops, for example when the Mac sleeps, the app notices within about 15 seconds and reconnects on its own. Meanwhile, the last results stay visible but dimmed under a "Reconnecting…" banner, and your search runs once it's back.
- Index jobs keep running on the server, and their progress reappears once the app reconnects. If the server itself restarts mid-run (which stops the run), the job is shown as **Interrupted** rather than appearing to run forever. Files indexed so far are kept.

## Testing

- **Go:** `make test`, with tests for the indexer, database, server, CLI commands and TUI. `make coverage-go` fails if coverage across all packages drops below 80%.
- **macOS app logic:** `make test-apple` runs the Swift tests. Many of them drive the app's model against a real `diskindexer serve`. `make coverage-apple` gates that logic at 80%.
- **End-to-end UI tests:** `apple/UITests` uses XCUITest to drive the real app: browsing, search and filters, indexing a disk, renaming, drag-to-move with undo, the name-clash alert, and the can't-connect screen. They need full Xcode and run in CI. To run them locally:

  ```bash
  brew install xcodegen
  ```
  ```bash
  make build && (cd apple/Xcode && xcodegen generate)
  ```
  ```bash
  TEST_RUNNER_DISKINDEXER_BIN="$PWD/diskindexer" xcodebuild test -project apple/Xcode/DiskIndexer.xcodeproj -scheme DiskIndexer -destination 'platform=macOS'
  ```

CI runs all of these on every pull request.

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
- **Unreadable folders** — if a folder can't be read (permissions, a failing drive), the run still completes. It reports the paths it couldn't read: at the end of CLI output, and in the app's Jobs list. Whatever was indexed under those folders before is **kept** rather than removed, because an error doesn't mean the files are gone. The next readable run brings them up to date.
- **Directory sizes** — computed at the end of every index or reindex run by summing all non-directory file sizes beneath each directory. Re-indexing an existing disk populates sizes for directories that were previously recorded with a size of 0.
- **Collections** — top-level directories on a disk. Files at the disk root (not inside any directory) are indexed without a collection. When indexing, a collection is matched by its folder location or, failing that, by name on the same disk. A collection moved from another disk, or first indexed from a copy elsewhere, is therefore updated in place rather than duplicated.
- **Multi-DB search** — each `.diskindex` is queried independently; results are merged and sorted in memory.
- **Duplicate highlighting** — the TUI marks files and directories that share the same name and size (across all indexed disks) in amber.

## License

MIT
