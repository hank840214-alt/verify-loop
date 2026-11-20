---
name: verify-loop
description: "Verification workflow for people who direct coding agents but do not read code. Use when the user says verify, check this, is it done, set up guardrails, feature map, or after a mistake that should become a check. Modes: start (set 3-5 checkpoints), setup (audit a repo's guardrails), map (feature map + app driver), triage (turn a mistake into a check), done (evidence and risk-tiered review before handing over). Pick the mode from the conversation."
---

# verify-loop

Method: `${CLAUDE_PLUGIN_ROOT}/docs/METHOD.md`. Read it before the first use in a session.

Pick the mode from the conversation without asking: a multi-step task is starting → start; new repo or "set this up" → setup; "feature map" or no way to drive the app → map; a mistake just happened or a review returned findings → triage; work is finishing or the user asks "is it done" → done.

**Evidence rule (all modes):** every "done" or "passes" carries the command plus the tail of its output, or an artifact path. No evidence, not done. Ask reviewers for the same.

**Risk tier first (start and done):** the first line of the reply names the tier and why. Unsure, or one task spans two tiers → use the higher one.
- Text: copy, docs, typos.
- Normal: features, screens, bug fixes.
- High risk: money, login, store submission, deleting data.

**When the project lacks something:** no feature map, driver, lint or findings ledger → follow the fallback written in the step. Do not stop, and do not report the step as done. In the report, add one "gap" line each: what is missing, which step ran in reduced form, what to run to close it. No second agent is available for a required review → hand over marked NOT REVIEWED; never review your own work to fill the slot.

## start — set checkpoints first
1. Write 3–5 pass/fail checkpoints ("a new user sees the welcome screen within one second"), not implementation. Use feature-map names; with no map, use the user's own words from the conversation.
2. Post the list to the user, then start; do not wait for a reply. Ask first only when a checkpoint contains a product decision the user has not made (whether a behaviour should exist, which of two features wins): ask once, and work on the unaffected parts meanwhile. If the user edits the list later, recheck the finished parts against the new list.
3. Turn each checkpoint into a failing test or verification step first, then write the code. For a normal change the implementer can add the test. An independent reviewer checks that it catches the original failure. For high-risk work, a different agent writes and commits the failing test before implementation. The reviewer checks the order in `git log`. Tick each with two outputs: the test failing before the fix and passing after.
4. For long, overnight or unattended runs, keep `.scratch/decisions.tsv`: time | phase | decision | why | evidence | result. Append only. At the end, a **different** agent audits each row's evidence and writes the "needs your attention" section; the session that did the work does not write it.

## setup — audit a repo's guardrails
1. Read `AGENTS.md`/`CLAUDE.md`, the package manifest, CI workflows, `.claude/settings*.json`.
2. Output a table: item | current state (file:line) | gap | who fixes it. List gaps in the adoption order of METHOD §5, with lint right after tests and CI. Check:
   - Tests run. **Before running**, read the test setup for steps that reset a database, deploy, send mail, call paid APIs or write into the repo. If found, run in a copy or a throwaway database, or only list the risk. Run twice; a test that changes result is flaky. Time it.
   - CI runs the same tests.
   - Lint exists (missing lint is the first gap). Folder boundaries / import bans exist.
   - The Stop hook covers this repo (`~/.claude/stop-verify.projects.json`, with `roots` listing the trusted checkout paths), its `code_re` includes every file type the tests read (`skip_re` excludes generated files and leftovers of killed runs; checks wait while agents run and happen at the next stop), and `limit` ≥ 1.5× the measured time and < 540 s. A verify command that touches a database must point at a throwaway one and check that it does.
   - Read this repo's rows in `~/.claude/state/stop-verify/ledger.tsv`: count the `block` rows, and how many were followed by a `pass` in the same checkout folder (third column), which suggests blocked, then fixed. If most blocks have no later pass, find why (flaky tests, leftover files, timeouts) and list it as a gap.
   - Deny rules cover this project's secrets (including backup copies outside the repo). Sandbox on where possible; `excludedCommands` lists no agent launchers, `osascript *` or `docker *`.
   - Codex goes through the `codex-dispatch.sh` wrapper at the stable path the user set up (see README); the bundled copy is `${CLAUDE_PLUGIN_ROOT}/tools/codex-dispatch.sh`.
   - `AGENTS.md` permissions section, `DESIGN.md`, a feature map, a findings ledger.
   - Up to 3 state/timing flows or invariant-heavy algorithms as formal-verification candidates, and any existing `*.tla`/`*.lean`. List only.
3. Repo changes become work orders. Settings changes become a script the user runs (backup, validate, then replace, print the restore command).
4. Never edit a worktree that holds someone else's uncommitted work.
5. Send the setup report to review at most twice. A finding about an agent deliberately bypassing a guard (rewording a command to dodge a match, committing before editing tests) goes in a "known limits" line; do not change the scripts for it. The local guard stops mistakes, not deliberate bypasses (METHOD §2); hard enforcement is CI plus branch protection, which is the user's decision.

## map — feature map plus a driver for the real app
1. `plans/FEATURE-MAP.md`, one row per feature: fixed name (the user's word) | how to reach it from launch | what proves it works | the verify command. The first version holds 3–5 features: the ones the user names most, plus any that broke recently. Find them in the repo (routes, menus, existing QA scripts); ask the user only what the repo cannot show.
2. One CLI in the repo (e.g. `tools/drive.mjs`; include a `doctor` command that confirms the running build is this commit and the services are up; screenshots must show which app and version; cleanup never deletes evidence) with at least `open <feature>`, `click --name <accessible name>`, `snapshot` (text view of the screen), `screenshot <file>`. Reuse existing QA scripts: pull the repeated launch/login steps into the driver and make old scripts call it.
3. Each mapped feature gets at least one driver flow that saves a screenshot as evidence. Drive the real user path, not internal setters or test-only entry points.
4. Before handing over, run one mapped feature end to end: launch → `doctor` → drive → screenshot → cleanup, and confirm the screenshot is still there after cleanup. A map and driver that were never run are a draft.
5. Growth: a task that changes a feature not on the map adds its row and one driver flow in the same task. Do not schedule a separate "map everything" task.
6. Refresh monthly, or when a mapped feature changes: walk every row for real. A row that fails gets a fixed map or a bug ticket, at most one PR per pass. If a flow fails because a precondition is missing (test account, seed data), note it on that row; never loosen the flow to make it pass.

## triage — where a mistake or requirement belongs
1. Answer the questions in `${CLAUDE_PLUGIN_ROOT}/docs/METHOD.md` §1 in order, one line of reasoning each. Fallbacks: the tree lands on lint and the project has none → this task installs the lint tool with this one rule only, not a preset (a preset reports thousands of old violations that nobody fixes). It lands on the feature map and there is none → write a rerunnable verification script in the repo and add a gap line.
2. Prove the new check: it fails on the real past mistake and passes without it. Attach both outputs.
3. List any old text rule this replaces as "can delete", for the user to approve.
4. Many findings at once (one review round): P1/P2, and any kind already in the ledger before this round, get steps 1–3 each. For the rest answer only METHOD §1 question 3 in one line: a machine can tell → build the check by the correction tree (several may share one task); it cannot → the ledger row is enough. Each finding gets one ledger row.
5. Monthly, you may also look for mistakes yourself: recent commits, reverts, review comments, and comments that explain a workaround. A kind counts only once it shows up twice; then handle it as step 4 says.

## done — before handing over
Tier first. Text tier does two things and skips steps 1–8: run the project's existing automatic checks (tests, lint, link check, whatever exists) until green and look at the changed content or its rendering; say what changed in one sentence.
Who does what: a dispatched worker does steps 1–4 and hands back "awaiting review" with the commit SHA; the party that dispatched it (the orchestrator, or the main session) does steps 5–8.
1. Commit on a work branch (not the default branch), then run the checks through `${CLAUDE_PLUGIN_ROOT}/tools/verify-evidence.sh --tests-re '<test paths>' -- <verify command>`. Paste its output unchanged into the Verification section of the PR or hand-over report; never write that section by hand. Keep secrets out of the command (pass them as environment variables). Add `--tail N` only after reading the log for paths or secrets. Red means not done. If it lists changed existing tests, another agent or the user must approve that part.
2. Produce artifacts: UI change → before/after screenshots or a short video; flow/state change → a statechart (rerun the model if one exists); bug fix → failing repro before, passing after. Name things by the feature map; with no map, use the user's own words.
3. Blast radius for any code change, even one line: list callers and shared data (file:line), write "this is safe because ___", prove that one fact by running real code.
4. PR body, in order: Why | What changed | Scope | Tradeoffs | Blast radius | Verification (commands + output). Conventional Commits title. Never merge from here. No remote or no PR flow → write the same six sections into the hand-over report.
5. Review by risk tier (METHOD §2), never by the session that wrote the code. Reviewers first check that the evidence SHA equals the head of the branch under review (the PR head when there is a PR); if not, rerun. Merge only after the user or an independent reviewer approves that SHA.
6. UI or flow change: a non-author agent drives the app like a user on the old and new build and gives a pass/fail verdict with screenshots. Green CI and code review do not replace this verdict. No driver → walk the same user path with the project's existing QA scripts or a browser/device automation tool, and add a gap line.
7. Each review finding gets one of: fix, dismiss with a concrete disproof, or ask the user. The writing session may not dismiss findings about auth, billing, data, migrations or concurrency on its own: a reviewer from another model family must confirm the disproof (if the disproof is a test, it reproduces the finding's conditions and the reviewer runs it). Ask the user only about product decisions, phrased as what a user of the app would see, never about whether code is correct. Settle P1/P2 before handing over; after any fix, rerun step 1, redo the artifacts and the user-path verdict the fix touched, and get the new SHA approved. Append each finding to `plans/FINDINGS.md`: date | kind | one sentence | already has a check?
8. Findings go through triage as its step 4 says. A kind seen a second time means the first check was missing or weak.
