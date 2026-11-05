package cmd

import (
	"errors"
	"fmt"
	"io"
	"net"

	"github.com/spf13/cobra"
)

var connectSocket string

var connectCmd = &cobra.Command{
	Use:   "connect",
	Short: "Relay stdin and stdout to a running server's socket",
	Long: `Connects to the Unix socket of a running "diskindexer serve" and relays
stdin and stdout to it until either side closes. The iPhone and iPad app runs
it over SSH for each HTTP connection, since SSH libraries there can't forward
Unix sockets themselves.

Exits with status 3 when no server is listening on the socket.`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		path := connectSocket
		if path == "" {
			path = defaultSocketPath()
		}
		return relay(expandHome(path), cmd.InOrStdin(), cmd.OutOrStdout())
	},
}

func init() {
	connectCmd.Flags().StringVar(&connectSocket, "socket", "",
		"server socket (default ~/.config/diskindexer/server.sock)")
	rootCmd.AddCommand(connectCmd)
}

// exitError carries a specific exit status out of a command.
type exitError struct {
	code int
	err  error
}

func (e *exitError) Error() string { return e.err.Error() }
func (e *exitError) Unwrap() error { return e.err }

// errNoServer is returned (as exit status 3) when nothing listens on the socket.
var errNoServer = errors.New("no server is running")

// relay copies in to the socket at path and the socket's replies to out.
// When in ends, the socket's write side is closed so the server sees the
// end of the request stream; relay returns once the server closes too.
func relay(path string, in io.Reader, out io.Writer) error {
	c, err := net.Dial("unix", path)
	if err != nil {
		return &exitError{3, fmt.Errorf("%w on %s: %v", errNoServer, path, err)}
	}
	defer c.Close()
	go func() {
		_, _ = io.Copy(c, in)
		_ = c.(*net.UnixConn).CloseWrite()
	}()
	if _, err := io.Copy(out, c); err != nil && !errors.Is(err, net.ErrClosed) {
		return err
	}
	return nil
}

// exitCode is the process status for an error returned by a command.
func exitCode(err error) int {
	var e *exitError
	if errors.As(err, &e) {
		return e.code
	}
	return 1
}
