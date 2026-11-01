package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/cobra"
	"github.com/viraj/diskindexer/internal/api"
	"github.com/viraj/diskindexer/internal/server"
)

var (
	serveListen     []string
	serveToken      string
	serveStdinWatch bool
)

var serveCmd = &cobra.Command{
	Use:   "serve",
	Short: "Run the HTTP API used by the DiskIndexer GUI apps",
	Long: `Serves a JSON API for searching, managing and indexing disks. The macOS app
talks to it, either by launching it locally or through an SSH tunnel to a
server where it runs as a service.

--listen accepts "unix:/path/to.sock" or "host:port" and may be repeated. The
default is a Unix socket at ~/.config/diskindexer/server.sock, readable only by
your user. TCP listeners on a non-loopback address require --token.

Each listener's address is printed to stdout as a JSON line, e.g.
{"listen":"127.0.0.1:54321"}, which is how clients find a ":0" port.`,
	Args: cobra.NoArgs,
	RunE: runServe,
}

func init() {
	serveCmd.Flags().StringArrayVar(&serveListen, "listen", nil,
		`address to listen on: "unix:/path" or "host:port" (repeatable; default unix:~/.config/diskindexer/server.sock)`)
	serveCmd.Flags().StringVar(&serveToken, "token", "",
		"require this bearer token on every request (default $DISKINDEXER_TOKEN)")
	serveCmd.Flags().BoolVar(&serveStdinWatch, "stdin-watch", false,
		"exit when stdin closes (used by the macOS app so the server dies with it)")
	_ = serveCmd.Flags().MarkHidden("stdin-watch")
	rootCmd.AddCommand(serveCmd)
}

func defaultSocketPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "diskindexer", "server.sock")
}

func runServe(_ *cobra.Command, _ []string) error {
	log.SetOutput(os.Stderr)
	token := serveToken
	if token == "" {
		token = os.Getenv("DISKINDEXER_TOKEN")
	}
	addrs := serveListen
	if len(addrs) == 0 {
		addrs = []string{"unix:" + defaultSocketPath()}
	}

	var listeners []net.Listener
	closeAll := func() {
		for _, l := range listeners {
			l.Close()
		}
	}
	for _, addr := range addrs {
		l, err := listen(addr, token)
		if err != nil {
			closeAll()
			return err
		}
		listeners = append(listeners, l)
	}

	cfg := loadConfig()
	svc, err := api.NewService(version, resolveSingleDB(cfg), resolveSearchDBs(cfg))
	if err != nil {
		closeAll()
		return err
	}
	defer svc.Close()

	srv := &http.Server{Handler: server.New(svc, token), ReadHeaderTimeout: 10 * time.Second}
	errc := make(chan error, len(listeners))
	for _, l := range listeners {
		line, _ := json.Marshal(map[string]string{"listen": listenerAddr(l)})
		fmt.Println(string(line))
		go func(l net.Listener) { errc <- srv.Serve(l) }(l)
	}
	log.Printf("diskindexer %s serving %s", version, strings.Join(addrs, ", "))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if serveStdinWatch {
		go func() {
			_, _ = io.Copy(io.Discard, os.Stdin)
			stop()
		}()
	}

	select {
	case <-ctx.Done():
	case err := <-errc:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	}
	log.Printf("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	// Progress streams never end on their own, so fall back to a hard close.
	if err := srv.Shutdown(shutdownCtx); err != nil {
		srv.Close()
	}
	return nil
}

func listenerAddr(l net.Listener) string {
	if l.Addr().Network() == "unix" {
		return "unix:" + l.Addr().String()
	}
	return l.Addr().String()
}

func listen(addr, token string) (net.Listener, error) {
	if path, ok := strings.CutPrefix(addr, "unix:"); ok {
		return listenUnix(expandHome(path))
	}
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, fmt.Errorf("--listen %q: %w", addr, err)
	}
	if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) && token == "" {
		return nil, fmt.Errorf("--listen %q is reachable from the network; set --token too", addr)
	}
	return net.Listen("tcp", addr)
}

// listenUnix creates a socket only the current user can connect to. A stale
// socket left by a crashed server is removed; a live one is an error.
func listenUnix(path string) (net.Listener, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	if _, err := os.Stat(path); err == nil {
		if c, err := net.Dial("unix", path); err == nil {
			c.Close()
			return nil, fmt.Errorf("another server is already listening on %s", path)
		}
		if err := os.Remove(path); err != nil {
			return nil, err
		}
	}
	old := syscall.Umask(0o177)
	l, err := net.Listen("unix", path)
	syscall.Umask(old)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		l.Close()
		return nil, err
	}
	return l, nil
}

func expandHome(path string) string {
	if rest, ok := strings.CutPrefix(path, "~/"); ok {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, rest)
	}
	return path
}
