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
expect_rc 65 "dispatch: HOME=elsewhere cannot unprotect the real ~/.claude" env HOME="$T" bash "$D" -f "$T/task.md" -s read-only --skip-git-repo-check -C "$REALHOME/.claude"
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
expect_rc 1 "evidence: failing command keeps exit code" in_g -- false
grep -q FAIL "$T/out" && ok "evidence: says FAIL" || bad "evidence: FAIL label"

printf 'not json' > "$HOME/.claude/stop-verify.projects.json"
expect_rc 0 "hook: broken config never traps the session" run_hook

echo; echo "$pass passed, $fail failed"; (( fail == 0 ))
