# R6 — Harness incident, and what it invalidated

Recorded because a mutation census is only worth the trust you can place in its numbers, and this
run produced five numbers that were wrong.

## What happened

Re-running the census to verify the R4 tests, five T-A mutations reported **KILLED** in 4-5 seconds.
A clean run of the 148-test suite takes ~24s. That gap was the tell.

Investigated rather than banked the result: all five were **compile failures**, 91 errors each, every
one `type 'LocalStore' has no member 'makeForTesting'`.

Root cause, entirely mine: the harness reverted mutations with

    git checkout -- "DS Video clone/DSM Video/DSM Video"

which restores EVERY uncommitted change under that directory. The R4 agent's test seams
(`LocalStore.makeForTesting`, `DownloadManager.init(containerForTesting:)`, the HTTP-gate extraction)
were uncommitted work in that tree. My first revert deleted them, leaving its 43 new tests referencing
symbols that no longer existed. From then on every run failed to build, and the harness read a non-zero
exit as a dead mutation.

## What this invalidated

The five "KILLED" results in `r6-A.log` and `r6-B.log` for M5-upsert, M6-delitems, M1-clearall,
M1-delete-dl and M5-resume are **void**. Not pessimistic, not optimistic — meaningless. They measured
whether the project compiles without the seams.

The earlier **R2 census is unaffected** and stands: it ran before the agent existed, against a clean
committed tree, and its four kills each took 35-64s. The 9-survivor diagnosis is intact.

## The fix

Two changes, both in the harness:

1. **Revert one file, not a directory.** A mutation touches exactly one file by construction, so
   narrowing the revert costs nothing and cannot collateral-damage concurrent work.
2. **A build failure is never a kill.** `run_suite` now returns `BUILD_FAILED` when the output carries
   compiler errors and no test suite ran. That is reported as its own verdict. Conflating "the code
   does not compile" with "a test noticed the behavior break" is the precise error that produced five
   false positives here.

## The general lesson

A 2-second kill, earlier in this same session, was also a compile failure (`M1-clearall`, bare `return`
injected into a void function). I caught that one and noted "a 2-second kill is always suspect" — then
hit the identical class of error again from a different cause, because I had fixed the *instance* and
not added the *guard*. The harness now enforces it.

Timing is the cheapest signal available that a mutation result is lying. Any kill materially faster
than a clean run deserves investigation before it is believed.
