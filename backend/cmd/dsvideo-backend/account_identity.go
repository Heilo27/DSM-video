package main

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"
)

// Account keys (TASK-931).
//
// An account's key ("u_…", the user_id on every progress, watchlist, playlist, settings and
// profiles row) was "u_"+sanitizeID(username). sanitizeID maps every character outside
// [a-z0-9] to '_' and trims '_', so distinct DSM users shared one account: "ryan.p",
// "ryan_p" and "ryan-p" all became u_ryan_p, and every username made only of non-ASCII
// letters became the bare "u_". The second user saw the first's history, watchlist and
// profiles, and could reset the owner PIN with their own DSM password (FR-216).
//
// The fix is additive. Existing rows are never moved, re-keyed or deleted (an irreversible
// data change is out of bounds); instead account_claims records which DSM user owns each
// key, and the database constraints make a shared key impossible from here on:
//
//   - user_id is the PRIMARY KEY: one key, one DSM user.
//   - username is UNIQUE: one DSM user, one key.
//
// A DSM user's first sign-in after the upgrade claims the key they always had (the legacy
// mapping), so every existing account carries on exactly as before. A DIFFERENT DSM user
// whose legacy key is already claimed gets a deterministic key of their own (legacy key +
// a short hash of their username) instead of entering the claimant's account.
//
// Known limit: a key with existing data and no claim yet goes to whichever matching DSM
// user signs in first after the upgrade. Only users who were ALREADY colliding (and so
// already sharing one account) are affected; nothing records who came first.

const accountClaimsSchema = `
CREATE TABLE IF NOT EXISTS account_claims (
  user_id    TEXT PRIMARY KEY,
  username   TEXT NOT NULL UNIQUE,
  claimed_at TEXT NOT NULL
);`

// migrateAccountClaims creates account_claims. Idempotent; it never touches another table.
func migrateAccountClaims(db *sql.DB) error {
	if _, err := db.Exec(accountClaimsSchema); err != nil {
		return fmt.Errorf("create account_claims: %w", err)
	}
	return nil
}

// dsmIdentity is the form a DSM username is compared and stored in. DSM usernames are
// case-insensitive, and sanitizeID always trimmed, so " Ryan" and "ryan" were and stay one
// user. Nothing else is folded: "ryan.p" and "ryan_p" are different people.
func dsmIdentity(username string) string {
	return strings.ToLower(strings.TrimSpace(username))
}

// legacyAccountKey is the pre-TASK-931 mapping. Every existing account is keyed by it.
func legacyAccountKey(identity string) string {
	return "u_" + sanitizeID(identity)
}

// distinctAccountKey is the key for a DSM user whose legacy key belongs to someone else:
// stable across sign-ins (it depends only on the username), readable by its prefix, and
// distinct per username. 48 bits of SHA-256 is far past collision range for the handful of
// colliding names one NAS can have, and even a collision cannot merge two users: the
// PRIMARY KEY refuses the second claim and sign-in fails instead.
func distinctAccountKey(identity string) string {
	sum := sha256.Sum256([]byte(identity))
	h := hex.EncodeToString(sum[:6])
	if base := sanitizeID(identity); base != "" {
		return "u_" + base + "_" + h
	}
	return "u_" + h
}

// accountKey returns the account key for a DSM-authenticated username, claiming one on the
// user's first sign-in. It is the ONE place a username becomes an account key: REST sign-in,
// every WebAPI session path and the FR-216 owner PIN reset all call it.
func (s *Server) accountKey(ctx context.Context, username string) (string, error) {
	identity := dsmIdentity(username)
	if identity == "" {
		return "", errors.New("accountKey: empty DSM username")
	}
	if key, ok, err := s.claimedAccountKey(ctx, identity); err != nil || ok {
		return key, err
	}
	legacy := legacyAccountKey(identity)
	for _, candidate := range []string{legacy, distinctAccountKey(identity)} {
		// INSERT OR IGNORE is atomic: it is skipped when another DSM user holds the
		// candidate (PRIMARY KEY) or when a concurrent sign-in of this same user already
		// claimed a key (UNIQUE username). Either way the lookup below says what we own.
		if _, err := s.db.ExecContext(ctx,
			`INSERT OR IGNORE INTO account_claims(user_id, username, claimed_at) VALUES(?, ?, ?)`,
			candidate, identity, time.Now().UTC().Format(time.RFC3339)); err != nil {
			return "", fmt.Errorf("accountKey: claim: %w", err)
		}
		key, ok, err := s.claimedAccountKey(ctx, identity)
		if err != nil {
			return "", err
		}
		if ok {
			if key != legacy {
				log.Printf("[identity] account key %s belongs to another DSM user; this user gets %s (TASK-931)", legacy, key)
			}
			return key, nil
		}
	}
	return "", fmt.Errorf("accountKey: every candidate key for this DSM user is claimed")
}

// claimedAccountKey is the key identity already owns, if any.
func (s *Server) claimedAccountKey(ctx context.Context, identity string) (string, bool, error) {
	var key string
	err := s.db.QueryRowContext(ctx, `SELECT user_id FROM account_claims WHERE username = ?`, identity).Scan(&key)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return "", false, nil
	case err != nil:
		return "", false, fmt.Errorf("accountKey: lookup: %w", err)
	}
	return key, true, nil
}

// credentialOwnsAccount reports whether a credential issued for (key, username), a REST
// token's sub/usr or a WebAPI session's UserID/Username, still belongs to the DSM user who
// owns key. It is false only when account_claims gives key to a DIFFERENT DSM user.
//
// This closes the window TASK-931 left open: tokens (30 days) and persisted WebAPI sessions
// issued BEFORE account_claims existed still carry the old shared key, so a colliding DSM
// user kept entering the claimant's account until the credential expired. An unclaimed key
// passes: its user has not signed in since the upgrade, and nobody else has a better claim
// to it (accountKey hands an unclaimed legacy key to the first matching sign-in).
func (s *Server) credentialOwnsAccount(ctx context.Context, key, username string) (bool, error) {
	if owner, ok := s.accountClaimOwners.Load(key); ok {
		return owner.(string) == dsmIdentity(username), nil
	}
	var owner string
	err := s.db.QueryRowContext(ctx, `SELECT username FROM account_claims WHERE user_id = ?`, key).Scan(&owner)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return true, nil // not cached: a claim can still appear
	case err != nil:
		return false, fmt.Errorf("credentialOwnsAccount: lookup: %w", err)
	}
	s.accountClaimOwners.Store(key, owner)
	return owner == dsmIdentity(username), nil
}
