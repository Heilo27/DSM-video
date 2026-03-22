# DSVideo (Daily Mirror) — Accessibility Audit

**Date:** 2026-03-22
**Design file:** `designs/ds-reel-redesign.pen`
**Standard:** WCAG 2.1 AA
**Context:** Apple rejected app for "difficult to read text"
**Screens audited:** Daily Challenge, Leaderboard, Cosmetics Shop

---

## Executive Summary

**31 of 63 text elements fail WCAG AA contrast requirements (49% failure rate).**

Three systemic issues account for the vast majority of failures:

1. **`#9B8FF5` (light purple) used as secondary text color** — fails on both `#FFFFFF` (2.75:1) and `#F8F7FF` (2.58:1) backgrounds. This single color accounts for 20 of 31 failures. Needs to darken to at least `#6B5CE7` (~4.6:1 on white).

2. **`#C7C7CC` (light gray) used for tertiary/hint text** — fails at 1.58-1.68:1. Essentially invisible. Needs to darken to at least `#767680` (~4.6:1 on white).

3. **Font sizes below 11px** — multiple labels at 9-10px are far below the 14px minimum recommended for body text on mobile. Apple HIG recommends minimum 11pt for caption text, and these are functional labels, not decorative.

### Font Size Distribution

| Size | Count | Usage | Assessment |
|------|-------|-------|------------|
| 9px | 5 | Skin labels (Classic, Marble, etc.) | **TOO SMALL** — raise to 11px minimum |
| 10px | 10 | Tab labels, stat labels, theme labels, countdown units | **TOO SMALL** — raise to 11px minimum |
| 11px | 14 | Section headers, level text, item counts, badge text | Borderline — acceptable as caption only |
| 12px | 6 | Streak text, descriptions, prices, button text | Acceptable for secondary |
| 13px | 8 | Tab text, equip/banner text, grid label, rank text | Acceptable |
| 14px | 8 | Player names, scores, share button, sound names | Good |
| 15px | 3 | Status bar, link text | Good |
| 16px | 5 | Play button, rank numbers, preview title | Good |
| 20px | 5 | Nav titles, stat values | Good |
| 22px | 1 | Date heading | Good |
| 28px | 3 | Countdown numbers | Good |

---

## Screen 1: Daily Challenge

### All Text Elements

| Element | Color | Background | Size | Weight | Ratio | AA Req | Result |
|---------|-------|------------|------|--------|-------|--------|--------|
| Status bar time "9:41" | `#0F0E1A` | `#F8F7FF` | 15px | 600 | 17.98:1 | 4.5:1 | PASS |
| Nav title "Daily Mirror" | `#0F0E1A` | `#F8F7FF` | 20px | 700 | 17.98:1 | 3.0:1 | PASS |
| Date label "TODAY'S CHALLENGE" | `#B8B0F5` | `#5B4FE8` | 11px | 600 | 2.83:1 | 4.5:1 | **FAIL** |
| Date heading "March 21, 2026" | `#FFFFFF` | `#5B4FE8` | 22px | 700 | 5.63:1 | 3.0:1 | PASS |
| Streak text "5-day streak" | `#E2DEFF` | `#5B4FE8` | 12px | 500 | 4.33:1 | 4.5:1 | **FAIL** |
| Section label "FEATURED PUZZLE" | `#9B8FF5` | `#F8F7FF` | 11px | 600 | 2.58:1 | 4.5:1 | **FAIL** |
| Difficulty badge "Medium" | `#F5A623` | `#EDE9FF` | 11px | 500 | 1.71:1 | 4.5:1 | **FAIL** |
| Grid label "4x4 Grid" | `#0F0E1A` | `#FFFFFF` | 13px | 600 | 19.12:1 | 4.5:1 | PASS |
| Puzzle description | `#6B6A8A` | `#FFFFFF` | 12px | 400 | 5.18:1 | 4.5:1 | PASS |
| Play button "Start Today's Challenge" | `#FFFFFF` | `#5B4FE8` | 16px | 600 | 5.63:1 | 4.5:1 | PASS |
| Countdown label "RESETS IN" | `#9B8FF5` | `#F8F7FF` | 11px | 600 | 2.58:1 | 4.5:1 | **FAIL** |
| Countdown numbers (14, 22, 07) | `#0F0E1A` | `#FFFFFF` | 28px | 700 | 19.12:1 | 3.0:1 | PASS |
| Countdown units (hours, minutes, seconds) | `#9B8FF5` | `#FFFFFF` | 10px | 500 | 2.75:1 | 4.5:1 | **FAIL** |
| Countdown colons | `#C7C7CC` | `#FFFFFF` | 28px | 700 | 1.68:1 | 3.0:1 | **FAIL** |
| Stat value "1,247" | `#0F0E1A` | `#FFFFFF` | 20px | 700 | 19.12:1 | 3.0:1 | PASS |
| Stat value "#12" | `#5B4FE8` | `#FFFFFF` | 20px | 700 | 5.63:1 | 3.0:1 | PASS |
| Stat value "12.3s" (green) | `#34C759` | `#FFFFFF` | 20px | 700 | 2.22:1 | 3.0:1 | **FAIL** |
| Stat labels (10px, e.g. "Today's players") | `#9B8FF5` | `#FFFFFF` | 10px | 500 | 2.75:1 | 4.5:1 | **FAIL** |
| LB link "View full leaderboard" | `#0F0E1A` | `#FFFFFF` | 15px | 500 | 19.12:1 | 4.5:1 | PASS |
| Share label "SHARE YOUR RESULT" | `#9B8FF5` | `#F8F7FF` | 11px | 600 | 2.58:1 | 4.5:1 | **FAIL** |
| Share text content | `#0F0E1A` | `#FFFFFF` | 13px | 400 | 19.12:1 | 4.5:1 | PASS |
| Share button "Share to Friends" | `#5B4FE8` | `#EDE9FF` | 14px | 600 | 4.75:1 | 4.5:1 | PASS |
| Tab label active "DAILY" | `#FFFFFF` | `#5B4FE8` | 10px | 600 | 5.63:1 | 4.5:1 | PASS |
| Tab labels inactive (PLAY/RANKS/SHOP) | `#9B8FF5` | `#FFFFFF` | 10px | 600 | 2.75:1 | 4.5:1 | **FAIL** |

**Daily Challenge failures: 11 of 24 (46%)**

### Recommended Fixes — Daily Challenge

| Element | Current | Fix |
|---------|---------|-----|
| "TODAY'S CHALLENGE" label | `#B8B0F5` 11px | Change to `#FFFFFF` with 70% opacity or `#D4CFFF` — or increase to 14px bold for large-text threshold |
| "5-day streak" | `#E2DEFF` 12px | Change to `#FFFFFF` (5.63:1) or `#F0EDFF` |
| Section labels (FEATURED PUZZLE, RESETS IN, SHARE YOUR RESULT) | `#9B8FF5` on `#F8F7FF` | Change to `#6B5CE7` (~4.6:1) or `#5B4FE8` (6.95:1) |
| "Medium" badge | `#F5A623` on `#EDE9FF` | Change text to `#8B6914` (~4.5:1) or darken badge bg |
| Countdown units | `#9B8FF5` 10px on `#FFFFFF` | Change to `#6B5CE7` and increase to 11px+ |
| Countdown colons | `#C7C7CC` on `#FFFFFF` | Change to `#8E8E93` (3.53:1 for large text) |
| Stat "12.3s" green | `#34C759` on `#FFFFFF` | Change to `#1B8A36` (~4.6:1) or `#248A3D` (Apple's accessible green) |
| Stat labels 10px | `#9B8FF5` 10px | Change to `#6B5CE7` and increase to 11px+ |
| Inactive tab labels 10px | `#9B8FF5` 10px on `#FFFFFF` | Change to `#6B5CE7` |

---

## Screen 2: Leaderboard

### All Text Elements

| Element | Color | Background | Size | Weight | Ratio | AA Req | Result |
|---------|-------|------------|------|--------|-------|--------|--------|
| Status bar time | `#0F0E1A` | `#F8F7FF` | 15px | 600 | 17.98:1 | 4.5:1 | PASS |
| Nav title "Leaderboard" | `#0F0E1A` | `#F8F7FF` | 20px | 700 | 17.98:1 | 3.0:1 | PASS |
| Tab "Global" active | `#FFFFFF` | `#5B4FE8` | 13px | 600 | 5.63:1 | 4.5:1 | PASS |
| Tab "Daily"/"Friends" inactive | `#9B8FF5` | `#F8F7FF` | 13px | 500 | 2.58:1 | 4.5:1 | **FAIL** |
| Rank #1 number | `#F5A623` | `#FFFFFF` | 16px | 700 | 2.03:1 | 3.0:1 | **FAIL** |
| Rank #2 number | `#9B8FF5` | `#FFFFFF` | 16px | 700 | 2.75:1 | 3.0:1 | **FAIL** |
| Rank #3 number | `#C97B2F` | `#FFFFFF` | 16px | 700 | 3.30:1 | 3.0:1 | PASS |
| Rank #4-5 number | `#6B6A8A` | `#FFFFFF` | 16px | 700 | 5.18:1 | 3.0:1 | PASS |
| Player names | `#0F0E1A` | `#FFFFFF` | 14px | 600 | 19.12:1 | 4.5:1 | PASS |
| Level text (e.g. "Level 48") | `#9B8FF5` | `#FFFFFF` | 11px | 400 | 2.75:1 | 4.5:1 | **FAIL** |
| Scores | `#0F0E1A` | `#FFFFFF` | 14px | 700 | 19.12:1 | 3.0:1 | PASS |
| "ranks 6-99" hint | `#C7C7CC` | `#FFFFFF` | 11px | 400 | 1.68:1 | 4.5:1 | **FAIL** |
| Self rank "#12" | `#5B4FE8` | `#EDE9FF` | 13px | 700 | 4.75:1 | 4.5:1 | PASS |
| Self name "You" | `#5B4FE8` | `#EDE9FF` | 14px | 600 | 4.75:1 | 4.5:1 | PASS |
| Self level "Level 22 - PRO" | `#9B8FF5` | `#EDE9FF` | 11px | 400 | 2.32:1 | 4.5:1 | **FAIL** |
| Self score "54,820" | `#5B4FE8` | `#EDE9FF` | 14px | 700 | 4.75:1 | 3.0:1 | PASS |
| Tab labels inactive | `#9B8FF5` | `#FFFFFF` | 10px | 600 | 2.75:1 | 4.5:1 | **FAIL** |

**Leaderboard failures: 7 of 17 (41%)**

### Recommended Fixes — Leaderboard

| Element | Current | Fix |
|---------|---------|-----|
| Inactive tab text ("Daily"/"Friends") | `#9B8FF5` 13px | Change to `#6B5CE7` (~4.6:1 on `#F8F7FF`) |
| Rank #1 gold | `#F5A623` on `#FFFFFF` | Change to `#B07D18` (~4.5:1) |
| Rank #2 purple | `#9B8FF5` on `#FFFFFF` | Change to `#6B5CE7` (large text needs 3:1, this gets ~4.6:1) |
| Level text | `#9B8FF5` 11px on `#FFFFFF` | Change to `#6B5CE7` |
| "ranks 6-99" hint | `#C7C7CC` 11px | Change to `#767680` (~4.6:1) |
| Self level text | `#9B8FF5` on `#EDE9FF` | Change to `#5B4FE8` (4.75:1) |
| Bottom tab labels | `#9B8FF5` 10px | Change to `#6B5CE7` |

---

## Screen 3: Cosmetics Shop

### All Text Elements

| Element | Color | Background | Size | Weight | Ratio | AA Req | Result |
|---------|-------|------------|------|--------|-------|--------|--------|
| Status bar time | `#0F0E1A` | `#F8F7FF` | 15px | 600 | 17.98:1 | 4.5:1 | PASS |
| Nav title "Cosmetics" | `#0F0E1A` | `#F8F7FF` | 20px | 700 | 17.98:1 | 3.0:1 | PASS |
| Pro banner text | `#FFFFFF` | `#5B4FE8` | 13px | 600 | 5.63:1 | 4.5:1 | PASS |
| "Upgrade" button | `#5B4FE8` | `#FFFFFF` | 12px | 700 | 5.63:1 | 4.5:1 | PASS |
| Section label "LIVE PREVIEW" | `#9B8FF5` | `#F8F7FF` | 11px | 600 | 2.58:1 | 4.5:1 | **FAIL** |
| Preview title "Neon Skin" | `#0F0E1A` | `#FFFFFF` | 16px | 700 | 19.12:1 | 3.0:1 | PASS |
| Preview subtitle "Tile Skin - $0.99" | `#9B8FF5` | `#FFFFFF` | 12px | 400 | 2.75:1 | 4.5:1 | **FAIL** |
| Equip button | `#FFFFFF` | `#5B4FE8` | 13px | 600 | 5.63:1 | 4.5:1 | PASS |
| Section label "TILE SKINS" | `#9B8FF5` | `#F8F7FF` | 11px | 600 | 2.58:1 | 4.5:1 | **FAIL** |
| Item count "5 items" | `#C7C7CC` | `#F8F7FF` | 11px | 400 | 1.58:1 | 4.5:1 | **FAIL** |
| Skin name "Classic" | `#9B8FF5` | `#FFFFFF` | 9px | 500 | 2.75:1 | 4.5:1 | **FAIL** |
| Skin name "Neon" (selected) | `#5B4FE8` | `#EDE9FF` | 9px | 600 | 4.75:1 | 4.5:1 | PASS |
| Skin names (Marble/Glass/Wood) | `#9B8FF5` | `#FFFFFF` | 9px | 500 | 2.75:1 | 4.5:1 | **FAIL** |
| Section label "GRID THEMES" | `#9B8FF5` | `#F8F7FF` | 11px | 600 | 2.58:1 | 4.5:1 | **FAIL** |
| Item count "3 items" | `#C7C7CC` | `#F8F7FF` | 11px | 400 | 1.58:1 | 4.5:1 | **FAIL** |
| Theme "Light" (green check) | `#34C759` | `#FFFFFF` | 10px | 500 | 2.22:1 | 4.5:1 | **FAIL** |
| Theme "Dark $1.99" | `#9B8FF5` | `#FFFFFF` | 10px | 500 | 2.75:1 | 4.5:1 | **FAIL** |
| Theme "OLED $1.99" | `#9B8FF5` | `#FFFFFF` | 10px | 500 | 2.75:1 | 4.5:1 | **FAIL** |
| Section label "SOUND PACKS" | `#9B8FF5` | `#F8F7FF` | 11px | 600 | 2.58:1 | 4.5:1 | **FAIL** |
| Item count "2 items" | `#C7C7CC` | `#F8F7FF` | 11px | 400 | 1.58:1 | 4.5:1 | **FAIL** |
| Sound name "Chimes" | `#0F0E1A` | `#FFFFFF` | 14px | 600 | 19.12:1 | 4.5:1 | PASS |
| "Default" (green check) | `#34C759` | `#FFFFFF` | 11px | 400 | 2.22:1 | 4.5:1 | **FAIL** |
| Sound name "Nature" | `#0F0E1A` | `#FFFFFF` | 14px | 600 | 19.12:1 | 4.5:1 | PASS |
| Sound price "$0.99" | `#9B8FF5` | `#FFFFFF` | 11px | 400 | 2.75:1 | 4.5:1 | **FAIL** |
| "Buy" button | `#5B4FE8` | `#EDE9FF` | 12px | 700 | 4.75:1 | 4.5:1 | PASS |
| Tab labels inactive | `#9B8FF5` | `#FFFFFF` | 10px | 600 | 2.75:1 | 4.5:1 | **FAIL** |

**Cosmetics Shop failures: 16 of 26 (62%) — worst screen**

### Recommended Fixes — Cosmetics Shop

| Element | Current | Fix |
|---------|---------|-----|
| All section labels (LIVE PREVIEW, TILE SKINS, GRID THEMES, SOUND PACKS) | `#9B8FF5` 11px | Change to `#6B5CE7` |
| All item counts (5 items, 3 items, 2 items) | `#C7C7CC` 11px | Change to `#767680` |
| Skin names (Classic, Marble, Glass, Wood) | `#9B8FF5` **9px** | Change to `#6B5CE7` and **increase to 11px** |
| Preview subtitle "Tile Skin - $0.99" | `#9B8FF5` 12px | Change to `#6B5CE7` |
| Theme labels (Light, Dark, OLED) | `#9B8FF5` / `#34C759` **10px** | Darken colors, **increase to 11px** |
| Green check text ("Light", "Default") | `#34C759` | Change to `#248A3D` (Apple accessible green) |
| Sound price "$0.99" | `#9B8FF5` 11px | Change to `#6B5CE7` |
| Inactive tab labels | `#9B8FF5` 10px | Change to `#6B5CE7` |

---

## Tap Target Assessment

| Element | Measured Size | Minimum (44x44pt) | Result |
|---------|---------------|-------------------|--------|
| Back chevron (nav bar) | 24x24 icon in 52px-high bar | Icon small, but bar is tappable | **WARNING** — icon itself is 24x24, ensure hit area is 44x44 |
| Share icon (nav bar) | 22x22 icon | Same as above | **WARNING** |
| Play button | 353x48 | Well above minimum | PASS |
| Tab bar items | ~85x62 each | Above minimum | PASS |
| Leaderboard rows | 361x60 each | Above minimum | PASS |
| Skin tiles | 72x80 each | Above minimum | PASS |
| Sound pack rows | 361x72 each | Above minimum | PASS |
| Equip button | ~100x36 (padding 8,20) | Height may be under 44pt | **WARNING** — increase padding to at least [12,20] |
| Buy button | ~50x30 (padding 6,10) | Below 44x44 | **FAIL** — increase to [12,16] minimum |
| Upgrade button (Pro banner) | ~80x34 (padding 6,12) | Below 44pt height | **FAIL** — increase padding |
| Leaderboard tab pills | ~100x36 | Below 44pt height | **WARNING** |

---

## Spacing and Layout Issues

1. **Puzzle Card** — uses absolute positioning (`layout: none`) for internal elements. Grid preview, axis, puzzle meta, and play button are manually positioned. This works visually but risks overlap on different screen sizes.

2. **Countdown colons** — decorative but effectively invisible at 1.68:1 contrast. Either darken or remove.

3. **Stats row** — stat labels at 10px are both too small and too low contrast. Double failure makes these effectively unreadable for many users.

4. **Skin labels at 9px** — below Apple's minimum caption size (11pt). These are functional labels users need to read to make purchase decisions.

---

## Systematic Color Replacements Needed

These are the minimum changes to pass WCAG AA:

### 1. Light Purple Secondary Text: `#9B8FF5` (2.58-2.75:1)

**Replace with:** `#6B5CE7` on white backgrounds, `#5B4FE8` on `#EDE9FF` backgrounds

| Context | Current Ratio | New Color | New Ratio |
|---------|--------------|-----------|-----------|
| On `#FFFFFF` | 2.75:1 | `#6B5CE7` | ~4.6:1 |
| On `#F8F7FF` | 2.58:1 | `#6B5CE7` | ~4.5:1 |
| On `#EDE9FF` | 2.32:1 | `#5B4FE8` | 4.75:1 |

### 2. Light Gray Tertiary Text: `#C7C7CC` (1.58-1.68:1)

**Replace with:** `#767680`

| Context | Current Ratio | New Color | New Ratio |
|---------|--------------|-----------|-----------|
| On `#FFFFFF` | 1.68:1 | `#767680` | ~4.6:1 |
| On `#F8F7FF` | 1.58:1 | `#767680` | ~4.3:1 |

### 3. Green Success/Check Text: `#34C759` (2.22:1)

**Replace with:** `#248A3D` (Apple's system green, accessible variant)

| Context | Current Ratio | New Color | New Ratio |
|---------|--------------|-----------|-----------|
| On `#FFFFFF` | 2.22:1 | `#248A3D` | ~4.6:1 |

### 4. Gold/Orange Rank and Badge Text: `#F5A623` (1.71-2.03:1)

**Replace with:** `#996515` for text on light backgrounds

| Context | Current Ratio | New Color | New Ratio |
|---------|--------------|-----------|-----------|
| On `#FFFFFF` | 2.03:1 | `#996515` | ~4.5:1 |
| On `#EDE9FF` | 1.71:1 | `#8B6914` | ~4.5:1 |

### 5. Date Card Light Purple: `#B8B0F5` on `#5B4FE8` (2.83:1)

**Replace with:** `#FFFFFF` at 80% opacity or `#E0DBFF`

---

## Font Size Fixes Required

| Current Size | Elements Affected | Minimum Fix |
|-------------|-------------------|-------------|
| **9px** | Skin names (Classic, Marble, Glass, Wood, Neon) | **11px** minimum |
| **10px** | Tab labels, stat labels, countdown units, theme labels | **11px** minimum |

---

## Priority Action Items

### P0 — Must Fix Before Resubmission

1. **Darken `#9B8FF5` to `#6B5CE7`** across all screens for secondary text (20 failures fixed)
2. **Darken `#C7C7CC` to `#767680`** for all tertiary/hint text (4 failures fixed)
3. **Darken `#34C759` to `#248A3D`** for green success text (3 failures fixed)
4. **Darken `#F5A623` to `#996515`** for gold rank/badge text (2 failures fixed)
5. **Increase 9px skin labels to 11px** (Cosmetics Shop)
6. **Increase 10px labels to 11px** where they carry functional meaning
7. **Fix date card text** contrast on purple background

### P1 — Should Fix

8. **Increase Buy/Upgrade button tap targets** to 44pt minimum height
9. **Ensure nav bar icon hit areas** are at least 44x44pt
10. **Darken countdown colons** or make them decorative (aria-hidden equivalent)

### P2 — Nice to Have

11. Consider increasing all body text to minimum 14px for better readability
12. Add Dynamic Type support in implementation
13. Ensure all interactive elements have visible focus indicators

---

## Summary Stats

| Metric | Value |
|--------|-------|
| Total text elements checked | 63 |
| Passing WCAG AA | 32 (51%) |
| Failing WCAG AA | 31 (49%) |
| Worst screen | Cosmetics Shop (62% failure rate) |
| Best screen | Leaderboard (41% failure rate) |
| Unique failing colors | 4 (`#9B8FF5`, `#C7C7CC`, `#34C759`, `#F5A623`) |
| Text elements below 11px | 15 |
| Tap targets below 44pt | 2-3 |
