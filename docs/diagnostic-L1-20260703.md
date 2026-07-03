# Level 1 Diagnostic — DSVideo — 2026-07-03

Platforms: iOS + tvOS · Branch: feat/sprint-convert-script

## Cycle 1

### Gate (Phase 1 — Worf)
- iOS build: **SUCCEEDED**
- tvOS build: **SUCCEEDED** (Cinematic redesign compiles on tvOS; `#if !os(tvOS)` fencing correct)
- Tests: scheme has orphaned test target (not wired to test action) → TASK-770
- **GATE: PASS** (no P0)

### Summary
Total open issues this run: **25** (after dedup of TASK-785≡786)
Doctor pre-pass: 274 findings (49 err/225 warn), score 0. Actionable error-classes → TASK-766–769.

By category:
Integration 2 · Completeness 2 · Security 5 · Code 3 · Architecture 1 · Stability 5 · Accessibility 2 · Layout 1 · Doctor 4

### By Severity
- **P0 (blocking): 0** — none. No crash, data loss, auth bypass, or absent feature.
- **P1 (critical): 7** — TASK-774, 775, 776 (credential-exposure chain), 782, 783 (stability), 784 (a11y CTA), 770 (orphaned tests)
- **P2 (major): 11** — 766*, 767, 768*, 769, 771, 772, 773, 777, 778, 779, 780, 786, 787
- **P3 (minor): 3** — 781, 788, 789, 790

  (*766/768 filed as high but are P1/P2-mixed; treated per-site during fix.)

### Reviewed CLEAN (no issues)
- **Cinematic theme** — custom init maps all fields 1:1, Classic/Nitrate preserved, resolver correct, all overlays non-interactive + a11y-hidden.
- **Classic regression: PASS** (Vernier, live sim) — redesign did NOT leak into Classic.
- **AuthenticatedImage** loadedKey/loadGeneration fix — TOCTOU-free, correct across recycling.
- **HomeHero rotation** — Task cancelled properly, no retain cycle.
- Core reliability (actor storage, serialized cache I/O, bounded seek coalescing) — solid.
- All 4 recent shipped features verified vs their commits — no spec gaps.

### Headline finding — P1 credential-exposure chain (Scotty)
1. TASK-776: QuickConnect relay uses cleartext http:// — password + bearer token exposed off-home.
2. TASK-774: live bearer token written plaintext to topshelf.json (App Group, not Keychain).
3. TASK-775: logout doesn't clear it (empty-guard early return) — stale credential persists.
Linked P2s (778, 779): cert failures on direct HTTPS paths funnel users onto the plaintext relay.

### Verdict
**FIX REQUIRED — Cycle 1 of 3.** Zero P0, but 7 P1 (security + stability + a11y). Proceed to Phase 5A.
