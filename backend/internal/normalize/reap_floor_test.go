package normalize

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TASK-937: the retention reaper never removes the newest three backups, whatever their
// age, so an idle server keeps the originals of its most recent conversions.

// writeBackup creates backup/rel with the given age and returns its path.
func writeBackup(t *testing.T, backup, rel string, age time.Duration) string {
	t.Helper()
	p := filepath.Join(backup, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	at := time.Now().Add(-age)
	if err := os.Chtimes(p, at, at); err != nil {
		t.Fatal(err)
	}
	return p
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

const day = 24 * time.Hour

func TestReapFloor_IdleServerKeepsNewestThreeExpiredBackups(t *testing.T) {
	backup := t.TempDir()
	w := &NormalizeWorker{backupDir: backup}
	// Every backup is past the 7-day window; ages 10..14 days, spread over folders.
	paths := []string{
		writeBackup(t, backup, "Movies/a.mkv", 10*day),
		writeBackup(t, backup, "TV/Show/b.mkv", 11*day),
		writeBackup(t, backup, "Movies/c.mkv", 12*day),
		writeBackup(t, backup, "TV/Show/d.mkv", 13*day),
		writeBackup(t, backup, "Movies/e.mkv", 14*day),
	}

	w.reapBackups(7)

	for _, p := range paths[:3] {
		if !exists(p) {
			t.Errorf("%s is one of the newest three backups and was reaped", p)
		}
	}
	for _, p := range paths[3:] {
		if exists(p) {
			t.Errorf("%s is expired and not among the newest three, but survived", p)
		}
	}
}

func TestReapFloor_FewerThanThreeExpiredBackupsAreAllKept(t *testing.T) {
	backup := t.TempDir()
	w := &NormalizeWorker{backupDir: backup}
	a := writeBackup(t, backup, "a.mkv", 30*day)
	b := writeBackup(t, backup, "sub/b.mkv", 40*day)

	w.reapBackups(7)

	if !exists(a) || !exists(b) {
		t.Errorf("the only backups were reaped by age (a=%v b=%v); the newest three are kept", exists(a), exists(b))
	}
}

func TestReapFloor_WindowStillReapsExpiredBackupsBeyondTheFloor(t *testing.T) {
	backup := t.TempDir()
	w := &NormalizeWorker{backupDir: backup}
	var fresh []string
	for _, rel := range []string{"f1.mkv", "f2.mkv", "sub/f3.mkv", "sub/f4.mkv"} {
		fresh = append(fresh, writeBackup(t, backup, rel, time.Hour))
	}
	oldA := writeBackup(t, backup, "old/a.mkv", 8*day)
	oldB := writeBackup(t, backup, "old/b.mkv", 20*day)

	w.reapBackups(7)

	for _, p := range fresh {
		if !exists(p) {
			t.Errorf("fresh backup %s was reaped", p)
		}
	}
	if exists(oldA) || exists(oldB) {
		t.Errorf("expired backups survived although four newer ones fill the floor (a=%v b=%v)", exists(oldA), exists(oldB))
	}
	if exists(filepath.Join(backup, "old")) {
		t.Errorf("folder emptied by the reaper was not pruned")
	}
}
