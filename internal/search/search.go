package search

import (
	"sort"

	"github.com/viraj/diskindexer/internal/db"
)

// Result wraps a file record with the source DB path for multi-DB searches.
type Result struct {
	File   *db.File
	DBPath string
}

// Across runs a search against multiple databases and merges the results.
// Results are sorted by filename. When a query string is present each DB's
// FTS ranking is preserved within that DB's slice before merging.
func Across(databases []*db.DB, params db.SearchParams) ([]Result, error) {
	var all []Result
	for _, d := range databases {
		files, err := d.Search(params)
		if err != nil {
			return nil, err
		}
		for _, f := range files {
			all = append(all, Result{File: f, DBPath: d.Path})
		}
	}
	// Stable sort by name so results from multiple DBs interleave naturally.
	sort.SliceStable(all, func(i, j int) bool {
		return all[i].File.Name < all[j].File.Name
	})
	return all, nil
}
