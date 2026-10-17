package main

// FRD-002 FR-232 / FR-206 verification: the production migration envelope (AC-002-22/23) and
// profile deletion scope (AC-002-27). Fixture is an OLD-schema database (migrate() only, no
// migrateProfiles) populated with literal rows. Expected values are literals.

import (
	"bytes"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
)

const qaDSN = "?_pragma=busy_timeout(30000)&_pragma=journal_mode(WAL)&_pragma=synchronous(1)"

type qaProgressRow struct {
	Item, User string
	Pos, Dur   int
	At         string
	Seq        int
}

type qaWatchRow struct{ Item, User, At string }

var (
	qaOldProgress = []qaProgressRow{
		{"m1", "u_alice", 120, 7200, "2026-09-01T10:00:00Z", 5},
		{"m2", "u_alice", 3000, 5400, "2026-09-02T11:30:00Z", 9},
		{"m3", "u_alice", 0, 100, "2026-09-03T00:00:00Z", 0},
		{"m1", "u_bob", 45, 7200, "2026-09-04T08:15:00Z", 11},
	}
	qaOldWatchlist = []qaWatchRow{
		{"m2", "u_alice", "2026-08-01T00:00:00Z"},
		{"m3", "u_alice", "2026-08-02T00:00:00Z"},
		{"m1", "u_carol", "2026-08-03T00:00:00Z"},
	}
)

// oldSchemaDB builds a database exactly as a pre-profiles server left it: migrate() only.
func oldSchemaDB(t *testing.T) (*sql.DB, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "dsvideo.db")
	db, err := sql.Open("sqlite", path+qaDSN)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if err := migrate(db); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if has := hasColumn(t, db, "progress", "profile_id"); has {
		t.Fatalf("fixture is not old-schema: migrate() already created progress.profile_id")
	}
	for _, id := range []string{"m1", "m2", "m3"} {
		if _, err := db.Exec(`INSERT INTO items(id, library_id, type, title, path, added_at, updated_at)
			VALUES(?, 'lib1', 'movie', ?, ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')`, id, id, "/media/"+id+".mkv"); err != nil {
			t.Fatal(err)
		}
	}
	for _, r := range qaOldProgress {
		if _, err := db.Exec(`INSERT INTO progress(item_id,user_id,position_seconds,duration_seconds,updated_at,write_seq) VALUES(?,?,?,?,?,?)`,
			r.Item, r.User, r.Pos, r.Dur, r.At, r.Seq); err != nil {
			t.Fatal(err)
		}
	}
	for _, r := range qaOldWatchlist {
		if _, err := db.Exec(`INSERT INTO watchlist(item_id,user_id,added_at) VALUES(?,?,?)`, r.Item, r.User, r.At); err != nil {
			t.Fatal(err)
		}
	}
	// dave exists only through a download mark (an account with no progress or watchlist).
	if _, err := db.Exec(`INSERT INTO downloads(item_id,user_id,marked_at) VALUES('m1','u_dave','2026-07-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	return db, path
}

func hasColumn(t *testing.T, db *sql.DB, table, col string) bool {
	t.Helper()
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info(?) WHERE name=?`, table, col).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n > 0
}

func readProgress(t *testing.T, db *sql.DB, table string) []qaProgressRow {
	t.Helper()
	rows, err := db.Query(`SELECT item_id,user_id,position_seconds,duration_seconds,updated_at,write_seq FROM ` + table + ` ORDER BY user_id,item_id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []qaProgressRow
	for rows.Next() {
		var r qaProgressRow
		if err := rows.Scan(&r.Item, &r.User, &r.Pos, &r.Dur, &r.At, &r.Seq); err != nil {
			t.Fatal(err)
		}
		out = append(out, r)
	}
	return out
}

func readWatchlist(t *testing.T, db *sql.DB, table string) []qaWatchRow {
	t.Helper()
	rows, err := db.Query(`SELECT item_id,user_id,added_at FROM ` + table + ` ORDER BY user_id,item_id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []qaWatchRow
	for rows.Next() {
		var r qaWatchRow
		if err := rows.Scan(&r.Item, &r.User, &r.At); err != nil {
			t.Fatal(err)
		}
		out = append(out, r)
	}
	return out
}

// schemaDump is every object's name+sql, the whole shape of the database.
func schemaDump(t *testing.T, db *sql.DB) []string {
	t.Helper()
	rows, err := db.Query(`SELECT type||':'||name||':'||COALESCE(sql,'') FROM sqlite_master ORDER BY type,name`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			t.Fatal(err)
		}
		out = append(out, s)
	}
	return out
}

func backups(t *testing.T, dbPath string) []string {
	t.Helper()
	m, err := filepath.Glob(dbPath + ".pre-profiles-*.db")
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func captureLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	return &buf
}

func qaSeams(t *testing.T) {
	t.Helper()
	free, backup := profilesFreeBytes, profilesBackup
	t.Cleanup(func() { profilesFreeBytes, profilesBackup = free, backup })
}

// AC-002-22 / FR-232. On an old-schema database: every account has exactly one owner profile;
// per-account progress and watchlist counts and VALUES are identical; each row now belongs to
// the owner profile of its account; a full pre-migration copy exists, holds the old data, and
// the path is logged; the pre-migration tables are kept; a second run changes nothing.
// Red if: a row is dropped/changed, an account gets 0 or 2 owners, rows land on another
// account's owner, no copy is written, or the old tables are dropped.
func TestAC00222_MigrationOnOldSchemaDatabase(t *testing.T) {
	db, path := oldSchemaDB(t)
	logs := captureLog(t)

	if err := migrateProfiles(db, path); err != nil {
		t.Fatalf("migrateProfiles: %v", err)
	}

	// exactly one owner per account; carol and dave (watchlist-only / download-only) included.
	for _, u := range []string{"u_alice", "u_bob", "u_carol", "u_dave"} {
		var owners, total int
		if err := db.QueryRow(`SELECT COUNT(*) FROM profiles WHERE user_id=? AND is_owner=1`, u).Scan(&owners); err != nil {
			t.Fatal(err)
		}
		if err := db.QueryRow(`SELECT COUNT(*) FROM profiles WHERE user_id=?`, u).Scan(&total); err != nil {
			t.Fatal(err)
		}
		if owners != 1 || total != 1 {
			t.Errorf("%s: owners=%d total profiles=%d, want 1 and 1", u, owners, total)
		}
	}
	var accounts int
	_ = db.QueryRow(`SELECT COUNT(DISTINCT user_id) FROM profiles`).Scan(&accounts)
	if accounts != 4 {
		t.Errorf("profiles exist for %d accounts, want exactly the 4 that had data", accounts)
	}
	var level int
	var pin sql.NullString
	if err := db.QueryRow(`SELECT max_age_level, pin_hash FROM profiles WHERE user_id='u_alice'`).Scan(&level, &pin); err != nil {
		t.Fatal(err)
	}
	if level != 4 || pin.Valid {
		t.Errorf("migrated owner must be level 4 with no PIN (FR-204), got level=%d pin=%v", level, pin)
	}

	// values identical, per account
	if got := readProgress(t, db, "progress"); !reflect.DeepEqual(got, qaOldProgress) {
		t.Errorf("progress after migration:\n got %+v\nwant %+v", got, qaOldProgress)
	}
	if got := readWatchlist(t, db, "watchlist"); !reflect.DeepEqual(got, qaOldWatchlist) {
		t.Errorf("watchlist after migration:\n got %+v\nwant %+v", got, qaOldWatchlist)
	}
	// each row sits on the OWNER profile of its own account
	var misfiled int
	if err := db.QueryRow(`SELECT COUNT(*) FROM progress p LEFT JOIN profiles o ON o.id=p.profile_id
		WHERE o.id IS NULL OR o.user_id<>p.user_id OR o.is_owner<>1`).Scan(&misfiled); err != nil {
		t.Fatal(err)
	}
	if misfiled != 0 {
		t.Errorf("%d progress rows are not on their own account's owner profile", misfiled)
	}
	if err := db.QueryRow(`SELECT COUNT(*) FROM watchlist p LEFT JOIN profiles o ON o.id=p.profile_id
		WHERE o.id IS NULL OR o.user_id<>p.user_id OR o.is_owner<>1`).Scan(&misfiled); err != nil {
		t.Fatal(err)
	}
	if misfiled != 0 {
		t.Errorf("%d watchlist rows are not on their own account's owner profile", misfiled)
	}

	// the pre-migration tables are kept, with the original values
	if got := readProgress(t, db, "progress_pre_profiles"); !reflect.DeepEqual(got, qaOldProgress) {
		t.Errorf("progress_pre_profiles:\n got %+v\nwant %+v", got, qaOldProgress)
	}
	if got := readWatchlist(t, db, "watchlist_pre_profiles"); !reflect.DeepEqual(got, qaOldWatchlist) {
		t.Errorf("watchlist_pre_profiles:\n got %+v\nwant %+v", got, qaOldWatchlist)
	}

	// a full pre-migration copy exists, is a real old-schema database, and its path was logged
	bk := backups(t, path)
	if len(bk) != 1 {
		t.Fatalf("want exactly one pre-migration copy next to the database, found %v", bk)
	}
	if !strings.Contains(logs.String(), bk[0]) {
		t.Errorf("the copy's path %q was not logged:\n%s", bk[0], logs.String())
	}
	cp, err := sql.Open("sqlite", bk[0])
	if err != nil {
		t.Fatal(err)
	}
	defer cp.Close()
	if hasColumn(t, cp, "progress", "profile_id") {
		t.Errorf("the copy was taken AFTER the schema change (has profile_id)")
	}
	if got := readProgress(t, cp, "progress"); !reflect.DeepEqual(got, qaOldProgress) {
		t.Errorf("copy progress:\n got %+v\nwant %+v", got, qaOldProgress)
	}
	if got := readWatchlist(t, cp, "watchlist"); !reflect.DeepEqual(got, qaOldWatchlist) {
		t.Errorf("copy watchlist:\n got %+v\nwant %+v", got, qaOldWatchlist)
	}
	var items, dl int
	_ = cp.QueryRow(`SELECT COUNT(*) FROM items`).Scan(&items)
	_ = cp.QueryRow(`SELECT COUNT(*) FROM downloads`).Scan(&dl)
	if items != 3 || dl != 1 {
		t.Errorf("copy is not a full database copy: items=%d downloads=%d, want 3 and 1", items, dl)
	}

	// idempotent: a second run (every restart) adds no copy, no profile, no row
	before := schemaDump(t, db)
	if err := migrateProfiles(db, path); err != nil {
		t.Fatalf("second migrateProfiles: %v", err)
	}
	if n := len(backups(t, path)); n != 1 {
		t.Errorf("second run wrote another copy: %d copies", n)
	}
	var profs int
	_ = db.QueryRow(`SELECT COUNT(*) FROM profiles`).Scan(&profs)
	if profs != 4 {
		t.Errorf("second run changed the profile count to %d", profs)
	}
	if got := readProgress(t, db, "progress"); !reflect.DeepEqual(got, qaOldProgress) {
		t.Errorf("progress changed by the second run: %+v", got)
	}
	if !reflect.DeepEqual(before, schemaDump(t, db)) {
		t.Errorf("schema changed by the second run")
	}
}

// AC-002-22 through the product: after migration the OLD positions are served to their
// owner by the real handlers, with and without the profile header, and bob never sees alice's.
func TestAC00222_MigratedPositionsAreServedToTheirOwner(t *testing.T) {
	db, path := oldSchemaDB(t)
	if err := migrateProfiles(db, path); err != nil {
		t.Fatal(err)
	}
	s := &Server{db: db, cfg: Config{DBPath: path, JWTSecret: "qa-profiles-secret-qa-profiles-secret"}}
	s.justAdded = newJustAddedCache()
	r := chi.NewRouter()
	registerAPIRoutes(r, s)
	e := &qaEnv{t: t, s: s, db: db, dbPath: path, h: r}

	aliceOwner := e.ownerID(qaAlice)
	for _, h := range []string{"", aliceOwner} {
		p := e.do(qaAlice, "GET", "/progress/all", "", h)
		prog, _ := p.js["progress"].(map[string]any)
		if len(prog) != 3 {
			t.Errorf("header %q: alice sees %d migrated positions, want 3: %s", h, len(prog), p.raw)
		}
		if m, _ := prog["m2"].(map[string]any); m == nil || m["positionSeconds"] != float64(3000) || m["durationSeconds"] != float64(5400) {
			t.Errorf("header %q: m2 = %v, want 3000/5400", h, prog["m2"])
		}
		w := e.do(qaAlice, "GET", "/watchlist", "", h)
		items, _ := w.js["items"].([]any)
		if len(items) != 2 {
			t.Errorf("header %q: alice's migrated watchlist has %d items, want 2: %s", h, len(items), w.raw)
		}
	}
	bob := e.do(qaBob, "GET", "/progress/all", "", "")
	if prog, _ := bob.js["progress"].(map[string]any); len(prog) != 1 || prog["m1"] == nil {
		t.Errorf("bob should hold only his own m1 position: %s", bob.raw)
	}
	if prog, _ := bob.js["progress"].(map[string]any); prog["m1"] != nil {
		if m := prog["m1"].(map[string]any); m["positionSeconds"] != float64(45) {
			t.Errorf("bob's m1 = %v, want 45 (not alice's 120)", m)
		}
	}
	carol := e.do(qa("u_carol", "carol"), "GET", "/watchlist", "", "")
	if items, _ := carol.js["items"].([]any); len(items) != 1 {
		t.Errorf("carol's migrated watchlist: %s", carol.raw)
	}
}

func qa(id, name string) qaUser { return qaUser{id, name} }

func after(sec int) <-chan time.Time { return time.After(time.Duration(sec) * time.Second) }

// AC-002-23 via the seams. A copy that cannot be written (any cause) leaves the database
// byte-for-byte schema-and-data identical, runs no migration, and the error names the cause.
// Red if the migration proceeds without a copy, or the failure is swallowed, or half the
// schema change is left behind.
func TestAC00223_BackupFailureViaSeamsLeavesDatabaseUntouched(t *testing.T) {
	cases := []struct {
		name  string
		arm   func()
		wants []string
	}{
		{
			name: "backup writer fails",
			arm: func() {
				profilesBackup = func(*sql.DB, string) (string, error) {
					return "", errors.New("simulated: no space left on device")
				}
			},
			wants: []string{"migration not run", "no space left on device"},
		},
		{
			name: "not enough free space (real backup code, tiny free space)",
			arm: func() {
				profilesFreeBytes = func(string) (uint64, error) { return 3 << 20, nil }
			},
			wants: []string{"migration not run", "MB free", "3 MB available"},
		},
		{
			name: "free space cannot be measured",
			arm: func() {
				profilesFreeBytes = func(string) (uint64, error) { return 0, errors.New("statfs: input/output error") }
			},
			wants: []string{"migration not run", "free space", "input/output error"},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			qaSeams(t)
			db, path := oldSchemaDB(t)
			before := schemaDump(t, db)
			c.arm()
			err := migrateProfiles(db, path)
			if err == nil {
				t.Fatalf("migration reported success although the copy could not be written")
			}
			for _, w := range c.wants {
				if !strings.Contains(err.Error(), w) {
					t.Errorf("error %q does not contain %q", err, w)
				}
			}
			if !reflect.DeepEqual(before, schemaDump(t, db)) {
				t.Errorf("schema changed despite refusing to migrate:\nbefore %v\nafter  %v", before, schemaDump(t, db))
			}
			if hasColumn(t, db, "progress", "profile_id") {
				t.Errorf("progress was migrated without a copy")
			}
			if got := readProgress(t, db, "progress"); !reflect.DeepEqual(got, qaOldProgress) {
				t.Errorf("progress data changed: %+v", got)
			}
			if got := readWatchlist(t, db, "watchlist"); !reflect.DeepEqual(got, qaOldWatchlist) {
				t.Errorf("watchlist data changed: %+v", got)
			}
			if n := len(backups(t, path)); n != 0 {
				t.Errorf("a partial copy was left behind: %v", backups(t, path))
			}
		})
	}
}

// AC-002-23 naturally: VACUUM INTO cannot write the copy. No seam is replaced. The preferred
// injection is a read-only (0555) database folder; where that cannot bite (running as root, or
// a filesystem that ignores directory modes) the copy's file name is already taken, which the
// same backup step refuses. Either way the test RUNS: it never skips. The error must name the
// cause, and nothing may change.
// Red if: backupBeforeProfiles stops probing the folder / stops refusing an existing copy, or
// migrateProfiles proceeds after a failed copy.
func TestAC00223_BackupFailureNaturalReadOnlyDirectory(t *testing.T) {
	db, path := oldSchemaDB(t)
	before := schemaDump(t, db)
	inj := forceNaturalBackupFailure(t, path, 30*time.Second)
	t.Logf("injection: %s", inj.how)

	err := migrateProfiles(db, path)
	if err == nil {
		t.Fatalf("migration succeeded although the pre-migration copy could not be written (%s)", inj.how)
	}
	t.Logf("natural failure message: %v", err)
	for _, w := range append([]string{"migration not run", "pre-migration copy"}, inj.wantInErr...) {
		if !strings.Contains(err.Error(), w) {
			t.Errorf("error %q does not contain %q", err, w)
		}
	}
	if !reflect.DeepEqual(before, schemaDump(t, db)) {
		t.Errorf("schema changed despite the failed copy")
	}
	if got := readProgress(t, db, "progress"); !reflect.DeepEqual(got, qaOldProgress) {
		t.Errorf("progress data changed: %+v", got)
	}
	if got := readWatchlist(t, db, "watchlist"); !reflect.DeepEqual(got, qaOldWatchlist) {
		t.Errorf("watchlist data changed: %+v", got)
	}
}

// AC-002-23 end to end: the real binary, started against an old-schema database whose copy
// cannot be written, must exit non-zero with a log line naming the cause, and leave the
// database unmigrated. Runs as root and under -short too (no skip): the injection falls back
// to an occupied copy name where a 0555 folder cannot bite.
// Red if main() ignores migrateProfiles' error.
func TestAC00223_ServerExitsAtStartupWhenCopyCannotBeWritten(t *testing.T) {
	bin := buildBackendBinary(t)

	db, path := oldSchemaDB(t) // keep this connection open so the -wal/-shm files persist in the 0555 dir
	before := schemaDump(t, db)
	inj := forceNaturalBackupFailure(t, path, 90*time.Second)
	t.Logf("injection: %s", inj.how)

	code, out := runBackendUntilExit(t, bin, path, 20)
	if code == 0 {
		t.Errorf("server exited 0, want a non-zero exit\n%s", out)
	}
	for _, w := range append([]string{"migration not run", "pre-migration copy"}, inj.wantInErr...) {
		if !strings.Contains(out, w) {
			t.Errorf("startup log does not contain %q:\n%s", w, out)
		}
	}
	if !reflect.DeepEqual(before, schemaDump(t, db)) {
		t.Errorf("database was changed by the failed startup")
	}
}

// AC-002-22 envelope item 2: if the copy succeeded but the migration itself fails, everything
// rolls back and the old tables stay authoritative. Forced with a pre-existing, incompatible
// `profiles` table.
func TestAC00222_FailedMigrationRollsBackCompletely(t *testing.T) {
	db, path := oldSchemaDB(t)
	if _, err := db.Exec(`CREATE TABLE profiles(unrelated TEXT)`); err != nil {
		t.Fatal(err)
	}
	before := schemaDump(t, db)
	err := migrateProfiles(db, path)
	if err == nil {
		t.Fatalf("migration over an incompatible profiles table reported success")
	}
	if !strings.Contains(err.Error(), "rolled back") {
		t.Errorf("error should say it rolled back and where the copy is: %v", err)
	}
	if !reflect.DeepEqual(before, schemaDump(t, db)) {
		t.Errorf("schema not restored after rollback:\nbefore %v\nafter  %v", before, schemaDump(t, db))
	}
	if hasColumn(t, db, "progress", "profile_id") {
		t.Errorf("progress half-migrated after rollback")
	}
	if got := readProgress(t, db, "progress"); !reflect.DeepEqual(got, qaOldProgress) {
		t.Errorf("progress changed: %+v", got)
	}
	if got := readWatchlist(t, db, "watchlist"); !reflect.DeepEqual(got, qaOldWatchlist) {
		t.Errorf("watchlist changed: %+v", got)
	}
	if n := len(backups(t, path)); n != 1 {
		t.Errorf("the pre-migration copy must exist for a failed migration, found %d", n)
	}
}

// AC-002-27 / FR-206. Deleting profile B removes exactly B's progress and watchlist rows.
// The owner's and a third profile's rows, the account's download marks, the library items
// and the media files are unchanged (count delta + target identity + survivor identity).
// Red if the DELETE is not scoped by profile_id (would also take A/C rows) or reaches
// downloads/items/files.
func TestAC00227_DeletingAProfileRemovesOnlyItsRows(t *testing.T) {
	e := newQAEnv(t)
	owner := e.setOwnerPin(qaAlice, "0420")
	b := e.mustCreate(qaAlice, "0420", "Bee", 4, nil)
	c := e.mustCreate(qaAlice, "0420", "Cee", 4, nil)
	bobOwner := e.ownerID(qaBob)

	media := filepath.Join(t.TempDir(), "movie.mkv")
	if err := os.WriteFile(media, []byte("not really a video"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"i1", "i2", "i3"} {
		e.seedItem(id, "Drama", sp("PG"))
	}
	if _, err := e.db.Exec(`UPDATE items SET path=? WHERE id='i1'`, media); err != nil {
		t.Fatal(err)
	}
	if _, err := e.db.Exec(`INSERT INTO downloads(item_id,user_id,marked_at) VALUES('i1','u_alice','2026-07-01T00:00:00Z'),('i2','u_alice','2026-07-02T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}

	prog := func(who qaUser, item, profile string, pos int) {
		wantOK(t, e.do(who, "POST", "/items/"+item+"/progress", jb(map[string]any{"positionSeconds": pos, "durationSeconds": 1000}), profile), 200)
	}
	watch := func(who qaUser, item, profile string) {
		wantOK(t, e.do(who, "POST", "/watchlist/"+item, "", profile), 200)
	}
	prog(qaAlice, "i1", owner, 11)
	prog(qaAlice, "i2", owner, 12)
	prog(qaAlice, "i1", b, 21)
	prog(qaAlice, "i2", b, 22)
	prog(qaAlice, "i3", b, 23)
	prog(qaAlice, "i1", c, 31)
	prog(qaBob, "i1", bobOwner, 41)
	watch(qaAlice, "i1", owner)
	watch(qaAlice, "i1", b)
	watch(qaAlice, "i2", b)
	watch(qaAlice, "i2", c)
	watch(qaBob, "i3", bobOwner)

	count := func(table, profile string) int {
		return e.count(`SELECT COUNT(*) FROM `+table+` WHERE profile_id=?`, profile)
	}
	if count("progress", b) != 3 || count("watchlist", b) != 2 {
		t.Fatalf("precondition: B should hold 3 progress + 2 watchlist rows, has %d + %d", count("progress", b), count("watchlist", b))
	}
	totalProgress, totalWatch := e.count(`SELECT COUNT(*) FROM progress`), e.count(`SELECT COUNT(*) FROM watchlist`)
	if totalProgress != 7 || totalWatch != 5 {
		t.Fatalf("precondition: totals %d/%d, want 7/5", totalProgress, totalWatch)
	}
	snapshot := func() string {
		rows, err := e.db.Query(`SELECT profile_id||'|'||item_id||'|'||position_seconds FROM progress WHERE profile_id<>? ORDER BY 1`, b)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var parts []string
		for rows.Next() {
			var s string
			_ = rows.Scan(&s)
			parts = append(parts, s)
		}
		w, _ := e.db.Query(`SELECT profile_id||'|'||item_id||'|'||added_at FROM watchlist WHERE profile_id<>? ORDER BY 1`, b)
		defer w.Close()
		for w.Next() {
			var s string
			_ = w.Scan(&s)
			parts = append(parts, "w:"+s)
		}
		return fmt.Sprint(parts)
	}
	survivorsBefore := snapshot()

	wantOK(t, e.do(qaAlice, "DELETE", "/profiles/"+b, jb(map[string]any{"ownerPin": "0420"}), ""), 200)

	if count("progress", b) != 0 || count("watchlist", b) != 0 {
		t.Errorf("B's rows survive deletion: progress=%d watchlist=%d", count("progress", b), count("watchlist", b))
	}
	if e.count(`SELECT COUNT(*) FROM profiles WHERE id=?`, b) != 0 {
		t.Errorf("B's profile row survives")
	}
	if got := e.count(`SELECT COUNT(*) FROM progress`); got != totalProgress-3 {
		t.Errorf("progress total %d, want %d (only B's 3 rows gone)", got, totalProgress-3)
	}
	if got := e.count(`SELECT COUNT(*) FROM watchlist`); got != totalWatch-2 {
		t.Errorf("watchlist total %d, want %d (only B's 2 rows gone)", got, totalWatch-2)
	}
	if survivorsBefore != snapshot() {
		t.Errorf("surviving rows changed:\nbefore %s\nafter  %s", survivorsBefore, snapshot())
	}
	if count("progress", owner) != 2 || count("progress", c) != 1 || count("watchlist", owner) != 1 || count("watchlist", c) != 1 {
		t.Errorf("owner/C rows: owner %d/%d, C %d/%d, want 2/1 and 1/1",
			count("progress", owner), count("watchlist", owner), count("progress", c), count("watchlist", c))
	}
	if got := e.count(`SELECT COUNT(*) FROM downloads WHERE user_id='u_alice'`); got != 2 {
		t.Errorf("download marks changed: %d, want 2", got)
	}
	if got := e.count(`SELECT COUNT(*) FROM items`); got != 3 {
		t.Errorf("items changed: %d, want 3", got)
	}
	if b, err := os.ReadFile(media); err != nil || string(b) != "not really a video" {
		t.Errorf("media file touched: %v %q", err, b)
	}
	// The deleted id is gone for real: header with it is now refused, and nothing re-created it.
	wantErr(t, e.do(qaAlice, "GET", "/libraries", "", b), 403, "unknown_profile")
	// A new profile with B's name starts empty (no resurrected rows).
	b2 := e.mustCreate(qaAlice, "0420", "Bee", 4, nil)
	if count("progress", b2) != 0 || count("watchlist", b2) != 0 || b2 == b {
		t.Errorf("recreated Bee id=%s (old %s) inherited rows: %d/%d", b2, b, count("progress", b2), count("watchlist", b2))
	}
}
