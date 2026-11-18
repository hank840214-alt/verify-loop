#!/usr/bin/env bash
# stop-verify.sh — one Stop hook for every registered project (verify-loop).
#
# When Claude tries to finish a turn inside a registered repo whose code differs
# from HEAD or from origin/main, run that project's verify command.
#   pass                 -> exit 0, Claude stops.
#   fail or time limit   -> summary on stderr + exit 2, once per state per session.
#   same state again     -> not re-run; Claude stops with a visible NOT VERIFIED note.
#   hook's own problem   -> exit 0 with a systemMessage (never traps the session).
#
# Projects live in ~/.claude/stop-verify.projects.json (or $STOP_VERIFY_CONFIG),
# keyed by "owner/repo" from the origin remote. No config file -> the hook does nothing.
# Fields:
#   code_re    files that trigger a run (extended regex, repo-relative)
#   skip_re    optional: files that never trigger a run, even if code_re matches
#              (generated files, folders that killed tests leave behind)
#   verify     bash command run at the repo root. $VERIFY_CHANGED_FILE names a file with the
#              changed files, one per line.
#   requires   path that must exist first (e.g. node_modules), optional
#   limit      seconds before the run is stopped as "not verified" (default 480)
#   roots      REQUIRED: absolute paths of the checkouts you trust, e.g. ["/home/me/src/shop"].
#              Another clone with the same owner/repo is never run. Linked worktrees of a
#              trusted checkout are trusted. Trust is by path: whatever branch is checked
#              out there is run with your permissions.
#   tests_re   optional: existing files matching it may not be modified or deleted in the
#              same change as other code (the fixer may not grade itself)
#
# One deadline for the whole hook (STOP_VERIFY_DEADLINE s, 120..540, default 540; below the
# 600 s hook timeout), so the hook can never run past its timeout and fail open.
# Checks are skipped (silently) while a subagent, workflow or codex-dispatch.sh is running.
#
# Order: test guard first, then the fingerprint cache (same changes already passed or
# already failed -> no new run); at most MAX_BLOCKS blocks in a row per session.
# State in $STATE_DIR: <id>.pass, <id>.red (fingerprint + verdict; delete it to force a re-run),
# <id>.fail.log (last failing output per checkout), <id>.<session>.blocks (blocked states),
# ledger.tsv (one line per verdict).

set -uo pipefail
MAX_BLOCKS=3
DEADLINE="${STOP_VERIFY_DEADLINE:-540}"; [[ "$DEADLINE" =~ ^[0-9]{1,6}$ ]] && DEADLINE=$((10#$DEADLINE)) && (( DEADLINE >= 120 && DEADLINE <= 540 )) || DEADLINE=540
CONF="${STOP_VERIFY_CONFIG:-$HOME/.claude/stop-verify.projects.json}"
STATE_DIR="$HOME/.claude/state/stop-verify"

[[ -f "$CONF" ]] || exit 0
command -v jq >/dev/null 2>&1 || { printf '{"systemMessage":"[stop-verify] jq missing; verification skipped"}\n'; exit 0; }
msg() { jq -cn --arg m "[stop-verify] $1" '{systemMessage:$m}'; }
note() { msg "$1"; exit 0; }
command -v perl >/dev/null 2>&1 || note "perl missing; verification skipped"
if command -v shasum >/dev/null 2>&1; then HASH=shasum
elif command -v sha1sum >/dev/null 2>&1; then HASH=sha1sum
else note "shasum/sha1sum missing; verification skipped"; fi
hsum() { "$HASH" -- "$@"; }
jq -e . "$CONF" >/dev/null 2>&1 || note "projects.json is not valid JSON; verification skipped"

INPUT="$(cat)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
SESSION="$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"')"
SESSION="${SESSION//[^A-Za-z0-9_-]/_}"
ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active | tostring')"   # "false" = this stop does not follow a block (jq's // would drop false)
# Field shapes confirmed by capture on Claude Code 2.1.327. Agents this session started are
# still working: the session is paused, not done, and stops again later. Plain shells do not count.
BUSY="$(printf '%s' "$INPUT" | jq -r '[(.background_tasks? // []) | if type == "array" then .[] else empty end
  | select(type == "object" and ((.status // "running") == "running")
    and (.type == "subagent" or .type == "workflow"
      or (.type == "shell" and ((.command | type) == "string") and (.command | test("(^|[[:space:]/])codex-dispatch\\.sh([^[:alnum:]._-]|$)")) and ((.command | test("^[[:space:]]*(tail|cat|less|grep|head)([[:space:]]|$)")) | not))))] | length' 2>/dev/null)"
[[ -n "$CWD" && -d "$CWD" ]] || exit 0

export NPM_CONFIG_UPDATE_NOTIFIER=false

project_of() {  # repo root -> project key, or empty
  local url name
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 0
  name="${url%/}"; name="${name%.git}"; name="${name%/}"; name="${name##*:}"   # git@host:owner/repo -> owner/repo
  name="$(printf '%s' "$name" | awk -F/ 'NF>=2{print $(NF-1)"/"$NF}')"
  [[ -n "$name" ]] || return 0
  jq -e --arg k "$name" 'has($k)' "$CONF" >/dev/null 2>&1 && printf '%s' "$name"
}
field() { jq -r --arg k "$1" --arg f "$2" '.[$k][$f] // empty' "$CONF"; }

run_limited() {  # seconds, command...  -> exit 124 on time limit, kills the whole group
  perl -e '
    my $t = shift; $t = 1 if $t < 1; my $pid = fork();
    if (!$pid) { setpgrp(0,0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 3; kill "KILL", -$pid; exit 124 };
    alarm $t; waitpid($pid, 0); my $s = $?; exit(($s & 127) ? 128 + ($s & 127) : $s >> 8);
  ' "$@"
}

re_ok() { [[ -z "$1" ]] && return 0; [[ "" =~ $1 ]]; [[ $? -le 1 ]]; }

# NUL-separated, so tabs, quotes and newlines in file names are never mangled.
# --no-renames: a moved file shows its old path too, so moving code out of code_re still counts.
uncommitted_z() { git diff -z --no-renames --name-only HEAD && git ls-files -z --others --exclude-standard; }

verify_root() {
  local ROOT="$1" KEY="$2" fld LOG="" LIST="" FT=""   # LOG, LIST, FT: only paths this run creates are ever removed
  cd "$ROOT" || return 0
  for fld in code_re tests_re skip_re verify; do
    jq -e --arg k "$KEY" --arg f "$fld" '.[$k] | if has($f) then (.[$f] | type) == "string" else true end' "$CONF" >/dev/null 2>&1 \
      || { msg "invalid $fld in config for $KEY: must be a string"; return 0; }
  done
  local CODE_RE SKIP_RE VERIFY REQ LIMIT TESTS_RE
  CODE_RE="$(field "$KEY" code_re)"; VERIFY="$(field "$KEY" verify)"; TESTS_RE="$(field "$KEY" tests_re)"; SKIP_RE="$(field "$KEY" skip_re)"
  REQ="$(field "$KEY" requires)"; LIMIT="$(field "$KEY" limit)"; LIMIT="${LIMIT:-480}"
  [[ -n "$CODE_RE" && -n "$VERIFY" ]] || return 0
  [[ "$LIMIT" =~ ^[0-9]{1,6}$ ]] && LIMIT=$((10#$LIMIT)) && (( LIMIT >= 1 && LIMIT <= DEADLINE - 30 )) || { msg "$KEY: limit must be 1-$((DEADLINE - 30)) seconds; checks skipped"; return 0; }
  re_ok "$CODE_RE" && re_ok "$TESTS_RE" && re_ok "$SKIP_RE" || { msg "$KEY: invalid regex in config; checks skipped"; return 0; }
  if [[ -n "$REQ" && ! -e "$ROOT/$REQ" ]]; then msg "$KEY: $REQ is missing, checks skipped"; return 0; fi
  local BASE
  BASE="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  [[ -n "$BASE" ]] || { git rev-parse -q --verify origin/main >/dev/null && BASE=origin/main; }
  [[ -n "$BASE" ]] || { git rev-parse -q --verify origin/master >/dev/null && BASE=origin/master; }

  is_skip() { [[ -n "$SKIP_RE" && "$1" =~ $SKIP_RE ]]; }
  is_code() { [[ "$1" =~ $CODE_RE ]] && ! is_skip "$1"; }
  is_test() { [[ -n "$TESTS_RE" && "$1" =~ $TESTS_RE ]] && ! is_skip "$1"; }
  local f CODE=() TESTF=() OTHER=() UNC_CODE=0
  list_files() {  # fills CODE, TESTF, OTHER; returns 1 when git cannot list the changes
    local LZ; CODE=(); TESTF=(); OTHER=()
    LZ="$(mktemp "${TMPDIR:-/tmp}/stop-verify-z.XXXXXX")" || note "mktemp failed; verification skipped"
    if ! { uncommitted_z && { [[ -z "$BASE" ]] || git diff -z --no-renames --name-only "$BASE"...HEAD; }; } >"$LZ" 2>/dev/null; then
      /bin/rm -f "$LZ"; return 1
    fi
    while IFS= read -r -d '' f; do
      is_skip "$f" && continue
      if is_code "$f"; then CODE+=("$f"); else OTHER+=("$f"); fi
      if is_test "$f"; then TESTF+=("$f"); fi
    done < <(sort -zu "$LZ")
    /bin/rm -f "$LZ"
  }
  list_files || { msg "$KEY: git could not list the changed files; checks NOT run"; return 0; }
  if (( ${#CODE[@]} == 0 )); then
    [[ "${STOP_VERIFY_DRY:-0}" == 1 ]] && echo "[dry] $KEY: no changed files match code_re (base: ${BASE:-none})" >&2
    return 0
  fi

  (umask 077; mkdir -p "$STATE_DIR") || return 0
  no_state() { [[ -n "$LOG" ]] && /bin/rm -f "$LOG"; [[ -n "$LIST" ]] && /bin/rm -f "$LIST"; [[ -n "$FT" ]] && /bin/rm -f "$FT"; msg "$KEY: cannot write state in $STATE_DIR; not blocking. Fix the folder permissions."; exit 0; }
  [[ -w "$STATE_DIR" ]] || no_state
  wr() {  # file, content: atomic write inside the state dir
    local t; t="$(mktemp "$STATE_DIR/.w.XXXXXX" 2>/dev/null)" && printf '%s\n' "$2" > "$t" && mv -f "$t" "$1" || { [[ -n "$t" ]] && /bin/rm -f "$t"; no_state; }
  }
  find "$STATE_DIR" -name '*.blocks' -mtime +7 -delete 2>/dev/null
  local S BLOCKS=0 SET="" REDALL="" PFP="" RFP="" RFP2=""
  S="$STATE_DIR/$(printf '%s' "$ROOT" | hsum | cut -c1-16)"
  { { read -r BLOCKS _; SET="$(cat)"; } < "$S.$SESSION.blocks"; } 2>/dev/null
  REDALL="$(cat "$S.red" 2>/dev/null)"   # lines "<state> <verdict> [<state after the run>]", last 20
  [[ "$BLOCKS" =~ ^[0-9]+$ ]] || BLOCKS=0
  [[ "$ACTIVE" == false ]] && BLOCKS=0

  local LOAD; LOAD="$(uptime 2>/dev/null | sed 's/.*load average[s]*: *//; s/[, ].*//')"
  led() {  # verdict, action, seconds -> one ledger line (local file, mode 600, never printed)
    local d="${ROOT##*/}"; d="${d//[$'\t\r\n']/_}"
    ( umask 077; [[ -e "$STATE_DIR/ledger.tsv" ]] && chmod 600 "$STATE_DIR/ledger.tsv"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "${KEY//[^A-Za-z0-9._\/-]/_}" "$d" "${SESSION:0:8}" \
      "$1" "$2" "$3" "$LOAD" "${RFP:0:12}" >> "$STATE_DIR/ledger.tsv" ) 2>/dev/null
  }
  # Fingerprints. PFP (pass cache): HEAD, verify command, limit, and type, mode and content of
  # every changed code or test file. RFP (red cache, blocks): PFP plus all other changed files.
  fp_part() {  # files... -> kind+mode of each path, then content hashes (deleted paths hash as "deleted")
    local f k H=() HL=$((DEADLINE - SECONDS - 60)); (( HL < 1 )) && HL=1
    for f in "$@"; do
      if [[ -L "$f" ]]; then
        k="link $(readlink "$f") $([[ -f "$f" ]] && echo file || { [[ -d "$f" ]] && echo dir || echo broken; })"; [[ -f "$f" ]] && H+=("$f")
      elif [[ -f "$f" ]]; then k=file; [[ -x "$f" ]] && k="file x"; H+=("$f")
      elif [[ -e "$f" ]]; then k=other; else k=deleted; fi
      printf '%s %s\0' "$k" "$f"
    done
    if (( ${#H[@]} )); then printf '%s\0' "${H[@]}" | run_limited "$HL" xargs -0 "$HASH" -- 2>/dev/null || echo "hash-incomplete $RANDOM$RANDOM"; fi
    return 0
  }
  fingerprint() {  # sets PFP and RFP from CODE, TESTF, OTHER; returns 1 when the time budget is spent
    (( DEADLINE - SECONDS - 60 >= 1 )) || return 1
    PFP="$( { git rev-parse HEAD 2>/dev/null; printf '%s\n%s\n' "$VERIFY" "$LIMIT"; fp_part ${CODE[@]+"${CODE[@]}"} ${TESTF[@]+"${TESTF[@]}"}; } | hsum | cut -c1-40)"
    (( DEADLINE - SECONDS - 60 >= 1 )) || return 1
    RFP="$( { printf '%s\n' "$PFP"; fp_part ${OTHER[@]+"${OTHER[@]}"}; } | hsum | cut -c1-40)"
  }
  fingerprint || { led skipped ok 0; msg "$KEY: not enough time left in this stop to run checks; not verified"; return 0; }
  [[ ${#PFP} == 40 && ${#RFP} == 40 ]] || { msg "could not fingerprint changes; checks skipped"; return 0; }
  redline() { grep -m1 -e "^$RFP " -e " $RFP\$" <<<"$REDALL"; }
  redm() { [[ -n "$(redline)" ]]; }   # a saved failure is for this state

  # One block per exact state per session (a set, so going back to an earlier state is not blocked
  # again); MAX_BLOCKS blocks in a row. Returns 0 when Claude may stop, 1 when this stop is blocked.
  released() {  # verdict, seconds
    local N="$BLOCKS" ADD
    if grep -q "^$RFP " <<<"$SET"; then
      led "$1" released "$2"
      msg "$KEY: NOT VERIFIED ($1) in $ROOT. Claude was already blocked for this exact state and stopped anyway. It is not re-run until the files change."
      return 0
    fi
    if (( BLOCKS >= MAX_BLOCKS )); then   # the streak resets; this state is not remembered as blocked
      wr "$S.$SESSION.blocks" "$(printf '0\n%s' "$SET")"; led "$1" released "$2"
      msg "$KEY: NOT VERIFIED ($1) in $ROOT. Claude was blocked $N times in a row and is now allowed to stop. Checks are red."
      return 0
    fi
    ADD="$RFP $1"; [[ -n "$RFP2" ]] && ADD="$ADD"$'\n'"$RFP2 $1"   # RFP2: the state after the run (verify may write files)
    SET="$(printf '%s\n%s\n' "$SET" "$ADD" | grep . | tail -50)"
    wr "$S.$SESSION.blocks" "$(printf '%s\n%s' "$((BLOCKS + 1))" "$SET")"; led "$1" block "$2"; return 1
  }
  if (( ${BUSY:-0} > 0 )) && [[ "${STOP_VERIFY_DRY:-0}" != 1 ]]; then led deferred ok 0; return 0; fi

  # Test guard (before any cache): the change that fixes code may not also edit the
  # existing tests that judge it. Uncommitted edits only; committed test edits are
  # listed by verify-evidence.sh for the PR reviewer.
  if [[ -n "$TESTS_RE" ]]; then
    local st old TAMPER=() NS
    NS="$(mktemp "${TMPDIR:-/tmp}/stop-verify-ns.XXXXXX")" || note "mktemp failed; verification skipped"
    if ! git diff -z --no-renames --name-status HEAD >"$NS" 2>/dev/null || ! uncommitted_z >/dev/null 2>&1; then
      /bin/rm -f "$NS"; msg "$KEY: git could not list edited tests; checks NOT run"; return 0
    fi
    while IFS= read -r -d '' st; do
      case "$st" in
        R*|C*) IFS= read -r -d '' old; IFS= read -r -d '' f; f="$old" ;;
        *) IFS= read -r -d '' f ;;
      esac
      case "$st" in M*|D*|R*|T*) is_test "$f" && TAMPER+=("$f") ;; esac
    done < "$NS"
    /bin/rm -f "$NS"
    while IFS= read -r -d '' f; do
      is_code "$f" && [[ ! "$f" =~ $TESTS_RE ]] && { UNC_CODE=1; break; }
    done < <(uncommitted_z 2>/dev/null)
    if (( ${#TAMPER[@]} > 0 && UNC_CODE )); then
      if [[ "${STOP_VERIFY_DRY:-0}" == 1 ]]; then echo "[dry] $KEY: test guard would block: ${TAMPER[*]}" >&2; return 0; fi
      if released guard 0; then return 0; fi
      {
        echo "[stop-verify] $KEY: test guard (block $((BLOCKS + 1))/$MAX_BLOCKS). Uncommitted edits in $ROOT change code AND existing tests:"
        printf '  %s\n' "${TAMPER[@]}"
        echo "Whoever changes code may not also change the tests that grade it, even by a comment or a title."
        echo "Your own test edits from this session: undo them, or stop and say why the test is wrong."
        echo "Someone else's (a subagent, another agent, the user): do NOT revert them. Say so and stop; they commit the test edits on their own, apart from the code, for a different agent or the user to approve."
        echo "New test files are fine. This exact state will not be blocked again."
      } >&2
      return 2
    fi
  fi

  [[ -f "$S.pass" && "$(cat "$S.pass")" == "$PFP" ]] && return 0

  if [[ "${STOP_VERIFY_DRY:-0}" == 1 ]]; then
    echo "[dry] $KEY in $ROOT limit=${LIMIT}s deadline=${DEADLINE}s changed=${#CODE[@]} :: $VERIFY" >&2
    return 0
  fi
  local PREV; PREV="$(grep -m1 "^$RFP " <<<"$SET")"
  if [[ -n "$PREV" ]] && redm; then released "${PREV#* }" 0; return 0; fi   # already blocked here; deleting <id>.red forces a re-run

  local RC=1 START SECS=0 LEFT V; V="$(redline | cut -d' ' -f2)"; V="${V:-fail}"
  if ! redm; then   # a state that already failed is not run again
    LEFT=$((DEADLINE - SECONDS))
    if (( LEFT < LIMIT + 30 )); then led skipped ok 0; msg "$KEY: not enough time left in this stop to run checks; not verified"; return 0; fi
    LOG="$(mktemp "${TMPDIR:-/tmp}/stop-verify.XXXXXX")" || note "mktemp failed; verification skipped"
    LIST="$(mktemp "${TMPDIR:-/tmp}/stop-verify-list.XXXXXX")" || note "mktemp failed; verification skipped"
    printf '%s\n' "${CODE[@]}" > "$LIST"
    START=$SECONDS
    VERIFY_CHANGED_FILE="$LIST" run_limited "$LIMIT" bash -c "$VERIFY" >"$LOG" 2>&1
    RC=$?
    SECS=$((SECONDS - START)); /bin/rm -f "$LIST"
    if (( RC == 0 )); then
      wr "$S.pass" "$PFP"; /bin/rm -f "$S.$SESSION.blocks" "$S.red" "$S.fail.log" "$LOG"; led pass ok "$SECS"; return 0
    fi
    V=fail; (( RC == 124 )) && V=timeout
    FT="$(mktemp "$STATE_DIR/.f.XXXXXX")" && tail -c 2000000 "$LOG" > "$FT" && mv -f "$FT" "$S.fail.log" || no_state
    /bin/rm -f "$LOG"
    local P0="$PFP" R0="$RFP"   # verify may have written files: remember the state after the run too
    if list_files && fingerprint; then RFP2="$RFP"; fi
    PFP="$P0"; RFP="$R0"; [[ "$RFP2" == "$RFP" ]] && RFP2=""
    wr "$S.red" "$(printf '%s\n%s %s %s' "$REDALL" "$RFP" "$V" "$RFP2" | grep . | tail -20)"
  fi

  if released "$V" "$SECS"; then return 0; fi
  {
    local RAN="rc=$RC, ${SECS}s, load $LOAD"; redm && RAN="an earlier run of this exact state, not re-run"
    if [[ "$V" == timeout ]]; then
      echo "[stop-verify] $KEY: checks did NOT FINISH within the limit ($RAN) in $ROOT (block $((BLOCKS + 1))/$MAX_BLOCKS). This is 'not verified', not a test failure."
      echo "Editing code rarely fixes this, and finishing again will not re-run it. Tell the user the checks timed out and what the lines below show (a hung test, or a busy machine)."
    else
      echo "[stop-verify] $KEY: checks FAILED ($RAN) in $ROOT (block $((BLOCKS + 1))/$MAX_BLOCKS)."
      echo "If this session's changes caused it: fix the cause, then finish again."
      echo "If not (another agent or the user is still working here, or the test fails only sometimes): say so and stop. Do not edit or revert work that is not yours. This exact state will not be re-run or blocked again."
    fi
    echo "Full log: $S.fail.log"
    [[ -f "$S.fail.log" ]] || return 2
    { if grep -q "failing tests:" "$S.fail.log"; then sed -n '/failing tests:/,$p' "$S.fail.log" | head -60
      elif grep -qE '^[[:space:]]*(not ok |✖)' "$S.fail.log"; then grep -E -A6 '^[[:space:]]*(not ok |✖)' "$S.fail.log" | head -60
      else tail -15 "$S.fail.log"; fi; } | LC_ALL=C cut -c1-500
  } >&2
  return 2
}

ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || exit 0
KEY="$(project_of "$ROOT")"
[[ -n "$KEY" ]] || exit 0
# Only checkouts listed in "roots" (and their linked worktrees) are trusted.
in_roots() { [[ -n "$1" ]] && jq -e --arg k "$KEY" --arg r "$1" '(.[$k].roots // []) | map(sub("/+$";"")) | index($r) != null' "$CONF" >/dev/null 2>&1; }
RROOT="$(cd "$ROOT" && pwd -P)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
MAIN="$( [[ -n "$COMMON" ]] && cd "$COMMON/.." 2>/dev/null && pwd -P)"
# A worktree counts only if the trusted checkout itself lists it (a crafted .git file is not enough).
trusted_worktree() {
  [[ -n "$MAIN" && "$MAIN" != "$RROOT" ]] && in_roots "$MAIN" || return 1
  local line p
  while IFS= read -r line; do
    [[ "$line" == "worktree "* ]] || continue
    p="$(cd "${line#worktree }" 2>/dev/null && pwd -P)" && [[ "$p" == "$RROOT" ]] && return 0
  done < <(git -C "$MAIN" worktree list --porcelain 2>/dev/null)
  return 1
}
if ! in_roots "$RROOT" && ! trusted_worktree; then
  if jq -e --arg k "$KEY" '.[$k].roots' "$CONF" >/dev/null 2>&1; then
    msg "$KEY: this checkout is not in roots, so its checks are not run. To trust it, add its real path to roots: $RROOT"
  else
    msg "$KEY has no roots list; add this checkout path to roots to trust it: $RROOT"
  fi
  exit 0
fi
verify_root "$ROOT" "$KEY"
exit $?
