package indexer

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// ErrUnavailable means a folder to index isn't there in a usable form: it is
// missing, empty, or the disk it was on isn't mounted. Indexing it anyway
// would remove everything indexed from it, so unattended runs skip instead.
var ErrUnavailable = errors.New("not available")

// FindMountPoint returns the mount point of the filesystem holding path: the
// highest folder above it on the same device. It returns "" when that is the
// root filesystem, or when path can't be read.
func FindMountPoint(path string) string {
	cur, err := filepath.EvalSymlinks(path)
	if err != nil {
		return ""
	}
	dev, ok := device(cur)
	if !ok {
		return ""
	}
	for cur != "/" {
		parent := filepath.Dir(cur)
		pdev, ok := device(parent)
		if !ok || pdev != dev {
			return cur
		}
		cur = parent
	}
	return ""
}

// CheckAvailable reports, as ErrUnavailable, why path shouldn't be indexed
// unattended: it doesn't exist, isn't a folder, is empty, or lies under
// mountPoint (from FindMountPoint, when the folder was set up) while nothing
// is mounted there any more. An unplugged disk usually leaves an empty folder
// behind at its mount point, which would otherwise read as "every file was
// deleted".
func CheckAvailable(path, mountPoint string) error {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return fmt.Errorf("%w: %s isn’t there", ErrUnavailable, path)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return fmt.Errorf("%w: %s: %v", ErrUnavailable, path, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("%w: %s isn’t a folder", ErrUnavailable, path)
	}
	if r, err := filepath.EvalSymlinks(mountPoint); mountPoint != "" && err == nil {
		mountPoint = r
	}
	if mountPoint != "" && (resolved == mountPoint || strings.HasPrefix(resolved, mountPoint+"/")) && !isMountPoint(mountPoint) {
		return fmt.Errorf("%w: nothing is mounted at %s", ErrUnavailable, mountPoint)
	}
	f, err := os.Open(resolved)
	if err != nil {
		return fmt.Errorf("%w: %s: %v", ErrUnavailable, path, err)
	}
	defer f.Close()
	if names, _ := f.Readdirnames(1); len(names) == 0 {
		return fmt.Errorf("%w: %s is empty", ErrUnavailable, path)
	}
	return nil
}

// isMountPoint reports whether path is the root of a filesystem, i.e. on a
// different device from its parent.
func isMountPoint(path string) bool {
	if path == "/" {
		return true
	}
	dev, ok := device(path)
	if !ok {
		return false
	}
	pdev, ok := device(filepath.Dir(path))
	return ok && pdev != dev
}

func device(path string) (uint64, bool) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, false
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return uint64(st.Dev), true //nolint:unconvert // int32 on darwin
}
