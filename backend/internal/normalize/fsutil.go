package normalize

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
)

// moveFile moves src to dst and NEVER overwrites: if anything already exists at dst it
// returns an error wrapping fs.ErrExist and leaves both files untouched. (TASK-1032: the
// backup tree is shared by every library and a backup is the only copy of the user's
// original once the converted file replaces it, so a silent overwrite is data loss.)
//
// The no-clobber guarantee is atomic, not a check-then-act: os.Rename replaces an existing
// destination, so the move is a hard link (os.Link fails with EEXIST rather than replacing)
// followed by removing src. Where hard links are unavailable (a backup dir on another volume
// or a filesystem without link support) it falls back to claiming dst with O_EXCL and then
// copy+remove. The destination is written, fully fsync'd, and size-verified, and ONLY THEN
// is the source removed, so a failed move (or a power loss mid-copy) never loses the
// original. (TASK-755 data-safety, Worf P0-1.)
func moveFile(src, dst string) error {
	err := os.Link(src, dst)
	if err == nil {
		if rmErr := os.Remove(src); rmErr != nil {
			// Both names now point at the data. Drop the new one so we do not leave a
			// duplicate, and surface the error; the source is still intact.
			_ = os.Remove(dst)
			return fmt.Errorf("remove source after link: %w", rmErr)
		}
		return nil
	}
	if errors.Is(err, fs.ErrExist) {
		return fmt.Errorf("refusing to overwrite existing %s: %w", dst, fs.ErrExist)
	}

	// Cross-device or no hard-link support: claim the name atomically, then copy. O_EXCL
	// means two movers racing for the same slot cannot both win it.
	claim, cerr := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if cerr != nil {
		if errors.Is(cerr, fs.ErrExist) {
			return fmt.Errorf("refusing to overwrite existing %s: %w", dst, fs.ErrExist)
		}
		return cerr
	}
	if clErr := claim.Close(); clErr != nil {
		_ = os.Remove(dst)
		return clErr
	}
	// copyFile fsyncs the destination (and its parent dir) and verifies the copied size
	// matches the source before returning nil, and removes dst on any failure, so reaching
	// os.Remove(src) means the copy is durable on disk.
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

// copyFile copies src to dst (dst must be one the caller owns: moveFile claims it with
// O_EXCL first, and this truncates it), preserving the source's
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
