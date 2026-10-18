package normalize

import (
	"os"
	"path/filepath"
	"testing"
)

// TASK-1032: nothing that moves a file into (or out of) the backup tree may overwrite an
// existing file. The tree is shared by every library, and a backup is the only copy of the
// user's original once the converted file replaces it.

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestMoveFileRefusesToOverwriteExistingDestination(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src.bin")
	dst := filepath.Join(dir, "dst.bin")
	writeFile(t, src, "new original")
	writeFile(t, dst, "precious backup")

	if err := moveFile(src, dst); err == nil {
		t.Fatal("moveFile over an existing destination succeeded; it must refuse")
	}
	if b, _ := os.ReadFile(dst); string(b) != "precious backup" {
		t.Errorf("existing destination was modified: %q", b)
	}
	if b, err := os.ReadFile(src); err != nil || string(b) != "new original" {
		t.Errorf("source must be untouched after a refused move: %q (err %v)", b, err)
	}
}

// Movies/a/b.mkv and Shows/a/b.mkv have the same path relative to their library roots and so
// the same slot in the shared backup tree. Both originals must survive.
func TestBackupOriginalKeepsBothLibrariesSameRelativePath(t *testing.T) {
	movies, shows, backup := t.TempDir(), t.TempDir(), t.TempDir()
	w := &NormalizeWorker{backupDir: backup}

	m := filepath.Join(movies, "Dir", "film.mkv")
	s := filepath.Join(shows, "Dir", "film.mkv")
	writeFile(t, m, "movie original")
	writeFile(t, s, "show original")

	if err := w.backupOriginal(m, movies); err != nil {
		t.Fatalf("backup movie: %v", err)
	}
	if err := w.backupOriginal(s, shows); err != nil {
		t.Fatalf("backup show: %v", err)
	}

	got := map[string]bool{}
	_ = filepath.Walk(backup, func(p string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			b, _ := os.ReadFile(p)
			got[string(b)] = true
		}
		return nil
	})
	if !got["movie original"] || !got["show original"] {
		t.Errorf("a backup was overwritten; surviving contents: %v", got)
	}
}

// A rollback must put back the file that was backed up, from wherever it landed, and must
// leave the OTHER library's backup in the preferred slot alone.
func TestRestoreOriginalUsesActualBackupLocation(t *testing.T) {
	movies, shows, backup := t.TempDir(), t.TempDir(), t.TempDir()
	w := &NormalizeWorker{backupDir: backup}

	m := filepath.Join(movies, "film.mkv")
	s := filepath.Join(shows, "film.mkv")
	writeFile(t, m, "movie original")
	writeFile(t, s, "show original")

	mAt, err := w.backupOriginalTo(m, movies)
	if err != nil {
		t.Fatal(err)
	}
	sAt, err := w.backupOriginalTo(s, shows)
	if err != nil {
		t.Fatal(err)
	}
	if mAt == sAt {
		t.Fatalf("both originals were filed at %s", mAt)
	}

	if err := w.restoreOriginal(s, sAt); err != nil {
		t.Fatalf("restore: %v", err)
	}
	if b, _ := os.ReadFile(s); string(b) != "show original" {
		t.Errorf("restored content = %q", b)
	}
	if b, _ := os.ReadFile(mAt); string(b) != "movie original" {
		t.Errorf("the other library's backup was disturbed: %q", b)
	}
}
