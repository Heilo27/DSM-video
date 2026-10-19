#!/bin/bash
# check-tvos-focus.sh — guard against the recurring tvOS "rendered but unreachable" bug.
#
# WHY THIS EXISTS
# ---------------
# Four separate times, a Button that compiles into the tvOS target has shipped with no way
# to focus it. It renders, it looks live, and the Siri Remote can never reach it. The
# simulator does not reproduce it, so it only surfaces on a real Apple TV.
#
# Written rules did not hold: the last fix ADDED a `.skipIntro` focus case and never bound
# it to the button, so the enum grew a case that satisfied nothing. This checks mechanically
# instead.
#
# WHAT IT CHECKS
#   PART 1 (focus enums)
#     1. Every case in each listed focus enum is bound via .focused(..., equals: .case)
#     2. For the player, every case is a destination in handleTVMoveCommand (d-pad reachable)
#     3. No case is declared and then never mentioned again (the .skipIntro failure)
#   PART 2 (every Button, exactly)
#     Every `Button` that compiles into the tvOS target and carries a CUSTOM look
#     (dsPrimaryButton, dsSecondaryButton, dsPlainButton, .buttonStyle(.plain) or any non-system style, .background, .overlay)
#     must be bound with .focused(...). A custom look replaces the system focus effect, so an
#     unbound one renders and can never be reached by the Siri Remote. It fails the run; it is
#     not a count heuristic.
#
# HOW PART 2 DECIDES WHAT RENDERS ON tvOS
#   * It reads `#if os(tvOS)` / `#if os(iOS)` / `#if !os(tvOS)` / `#else` regions, so a button
#     inside an iOS-only branch is not checked.
#   * IOS_ONLY (inside the analyzer) lists files that compile into the tvOS target but are only
#     ever built on iOS, each with the reason (ContentView builds only TVMainView on tvOS). The
#     analyzer also fails if a type declared in such a file is used by a tvOS-compiled line
#     elsewhere, so the list cannot go stale quietly.
#   * A button that is intentionally not bound carries `// focus-exempt: <reason>` on the lines
#     directly above it, or inside its modifier chain. Valid reasons: a List/Form row (the list
#     grants focus), an iOS-only helper view, a helper whose callers bind it. "Forgot" is not one.
#   * System-styled buttons (.bordered, .borderedProminent, .borderless, .automatic, .card,
#     .glass) keep the system focus effect and are outside the rule.
#   PART 3 (the white platter, TASK-1060)
#     `.buttonStyle(.plain)` on tvOS draws the system focus platter, a white slab behind the
#     focused control, and `.focusEffectDisabled()` does not remove it. Any `.buttonStyle(.plain)`
#     on a line that compiles into tvOS fails unless it carries `// plain-exempt: <reason>` on
#     the same line or in the comment block directly above. Use `.dsPlainButton()` instead
#     (App/CinematicChrome.swift): it is the one pressable style on tvOS and `.plain` elsewhere.
#     Valid reasons: a zero-size focus sink that draws nothing, a List row whose platter is the
#     intended focus treatment. "It looked fine in the simulator" is not one.
#   The analyzer tests itself against small embedded fixtures first, so a broken analyzer fails
#   loudly instead of passing everything.
#
# SCOPE HISTORY (widened 2026-09-11 after recurrence #5)
# ------------------------------------------------------
# Checking only the player was not enough. Recurrence #5 was ItemDetailView's "Next Episode"
# button: the view already had an ActionButton focus enum with four bound cases, and the new
# button simply was not added to it, outside this guard's scope, so CI passed. PART 2 used to
# compare a count of .buttonStyle(.plain) against a count of .focused() and print a NOTE nobody
# could act on (16 vs 12 in the player, mostly noise). It now inspects each button.
#
# Exit 0 = clean, 1 = a case is unbound/unreachable or a tvOS button has no focus binding.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$ROOT/DS Video clone/DSM Video/DSM Video"
VIEWS="$SOURCES/Views"
PLAYER="$VIEWS/GestureVideoPlayer.swift"

# Each entry: <file>|<enum name>|<@FocusState property>[|<bind file>|<bind property>]
# Add a row whenever a tvOS-facing view grows its own focus enum.
# The optional last two fields name a SECOND file whose buttons also bind cases of the enum, through
# a FocusState.Binding parameter of that name (TASK-1066: ProfileEditorActions.swift draws the
# editor's Save/Cancel/Delete/PIN buttons and binds them with `.focused(focus, equals: .save)`).
# A case counts as bound if EITHER file binds it; an unbound case still fails.
TARGETS=(
  "$PLAYER|TVFocusField|focusedControl"
  "$VIEWS/ItemDetailView.swift|ActionButton|focusedAction"
  "$VIEWS/ItemDetailView.swift|OverlayButton|focused"
  "$VIEWS/ProfileViews.swift|PinPadKey|focusedKey"
  "$VIEWS/ProfileViews.swift|EditorControl|focusedControl|$VIEWS/ProfileEditorActions.swift|focus"
  "$VIEWS/ProfileViews.swift|OwnerPinResetControl|focusedField"
  "$VIEWS/CollectionViews.swift|CollectionControl|focusedControl"
  "$VIEWS/ProfileViews.swift|PickerControl|focusedControl"
  "$VIEWS/ProfileViews.swift|ManageControl|focusedControl"
  "$VIEWS/TVPairingView.swift|PairingControl|control"
  "$VIEWS/TVMainView.swift|HomeControl|homeControl"
  "$VIEWS/TVShowsView.swift|ShowsControl|control"
  "$VIEWS/ServerUpdateNoticeViews.swift|ServerUpdateControl|control"
)

if [[ ! -f "$PLAYER" ]]; then
  echo "check-tvos-focus: cannot find GestureVideoPlayer.swift at $PLAYER" >&2
  exit 1
fi

# Pull the case names out of an enum declaration that may span several lines.
parse_cases() {
  local file="$1" enum="$2"
  awk -v want="enum $enum" '
    index($0, want) { collecting = 1 }
    collecting { buf = buf " " $0 }
    collecting && /}/ { exit }
    END { print buf }
  ' "$file" \
    | sed "s/.*enum $enum[^{]*{//; s/}.*//" \
    | tr ',' '\n' \
    | sed 's/case//g; s/[[:space:]]//g' \
    | grep -v '^$'
}

FAILED=0

# ── PART 1: every declared case is bound, and (for the player) d-pad reachable ──
for entry in "${TARGETS[@]}"; do
  FILE="${entry%%|*}"
  REST="${entry#*|}"
  ENUM="${REST%%|*}"
  REST="${REST#*|}"
  PROP="${REST%%|*}"
  BIND_FILE=""
  BIND_PROP=""
  if [[ "$REST" == *"|"* ]]; then
    REST="${REST#*|}"
    BIND_FILE="${REST%%|*}"
    BIND_PROP="${REST#*|}"
    if [[ ! -f "$BIND_FILE" ]]; then
      echo "FAIL: $(basename "$BIND_FILE") not found at $BIND_FILE — has it moved?"
      FAILED=1
      continue
    fi
  fi
  SHORT="$(basename "$FILE")"

  if [[ ! -f "$FILE" ]]; then
    echo "FAIL: $SHORT not found at $FILE — has it moved?"
    FAILED=1
    continue
  fi

  CASES="$(parse_cases "$FILE" "$ENUM")"
  if [[ -z "$CASES" ]]; then
    echo "FAIL: could not parse $ENUM in $SHORT — has the enum been renamed or removed?"
    echo "      This guard is the only thing standing between a .plain tvOS button and a"
    echo "      control the remote can never reach. Fix the guard, do not delete the row."
    FAILED=1
    continue
  fi

  for c in $CASES; do
    # `hidden` is the deliberate focus sink that swallows Select for the whole overlay —
    # it is bound but intentionally has no d-pad destination.
    if [[ "$c" == "hidden" ]]; then
      continue
    fi

    if ! grep -q "focused(\$$PROP, equals: \.$c)" "$FILE" \
      && ! { [[ -n "$BIND_FILE" ]] && grep -q "focused($BIND_PROP, equals: \.$c)" "$BIND_FILE"; }; then
      echo "FAIL: $SHORT — .$c is declared in $ENUM but never bound with .focused(\$$PROP, equals: .$c)"
      echo "      A button using it renders on tvOS and cannot be focused with the remote."
      FAILED=1
    fi
  done

  # Reachability via the d-pad handler is only meaningful for the player, which drives focus
  # manually. The detail views rely on SwiftUI's own focus engine to move between siblings.
  if [[ "$FILE" == "$PLAYER" ]]; then
    for c in $CASES; do
      [[ "$c" == "hidden" ]] && continue
      if ! grep -qE "$PROP = (showSkipIntroNow \? \.$c :|.*: )?\.$c|$PROP = \.$c|row\[next\]" "$FILE"; then
        if ! grep -qE "\.$c(,|\])" "$FILE"; then
          echo "FAIL: $SHORT — .$c is bound but no code path in handleTVMoveCommand assigns it."
          echo "      The button is focusable in principle but the d-pad can never reach it."
          FAILED=1
        fi
      fi
    done
  fi
done

# ── PART 2: every custom-styled Button that renders on tvOS is bound ─────────────
# The analyzer is embedded so the script stays one self-contained file with no repo-relative
# imports. `python3 -I` ignores the environment and the current directory.
PY_OUT="$(python3 -I - "$SOURCES" <<'PYEOF'
import os, re, sys

# Files that compile into the tvOS target but are never built there. Reason is mandatory.
IOS_ONLY = {
    "MainView.swift": "iOS root; ContentView builds only TVMainView on tvOS",
    "ServerSetupView.swift": "iOS sign-in; ContentView builds only TVMainView on tvOS",
    "LibrariesView.swift": "iOS tab content, reached only through MainView",
    "HomeHero.swift": "iOS home hero, reached only through LibrariesView",
}

# Styles that keep the system focus effect.
SYSTEM_STYLES = (".bordered", ".borderedProminent", ".borderless", ".automatic", ".card",
                 ".glass", ".glassProminent")

def blank(src):
    """src with comments and string contents replaced by spaces (newlines kept)."""
    out = []; i = 0; n = len(src)
    while i < n:
        c = src[i]; two = src[i:i+2]
        if two == '//':
            while i < n and src[i] != '\n':
                out.append(' '); i += 1
        elif two == '/*':
            depth = 1; out.append('  '); i += 2
            while i < n and depth:
                if src[i:i+2] == '/*': depth += 1; out.append('  '); i += 2
                elif src[i:i+2] == '*/': depth -= 1; out.append('  '); i += 2
                else: out.append('\n' if src[i] == '\n' else ' '); i += 1
        elif src[i:i+3] == '"""':
            out.append('"""'); i += 3
            while i < n and src[i:i+3] != '"""':
                out.append('\n' if src[i] == '\n' else ' '); i += 1
            out.append('"""'); i += 3
        elif c == '"':
            out.append('"'); i += 1
            while i < n and src[i] != '"' and src[i] != '\n':
                if src[i] == '\\' and i + 1 < n:
                    out.append('  '); i += 2; continue
                out.append(' '); i += 1
            if i < n and src[i] == '"':
                out.append('"'); i += 1
        else:
            out.append(c); i += 1
    return ''.join(out)

def cond_value(cond):
    """Does an `#if` condition hold when building for tvOS? Unknown terms count as true."""
    s = re.sub(r'os\(\s*tvOS\s*\)', ' True ', cond)
    s = re.sub(r'os\(\s*\w+\s*\)', ' False ', s)
    s = re.sub(r'canImport\([^)]*\)', ' True ', s)
    s = re.sub(r'\b(?!True\b|False\b)[A-Za-z_]\w*\b', ' True ', s)
    s = s.replace('!', ' not ').replace('&&', ' and ').replace('||', ' or ')
    if not re.fullmatch(r'(\s|True|False|not|and|or|\(|\))*', s):
        return True
    try:
        return bool(eval(s, {'__builtins__': {}}, {}))
    except Exception:
        return True

def tvos_lines(lines):
    """Per line: does it compile into tvOS?"""
    stack = []; flags = []
    for ln in lines:
        t = ln.strip()
        if t.startswith('#if '):
            v = cond_value(t[4:]); stack.append({'on': v, 'taken': v}); flags.append(False); continue
        if t.startswith('#elseif '):
            e = stack[-1]; v = (not e['taken']) and cond_value(t[8:])
            e['on'] = v; e['taken'] = e['taken'] or v; flags.append(False); continue
        if t == '#else':
            e = stack[-1]; e['on'] = not e['taken']; e['taken'] = True; flags.append(False); continue
        if t == '#endif':
            stack.pop(); flags.append(False); continue
        flags.append(all(e['on'] for e in stack))
    return flags

BUTTON = re.compile(r'(?<![A-Za-z0-9_.])Button\s*[({]')

def balanced_end(text, i):
    d = 0
    while i < len(text):
        ch = text[i]
        if ch in '({[': d += 1
        elif ch in ')}]':
            d -= 1
            if d == 0: return i + 1
        i += 1
    return i

def buttons(src):
    """Yield (line, header, chain_text, exempt) for each Button that compiles into tvOS.
    The chain is the Button, its closures, and the modifiers that follow it."""
    clean = blank(src); lines = clean.split('\n'); raw = src.split('\n')
    flags = tvos_lines(lines); n = len(clean); found = []
    for m in BUTTON.finditer(clean):
        ln0 = clean.count('\n', 0, m.start())
        i = balanced_end(clean, m.end() - 1)
        while True:
            j = i
            while j < n and clean[j] in ' \t': j += 1
            if j < n and clean[j] == '{':
                i = balanced_end(clean, j); continue
            lab = re.match(r'\s*label\s*:\s*\{', clean[i:i+40])
            if lab:
                i = balanced_end(clean, i + lab.end() - 1); continue
            break
        cur = clean.count('\n', 0, i); k = cur + 1
        while k < len(lines):
            t = lines[k].strip()
            if t.startswith('.'):
                d = 0; kk = k
                while kk < len(lines):
                    d += sum(lines[kk].count(c) for c in '({[') - sum(lines[kk].count(c) for c in ')}]')
                    if d <= 0: break
                    kk += 1
                k = kk + 1; continue
            if t.startswith(('#if', '#else', '#elseif', '#endif')) or (t == '' and raw[k].strip() != ''):
                k += 1; continue
            break
        last = cur; depth = 0
        for q in range(cur + 1, k):
            t = lines[q].strip()
            if t.startswith('#if'): depth += 1
            elif t.startswith('#endif'):
                if depth == 0: break
                depth -= 1
            last = q
        found.append((ln0, last, i))
    prev_end = -1
    for ln0, last, close in found:
        lo = max(ln0 - 3, prev_end + 1)
        prev_end = last
        if not flags[ln0]:
            continue
        # Modifiers only: what is INSIDE the label (a .background on its HStack) is not the style.
        cur_end = clean.find('\n', close); cur_end = n if cur_end < 0 else cur_end
        cur = clean.count('\n', 0, close)
        chain = clean[close:cur_end] + '\n' + '\n'.join(lines[q] for q in range(cur + 1, last + 1) if flags[q])
        around = '\n'.join(raw[lo:last + 1])
        yield ln0 + 1, raw[ln0].strip(), chain, 'focus-exempt:' in around

def custom_look(chain):
    if 'dsPrimaryButton' in chain or 'dsSecondaryButton' in chain or 'dsPlainButton' in chain or '.background(' in chain or '.overlay(' in chain:
        return True
    for m in re.finditer(r'\.buttonStyle\(\s*([^)\n]*)', chain):
        if m.group(1).strip() not in SYSTEM_STYLES:
            return True
    return False

def unbound(src):
    """([(line, header)], bound, exempt): tvOS Buttons with a custom look and no .focused or exemption."""
    out = []; exempt = 0; bound = 0
    for line, head, chain, ex in buttons(src):
        if not custom_look(chain): continue
        if '.focused(' in chain: bound += 1
        elif ex: exempt += 1
        else: out.append((line, head))
    return out, bound, exempt

PLAIN = re.compile(r'\.buttonStyle\(\s*\.plain\s*\)')

def plain_sites(src):
    """[(line, text)] of `.buttonStyle(.plain)` that compile into tvOS with no plain-exempt marker."""
    clean = blank(src); lines = clean.split('\n'); raw = src.split('\n'); flags = tvos_lines(lines)
    out = []
    for i, l in enumerate(lines):
        if not flags[i] or not PLAIN.search(l): continue
        if 'plain-exempt:' in raw[i]: continue
        k = i - 1; marked = False
        while k >= 0 and raw[k].strip().startswith('//'):
            if 'plain-exempt:' in raw[k]: marked = True; break
            k -= 1
        if not marked: out.append((i + 1, raw[i].strip()))
    return out

# The analyzer proves itself on fixtures before it is trusted with the app.
FIXTURES = [
    ("unbound plain button on tvOS is flagged", 1, """
#if os(tvOS)
Button(action: go) { Text("x") }
  .buttonStyle(.plain)
#endif
"""),
    ("bound button passes", 0, """
Button("x") { go() }
  .buttonStyle(.plain)
  .focused($f, equals: .a)
"""),
    ("iOS-only region is skipped", 0, """
#if os(iOS)
Button("x") { go() }
  .buttonStyle(.plain)
#endif
"""),
    ("#else of an iOS-only #if is tvOS and is checked", 1, """
#if os(iOS)
Text("x")
#else
Button("x") { go() }
  .dsPrimaryButton()
#endif
"""),
    ("exemption comment passes", 0, """
// focus-exempt: List row, the list grants focus
Button("x") { go() }
  .buttonStyle(.plain)
"""),
    ("an exemption does not leak onto the next button", 1, """
// focus-exempt: List row
Button("a") { go() }
  .buttonStyle(.plain)
Button("b") { go() }
  .buttonStyle(.plain)
"""),
    ("system-styled button is outside the rule", 0, """
Button("x") { go() }
  .buttonStyle(.borderedProminent)
"""),
    ("a Button in a comment or string is ignored", 0, """
// Button("x") { go() }.buttonStyle(.plain)
let s = "Button(x).buttonStyle(.plain)"
"""),
    ("dsPrimaryButton without a binding is flagged", 1, """
Button { go() } label: { Text("x") }
  .dsPrimaryButton()
"""),
    ("dsSecondaryButton without a binding is flagged", 1, """
Button { go() } label: { Text("x") }
  .dsSecondaryButton()
"""),
    ("dsPlainButton without a binding is flagged", 1, """
Button { go() } label: { Text("x") }
  .dsPlainButton()
"""),
    ("dsSecondaryButton with a binding passes", 0, """
Button { go() } label: { Text("x") }
  .dsSecondaryButton(minWidth: 200)
  .focused($f, equals: .a)
"""),
]
for name, want, src in FIXTURES:
    got = len(unbound(src)[0])
    if got != want:
        print(f"FAIL: analyzer self-test '{name}': expected {want} unbound, got {got}. "
              "Fix the analyzer before trusting any result from it.")
        sys.exit(2)

PLAIN_FIXTURES = [
    ("plain on tvOS is flagged", 1, """
Button("x") { go() }
  .buttonStyle(.plain)
"""),
    ("plain in an iOS-only region is skipped", 0, """
#if os(iOS)
Button("x") { go() }
  .buttonStyle(.plain)
#endif
"""),
    ("plain-exempt on the same line passes", 0, """
Button("x") { go() }
  .buttonStyle(.plain) // plain-exempt: draws nothing
"""),
    ("plain-exempt in the comment block above passes", 0, """
Button("x") { go() }
  // plain-exempt: List row
  // second line of the reason
  .buttonStyle(.plain)
"""),
    ("plain-exempt does not leak across code", 1, """
Button("a") { go() }
  // plain-exempt: first only
  .buttonStyle(.plain)
Button("b") { go() }
  .buttonStyle(.plain)
"""),
    ("plain in a comment is ignored", 0, """
// use .buttonStyle(.plain) here
"""),
    ("dsPlainButton is not flagged", 0, """
Button("x") { go() }
  .dsPlainButton()
"""),
]
for name, want, src in PLAIN_FIXTURES:
    got = len(plain_sites(src))
    if got != want:
        print(f"FAIL: analyzer self-test '{name}': expected {want} plain sites, got {got}. "
              "Fix the analyzer before trusting any result from it.")
        sys.exit(2)

root = sys.argv[1]
paths = []
for d, _, fs in os.walk(root):
    for f in fs:
        if f.endswith('.swift'): paths.append(os.path.join(d, f))
paths.sort()
texts = {p: open(p, encoding='utf-8').read() for p in paths}
failed = 0

# An IOS_ONLY entry is only honest while nothing that renders on tvOS uses its types.
for fname, reason in IOS_ONLY.items():
    mine = [p for p in paths if os.path.basename(p) == fname]
    if not mine:
        print(f"FAIL: IOS_ONLY lists {fname} but it is not in the sources; update the list.")
        failed += 1; continue
    names = set(re.findall(r'\b(?:struct|class|enum|actor)\s+([A-Z]\w*)', blank(texts[mine[0]])))
    for p in paths:
        if os.path.basename(p) in IOS_ONLY: continue
        lines = blank(texts[p]).split('\n'); fl = tvos_lines(lines)
        for i, l in enumerate(lines):
            if not fl[i]: continue
            for nm in names:
                if re.search(r'\b' + nm + r'\b', l):
                    print(f"FAIL: {os.path.basename(p)}:{i+1} uses {nm}, declared in {fname}, which "
                          f"IOS_ONLY says never renders on tvOS ({reason}). Move it off the list "
                          "and bind its buttons.")
                    failed += 1

total_bound = total_exempt = total_plain = 0
for p in paths:
    fname = os.path.basename(p)
    if fname in IOS_ONLY: continue
    bad, b, e = unbound(texts[p]); total_bound += b; total_exempt += e
    for line, head in plain_sites(texts[p]):
        print(f"FAIL: {fname}:{line} .buttonStyle(.plain) renders the white system focus platter on tvOS: {head[:60]}")
        print("      Use .dsPlainButton(), or mark it '// plain-exempt: <reason>'.")
        failed += 1
        total_plain += 1
    for line, head in bad:
        print(f"FAIL: {fname}:{line} renders on tvOS with a custom look but no .focused(...): {head[:70]}")
        print("      Bind it to this view's focus enum, or mark it '// focus-exempt: <reason>' if a")
        print("      List/Form grants its focus or it never renders on tvOS.")
        failed += 1
print(f"check-tvos-focus: buttons with a custom look: {total_bound} bound, {total_exempt} exempt (annotated); "
      f"{len(IOS_ONLY)} iOS-only files; {total_plain} unjustified .plain; {failed} failing")
sys.exit(1 if failed else 0)
PYEOF
)"
PY_STATUS=$?
echo "$PY_OUT"
if [[ $PY_STATUS -ne 0 ]]; then
  FAILED=1
fi

if [[ $FAILED -eq 0 ]]; then
  echo "check-tvos-focus: OK — every focus case is bound and reachable, and every tvOS button with a custom look is bound or justified."
fi

exit $FAILED
