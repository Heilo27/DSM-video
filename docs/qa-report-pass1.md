# QA Report — Pass 1
**Date:** 2026-03-15
**Reviewer:** Aegis
**Scope:** All files modified since last commit (iOS app + backend)

---

## Build Status

| Platform | Result | Notes |
|----------|--------|-------|
| iOS Simulator (iPhone 17 Pro, iOS 26.2) | **SUCCEEDED** | Zero errors, zero warnings |
| tvOS Simulator (Apple TV 4K 3rd gen) | **FAILED** | Provisioning profile missing for tvOS target — no tvOS App Development profile found for `HeiloProjects.DSReel`. iOS simulator profiles do not cover tvOS. Ticket: TASK-073 |
| macOS | **FAILED** | Provisioning profile error — `iOS Team Provisioning Profile: *` doesn't include this Mac. Not a code issue; signing configuration issue. |

**iOS build is clean.** No warnings, no errors.

---

## Screenshots

Login screen captured on iPhone 17 Pro simulator (iOS 26.2).

**File:** `/tmp/ds-reel-launch.png`

**Observations from screenshot:**
- Red background with DS Reel logo (circle + play triangle) renders correctly
- "DS Reel" title and "Your NAS, beautifully." subtitle render correctly
- Input group (server/username/password) renders correctly with white card background
- Login button renders correctly (white pill with red text)
- "Pair with Apple TV" link is visible
- Settings gear (bottom-left) and info button (bottom-right) visible
- Version reads "v1.0"
- HTTPS toggle shows ON (red), Remember me shows OFF — these are persisted simulator values from a prior run, not fresh defaults. Default in code is HTTPS=false, RememberMe=true. Correct behavior.

**No visual regressions visible on login screen.**

---

## Code Review Findings

### Files Reviewed

1. `DS Video clone/DS Video clone/DSVideo/App/DSVideoDesignTokens.swift` — NEW file
2. `DS Video clone/DS Video clone/DSVideo/Views/ItemsGridView.swift`
3. `DS Video clone/DS Video clone/DSVideo/Views/GestureVideoPlayer.swift`
4. `DS Video clone/DS Video clone/DSVideo/Views/LoginView.swift`
5. `DS Video clone/DS Video clone/DSVideo/Views/ItemDetailView.swift`
6. `DS Video clone/DS Video clone/DSVideo/Views/MainView.swift`
7. `DS Video clone/DS Video clone/DSVideo/Views/TVShowDetailView.swift`
8. `DS Video clone/DS Video clone/DSVideo/Views/LibrariesView.swift`
9. `DS Video clone/DS Video clone/DSVideo/Views/TVMainView.swift` (read during review)
10. `DS Video clone/DS Video clone/DSVideo/App/AppState.swift` (read during review)
11. `DS Video clone/DS Video clone/DSVideo/Networking/AuthenticatedImage.swift` (read during review)
12. `backend/internal/metadata/images.go`
13. `backend/internal/transcode/hls.go`

---

## Issues Found

### Critical (build/crash)
None.

### High

| Ticket | File | Issue |
|--------|------|-------|
| TASK-069 | MainView.swift:41-55 | Split view SidebarView missing "Home" — LibraryHomeView completely inaccessible on iPad and macOS |

### Medium

| Ticket | File | Issue |
|--------|------|-------|
| TASK-070 | LibrariesView.swift:100-113 | LibraryHomeView "Home" tab shows first library only with false "Just Added" label — not date-sorted |
| TASK-072 | TVMainView.swift:262-264 | TVLibraryRail silent catch — empty rail with no user feedback on load failure |
| TASK-073 | Build config | tvOS provisioning profile missing — tvOS builds fail without connected device |
| TASK-075 | LoginView.swift:396-403 | QuickConnect resolver tries HTTP before HTTPS for LAN addresses — credentials sent unencrypted on first attempt |

### Low

| Ticket | File | Issue |
|--------|------|-------|
| TASK-067 | LoginView.swift:28-37 | Logo ZStack has no .accessibilityHidden(true) or .accessibilityLabel — VoiceOver gets unlabeled element |
| TASK-068 | ItemDetailView.swift:90-100 | Dead code: identical fullScreenCover in both sides of #if os(tvOS) conditional |
| TASK-071 | DSVideoDesignTokens.swift:44-46 | hex initializer default fallback `(1, 1, 0)` is misleading — looks like "yellow" but resolves to near-black |
| TASK-074 | GestureVideoPlayer.swift:265-267 | Two consecutive Spacer() elements — duplicate is dead code |

---

## Pass/Fail Verdicts by Implementation Area

### LoginView changes (logomark, QuickConnect button, settings/info sheet actions)
- Logomark renders correctly: **PASS**
- Settings button opens SettingsView sheet: **PASS** (code verified — showSettings state + sheet modifier)
- About button opens AboutView sheet: **PASS** (code verified — showAbout state + sheet modifier)
- QuickConnect button opens QuickConnectSheet: **PASS** (code verified)
- QuickConnect resolver logic: **PASS** (implementation is correct)
- Accessibility on logo: **FAIL** — TASK-067
- HTTP-first ordering in QuickConnect candidates: **FAIL** (medium concern) — TASK-075

### GestureVideoPlayer (AirPlay button, removed center play button)
- AirPlay button present on iOS using AVRoutePickerView: **PASS** (GestureVideoPlayer.swift:232-235)
- AirPlay button tinted white with brand active color: **PASS** (AirPlayButton struct, lines 862-867)
- Center play button removed: **PASS** (confirmed absent — only bottom controls HStack with skip/play/skip)
- Single-tap/double-tap gesture exclusive composition: **PASS** (SpatialTapGesture exclusively composed, lines 180-200)
- Double Spacer: **FAIL** (low cosmetic) — TASK-074

### ItemsGridView (progress bar fix)
- Progress bar inside clip boundary: **PASS** (GeometryReader-based implementation inside ZStack, clipped with parent)
- Watched badge outside clip (overlay): **PASS** (overlay modifier outside clipShape)
- frac clamped to 1.0: **PASS** (`min(1.0, ...)` applied before comparison)

### ItemDetailView (hero height 300pt, backdrop image)
- Hero height 300pt on iOS: **PASS** (minHeight/maxHeight: 300 on non-tvOS)
- Hero height 450pt on tvOS: **PASS** (#if os(tvOS) branch)
- Backdrop image with gradual fade: **PASS** (LinearGradient with 3 stops: clear → 60% at 0.55 → black at 1.0)
- Title floating on gradient: **PASS** (ZStack alignment: .bottomLeading with VStack)
- Fallback gradient when no backdrop: **PASS** (LinearGradient placeholder in backdropImage)
- Dead code in fullScreenCover: **FAIL** (low) — TASK-068

### MainView (settings version label, search error state)
- Version in Settings reads from CFBundleShortVersionString: **PASS** (MainView.swift:388)
- Search error state uses ContentUnavailableView: **PASS** (MainView.swift:77-78)
- Split layout missing Home: **FAIL** (high) — TASK-069
- Home tab "Just Added" misrepresents content: **FAIL** (medium) — TASK-070

### TVShowDetailView (brand color fix)
- CircularProgressView uses DSReelBrandColor.background: **PASS** (TVShowDetailView.swift:273)

### LibrariesView (empty state)
- Empty state uses ContentUnavailableView: **PASS** (LibrariesView.swift:22-23)
- Error state uses ContentUnavailableView: **PASS** (LibrariesView.swift:20-21)

### DSVideoDesignTokens.swift (new file)
- Syntax valid: **PASS** (build succeeds)
- All required tokens defined: **PASS** (backgrounds, accents, status, text, borders)
- Font scale defined: **PASS**
- Hex initializer functional: **PASS** (for valid 6-char strings)
- Hex initializer fallback misleading: **FAIL** (low) — TASK-071

### Backend — images.go
- Explicit f.Close() with error handling: **PASS** (lines 153-155: close error is checked, cleanup on failure)
- io.Copy error handled with cleanup: **PASS** (lines 148-152)

### Backend — hls.go
- Context lifecycle management reviewed: **PASS** (HLSSession has cancel func, StopSession decrements active)
- Session map thread safety: **PASS** (sync.Mutex protects active and sessions map)

---

## Overall Verdict

**iOS build: PASS**
**tvOS build: BLOCKED** (provisioning, not a code issue — TASK-073)
**macOS build: BLOCKED** (provisioning, not a code issue)

**Code quality: CONDITIONAL PASS**

9 issues found across all reviewed files. No crashes or data loss issues. The high-priority issue (TASK-069: Home tab missing from split view) is a UX gap that affects all iPad and macOS users. The medium issues are functional gaps and security concerns. Low issues are cosmetic or maintainability.

**Recommended next actions (priority order):**
1. TASK-069 — Fix SidebarView missing Home
2. TASK-073 — Fix tvOS provisioning so tvOS builds are verifiable
3. TASK-075 — Evaluate QuickConnect HTTP-first ordering
4. TASK-070 — Fix "Just Added" label accuracy
5. TASK-072 — Fix TVLibraryRail silent failure on tvOS
6. TASK-067, TASK-071, TASK-074, TASK-068 — Low polish items
