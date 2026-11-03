package server_test

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/viraj/diskindexer/internal/api"
	"github.com/viraj/diskindexer/internal/server"
)

type harness struct {
	t     *testing.T
	srv   *httptest.Server
	token string
}

func newHarness(t *testing.T, token string) *harness {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "test.diskindex")
	svc, err := api.NewService("test", dbPath, nil)
	require.NoError(t, err)
	srv := httptest.NewServer(server.New(svc, token))
	t.Cleanup(func() {
		srv.Close()
		svc.Close()
	})
	return &harness{t: t, srv: srv, token: token}
}

func (h *harness) do(method, path string, body any, out any) int {
	h.t.Helper()
	var rd *bytes.Reader
	if body != nil {
		b, err := json.Marshal(body)
		require.NoError(h.t, err)
		rd = bytes.NewReader(b)
	} else {
		rd = bytes.NewReader(nil)
	}
	req, err := http.NewRequest(method, h.srv.URL+path, rd)
	require.NoError(h.t, err)
	if h.token != "" {
		req.Header.Set("Authorization", "Bearer "+h.token)
	}
	resp, err := http.DefaultClient.Do(req)
	require.NoError(h.t, err)
	defer resp.Body.Close()
	if out != nil && resp.StatusCode < 300 && resp.StatusCode != http.StatusNoContent {
		require.NoError(h.t, json.NewDecoder(resp.Body).Decode(out))
	}
	return resp.StatusCode
}

func makeDisk(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for rel, content := range files {
		p := filepath.Join(root, rel)
		require.NoError(t, os.MkdirAll(filepath.Dir(p), 0755))
		require.NoError(t, os.WriteFile(p, []byte(content), 0644))
	}
	return root
}

// waitJob polls until the job leaves the running state. The deadline only
// guards against a hung job: the 3000-file tree takes ~6s under -race on a
// laptop and longer on shared CI runners.
func (h *harness) waitJob(id string) api.Job {
	h.t.Helper()
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		var j api.Job
		require.Equal(h.t, http.StatusOK, h.do("GET", "/v1/jobs/"+id, nil, &j))
		if j.State != api.JobRunning {
			return j
		}
		time.Sleep(20 * time.Millisecond)
	}
	h.t.Fatalf("job %s did not finish", id)
	return api.Job{}
}

func (h *harness) index(root string) api.Job {
	h.t.Helper()
	var j api.Job
	require.Equal(h.t, http.StatusAccepted, h.do("POST", "/v1/jobs", api.IndexRequest{Disk: "Disk1", MountPath: root}, &j))
	return h.waitJob(j.ID)
}

func TestInfo(t *testing.T) {
	h := newHarness(t, "")
	var info api.Info
	require.Equal(t, http.StatusOK, h.do("GET", "/v1/info", nil, &info))
	assert.Equal(t, api.Version, info.APIVersion)
	assert.Equal(t, "test", info.Version)
	assert.Len(t, info.DBs, 1)
}

func TestIndexSearchAndManage(t *testing.T) {
	h := newHarness(t, "")
	root := makeDisk(t, map[string]string{
		"Photos/beach.jpg": "aaaa",
		"Photos/hotel.jpg": "bb",
		"Work/report.pdf":  "cccccc",
	})

	j := h.index(root)
	require.Equal(t, api.JobDone, j.State, j.Error)
	require.NotNil(t, j.Stats)
	assert.Greater(t, j.Stats.Added, 0)

	var disks []api.Disk
	require.Equal(t, http.StatusOK, h.do("GET", "/v1/disks", nil, &disks))
	require.Len(t, disks, 1)
	assert.Equal(t, "Disk1", disks[0].Label)

	var res api.SearchResponse
	require.Equal(t, http.StatusOK, h.do("POST", "/v1/search", api.SearchRequest{Query: "jpg", Type: "files"}, &res))
	assert.Len(t, res.Results, 2)
	assert.False(t, res.Capped)

	require.Equal(t, http.StatusOK, h.do("POST", "/v1/search", api.SearchRequest{Type: "files", Limit: 1}, &res))
	assert.Len(t, res.Results, 1)
	assert.True(t, res.Capped)

	assert.Equal(t, http.StatusBadRequest, h.do("POST", "/v1/search", api.SearchRequest{Type: "bogus"}, nil))

	var colls []api.Collection
	require.Equal(t, http.StatusOK, h.do("GET", "/v1/collections?disk=Disk1", nil, &colls))
	require.Len(t, colls, 2)
	var photos api.Collection
	for _, c := range colls {
		if c.Label == "Photos" {
			photos = c
		}
	}
	require.NotZero(t, photos.ID)

	assert.Equal(t, http.StatusNoContent, h.do("PATCH", fmt.Sprintf("/v1/collections/%d", photos.ID),
		map[string]string{"label": "Pictures"}, nil))
	require.Equal(t, http.StatusOK, h.do("POST", "/v1/search", api.SearchRequest{Collection: "Pictures", Type: "files"}, &res))
	assert.Len(t, res.Results, 2)

	assert.Equal(t, http.StatusNoContent, h.do("DELETE", fmt.Sprintf("/v1/collections/%d", photos.ID), nil, nil))
	assert.Equal(t, http.StatusNotFound, h.do("DELETE", fmt.Sprintf("/v1/collections/%d", photos.ID), nil, nil))
	require.Equal(t, http.StatusOK, h.do("POST", "/v1/search", api.SearchRequest{Query: "jpg"}, &res))
	assert.Empty(t, res.Results)

	assert.Equal(t, http.StatusBadRequest, h.do("DELETE", "/v1/collections/1?db=/etc/passwd", nil, nil))

	assert.Equal(t, http.StatusNoContent, h.do("DELETE", "/v1/disks/Disk1", nil, nil))
	assert.Equal(t, http.StatusNotFound, h.do("DELETE", "/v1/disks/Disk1", nil, nil))
}

func TestStartIndexValidation(t *testing.T) {
	h := newHarness(t, "")
	assert.Equal(t, http.StatusBadRequest, h.do("POST", "/v1/jobs", api.IndexRequest{MountPath: t.TempDir()}, nil))
	assert.Equal(t, http.StatusBadRequest, h.do("POST", "/v1/jobs", api.IndexRequest{Disk: "D", MountPath: "/does/not/exist"}, nil))
	assert.Equal(t, http.StatusNotFound, h.do("GET", "/v1/jobs/nope", nil, nil))
}

// A large tree keeps the first job running long enough to test the conflict,
// the progress stream, and cancellation.
func bigDisk(t *testing.T) string {
	files := map[string]string{}
	for i := 0; i < 3000; i++ {
		files[fmt.Sprintf("Coll%d/dir%d/file%d.txt", i%3, i%50, i)] = "x"
	}
	return makeDisk(t, files)
}

func TestJobEventsConflictAndCancel(t *testing.T) {
	h := newHarness(t, "")
	root := bigDisk(t)

	var j api.Job
	require.Equal(t, http.StatusAccepted, h.do("POST", "/v1/jobs", api.IndexRequest{Disk: "Big", MountPath: root}, &j))
	assert.Equal(t, http.StatusConflict, h.do("POST", "/v1/jobs", api.IndexRequest{Disk: "Big", MountPath: root}, nil))

	var cancelled api.Job
	require.Equal(t, http.StatusOK, h.do("DELETE", "/v1/jobs/"+j.ID, nil, &cancelled))
	assert.Contains(t, []api.JobState{api.JobCancelled, api.JobDone}, cancelled.State)

	// After the first job stops, a new run is allowed and streams to "done".
	require.Equal(t, http.StatusAccepted, h.do("POST", "/v1/jobs", api.IndexRequest{Disk: "Big", MountPath: root}, &j))
	resp, err := http.Get(h.srv.URL + "/v1/jobs/" + j.ID + "/events")
	require.NoError(t, err)
	defer resp.Body.Close()
	assert.Equal(t, "text/event-stream", resp.Header.Get("Content-Type"))

	var events []string
	var last api.Job
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		if ev, ok := strings.CutPrefix(line, "event: "); ok {
			events = append(events, ev)
		}
		if data, ok := strings.CutPrefix(line, "data: "); ok {
			require.NoError(t, json.Unmarshal([]byte(data), &last))
		}
	}
	require.NotEmpty(t, events)
	assert.Equal(t, "done", events[len(events)-1])
	assert.Equal(t, api.JobDone, last.State, last.Error)

	var jobs []api.Job
	require.Equal(t, http.StatusOK, h.do("GET", "/v1/jobs", nil, &jobs))
	assert.Len(t, jobs, 2)
}

func TestSearchDuringIndex(t *testing.T) {
	h := newHarness(t, "")
	var j api.Job
	require.Equal(t, http.StatusAccepted, h.do("POST", "/v1/jobs", api.IndexRequest{Disk: "Big", MountPath: bigDisk(t)}, &j))
	var res api.SearchResponse
	assert.Equal(t, http.StatusOK, h.do("POST", "/v1/search", api.SearchRequest{Query: "file1"}, &res))
	h.waitJob(j.ID)
}

func TestAuth(t *testing.T) {
	h := newHarness(t, "s3cret")
	var info api.Info
	assert.Equal(t, http.StatusOK, h.do("GET", "/v1/info", nil, &info))

	resp, err := http.Get(h.srv.URL + "/v1/info")
	require.NoError(t, err)
	resp.Body.Close()
	assert.Equal(t, http.StatusUnauthorized, resp.StatusCode)
}

func TestFSList(t *testing.T) {
	h := newHarness(t, "")
	root := makeDisk(t, map[string]string{"b/x": "1", "A/y": "1", ".hidden/z": "1", "file.txt": "1"})
	var listing api.DirListing
	require.Equal(t, http.StatusOK, h.do("GET", "/v1/fs/list?path="+root, nil, &listing))
	require.Len(t, listing.Entries, 2)
	assert.Equal(t, "A", listing.Entries[0].Name)
	assert.Equal(t, "b", listing.Entries[1].Name)
	assert.Equal(t, filepath.Dir(root), listing.Parent)

	assert.Equal(t, http.StatusBadRequest, h.do("GET", "/v1/fs/list?path=relative", nil, nil))

	var roots []api.DirEntry
	require.Equal(t, http.StatusOK, h.do("GET", "/v1/fs/roots", nil, &roots))
	assert.NotEmpty(t, roots)
}

func TestAddCollectionWithoutMountPath(t *testing.T) {
	h := newHarness(t, "")
	disk := makeDisk(t, map[string]string{"root.txt": "r", "Photos/a.jpg": "a"})
	require.Equal(t, api.JobDone, h.index(disk).State)

	copyRoot := makeDisk(t, map[string]string{"Music/song.flac": "s"})
	var j api.Job
	require.Equal(t, http.StatusAccepted, h.do("POST", "/v1/jobs", api.IndexRequest{
		Disk:        "Disk1",
		Collections: []api.CollectionSpec{{Label: "Music", RootPath: filepath.Join(copyRoot, "Music")}},
	}, &j))
	j = h.waitJob(j.ID)
	require.Equal(t, api.JobDone, j.State, j.Error)
	assert.Equal(t, 0, j.Stats.Deleted)

	var colls []api.Collection
	require.Equal(t, http.StatusOK, h.do("GET", "/v1/collections?disk=Disk1", nil, &colls))
	assert.Len(t, colls, 2)
	var res api.SearchResponse
	require.Equal(t, http.StatusOK, h.do("POST", "/v1/search", api.SearchRequest{Query: "root"}, &res))
	assert.Len(t, res.Results, 1, "disk-root files survive")

	// The same collection name twice is a 400, not a failed job.
	assert.Equal(t, http.StatusBadRequest, h.do("POST", "/v1/jobs", api.IndexRequest{
		Disk: "Disk1",
		Collections: []api.CollectionSpec{
			{Label: "Music", RootPath: filepath.Join(copyRoot, "Music")},
			{Label: "Music", RootPath: copyRoot},
		},
	}, nil))

	// Neither a mount path nor collections, or a missing collection folder, is a 400.
	assert.Equal(t, http.StatusBadRequest, h.do("POST", "/v1/jobs", api.IndexRequest{Disk: "Disk1"}, nil))
	assert.Equal(t, http.StatusBadRequest, h.do("POST", "/v1/jobs", api.IndexRequest{
		Disk:        "Disk1",
		Collections: []api.CollectionSpec{{Label: "Gone", RootPath: "/does/not/exist"}},
	}, nil))
}

func TestMoveCollection(t *testing.T) {
	h := newHarness(t, "")
	require.Equal(t, api.JobDone, h.index(makeDisk(t, map[string]string{"Photos/a.jpg": "a", "Music/x.flac": "x"})).State)
	var j api.Job
	require.Equal(t, http.StatusAccepted, h.do("POST", "/v1/jobs", api.IndexRequest{Disk: "Disk2", MountPath: makeDisk(t, map[string]string{"Docs/d.txt": "d"})}, &j))
	require.Equal(t, api.JobDone, h.waitJob(j.ID).State)

	var colls []api.Collection
	require.Equal(t, http.StatusOK, h.do("GET", "/v1/collections?disk=Disk1", nil, &colls))
	var photos api.Collection
	for _, c := range colls {
		if c.Label == "Photos" {
			photos = c
		}
	}

	var moved api.Collection
	require.Equal(t, http.StatusOK, h.do("POST", fmt.Sprintf("/v1/collections/%d/move", photos.ID), map[string]string{"disk": "Disk2"}, &moved))
	assert.Equal(t, "Disk2", moved.DiskLabel)
	assert.Equal(t, photos.ID, moved.ID)

	var res api.SearchResponse
	require.Equal(t, http.StatusOK, h.do("POST", "/v1/search", api.SearchRequest{Query: "a.jpg"}, &res))
	require.Len(t, res.Results, 1)
	assert.Equal(t, "Disk2/Photos/a.jpg", res.Results[0].Path)

	// Unknown target disk, unknown collection, and a name clash on the target.
	assert.Equal(t, http.StatusNotFound, h.do("POST", fmt.Sprintf("/v1/collections/%d/move", photos.ID), map[string]string{"disk": "Nope"}, nil))
	assert.Equal(t, http.StatusNotFound, h.do("POST", "/v1/collections/9999/move", map[string]string{"disk": "Disk1"}, nil))
	require.Equal(t, http.StatusOK, h.do("GET", "/v1/collections?disk=Disk2", nil, &colls))
	var docs api.Collection
	for _, c := range colls {
		if c.Label == "Docs" {
			docs = c
		}
	}
	require.Equal(t, http.StatusNoContent, h.do("PATCH", fmt.Sprintf("/v1/collections/%d", docs.ID), map[string]string{"label": "Music"}, nil))
	assert.Equal(t, http.StatusConflict, h.do("POST", fmt.Sprintf("/v1/collections/%d/move", docs.ID), map[string]string{"disk": "Disk1"}, nil))
}

func TestJobReportsUnreadablePaths(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read anything")
	}
	h := newHarness(t, "")
	root := makeDisk(t, map[string]string{"Photos/ok.jpg": "o", "Photos/locked/a.jpg": "a"})
	require.Equal(t, api.JobDone, h.index(root).State)

	locked := filepath.Join(root, "Photos", "locked")
	require.NoError(t, os.Chmod(locked, 0))
	t.Cleanup(func() { os.Chmod(locked, 0o755) })

	j := h.index(root)
	require.Equal(t, api.JobDone, j.State, "unreadable folders don't fail the run")
	require.NotNil(t, j.Stats)
	assert.Equal(t, 1, j.Stats.ErrorCount)
	require.Len(t, j.Stats.Errors, 1)
	assert.Equal(t, locked, j.Stats.Errors[0].Path)
	assert.Equal(t, 1, j.Progress.Errors)
	assert.Zero(t, j.Stats.Deleted)
}

func TestExcludesDefaultsAndPerDisk(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "x.diskindex")
	svc, err := api.NewService("test", dbPath, nil)
	require.NoError(t, err)
	svc.DefaultExcludes = []string{".snapshots"}
	srv := httptest.NewServer(server.New(svc, ""))
	t.Cleanup(func() { srv.Close(); svc.Close() })
	h := &harness{t: t, srv: srv}

	var info api.Info
	require.Equal(t, http.StatusOK, h.do("GET", "/v1/info", nil, &info))
	assert.Equal(t, []string{".snapshots"}, info.DefaultExcludes)

	root := makeDisk(t, map[string]string{"P/a.jpg": "a", "P/.snapshots/s": "s", "P/x.tmp": "t"})
	var j api.Job
	require.Equal(t, http.StatusAccepted, h.do("POST", "/v1/jobs",
		api.IndexRequest{Disk: "D", MountPath: root, Excludes: []string{"*.tmp"}}, &j))
	j = h.waitJob(j.ID)
	require.Equal(t, api.JobDone, j.State, j.Error)
	assert.Equal(t, []string{".snapshots", "*.tmp"}, j.Stats.Excludes)

	var disks []api.Disk
	require.Equal(t, http.StatusOK, h.do("GET", "/v1/disks", nil, &disks))
	require.Len(t, disks, 1)
	assert.Equal(t, []string{"*.tmp"}, disks[0].Excludes, "only the disk's own excludes are saved")

	// Omitting excludes reuses the saved ones; opting out drops the defaults.
	require.Equal(t, http.StatusAccepted, h.do("POST", "/v1/jobs",
		api.IndexRequest{Disk: "D", MountPath: root, NoDefaultExcludes: true}, &j))
	j = h.waitJob(j.ID)
	assert.Equal(t, []string{"*.tmp"}, j.Stats.Excludes)
}

func TestSchedules(t *testing.T) {
	h := newHarness(t, "")
	root := makeDisk(t, map[string]string{"Photos/a.jpg": "a"})
	require.Equal(t, api.JobDone, h.index(root).State)

	var sc api.Schedule
	req := map[string]any{"disk": "Disk1", "path": root, "intervalHours": 24, "at": "03:00", "enabled": true}
	require.Equal(t, http.StatusCreated, h.do("POST", "/v1/schedules", req, &sc))
	assert.NotNil(t, sc.NextRunAt)
	assert.Equal(t, http.StatusConflict, h.do("POST", "/v1/schedules", req, nil))
	assert.Equal(t, http.StatusBadRequest, h.do("POST", "/v1/schedules", map[string]any{"disk": "Disk1", "intervalHours": 24}, nil))
	assert.Equal(t, http.StatusNotFound, h.do("POST", "/v1/schedules", map[string]any{"disk": "Nope", "path": root, "intervalHours": 24}, nil))

	req["enabled"] = false
	sc = api.Schedule{ID: sc.ID}
	require.Equal(t, http.StatusOK, h.do("PUT", fmt.Sprintf("/v1/schedules/%d", sc.ID), req, &sc))
	assert.Nil(t, sc.NextRunAt)

	var list []api.Schedule
	require.Equal(t, http.StatusOK, h.do("GET", "/v1/schedules", nil, &list))
	require.Len(t, list, 1)

	require.Equal(t, http.StatusOK, h.do("POST", fmt.Sprintf("/v1/schedules/%d/run", sc.ID), nil, &sc))
	require.Equal(t, "running", sc.LastStatus)
	j := h.waitJob(sc.LastJobID)
	assert.Equal(t, sc.ID, j.Schedule)

	assert.Equal(t, http.StatusBadRequest, h.do("POST", "/v1/schedules/x/run", nil, nil))
	assert.Equal(t, http.StatusNotFound, h.do("POST", "/v1/schedules/99/run", nil, nil))
	assert.Equal(t, http.StatusBadRequest, h.do("PUT", "/v1/schedules/x", req, nil))
	assert.Equal(t, http.StatusBadRequest, h.do("DELETE", "/v1/schedules/x", nil, nil))
	assert.Equal(t, http.StatusNoContent, h.do("DELETE", fmt.Sprintf("/v1/schedules/%d", sc.ID), nil, nil))
	assert.Equal(t, http.StatusNotFound, h.do("DELETE", fmt.Sprintf("/v1/schedules/%d", sc.ID), nil, nil))
}

// JSON responses are gzipped for clients that ask; event streams never are.
func TestGzip(t *testing.T) {
	h := newHarness(t, "")
	root := makeDisk(t, map[string]string{"Photos/a.jpg": "a"})
	j := h.index(root)

	get := func(path string) *http.Response {
		req, err := http.NewRequest("GET", h.srv.URL+path, nil)
		require.NoError(t, err)
		req.Header.Set("Accept-Encoding", "gzip")
		resp, err := http.DefaultTransport.RoundTrip(req)
		require.NoError(t, err)
		t.Cleanup(func() { resp.Body.Close() })
		return resp
	}
	resp := get("/v1/disks")
	require.Equal(t, "gzip", resp.Header.Get("Content-Encoding"))
	zr, err := gzip.NewReader(resp.Body)
	require.NoError(t, err)
	var disks []api.Disk
	require.NoError(t, json.NewDecoder(zr).Decode(&disks))
	assert.Len(t, disks, 1)

	assert.Empty(t, get("/v1/jobs/"+j.ID+"/events").Header.Get("Content-Encoding"))
}
