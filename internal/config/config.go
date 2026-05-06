package config

import (
	"os"
	"path/filepath"

	"github.com/BurntSushi/toml"
)

type Config struct {
	DefaultDB string   `toml:"default_db"`
	KnownDBs  []string `toml:"known_dbs"`
}

func DefaultConfigPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "diskindexer", "config.toml")
}

func DefaultDBPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "diskindexer", "global.diskindex")
}

// Load reads the config file, returning defaults if it doesn't exist yet.
func Load() (*Config, error) {
	cfg := &Config{
		DefaultDB: DefaultDBPath(),
		KnownDBs:  []string{DefaultDBPath()},
	}
	path := DefaultConfigPath()
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return cfg, nil
	}
	if _, err := toml.DecodeFile(path, cfg); err != nil {
		return nil, err
	}
	cfg.DefaultDB = expandHome(cfg.DefaultDB)
	for i, p := range cfg.KnownDBs {
		cfg.KnownDBs[i] = expandHome(p)
	}
	return cfg, nil
}

// Save writes the config to disk, creating parent directories as needed.
func Save(cfg *Config) error {
	path := DefaultConfigPath()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return toml.NewEncoder(f).Encode(cfg)
}

func expandHome(path string) string {
	if len(path) >= 2 && path[:2] == "~/" {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, path[2:])
	}
	return path
}
