package cmd

import (
	"time"
	"path/filepath"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestFormatSize(t *testing.T) {
	tests := []struct {
		bytes    int64
		expected string
	}{
		{0, "0 B"},
		{512, "512 B"},
		{1024, "1.0 KB"},
		{1536, "1.5 KB"},
		{1024 * 1024, "1.0 MB"},
		{4404019, "4.2 MB"},    // int64(4.2 * 1024 * 1024)
		{1024 * 1024 * 1024, "1.0 GB"},
		{2254857830, "2.1 GB"}, // int64(2.1 * 1024 * 1024 * 1024)
		{1024 * 1024 * 1024 * 1024, "1.0 TB"},
	}
	for _, tc := range tests {
		assert.Equal(t, tc.expected, formatSize(tc.bytes), "bytes=%d", tc.bytes)
	}
}

func TestParseSize(t *testing.T) {
	tests := []struct {
		input   string
		want    int64
		wantErr bool
	}{
		{"1KB", 1024, false},
		{"1MB", 1024 * 1024, false},
		{"1GB", 1024 * 1024 * 1024, false},
		{"1TB", 1024 * 1024 * 1024 * 1024, false},
		{"1.5MB", int64(1.5 * 1024 * 1024), false},
		{"500B", 500, false},
		{"500", 500, false},
		{"", 0, true},
		{"abc", 0, true},
	}
	for _, tc := range tests {
		got, err := parseSize(tc.input)
		if tc.wantErr {
			assert.Error(t, err, "input=%q", tc.input)
		} else {
			require.NoError(t, err, "input=%q", tc.input)
			assert.Equal(t, tc.want, got, "input=%q", tc.input)
		}
	}
}

// --before covers the whole local day, including the 25-hour day when
// daylight saving time ends.
func TestBeforeCoversWholeLocalDay(t *testing.T) {
	ny, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Skip("no tz database")
	}
	orig := time.Local
	time.Local = ny
	defer func() { time.Local = orig }()

	disk := setupHome(t)
	// 23:30 on 2026-11-01, the day New York leaves daylight saving time.
	late := time.Date(2026, 11, 1, 23, 30, 0, 0, ny)
	require.NoError(t, os.Chtimes(filepath.Join(disk, "readme.txt"), late, late))
	_, err = run(t, "index", disk, "--disk", "D")
	require.NoError(t, err)

	out, err := run(t, "search", "readme", "--no-tui", "--before", "2026-11-01")
	require.NoError(t, err)
	assert.Contains(t, out, "readme.txt")

	out, err = run(t, "search", "readme", "--no-tui", "--before", "2026-10-31")
	require.NoError(t, err)
	assert.Contains(t, out, "No results")
}
