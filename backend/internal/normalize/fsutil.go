package normalize

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// moveFile moves src to dst. It first tries a plain rename (atomic, instant when src
// and dst are on the same filesystem — the normal case, backupDir is a sibling tree
// on the video volume). If rename fails with a cross-device error, it falls back to a
// copy+remove so a backup dir on a different volume still works. The destination is
// written, fully fsync'd, and size-verified, and ONLY THEN is the source removed, so a
// failed move (or a power loss mid-copy) never loses the original. (TASK-755 data-safety,
// Worf P0-1: the old fallback never fsync'd, so on power loss the backup could be
// truncated while the original had already been removed.)
func moveFile(src, dst string) error {
	if err := os.Rename(src, dst); err == nil {
		return nil
	}
	// Cross-device or other rename failure — copy then remove. copyFile fsyncs the
	// destination (and its parent dir) and verifies the copied size matches the source
	// before returning nil, so reaching os.Remove means the backup is durable on disk.
	if err := copyFile(src, dst); err != nil {
		return err
	}
	if err := os.Remove(src); err != nil {
		// Copy succeeded but the source couldn't be removed. Remove the copy to avoid
		// a duplicate and surface the error rather than silently leaving two files.
		_ = os.Remove(dst)
		return fmt.Errorf("remove source after copy: %w", err)
	}
	return nil
}

// copyFile copies src to dst (creating/truncating dst), preserving the source's
// modification time so a same-volume vs cross-volume move yield consistent backup
// mtimes before the caller resets them.
//
// Worf P0-1 (TASK-755): the copy is made durable before the caller is allowed to remove
// the source. We fsync the file contents (out.Sync) and CHECK its error BEFORE Close,
// fsync the destination's parent directory so the new directory entry survives a crash,
// and verify the copied size equals the source size. On ANY copy/sync/verify error the
// partial destination is removed and the error returned with src left fully intact, so
// the caller's os.Remove(src) is never reached on a bad copy.
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	srcInfo, err := in.Stat()
	if err != nil {
		return err
	}

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	n, err := io.Copy(out, in)
	if err != nil {
		out.Close()
		_ = os.Remove(dst)
		return err
	}
	// Flush file data+metadata to stable storage and check the error BEFORE Close: a
	// deferred/late Close can mask a write-back failure, leaving us believing a truncated
	// backup is good. This is the crux of the P0-1 fix.
	if syncErr := out.Sync(); syncErr != nil {
		out.Close()
		_ = os.Remove(dst)
		return fmt.Errorf("fsync copy %s: %w", dst, syncErr)
	}
	if err := out.Close(); err != nil {
		_ = os.Remove(dst)
		return err
	}
	// Verify the copy is whole. A short copy that somehow returned no error must never
	// be treated as a durable backup the caller can delete the source against.
	if n != srcInfo.Size() {
		_ = os.Remove(dst)
		return fmt.Errorf("copy size mismatch for %s: wrote %d of %d bytes", dst, n, srcInfo.Size())
	}
	// fsync the destination's parent directory so the new directory entry itself survives
	// a power loss (file data is durable from out.Sync, but the entry linking it into the
	// dir is not until the dir is synced). Best-effort: a filesystem that rejects dir
	// fsync (some do) shouldn't fail an otherwise-good copy.
	if d, derr := os.Open(filepath.Dir(dst)); derr == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	_ = os.Chtimes(dst, srcInfo.ModTime(), srcInfo.ModTime())
	return nil
}

// pruneEmptyDirs removes empty directories under root (excluding root itself) after a
// retention sweep, so the backup tree doesn't accumulate empty skeleton folders. Walks
// bottom-up by recursing first. Best-effort; errors are ignored.
func pruneEmptyDirs(root string) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return
	}
	for _, e := range entries {
		if e.IsDir() {
			sub := filepath.Join(root, e.Name())
			pruneEmptyDirs(sub)
			if remaining, rerr := os.ReadDir(sub); rerr == nil && len(remaining) == 0 {
				_ = os.Remove(sub)
			}
		}
	}
}
