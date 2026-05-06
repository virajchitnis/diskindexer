package config_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/viraj/diskindexer/internal/config"
)

func TestLoad_ReturnsDefaultsWhenNoFile(t *testing.T) {
	// Point home to a temp dir so there's no real config file.
	t.Setenv("HOME", t.TempDir())

	cfg, err := config.Load()
	require.NoError(t, err)
	assert.NotEmpty(t, cfg.DefaultDB)
	assert.NotEmpty(t, cfg.KnownDBs)
}

func TestLoad_ParsesTOML(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cfgDir := filepath.Join(home, ".config", "diskindexer")
	require.NoError(t, os.MkdirAll(cfgDir, 0755))

	toml := `
default_db = "/tmp/myindex.diskindex"
known_dbs  = ["/tmp/myindex.diskindex", "/tmp/second.diskindex"]
`
	require.NoError(t, os.WriteFile(filepath.Join(cfgDir, "config.toml"), []byte(toml), 0644))

	cfg, err := config.Load()
	require.NoError(t, err)
	assert.Equal(t, "/tmp/myindex.diskindex", cfg.DefaultDB)
	assert.Len(t, cfg.KnownDBs, 2)
}

func TestLoad_ExpandsHomeTilde(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cfgDir := filepath.Join(home, ".config", "diskindexer")
	require.NoError(t, os.MkdirAll(cfgDir, 0755))

	toml := `default_db = "~/my.diskindex"`
	require.NoError(t, os.WriteFile(filepath.Join(cfgDir, "config.toml"), []byte(toml), 0644))

	cfg, err := config.Load()
	require.NoError(t, err)
	assert.Equal(t, filepath.Join(home, "my.diskindex"), cfg.DefaultDB)
}

func TestSave_WritesFile(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cfg := &config.Config{
		DefaultDB: "/tmp/global.diskindex",
		KnownDBs:  []string{"/tmp/global.diskindex", "/tmp/extra.diskindex"},
	}
	require.NoError(t, config.Save(cfg))

	loaded, err := config.Load()
	require.NoError(t, err)
	assert.Equal(t, cfg.DefaultDB, loaded.DefaultDB)
	assert.Equal(t, cfg.KnownDBs, loaded.KnownDBs)
}
