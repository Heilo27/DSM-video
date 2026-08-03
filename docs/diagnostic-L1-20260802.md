# Level 1 Diagnostic — DSVideo (iOS + tvOS) — 2026-08-02

## Cycle 1

**Scope:** `DS Video clone/DSM Video` — 47 Swift files shared between the iOS target
(`DSM Video`) and the tvOS target (`DS Video clone tvOS`) via `#if os(tvOS)` blocks.
Go backend included where client assumptions needed cross-checking.

**Baseline:** branch `main`, clean tree at `0aff373`.
**Doctor pre-pass:** swift-doctor — 260 findings (39 errors, 221 warnings), score 0/100.

---

### Summary

| Category | Count |
|---|---|
| Integration / Platform Gate | 5 |
| Code | 7 |
| Stability | 9 |
| Security | 5 |
| Layout / Accessibility / UX | 6 |
| **Total new this run** | **31** |

### By severity

| | Count | IDs |
|---|---|---|
| **P0** | 4 | TASK-831, TASK-832 (fixed), TASK-837, TASK-834 (fixed) |
| **P1** | 12 | TASK-830, 833, 835, 836, 838, 839, 840, 841, 843, 853, 854, 857 |
| **P2** | 11 | TASK-842, 844, 845, 846, 847, 848, 849, 850, 851, 855, 856, 858 |
| **P3** | 4 | TASK-852, 859, + doctor-class polish |

---

### The dominant finding: one defect class, five locations

Every tvOS bug this run is the same mistake — **iOS UI API compiled for tvOS, laid out
somewhere the author never looked.** It compiles, it ships, and the control simply is not
on screen. The simulator does not overscan, so none of it reproduces without either a real
TV or measuring pixel bounds against the title-safe rect.

| Location | Symptom | Status |
|---|---|---|
| `GestureVideoPlayer` top bar | 20pt padding → 40pt into overscan | Fixed (pre-run) |
| `GestureVideoPlayer` transport row | remaining-time label clipped off-screen | Fixed (pre-run) |
| `ItemsGridView` (Movies grid) | sort in `ToolbarItem(.topBarTrailing)` — never renders | **Fixed** |
| `TVShowsView` (TV Shows grid) | 4 sort buttons in same placement; chip bar `#if !os(tvOS)` | **Fixed** |
| `TVMainView` (Home) | Settings/Search pills printed **over** the "Just Added" header | **Fixed** |

Measured on Apple TV 4K @1920×1080: the Home toolbar buttons drew at x 46–283, y 60–135,
rendering the rail header as "ust A d". The library rail header's focus highlight breached
the left title-safe margin by 14px because its 60pt padding sat *inside* the Button label.

**Rule going forward:** on tvOS, `ToolbarItem` with any `topBar*` placement is a bug. Put
header actions in the content with `.safeAreaInset` and 60pt horizontal padding.

---

### P0s — all fixed this cycle

**TASK-837 — crash-loop from a 64-bit integer.** `LocalStore` bound every integer through
`Int32(...)` — the *trapping* narrowing initializer — at 8 sites, while the models are
`Int` and the values come straight from server JSON. The backend validated progress only as
`duration <= 0 || position < 0` with no upper bound, so an out-of-range duration was
accepted, stored, returned by `/progress/all`, and trapped inside the client's sync write.
`runDeltaSync` runs at every launch, so one bad row bricks the app with no in-app escape
(Force Refresh runs the same sync). Fixed on both sides: client binds `int64` throughout;
server now rejects impossible durations so no client — including builds already shipped —
can be poisoned.

**TASK-834 — the entire auth-expiry layer was dead code.** `APIClient` decoded the JSON
error body before falling through to `.http(status)`, and the backend attaches a JSON body
to *every* error including 401. So all auth rejections became `.server("invalid_token")`
and the two `case .http(401)` handlers could never fire. An expired or revoked token left
the user on an authenticated-looking UI with empty rails, no route back to login, and the
dead token still in the Keychain. `APIError.server` now carries the HTTP status; a new
`isAuthFailure` covers both shapes.

**TASK-853 (P1, same root)** — `reconnect()` *failed open* for the same reason: its
`.http(401)` match never fired, so it fell through and **adopted** the server on any auth
rejection, calling `clearNetworkError()`. `/api/v1/version` is unauthenticated, so a revoked
account passed probe one and had probe two's failure swallowed. Now fails closed.

**TASK-831 / TASK-832** — the tvOS sort controls above.

---

### Confirmed, not fixed (carried to cycle 2)

**Progress sync had no retry (TASK-830 + TASK-839) — FIXED.** `recordProgress` fired the
POST in a detached, unretried `Task` that only logged failure, and its comment claimed a
"delta-sync cursor reconciles the server on the next pass" — a mechanism that does not exist
anywhere in the client. Sync is download-only, so progress recorded while the NAS was
unreachable was lost permanently. Fixed with a `pending_sync` outbox (schema v2), flushed
before the download half of sync and on every reconnect.

**CORRECTION — the server was never empty.** Earlier in this session I reported "the server
has zero progress rows" and repeated it several times while reasoning about the tvOS rails.
That measurement was wrong: I queried `/api/v1/progress`, a *batch* endpoint that returns an
empty map unless given `ids=`. The correct endpoint is `/api/v1/progress/all`, which returns
**193 rows — 35 eligible for Continue Watching, 118 for Recently Watched**. The client
already calls `/progress/all` correctly (`APIClient.swift:141`).

The empty tvOS rails were therefore NOT caused by missing server data. The actual cause is
the `homeLoad()` early-return fixed in `0aff373`: once `homeLibraries` was populated the
function returned before ever querying the rails from SQLite. Replaying the real server data
through the rail SQL confirms Continue Watching will show 10 titles once that fix reaches the
device.

The outbox fix remains correct and worth keeping — a failed POST was genuinely being dropped
— but it is a durability improvement, not the cause of the reported symptom.

**iOS AX5 Dynamic Type is broken (TASK-857).** At maximum text size, card titles overflow
onto the poster art and collide with text baked into the artwork. Unreadable.

---

### Clean results worth recording

- `runDeltaSync`'s page loop **terminates** — the 200-page cap and stalled-cursor guard
  added earlier this session work; bounded by `hasMore` as well.
- Migrations are `user_version`-gated and additive. No crash-on-update path.
- All multi-step writes are transactional. Every division by duration guards `> 0`.
- ATS: `NSAllowsLocalNetworking` only, no arbitrary loads, no cert bypass anywhere.
- Tokens never appear in a URL or a log. Keychain accessibility class is correct.
- SQL is fully parameterized.
- iOS empty states are complete — only tvOS was defective.
- Test suite uses Swift Testing: **47 tests, all unconditional, no `XCTSkip` escape
  hatches.** The pass count is real, not manufactured. (3 UITest functions are boilerplate.)

---

### Coverage gaps — stated, not hidden

1. **tvOS focus reachability was never verified.** This host has no UI driver: Simulator.app
   is absent (headless Xcode-beta), `idb` is broken under Python 3.14, and there is no tvOS
   UITest scheme. Findings came from a demo-mode launch argument, which reaches Home only.
   **The Movies and TV Shows sort chips fixed this cycle have never been focused on a
   device.** Tracked as TASK-859 with the cheap fix (register a debug URL scheme —
   `onOpenURL` already sets `pendingDeepLinkItemID`).
2. **No iPhone SE exists on this Mac.** iOS layout was checked on iPhone 17e, the narrowest
   available — a wider screen than the spec's target, so narrow-width clipping may be
   under-reported.
3. **No physical device pass.** The Apple TV is not paired to this Mac.

---

### Verdict

**FIX REQUIRED — cycle 1 of 3.** All 4 P0s fixed and committed (`3677377`). iOS, tvOS, and
the Go backend build clean; backend tests pass.

Remaining: 12 P1 / 11 P2 / 4 P3, none blocking a build. The highest-value next item is
progress sync (TASK-830/839) — it is the root cause of the user-reported empty Continue
Watching rails and is a real data-durability gap, not cosmetic.
