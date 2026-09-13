# R5 — Checks Friday ran directly (alongside the adversarial agent)

## CONFIRMED CLEAN — recorded so a clean check is distinguishable from an unattempted one

### SQL injection via LocalStore — CLEAN, verified
LocalStore uses raw SQLite (`sqlite3_prepare_v2`), which is the highest-value injection target in the
app. Checked every query:
- 21 `sqlite3_prepare_v2` calls, 35 `sqlite3_bind_*` calls. Every value-carrying query uses `?`
  placeholders.
- The ONLY string interpolation inside a SQL literal is `\(Self.itemSelectColumns)` (4 sites), which
  is a compile-time `static let` column list — not user input, not server input.
- No `LIKE` and no search query in LocalStore at all: search is a server round-trip, so no
  user-typed string ever reaches SQLite.
VERDICT: no injection surface. Not a finding.

### Locale decimal separator in URL query params — CLEAN, and I was WRONG to suspect it
`APIClient.swift:192-193` builds `start` and `subtitleOffset` query params with
`String(format: "%.3f", …)`, and the Go server parses them with `strconv.ParseFloat`, which is
locale-independent and REQUIRES a `.` separator. `clampStartSeconds` (main.go:5233) returns 0 on a
parse error — so if the client ever emitted `1234,500`, every mid-file resume in a comma-decimal
locale would silently restart from the beginning.

I expected that to be a P1 and tested it instead of filing it:
```
String(format:) under de_DE -> 1234.500
String(format:) under C     -> 1234.500
```
Swift's `String(format:)` with no explicit `locale:` argument uses the POSIX locale, NOT
`Locale.current`, so it always emits `.`. `setlocale()` does not affect it. The contract holds.
VERDICT: not a defect. Worth a regression test anyway, because the failure mode is severe and the
protection is implicit — if anyone ever "improves" these to `.formatted()` or adds
`locale: .current`, every comma-decimal locale breaks with no compiler warning.

### ISO8601 date handling — CLEAN
`ISO8601DateFormatter` is locale- and calendar-independent by construction. AppState keeps TWO
instances (`homeRailsFormatterFrac` with `.withFractionalSeconds`, and a plain one), so the
with/without-fractional-seconds server variance is already handled deliberately.

## FINDING — P3 · DiagnosticLog export uses the user's calendar
`DiagnosticLog.exportText()` (DiagnosticLog.swift:166) creates a `DateFormatter`, sets a fixed
`dateFormat = "yyyy-MM-dd HH:mm:ss"`, and never sets `locale` or `calendar`. A `DateFormatter` with a
fixed format string but no explicit locale still follows the user's locale and CALENDAR — so under a
Japanese or Buddhist calendar the exported diagnostic log carries dates like `0008-09-12` or
`2569-09-12`.

Impact is contained: this is the share/export path of the diagnostics screen, not user-facing content.
But the whole point of that export is that Ryan can read a photographed log and know WHEN something
happened, and a log whose year is wrong by 2,000 is actively misleading during a support diagnosis.

FIX: `fmt.locale = Locale(identifier: "en_US_POSIX")` — one line, the standard fix for a
fixed-format DateFormatter.
SEVERITY: P3 (diagnostic-only, no user data affected).
