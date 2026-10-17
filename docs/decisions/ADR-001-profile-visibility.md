# ADR-001 — Where profile visibility lives

**Date:** 2026-10-17 · **Status:** Accepted (spec stage, TASK-914) · **Spec:** `docs/frd/FRD-002-profiles.md`

## Context

FRD-002 adds profiles with age ceilings. Every title gets an age level derived from its US certification,
and every client-facing route must respect the active profile's ceiling. Three forces shape this:
- **Rule 9 (one home).** The certification → level mapping and the unrated rule are business rules. If two
  copies drift, one platform shows a child a title the other hides.
- **NAS hardware.** Listing queries already page over large libraries on a weak CPU. Filtering must stay in
  SQL and use indexes, not run as a per-row pass in Go.
- **Delta sync.** Devices replicate the catalog by `change_seq`. That stream must keep its meaning, "rows
  that changed since N".

## Decisions

1. **A leaf package owns the ladder.** `backend/internal/rating` holds the table (FRD-002 FR-241), the
   unrated rule (FR-242), a `Level(cert string) int` function, and a generated SQL expression that computes
   the same level from `items.content_rating`. It imports nothing from the server. `internal/metadata` (the
   TMDb client) fetches and normalizes the raw string and never imports `rating`. Handlers in `main.go` and
   `webapi.go` import `rating`. Dependencies point one way: handlers → rating; metadata → nothing new.
2. **The certification string is the only stored fact.** No `age_level` column. Every filtered query uses
   `rating.SQLLevel("content_rating") <= ?`. A stored derived column would need every write path (TASK-915's
   fetch, `tmdb-fix`, show fix) to remember to stamp it, which means a second home in practice. The CASE
   expression over one short TEXT column costs little next to the existing LIKE and ORDER BY work. If
   profiling on the NAS proves otherwise, add a generated column (`GENERATED ALWAYS AS (…) STORED`) built
   from the same expression, which keeps one home.
3. **The server sends levels, clients compare.** Every item payload, the sync stream included, carries
   `ageLevel` (unrated is 4). Clients never see the ladder's rules, only `GET /profiles/age-levels` for
   display. A client's whole visibility logic is `ageLevel <= maxAgeLevel`.
4. **Sync is account-scoped and unfiltered.** Filtering `/sync/items` per profile would break delta
   semantics: switching profiles changes the visible set without changing any row, so no delta would
   deliver the newly visible rows and every switch would need a full re-sync (~100x slower over WAN, see the
   sync durability notes). The device cache holds the account's catalog with levels, and every local read
   filters (FR-262). Playback, detail and stream creation stay server-refused, so a client bug that leaks a
   title into a list still cannot play it.
5. **Profile resolution is one middleware step after auth.** It reads `X-DSVideo-Profile`, validates it
   against the token's account, or applies the no-header fallback (FR-221: most restricted profile if any
   exists, else the owner). It puts `{profileID, maxAgeLevel, isOwner}` in the request context and echoes
   the resolved id. Handlers read the context; none of them parse the header. The WebAPI layer calls the
   same resolver with no header.
6. **Collections are data in one Go definition** (id, title, kind, audience, rule with `(kind, id)` company
   pairs, keyword ids, genre names), in the same leaf-package style. Membership is evaluated in SQL against
   `item_companies` / `item_keywords`, and the visibility expression from decision 1 is ANDed in.

## Stress test

- *Add a fifth tier or change a mapping:* edit the table in `rating`. A migration bumps `change_seq` for
  items whose level moved (FR-244). No client release needed.
- *Add a non-US ratings source:* `metadata` stores a different raw string. `rating` gains a mapping. Nothing
  else changes.
- *Close the PIN gap with profile-scoped tokens (FRD-002 §11):* only decision 5 changes, because the
  resolver reads a token instead of an id. Handlers are untouched.
- *Swap SQLite:* the level expression is plain SQL CASE and ports as-is.

## Rejected

- **Client-side-only filtering:** contradicts the server-enforcement decision and leaves shipped builds
  unfiltered.
- **Per-profile filtered sync:** see decision 4.
- **Stored `age_level` column stamped by writers:** see decision 2.
