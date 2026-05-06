package cmd

import (
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
