package main

// TASK-933: a read failure during a library scan must resolve toward KEEPING rows.
//
// The walk used to swallow every error, so an unreadable folder looked like an empty one:
// its items were deleted and tombstoned (every client dropped them), and the periodic
// orphaned-progress purge then erased every profile's watch position for them.

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func scanTestServer(t *testing.T) *Server {
	t.Helper()
	s, _ := newProfilesTestServer(t)
	return s
}

func writeVideo(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte("not really a video"), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func itemExists(t *testing.T, s *Server, path string) bool {
	t.Helper()
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM items WHERE id = ?`, itemIDFromPath(path)).Scan(&n); err != nil {
		t.Fatalf("count items: %v", err)
	}
	return n == 1
}

func tombstoned(t *testing.T, s *Server, path string) bool {
	t.Helper()
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM deleted_items WHERE item_id = ?`, itemIDFromPath(path)).Scan(&n); err != nil {
		t.Fatalf("count tombstones: %v", err)
	}
	return n > 0
}

func insertProgress(t *testing.T, s *Server, itemID, profileID string) {
	t.Helper()
	if _, err := s.db.Exec(`INSERT INTO progress(item_id, user_id, profile_id, position_seconds, duration_seconds, updated_at)
		VALUES(?, 'u1', ?, 600, 3600, '2026-10-01T00:00:00Z')`, itemID, profileID); err != nil {
		t.Fatalf("insert progress: %v", err)
	}
}

func progressExists(t *testing.T, s *Server, itemID, profileID string) bool {
	t.Helper()
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM progress WHERE item_id = ? AND profile_id = ?`, itemID, profileID).Scan(&n); err != nil {
		t.Fatalf("count progress: %v", err)
	}
	return n == 1
}

// captureLog is the shared helper in profiles_migrate_test.go.

// lockDir removes every permission from dir so ReadDir fails, restoring it on cleanup so
// t.TempDir can remove the tree. Root ignores mode bits, so the reproduction is impossible
// there; the pure planStalePurge tests below still cover the rule under root.
func lockDir(t *testing.T, dir string) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("running as root: permission bits do not make a folder unreadable, so this reproduction cannot be staged")
	}
	if err := os.Chmod(dir, 0); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })
	if _, err := os.ReadDir(dir); err == nil {
		t.Fatalf("staging failed: %s is still readable after chmod 0", dir)
	}
}

func TestScanKeepsItemsUnderUnreadableFolder(t *testing.T) {
	s := scanTestServer(t)
	ctx := context.Background()
	root := t.TempDir()
	readable := filepath.Join(root, "Open", "kept.mp4")
	removed := filepath.Join(root, "Open", "removed.mp4")
	locked := filepath.Join(root, "Locked", "inside.mp4")
	for _, p := range []string{readable, removed, locked} {
		writeVideo(t, p)
	}
	if err := s.scanLibraryWithClient(ctx, "lib_movies", "movies", root, nil); err != nil {
		t.Fatalf("first scan: %v", err)
	}
	for _, p := range []string{readable, removed, locked} {
		if !itemExists(t, s, p) {
			t.Fatalf("first scan did not index %s", p)
		}
	}
	insertProgress(t, s, itemIDFromPath(locked), "pr_kid")
	insertProgress(t, s, itemIDFromPath(locked), "pr_owner")

	// One file genuinely deleted from a readable folder, one folder made unreadable.
	if err := os.Remove(removed); err != nil {
		t.Fatal(err)
	}
	lockDir(t, filepath.Join(root, "Locked"))
	logs := captureLog(t)

	if err := s.scanLibraryWithClient(ctx, "lib_movies", "movies", root, nil); err != nil {
		t.Fatalf("second scan: %v", err)
	}

	if !itemExists(t, s, locked) {
		t.Fatal("an item under an unreadable folder was deleted — a read failure must keep rows, not purge them")
	}
	if tombstoned(t, s, locked) {
		t.Fatal("an item under an unreadable folder was tombstoned — clients would drop it on their next delta sync")
	}
	if !itemExists(t, s, readable) {
		t.Fatal("an unchanged file in a readable folder was deleted")
	}
	// The guard is targeted: a real deletion in a folder the walk COULD read still goes.
	if itemExists(t, s, removed) || !tombstoned(t, s, removed) {
		t.Fatal("a file deleted from a readable folder must still be purged and tombstoned")
	}

	out := logs.String()
	if !strings.Contains(out, filepath.Join(root, "Locked")) || !strings.Contains(out, "permission denied") {
		t.Fatalf("the unreadable folder and its error must be logged; log was:\n%s", out)
	}

	// The periodic purge must not take the progress of a kept item.
	if _, err := s.purgeOrphanedProgress(time.Now()); err != nil {
		t.Fatalf("purge: %v", err)
	}
	for _, pr := range []string{"pr_kid", "pr_owner"} {
		if !progressExists(t, s, itemIDFromPath(locked), pr) {
			t.Fatalf("progress for %s on a kept item was purged", pr)
		}
	}
}

func TestScanOfEmptiedRootDeletesNothing(t *testing.T) {
	s := scanTestServer(t)
	ctx := context.Background()
	root := t.TempDir()
	files := []string{filepath.Join(root, "a.mp4"), filepath.Join(root, "Sub", "b.mkv")}
	for _, p := range files {
		writeVideo(t, p)
	}
	if err := s.scanLibraryWithClient(ctx, "lib_movies", "movies", root, nil); err != nil {
		t.Fatalf("first scan: %v", err)
	}

	// What an unmounted volume looks like: the mount point is still there, and empty.
	entries, _ := os.ReadDir(root)
	for _, e := range entries {
		if err := os.RemoveAll(filepath.Join(root, e.Name())); err != nil {
			t.Fatal(err)
		}
	}
	logs := captureLog(t)
	if err := s.scanLibraryWithClient(ctx, "lib_movies", "movies", root, nil); err != nil {
		t.Fatalf("second scan: %v", err)
	}
	for _, p := range files {
		if !itemExists(t, s, p) || tombstoned(t, s, p) {
			t.Fatalf("%s was purged by a scan of an empty root — an unmounted volume would wipe the library", p)
		}
	}
	if !strings.Contains(logs.String(), "found no video files") {
		t.Fatalf("the skipped purge must be logged; log was:\n%s", logs.String())
	}
}

func TestScanOfUnreadableRootFailsAndKeepsRows(t *testing.T) {
	s := scanTestServer(t)
	ctx := context.Background()
	root := t.TempDir()
	file := filepath.Join(root, "a.mp4")
	writeVideo(t, file)
	if err := s.scanLibraryWithClient(ctx, "lib_movies", "movies", root, nil); err != nil {
		t.Fatalf("first scan: %v", err)
	}
	lockDir(t, root)
	if err := s.scanLibraryWithClient(ctx, "lib_movies", "movies", root, nil); err == nil {
		t.Fatal("a scan whose root cannot be listed must report an error, not succeed with an empty view")
	}
	if !itemExists(t, s, file) || tombstoned(t, s, file) {
		t.Fatal("an unreadable root purged its library")
	}
}

// The rule itself, independent of how a folder came to be unreadable (runs as root too).
func TestPlanStalePurgeKeepsRowsUnderUnreadableFolders(t *testing.T) {
	rows := []libraryItemPath{
		{"seen", "/m/Open/a.mp4"},
		{"gone", "/m/Open/b.mp4"},
		{"locked", "/m/Locked/c.mp4"},
		{"lockedDeep", "/m/Locked/S01/d.mp4"},
		// A sibling whose name merely STARTS with the locked folder's name is not under it.
		{"sibling", "/m/LockedOut/e.mp4"},
	}
	seen := map[string]struct{}{"/m/Open/a.mp4": {}}
	plan := planStalePurge(rows, seen, []string{"/m/Locked"})
	if plan.emptyWalkGuard {
		t.Fatal("the walk saw a file; the empty-walk guard must not trip")
	}
	got := strings.Join(plan.staleIDs, ",")
	if got != "gone,sibling" {
		t.Fatalf("stale = %q, want %q", got, "gone,sibling")
	}
	if plan.keptUnreadable != 2 {
		t.Fatalf("keptUnreadable = %d, want 2", plan.keptUnreadable)
	}
}

func TestPlanStalePurgeEmptyWalkDeletesNothing(t *testing.T) {
	rows := []libraryItemPath{{"a", "/m/a.mp4"}, {"b", "/m/b.mp4"}}
	plan := planStalePurge(rows, map[string]struct{}{}, nil)
	if !plan.emptyWalkGuard || len(plan.staleIDs) != 0 {
		t.Fatalf("a walk that saw nothing must delete nothing: %+v", plan)
	}
	// A library with no rows has nothing to protect; the guard is about existing rows.
	if plan := planStalePurge(nil, map[string]struct{}{}, nil); plan.emptyWalkGuard || len(plan.staleIDs) != 0 {
		t.Fatalf("empty library: %+v", plan)
	}
}

// Progress for a title whose file is briefly missing survives the purge for the grace
// window, measured from the item's deletion tombstone, and goes after it.
func TestOrphanedProgressPurgeHonoursGraceWindow(t *testing.T) {
	s := scanTestServer(t)
	now := time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC)
	tomb := func(itemID string, age time.Duration) {
		t.Helper()
		if _, err := s.db.Exec(`INSERT INTO deleted_items(item_id, change_seq, deleted_at) VALUES(?, 1, ?)`,
			itemID, now.Add(-age).Format(time.RFC3339)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.db.Exec(`INSERT INTO items(id, library_id, type, title, path, added_at, updated_at) VALUES('present','lib_movies','movie','P','/m/p.mp4','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	insertProgress(t, s, "present", "pr1")
	insertProgress(t, s, "recentlyGone", "pr1")
	tomb("recentlyGone", 24*time.Hour)
	insertProgress(t, s, "longGone", "pr1")
	tomb("longGone", orphanProgressGrace+24*time.Hour)
	insertProgress(t, s, "noTombstone", "pr1")

	n, err := s.purgeOrphanedProgress(now)
	if err != nil {
		t.Fatalf("purge: %v", err)
	}
	if !progressExists(t, s, "present", "pr1") {
		t.Fatal("progress for a present item was purged")
	}
	if !progressExists(t, s, "recentlyGone", "pr1") {
		t.Fatal("progress for an item gone one day was purged — a remounted drive would lose every watch position")
	}
	if progressExists(t, s, "longGone", "pr1") || progressExists(t, s, "noTombstone", "pr1") {
		t.Fatal("orphans past the grace window (or with no tombstone) must still be purged")
	}
	if n != 2 {
		t.Fatalf("purged %d rows, want 2", n)
	}
	if orphanProgressGrace >= tombstoneRetention {
		t.Fatal("the grace window is measured from the tombstone, so it must be shorter than tombstone retention")
	}
}

// A folder that lists but whose entries cannot be stat'ed (read bit without search bit):
// the walk sees the names, every stat fails with EACCES. Not knowing a file's size is not
// evidence it is gone, so its row stays.
func TestScanKeepsItemWhoseStatFails(t *testing.T) {
	s := scanTestServer(t)
	ctx := context.Background()
	root := t.TempDir()
	dir := filepath.Join(root, "ListOnly")
	file := filepath.Join(dir, "a.mp4")
	writeVideo(t, file)
	writeVideo(t, filepath.Join(root, "other.mp4")) // keeps the empty-walk guard out of play
	if err := s.scanLibraryWithClient(ctx, "lib_movies", "movies", root, nil); err != nil {
		t.Fatalf("first scan: %v", err)
	}
	if os.Geteuid() == 0 {
		t.Skip("running as root: permission bits do not block stat, so this reproduction cannot be staged")
	}
	if err := os.Chmod(dir, 0o444); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })
	if _, err := os.ReadDir(dir); err != nil {
		t.Fatalf("staging failed: %s must still list: %v", dir, err)
	}
	if _, err := os.Lstat(file); err == nil {
		t.Fatalf("staging failed: %s is still stat-able", file)
	}
	logs := captureLog(t)
	if err := s.scanLibraryWithClient(ctx, "lib_movies", "movies", root, nil); err != nil {
		t.Fatalf("second scan: %v", err)
	}
	if !itemExists(t, s, file) || tombstoned(t, s, file) {
		t.Fatal("a file whose stat failed was purged — only ENOENT means a file is gone")
	}
	if !strings.Contains(logs.String(), "cannot stat") {
		t.Fatalf("the stat failure must be logged; log was:\n%s", logs.String())
	}
}
