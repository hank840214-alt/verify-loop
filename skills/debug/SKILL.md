---
name: debug
description: "One entry for debugging. Use when the user says debug, it's broken, why did this fail, it's slow, laggy, is this speedup real, or what could this change break. Decide the route yourself: ordinary bug, performance, state/timing (concurrent users, reconnects, races), or blast radius of a change."
---

# debug

Decide the route, state the reason in one line, do not ask.

| Situation | Route |
|---|---|
| A bug with a symptom you can reproduce | Ordinary debugging |
| Slow, laggy, or a performance number | Measure first; every before/after number passes the seven questions |
| Several devices or users at once, reconnects, schedules, payments; two failed repros and timing is suspected | Model it (TLA+) — see `${CLAUDE_PLUGIN_ROOT}/docs/METHOD.md` §1.3 |
| A fix exists; "what else could this break?" | Blast radius |

## Ordinary debugging
1. Restate the symptom in one line. Pin the target: repo, HEAD, uncommitted files.
2. Reproduce on the real code with the smallest script or test; print one decisive line. Cannot reproduce → report what you tried. Do not guess-fix.
3. Find the cause (file:line). Write the failing test first, then the smallest fix, then watch the test pass. If another session has uncommitted work in the same files, fix in an isolated copy and apply a patch.
4. Run the blast radius.
5. Same kind of bug a second time → `verify-loop` triage, to turn it into a check.
6. Hand over through `verify-loop` done.

## Blast radius
1. List callers and shared data the change touches (search for real; cite file:line).
2. Write the one fact: "this is safe because ___".
3. Prove that fact by running real code (command + output). Cannot prove it → list it as a risk; do not call it safe.

## Seven questions for any performance number
1. What is the bottleneck (CPU, network, disk, lock)?
2. Same setup before and after (machine, data size, warm or cold cache)?
3. Does it beat a physical limit? (Impossible numbers mean a broken measurement.)
4. Are errors being swallowed? (Faster because it did less.)
5. How many runs, and how much do they vary?
6. Would a user notice end to end?
7. Did the work actually happen (is the output right)?
