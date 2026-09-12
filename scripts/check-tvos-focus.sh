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
#   1. Every case in TVFocusField is bound via .focused(..., equals: .case)
#   2. Every case is a destination in handleTVMoveCommand (reachable by the d-pad)
#   3. No case is declared and then never mentioned again (the .skipIntro failure)
#
# It deliberately does NOT try to parse every Button in every view — that needs a real
# Swift parser and would be noisy. It locks down the FOCUS ENUMS, which is where this bug
# has actually recurred.
#
# SCOPE (widened 2026-09-11 after recurrence #5)
# ----------------------------------------------
# Checking only the player was not enough. Recurrence #5 was ItemDetailView's "Next Episode"
# button: the view already had an ActionButton focus enum with four bound cases, and the new
# button simply was not added to it — outside this guard's scope, so CI passed. Every file
# below is now checked, and PART 2 additionally verifies that each file's bound-case count
# keeps pace with the number of .buttonStyle(.plain) buttons it compiles into tvOS.
#
# Exit 0 = clean, 1 = a case is unbound/unreachable.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEWS="$ROOT/DS Video clone/DSM Video/DSM Video/Views"
PLAYER="$VIEWS/GestureVideoPlayer.swift"

# Each entry: <file>|<enum name>|<@FocusState property>
# Add a row whenever a tvOS-facing view grows its own focus enum.
TARGETS=(
  "$PLAYER|TVFocusField|focusedControl"
  "$VIEWS/ItemDetailView.swift|ActionButton|focusedAction"
  "$VIEWS/ItemDetailView.swift|OverlayButton|focused"
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
  PROP="${REST#*|}"
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

    if ! grep -q "focused(\$$PROP, equals: \.$c)" "$FILE"; then
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

# ── PART 2: no tvOS .plain button left unbound ──────────────────────────────────
# The recurrence-#5 shape: the enum is fine and every case is bound, but a NEW button was
# added with .buttonStyle(.plain) and never given a case. Counting is crude but it is the
# only check that fails when the omission is the button rather than the enum — which is how
# this bug has actually shipped. A button inside a List/Form gets focus from its container,
# so a mismatch is a prompt to look, not proof of a defect.
for entry in "${TARGETS[@]}"; do
  FILE="${entry%%|*}"
  REST="${entry#*|}"
  ENUM="${REST%%|*}"
  PROP="${REST#*|}"
  SHORT="$(basename "$FILE")"
  [[ -f "$FILE" ]] || continue
  # Only one report per file even when it holds several enums.
  [[ "$ENUM" == "OverlayButton" ]] && continue

  PLAIN_COUNT="$(grep -c 'buttonStyle(\.plain)' "$FILE" || true)"
  BOUND_COUNT="$(grep -cE '\.focused\(\$' "$FILE" || true)"

  if (( PLAIN_COUNT > BOUND_COUNT )); then
    echo "NOTE: $SHORT has $PLAIN_COUNT .buttonStyle(.plain) button(s) but only $BOUND_COUNT .focused() binding(s)."
    echo "      Confirm every tvOS-rendered one is either bound to a focus case or inside a"
    echo "      List/Form that grants focus. An unbound .plain button on tvOS is invisible to"
    echo "      the remote. This is a WARNING, not a failure."
  fi
done

if [[ $FAILED -eq 0 ]]; then
  echo "check-tvos-focus: OK — every focus case is bound and reachable."
fi

exit $FAILED
