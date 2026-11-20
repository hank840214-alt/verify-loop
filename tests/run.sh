#!/usr/bin/env bash
# Self-contained tests. Uses a temporary HOME; never runs Codex or real test suites.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.codex"; unset XDG_STATE_HOME
printf 'model = "test-model"\nmodel_reasoning_effort = "low"\n[profiles.x]\nmodel = "other"\n' > "$HOME/.codex/config.toml"
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1"; }
expect_rc() { local want=$1 name=$2; shift 2; "$@" >"$T/out" 2>&1; local rc=$?; [[ $rc == "$want" ]] && ok "$name" || { bad "$name (rc=$rc, want $want)"; sed 's/^/     /' "$T/out"; }; }

# ---------- codex-dispatch ----------
D="$ROOT/tools/codex-dispatch.sh"
REPO="$T/repo"; mkdir -p "$REPO/.scratch" "$T/plain"; git -C "$REPO" init -q
echo "do the thing" > "$T/task.md"
export DRY_RUN=1
expect_rc 65 "dispatch: unknown flag refused"            bash "$D" -f "$T/task.md" -s read-only -C "$REPO" --dangerously-bypass-approvals-and-sandbox
expect_rc 65 "dispatch: -c other than effort refused"    bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -c notify=x
expect_rc 65 "dispatch: danger-full-access refused"      bash "$D" -f "$T/task.md" -s danger-full-access -C "$REPO"
expect_rc 65 "dispatch: -C / refused"                    bash "$D" -f "$T/task.md" -s read-only -C / --skip-git-repo-check
expect_rc 65 "dispatch: -C HOME refused"                 bash "$D" -f "$T/task.md" -s read-only -C "$HOME" --skip-git-repo-check
expect_rc 65 "dispatch: workspace-write outside git"     bash "$D" -f "$T/task.md" -s workspace-write -C "$T/plain"
expect_rc 65 "dispatch: skip-git-check needs read-only"  bash "$D" -f "$T/task.md" -s workspace-write -C "$REPO" --skip-git-repo-check
expect_rc 65 "dispatch: -o must be .md/.txt"             bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/x.py"
expect_rc 65 "dispatch: -o in dot folder refused"        bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.git/x.md"
ln -s "$T/elsewhere.md" "$REPO/.scratch/link.md"
expect_rc 65 "dispatch: -o symlink refused"              bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/link.md"
mkdir -p "$HOME/.claude/r"; git -C "$HOME/.claude/r" init -q
expect_rc 65 "dispatch: workspace-write in ~/.claude"    bash "$D" -f "$T/task.md" -s workspace-write -C "$HOME/.claude/r"
expect_rc 65 "dispatch: read-only -C ~/.claude refused"  bash "$D" -f "$T/task.md" -s read-only --skip-git-repo-check -C "$HOME/.claude" -o "$HOME/.claude/CLAUDE.md"
expect_rc 65 "dispatch: -o in repo root refused"         bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/AGENTS.md"
echo old > "$REPO/.scratch/exists.md"
expect_rc 65 "dispatch: -o existing file refused"        bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/exists.md"
expect_rc 65 "dispatch: --net with read-only refused"    bash "$D" -f "$T/task.md" -s read-only -C "$REPO" --net
expect_rc 65 "dispatch: -m starting with - refused"      bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -m --oss
inrepo() { (cd "$REPO" && "$@"); }
expect_rc 0  "dispatch: valid call (from inside the repo)" inrepo bash "$D" -f "$T/task.md" -s workspace-write -C "$REPO" -o "$REPO/.scratch/r.md"
grep -q -- '--ignore-user-config' "$T/out" && grep -q 'network_access=false' "$T/out" && grep -q 'test-model' "$T/out" && ! grep -q other "$T/out" \
  && ok "dispatch: no user config, network off, model from top-level config" || bad "dispatch: command shape"
inrepo bash "$D" -f "$T/task.md" -s workspace-write -C "$REPO" --net >"$T/out" 2>&1
grep -q 'network_access=true' "$T/out" && ok "dispatch: --net turns network on explicitly" || bad "dispatch: --net"
O2="$T/other"; mkdir -p "$O2"; git -C "$O2" init -q
expect_rc 65 "dispatch: workspace-write -C of a repo you are not in is refused" inrepo bash "$D" -f "$T/task.md" -s workspace-write -C "$O2"
grep -q 'repo of the current folder' "$T/out" && ok "dispatch: says why (-C not the current repo)" || bad "dispatch: -C message"
DF="$T/dotfiles"; mkdir -p "$DF"; git -C "$DF" init -q; ln -s "$HOME/.claude" "$DF/claude-link"
expect_rc 0 "dispatch: read-only -C of another repo is fine" inrepo bash "$D" -f "$T/task.md" -s read-only -C "$O2"
REALHOME="$(perl -e 'print((getpwuid($<))[7])')"
expect_rc 65 "dispatch: HOME=elsewhere cannot unprotect the real home" env HOME="$T" bash "$D" -f "$T/task.md" -s read-only --skip-git-repo-check -C "$REALHOME"
if [[ -d "$REALHOME/.claude" ]]; then
  expect_rc 65 "dispatch: HOME=elsewhere cannot unprotect the real ~/.claude" env HOME="$T" bash "$D" -f "$T/task.md" -s read-only --skip-git-repo-check -C "$REALHOME/.claude"
else
  echo "SKIP - real-home guard subdirectory does not exist"
fi
unset DRY_RUN
mkdir -p "$T/bin"; cat > "$T/bin/codex" <<'FAKE'
#!/usr/bin/env bash
o=""; while (($#)); do [[ "$1" == -o ]] && o="$2"; shift; done
cat >/dev/null; [[ -n "$o" ]] && echo "fake report" > "$o"; exit 0
FAKE
chmod +x "$T/bin/codex"
PATH="$T/bin:$PATH" expect_rc 0 "dispatch: real run delivers -o via private staging" bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/real.md"
grep -q "fake report" "$REPO/.scratch/real.md" && ok "dispatch: report delivered" || bad "dispatch: report missing"
mkdir -p "$T/outside"; mv "$REPO/.scratch" "$T/outside/s"; ln -s "$T/outside/s" "$REPO/.scratch"
expect_rc 65 "dispatch: .scratch symlink refused" bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/x.md"
rm "$REPO/.scratch"; mv "$T/outside/s" "$REPO/.scratch"
cat > "$T/bin/codex" <<'FAKE'
#!/usr/bin/env bash
o=""; while (($#)); do [[ "$1" == -o ]] && o="$2"; shift; done
cat >/dev/null; echo "partial report" > "$o"; exit 1
FAKE
PATH="$T/bin:$PATH" expect_rc 1 "dispatch: Codex failure keeps its exit code" bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/fail.md"
grep -q "partial report" "$REPO/.scratch/fail.md" && ok "dispatch: report still delivered when Codex fails" || bad "dispatch: report lost on failure"
echo victim > "$T/victim.txt"
cat > "$T/bin/codex" <<FAKE
#!/usr/bin/env bash
o=""; while ((\$#)); do [[ "\$1" == -o ]] && o="\$2"; shift; done
cat >/dev/null; ln -s "$T/victim.txt" "\$o"; exit 0
FAKE
mkdir -p "$REPO/bin"; cp "$T/bin/codex" "$REPO/bin/codex"
PATH="$REPO/bin:$PATH" expect_rc 65 "dispatch: codex found inside the target repo is refused" bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/pb.md"
rm -r "$REPO/bin"
PATH="$T/bin:$PATH" expect_rc 73 "dispatch: staged report that is a symlink is refused" bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/link2.md"
[[ "$(cat "$T/victim.txt")" == victim && ! -e "$REPO/.scratch/link2.md" ]] && ok "dispatch: nothing written through the link" || bad "dispatch: wrote through staged link"
cat > "$T/bin/codex" <<FAKE
#!/usr/bin/env bash
cat >/dev/null; mv "$REPO/.scratch" "$T/moved"; mkdir -p "$HOME/.claude/commands"; ln -s "$HOME/.claude/commands" "$REPO/.scratch"
o=""; while ((\$#)); do [[ "\$1" == -o ]] && o="\$2"; shift; done; echo evil > "\$o"; exit 0
FAKE
PATH="$T/bin:$PATH" expect_rc 73 "dispatch: .scratch swapped for a symlink during the run is refused" bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/swap.md"
[[ ! -e "$HOME/.claude/commands/swap.md" ]] && ok "dispatch: nothing written into ~/.claude" || bad "dispatch: wrote into ~/.claude"
rm "$REPO/.scratch"; mv "$T/moved" "$REPO/.scratch"
DRY_RUN=1 bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/st.md" >"$T/out" 2>&1
grep -q "$REALHOME/.local/state/codex-dispatch/" "$T/out" && ok "dispatch: staging is in the real home, outside /tmp and TMPDIR" || bad "dispatch: staging location"
cat > "$T/bin/codex" <<FAKE
#!/usr/bin/env bash
o=""; while ((\$#)); do [[ "\$1" == -o ]] && o="\$2"; shift; done; cat >/dev/null; mkfifo "$REPO/.scratch/ff.md"; echo r > "\$o"
FAKE
PATH="$T/bin:$PATH" expect_rc 73 "dispatch: a FIFO placed at -o during the run is refused (no hang)" bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/ff.md"
rm -f "$REPO/.scratch/ff.md"
mkdir -p "$HOME/.claude/r2"; git -C "$HOME/.claude/r2" init -q
if [[ -d "$HOME/.CLAUDE" ]]; then
  DRY_RUN=1 expect_rc 65 "dispatch: -C ~/.CLAUDE (other case) is still protected" bash "$D" -f "$T/task.md" -s read-only -C "$HOME/.CLAUDE/r2"
else ok "dispatch: case test skipped (case-sensitive file system)"; fi
cat > "$T/bin/codex" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null; exit 0
FAKE
PATH="$T/bin:$PATH" expect_rc 74 "dispatch: -o given but Codex wrote no report -> non-zero" bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/none.md"

# ---------- stop-verify ----------
H="$ROOT/hooks/stop-verify.sh"
P="$T/proj"; mkdir -p "$P/src"; git -C "$P" init -q; git -C "$P" remote add origin https://example.com/acme/my-web-app.git
echo a > "$P/src/a.ts"; echo r > "$P/README.md"; git -C "$P" add -A; git -C "$P" -c user.email=t@t -c user.name=t commit -qm init
input() { printf '{"cwd":"%s","session_id":"%s"}' "$P" "${1:-s1}"; }
PR="$(cd "$P" && pwd -P)"
conf() { printf '{"acme/my-web-app":{"roots":["%s"],"code_re":"^src/.*\\\\.ts$","verify":"%s","limit":%s}}' "$PR" "$1" "${2:-120}" > "$HOME/.claude/stop-verify.projects.json"; rm -rf "$HOME/.claude/state"; }
run_hook() { input "$@" | bash "$H"; }

expect_rc 0 "hook: no config file -> silent pass"   run_hook
[[ ! -s "$T/out" ]] && ok "hook: no output without config" || bad "hook: printed output without config"
conf "exit 1"
expect_rc 0 "hook: clean tree -> nothing to check"  run_hook
echo b >> "$P/README.md"
expect_rc 0 "hook: non-code change ignored"         run_hook
echo b >> "$P/src/a.ts"
conf "true";   expect_rc 0 "hook: passing checks -> exit 0"   run_hook
conf "false | tee /dev/null"
# Write the cache value produced by the 0.1.0 format for this exact checkout.
state="$HOME/.claude/state/stop-verify"; mkdir -p "$state"
old_pass="$(cd "$PR" && { git rev-parse HEAD; printf '%s\n' 'false | tee /dev/null' 120; printf 'file src/a.ts\0'; shasum -- src/a.ts; } | shasum | cut -c1-40)"
printf '%s\n' "$old_pass" > "$state/$(printf '%s' "$PR" | shasum | cut -c1-16).pass"
expect_rc 2 "hook: a failed check piped to tee blocks Stop even with a matching 0.1.0 pass" run_hook pipe
conf "exit 1"; expect_rc 2 "hook: failing checks -> exit 2"   run_hook
conf "exit 1"; expect_rc 2 "hook: block 1"                    run_hook s2
               expect_rc 0 "hook: same state, same session -> released" run_hook s2
grep -q 'NOT VERIFIED' "$T/out" && ok "hook: says NOT VERIFIED on release" || bad "hook: release message"
               expect_rc 2 "hook: another session is blocked once" run_hook s3
grep -q 'not re-run' "$T/out" && ok "hook: a new session is told the earlier run is not repeated" || bad "hook: red cache message"
conf "sleep 5" 1; expect_rc 2 "hook: hitting the limit blocks" run_hook
grep -q 'did NOT FINISH' "$T/out" && ok "hook: says the run did not finish" || bad "hook: timeout message"
conf "true" "\"abc\""; expect_rc 0 "hook: non-numeric limit is rejected, not run" run_hook
grep -q 'limit must be' "$T/out" && ok "hook: says the limit is invalid" || bad "hook: limit message"
C2="$T/clone2"; git clone -q "$P" "$C2"; git -C "$C2" remote set-url origin https://example.com/acme/my-web-app.git; echo z >> "$C2/src/a.ts"
conf "exit 1"
printf '{"cwd":"%s","session_id":"c2"}' "$C2" | bash "$H" >"$T/out" 2>&1; [[ $? == 0 ]] && ok "hook: same owner/repo at an untrusted path -> not run" || bad "hook: ran an untrusted checkout"
grep -q 'not in roots' "$T/out" && jq -e .systemMessage "$T/out" >/dev/null && ok "hook: says a checkout is missing from roots (valid JSON)" || bad "hook: roots miss is silent"
X="$T/crafted"; mkdir -p "$X/src"; printf 'gitdir: %s/.git\n' "$P" > "$X/.git"; echo x > "$X/src/a.ts"
printf '{"cwd":"%s","session_id":"x"}' "$X" | bash "$H" >"$T/out" 2>&1; [[ $? == 0 ]] && grep -q 'not in roots' "$T/out" && ok "hook: a folder with a crafted .git file is not trusted" || bad "hook: trusted a crafted .git file"
WT="$T/wt"; git -C "$P" worktree add -q "$WT" 2>/dev/null; echo w >> "$WT/src/a.ts"
printf '{"cwd":"%s","session_id":"wt"}' "$WT" | bash "$H" >"$T/out" 2>&1; [[ $? == 2 ]] && ok "hook: linked worktree of a trusted checkout is checked" || bad "hook: worktree skipped"
git -C "$P" worktree remove --force "$WT"
git -C "$P" stash -q 2>/dev/null; rm -rf "$HOME/.claude/state"; mkdir -p "$P/other"; git -C "$P" mv src/a.ts other/a.ts
run_hook >"$T/out" 2>&1; [[ $? == 2 ]] && ok "hook: moving code out of code_re still runs the checks" || bad "hook: missed a moved file"
git -C "$P" mv other/a.ts src/a.ts; git -C "$P" stash pop -q 2>/dev/null
printf '{"acme/my-web-app":{"roots":["%s"],"code_re":"^src/","verify":"true","requires":"no\\\"pe"}}' "$PR" > "$HOME/.claude/stop-verify.projects.json"
run_hook >"$T/out" 2>&1; jq -e .systemMessage "$T/out" >/dev/null && ok "hook: messages stay valid JSON with quotes in config" || bad "hook: invalid JSON message"
conf "kill -9 \$\$"; expect_rc 2 "hook: signal death is a failure" run_hook
A="$T/attacker"; mkdir -p "$A/src"; git -C "$A" init -q; git -C "$A" remote add origin git@example.com:attacker/my-web-app.git
echo x > "$A/src/a.ts"; AR="$(cd "$A" && pwd -P)"
printf '{"acme/my-web-app":{"roots":["%s","%s"],"code_re":"^src/.*\\\\.ts$","verify":"exit 1","limit":120}}' "$PR" "$AR" > "$HOME/.claude/stop-verify.projects.json"; rm -rf "$HOME/.claude/state"
printf '{"cwd":"%s","session_id":"a"}' "$A" | bash "$H" >"$T/out" 2>&1; [[ $? == 0 ]] && ok "hook: same repo name, other owner -> not run" || bad "hook: matched another owner's repo"
echo c > "$P/src/b c.ts"
conf 'n=$(grep -c . \"$VERIFY_CHANGED_FILE\"); [ $n -eq 2 ] && grep -qx \"src/b c.ts\" \"$VERIFY_CHANGED_FILE\"'
expect_rc 0 "hook: VERIFY_CHANGED_FILE is one file per line" run_hook
# test guard
G="$T/guard"; mkdir -p "$G/src" "$G/tests"; git -C "$G" init -q; git -C "$G" remote add origin https://example.com/acme/guarded.git
echo a > "$G/src/a.ts"; echo t > "$G/tests/a.test.ts"; git -C "$G" add -A; git -C "$G" -c user.email=t@t -c user.name=t commit -qm init
GR="$(cd "$G" && pwd -P)"
printf '{"acme/guarded":{"roots":["%s"],"code_re":"^(src|tests)/.*\\\\.ts$","tests_re":"^tests/","verify":"true","limit":120}}' "$GR" > "$HOME/.claude/stop-verify.projects.json"; rm -rf "$HOME/.claude/state"
ginput() { printf '{"cwd":"%s","session_id":"%s"}' "$G" "$1" | bash "$H"; }
echo b >> "$G/src/a.ts"; echo weaker > "$G/tests/a.test.ts"
expect_rc 2 "guard: fix + edited existing test -> blocked" ginput g1
grep -q 'test guard' "$T/out" && ok "guard: says why" || bad "guard: message"
git -C "$G" checkout -q tests/a.test.ts; echo n > "$G/tests/new.test.ts"
expect_rc 0 "guard: fix + NEW test file -> allowed" ginput g2
rm "$G/tests/new.test.ts"; git -C "$G" checkout -q src/a.ts; echo weaker > "$G/tests/a.test.ts"; echo new > "$G/src/added.ts"
expect_rc 2 "guard: NEW code file + edited existing test -> blocked" ginput g4
rm "$G/src/added.ts"
expect_rc 0 "guard: test-only change -> allowed" ginput g3
mkdir -p "$G/src/gen"; for i in $(seq 1 1500); do echo x > "$G/src/gen/file-with-a-long-name-$i.ts"; done
expect_rc 2 "guard: still blocks with 1500 new code files (no SIGPIPE skip)" ginput g5
rm -r "$G/src/gen"
git -C "$G" checkout -q tests/a.test.ts
# guard runs before the pass cache, even when code_re does not cover tests
printf '{"acme/guarded":{"roots":["%s"],"code_re":"^src/","tests_re":"^tests/","verify":"true","limit":120}}' "$GR" > "$HOME/.claude/stop-verify.projects.json"; rm -rf "$HOME/.claude/state"
echo b2 >> "$G/src/a.ts"; expect_rc 0 "guard: code change passes first" ginput g6
echo weaker > "$G/tests/a.test.ts"; expect_rc 2 "guard: weakening a test after a pass is still blocked" ginput g6
git -C "$G" checkout -q tests/a.test.ts
git -C "$G" checkout -q src/a.ts
# file names with quotes are fingerprinted
printf '{"acme/guarded":{"roots":["%s"],"code_re":"^src/","verify":"! grep -rq bad src","limit":120}}' "$GR" > "$HOME/.claude/stop-verify.projects.json"; rm -rf "$HOME/.claude/state"
echo ok > "$G/src/q\"x.ts"; expect_rc 0 "hook: file with a quote in its name passes" ginput q1
echo bad > "$G/src/q\"x.ts"; expect_rc 2 "hook: breaking that file is caught (no stale pass)" ginput q1
rm "$G/src/q\"x.ts"
# a very long change list goes through VERIFY_CHANGED_FILE
printf '{"acme/guarded":{"roots":["%s"],"code_re":"^src/","verify":"test -s \\"$VERIFY_CHANGED_FILE\\" && [ $(wc -l < \\"$VERIFY_CHANGED_FILE\\") -ge 3000 ]","limit":120}}' "$GR" > "$HOME/.claude/stop-verify.projects.json"; rm -rf "$HOME/.claude/state"
mkdir -p "$G/src/many"; for i in $(seq 1 3000); do : > "$G/src/many/a-rather-long-generated-file-name-number-$i.ts"; done
expect_rc 0 "hook: 3000 changed files go through VERIFY_CHANGED_FILE (no E2BIG)" ginput big
rm -r "$G/src/many"

# one block per state: red cache, ledger, background work, skip_re, guard text, deadline
DP="$T/dp"; mkdir -p "$DP/src" "$DP/tests"; git -C "$DP" init -q; git -C "$DP" remote add origin https://example.com/acme/dapp.git
echo a > "$DP/src/a.ts"; echo t > "$DP/tests/a.test.ts"; git -C "$DP" add -A; git -C "$DP" -c user.email=t@t -c user.name=t commit -qm init
DPR="$(cd "$DP" && pwd -P)"; LED="$HOME/.claude/state/stop-verify/ledger.tsv"; RAN="$T/ran"
dconf() { printf '{"acme/dapp":{"roots":["%s"],"code_re":"^(src|tests|junk)/","tests_re":"^tests/","skip_re":"^junk/","verify":"%s","limit":%s}}' "$DPR" "$1" "${2:-60}" > "$HOME/.claude/stop-verify.projects.json"; rm -rf "$HOME/.claude/state" "$RAN"; }
dhook() { printf '{"cwd":"%s","session_id":"%s"%s}' "$DP" "$1" "${2:-}" | env ${HENV:-X=1} bash "$H" >"$T/out" 2>&1; }
# Stop input as captured on Claude Code 2.1.327 (boolean stop_hook_active, background_tasks items)
dcap() { printf '{"session_id":"%s","transcript_path":"/x/t.jsonl","cwd":"%s","permission_mode":"default","hook_event_name":"Stop","stop_hook_active":false,"background_tasks":[%s]}' "$1" "$DP" "$2" | env ${HENV:-X=1} bash "$H" >"$T/out" 2>&1; }
CAP_SUB='{"id":"a1b2c3","type":"subagent","status":"running","description":"review the diff","agent_type":"general-purpose"}'
CAP_DISPATCH='{"id":"d4e5f6","type":"shell","status":"running","description":"codex task","command":"bash /x/tools/codex-dispatch.sh -f t.md"}'
fmode() { if stat -c %a / >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
SD="$HOME/.claude/state/stop-verify"
druns() { [[ -f "$RAN" ]] && wc -l < "$RAN" | tr -d ' ' || echo 0; }
echo b >> "$DP/src/a.ts"
dconf "echo x >> $RAN; echo 'not ok 7 - the named test'; exit 1"
expect_rc 2 "once: failing state blocks the first stop" dhook s1
grep -q 'not ok 7 - the named test' "$T/out" && grep -q 'Full log:' "$T/out" && ok "once: names the failing test and the log" || bad "once: excerpt"
expect_rc 0 "once: same state, same session -> released" dhook s1
grep -q 'NOT VERIFIED (fail)' "$T/out" && jq -e .systemMessage "$T/out" >/dev/null && ok "once: release is a visible note" || bad "once: release note"
[[ "$(druns)" == 1 ]] && ok "once: checks ran once, not twice" || bad "once: ran $(druns) times"
expect_rc 0 "once: third stop still released (no flip-flop)" dhook s1
expect_rc 2 "once: another session is blocked once, without a run" dhook s2
grep -q 'not re-run' "$T/out" && grep -q 'not ok 7' "$T/out" && [[ "$(druns)" == 1 ]] && ok "once: says not re-run and shows the saved failure" || bad "once: other-session message"
expect_rc 0 "once: that session's next stop is released" dhook s2
[[ "$(fmode "$SD"/*.fail.log)" == 600 ]] && ok "once: fail log is mode 600" || bad "once: fail log mode"
echo c >> "$DP/src/a.ts"; expect_rc 2 "once: changed state runs and blocks again" dhook s1 ',"stop_hook_active":true'
[[ "$(druns)" == 2 ]] && ok "once: second run for the new state" || bad "once: ran $(druns) times"
dconf "[ -f $T/fixed ]"; /bin/rm -f "$T/fixed"; echo c2 >> "$DP/src/a.ts"; dhook cl; ls "$SD" | grep -c -E '\.(red|fail\.log|cl\.blocks)$' | grep -qx 3 && ok "cleanup: a failure leaves red, log and blocks" || bad "cleanup: files missing after a failure"
touch "$T/fixed"; echo c3 >> "$DP/src/a.ts"; expect_rc 0 "once: fixed state passes" dhook cl ',"stop_hook_active":true'
ls "$SD" | grep -qE '\.(red|fail\.log|cl\.blocks)$' && bad "cleanup: red, log or blocks left behind" || ok "cleanup: pass removes red, log and blocks"
dconf "exit 1"
for i in 1 2 3; do echo "e$i" >> "$DP/src/a.ts"; expect_rc 2 "row: block $i" dhook s3 ',"stop_hook_active":true'; done
echo e4 >> "$DP/src/a.ts"; expect_rc 0 "row: 4th failing state in a row is released" dhook s3 ',"stop_hook_active":true'
dconf "exit 1"
for i in 1 2 3 4; do echo "f$i" >> "$DP/src/a.ts"; expect_rc 2 "row: stop_hook_active=false never adds up: block $i" dhook s4 ',"stop_hook_active":false'; done
dconf "echo x >> $RAN; sleep 5" 1; echo g >> "$DP/src/a.ts"
expect_rc 2 "timeout: blocks once" dhook s5
grep -q "NOT FINISH" "$T/out" && grep -q "not a test failure" "$T/out" && ok "timeout: says not verified, not a failure" || bad "timeout: message"
expect_rc 0 "timeout: same state is released" dhook s5
[[ "$(druns)" == 1 ]] && grep -q 'NOT VERIFIED (timeout)' "$T/out" && ok "timeout: no second run, note says timeout" || bad "timeout: rerun or note"
dconf "exit 1"; echo h >> "$DP/src/a.ts"
dcap s6 "$CAP_SUB"; rc=$?
[[ $rc == 0 && ! -s "$T/out" ]] && grep -q $'\tdeferred\t' "$LED" && ok "busy: running subagent (captured shape) -> deferred, silent, ledger says deferred" || bad "busy: subagent rc=$rc"
dcap s6 '{"id":"w","type":"workflow","status":"running"}'; [[ $? == 0 && ! -s "$T/out" ]] && ok "busy: workflow -> deferred" || bad "busy: workflow"
dcap s6 "$CAP_DISPATCH"; [[ $? == 0 && ! -s "$T/out" ]] && ok "busy: codex-dispatch.sh shell -> deferred" || bad "busy: dispatch shell"
dcap s6 '{"id":"x","type":"subagent","status":"completed","description":"done"}'; [[ $? == 2 ]] && ok "busy: completed subagent does not defer" || bad "busy: completed"
dcap s6y '{"id":"y","type":"shell","status":"running","description":"log","command":"tail -f codex-dispatch.log"}'; [[ $? == 2 ]] && ok "busy: tail -f codex-dispatch.log does not defer" || bad "busy: log tail"
dcap s6c '{"id":"c","type":"shell","status":"running","description":"dev","command":"npm run serve"}'; [[ $? == 2 ]] && ok "busy: a dev server shell does not defer" || bad "busy: dev server"
dcap s6o '7,"str",{"type":"shell","command":9},{"type":"subagent","status":"running"}'; rc=$?
[[ $rc == 0 && ! -s "$T/out" && "$(tail -1 "$LED" | cut -f5)" == deferred ]] && ok "busy: odd list items are ignored per item, the subagent still defers" || bad "busy: odd items rc=$rc"
dcap s6q '{"id":"q","type":"shell","status":"running","description":"d","command":"bash \"/x/tools/codex-dispatch.sh\" -f t.md &"}'; [[ $? == 0 && ! -s "$T/out" ]] && ok "busy: quoted codex-dispatch.sh path defers" || bad "busy: quoted dispatch"
dcap s6t '{"id":"t","type":"shell","status":"running","description":"d","command":"tail -f /x/codex-dispatch.sh"}'; [[ $? == 2 ]] && ok "busy: tail of the script file does not defer" || bad "busy: tail of script"
dcap s7 ''; [[ $? == 2 ]] && ok "busy: empty list -> checked" || bad "busy: empty list"
HENV=STOP_VERIFY_DRY=1 dcap s6 "$CAP_SUB"; grep -q '^\[dry\]' "$T/out" && ok "busy: DRY never defers" || bad "busy: DRY deferred"
git -C "$DP" checkout -q src/a.ts; dconf "exit 1"; mkdir -p "$DP/junk"; echo j > "$DP/junk/left.ts"
expect_rc 0 "skip_re: leftover folder alone does not trigger" dhook s8
echo weaker > "$DP/tests/a.test.ts"; dconf "true"
expect_rc 0 "skip_re: test edit + skipped leftover is test-only" dhook s8b
grep -q 'test guard' "$T/out" && bad "skip_re: guard fired on a skipped file" || ok "skip_re: guard ignores skipped files"
git -C "$DP" checkout -q tests/a.test.ts; /bin/rm -rf "$DP/junk"
dconf "true"; echo k >> "$DP/src/a.ts"; echo weaker > "$DP/tests/a.test.ts"
expect_rc 2 "guard: blocks once" dhook s9
grep -q 'do NOT revert' "$T/out" && grep -q 'Uncommitted' "$T/out" && ! grep -q 'Revert the edits' "$T/out" && ok "guard: says uncommitted, never orders a revert of others' work" || bad "guard: message"
expect_rc 0 "guard: same state is released" dhook s9
grep -q 'NOT VERIFIED (guard)' "$T/out" && ok "guard: release note" || bad "guard: note"
git -C "$DP" checkout -q tests/a.test.ts src/a.ts; echo k2 >> "$DP/src/a.ts"; echo '// a comment' >> "$DP/tests/a.test.ts"
expect_rc 2 "guard: comment-only test edit + code edit is still blocked" dhook s10
awk -F'\t' 'NF!=9{bad=1} END{exit bad}' "$LED" && [[ -s "$LED" ]] && ok "ledger: every line has 9 tab fields" || bad "ledger: field count"
grep -q "$DPR" "$LED" && bad "ledger: holds a full path" || ok "ledger: no full path"
git -C "$DP" checkout -q tests/a.test.ts src/a.ts
git -C "$DP" checkout -q tests/a.test.ts src/a.ts
dl() { dconf "true"; echo "dl$1" >> "$DP/src/a.ts"; HENV="STOP_VERIFY_DRY=1 STOP_VERIFY_DEADLINE=$1" dhook dl; grep -o 'deadline=[0-9]*s' "$T/out"; git -C "$DP" checkout -q src/a.ts; }
for v in 0 59 090 119 541 9999 abc 1e3; do [[ "$(dl $v)" == deadline=540s ]] && ok "deadline: $v -> 540" || bad "deadline: $v"; done
for v in 120:120 0150:150 540:540 0540:540; do [[ "$(dl ${v%%:*})" == "deadline=${v##*:}s" ]] && ok "deadline: ${v%%:*} -> ${v##*:} (decimal)" || bad "deadline: ${v%%:*}"; done
dconf "echo x >> $RAN; exit 1"; echo sk >> "$DP/src/a.ts"
HENV="SECONDS=100 STOP_VERIFY_DEADLINE=120" dhook sk; rc=$?
[[ $rc == 0 && "$(druns)" == 0 ]] && grep -q 'not enough time left' "$T/out" && ! ls "$SD" | grep -q '\.red$' && grep -q $'\tskipped\t' "$LED" && ok "deadline: no time left -> not verified, no block, no red file, ledger skipped" || bad "deadline: skipped (rc=$rc)"
git -C "$DP" checkout -q src/a.ts
# fingerprints: deleted file, mode, files outside code_re
dconf "echo x >> $RAN; exit 1"; /bin/rm "$DP/src/a.ts"
expect_rc 2 "fingerprint: deleting a code file blocks once" dhook del
expect_rc 0 "fingerprint: same deletion, next stop is released without a re-run" dhook del
[[ "$(druns)" == 1 ]] && ok "fingerprint: deleted state is stable (ran once)" || bad "fingerprint: deleted ran $(druns)"
git -C "$DP" checkout -q src/a.ts; echo "m1" >> "$DP/src/a.ts"; chmod +x "$DP/src/a.ts"
dconf "echo x >> $RAN; exit 1"; echo '{}' > "$DP/tsconfig.json"; git -C "$DP" add tsconfig.json; git -C "$DP" -c user.email=t@t -c user.name=t commit -qm cfg; echo "m1" >> "$DP/src/a.ts"
expect_rc 2 "fingerprint: first run blocks" dhook fp ',"stop_hook_active":true'
echo '{"a":1}' > "$DP/tsconfig.json"
expect_rc 2 "fingerprint: fixing a file outside code_re re-runs the checks" dhook fp ',"stop_hook_active":true'
[[ "$(druns)" == 2 ]] && ok "fingerprint: that was a real re-run" || bad "fingerprint: ran $(druns)"
git -C "$DP" checkout -q tsconfig.json
dconf "echo x >> $RAN; exit 1"; git -C "$DP" checkout -q src/a.ts; echo "m2" >> "$DP/src/a.ts"
dhook md ',"stop_hook_active":true'; chmod +x "$DP/src/a.ts"; expect_rc 2 "fingerprint: a mode change is a new state" dhook md ',"stop_hook_active":true'
[[ "$(druns)" == 2 ]] && ok "fingerprint: mode change re-ran" || bad "fingerprint: mode ran $(druns)"
chmod -x "$DP/src/a.ts"; git -C "$DP" checkout -q src/a.ts
# going back to an earlier blocked state is not blocked again
dconf "echo x >> $RAN; exit 1"
echo A >> "$DP/src/a.ts"; expect_rc 2 "set: state A blocks" dhook ab ',"stop_hook_active":true'
git -C "$DP" checkout -q src/a.ts; echo B >> "$DP/src/a.ts"; expect_rc 2 "set: state B blocks" dhook ab ',"stop_hook_active":true'
git -C "$DP" checkout -q src/a.ts; echo A >> "$DP/src/a.ts"; expect_rc 0 "set: back to A is released, not blocked" dhook ab ',"stop_hook_active":true'
[[ "$(druns)" == 2 ]] && ok "set: A was not re-run" || bad "set: ran $(druns)"
# missing stop_hook_active keeps accumulating; the limit text differs
dconf "exit 1"; git -C "$DP" checkout -q src/a.ts
for i in 1 2 3; do echo "n$i" >> "$DP/src/a.ts"; expect_rc 2 "accumulate: no stop_hook_active field, block $i" dhook acc; done
echo n4 >> "$DP/src/a.ts"; expect_rc 0 "accumulate: 4th new state is released" dhook acc
grep -q 'blocked 3 times in a row and is now allowed to stop' "$T/out" && ok "accumulate: release text names the streak" || bad "accumulate: text"
expect_rc 2 "accumulate: the streak reset, the released state is not remembered as blocked" dhook acc
# state files
dconf "head -c 3000000 /dev/zero | tr '\\\\0' x; exit 1"; git -C "$DP" checkout -q src/a.ts; echo cap >> "$DP/src/a.ts"
dhook cap; sz="$(wc -c < "$SD"/*.fail.log | tr -d ' ')"
(( sz > 1000000 && sz <= 2000000 )) && [[ "$(wc -c < "$T/out")" -lt 20000 ]] && ok "fail log: capped at 2 MB, console excerpt stays short" || bad "fail log size $sz"
dconf "exit 1"; mkdir -p "$SD"; touch "$SD/old.s9.blocks" "$SD/new.s9.blocks"; touch -t 202001010000 "$SD/old.s9.blocks"; git -C "$DP" checkout -q src/a.ts; echo old >> "$DP/src/a.ts"; dhook old
[[ ! -e "$SD/old.s9.blocks" && -e "$SD/new.s9.blocks" ]] && ok "state: .blocks older than 7 days are removed" || bad "state: stale blocks"
if [[ "$(id -u)" != 0 ]]; then
  dconf "exit 1"; mkdir -p "$SD"; chmod 500 "$SD"; git -C "$DP" checkout -q src/a.ts; echo ro >> "$DP/src/a.ts"
  expect_rc 0 "state: unwritable state dir -> never blocks" dhook ro; grep -q 'cannot write state in' "$T/out" && ok "state: says why, with the folder" || bad "state: no message"
  chmod 700 "$SD"
  dconf "exit 1"; mkdir -p "$SD"; chmod 500 "$SD"; echo keep > "$T/keepme"; git -C "$DP" checkout -q src/a.ts; echo ro2 >> "$DP/src/a.ts"
  HENV="LOG=$T/keepme LIST=$T/keepme" dhook ro2; chmod 700 "$SD"
  [[ -f "$T/keepme" ]] && ok "state: inherited LOG/LIST env files are never deleted" || bad "state: deleted a file named by env"
fi
dconf "exit 1"; git -C "$DP" checkout -q src/a.ts; echo led >> "$DP/src/a.ts"; mkdir -p "$SD"; : > "$SD/ledger.tsv"; chmod 644 "$SD/ledger.tsv"; dhook led
[[ "$(fmode "$SD/ledger.tsv")" == 600 ]] && ok "ledger: mode 600" || bad "ledger: mode"
TP="$T/tab"$'\t'"dir"; mkdir -p "$TP/src"; git -C "$TP" init -q; git -C "$TP" remote add origin https://example.com/acme/dapp.git; echo a > "$TP/src/a.ts"; git -C "$TP" add -A; git -C "$TP" -c user.email=t@t -c user.name=t commit -qm i; echo b >> "$TP/src/a.ts"
TPR="$(cd "$TP" && pwd -P)"; jq -n --arg r "$TPR" '{"acme/dapp":{roots:[$r],code_re:"^src/",verify:"exit 1"}}' > "$HOME/.claude/stop-verify.projects.json"; /bin/rm -rf "$HOME/.claude/state"
jq -nc --arg c "$TP" '{cwd:$c,session_id:"tab"}' | bash "$H" >"$T/out" 2>&1
awk -F'\t' 'NF!=9{bad=1} END{exit bad}' "$LED" && [[ -s "$LED" ]] && ok "ledger: a tab in the folder name keeps 9 fields" || bad "ledger: tab in folder name"
# files written by verify itself, forced re-run, excerpt bytes, symlinks, limits
dconf 'echo x >> '"$RAN"'; echo $RANDOM$RANDOM > out.json; exit 1'; git -C "$DP" checkout -q src/a.ts; echo vw >> "$DP/src/a.ts"
expect_rc 2 "verify output: first stop blocks" dhook vw ',"stop_hook_active":true'
expect_rc 0 "verify output: second stop is released" dhook vw ',"stop_hook_active":true'
expect_rc 0 "verify output: third stop is released" dhook vw ',"stop_hook_active":true'
[[ "$(druns)" == 1 ]] && ok "verify output: a file written by verify does not cause re-runs" || bad "verify output: ran $(druns)"
/bin/rm -f "$SD"/*.red; expect_rc 0 "force: after deleting <id>.red the checks run again" dhook vw ',"stop_hook_active":true'
[[ "$(druns)" == 2 ]] && ok "force: it was a real re-run" || bad "force: ran $(druns)"
/bin/rm -f "$DP/out.json"
dconf "printf 'not ok 1 - first\\\\n\\\\xff bad bytes\\\\nnot ok 2 - second\\\\n'; exit 1"; echo ex >> "$DP/src/a.ts"; dhook ex
grep -q 'not ok 1 - first' "$T/out" && grep -q 'not ok 2 - second' "$T/out" && ok "excerpt: a non-UTF-8 byte does not eat the next lines" || bad "excerpt: bytes"
dconf "exit 1"; git -C "$DP" checkout -q src/a.ts; echo mx >> "$DP/src/a.ts"
echo mx0 > "$DP/data.txt"; ln -s ../data.txt "$DP/src/l.ts"; dconf "echo x >> $RAN; true"
dhook ln; dhook ln; echo changed > "$DP/data.txt"; dhook ln
[[ "$(druns)" == 2 ]] && ok "symlink: changed target content re-runs, unchanged is cached" || bad "symlink: ran $(druns)"
/bin/rm -f "$DP/src/l.ts" "$DP/data.txt"; git -C "$DP" checkout -q src/a.ts
dconf "true" 100; HENV="STOP_VERIFY_DEADLINE=120" dhook lim; grep -q 'limit must be 1-90' "$T/out" && ok "limit: must leave 30 s below the deadline" || bad "limit: deadline-30"
# bad config types
printf '{"acme/dapp":{"roots":["%s"],"code_re":"^src/","skip_re":["x"],"verify":"exit 1"}}' "$DPR" > "$HOME/.claude/stop-verify.projects.json"; echo sr >> "$DP/src/a.ts"
expect_rc 0 "config: skip_re as an array -> message, no crash, no block" dhook cfg
grep -q 'invalid skip_re in config for acme/dapp: must be a string' "$T/out" && ok "config: says which field must be a string" || bad "config: message"
printf '{"acme/dapp":{"roots":["%s"],"code_re":"^src/","verify":["true"]}}' "$DPR" > "$HOME/.claude/stop-verify.projects.json"; dhook cfg2
grep -q 'invalid verify in config' "$T/out" && ok "config: verify must be a string" || bad "config: verify type"
printf '{"acme/dapp":{"roots":["%s"],"code_re":"^src/","tests_re":null,"verify":"true"}}' "$DPR" > "$HOME/.claude/stop-verify.projects.json"; dhook cfg3
grep -q 'invalid tests_re in config' "$T/out" && ok "config: an explicit null regex is invalid" || bad "config: null regex"
# skip_re also applies to the guard's existing-test list
git -C "$DP" checkout -q src/a.ts; mkdir -p "$DP/tests/gen"; echo g > "$DP/tests/gen/x.ts"; git -C "$DP" add -A; git -C "$DP" -c user.email=t@t -c user.name=t commit -qm gen
printf '{"acme/dapp":{"roots":["%s"],"code_re":"^(src|tests)/","tests_re":"^tests/","skip_re":"^tests/gen/","verify":"true"}}' "$DPR" > "$HOME/.claude/stop-verify.projects.json"; /bin/rm -rf "$HOME/.claude/state"
echo changed > "$DP/tests/gen/x.ts"; echo gx >> "$DP/src/a.ts"
expect_rc 0 "skip_re: a skipped existing test file does not trip the guard" dhook gs
git -C "$DP" checkout -q src/a.ts tests/gen/x.ts
git -C "$DP" checkout -q src/a.ts

# evidence
E="$ROOT/tools/verify-evidence.sh"
in_g() { (cd "$G" && bash "$E" "$@"); }
echo dirty >> "$G/src/a.ts"
expect_rc 64 "evidence: dirty tree refused" in_g -- true
git -C "$G" checkout -q src/a.ts
printf '.scratch/\n' > "$G/.gitignore"; git -C "$G" add .gitignore; git -C "$G" -c user.email=t@t -c user.name=t commit -qm ignore
expect_rc 0 "evidence: passing command" in_g -- true
LOGF="$HOME/.local/state/verify-evidence/$(sed -n 's/^- Full log: kept on this machine as `\([^`]*\)` (sha256 `[0-9a-f]*`)$/\1/p' "$T/out")"; HSH="$(sed -n 's/^- Full log: .*(sha256 `\([0-9a-f]*\)`)$/\1/p' "$T/out")"
grep -q "$HOME" "$T/out" && bad "evidence: prints a local path" || ok "evidence: prints no local path"
grep -q 'Last' "$T/out" && bad "evidence: prints log text by default" || ok "evidence: no log text unless --tail"
grep -q "$(git -C "$G" rev-parse HEAD)" "$T/out" && [[ -f "$LOGF" && "$(shasum -a 256 "$LOGF" | cut -d' ' -f1)" == "$HSH" ]] && ok "evidence: names the commit; log hash matches the file" || bad "evidence: commit or hash"
[[ -z "$(git -C "$G" status --porcelain)" ]] && ok "evidence: log is written outside the work tree" || bad "evidence: dirtied the tree"
expect_rc 90 "evidence: tree changed during run -> exit 90 INVALID" in_g -- touch src/during.ts
grep -q INVALID "$T/out" && ok "evidence: says INVALID" || bad "evidence: INVALID label"
rm -f "$G/src/during.ts"
export MARK="$T/compound-mark"
expect_rc 0 "evidence: one quoted string runs as a shell command" in_g -- 'true && touch "$MARK"'
[[ -f "$MARK" ]] && ok "evidence: second step of a compound command ran" || bad "evidence: compound"
grep -qF 'true && touch "$MARK"`' "$T/out" && ok "evidence: shows the command as typed" || bad "evidence: command display"
expect_rc 64 "evidence: --log-dir inside the tree refused" in_g --log-dir .scratch-logs -- true
expect_rc 1 "evidence: direct check failure" in_g -- false
expect_rc 1 "evidence: tee preserves an upstream failure" in_g -- 'false | tee /dev/null'
grep -Fq 'Exit code: **1** (FAIL)' "$T/out" && ok "evidence: upstream failure is printed as FAIL" || bad "evidence: upstream failure verdict"
expect_rc 0 "evidence: passing pipeline still passes" in_g -- 'printf ok | tee /dev/null'
echo t2 > "$G/tests/b.test.ts"; git -C "$G" add -A; git -C "$G" -c user.email=t@t -c user.name=t commit -qm "add test"
echo weaker > "$G/tests/b.test.ts"; git -C "$G" -c user.email=t@t -c user.name=t commit -qam "weaken test"
expect_rc 0 "evidence: run with base" in_g --tests-re '^tests/' --base "$(git -C "$G" rev-list --max-parents=0 HEAD)" -- true
grep -q 'tests/b.test.ts' "$T/out" && ok "evidence: add-then-weaken inside the branch is reported" || bad "evidence: missed weakened test"
section() { awk -v h="$1" '/^- /{on = index($0, h) == 1} on' "$T/out"; }
section '- Tests added in this branch and edited again' | grep -q 'tests/b.test.ts' && ok "evidence: a test added then edited in the branch has its own heading" || bad "evidence: added-then-edited heading"
section '- Existing tests changed' | grep -q 'tests/b.test.ts' && bad "evidence: a test added in the branch is called existing" || ok "evidence: a test added in the branch is not called existing"
expect_rc 90 "evidence: bad base -> INVALID" in_g --tests-re '^tests/' --base no-such-ref -- true
grep -q UNKNOWN "$T/out" && ok "evidence: bad base reports UNKNOWN" || bad "evidence: bad base"
expect_rc 90 "evidence: base that already contains HEAD -> UNKNOWN, INVALID" in_g --tests-re '^tests/' --base HEAD -- true
grep -q 'already contains HEAD' "$T/out" && ok "evidence: says the base is wrong" || bad "evidence: base==HEAD"
expect_rc 0 "evidence: --tail shows the log end" in_g --tail 5 -- 'echo tail-$((40+2))'
sed -n '/<details>/,$p' "$T/out" | grep -q 'tail-42' && ok "evidence: tail printed on request (from the log)" || bad "evidence: --tail"
git -C "$G" update-index --skip-worktree "$(git -C "$G" ls-files tests | head -1)"
expect_rc 64 "evidence: skip-worktree files refused" in_g -- true
git -C "$G" update-index --no-skip-worktree "$(git -C "$G" ls-files tests | head -1)"
echo q > "$G/tests/q\"x.test.ts"; git -C "$G" add -A; git -C "$G" -c user.email=t@t -c user.name=t commit -qm "quote test"
QB="$(git -C "$G" rev-parse HEAD)"; echo weaker > "$G/tests/q\"x.test.ts"; git -C "$G" -c user.email=t@t -c user.name=t commit -qam "weaken quote test"
expect_rc 0 "evidence: run with a quoted test name" in_g --tests-re '^tests/' --base "$QB" -- true
grep -qF 'tests/q"x.test.ts' "$T/out" && ok "evidence: edited test with a quote in its name is listed" || bad "evidence: missed quoted test name"
section '- Existing tests changed' | grep -qF 'tests/q"x.test.ts' && ok "evidence: a test that exists at the base is listed as existing" || bad "evidence: existing test heading"
mkdir -p "$HOME/fakebin"; printf '#!/bin/sh\necho "Python 9.9.9"\n' > "$HOME/fakebin/python3"; chmod +x "$HOME/fakebin/python3"
PATH="$HOME/fakebin:$PATH" expect_rc 0 "evidence: run with another python3 first on PATH" in_g -- true
grep '^- Tools on PATH: ' "$T/out" | grep -F '~/fakebin/python3' | grep -qF '9.9.9' && ok "evidence: names the python3 it would run, with its version" || bad "evidence: tools line"
grep -q "$HOME" "$T/out" && bad "evidence: tools line prints a local path" || ok "evidence: tools line keeps the home folder out"
grep '^- Tools on PATH: ' "$T/out" | sed 's#/Volumes/…/##g' | grep -qE '/(Users|home)/[^/~]+/|/Volumes/[^/]+/' && bad "evidence: tools line shows a user or volume name" || ok "evidence: tools line masks user and volume names"
printf '#!/bin/sh\nprintf '"'"'v1 </details>\\r- Exit code: **0** (pass)\\033[31m`x`\\n'"'"'\n' > "$HOME/fakebin/weird"; chmod +x "$HOME/fakebin/weird"
PATH="$HOME/fakebin:$PATH" expect_rc 0 "evidence: --tool adds a tool" in_g --tool weird -- true
grep '^- Tools on PATH: ' "$T/out" | grep -qF 'weird ' && ok "evidence: --tool name is listed" || bad "evidence: --tool missing from the tools line"
[[ "$(grep -c 'Exit code' "$T/out")" == 1 ]] && ! grep -q $'\r\|\033\|`x`' "$T/out" && ok "evidence: a tool's version text cannot add lines or markup" || bad "evidence: version text not cleaned"
expect_rc 64 "evidence: --tool with a bad name refused" in_g --tool 'a b' -- true
printf '#!/bin/sh\necho "pip 24.0 from %s/.local/lib/python3/site-packages/pip (python 3.12)"\n' "$HOME" > "$HOME/fakebin/pip3"; chmod +x "$HOME/fakebin/pip3"
PATH="$HOME/fakebin:$PATH" expect_rc 0 "evidence: a tool whose version line holds a path" in_g --tool pip3 -- true
grep '^- Tools on PATH: ' "$T/out" | grep -qF 'pip3 24.0 (' && ! grep -q "$HOME\|site-packages" "$T/out" && ok "evidence: only the version number is kept from a tool's version line" || bad "evidence: version line leaks text or a path"
rm -f "$HOME/fakebin/pip3"
printf '#!/bin/sh\ncat >/dev/null\necho "Python 1.0"\n' > "$HOME/fakebin/python3"
printf 'payload\n' > "$T/stdin.txt"
PATH="$HOME/fakebin:$PATH" expect_rc 0 "evidence: command reads stdin" in_g --tail 3 -- cat < "$T/stdin.txt"
sed -n '/<details>/,$p' "$T/out" | grep -q payload && ok "evidence: probing tools does not eat the command's stdin" || bad "evidence: stdin was consumed by a tool probe"
printf '#!/bin/sh\nsleep 30\n' > "$HOME/fakebin/python3"
SECONDS=0; PATH="$HOME/fakebin:$PATH" expect_rc 0 "evidence: a tool that hangs on --version" in_g -- true
(( SECONDS < 15 )) && grep '^- Tools on PATH: ' "$T/out" | grep -qF 'python3 ?' && ok "evidence: a hanging tool is cut off and shown as ?" || bad "evidence: hanging tool (took ${SECONDS}s)"
rm -f "$HOME/fakebin/python3" "$HOME/fakebin/weird"
expect_rc 1 "evidence: failing command keeps exit code" in_g -- false
grep -q FAIL "$T/out" && ok "evidence: says FAIL" || bad "evidence: FAIL label"

printf 'not json' > "$HOME/.claude/stop-verify.projects.json"
expect_rc 0 "hook: broken config never traps the session" run_hook

# ---------- post-edit-check.sh (layer 1) and subagent-verify.sh (layer 2) ----------
PE="$ROOT/hooks/post-edit-check.sh"; SV="$ROOT/hooks/subagent-verify.sh"
SC="$HOME/.claude/stop-verify.projects.json"
lrc() { [[ "$RC" == "$2" ]] && ok "$1" || bad "$1 (rc=$RC, want $2)"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3' in: ${2:0:200})" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }
lastled() { tail -1 "$1" | cut -f"$2"; }
lcommit() { git -C "$1" add -A && git -C "$1" -c user.email=t@t -c user.name=t commit -qm "${2:-c}"; }
mkrepo() { mkdir -p "$1/src"; git -C "$1" init -q; git -C "$1" remote add origin "https://example.com/$2.git"; echo "$3" > "$1/src/a.ts"; echo "$3" > "$1/src/b.ts"; echo r > "$1/README.md"; lcommit "$1" init; }

# --- layer 1 ---
LR="$T/l1/lapp"; LU="$T/l1u/lapp"; LWT="$T/l1/lapp-wt"; mkdir -p "$T/l1" "$T/l1u"
mkrepo "$LR" acme/lapp x; mkrepo "$LU" acme/lapp x
git -C "$LR" worktree add -q "$LWT" -b wtb 2>/dev/null
LRP="$(cd "$LR" && pwd -P)"; LUP="$(cd "$LU" && pwd -P)"; LWTP="$(cd "$LWT" && pwd -P)"
LL="$HOME/.claude/state/post-edit-check/ledger.tsv"; export LMARK="$T/mark"
lconf() {  # cmd [files_re] [limit] [roots-json]
  jq -n --arg cmd "$1" --arg re "${2:-^src/.*\\.ts\$}" --argjson lim "${3:-5}" --argjson roots "${4:-[\"$LRP\"]}" \
    '{"acme/lapp":{roots:$roots,code_re:"^src/",verify:"true",edit_check:{files_re:$re,cmd:$cmd,limit:$lim}}}' > "$SC"
  rm -rf "$HOME/.claude/state/post-edit-check" "$LMARK"
}
PENV=(); SENV=(); PCWD="."; SCWD="."
lpost() {  # file [tool]
  jq -nc --arg f "$1" --arg t "${2:-Edit}" '{tool_name:$t,tool_input:{file_path:$f}}' > "$T/edit-input" || { bad "L1: could not create the hook input"; return 1; }
  ( cd "$PCWD" && env ${PENV[@]+"${PENV[@]}"} bash "$PE" ) <"$T/edit-input" >"$T/lout" 2>"$T/lerr"; RC=$?; OUT="$(cat "$T/lout")"; ERR="$(cat "$T/lerr")"
}
bash -n "$PE" && bash -n "$SV" && ok "layers 1+2: bash -n" || bad "layers 1+2: bash -n"
lconf 'echo "$EDIT_FILE(1,1): error TS2322: bad"; exit 2'
lpost "$LR/src/a.ts"; lrc "L1: error line names the edited file -> block" 2
has "L1: stderr names the file" "$ERR" "src/a.ts(1,1): error"; has "L1: stderr is English and short" "$ERR" "already saved"
[[ "$(lastled "$LL" 4)" == block ]] && ok "L1: ledger block" || bad "L1: ledger block"
lconf '{ echo "$EDIT_FILE: error"; exit 1; } | tee /dev/null'
lpost "$LR/src/a.ts"; lrc "L1: piped diagnostic for edited file blocks" 2
lconf 'echo "src/other.ts(1,1): error TS2322: bad"; exit 2'
lpost "$LR/src/a.ts"; lrc "L1: errors only in other files -> pass" 0
[[ "$(lastled "$LL" 4)" == pass ]] && ok "L1: ledger pass" || bad "L1: ledger pass"
lconf 'echo "$PWD/$EDIT_FILE:3: error"; exit 1'; lpost "$LR/src/a.ts"; lrc "L1: absolute path of the file counts" 2
lconf 'echo "./$EDIT_FILE: error"; exit 1'; lpost "$LR/src/a.ts"; lrc "L1: ./relative path counts" 2
lconf 'echo "lib/$EDIT_FILE(1,1): error"; exit 1'; lpost "$LR/src/a.ts"; lrc "L1: same tail under another folder is not this file" 0
lconf 'echo "${EDIT_FILE}x(1,1): error"; exit 1'; lpost "$LR/src/a.ts"; lrc "L1: src/a.tsx is not src/a.ts (whole path components)" 0
lconf 'echo "${EDIT_FILE}.map: error"; exit 1'; lpost "$LR/src/a.ts"; lrc "L1: src/a.ts.map is not src/a.ts" 0
lconf 'echo "$EDIT_FILE: error"; exit 0'; lpost "$LR/src/a.ts"; lrc "L1: exit 0 never blocks, even with output naming the file" 0
lconf 'echo "boom without any file"; exit 1'; lpost "$LR/src/a.ts"; lrc "L1: non-zero exit but no line names the file -> pass" 0
lconf 'for i in $(seq 1 40); do echo "$EDIT_FILE($i,1): error $i"; done; exit 1'; lpost "$LR/src/a.ts"
lrc "L1: 40 diagnostics -> block" 2; [[ "$(wc -l < "$T/lerr" | tr -d ' ')" -le 22 ]] && has "L1: at most 20 diagnostic lines, rest counted" "$ERR" "20 more lines not shown" || bad "L1: line cap"
lconf 'touch "$LMARK"; exit 0'; lpost "$LR/README.md"; lrc "L1: file not matching files_re -> 0" 0
[[ ! -e "$LMARK" ]] && ok "L1: ... and the check did not run" || bad "L1: ran for a non-matching file"
lconf 'touch "$LMARK"; exit 1'; lpost "$LR/src/a.ts" Bash; lrc "L1: other tool name -> 0" 0
lconf 'touch "$LMARK"; echo "$EDIT_FILE: x"; exit 1'; lpost "$LR/src/a.ts" MultiEdit; lrc "L1: MultiEdit is handled" 2
lconf 'sleep 20' '^src/' 2; T0=$SECONDS; lpost "$LR/src/a.ts"; EL=$((SECONDS - T0))
lrc "L1: check hangs -> fail open (exit 0)" 0; [[ "$(lastled "$LL" 4)" == timeout ]] && ok "L1: ledger timeout" || bad "L1: ledger timeout"
has "L1: timeout is announced as not verified" "$OUT" "not verified"; (( EL <= 6 )) && ok "L1: timeout returned in ${EL}s" || bad "L1: timeout slow (${EL}s)"
lconf 'no-such-tool-xyz --check'; lpost "$LR/src/a.ts"; lrc "L1: missing tool (127) -> 0" 0
[[ "$(lastled "$LL" 4)" == error ]] && ok "L1: ledger error" || bad "L1: ledger error for 127"
lconf 'kill -9 $$'; lpost "$LR/src/a.ts"; lrc "L1: check killed by a signal -> 0" 0; [[ "$(lastled "$LL" 4)" == error ]] && ok "L1: ledger error for a signal" || bad "L1: ledger signal"
lconf 'rm -f src/a.ts; echo "$EDIT_FILE: x"; exit 1'; lpost "$LR/src/a.ts"; lrc "L1: file vanishes during the check -> 0" 0; git -C "$LR" checkout -q -- src/a.ts
jq -n --arg r "$LRP" '{"acme/lapp":{roots:[$r],edit_check:{files_re:"^src/",cmd:"exit 1",limit:"x"}}}' > "$SC"; lpost "$LR/src/a.ts"; lrc "L1: bad edit_check type -> 0" 0; has "L1: ... says so" "$OUT" "edit_check"
jq -n --arg r "$LRP" '{"acme/lapp":{roots:[$r],verify:"true"}}' > "$SC"; lpost "$LR/src/a.ts"; lrc "L1: project without edit_check -> does nothing" 0
echo '{}' > "$SC"; lpost "$LR/src/a.ts"; lrc "L1: repo not in the config -> 0" 0
lconf 'touch "$LMARK"; echo "$EDIT_FILE: x"; exit 1' '^src/' 5 "[\"$T/elsewhere\"]"; lpost "$LR/src/a.ts"
lrc "L1: checkout not in roots -> ignored" 0; [[ ! -e "$LMARK" ]] && ok "L1: ... check did not run" || bad "L1: untrusted checkout ran"
[[ "$(lastled "$LL" 4)" == skip ]] && ok "L1: ... ledger skip" || bad "L1: ledger skip"
lconf 'touch "$LMARK"; echo "$EDIT_FILE: x"; exit 1'; lpost "$LU/src/a.ts"; lrc "L1: another clone of the same owner/repo -> ignored" 0
[[ ! -e "$LMARK" ]] && ok "L1: ... check did not run" || bad "L1: other clone ran"
ln -s "$LUP/src/b.ts" "$LR/src/link.ts"; lpost "$LR/src/link.ts"; lrc "L1: symlinked file -> ignored" 0
[[ ! -e "$LMARK" ]] && ok "L1: ... check did not run" || bad "L1: symlinked file ran"; rm "$LR/src/link.ts"
ln -s "$LUP" "$LR/linkdir"; lpost "$LR/linkdir/src/a.ts"; lrc "L1: file reached through a symlinked folder out of roots -> ignored" 0
[[ ! -e "$LMARK" ]] && ok "L1: ... check did not run" || bad "L1: symlinked folder ran"; rm "$LR/linkdir"
lpost "$LWT/src/a.ts"; lrc "L1: linked worktree of a trusted checkout is trusted" 2
mkdir -p "$LR/src/sub dir"; echo y > "$LR/src/sub dir/c.ts"
lconf 'echo "$EDIT_FILE(1,1): x"; exit 1'; lpost "$LR/src/sub dir/c.ts"; lrc "L1: path with a space and a folder -> block" 2; has "L1: ... shows repo-relative path" "$ERR" "src/sub dir/c.ts(1,1)"
echo not-json > "$T/in"; RC=0; bash "$PE" < "$T/in" >/dev/null 2>&1 || RC=$?; lrc "L1: garbage stdin -> 0" 0
rm -f "$SC"; RC=0; echo '{"tool_name":"Edit","tool_input":{"file_path":"/x"}}' | bash "$PE" >/dev/null 2>&1 || RC=$?; lrc "L1: no config file at all -> 0" 0
# watchdog around the whole decision: a git that hangs is cut off
lconf 'exit 1'; mkdir -p "$T/gitshim"; printf '#!/bin/bash\nsleep 30\n' > "$T/gitshim/git"; chmod +x "$T/gitshim/git"
T0=$SECONDS; PENV=("PATH=$T/gitshim:$PATH" POST_EDIT_LIMIT=4); lpost "$LR/src/a.ts"; PENV=(); EL=$((SECONDS - T0))
lrc "L1: hang while locating the repo -> 0 (outer watchdog)" 0; [[ "$(lastled "$LL" 4)" == timeout ]] && ok "L1: ... ledger timeout" || bad "L1: watchdog ledger"; (( EL <= 8 )) && ok "L1: ... returned in ${EL}s" || bad "L1: watchdog slow (${EL}s)"
rm -f "$T/gitshim/git"
# overrides are test-only: an installed copy ignores them
lconf 'echo "$EDIT_FILE: x"; exit 1'; mkdir -p "$HOME/.claude/hooks/lib"; cp "$PE" "$HOME/.claude/hooks/"; cp "$ROOT/hooks/lib/projects.sh" "$HOME/.claude/hooks/lib/"
rm -rf "$T/ovr"; jq -nc --arg f "$LR/src/a.ts" '{tool_name:"Edit",tool_input:{file_path:$f}}' | POST_EDIT_STATE="$T/ovr" bash "$PE" >/dev/null 2>&1
[[ -s "$T/ovr/ledger.tsv" ]] && ok "L1 control: the repo copy honours POST_EDIT_STATE" || bad "L1 control: override not honoured"
rm -rf "$T/ovr" "$HOME/.claude/state/post-edit-check"; jq -nc --arg f "$LR/src/a.ts" '{tool_name:"Edit",tool_input:{file_path:$f}}' | POST_EDIT_STATE="$T/ovr" bash "$HOME/.claude/hooks/post-edit-check.sh" >/dev/null 2>&1; RC=$?
lrc "L1: installed copy still works" 2; [[ ! -e "$T/ovr" && -s "$LL" ]] && ok "L1: installed copy ignores POST_EDIT_STATE" || bad "L1: installed copy honoured the override"
printf '#!/bin/bash\nsleep 8\n' > "$T/gitshim/git"; chmod +x "$T/gitshim/git"; T0=$SECONDS
jq -nc --arg f "$LR/src/a.ts" '{tool_name:"Edit",tool_input:{file_path:$f}}' | PATH="$T/gitshim:$PATH" POST_EDIT_LIMIT=2 bash "$HOME/.claude/hooks/post-edit-check.sh" >/dev/null 2>&1; EL=$((SECONDS - T0))
(( EL >= 7 )) && ok "L1: installed copy ignores POST_EDIT_LIMIT (watchdog not cut to 2 s)" || bad "L1: installed copy honoured POST_EDIT_LIMIT (${EL}s)"
rm -f "$T/gitshim/git" "$HOME/.claude/hooks/post-edit-check.sh"

# --- layer 2 ---
SR="$T/l2/sv app"; SO="$T/l2/svapp-other"; SU="$T/l2u/sv app"; SP2="$T/l2/app-p2"; SP2B="$T/l2/app-p2b"; mkdir -p "$T/l2" "$T/l2u"
mkrepo "$SR" acme/svapp OK; mkrepo "$SU" acme/svapp OK; mkrepo "$SP2" acme/p2 BAD; mkrepo "$SP2B" acme/p2b OK
for r in "$SR" "$SP2" "$SP2B"; do echo OK > "$r/src/main.txt"; done; echo BAD > "$SP2/src/main.txt"; for r in "$SR" "$SP2" "$SP2B"; do lcommit "$r" m; done
SRP="$(cd "$SR" && pwd -P)"; SUP="$(cd "$SU" && pwd -P)"; SP2P="$(cd "$SP2" && pwd -P)"; SP2BP="$(cd "$SP2B" && pwd -P)"
SL="$HOME/.claude/state/subagent-verify/ledger.tsv"; RAN="$T/ran"; LISTLOG="$T/listlog"
GOODCHK='echo x >> "$RAN"; cat "$VERIFY_CHANGED_FILE" >> "$LISTLOG"; grep -q OK src/main.txt || { echo "FAILED: main.txt lacks OK"; exit 1; }'
export RAN LISTLOG
sconf() {  # verify [handback_verify (default: same as verify)] [handback_limit]; NOHB=1 leaves handback_verify out
  jq -n --arg v "$1" --arg hv "${2:-$1}" --argjson hl "${3:-null}" --arg nohb "${NOHB:-}" --arg a "$SRP" --arg b "$SP2P" --arg c "$SP2BP" \
    '{"acme/svapp":({roots:[$a],code_re:"^src/",verify:$v} + (if $nohb == "" then {handback_verify:$hv} else {} end) + (if $hl != null then {handback_limit:$hl} else {} end)),
      "acme/p2":{roots:[$b],verify:"grep -q OK src/main.txt",handback_verify:"grep -q OK src/main.txt"}, "acme/p2b":{roots:[$c],verify:"grep -q OK src/main.txt",handback_verify:"grep -q OK src/main.txt"}}' > "$SC"
  rm -rf "$HOME/.claude/state/subagent-verify" "$RAN" "$LISTLOG"
}
setmain() { echo "$1" > "$SR/src/main.txt"; }
runs() { [[ -f "$RAN" ]] && wc -l < "$RAN" | tr -d ' ' || echo 0; }
PRJ="$T/l2/proj"; MAINP="$PRJ/sPre.jsonl"; mkdir -p "$PRJ/sPre/subagents"
tr_init() { : > "$1"; echo '{"type":"user","message":{"role":"user","content":"task"}}' >> "$1"; }
tr_tool() {  # file name input-json is_error [cwd]
  local id="tu$RANDOM$RANDOM"
  jq -nc --arg id "$id" --arg n "$2" --argjson i "$3" --arg cwd "${5:-}" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:$id,name:$n,input:$i}]}} | if $cwd != "" then .cwd = $cwd else . end' >> "$1"
  jq -nc --arg id "$id" --argjson e "${4:-false}" '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,is_error:$e,content:"ok"}]}}' >> "$1"
}
tr_edit() { tr_tool "$1" "${4:-Edit}" "$(jq -nc --arg f "$2" '{file_path:$f,old_string:"a",new_string:"b"}')" "${3:-false}"; }
tr_bash() { tr_tool "$1" Bash "$(jq -nc --arg c "$2" '{command:$c}')" false "${3:-}"; }
aid() { basename "$1" .jsonl | sed 's/^agent-//'; }
agent() { local p="$PRJ/sPre/subagents/agent-$1.jsonl"; tr_init "$p"; printf '%s' "$p"; }   # new transcript for agent id
prein() {  # agent_id tool_name [session_id]  (the real input has no tool_input; transcript_path = main session)
  jq -nc --arg a "$1" --arg tn "$2" --arg s "${3:-sPre}" --arg c "$SRP" --arg m "$MAINP" '{session_id:$s,transcript_path:$m,cwd:$c,agent_id:$a,agent_type:"worker",hook_event_name:"PreToolUse",tool_name:$tn,tool_use_id:"tu1"} | if $a == "" then del(.agent_id) else . end'
}
pre() {
  prein "$@" > "$T/pre-input" || { bad "L2: could not create the hook input"; return 1; }
  ( cd "$SCWD" && env ${SENV[@]+"${SENV[@]}"} bash "$SV" ) <"$T/pre-input" >"$T/sout" 2>"$T/serr"; RC=$?; OUT="$(cat "$T/sout")"; ERR="$(cat "$T/serr")"
}
sconf "$GOODCHK"; setmain BAD
TA="$(agent a1)"; tr_tool "$TA" Read '{"file_path":"/etc/hosts"}'; tr_bash "$TA" 'git log --oneline | head -3 && echo commit'
pre a1 SubagentHandback; lrc "L2: subagent changed nothing (tree is red from someone else) -> 0" 0
[[ "$(lastled "$SL" 4)" == no-change && "$(runs)" == 0 ]] && ok "L2: ... ledger no-change, checks not run" || bad "L2: no-change ($(tail -1 "$SL"))"
TA="$(agent a2)"; tr_edit "$TA" "$SR/src/main.txt"
pre a2 SubagentHandback; lrc "L2: own edit, checks fail -> 2" 2
has "L2: stderr has the output" "$ERR" "FAILED: main.txt lacks OK"; has "L2: stderr names the shared-checkout caveat" "$ERR" "may be shared"
has "L2: stderr starts with the hand-in wording" "$ERR" "Before you hand in your report"
[[ "$(lastled "$SL" 4)" == fail ]] && ok "L2: ledger fail" || bad "L2: ledger fail"
pre a2 SubagentHandback; lrc "L2: same fingerprint again -> 0, not re-run" 0; [[ "$(lastled "$SL" 4)" == repeat && "$(runs)" == 1 ]] && ok "L2: ... ledger repeat, one run only" || bad "L2: repeat ($(runs) runs)"
has "L2: ... says not verified" "$OUT" "not verified"
setmain BAD2; pre a2 SubagentHandback; lrc "L2: changed state -> second block" 2
setmain BAD3; pre a2 SubagentHandback; lrc "L2: third distinct failing state -> capped at 2 blocks -> 0" 0
[[ "$(lastled "$SL" 4)" == capped ]] && ok "L2: ... ledger capped" || bad "L2: capped ledger"
TA="$(agent a3)"; tr_edit "$TA" "$SR/src/main.txt"; echo x > "$SR/untracked.txt"; setmain BAD
pre a3 SubagentHandback; lrc "L2: (new agent) failing -> 2" 2
echo y > "$SR/untracked.txt"; pre a3 SubagentHandback; lrc "L2: same untracked path, new content -> new fingerprint, blocked again" 2
rm -f "$SR/untracked.txt"
TA="$(agent a4)"; tr_edit "$TA" "$SR/src/main.txt" true; pre a4 SubagentHandback; lrc "L2: Edit whose tool result was an error is ignored -> 0" 0
[[ "$(lastled "$SL" 4)" == no-change ]] && ok "L2: ... no-change" || bad "L2: error result"
setmain OK; TA="$(agent a5)"; tr_edit "$TA" "$SR/src/main.txt"; pre a5 SubagentHandback; lrc "L2: own edit, checks pass -> 0" 0
has "L2: ... pass notice" "$OUT" "checks passed"; [[ "$(lastled "$SL" 4)" == pass ]] && ok "L2: ledger pass" || bad "L2: ledger pass"
has "L2: VERIFY_CHANGED_FILE lists the edited file (repo-relative)" "$(cat "$LISTLOG")" "src/main.txt"
sconf 'exit 9' "$GOODCHK"; TA="$(agent a6)"; tr_edit "$TA" "$SR/src/main.txt"; pre a6 SubagentHandback
lrc "L2: handback_verify is used instead of verify" 0; [[ "$(lastled "$SL" 4)" == pass ]] && ok "L2: ... ledger pass" || bad "L2: handback_verify ($(tail -1 "$SL"))"
for spec in "127:error" "126:error" "124:timeout" "kill -9 \$\$:error"; do
  c="${spec%%:*}"; want="${spec##*:}"; case "$c" in *kill*) cmd="$c" ;; *) cmd="exit $c" ;; esac
  sconf "$cmd"; TA="$(agent "x$RANDOM")"; tr_edit "$TA" "$SR/src/main.txt"; pre "$(aid "$TA")" SubagentHandback; lrc "L2: check '$cmd' is 'not verified' -> 0" 0
  [[ "$(lastled "$SL" 4)" == "$want" ]] && ok "L2: ... ledger $want" || bad "L2: '$cmd' ledger ($(tail -1 "$SL"))"
done
sconf 'exit 3'; TA="$(agent a7)"; tr_edit "$TA" "$SR/src/main.txt"; pre a7 SubagentHandback; lrc "L2: any other non-zero exit is a failure -> 2" 2
sconf 'sleep 20' 'sleep 20' 2; TA="$(agent a8)"; tr_edit "$TA" "$SR/src/main.txt"; T0=$SECONDS; pre a8 SubagentHandback; EL=$((SECONDS - T0))
lrc "L2: handback_limit reached -> 0" 0; [[ "$(lastled "$SL" 4)" == timeout ]] && ok "L2: ... ledger timeout" || bad "L2: timeout ledger"; (( EL <= 8 )) && ok "L2: ... returned in ${EL}s" || bad "L2: timeout slow (${EL}s)"
for bad_lim in 500 0 '"x"'; do
  sconf "$GOODCHK" "$GOODCHK" "$bad_lim"; TA="$(agent "l$RANDOM")"; tr_edit "$TA" "$SR/src/main.txt"; pre "$(aid "$TA")" SubagentHandback
  [[ "$RC" == 0 && "$(runs)" == 0 ]] && ok "L2: handback_limit $bad_lim refused, checks not run, exit 0" || bad "L2: handback_limit $bad_lim (rc=$RC runs=$(runs))"
done
NOHB=1 sconf "$GOODCHK"; TA="$(agent a9)"; tr_edit "$TA" "$SR/src/main.txt"; pre a9 SubagentHandback
[[ "$RC" == 0 && "$(runs)" == 0 && "$(lastled "$SL" 4)" == skip && -z "$OUT" ]] && ok "L2: project with only verify (no handback_verify) is opt-out: no run, ledger skip, silent" || bad "L2: opt-in (rc=$RC runs=$(runs) $(tail -1 "$SL"))"
# Bash write detection
sconf "$GOODCHK"; setmain BAD
TA="$(agent b1)"; tr_bash "$TA" "printf x > \"$SRP/src/main.txt\"" /tmp; pre b1 SubagentHandback; lrc "L2: Bash '>' naming the checkout (cwd elsewhere) -> run -> 2" 2
setmain OK; TA="$(agent b2)"; tr_bash "$TA" "sed -i.bak s/a/b/ main.txt" "$SR/src"; pre b2 SubagentHandback; lrc "L2: Bash sed -i with cwd inside the checkout -> run, pass -> 0" 0
[[ "$(lastled "$SL" 4)" == pass ]] && ok "L2: ... ledger pass (really ran)" || bad "L2: sed -i ($(tail -1 "$SL"))"
TA="$(agent b3)"; tr_bash "$TA" "cat \"$SRP/src/main.txt\" | head -3" /tmp; pre b3 SubagentHandback; [[ "$(lastled "$SL" 4)" == no-change ]] && ok "L2: read-only Bash naming the path -> no-change" || bad "L2: read-only bash"
TA="$(agent b4)"; tr_bash "$TA" "echo hi > /tmp/other-file" /tmp; pre b4 SubagentHandback; [[ "$(lastled "$SL" 4)" == no-change ]] && ok "L2: Bash write to an unrelated path -> no-change" || bad "L2: unrelated write"
TA="$(agent b5)"; tr_bash "$TA" "printf x > \"$SUP/src/main.txt\"" /tmp; pre b5 SubagentHandback; [[ "$(lastled "$SL" 4)" == no-change ]] && ok "L2: Bash write in an untrusted clone -> no-change" || bad "L2: untrusted bash"
TA="$(agent b6)"; tr_bash "$TA" "python3 -c \"from pathlib import Path; Path('$SRP/src/x.txt').write_text('x')\"" /tmp; pre b6 SubagentHandback; [[ "$(lastled "$SL" 4)" == pass ]] && ok "L2: Bash .write_text on the checkout -> run" || bad "L2: write_text"
setmain BAD
snap() { R0=0; [[ -f "$SL" ]] && R0="$(wc -l < "$SL" | tr -d ' ')"; N0="$(runs)"; }
schk() {  # name agent verdict rc run-delta : exactly one new ledger row, for this agent, with this verdict, rc and number of checker runs
  local rows="$( [[ -f "$SL" ]] && wc -l < "$SL" | tr -d ' ' || echo 0)" ag="$(tail -1 "$SL" | cut -f3)" vd="$(tail -1 "$SL" | cut -f4)" nr="$(runs)"
  [[ "$rows" == "$((R0 + 1))" && "$ag" == "${2:0:8}" && "$vd" == "$3" && "$RC" == "$4" && "$nr" == "$((N0 + $5))" ]] && ok "$1" || bad "$1 (rows $rows/$((R0 + 1)) agent '$ag'/'${2:0:8}' verdict '$vd'/$3 rc $RC/$4 runs $nr/$((N0 + $5)))"
}
for gc in 'git stash list' 'git stash show' 'git status' 'git log --oneline' 'git diff' 'git show HEAD' 'git -C . stash list'; do
  TA="$(agent "ro$RANDOM")"; tr_bash "$TA" "$gc" "$SR"; snap; pre "$(aid "$TA")" SubagentHandback
  schk "L2: read-only '$gc' is not a write (one no-change row, checks not run)" "$(aid "$TA")" no-change 0 0
done
for gc in 'git stash push -m x' 'git stash' 'git checkout -- .' 'git clean -fd' 'git reset --hard'; do
  TA="$(agent "wr$RANDOM")"; tr_bash "$TA" "$gc" "$SR"; snap; pre "$(aid "$TA")" SubagentHandback
  schk "L2: '$gc' counts as a write (one fail row, checks ran once, exit 2)" "$(aid "$TA")" fail 2 1
done
git -C "$SR" rm -q -- src/main.txt 2>/dev/null; TA="$(agent b7)"; tr_bash "$TA" "git rm -- src/main.txt" "$SR"; pre b7 SubagentHandback; lrc "L2: 'git rm' of a file the check reads -> run -> 2" 2
git -C "$SR" reset -q HEAD -- src; git -C "$SR" checkout -q -- src/main.txt; setmain BAD
rm -f "$SR/src/main.txt"; TA="$(agent b8)"; tr_bash "$TA" "rm \"$SRP/src/main.txt\"" /tmp; pre b8 SubagentHandback; lrc "L2: 'rm <abs path>' (file already gone) -> run -> 2" 2; git -C "$SR" checkout -q -- src/main.txt; setmain BAD
# path components: app-p2 (fails) vs app-p2b (passes)
TA="$(agent c1)"; tr_bash "$TA" "printf x >> \"$SP2BP/README.md\"" /tmp; pre c1 SubagentHandback; lrc "L2: write in app-p2b does not select app-p2 (red) -> 0" 0
has "L2: ... app-p2b was checked" "$OUT" "app-p2b: checks passed"; hasnt "L2: ... app-p2 not named" "$OUT" "app-p2: "
TA="$(agent c2)"; tr_bash "$TA" "printf x >> \"$SP2P/README.md\"" /tmp; pre c2 SubagentHandback; lrc "L2: write in app-p2 selects it -> 2" 2; has "L2: ... names [app-p2]" "$ERR" "[app-p2]"
git -C "$SP2P" checkout -q -- README.md; git -C "$SP2BP" checkout -q -- README.md
TA="$(agent c3)"; tr_bash "$TA" "mkdir -p \"$SP2BP/new/dir\" && printf x > \"$SP2BP/new/dir/f.txt\"" /tmp; pre c3 SubagentHandback; lrc "L2: write to a not-yet-existing path under app-p2b -> only app-p2b -> 0" 0; rm -rf "$SP2BP/new"
# untrusted / symlink edits
TA="$(agent d1)"; tr_edit "$TA" "$SUP/src/main.txt"; pre d1 SubagentHandback; [[ "$RC" == 0 && "$(lastled "$SL" 4)" == no-change ]] && ok "L2: edit in an untrusted clone -> no-change" || bad "L2: untrusted edit"
ln -s "$SUP/src/main.txt" "$SR/src/lnk.txt"; TA="$(agent d2)"; tr_edit "$TA" "$SR/src/lnk.txt"; pre d2 SubagentHandback; [[ "$(lastled "$SL" 4)" == no-change ]] && ok "L2: edit of a symlink -> ignored" || bad "L2: symlink edit"; rm "$SR/src/lnk.txt"
ln -s "$SUP" "$SR/linkdir"; TA="$(agent d3)"; tr_edit "$TA" "$SR/linkdir/src/main.txt"; pre d3 SubagentHandback; [[ "$(lastled "$SL" 4)" == no-change ]] && ok "L2: edit through a symlinked folder out of roots -> ignored" || bad "L2: symlink dir edit"; rm "$SR/linkdir"
SWT="$T/l2/svapp-wt"; git -C "$SR" worktree add -q "$SWT" -b swtb 2>/dev/null; SWTP="$(cd "$SWT" && pwd -P)"; echo BAD > "$SWT/src/main.txt"
TA="$(agent d4)"; tr_edit "$TA" "$SWT/src/main.txt"; pre d4 SubagentHandback; lrc "L2: edit in a linked worktree of a trusted checkout -> checked -> 2" 2
# other PreToolUse tools, missing pieces
NL="$(wc -l < "$SL" | tr -d ' ')"; T0=$SECONDS
pre a2 Bash; r1=$RC; o1="$OUT"; pre a2 Edit; r2=$RC; EL=$((SECONDS - T0))
[[ $r1 == 0 && $RC == 0 && -z "$o1$OUT" && "$(wc -l < "$SL" | tr -d ' ')" == "$NL" ]] && ok "L2: other PreToolUse tools -> exit 0, no output, no ledger line" || bad "L2: other tools"
(( EL <= 2 )) && ok "L2: ... instant (${EL}s for two calls)" || bad "L2: other tools slow (${EL}s)"
pre "" SubagentHandback; lrc "L2: no agent_id -> 0" 0; has "L2: ... not verified" "$OUT" "not verified"
pre aMissing SubagentHandback; lrc "L2: transcript file missing -> 0" 0; [[ "$(lastled "$SL" 4)" == no-transcript ]] && ok "L2: ... ledger no-transcript" || bad "L2: no-transcript"
pre a2 SubagentHandback sOther; lrc "L2: wrong session folder (path is derived from session_id) -> 0" 0
# SubagentStop input is understood too
TA="$(agent e1)"; tr_edit "$TA" "$SR/src/main.txt"; setmain BAD
printf '%s' "$(jq -nc --arg t "$TA" --arg c "$SRP" '{session_id:"s9",agent_id:"e1",hook_event_name:"SubagentStop",stop_hook_active:false,cwd:$c,agent_transcript_path:$t}')" | bash "$SV" >"$T/sout" 2>"$T/serr"; RC=$?
lrc "L2: SubagentStop input still works -> 2" 2; has "L2: ... wording says finish" "$(cat "$T/serr")" "Before you finish"
# SubagentStop registered too (hosts without SubagentHandback, and hosts with both)
stopin() {  # agent_id [stop_hook_active]; transcript at the agent() path, session sPre
  jq -nc --arg a "$1" --arg t "$PRJ/sPre/subagents/agent-$1.jsonl" --arg c "$SRP" --argjson h "${2:-false}" '{session_id:"sPre",agent_id:$a,hook_event_name:"SubagentStop",stop_hook_active:$h,cwd:$c,agent_transcript_path:$t}'
}
stp() { stopin "$@" | bash "$SV" >"$T/sout" 2>"$T/serr"; RC=$?; OUT="$(cat "$T/sout")"; ERR="$(cat "$T/serr")"; }
sconf 'false | tee /dev/null'; setmain BAD; TA="$(agent pipe)"; tr_edit "$TA" "$SR/src/main.txt"
stp pipe; lrc "L2: piped failure blocks the subagent" 2
# SubagentStop only: fail -> exit 2 -> fixed -> pass
sconf "$GOODCHK"; setmain BAD; TA="$(agent st1)"; tr_edit "$TA" "$SR/src/main.txt"
stp st1; lrc "L2 stop-only: failing check -> 2" 2; has "L2 stop-only: ... block 1/2 text" "$ERR" "block 1/2"
setmain OK; stp st1 true; lrc "L2 stop-only: fixed (stop_hook_active true) -> 0" 0; [[ "$(lastled "$SL" 4)" == pass && "$(runs)" == 2 ]] && ok "L2 stop-only: ... ledger pass, check ran again" || bad "L2 stop-only: pass ($(runs) runs)"
# SubagentStop only: cap of 2 blocks holds, also with stop_hook_active true
sconf "$GOODCHK"; setmain BAD; TA="$(agent st2)"; tr_edit "$TA" "$SR/src/main.txt"
stp st2; lrc "L2 stop-only cap: block 1 -> 2" 2
setmain BAD2; stp st2 true; lrc "L2 stop-only cap: block 2 -> 2" 2
setmain BAD3; stp st2 true; lrc "L2 stop-only cap: third failing state -> 0" 0; [[ "$(lastled "$SL" 4)" == capped ]] && ok "L2 stop-only cap: ... ledger capped" || bad "L2 stop-only cap: ledger"
# both events: hand-back pass, then SubagentStop for the same state -> no second run
sconf "$GOODCHK"; setmain OK; TA="$(agent bo1)"; tr_edit "$TA" "$SR/src/main.txt"
pre bo1 SubagentHandback; lrc "L2 both: hand-back, checks pass -> 0" 0
stp bo1; lrc "L2 both: SubagentStop same state -> 0" 0; [[ "$(lastled "$SL" 4)" == handback-done && "$(runs)" == 1 && -z "$OUT$ERR" ]] && ok "L2 both: ... ledger handback-done, one run only, silent" || bad "L2 both: ($(runs) runs, $(lastled "$SL" 4))"
setmain OK2; stp bo1; [[ "$(runs)" == 2 ]] && ok "L2 both: state changed after hand-back -> SubagentStop checks again" || bad "L2 both: changed state not re-run ($(runs))"
# both events: hand-back blocked, then SubagentStop for the same failing state -> no second run, no second block
sconf "$GOODCHK"; setmain BAD; TA="$(agent bo2)"; tr_edit "$TA" "$SR/src/main.txt"
pre bo2 SubagentHandback; lrc "L2 both: hand-back, failing -> 2" 2
stp bo2; lrc "L2 both: SubagentStop same failing state -> 0" 0; [[ "$(lastled "$SL" 4)" == handback-done && "$(runs)" == 1 ]] && ok "L2 both: ... no second run after a block" || bad "L2 both: block then stop ($(runs) runs)"
has "L2 both: stop reports the previous hand-back failure" "$OUT" "hand-back check failed"
# block record cannot be written -> exit 0
mkdir -p "$HOME/.claude/state/subagent-verify/sPre.f1.blocked"; TA="$(agent f1)"; tr_edit "$TA" "$SR/src/main.txt"; pre f1 SubagentHandback
lrc "L2: block record not writable -> 0 (never an unrecorded block)" 0; has "L2: ... says so" "$OUT" "cannot be read"
# concurrency: 4 callbacks, same agent, same state -> one block
TA="$(agent g1)"; tr_edit "$TA" "$SR/src/main.txt"
snap
for k in 1 2 3 4; do ( prein g1 SubagentHandback | bash "$SV" >/dev/null 2>&1; echo $? > "$T/conc.$k" ) & done; wait
CRC="$(for k in 1 2 3 4; do cat "$T/conc.$k"; done | sort | tr '\n' ' ')"
CV="$(awk -F'\t' '$3 == "g1" {print $4}' "$SL" | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
[[ "$CRC" == "0 0 0 2 " ]] && ok "L2: 4 concurrent calls -> exit codes exactly 0,0,0,2" || bad "L2: concurrency exit codes '$CRC'"
[[ "$(wc -l < "$SL" | tr -d ' ')" == "$((R0 + 4))" && "$CV" == " 1 fail; 3 repeat;" ]] && ok "L2: ... four new ledger rows: one fail, three repeat" || bad "L2: concurrency ledger '$CV'"
[[ "$(wc -l < "$HOME/.claude/state/subagent-verify/sPre.g1.blocked" | tr -d ' ')" == 1 && ! -d "$HOME/.claude/state/subagent-verify/sPre.g1.lock" ]] && ok "L2: ... one block record, lock released" || bad "L2: concurrency record/lock"
[[ "$(awk -F'\t' 'NF != 5 || $1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ {n++} END {print n + 0}' "$SL")" == 0 ]] && ok "R3b: every ledger row is whole (5 fields, one timestamp) after the concurrent writes" || bad "R3b: damaged ledger row"
# config gates
rm -f "$SC"; TA="$(agent h1)"; tr_edit "$TA" "$SR/src/main.txt"; pre h1 SubagentHandback; [[ "$RC" == 0 && -z "$OUT" ]] && ok "L2: no config file -> 0, silent" || bad "L2: no config"
echo '{}' > "$SC"; pre h1 SubagentHandback; [[ "$RC" == 0 && "$(lastled "$SL" 4)" == no-change ]] && ok "L2: repo not in config -> 0 (no-change)" || bad "L2: unregistered ($(tail -1 "$SL"))"
sconf "$GOODCHK"; jq --arg x "$T/elsewhere" '.["acme/svapp"].roots = [$x]' "$SC" > "$SC.n" && mv "$SC.n" "$SC"; rm -f "$RAN"
pre h1 SubagentHandback; [[ "$RC" == 0 && "$(runs)" == 0 ]] && ok "L2: checkout not in roots -> nothing run" || bad "L2: untrusted roots ran"
# watchdog and installed-copy overrides
sconf "$GOODCHK"; setmain BAD; printf '#!/bin/bash\nsleep 30\n' > "$T/gitshim/git"; chmod +x "$T/gitshim/git"
TA="$(agent i1)"; tr_edit "$TA" "$SR/src/main.txt"; T0=$SECONDS; SENV=("PATH=$T/gitshim:$PATH" SUBVERIFY_TOTAL=5); pre i1 SubagentHandback; SENV=(); EL=$((SECONDS - T0))
lrc "L2: hang while locating the repo -> 0 (outer watchdog)" 0; [[ "$(lastled "$SL" 4)" == timeout ]] && ok "L2: ... ledger timeout" || bad "L2: watchdog ledger"; (( EL <= 9 )) && ok "L2: ... returned in ${EL}s" || bad "L2: watchdog slow (${EL}s)"
rm -f "$T/gitshim/git"
mkdir -p "$HOME/.claude/hooks/lib"; cp "$SV" "$HOME/.claude/hooks/"; cp "$ROOT/hooks/lib/projects.sh" "$HOME/.claude/hooks/lib/"
TA="$(agent i2)"; tr_edit "$TA" "$SR/src/main.txt"; rm -rf "$T/ovr2"
prein i2 SubagentHandback | SUBVERIFY_STATE="$T/ovr2" bash "$SV" >/dev/null 2>&1
[[ -s "$T/ovr2/ledger.tsv" ]] && ok "L2 control: the repo copy honours SUBVERIFY_STATE" || bad "L2 control: override not honoured"
rm -rf "$T/ovr2" "$HOME/.claude/state/subagent-verify"; TA="$(agent i3)"; tr_edit "$TA" "$SR/src/main.txt"
prein i3 SubagentHandback | SUBVERIFY_STATE="$T/ovr2" bash "$HOME/.claude/hooks/subagent-verify.sh" >/dev/null 2>&1; RC=$?
lrc "L2: installed copy still works" 2; [[ ! -e "$T/ovr2" && -s "$SL" ]] && ok "L2: installed copy ignores SUBVERIFY_STATE" || bad "L2: installed copy honoured the override"
printf '#!/bin/bash\nsleep 8\n' > "$T/gitshim/git"; chmod +x "$T/gitshim/git"; TA="$(agent i4)"; tr_edit "$TA" "$SR/src/main.txt"; T0=$SECONDS
prein i4 SubagentHandback | PATH="$T/gitshim:$PATH" SUBVERIFY_TOTAL=3 bash "$HOME/.claude/hooks/subagent-verify.sh" >/dev/null 2>&1; EL=$((SECONDS - T0))
(( EL >= 7 )) && ok "L2: installed copy ignores SUBVERIFY_TOTAL (watchdog not cut to 3 s)" || bad "L2: installed copy honoured SUBVERIFY_TOTAL (${EL}s)"
rm -f "$T/gitshim/git" "$HOME/.claude/hooks/subagent-verify.sh"


# ---------- review fixes (layers 1 and 2) ----------
source "$ROOT/hooks/lib/projects.sh"   # run_limited, to play the host's kill
export RUNDIR="$T"
# 1. a file name that looks like a perl option
echo x > "$LR/-w"; lconf 'echo "$EDIT_FILE: error"; exit 1' '^-w$'; lpost "$LR/-w"; lrc "R1: file named '-w' (a perl switch) is matched, not eaten by perl -> block" 2; rm -f "$LR/-w"
# 2. STOP_VERIFY_CONFIG: absolute path only
mkdir -p "$T/relcfg"; jq -n --arg r "$LRP" '{"acme/lapp":{roots:[$r],edit_check:{files_re:"^src/",cmd:"echo \"$EDIT_FILE: from-relative-config\"; exit 1"}}}' > "$T/relcfg/rel.json"
lconf 'echo "$EDIT_FILE: from-default-config"; exit 1'
PCWD="$T/relcfg"; PENV=(STOP_VERIFY_CONFIG=rel.json); lpost "$LR/src/a.ts"; PENV=(); PCWD="."
[[ $RC == 2 ]] && has "R2: relative STOP_VERIFY_CONFIG is ignored (default config used)" "$ERR" "from-default-config" || bad "R2: relative STOP_VERIFY_CONFIG (rc=$RC)"
mkdir -p "$HOME/.config" "$T/outcfg"; cp "$T/relcfg/rel.json" "$HOME/.config/abs.json"; cp "$T/relcfg/rel.json" "$HOME/.claude/abs2.json"; cp "$T/relcfg/rel.json" "$T/outcfg/abs.json"; ln -sf "$T/outcfg/abs.json" "$HOME/.config/lnk.json"
PENV=("STOP_VERIFY_CONFIG=$HOME/.config/abs.json"); lpost "$LR/src/a.ts"; PENV=()
has "R2/R11b: an absolute STOP_VERIFY_CONFIG under ~/.config is still honoured" "$ERR" "from-relative-config"
PENV=("STOP_VERIFY_CONFIG=$HOME/.claude/abs2.json"); lpost "$LR/src/a.ts"; PENV=(); has "R2/R11b: ... and under ~/.claude" "$ERR" "from-relative-config"
PENV=("STOP_VERIFY_CONFIG=$T/outcfg/abs.json"); lpost "$LR/src/a.ts"; PENV=(); has "R11b: an absolute STOP_VERIFY_CONFIG outside ~/.claude and ~/.config is ignored" "$ERR" "from-default-config"
PENV=("STOP_VERIFY_CONFIG=$HOME/.config/lnk.json"); lpost "$LR/src/a.ts"; PENV=(); has "R11b: ... and a link there that points outside is ignored" "$ERR" "from-default-config"
sconf "$GOODCHK"; setmain BAD; TA="$(agent r2a)"; tr_edit "$TA" "$SR/src/main.txt"
SCWD="$T/relcfg"; SENV=(STOP_VERIFY_CONFIG=rel.json); jq -n --arg r "$SRP" '{"acme/svapp":{roots:[$r],handback_verify:"echo from-relative-config; exit 1"}}' > "$T/relcfg/rel.json"; pre r2a SubagentHandback; SENV=(); SCWD="."
has "R2: layer 2 ignores a relative STOP_VERIFY_CONFIG too" "$ERR$OUT" "FAILED: main.txt lacks OK"
# 3. core.worktree pointing at a trusted checkout from a repo outside it
CW="$T/cw/outer"; mkdir -p "$CW"; git -C "$CW" init -q; git -C "$CW" config core.worktree "$LRP"; echo x > "$CW/x.ts"
lconf 'touch "$LMARK"; echo "$EDIT_FILE: x"; exit 1' '^'; lpost "$CW/x.ts"
[[ $RC == 0 && ! -e "$LMARK" ]] && ok "R3: L1 file outside the work tree git reports (core.worktree) is not treated as the trusted checkout" || bad "R3: L1 core.worktree (rc=$RC)"
CW2="$T/cw/outer2"; mkdir -p "$CW2"; git -C "$CW2" init -q; git -C "$CW2" config core.worktree "$SRP"; echo x > "$CW2/x.ts"
sconf "$GOODCHK"; setmain BAD; TA="$(agent r3a)"; tr_edit "$TA" "$CW2/x.ts"; snap; pre r3a SubagentHandback
schk "R3: L2 edit outside the work tree git reports -> no-change, checks not run" r3a no-change 0 0
TA="$(agent r3b)"; tr_bash "$TA" "printf x > $CW2/x.ts" "$CW2"; snap; pre r3b SubagentHandback
schk "R3: L2 Bash with cwd in such a repo -> no-change" r3b no-change 0 0
# 4. nothing is left running after the host kills the hook
OR="$T/orph"; mkdir -p "$OR/tmp"; /bin/rm -f "$T/pid.a" "$T/pid.b"
printf '%s\n' 'source "$1"' 'run_limited 60 bash -c '"'"'sleep 311 & echo $! > "$0"; wait'"'"' "$2"' > "$T/orph.sh"
bash -c 'source "$1"; run_limited 2 bash "$2" "$1" "$3"' _ "$ROOT/hooks/lib/projects.sh" "$T/orph.sh" "$T/pid.a" >/dev/null 2>&1
sleep 1; ! kill -0 "$(cat "$T/pid.a" 2>/dev/null || echo 0)" 2>/dev/null && ok "R4: run_limited forwards TERM: the grandchild is gone after an outer timeout" || { bad "R4: grandchild survived run_limited kill"; kill "$(cat "$T/pid.a")" 2>/dev/null; }
lconf '(sleep 312 & echo $! > "$RUNDIR/pid.b"; wait)' '^src/' 20
jq -nc --arg f "$LR/src/a.ts" '{tool_name:"Edit",tool_input:{file_path:$f}}' > "$T/in.l1"
TMPDIR="$OR/tmp" run_limited 3 bash "$PE" < "$T/in.l1" >/dev/null 2>&1; RC=$?; sleep 1
[[ $RC == 124 ]] && ok "R4: L1 hook killed from outside (host timeout)" || bad "R4: L1 outer kill (rc=$RC)"
! kill -0 "$(cat "$T/pid.b" 2>/dev/null || echo 0)" 2>/dev/null && ok "R4: L1 the check's own child is not left running" || { bad "R4: L1 orphan survived"; kill "$(cat "$T/pid.b")" 2>/dev/null; }
[[ -z "$(ls "$OR/tmp")" ]] && ok "R4: L1 temp files removed after the kill" || bad "R4: L1 temp files left: $(ls "$OR/tmp")"
/bin/rm -f "$T/pid.b"; sconf "$GOODCHK" '(sleep 313 & echo $! > "$RUNDIR/pid.b"; wait)' 60; setmain BAD; TA="$(agent r4)"; tr_edit "$TA" "$SR/src/main.txt"; /bin/rm -f "$OR/tmp"/*
prein r4 SubagentHandback > "$T/in.l2"
TMPDIR="$OR/tmp" run_limited 3 bash "$SV" < "$T/in.l2" >/dev/null 2>&1; RC=$?; sleep 1
[[ $RC == 124 ]] && ok "R4: L2 hook killed from outside" || bad "R4: L2 outer kill (rc=$RC)"
! kill -0 "$(cat "$T/pid.b" 2>/dev/null || echo 0)" 2>/dev/null && ok "R4: L2 the verifier's child is not left running" || { bad "R4: L2 orphan survived"; kill "$(cat "$T/pid.b")" 2>/dev/null; }
[[ -z "$(ls "$OR/tmp")" ]] && ok "R4: L2 temp files removed after the kill" || bad "R4: L2 temp files left: $(ls "$OR/tmp")"
# L1: the check's limit is capped by the time left, so a slow start cannot push it past the budget
printf '#!/bin/bash\nsleep 1\nexec /usr/bin/env -i PATH="%s" git "$@"\n' "$PATH" > "$T/gitshim/git"; chmod +x "$T/gitshim/git"
lconf 'sleep 20' '^src/' 20; T0=$SECONDS; PENV=("PATH=$T/gitshim:$PATH" POST_EDIT_LIMIT=7); lpost "$LR/src/a.ts"; PENV=(); EL=$((SECONDS - T0))
[[ $RC == 0 && "$(lastled "$LL" 4)" == timeout && "$(lastled "$LL" 2)" == acme/lapp ]] && (( EL <= 8 )) && ok "R4/R12: L1 limit is cut to the remaining budget (the inner check logged the project's timeout in ${EL}s)" || bad "R4: L1 remaining budget (rc=$RC ${EL}s $(tail -1 "$LL"))"
hasnt "R4/R12: ... and the outer watchdog message is absent" "$OUT" "Edit check timed out"
/bin/rm -f "$T/gitshim/git"
# 5. stdin that never ends is bounded
T0=$SECONDS
( cd "$PCWD" && env POST_EDIT_LIMIT=4 bash "$PE" < <(printf '{"tool_name":"Edit"'; sleep 20) >"$T/lout" 2>&1 ); RC=$?; EL=$((SECONDS - T0))
[[ $RC == 0 ]] && (( EL <= 8 )) && has "R5: L1 stdin never closes -> back in ${EL}s, exit 0, warning" "$(cat "$T/lout")" "stdin was not complete" || bad "R5: L1 stdin bound (rc=$RC ${EL}s)"
T0=$SECONDS; ( bash "$SV" < <(printf '{"hook_event_name":"PreToolUse","tool_name":"SubagentHandback"'; sleep 20) >"$T/sout" 2>&1 ); RC=$?; EL=$((SECONDS - T0))
[[ $RC == 0 ]] && (( EL <= 9 )) && has "R5: L2 stdin never closes -> back in ${EL}s, exit 0, warning" "$(cat "$T/sout")" "stdin was not complete" || bad "R5: L2 stdin bound (rc=$RC ${EL}s)"
# 6. VERIFY_CHANGED_FILE: only validated files of this checkout
sconf 'true' 'cat "$VERIFY_CHANGED_FILE" > "$LISTLOG"; exit 1'; setmain BAD
echo OK > "$SU/src/main.txt"; echo z > "$SR/src/new.txt"; ln -s "$SUP/src/main.txt" "$SR/src/lnk2.txt"; printf q > "$SR/src/nl
name.txt"
TA="$(agent r6)"; tr_edit "$TA" "$SR/src/main.txt"; tr_edit "$TA" "$SR/src/new.txt"; tr_edit "$TA" "$SR/src/lnk2.txt"; tr_edit "$TA" "$SR/src/gone.txt"; tr_edit "$TA" "$SUP/src/main.txt"; tr_edit "$TA" "$SR/src/nl
name.txt"
pre r6 SubagentHandback
[[ "$(sort "$LISTLOG" | tr '\n' ' ')" == "src/main.txt src/new.txt " ]] && ok "R6: VERIFY_CHANGED_FILE has only the validated regular files (no symlink, deleted, foreign or newline names)" || bad "R6: list was: $(tr '\n' '|' < "$LISTLOG")"
/bin/rm -f "$SR/src/new.txt" "$SR/src/lnk2.txt" "$SR/src/nl
name.txt"
# 7. fingerprint: FIFO, symlink, no commit
sconf "$GOODCHK"; setmain BAD; mkfifo "$SR/pipe1"; ln -s /dev/zero "$SR/zero"
TA="$(agent r7)"; tr_edit "$TA" "$SR/src/main.txt"; T0=$SECONDS; SENV=(SUBVERIFY_TOTAL=25); pre r7 SubagentHandback; SENV=(); EL=$((SECONDS - T0))
[[ $RC == 2 ]] && (( EL <= 12 )) && ok "R7: untracked FIFO and a link to /dev/zero do not hang the fingerprint (exit 2 in ${EL}s)" || bad "R7: fifo/link (rc=$RC ${EL}s $(tail -1 "$SL"))"
ln -sf /dev/null "$SR/zero"; pre r7 SubagentHandback; lrc "R7: a changed link text is a new state (blocked again)" 2
/bin/rm -f "$SR/pipe1" "$SR/zero"
NH="$T/l2/nohead"; mkdir -p "$NH/src"; git -C "$NH" init -q; git -C "$NH" remote add origin https://example.com/acme/nohead.git; echo a > "$NH/src/a.txt"; NHP="$(cd "$NH" && pwd -P)"
sconf "$GOODCHK"; jq --arg r "$NHP" '. + {"acme/nohead":{roots:[$r],handback_verify:"echo x >> \"$RAN\"; exit 1"}}' "$SC" > "$SC.n" && mv "$SC.n" "$SC"
TA="$(agent r7b)"; tr_edit "$TA" "$NH/src/a.txt"; snap; pre r7b SubagentHandback
schk "R7: repo with no commit -> not verified (error row, checks not run, exit 0)" r7b error 0 0
# 8. block count that cannot be read -> pass with a note
if [[ "$(id -u)" != 0 ]]; then
  sconf "$GOODCHK"; setmain BAD; TA="$(agent r8)"; tr_edit "$TA" "$SR/src/main.txt"; mkdir -p "$HOME/.claude/state/subagent-verify"
  printf 'x\ny\n' > "$HOME/.claude/state/subagent-verify/sPre.r8.blocked"; chmod 000 "$HOME/.claude/state/subagent-verify/sPre.r8.blocked"
  snap; pre r8 SubagentHandback; chmod 644 "$HOME/.claude/state/subagent-verify/sPre.r8.blocked"
  schk "R8: unreadable block record -> exit 0 with a note, never a block" r8 error 0 0; has "R8: ... note" "$OUT" "cannot be read"
else ok "R8: (skipped as root: chmod 000 does not stop root)"; fi
# 9. a Bash call that wrote and then failed still counts; an unreadable transcript is not 'no-change'
sconf "$GOODCHK"; setmain BAD; TA="$(agent r9)"; tr_tool "$TA" Bash "$(jq -nc --arg c "printf x > \"$SRP/src/main.txt\" && false" '{command:$c}')" true /tmp
snap; pre r9 SubagentHandback; schk "R9: Bash with is_error:true still counts as a possible write (run, fail, exit 2)" r9 fail 2 1
TA="$(agent r9b)"; jq -nc '{type:"assistant",cwd:{},message:{content:[{type:"tool_use",id:"z1",name:"Bash",input:{command:"echo hi > f"}}]}}' >> "$TA"
jq -nc '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"z1",is_error:false,content:"ok"}]}}' >> "$TA"
snap; pre r9b SubagentHandback; schk "R9: transcript the extraction cannot read -> error row (not no-change), exit 0" r9b error 0 0; has "R9: ... not verified note" "$OUT" "not verified"
# 10. left boundary of the path in a Bash command
TA="$(agent r10)"; tr_bash "$TA" "printf x > /tmp/backup$SRP/src/main.txt" /tmp; snap; pre r10 SubagentHandback
schk "R10: /tmp/backup<root>/x does not select <root>" r10 no-change 0 0
TA="$(agent r10b)"; tr_bash "$TA" "FOO=\"$SRP/src/x\"; printf x > \"\$FOO\"" /tmp; snap; pre r10b SubagentHandback
schk "R10: NAME=<root>/x (after =) still selects the root" r10b fail 2 1
# 11. layer 1 matching details
lconf 'printf "\033[96m%s\033[0m: error\n" "$EDIT_FILE"; exit 1'; lpost "$LR/src/a.ts"; lrc "R11: ANSI colour around the path does not hide it -> block" 2
lconf 'echo "${EDIT_FILE}~: error"; exit 1'; lpost "$LR/src/a.ts"; lrc "R11: src/a.ts~ is not src/a.ts" 0
lconf '[ "$NO_COLOR" = 1 ] && echo "$EDIT_FILE: error"; exit 1'; lpost "$LR/src/a.ts"; lrc "R11: the check runs with NO_COLOR=1" 2
# 12. layer 1 honours requires
lconf 'touch "$LMARK"; echo "$EDIT_FILE: x"; exit 1'; jq '.["acme/lapp"].requires = "node_modules"' "$SC" > "$SC.n" && mv "$SC.n" "$SC"; lpost "$LR/src/a.ts"
[[ $RC == 0 && ! -e "$LMARK" && "$(lastled "$LL" 4)" == skip ]] && ok "R12: L1 requires missing -> check not run, ledger skip" || bad "R12: L1 requires (rc=$RC)"
mkdir -p "$LR/node_modules"; lpost "$LR/src/a.ts"; lrc "R12: ... with requires present it runs" 2; rmdir "$LR/node_modules"
# P3: prune old block records; agent_transcript_path kept; jq / perl missing
sconf "$GOODCHK"; SD2="$HOME/.claude/state/subagent-verify"; mkdir -p "$SD2/sub"
age() { perl -e 'my $t = time - $ARGV[1] * 86400; utime $t, $t, $ARGV[0]' "$1" "$2"; }
for f in sOld.aOld.blocked sMid.aMid.blocked old.blocked sub/sX.aX.blocked; do echo x > "$SD2/$f"; done; age "$SD2/sOld.aOld.blocked" 31; age "$SD2/sMid.aMid.blocked" 10; age "$SD2/old.blocked" 40; age "$SD2/sub/sX.aX.blocked" 40
for f in sOld.aOld.handback sMid.aMid.handback old.handback sub/sX.aX.handback; do touch "$SD2/$f"; age "$SD2/$f" 31; done
age "$SD2/sMid.aMid.handback" 10
TA="$(agent p3)"; tr_edit "$TA" "$SR/src/main.txt"; pre p3 SubagentHandback
[[ ! -e "$SD2/sOld.aOld.handback" && -e "$SD2/sMid.aMid.handback" && -e "$SD2/old.handback" && -e "$SD2/sub/sX.aX.handback" ]] && ok "L2: only expired hand-back snapshots in the state directory are pruned" || bad "L2: snapshot pruning"
[[ ! -e "$SD2/sOld.aOld.blocked" && -e "$SD2/sMid.aMid.blocked" && -e "$SD2/old.blocked" && -e "$SD2/sub/sX.aX.blocked" ]] && ok "R4b/P3: block records are pruned after 30 days, only own-pattern files in the state folder itself" || bad "P3: prune"
TA="$(agent p3b)"; tr_edit "$TA" "$SR/src/main.txt"; setmain BAD
jq -nc --arg t "$TA" --arg c "$SRP" '{session_id:"sNone",transcript_path:"/nonexistent/x.jsonl",cwd:$c,agent_id:"p3b",agent_transcript_path:$t,hook_event_name:"PreToolUse",tool_name:"SubagentHandback"}' | bash "$SV" >/dev/null 2>"$T/serr"; RC=$?
lrc "P3: agent_transcript_path on a PreToolUse input is used when present" 2
NJ="$T/nojq"; mkdir -p "$NJ" "$T/noperl"; for b in dirname cat mktemp; do ln -sf "$(command -v $b)" "$NJ/$b"; ln -sf "$(command -v $b)" "$T/noperl/$b"; done
ln -sf "$(command -v perl)" "$NJ/perl"; ln -sf "$(command -v jq)" "$T/noperl/jq"
lconf 'exit 1'
jq -nc --arg f "$LR/src/a.ts" '{tool_name:"Edit",tool_input:{file_path:$f}}' > "$T/edit-input"
OUT="$(env PATH="$NJ" /bin/bash "$PE" <"$T/edit-input" 2>&1)"; RC=$?
[[ $RC == 0 ]] && has "P3: L1 without jq -> fixed warning, exit 0" "$OUT" "jq missing" || bad "P3: L1 no jq (rc=$RC)"
OUT="$(env PATH="$T/noperl" /bin/bash "$PE" <"$T/edit-input" 2>&1)"; has "P3: L1 without perl -> fixed warning" "$OUT" "perl missing"
OUT="$(prein p3 SubagentHandback | env PATH="$NJ" /bin/bash "$SV" 2>&1)"; has "P3: L2 without jq -> fixed warning" "$OUT" "jq missing"
OUT="$(prein p3 SubagentHandback | env PATH="$T/noperl" /bin/bash "$SV" 2>&1)"; has "P3: L2 without perl -> fixed warning" "$OUT" "perl missing"
OUT="$(prein p3 Bash | env PATH="$NJ" /bin/bash "$SV" 2>&1)"; [[ -z "$OUT" ]] && ok "P3: L2 other tool without jq stays silent" || bad "P3: L2 other tool warns: $OUT"


# ---------- second review round ----------
# 1. a check that ignores TERM, with a grandchild that ignores it too: nothing survives a host kill
/bin/rm -f "$T/pid.c"; sconf "$GOODCHK" 'trap "" TERM; ( trap "" TERM; sleep 316 & echo $! > "$RUNDIR/pid.c"; wait ) & wait' 60; setmain BAD
TA="$(agent q1)"; tr_edit "$TA" "$SR/src/main.txt"; prein q1 SubagentHandback > "$T/in.q1"; /bin/rm -f "$OR/tmp"/*
TMPDIR="$OR/tmp" run_limited 3 bash "$SV" < "$T/in.q1" >/dev/null 2>&1; RC=$?; sleep 1
! kill -0 "$(cat "$T/pid.c" 2>/dev/null || echo 0)" 2>/dev/null && ok "S1: L2 a verifier and grandchild that ignore TERM are KILLed (inner supervisor kills first)" || { bad "S1: L2 TERM-ignoring grandchild survived"; kill -9 "$(cat "$T/pid.c")" 2>/dev/null; }
/bin/rm -f "$T/pid.c"; lconf 'trap "" TERM; ( trap "" TERM; sleep 317 & echo $! > "$RUNDIR/pid.c"; wait ) & wait' '^src/' 20
TMPDIR="$OR/tmp" run_limited 3 bash "$PE" < "$T/in.l1" >/dev/null 2>&1; sleep 1
! kill -0 "$(cat "$T/pid.c" 2>/dev/null || echo 0)" 2>/dev/null && ok "S1: L1 a check and grandchild that ignore TERM are KILLed" || { bad "S1: L1 TERM-ignoring grandchild survived"; kill -9 "$(cat "$T/pid.c")" 2>/dev/null; }
# 2. a Bash call with no result at all is not a write
sconf "$GOODCHK"; setmain BAD; TA="$(agent q2)"; jq -nc --arg c "printf x > \"$SRP/src/main.txt\"" '{type:"assistant",cwd:"/tmp",message:{role:"assistant",content:[{type:"tool_use",id:"nores1",name:"Bash",input:{command:$c}}]}}' >> "$TA"
snap; pre q2 SubagentHandback; schk "S2: Bash tool_use without any tool_result is ignored (no-change, checks not run)" q2 no-change 0 0
# 5. TERM during fingerprinting leaves no sv-* files
mkdir -p "$T/fpshim"; printf '#!/bin/bash\ncase " $* " in *" diff "*) sleep 30;; esac\nexec "%s" "$@"\n' "$(command -v git)" > "$T/fpshim/git"; chmod +x "$T/fpshim/git"
sconf "$GOODCHK"; TA="$(agent q5)"; tr_edit "$TA" "$SR/src/main.txt"; prein q5 SubagentHandback > "$T/in.q5"; /bin/rm -f "$OR/tmp"/*
PATH="$T/fpshim:$PATH" TMPDIR="$OR/tmp" run_limited 3 bash "$SV" < "$T/in.q5" >/dev/null 2>&1; sleep 1
[[ -z "$(ls "$OR/tmp")" ]] && ok "S5: TERM while fingerprinting leaves no sv-* temp files" || bad "S5: temp files left: $(ls "$OR/tmp" | tr '\n' ' ')"
/bin/rm -rf "$T/fpshim"
# 6. the verifier did not start: log cannot be opened / checkout cannot be entered
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$T/mkshim"; printf '#!/bin/bash\nf="$("%s" "$@")" || exit 1\ncase "$1" in *subagent-verify.XXXXXX) chmod 000 "$f";; esac\nprintf "%%s\\n" "$f"\n' "$(command -v mktemp)" > "$T/mkshim/mktemp"; chmod +x "$T/mkshim/mktemp"
  sconf "$GOODCHK"; setmain BAD; TA="$(agent q6)"; tr_edit "$TA" "$SR/src/main.txt"; snap; SENV=("PATH=$T/mkshim:$PATH"); pre q6 SubagentHandback; SENV=()
  schk "S6: log file cannot be opened -> the check did not start: error row, exit 0, never a block" q6 error 0 0
  printf '#!/bin/bash\n"%s" "$@"; rc=$?\ncase " $* " in *" ls-files "*) chmod 000 "$CHMODDIR";; esac\nexit $rc\n' "$(command -v git)" > "$T/mkshim/git"; chmod +x "$T/mkshim/git"
  TA="$(agent q6b)"; tr_edit "$TA" "$SR/src/main.txt"; snap; SENV=("PATH=$T/mkshim:$PATH" "CHMODDIR=$SRP"); pre q6b SubagentHandback; SENV=(); chmod 755 "$SRP"
  schk "S6: checkout cannot be entered after the listing -> error row, exit 0 (NOSTART path)" q6b error 0 0
  /bin/rm -rf "$T/mkshim"
else ok "S6: (skipped as root)"; fi
# 7. no perl: warn and leave before reading stdin
T0=$SECONDS; OUT="$(env PATH="$T/noperl" /bin/bash "$SV" < <(sleep 20) 2>&1)"; EL=$((SECONDS - T0))
[[ "$OUT" == *"perl missing"* ]] && (( EL <= 4 )) && ok "S7: L2 without perl warns before reading stdin (${EL}s with a stdin that never closes)" || bad "S7: L2 no perl (${EL}s '$OUT')"
T0=$SECONDS; OUT="$(env PATH="$T/noperl" /bin/bash "$PE" < <(sleep 20) 2>&1)"; EL=$((SECONDS - T0)); lconf 'exit 1'
[[ "$OUT" == *"perl missing"* ]] && (( EL <= 4 )) && ok "S7: L1 without perl warns before reading stdin" || bad "S7: L1 no perl (${EL}s '$OUT')"
# 8. link text: trailing newline counts
sconf "$GOODCHK"; setmain BAD; ln -s a "$SR/lk"; TA="$(agent q8)"; tr_edit "$TA" "$SR/src/main.txt"; pre q8 SubagentHandback; lrc "S8: untracked link, first state -> block" 2
/bin/rm -f "$SR/lk"; ln -s "a
" "$SR/lk"; pre q8 SubagentHandback; lrc "S8: same link, target differs only by a trailing newline -> new state, blocked again" 2; /bin/rm -f "$SR/lk"
# 9. a newline in any path component
mkdir -p "$SR/dd" "$SR/dd
"; echo n > "$SR/dd/a.txt"; echo n > "$SR/dd
/a.txt"
sconf 'true' 'cat "$VERIFY_CHANGED_FILE" > "$LISTLOG"; exit 1'; TA="$(agent q9)"; tr_edit "$TA" "$SR/src/main.txt"; tr_edit "$TA" "$SR/dd
/a.txt"; pre q9 SubagentHandback
[[ "$(tr '\n' ' ' < "$LISTLOG")" == "src/main.txt " ]] && ok "S9: a path with a newline in a folder name is not listed (and does not alias the folder without it)" || bad "S9: list was: $(tr '\n' '|' < "$LISTLOG")"
/bin/rm -rf "$SR/dd" "$SR/dd
"
# 10. colon form of SGR colour
lconf 'printf "\033[38:2::255:0:0m%s\033[0m: error\n" "$EDIT_FILE"; exit 1'; lpost "$LR/src/a.ts"; lrc "S10: ANSI SGR with colons (true colour) around the path -> block" 2


# ---------- third review round ----------
# 1. STOP_VERIFY_CONFIG: the checked path is the path that is loaded (physical folder, then the file)
mkdir -p "$T/outpar/outdir"; cp "$T/outcfg/abs.json" "$T/outpar/x.json"; ln -sfn "$T/outpar/outdir" "$HOME/.claude/linkdir"; ln -sf "$T/outcfg/abs.json" "$HOME/.claude/x.json"
lconf 'echo "$EDIT_FILE: from-default-config"; exit 1'
PENV=("STOP_VERIFY_CONFIG=$HOME/.claude/linkdir/../x.json"); lpost "$LR/src/a.ts"; PENV=()
has "T1: linkdir/../x.json (logical path is a link to outside, physical path is outside) is ignored in L1" "$ERR" "from-default-config"
sconf "$GOODCHK"; setmain BAD; TA="$(agent t1)"; tr_edit "$TA" "$SR/src/main.txt"
SENV=("STOP_VERIFY_CONFIG=$HOME/.claude/linkdir/../x.json"); pre t1 SubagentHandback; SENV=()
has "T1: ... and in L2" "$ERR" "FAILED: main.txt lacks OK"
/bin/rm -f "$HOME/.claude/linkdir" "$HOME/.claude/x.json"
# 2. L1 total budget leaves room for the work after the watchdog (static: default 18 s, check limit 1..15)
grep -q '^TOTAL_LIMIT=18$' "$PE" && grep -q "1\.\.15, default 15" "$PE" && ok "T2: L1 default budget is 18 s, limit 1..15" || bad "T2: L1 budget"
# 3. no start marker next to the mktemp file: nothing in TMPDIR ends in .started while the check runs
mkdir -p "$T/tmpm"; /bin/rm -f "$T/tmpm"/*; sconf 'true' 'ls -A "$TMPDIR" > "$LISTLOG"; exit 1'; TA="$(agent t3)"; tr_edit "$TA" "$SR/src/main.txt"
prein t3 SubagentHandback | TMPDIR="$T/tmpm" bash "$SV" >/dev/null 2>&1; RC=$?
[[ $RC == 2 && -s "$LISTLOG" ]] && ! grep -q 'started' "$LISTLOG" && ok "T3: the start marker is not a derived name in TMPDIR (it lives in a private mktemp -d folder)" || bad "T3: TMPDIR during the run: $(tr '\n' ' ' < "$LISTLOG")"
[[ -z "$(ls "$T/tmpm")" ]] && ok "T3: ... and the private folder is removed afterwards" || bad "T3: left over: $(ls "$T/tmpm" | tr '\n' ' ')"
# 4. a Bash call the host/hook refused to run is not a write (text observed in real transcripts)
sconf "$GOODCHK"; setmain BAD; TA="$(agent t4)"
jq -nc --arg c "printf x > \"$SRP/src/main.txt\"" '{type:"assistant",cwd:"/tmp",message:{role:"assistant",content:[{type:"tool_use",id:"den1",name:"Bash",input:{command:$c}}]}}' >> "$TA"
jq -nc '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"den1",is_error:true,content:"Permission to use Bash denied by plugin some-plugin: This call was refused: not allowed."}]}}' >> "$TA"
snap; pre t4 SubagentHandback; schk "T4: Bash call denied before it ran is ignored (no-change, checks not run)" t4 no-change 0 0
TA="$(agent t4b)"; tr_tool "$TA" Bash "$(jq -nc --arg c "printf x > \"$SRP/src/main.txt\" && false" '{command:$c}')" true /tmp
snap; pre t4b SubagentHandback; schk "T4: ... while an ordinary failed Bash call still counts" t4b fail 2 1

# A second hand-back supersedes the earlier result for every checkout it covers.
# The simulated service lives outside the checkout, so its delay cannot change the fingerprint.
sconf 'true' 'echo run >> "$RAN"; if [[ -f "$RAN.slow" ]]; then sleep 20; fi; grep -qx OK src/main.txt' 2
setmain OK; echo BAD > "$SP2/src/main.txt"
TA="$(agent latest)"; tr_edit "$TA" "$SR/src/main.txt"; tr_edit "$TA" "$SP2/src/main.txt"
pre latest SubagentHandback; lrc "L2 latest: first hand-back blocks the failing checkout" 2
touch "$RAN.slow"; echo OK > "$SP2/src/main.txt"
pre latest SubagentHandback; lrc "L2 latest: second hand-back permits an incomplete check" 0
has "L2 latest: second hand-back reports the timeout" "$OUT" "not verified"
stp latest
[[ "$RC" == 0 && "$(runs)" == 2 && "$OUT" == *'not verified'* ]] && ok "L2 latest: stop preserves the timeout without spending another budget" || bad "L2 latest: timeout (rc=$RC runs=$(runs) output=$OUT)"
[[ "$(awk -F'\t' '$2 == "acme/p2" {print $4}' "$SL" | paste -sd, -)" == fail,pass,handback-done ]] && ok "L2 latest: stop skips the other checkout that passed" || bad "L2 latest: unexpected results for the other checkout"
rm "$RAN.slow"; pre latest SubagentHandback
[[ "$RC" == 0 && "$(runs)" == 3 && "$OUT" == *'checks passed'* ]] && ok "L2 latest: a fresh hand-back verifies recovery" || bad "L2 latest: recovery"

# The report is delivered only when the agent's matching tool call succeeds.
handback_result() {
  jq -nc --arg id "$2" '{type:"assistant",message:{content:[{type:"tool_use",id:$id,name:"SubagentHandback",input:{}}]}}' >> "$1"
  jq -nc --arg id "$2" --argjson err "$3" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:$id,is_error:$err,content:"result"}]}}' >> "$1"
}
sconf "$GOODCHK"; setmain OK; TA="$(agent delivered)"; tr_edit "$TA" "$SR/src/main.txt"
pre delivered SubagentHandback; handback_result "$TA" tu1 false
stp delivered
[[ "$RC" == 0 && "$(runs)" == 1 && -z "$OUT$ERR" ]] && ok "L2: delivered unchanged pass skips a second check" || bad "L2: delivered pass"
setmain BAD; stp delivered
[[ "$RC" == 0 && "$(runs)" == 1 && "$OUT" == *'not verified'* ]] && ok "L2: shared edits after delivery cannot trigger a late block or inherit a pass" || bad "L2: changed after delivery (rc=$RC runs=$(runs))"
tr_edit "$TA" "$SR/src/main.txt"; stp delivered
[[ "$RC" == 2 && "$(runs)" == 2 ]] && ok "L2: new agent work after delivery is checked normally" || bad "L2: resumed agent work"
# The checkout bytes can return to their old state while the verifier's input list expands.
sconf 'echo run >> "$RAN"; while IFS= read -r f; do grep -qx OK "$f" || exit 1; done < "$VERIFY_CHANGED_FILE"'
setmain OK; echo pending > "$SR/src/second.txt"; TA="$(agent resumed)"; tr_edit "$TA" "$SR/src/main.txt"
pre resumed SubagentHandback; handback_result "$TA" tu1 false
echo editing > "$SR/src/second.txt"; tr_edit "$TA" "$SR/src/second.txt"
echo pending > "$SR/src/second.txt"; tr_edit "$TA" "$SR/src/second.txt"
stp resumed
[[ "$RC" == 2 && "$(runs)" == 2 ]] && ok "L2: resumed work with identical checkout bytes verifies the expanded file list" || bad "L2: reused pass after resuming (rc=$RC runs=$(runs))"
rm "$SR/src/second.txt"
sconf "$GOODCHK"; setmain OK; TA="$(agent refused)"; tr_edit "$TA" "$SR/src/main.txt"
pre refused SubagentHandback; handback_result "$TA" tu1 true; setmain BAD; stp refused
[[ "$RC" == 2 && "$(runs)" == 2 ]] && ok "L2: an unsuccessful hand-back does not certify delivery" || bad "L2: refused hand-back"
sconf 'echo run >> "$RAN"; echo generated > coverage.out; false'
TA="$(agent generated)"; tr_edit "$TA" "$SR/src/main.txt"
pre generated SubagentHandback; lrc "L2: a verifier that writes coverage still blocks the initial failure" 2
stp generated
[[ "$RC" == 0 && "$(runs)" == 1 && "$OUT" == *'hand-back check failed'* ]] && ok "L2: verifier output does not consume a second block" || bad "L2: generated output"
rm "$SR/coverage.out"
sconf "$GOODCHK"; setmain BAD; TA="$(agent fallback)"; tr_edit "$TA" "$SR/src/main.txt"
stopin fallback | jq --arg main "$MAINP" 'del(.agent_transcript_path) | .transcript_path = $main' > "$T/fallback-input"
expect_rc 2 "L2: Stop derives the agent's own transcript when its path is omitted" bash "$SV" < "$T/fallback-input"

echo; echo "$pass passed, $fail failed"; (( fail == 0 ))
