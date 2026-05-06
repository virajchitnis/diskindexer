package db

const schema = `
CREATE TABLE IF NOT EXISTS disks (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    label          TEXT UNIQUE NOT NULL,
    description    TEXT NOT NULL DEFAULT '',
    created_at     TEXT NOT NULL,
    last_indexed_at TEXT
);

CREATE TABLE IF NOT EXISTS collections (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    disk_id        INTEGER NOT NULL REFERENCES disks(id) ON DELETE CASCADE,
    label          TEXT NOT NULL,
    root_path      TEXT NOT NULL,
    last_indexed_at TEXT,
    UNIQUE(disk_id, root_path)
);

CREATE TABLE IF NOT EXISTS files (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    disk_id       INTEGER NOT NULL REFERENCES disks(id) ON DELETE CASCADE,
    collection_id INTEGER REFERENCES collections(id) ON DELETE SET NULL,
    name          TEXT NOT NULL,
    path          TEXT NOT NULL,
    size          INTEGER NOT NULL DEFAULT 0,
    modified_at   TEXT NOT NULL,
    extension     TEXT NOT NULL DEFAULT '',
    is_dir        INTEGER NOT NULL DEFAULT 0,
    UNIQUE(disk_id, path)
);

CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
    name,
    path,
    content=files,
    content_rowid=id
);

CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN
    INSERT INTO files_fts(rowid, name, path) VALUES (new.id, new.name, new.path);
END;

CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
    INSERT INTO files_fts(files_fts, rowid, name, path) VALUES('delete', old.id, old.name, old.path);
END;

CREATE TRIGGER IF NOT EXISTS files_au AFTER UPDATE ON files BEGIN
    INSERT INTO files_fts(files_fts, rowid, name, path) VALUES('delete', old.id, old.name, old.path);
    INSERT INTO files_fts(rowid, name, path) VALUES (new.id, new.name, new.path);
END;

CREATE INDEX IF NOT EXISTS idx_files_disk_id       ON files(disk_id);
CREATE INDEX IF NOT EXISTS idx_files_collection_id ON files(collection_id);
CREATE INDEX IF NOT EXISTS idx_files_extension     ON files(extension);
CREATE INDEX IF NOT EXISTS idx_files_modified_at   ON files(modified_at);
CREATE INDEX IF NOT EXISTS idx_files_size          ON files(size);
CREATE INDEX IF NOT EXISTS idx_files_is_dir        ON files(is_dir);
CREATE INDEX IF NOT EXISTS idx_collections_disk_id ON collections(disk_id);
`
