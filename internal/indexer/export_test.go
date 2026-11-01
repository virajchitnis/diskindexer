package indexer

import "time"

// SetProgressInterval lets tests make progress reports unthrottled.
func SetProgressInterval(d time.Duration) (restore func()) {
	old := progressInterval
	progressInterval = d
	return func() { progressInterval = old }
}
