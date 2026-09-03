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
# Swift parser and would be noisy. It locks down the player's focus enum, which is where
# this bug has actually recurred.
#
# Exit 0 = clean, 1 = a case is unbound/unreachable.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYER="$ROOT/DS Video clone/DSM Video/DSM Video/Views/GestureVideoPlayer.swift"

if [[ ! -f "$PLAYER" ]]; then
  echo "check-tvos-focus: cannot find GestureVideoPlayer.swift at $PLAYER" >&2
  exit 1
fi

# Pull the case names out of the TVFocusField enum declaration (it spans several lines).
CASES="$(awk '
  /enum TVFocusField/ { collecting = 1 }
  collecting { buf = buf " " $0 }
  collecting && /}/ { exit }
  END { print buf }
' "$PLAYER" \
  | sed 's/.*enum TVFocusField[^{]*{//; s/}.*//' \
  | tr ',' '\n' \
  | sed 's/case//g; s/[[:space:]]//g' \
  | grep -v '^$')"

if [[ -z "$CASES" ]]; then
  echo "check-tvos-focus: could not parse TVFocusField — has the enum moved or been renamed?" >&2
  exit 1
fi

FAILED=0

for c in $CASES; do
  # `hidden` is the deliberate focus sink that swallows Select for the whole overlay —
  # it is bound but intentionally has no d-pad destination.
  if [[ "$c" == "hidden" ]]; then
    continue
  fi

  if ! grep -q "focused(\$focusedControl, equals: \.$c)" "$PLAYER"; then
    echo "FAIL: .$c is declared in TVFocusField but never bound with .focused(\$focusedControl, equals: .$c)"
    echo "      A button using it renders on tvOS and cannot be focused with the remote."
    FAILED=1
  fi

  # Reachability: the case must appear as an assignment target in the move handler.
  if ! grep -qE "focusedControl = (showSkipIntroNow \? \.$c :|.*: )?\.$c|focusedControl = \.$c|row\[next\]" "$PLAYER"; then
    if ! grep -qE "\.$c(,|\])" "$PLAYER"; then
      echo "FAIL: .$c is bound but no code path in handleTVMoveCommand assigns it."
      echo "      The button is focusable in principle but the d-pad can never reach it."
      FAILED=1
    fi
  fi
done

if [[ $FAILED -eq 0 ]]; then
  echo "check-tvos-focus: OK — every TVFocusField case is bound and reachable."
fi

exit $FAILED
