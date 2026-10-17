package main

// FRD-002 profiles: which profile a request is for (§4), the /profiles API (§2, §3,
// docs/api/ProfilesAPI.md), and the ceiling helpers the enforcement work (part B) builds on.
// Schema and migration live in profiles_migrate.go; PIN hashing and the limiter in
// profiles_pin.go. The age ladder itself lives only in internal/rating (ADR-001).

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"dsvideo/backend/internal/rating"

	"github.com/go-chi/chi/v5"
)

const (
	maxProfilesPerAccount = 4 // FR-200, the owner included
	profileHeader         = "X-DSVideo-Profile"
	maxAvatarLen          = 32
)

const viewerKey ctxKey = 2

var errUnknownProfile = errors.New("unknown_profile")

// viewer is the profile a request is served for.
type viewer struct {
	UserID      string
	ProfileID   string
	MaxAgeLevel int
	IsOwner     bool
}

// VisibleClause is the WHERE fragment (and args) that keeps only titles this viewer may see;
// ("", nil) when the profile is unrestricted.
func (v viewer) VisibleClause(col string) (string, []any) {
	return rating.Visible(col, v.MaxAgeLevel)
}

func viewerFromCtx(ctx context.Context) (viewer, bool) {
	v, ok := ctx.Value(viewerKey).(viewer)
	return v, ok
}

// profileState is the Server's profile bookkeeping. Its zero value is ready to use, so tests
// that build &Server{} directly need no setup.
type profileState struct {
	// mu serializes profile mutations (create, edit, delete, owner reset) so the 4-profile
	// limit, name uniqueness and owner rules are checked and applied atomically.
	mu      sync.Mutex
	once    sync.Once
	limiter *pinLimiter
}

func (s *Server) pinLimiter() *pinLimiter {
	s.profiles.once.Do(func() { s.profiles.limiter = newPinLimiter(time.Now) })
	return s.profiles.limiter
}

// dsmAuth is the one entry point for checking a DSM password. dsmAuthOverride exists so
// tests can exercise login and the owner-PIN reset without a NAS.
func (s *Server) dsmAuth(ctx context.Context, username, password, otp, did string) (*dsmUserInfo, error) {
	if s.dsmAuthOverride != nil {
		return s.dsmAuthOverride(ctx, username, password, otp, did)
	}
	return s.authenticateDSM(ctx, username, password, otp, did)
}

// ── Rows ────────────────────────────────────────────────────────────────────────────────

type profileRow struct {
	ID          string
	UserID      string
	Name        string
	Avatar      string
	MaxAgeLevel int
	PinHash     sql.NullString
	IsOwner     bool
	CreatedAt   string
}

func (p profileRow) viewer() viewer {
	return viewer{UserID: p.UserID, ProfileID: p.ID, MaxAgeLevel: p.MaxAgeLevel, IsOwner: p.IsOwner}
}

func (p profileRow) hasPin() bool { return p.PinHash.Valid && p.PinHash.String != "" }

type profileJSON struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Avatar      string `json:"avatar"`
	MaxAgeLevel int    `json:"maxAgeLevel"`
	HasPin      bool   `json:"hasPin"`
	IsOwner     bool   `json:"isOwner"`
	CreatedAt   string `json:"createdAt"`
}

func (p profileRow) json() profileJSON {
	return profileJSON{ID: p.ID, Name: p.Name, Avatar: p.Avatar, MaxAgeLevel: p.MaxAgeLevel,
		HasPin: p.hasPin(), IsOwner: p.IsOwner, CreatedAt: p.CreatedAt}
}

// loadProfiles returns the account's profiles (at most 4), oldest first.
func (s *Server) loadProfiles(ctx context.Context, userID string) ([]profileRow, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, user_id, name, avatar, max_age_level, pin_hash, is_owner, created_at
		 FROM profiles WHERE user_id = ? ORDER BY created_at, rowid`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []profileRow
	for rows.Next() {
		var p profileRow
		var owner int
		if err := rows.Scan(&p.ID, &p.UserID, &p.Name, &p.Avatar, &p.MaxAgeLevel, &p.PinHash, &owner, &p.CreatedAt); err != nil {
			return nil, err
		}
		p.IsOwner = owner == 1
		out = append(out, p)
	}
	return out, rows.Err()
}

func ownerOf(rows []profileRow) (profileRow, bool) {
	for _, p := range rows {
		if p.IsOwner {
			return p, true
		}
	}
	return profileRow{}, false
}

func findProfile(rows []profileRow, id string) (profileRow, bool) {
	if id == "" {
		return profileRow{}, false
	}
	for _, p := range rows {
		if p.ID == id {
			return p, true
		}
	}
	return profileRow{}, false
}

// pickDefault is FR-221 over rows already ordered by (created_at, rowid): the lowest
// restricted ceiling, earliest-created on ties; otherwise the owner.
func pickDefault(rows []profileRow) (profileRow, bool) {
	best := -1
	for i, p := range rows {
		if rating.Restricted(p.MaxAgeLevel) && (best < 0 || p.MaxAgeLevel < rows[best].MaxAgeLevel) {
			best = i
		}
	}
	if best >= 0 {
		return rows[best], true
	}
	return ownerOf(rows)
}

// ensureOwnerProfile creates the account's owner profile if it has none (FR-204): at sign-in
// for new accounts, and lazily for tokens issued before the upgrade. Concurrent callers are
// safe: the partial unique index allows one owner per account and INSERT OR IGNORE lets the
// loser fall through.
func (s *Server) ensureOwnerProfile(ctx context.Context, userID, displayName string) error {
	if userID == "" {
		return errors.New("ensureOwnerProfile: empty user id")
	}
	var have int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM profiles WHERE user_id = ? AND is_owner = 1`, userID).Scan(&have); err != nil {
		return err
	}
	if have > 0 {
		return nil
	}
	existing, err := s.loadProfiles(ctx, userID)
	if err != nil {
		return err
	}
	name := uniqueProfileName(defaultOwnerName(displayName, userID), existing)
	id, err := newProfileID()
	if err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx,
		`INSERT OR IGNORE INTO profiles(id, user_id, name, avatar, max_age_level, pin_hash, is_owner, created_at)
		 VALUES(?, ?, ?, '', ?, NULL, 1, ?)`,
		id, userID, name, rating.MaxLevel, time.Now().UTC().Format(time.RFC3339)); err != nil {
		return err
	}
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM profiles WHERE user_id = ? AND is_owner = 1`, userID).Scan(&have); err != nil {
		return err
	}
	if have == 0 {
		return fmt.Errorf("ensureOwnerProfile: owner profile for %s was not created", userID)
	}
	return nil
}

// adoptOwnerDisplayName gives a migrated owner profile the DSM display name at sign-in
// (FR-204). The migration ran without a DSM session, so the owner may carry the user-id
// fallback name (defaultOwnerName("", userID)); only a profile still holding exactly that
// name is renamed, so a name the owner chose is never overwritten.
func (s *Server) adoptOwnerDisplayName(ctx context.Context, userID, displayName string) error {
	fallback := defaultOwnerName("", userID)
	want := defaultOwnerName(displayName, userID)
	if want == fallback {
		return nil
	}
	s.profiles.mu.Lock()
	defer s.profiles.mu.Unlock()
	rows, err := s.loadProfiles(ctx, userID)
	if err != nil {
		return err
	}
	owner, ok := ownerOf(rows)
	if !ok || owner.Name != fallback {
		return nil
	}
	others := make([]profileRow, 0, len(rows))
	for _, p := range rows {
		if p.ID != owner.ID {
			others = append(others, p)
		}
	}
	_, err = s.db.ExecContext(ctx, `UPDATE profiles SET name = ? WHERE id = ? AND name = ?`,
		uniqueProfileName(want, others), owner.ID, fallback)
	return err
}

// uniqueProfileName returns base, or base with " 2", " 3", … appended (base shortened to keep
// the 20-rune limit) when another profile in the account already uses it in any letter case.
func uniqueProfileName(base string, existing []profileRow) string {
	taken := func(n string) bool {
		for _, p := range existing {
			if strings.EqualFold(p.Name, n) {
				return true
			}
		}
		return false
	}
	if !taken(base) {
		return base
	}
	for i := 2; ; i++ {
		suffix := fmt.Sprintf(" %d", i)
		cand := strings.TrimSpace(truncateRunes(base, maxProfileNameRunes-len(suffix))) + suffix
		if !taken(cand) {
			return cand
		}
	}
}

// accountProfiles loads the account's profiles, creating the owner profile first if the
// account has none. Steady state is one query.
func (s *Server) accountProfiles(ctx context.Context, u authedUser) ([]profileRow, error) {
	rows, err := s.loadProfiles(ctx, u.ID)
	if err != nil {
		return nil, err
	}
	if _, ok := ownerOf(rows); ok {
		return rows, nil
	}
	if err := s.ensureOwnerProfile(ctx, u.ID, u.Username); err != nil {
		return nil, err
	}
	return s.loadProfiles(ctx, u.ID)
}

// defaultViewer is FR-221 for an account: the most restricted profile if any, else the owner.
func (s *Server) defaultViewer(ctx context.Context, userID string) (viewer, error) {
	rows, err := s.accountProfiles(ctx, authedUser{ID: userID})
	if err != nil {
		return viewer{}, err
	}
	p, ok := pickDefault(rows)
	if !ok {
		return viewer{}, fmt.Errorf("account %s has no owner profile", userID)
	}
	return p.viewer(), nil
}

// resolveViewer is FR-220/221: the named profile if it belongs to u's account, the FR-221
// default when header is empty, errUnknownProfile otherwise (another account's id and a
// deleted id are indistinguishable).
func (s *Server) resolveViewer(ctx context.Context, u authedUser, header string) (viewer, error) {
	rows, err := s.accountProfiles(ctx, u)
	if err != nil {
		return viewer{}, err
	}
	return resolveFromRows(rows, header, true)
}

func resolveFromRows(rows []profileRow, header string, strict bool) (viewer, error) {
	if header != "" {
		if p, ok := findProfile(rows, header); ok {
			return p.viewer(), nil
		}
		if strict {
			return viewer{}, errUnknownProfile
		}
	}
	p, ok := pickDefault(rows)
	if !ok {
		return viewer{}, errors.New("account has no owner profile")
	}
	return p.viewer(), nil
}

// profileResolver runs after authMiddleware. It puts the viewer in the request context and
// names it in the X-DSVideo-Profile response header (FR-222) before the handler runs.
// strict=false is only for the /profiles subtree: an unknown or deleted id falls back to
// FR-221 so a device holding a stale id can still load the picker.
func (s *Server) profileResolver(strict bool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			u := userFromCtx(r.Context())
			if u.ID == "" {
				writeErr(w, http.StatusUnauthorized, "missing_token")
				return
			}
			rows, err := s.accountProfiles(r.Context(), u)
			if err != nil {
				log.Printf("profile resolve: %v", err)
				writeErr(w, http.StatusInternalServerError, "db_error")
				return
			}
			v, err := resolveFromRows(rows, strings.TrimSpace(r.Header.Get(profileHeader)), strict)
			if errors.Is(err, errUnknownProfile) {
				writeErr(w, http.StatusForbidden, "unknown_profile")
				return
			}
			if err != nil {
				log.Printf("profile resolve: %v", err)
				writeErr(w, http.StatusInternalServerError, "db_error")
				return
			}
			w.Header().Set(profileHeader, v.ProfileID)
			next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), viewerKey, v)))
		})
	}
}

// viewerFor is how a handler learns its viewer: the resolver's answer when it ran, else the
// FR-221 default (routes outside the resolver, e.g. the WebAPI layer, which cannot send the
// header, FR-251).
func (s *Server) viewerFor(r *http.Request) (viewer, error) {
	if v, ok := viewerFromCtx(r.Context()); ok {
		return v, nil
	}
	u := userFromCtx(r.Context())
	if u.ID == "" {
		return viewer{}, errors.New("viewerFor: no authenticated user")
	}
	return s.defaultViewer(r.Context(), u.ID)
}

// requestViewer is viewerFor for handlers: on failure it answers 500 db_error (the cause is
// a profiles lookup) and returns false so the handler just returns.
func (s *Server) requestViewer(w http.ResponseWriter, r *http.Request) (viewer, bool) {
	v, err := s.viewerFor(r)
	if err != nil {
		log.Printf("viewer: %v", err)
		writeErr(w, http.StatusInternalServerError, "db_error")
		return viewer{}, false
	}
	return v, true
}

// ── Ceiling helpers for the enforcement work (FR-250) ───────────────────────────────────

// itemAboveCeiling reports whether itemID's age level is above v's ceiling. A missing item
// is (false, nil) so the caller's own not-found path answers.
func (s *Server) itemAboveCeiling(ctx context.Context, v viewer, itemID string) (bool, error) {
	if !rating.Restricted(v.MaxAgeLevel) {
		return false, nil
	}
	var cert sql.NullString
	err := s.db.QueryRowContext(ctx, `SELECT content_rating FROM items WHERE id = ?`, itemID).Scan(&cert)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return v.above(cert), nil
}

// above reports whether a title with stored certification cert is above v's ceiling. For
// handlers that already selected content_rating, so the gate costs no extra query.
func (v viewer) above(cert sql.NullString) bool {
	if !rating.Restricted(v.MaxAgeLevel) {
		return false
	}
	var p *string
	if cert.Valid {
		p = &cert.String
	}
	return rating.LevelPtr(p) > v.MaxAgeLevel
}

// andVisible appends v's ceiling on column col to where, which is "" or starts with "WHERE".
// Unrestricted viewers get where and args back unchanged. Listings apply FR-250 through
// this (or VisibleClause) so the unrated rule stays in package rating.
func (v viewer) andVisible(where string, args []any, col string) (string, []any) {
	clause, cargs := v.VisibleClause(col)
	if clause == "" {
		return where, args
	}
	if strings.TrimSpace(where) == "" {
		return "WHERE " + clause, append(args, cargs...)
	}
	return where + " AND " + clause, append(args, cargs...)
}

// andVisibleFrag is andVisible for queries that already have a WHERE: it returns
// " AND <clause>" (or "") and the args to append.
func (v viewer) andVisibleFrag(col string) (string, []any) {
	clause, cargs := v.VisibleClause(col)
	if clause == "" {
		return "", nil
	}
	return " AND " + clause, cargs
}

// visibleItemFrag is " AND EXISTS (…)" keeping only rows whose itemCol names a title v may
// see, for tables (progress) that are read without joining items. A row whose item is gone
// has no level and is hidden (unknown fails closed, FR-242). Unrestricted viewers get "",
// so their reads, orphan rows included, are exactly as before. itemCol is spliced into SQL
// and must be a programmer-written identifier.
func (v viewer) visibleItemFrag(itemCol string) (string, []any) {
	if !sqlIdentRe.MatchString(itemCol) {
		panic("visibleItemFrag: column is not a plain identifier: " + itemCol)
	}
	clause, cargs := v.VisibleClause("vis_i.content_rating")
	if clause == "" {
		return "", nil
	}
	return " AND EXISTS (SELECT 1 FROM items vis_i WHERE vis_i.id = " + itemCol + " AND " + clause + ")", cargs
}

var sqlIdentRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?$`)

// refuseAboveCeiling is the "refused if above" gate (FR-250) for a single title: it answers
// 403 content_restricted (or 500 db_error) and returns false when the handler must stop. A
// missing item passes, so the handler's own not-found answer is unchanged.
func (s *Server) refuseAboveCeiling(w http.ResponseWriter, r *http.Request, v viewer, itemID string) bool {
	above, err := s.itemAboveCeiling(r.Context(), v, itemID)
	if err != nil {
		log.Printf("ceiling check %s: %v", itemID, err)
		writeErr(w, http.StatusInternalServerError, "db_error")
		return false
	}
	if above {
		writeContentRestricted(w)
		return false
	}
	return true
}

// gateShow is "refused if above" for a whole show (FR-250: a show is visible iff its rating
// is; the content-rating backfill writes the show's certification onto every episode row).
// where/args select the show's rows (no leading WHERE). If the show has rows and the viewer
// may see none of them it answers 403 content_restricted and returns ok=false. Otherwise it
// returns the " AND …" fragment and args that keep the handler's episode queries to visible
// rows (empty for an unrestricted viewer, who pays no extra query).
func (s *Server) gateShow(w http.ResponseWriter, r *http.Request, v viewer, where string, args []any) (frag string, fargs []any, ok bool) {
	clause, cargs := v.VisibleClause("content_rating")
	if clause == "" {
		return "", nil, true
	}
	var total, visible int
	qargs := append(append([]any{}, cargs...), args...)
	if err := s.db.QueryRowContext(r.Context(),
		"SELECT COUNT(*), COALESCE(SUM(CASE WHEN "+clause+" THEN 1 ELSE 0 END), 0) FROM items WHERE "+where,
		qargs...).Scan(&total, &visible); err != nil {
		log.Printf("show ceiling check: %v", err)
		writeErr(w, http.StatusInternalServerError, "db_error")
		return "", nil, false
	}
	if total > 0 && visible == 0 {
		writeContentRestricted(w)
		return "", nil, false
	}
	return " AND " + clause, cargs, true
}

// writeContentRestricted is the "refused above the ceiling" answer (FR-250): it names the
// real cause, never a not-found that blames the library.
func writeContentRestricted(w http.ResponseWriter) {
	writeErr(w, http.StatusForbidden, "content_restricted")
}

// requireUnrestricted refuses restricted profiles with 403 profile_restricted (metadata fixes
// and /admin/*, FR-250).
func (s *Server) requireUnrestricted(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		v, err := s.viewerFor(r)
		if err != nil {
			log.Printf("requireUnrestricted: %v", err)
			writeErr(w, http.StatusInternalServerError, "db_error")
			return
		}
		if rating.Restricted(v.MaxAgeLevel) {
			writeErr(w, http.StatusForbidden, "profile_restricted")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// upsertProgress is the one progress write. The write_seq guard is the same as the
// pre-profiles statement (see handleProgress): a lower or equal write_seq never overwrites.
// The caller allocates writeSeq and holds s.progressMu, as today.
func (s *Server) upsertProgress(v viewer, itemID string, pos, dur int, updatedAt string, writeSeq int64) (sql.Result, error) {
	return s.db.Exec(
		"INSERT INTO progress(item_id, user_id, profile_id, position_seconds, duration_seconds, updated_at, write_seq) VALUES(?,?,?,?,?,?,?) "+
			"ON CONFLICT(item_id, profile_id) DO UPDATE SET "+
			"position_seconds=excluded.position_seconds, "+
			"duration_seconds=excluded.duration_seconds, "+
			"updated_at=excluded.updated_at, "+
			"write_seq=excluded.write_seq "+
			"WHERE excluded.write_seq > progress.write_seq",
		itemID, v.UserID, v.ProfileID, pos, dur, updatedAt, writeSeq,
	)
}

// ── Routes ──────────────────────────────────────────────────────────────────────────────

// registerProfileRoutes mounts /profiles* on an authenticated router, behind the lenient
// resolver (see profileResolver).
func registerProfileRoutes(r chi.Router, s *Server) {
	r.Group(func(r chi.Router) {
		r.Use(s.profileResolver(false))
		r.Get("/profiles", s.handleProfilesList)
		r.Post("/profiles", s.handleProfileCreate)
		r.Get("/profiles/age-levels", s.handleProfileAgeLevels)
		r.Post("/profiles/owner/pin/reset", s.handleOwnerPinReset)
		r.Patch("/profiles/{id}", s.handleProfileUpdate)
		r.Delete("/profiles/{id}", s.handleProfileDelete)
		r.Post("/profiles/{id}/pin/verify", s.handleProfilePinVerify)
	})
}

// ── Body parsing ────────────────────────────────────────────────────────────────────────

// profileBody keeps raw values so "absent" and "null" stay distinguishable (PATCH "pin": null
// clears a PIN; an absent "pin" leaves it alone).
type profileBody map[string]json.RawMessage

func decodeProfileBody(r *http.Request) (profileBody, bool) {
	b := profileBody{}
	data, err := io.ReadAll(r.Body)
	if err != nil {
		return nil, false
	}
	if len(strings.TrimSpace(string(data))) == 0 {
		return b, true // DELETE with no body: treated as no fields, so ownerPin is "absent"
	}
	if err := json.Unmarshal(data, &b); err != nil {
		return nil, false
	}
	return b, true
}

// field reports whether key is present and whether it is JSON null.
func (b profileBody) field(key string) (raw json.RawMessage, present, isNull bool) {
	raw, present = b[key]
	if !present {
		return nil, false, false
	}
	return raw, true, strings.TrimSpace(string(raw)) == "null"
}

// stringField decodes a present, non-null string value.
func (b profileBody) stringField(key string) (string, bool) {
	raw, present, isNull := b.field(key)
	if !present || isNull {
		return "", false
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", false
	}
	return s, true
}

func validProfileName(raw string) (string, bool) {
	name := strings.TrimSpace(raw)
	n := utf8.RuneCountInString(name)
	return name, utf8.ValidString(name) && n >= 1 && n <= maxProfileNameRunes
}

func validAvatar(a string) bool {
	if len(a) < 1 || len(a) > maxAvatarLen {
		return false
	}
	for i := 0; i < len(a); i++ {
		c := a[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

func nameTaken(rows []profileRow, name, exceptID string) bool {
	for _, p := range rows {
		if p.ID != exceptID && strings.EqualFold(p.Name, name) {
			return true
		}
	}
	return false
}

// profileFields is the validated, optional editable fields of a POST/PATCH body.
type profileFields struct {
	name, avatar           *string
	maxAgeLevel            *int
	pinPresent, pinIsClear bool
	pin                    string
}

// parseProfileFields validates every editable field present in b and writes the 400 itself
// when one is invalid. requireLevel is POST's "maxAgeLevel is required".
func parseProfileFields(w http.ResponseWriter, b profileBody, requireLevel bool) (profileFields, bool) {
	var f profileFields
	if _, present, _ := b.field("name"); present || requireLevel {
		s, ok := b.stringField("name")
		name, valid := validProfileName(s)
		if !ok || !valid {
			writeErr(w, http.StatusBadRequest, "invalid_profile_name")
			return f, false
		}
		f.name = &name
	}
	if _, present, isNull := b.field("avatar"); present {
		a := ""
		if !isNull {
			s, ok := b.stringField("avatar")
			if !ok || !validAvatar(s) {
				writeErr(w, http.StatusBadRequest, "invalid_avatar")
				return f, false
			}
			a = s
		}
		f.avatar = &a
	}
	if raw, present, isNull := b.field("maxAgeLevel"); present || requireLevel {
		var n int
		if !present || isNull || json.Unmarshal(raw, &n) != nil || !rating.ValidLevel(n) {
			writeErr(w, http.StatusBadRequest, "invalid_age_level")
			return f, false
		}
		f.maxAgeLevel = &n
	}
	if _, present, isNull := b.field("pin"); present {
		f.pinPresent = true
		if isNull {
			f.pinIsClear = true
		} else {
			s, ok := b.stringField("pin")
			if !ok || !validPINFormat(s) {
				writeErr(w, http.StatusBadRequest, "invalid_pin_format")
				return f, false
			}
			f.pin = s
		}
	}
	return f, true
}

// checkOwnerPin applies FR-211/212/215 to a management call and writes the refusal itself.
// Order: owner has no PIN → 409 owner_pin_not_set; ownerPin absent → 403 owner_pin_required;
// malformed → 400 invalid_pin_format (no attempt consumed); locked → 429 pin_locked;
// wrong → 403 pin_incorrect. The owner profile's limiter entry is shared with pin/verify.
func (s *Server) checkOwnerPin(w http.ResponseWriter, owner profileRow, b profileBody) bool {
	if !owner.hasPin() {
		writeErr(w, http.StatusConflict, "owner_pin_not_set")
		return false
	}
	if _, present, isNull := b.field("ownerPin"); !present || isNull {
		writeErr(w, http.StatusForbidden, "owner_pin_required")
		return false
	}
	pin, ok := b.stringField("ownerPin")
	if !ok || !validPINFormat(pin) {
		writeErr(w, http.StatusBadRequest, "invalid_pin_format")
		return false
	}
	return s.checkPinAttempt(w, owner, pin)
}

// checkPinAttempt runs one rate-limited PIN check for p and writes the refusal itself.
func (s *Server) checkPinAttempt(w http.ResponseWriter, p profileRow, pin string) bool {
	res := s.pinLimiter().attempt(p.ID, func() bool { return verifyPIN(p.PinHash.String, pin) })
	switch {
	case res.OK:
		return true
	case res.Locked:
		writeJSON(w, http.StatusTooManyRequests, map[string]any{"error": "pin_locked", "retryAfterSeconds": res.RetryAfterSeconds})
	default:
		writeJSON(w, http.StatusForbidden, map[string]any{"error": "pin_incorrect", "attemptsRemaining": res.AttemptsRemaining})
	}
	return false
}

// pinColumnValue turns validated pin fields into the pin_hash column value.
func pinColumnValue(f profileFields) (sql.NullString, error) {
	if f.pinIsClear {
		return sql.NullString{}, nil
	}
	h, err := hashPIN(f.pin)
	if err != nil {
		return sql.NullString{}, err
	}
	return sql.NullString{String: h, Valid: true}, nil
}

// requestUser returns the authenticated account, or writes 401 (the session, not a profile,
// is what is missing here).
func requestUser(w http.ResponseWriter, r *http.Request) (authedUser, bool) {
	u := userFromCtx(r.Context())
	if u.ID == "" {
		writeErr(w, http.StatusUnauthorized, "missing_token")
		return u, false
	}
	return u, true
}

// ── Handlers ────────────────────────────────────────────────────────────────────────────

func (s *Server) handleProfilesList(w http.ResponseWriter, r *http.Request) {
	u, ok := requestUser(w, r)
	if !ok {
		return
	}
	v, err := s.viewerFor(r)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	rows, err := s.loadProfiles(r.Context(), u.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	out := make([]profileJSON, 0, len(rows))
	for _, p := range rows {
		out = append(out, p.json())
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"maxProfiles":     maxProfilesPerAccount,
		"activeProfileId": v.ProfileID,
		"profiles":        out,
	})
}

func (s *Server) handleProfileAgeLevels(w http.ResponseWriter, r *http.Request) {
	type level struct {
		Level int      `json:"level"`
		Key   string   `json:"key"`
		Label string   `json:"label"`
		Movie []string `json:"movie"`
		TV    []string `json:"tv"`
	}
	tiers := rating.Tiers()
	levels := make([]level, 0, len(tiers))
	for _, t := range tiers {
		levels = append(levels, level{Level: t.Level, Key: t.Key, Label: t.Label, Movie: t.Movie, TV: t.TV})
	}
	writeJSON(w, http.StatusOK, map[string]any{"unratedLevel": rating.UnratedLevel, "levels": levels})
}

func (s *Server) handleProfileCreate(w http.ResponseWriter, r *http.Request) {
	u, ok := requestUser(w, r)
	if !ok {
		return
	}
	b, ok := decodeProfileBody(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}

	s.profiles.mu.Lock()
	defer s.profiles.mu.Unlock()

	rows, err := s.accountProfiles(r.Context(), u)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	owner, _ := ownerOf(rows)
	if !s.checkOwnerPin(w, owner, b) {
		return
	}
	if len(rows) >= maxProfilesPerAccount {
		writeErr(w, http.StatusConflict, "profile_limit_reached")
		return
	}
	f, ok := parseProfileFields(w, b, true)
	if !ok {
		return
	}
	if nameTaken(rows, *f.name, "") {
		writeErr(w, http.StatusConflict, "duplicate_profile_name")
		return
	}
	avatar := ""
	if f.avatar != nil {
		avatar = *f.avatar
	}
	var pinHash sql.NullString
	if f.pinPresent {
		if pinHash, err = pinColumnValue(f); err != nil {
			writeErr(w, http.StatusInternalServerError, "server_error")
			return
		}
	}
	id, err := newProfileID()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server_error")
		return
	}
	created := time.Now().UTC().Format(time.RFC3339)
	if _, err := s.db.ExecContext(r.Context(),
		`INSERT INTO profiles(id, user_id, name, avatar, max_age_level, pin_hash, is_owner, created_at)
		 VALUES(?, ?, ?, ?, ?, ?, 0, ?)`,
		id, u.ID, *f.name, avatar, *f.maxAgeLevel, pinHash, created); err != nil {
		if strings.Contains(err.Error(), "UNIQUE") {
			writeErr(w, http.StatusConflict, "duplicate_profile_name") // NOCASE index backstop
			return
		}
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	p := profileRow{ID: id, UserID: u.ID, Name: *f.name, Avatar: avatar, MaxAgeLevel: *f.maxAgeLevel,
		PinHash: pinHash, CreatedAt: created}
	writeJSON(w, http.StatusCreated, p.json())
}

func (s *Server) handleProfileUpdate(w http.ResponseWriter, r *http.Request) {
	u, ok := requestUser(w, r)
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")
	b, ok := decodeProfileBody(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}

	s.profiles.mu.Lock()
	defer s.profiles.mu.Unlock()

	rows, err := s.accountProfiles(r.Context(), u)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	target, ok := findProfile(rows, id)
	if !ok {
		writeErr(w, http.StatusForbidden, "unknown_profile")
		return
	}
	owner, _ := ownerOf(rows)

	if !owner.hasPin() {
		// FR-212: with no owner PIN yet, the only allowed edit is the owner setting its first
		// PIN (only the account holder has a session at that point).
		_, pinPresent, pinNull := b.field("pin")
		if !target.IsOwner || !pinPresent || pinNull {
			writeErr(w, http.StatusConflict, "owner_pin_not_set")
			return
		}
	} else if !s.checkOwnerPin(w, owner, b) {
		return
	}

	f, ok := parseProfileFields(w, b, false)
	if !ok {
		return
	}
	if target.IsOwner && f.maxAgeLevel != nil && *f.maxAgeLevel < rating.MaxLevel {
		writeErr(w, http.StatusConflict, "owner_profile_immutable") // FR-204
		return
	}
	if target.IsOwner && f.pinIsClear && len(rows) > 1 {
		writeErr(w, http.StatusConflict, "owner_profile_immutable") // FR-212
		return
	}
	if f.name != nil && nameTaken(rows, *f.name, target.ID) {
		writeErr(w, http.StatusConflict, "duplicate_profile_name")
		return
	}

	sets := []string{}
	args := []any{}
	if f.name != nil {
		sets, args = append(sets, "name = ?"), append(args, *f.name)
		target.Name = *f.name
	}
	if f.avatar != nil {
		sets, args = append(sets, "avatar = ?"), append(args, *f.avatar)
		target.Avatar = *f.avatar
	}
	if f.maxAgeLevel != nil {
		sets, args = append(sets, "max_age_level = ?"), append(args, *f.maxAgeLevel)
		target.MaxAgeLevel = *f.maxAgeLevel
	}
	if f.pinPresent {
		h, err := pinColumnValue(f)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "server_error")
			return
		}
		sets, args = append(sets, "pin_hash = ?"), append(args, h)
		target.PinHash = h
	}
	if len(sets) > 0 {
		args = append(args, target.ID, u.ID)
		if _, err := s.db.ExecContext(r.Context(),
			`UPDATE profiles SET `+strings.Join(sets, ", ")+` WHERE id = ? AND user_id = ?`, args...); err != nil {
			if strings.Contains(err.Error(), "UNIQUE") {
				writeErr(w, http.StatusConflict, "duplicate_profile_name")
				return
			}
			writeErr(w, http.StatusInternalServerError, "db_error")
			return
		}
	}
	if f.pinPresent {
		s.pinLimiter().reset(target.ID)
	}
	writeJSON(w, http.StatusOK, target.json())
}

func (s *Server) handleProfileDelete(w http.ResponseWriter, r *http.Request) {
	u, ok := requestUser(w, r)
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")
	b, ok := decodeProfileBody(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}

	s.profiles.mu.Lock()
	defer s.profiles.mu.Unlock()

	rows, err := s.accountProfiles(r.Context(), u)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	target, ok := findProfile(rows, id)
	if !ok {
		writeErr(w, http.StatusForbidden, "unknown_profile")
		return
	}
	if target.IsOwner {
		writeErr(w, http.StatusConflict, "owner_profile_immutable")
		return
	}
	owner, _ := ownerOf(rows)
	if !s.checkOwnerPin(w, owner, b) {
		return
	}

	// FR-206 [DESTRUCTIVE]: the profile and its progress, history and watchlist, in one
	// transaction, and nothing else. progressMu keeps a concurrent progress write for this
	// profile from landing after its rows are deleted.
	s.progressMu.Lock()
	err = s.deleteProfileData(r.Context(), u.ID, target.ID)
	s.progressMu.Unlock()
	if err != nil {
		log.Printf("delete profile: %v", err)
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	s.pinLimiter().reset(target.ID)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) deleteProfileData(ctx context.Context, userID, profileID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck // no-op after Commit
	for _, q := range []string{
		`DELETE FROM progress WHERE profile_id = ?`,
		`DELETE FROM watchlist WHERE profile_id = ?`,
	} {
		if _, err := tx.ExecContext(ctx, q, profileID); err != nil {
			return err
		}
	}
	res, err := tx.ExecContext(ctx, `DELETE FROM profiles WHERE id = ? AND user_id = ? AND is_owner = 0`, profileID, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return fmt.Errorf("profile %s: expected to delete 1 row, deleted %d", profileID, n)
	}
	return tx.Commit()
}

func (s *Server) handleProfilePinVerify(w http.ResponseWriter, r *http.Request) {
	u, ok := requestUser(w, r)
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")
	rows, err := s.accountProfiles(r.Context(), u)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	target, ok := findProfile(rows, id)
	if !ok {
		writeErr(w, http.StatusForbidden, "unknown_profile")
		return
	}
	if !target.hasPin() {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true}) // "returns ok immediately"
		return
	}
	b, ok := decodeProfileBody(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}
	pin, ok := b.stringField("pin")
	if !ok || !validPINFormat(pin) {
		writeErr(w, http.StatusBadRequest, "invalid_pin_format")
		return
	}
	if !s.checkPinAttempt(w, target, pin) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// isDSMUnavailable tells "DSM could not be asked" from "DSM said no". authenticateDSM's
// transport and decode failures are "dsm request failed: …", "dsm auth unavailable: …" or a
// request-construction error; "dsm error code N" is DSM answering, so it is not one of them.
func isDSMUnavailable(err error) bool {
	msg := err.Error()
	if strings.HasPrefix(msg, "dsm error code") {
		return false
	}
	return strings.HasPrefix(msg, "dsm ") || strings.HasPrefix(msg, "create request:") ||
		errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled)
}

func (s *Server) handleOwnerPinReset(w http.ResponseWriter, r *http.Request) {
	if s.checkAuthRateLimit(w, r) {
		return
	}
	u, ok := requestUser(w, r)
	if !ok {
		return
	}
	b, ok := decodeProfileBody(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}
	newPin, ok := b.stringField("newPin")
	if !ok || !validPINFormat(newPin) {
		writeErr(w, http.StatusBadRequest, "invalid_pin_format")
		return
	}
	password, _ := b.stringField("password")
	otp, _ := b.stringField("otp")
	if password == "" {
		writeErr(w, http.StatusForbidden, "password_incorrect")
		return
	}

	// FR-216: DSM is the only identity. Checked exactly as at sign-in, outside the profile
	// lock (a DSM round trip can take seconds).
	dsmUser, err := s.dsmAuth(r.Context(), u.Username, password, otp, "")
	if err != nil {
		log.Printf("owner PIN reset: DSM check failed (username redacted): %v", err)
		var perm *dsmPermissionError
		var tfa *dsmTwoFactorError
		switch {
		case errors.As(err, &perm):
			writeErr(w, http.StatusForbidden, "permission_denied")
		case errors.As(err, &tfa):
			// FR-216: two-factor account, no (usable) OTP sent. The password may be right;
			// blaming it would send the owner down the wrong path.
			writeErr(w, http.StatusForbidden, "otp_required")
		case isDSMUnavailable(err):
			writeErr(w, http.StatusServiceUnavailable, "dsm_unavailable")
		default:
			writeErr(w, http.StatusForbidden, "password_incorrect")
		}
		return
	}
	if dsmUser == nil || "u_"+sanitizeID(dsmUser.Username) != u.ID {
		// The password must belong to THIS account, not merely to some DSM user.
		writeErr(w, http.StatusForbidden, "password_incorrect")
		return
	}

	hash, err := hashPIN(newPin)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "server_error")
		return
	}

	s.profiles.mu.Lock()
	defer s.profiles.mu.Unlock()
	rows, err := s.accountProfiles(r.Context(), u)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	owner, ok := ownerOf(rows)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	if _, err := s.db.ExecContext(r.Context(),
		`UPDATE profiles SET pin_hash = ? WHERE id = ? AND user_id = ? AND is_owner = 1`,
		hash, owner.ID, u.ID); err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	s.pinLimiter().reset(owner.ID)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
