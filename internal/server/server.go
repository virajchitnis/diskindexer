// Package server exposes api.Service over HTTP/JSON for the GUI clients.
package server

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/viraj/diskindexer/internal/api"
)

// eventInterval throttles the progress stream; the indexer reports far more
// often than a UI needs.
const eventInterval = 250 * time.Millisecond

// New returns the HTTP handler. When token is non-empty every request must
// carry "Authorization: Bearer <token>".
func New(svc *api.Service, token string) http.Handler {
	mux := http.NewServeMux()
	h := &handlers{svc: svc}

	mux.HandleFunc("GET /v1/info", h.info)
	mux.HandleFunc("GET /v1/disks", h.disks)
	mux.HandleFunc("DELETE /v1/disks/{label}", h.deleteDisk)
	mux.HandleFunc("GET /v1/collections", h.collections)
	mux.HandleFunc("PATCH /v1/collections/{id}", h.renameCollection)
	mux.HandleFunc("DELETE /v1/collections/{id}", h.deleteCollection)
	mux.HandleFunc("POST /v1/collections/{id}/move", h.moveCollection)
	mux.HandleFunc("POST /v1/search", h.search)
	mux.HandleFunc("GET /v1/jobs", h.jobs)
	mux.HandleFunc("POST /v1/jobs", h.startJob)
	mux.HandleFunc("GET /v1/jobs/{id}", h.job)
	mux.HandleFunc("DELETE /v1/jobs/{id}", h.cancelJob)
	mux.HandleFunc("GET /v1/jobs/{id}/events", h.jobEvents)
	mux.HandleFunc("GET /v1/schedules", h.schedules)
	mux.HandleFunc("POST /v1/schedules", h.saveSchedule)
	mux.HandleFunc("PUT /v1/schedules/{id}", h.saveSchedule)
	mux.HandleFunc("DELETE /v1/schedules/{id}", h.deleteSchedule)
	mux.HandleFunc("POST /v1/schedules/{id}/run", h.runSchedule)
	mux.HandleFunc("GET /v1/fs/roots", h.fsRoots)
	mux.HandleFunc("GET /v1/fs/list", h.fsList)

	if token == "" {
		return mux
	}
	want := []byte("Bearer " + token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), want) != 1 {
			writeJSON(w, http.StatusUnauthorized, api.Error{Error: "unauthorized"})
			return
		}
		mux.ServeHTTP(w, r)
	})
}

type handlers struct {
	svc *api.Service
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, err error) {
	status := http.StatusInternalServerError
	switch {
	case errors.Is(err, api.ErrBadRequest):
		status = http.StatusBadRequest
	case errors.Is(err, api.ErrNotFound):
		status = http.StatusNotFound
	case errors.Is(err, api.ErrConflict):
		status = http.StatusConflict
	default:
		log.Printf("error: %v", err)
	}
	writeJSON(w, status, api.Error{Error: err.Error()})
}

func decode(r *http.Request, v any) error {
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		return fmt.Errorf("%w: invalid JSON: %v", api.ErrBadRequest, err)
	}
	return nil
}

func pathID(r *http.Request) (int64, error) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%w: invalid id", api.ErrBadRequest)
	}
	return id, nil
}

func (h *handlers) info(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, h.svc.Info())
}

func (h *handlers) disks(w http.ResponseWriter, _ *http.Request) {
	disks, err := h.svc.Disks()
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, disks)
}

func (h *handlers) deleteDisk(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.DeleteDisk(r.URL.Query().Get("db"), r.PathValue("label")); err != nil {
		writeErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *handlers) collections(w http.ResponseWriter, r *http.Request) {
	colls, err := h.svc.Collections(r.URL.Query().Get("disk"))
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, colls)
}

func (h *handlers) renameCollection(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r)
	if err != nil {
		writeErr(w, err)
		return
	}
	var body struct {
		DB    string `json:"db"`
		Label string `json:"label"`
	}
	if err := decode(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	if err := h.svc.RenameCollection(body.DB, id, body.Label); err != nil {
		writeErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *handlers) moveCollection(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r)
	if err != nil {
		writeErr(w, err)
		return
	}
	var body struct {
		DB   string `json:"db"`
		Disk string `json:"disk"`
	}
	if err := decode(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	coll, err := h.svc.MoveCollection(body.DB, id, body.Disk)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, coll)
}

func (h *handlers) deleteCollection(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r)
	if err != nil {
		writeErr(w, err)
		return
	}
	if err := h.svc.DeleteCollection(r.URL.Query().Get("db"), id); err != nil {
		writeErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *handlers) search(w http.ResponseWriter, r *http.Request) {
	var req api.SearchRequest
	if err := decode(r, &req); err != nil {
		writeErr(w, err)
		return
	}
	resp, err := h.svc.Search(req)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (h *handlers) jobs(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, h.svc.Jobs())
}

func (h *handlers) startJob(w http.ResponseWriter, r *http.Request) {
	var req api.IndexRequest
	if err := decode(r, &req); err != nil {
		writeErr(w, err)
		return
	}
	job, err := h.svc.StartIndex(req)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, job)
}

func (h *handlers) job(w http.ResponseWriter, r *http.Request) {
	job, err := h.svc.Job(r.PathValue("id"))
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, job)
}

func (h *handlers) cancelJob(w http.ResponseWriter, r *http.Request) {
	job, err := h.svc.CancelJob(r.PathValue("id"))
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, job)
}

// jobEvents streams the job as Server-Sent Events: a "progress" event with
// the full Job snapshot at most every eventInterval, and a final "done" event
// once the job has finished, after which the stream closes.
func (h *handlers) jobEvents(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	snap, changed, err := h.svc.WatchJob(id)
	if err != nil {
		writeErr(w, err)
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeErr(w, errors.New("streaming unsupported"))
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusOK)

	send := func(event string, job api.Job) {
		data, _ := json.Marshal(job)
		fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, data)
		flusher.Flush()
	}

	for {
		if snap.State != api.JobRunning {
			send("done", snap)
			return
		}
		send("progress", snap)
		select {
		case <-r.Context().Done():
			return
		case <-changed:
		}
		select {
		case <-r.Context().Done():
			return
		case <-time.After(eventInterval):
		}
		snap, changed, _ = h.svc.WatchJob(id)
	}
}

func (h *handlers) schedules(w http.ResponseWriter, _ *http.Request) {
	list, err := h.svc.Schedules()
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, list)
}

// saveSchedule creates (POST) or replaces (PUT) a schedule.
func (h *handlers) saveSchedule(w http.ResponseWriter, r *http.Request) {
	var id int64
	status := http.StatusCreated
	if r.PathValue("id") != "" {
		var err error
		if id, err = pathID(r); err != nil {
			writeErr(w, err)
			return
		}
		status = http.StatusOK
	}
	var body struct {
		DB string `json:"db"`
		api.ScheduleRequest
	}
	if err := decode(r, &body); err != nil {
		writeErr(w, err)
		return
	}
	sc, err := h.svc.SaveSchedule(body.DB, id, body.ScheduleRequest)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, status, sc)
}

func (h *handlers) deleteSchedule(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r)
	if err != nil {
		writeErr(w, err)
		return
	}
	if err := h.svc.DeleteSchedule(r.URL.Query().Get("db"), id); err != nil {
		writeErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *handlers) runSchedule(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r)
	if err != nil {
		writeErr(w, err)
		return
	}
	sc, err := h.svc.RunSchedule(r.URL.Query().Get("db"), id)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sc)
}

func (h *handlers) fsRoots(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, h.svc.Roots())
}

func (h *handlers) fsList(w http.ResponseWriter, r *http.Request) {
	listing, err := h.svc.ListDir(r.URL.Query().Get("path"))
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, listing)
}
