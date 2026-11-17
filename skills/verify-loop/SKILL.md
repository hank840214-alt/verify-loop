---
name: verify-loop
description: "Verification workflow for people who direct coding agents but do not read code. Use when the user says verify, check this, is it done, set up guardrails, feature map, or after a mistake that should become a check. Modes: start (agree on 3-5 checkpoints), setup (audit a repo's guardrails), map (feature map + app driver), triage (turn a mistake into a check), done (evidence and risk-tiered review before handing over). Pick the mode from the conversation."
---

# verify-loop

Method: `${CLAUDE_PLUGIN_ROOT}/docs/METHOD.md`. Read it before the first use in a session.

Pick the mode from the conversation without asking: a multi-step task is starting → start; new repo or "set this up" → setup; "feature map" or no way to drive the app → map; a mistake just happened → triage; work is finishing → done.

**Evidence rule (all modes):** every "done" or "passes" carries the command plus the tail of its output, or an artifact path. No evidence, not done. Ask reviewers for the same.

## start — agree on checkpoints first
0. Deepen the task, don't widen it: what would a top professional do, where is the rawest data, which method, what result would prove it right. One line each.
1. Write 3–5 pass/fail checkpoints in feature-map words ("a new user sees the welcome screen within one second"), not implementation.
2. The user confirms or edits the list before work starts.
3. Turn each checkpoint into a failing test or verification step first, then write the code. A different agent from the fixer writes the test and commits it first; the fixer may not edit it. Tick each with evidence.
4. For long, overnight or unattended runs, keep `.scratch/decisions.tsv`: time | phase | decision | why | evidence | result. Append only. At the end, a **different** agent audits each row's evidence and writes the "needs your attention" section; the session that did the work does not write it.

## setup — audit a repo's guardrails
1. Read `AGENTS.md`/`CLAUDE.md`, the package manifest, CI workflows, `.claude/settings*.json`.
2. Output a table: item | current state (file:line) | gap | who fixes it. Check:
   - Tests run. **Before running**, read the test setup for steps that reset a database, deploy, send mail, call paid APIs or write into the repo. If found, run in a copy or a throwaway database, or only list the risk. Run twice; a test that changes result is flaky. Time it.
   - CI runs the same tests.
   - The Stop hook covers this repo (`~/.claude/stop-verify.projects.json`), its `code_re` includes every file type the tests read, and `limit` ≥ 1.5× the measured time and < 540 s. A verify command that touches a database must point at a throwaway one and check that it does.
   - Deny rules cover this project's secrets (including backup copies outside the repo). Sandbox on where possible; `excludedCommands` lists no agent launchers, `osascript *` or `docker *`.
   - Codex goes through `${CLAUDE_PLUGIN_ROOT}/tools/codex-dispatch.sh`.
   - Lint exists (missing lint is the first gap). Folder boundaries / import bans exist.
   - `AGENTS.md` permissions section, `DESIGN.md`, a feature map, a findings ledger.
   - Up to 3 state/timing flows or invariant-heavy algorithms as formal-verification candidates, and any existing `*.tla`/`*.lean`. List only.
3. Repo changes become work orders. Settings changes become a script the user runs (backup, validate, then replace, print the restore command).
4. Never edit a worktree that holds someone else's uncommitted work.

## map — feature map plus a driver for the real app
1. `plans/FEATURE-MAP.md`, one row per feature: fixed name (the user's word) | how to reach it from launch | what proves it works | the verify command.
2. One CLI in the repo (e.g. `tools/drive.mjs`; include a `doctor` command that confirms the running build is this commit and the services are up; screenshots must show which app and version; cleanup never deletes evidence) with at least `open <feature>`, `click --name <accessible name>`, `snapshot` (text view of the screen), `screenshot <file>`. Reuse existing QA scripts: pull the repeated launch/login steps into the driver and make old scripts call it.
3. Each feature gets at least one driver flow that saves a screenshot as evidence.
4. Refresh monthly, or when a mapped feature changes: walk every row for real. A row that fails gets a fixed map or a bug ticket, at most one PR per pass.

## triage — where a mistake or requirement belongs
Answer the five questions in `${CLAUDE_PLUGIN_ROOT}/docs/METHOD.md` §1 in order, one line of reasoning each. For "a machine can tell", walk the correction tree (redesign → type → lint with the fix in its message → test → app-driving step) and stop at the first rung that works. Lint exceptions need a reason, an expiry date and an approver. Tests check behaviour: they should survive a refactor of the internals. Prove the check fails on the real past mistake and passes without it; attach both outputs. State/timing bugs → a TLA+ model locked in as a repo check, with a statechart. Pure invariants → consider Lean. List any old text rule this replaces as "can delete", for the user to approve.

## done — before handing over
1. Commit, then run the checks through `${CLAUDE_PLUGIN_ROOT}/tools/verify-evidence.sh --tests-re '<test paths>' -- <verify command>`. Paste its output unchanged into the PR's Verification section; never write that section by hand. Red means not done. If it lists changed existing tests, another agent or the user must approve that part.
2. Produce artifacts: UI change → before/after screenshots or a short video; flow/state change → a statechart (rerun the model if one exists); bug fix → failing repro before, passing after. Name things by the feature map.
3. Blast radius, even for small changes: list callers and shared data (file:line), write "this is safe because ___", prove that one fact by running real code.
4. PR body, in order: Why | What changed | Scope | Tradeoffs | Blast radius | Verification (commands + output). Conventional Commits title. Never merge from here.
5. For UI or flow changes, a non-author agent drives the app like a user on the old and new build and gives a pass/fail verdict with screenshots; green CI and code review are not that verdict. Reviewers first check that the evidence SHA equals the PR head; if not, rerun. Merge only after the user or an independent reviewer approves that SHA. Review by risk tier, never by the session that wrote the code: docs → green checks; normal → one fresh reviewer (strong model or Codex read-only via the dispatch script); money/login/store/data deletion → both, plus a rollback or flag.
6. Each review finding gets one of: fix, dismiss with a concrete disproof, or ask the user. Never dismiss findings about auth, billing, data, migrations or concurrency. Settle P1/P2 before handing over. Append each finding to `plans/FINDINGS.md`: date | kind | one sentence | already has a check?
7. A kind of finding seen a second time → run triage and propose the check.
