#!/usr/bin/env bash
# subagent-verify.sh — layer 2: check a subagent's work before it hands in its report.
#
# Input: PreToolUse with tool_name SubagentHandback. That is the tool a subagent calls to hand
#   in its report (observed on recent Claude Code). exit 2 blocks the hand-back and stderr goes
#   to the subagent, which keeps working. Any other PreToolUse call exits 0 at once. On a host
#   without that tool this hook never fires. A SubagentStop input is also understood (exit 2 keeps
#   the subagent running), but the plugin does not register that event.
#
# What counts as "the subagent changed something", read from the subagent's OWN transcript:
#   (a) a file written by Edit / Write / MultiEdit / NotebookEdit whose tool result was not an error;
#   (b) a successful Bash command that names a trusted checkout (or ran with its cwd inside one)
#       AND contains a write sign (> >> sed -i mv cp rm tee patch, git checkout/reset/..., etc.).
#       Read-only git (status, log, diff, show, stash list/show) is not a write. This is string
#       matching: it can miss a write and can count a harmless command.
# Only checkouts listed in "roots" of the projects file count (same trust as stop-verify.sh).
# If there is one, run that project's check at its root.
#
# Config, same projects file as stop-verify.sh. Optional fields per project:
#   handback_verify   bash command to run (default: the project's "verify")
#   handback_limit    seconds before the run is stopped as "not verified" (1..440, default 420)
# $VERIFY_CHANGED_FILE names a file listing the repo-relative paths the subagent wrote with the
# edit tools (empty when only Bash wrote).
#   exit 2   only when the command exits non-zero (not 124 / 126 / 127 / killed by a signal), at
#            most 2 blocks per agent, once per fingerprint (path + HEAD + diff + untracked files).
#            The block record is written under a lock and re-checked inside it; if it cannot be
#            written the hook exits 0 instead.
#   exit 0   everything else (no transcript, no change, untrusted path, timeout, missing tool,
#            signal, own error), with a systemMessage saying "not verified" where it matters.
# Known limit: checkouts are shared between sessions, so a failure may come from another
#   session's edit. The block message says so.
#
# Whole decision runs under a watchdog (460 s; the plugin hook timeout is 480), started by us with
# --inner. Test-only overrides SUBVERIFY_STATE and SUBVERIFY_TOTAL are ignored when this script
# lives under ~/.claude. They never touch trust: trust is only "roots".
# Ledger: ~/.claude/state/subagent-verify/ledger.tsv  (time, project, agent, result, seconds)
#   result: pass | fail | timeout | error | repeat | capped | no-change | no-transcript | skip
set -uo pipefail
SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd -P)"
CONF="${STOP_VERIFY_CONFIG:-$HOME/.claude/stop-verify.projects.json}"
[[ -f "$CONF" ]] || exit 0
STATE_DIR="$HOME/.claude/state/subagent-verify"
TOTAL_LIMIT=460
MAX_BLOCKS=2
CLAUDE_HOME="$(cd "$HOME/.claude" 2>/dev/null && pwd -P)"
if [[ -z "$CLAUDE_HOME" || "$SELF_DIR" != "$CLAUDE_HOME"/* ]]; then
  STATE_DIR="${SUBVERIFY_STATE:-$STATE_DIR}"
  [[ "${SUBVERIFY_TOTAL:-}" =~ ^[0-9]{1,3}$ ]] && TOTAL_LIMIT=$((10#$SUBVERIFY_TOTAL)) && (( TOTAL_LIMIT >= 1 )) || TOTAL_LIMIT=460
fi
INNER=0; for a in "$@"; do [[ "$a" == --inner ]] && INNER=1; done
# shellcheck source=lib/projects.sh
source "$SELF_DIR/lib/projects.sh" 2>/dev/null || exit 0

msg() { jq -cn --arg m "[subagent-verify] $1" '{systemMessage:$m}' 2>/dev/null; }
led() {  # project, result   (needs AGENT, START)
  ( umask 077; mkdir -p "$STATE_DIR" &&
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(clean_tabs "$1")" "${AGENT:0:8}" "$2" "$((SECONDS - START))" >> "$STATE_DIR/ledger.tsv" ) 2>/dev/null
}

# ---------- outer: watchdog around the whole decision ----------
if (( INNER == 0 )); then
  INPUT="$(cat)"
  # Cheap exit for every other tool call: no process is started.
  case "$INPUT" in *SubagentHandback*|*SubagentStop*) ;; *) exit 0 ;; esac
  command -v jq >/dev/null 2>&1 || exit 0
  command -v perl >/dev/null 2>&1 || exit 0
  START=$SECONDS
  OUTF="$(mktemp "${TMPDIR:-/tmp}/sv-out.XXXXXX")" || exit 0
  ERRF="$(mktemp "${TMPDIR:-/tmp}/sv-err.XXXXXX")" || { /bin/rm -f "$OUTF"; exit 0; }
  trap '/bin/rm -f "$OUTF" "$ERRF"' EXIT
  printf '%s' "$INPUT" | run_limited "$TOTAL_LIMIT" bash "$SELF" --inner >"$OUTF" 2>"$ERRF"; RC=$?
  if (( RC == 124 || (RC != 0 && RC != 2) )); then
    AGENT="$(printf '%s' "$INPUT" | jq -r '.agent_id // "noagent"' 2>/dev/null)"; AGENT="${AGENT//[^A-Za-z0-9_-]/_}"
    if (( RC == 124 )); then led "-" timeout; msg "Subagent check timed out (${TOTAL_LIMIT} s); not verified."
    else led "-" error; msg "Subagent check failed by itself (rc=${RC}); not verified."; fi
    exit 0
  fi
  cat "$OUTF"; cat "$ERRF" >&2
  exit "$RC"
fi

# ---------- inner ----------
START=$SECONDS
BUDGET=$((TOTAL_LIMIT - 10)); (( BUDGET >= 5 )) || BUDGET=5
INPUT="$(cat)"
j() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null; }
if command -v shasum >/dev/null 2>&1; then HASH=shasum
elif command -v sha1sum >/dev/null 2>&1; then HASH=sha1sum
else HASH=""; fi
SESSION="$(j '.session_id // "nosession"')"; SESSION="${SESSION//[^A-Za-z0-9_-]/_}"
EVENT="$(j '.hook_event_name // empty')"; TOOLN="$(j '.tool_name // empty')"
T="$(j '.agent_transcript_path // empty')"; T="${T/#\~/$HOME}"
AGENT="$(j '.agent_id // empty')"
PRE=0
if [[ "$EVENT" != SubagentStop ]]; then
  # Any other tool: nothing to do. The subagent's transcript path is derived:
  # dirname(transcript_path)/<session_id>/subagents/agent-<agent_id>.jsonl
  [[ "$TOOLN" == SubagentHandback ]] || exit 0
  PRE=1; T=""
  MT="$(j '.transcript_path // empty')"; MT="${MT/#\~/$HOME}"; RAWS="$(j '.session_id // empty')"
  if [[ -n "$MT" && -n "$RAWS" && -n "$AGENT" ]]; then T="$(dirname "$MT")/$RAWS/subagents/agent-$AGENT.jsonl"; fi
fi
[[ -n "$AGENT" ]] || AGENT="$(basename "${T:-noagent}" .jsonl)"
AGENT="${AGENT//[^A-Za-z0-9_-]/_}"

(umask 077; mkdir -p "$STATE_DIR") 2>/dev/null || { msg "Cannot create the state folder; not verified."; exit 0; }
[[ -n "$HASH" ]] || { led "-" error; msg "shasum/sha1sum missing; not verified."; exit 0; }
# No fallback to the main session transcript: it would blame the subagent for the parent's edits.
if [[ -z "$T" || ! -f "$T" ]]; then
  led "-" no-transcript
  msg "Cannot read the subagent's transcript; not verified."
  exit 0
fi
if ! jq -n '[inputs]|length' "$T" >/dev/null 2>&1; then
  led "-" error; msg "The subagent's transcript could not be parsed; not verified."; exit 0
fi

# --- 1. what the subagent changed, from its own transcript ---
OK_JQ='
  [inputs] as $all
  | (reduce ($all[] | select(.type == "user") | .message.content? | arrays | .[]
        | select(type == "object" and .type == "tool_result" and ((.is_error // false) | not))
        | .tool_use_id) as $id ({}; .[$id] = true)) as $ok'
FILES_JQ="$OK_JQ"'
  | [ $all[] | select(.type == "assistant") | .message.content? | arrays | .[]
      | select(type == "object" and .type == "tool_use")
      | select($ok[.id // ""] == true)
      | select(.name == "Edit" or .name == "Write" or .name == "MultiEdit" or .name == "NotebookEdit")
      | (.input.file_path // .input.notebook_path // empty)
      | select(type == "string" and startswith("/")) ]
  | unique | .[] | . + "\u0000"'
# Bash calls with a write sign: prints cwd NUL command NUL
BASH_JQ="$OK_JQ"'
  | $all[] | select(.type == "assistant") | (.cwd // "") as $cwd | .message.content? | arrays | .[]
    | select(type == "object" and .type == "tool_use" and .name == "Bash" and ($ok[.id // ""] == true))
    | (.input.command // "" | tostring) as $c
    | ($c | gsub("[0-9]?>&[0-9]"; "") | gsub("[0-9]?>>? ?/dev/null"; "")) as $x
    | select($x | test(">|>>|sed +(-[A-Za-z]+ +)*-i|git apply|(^|[;&|(] *)(mv|cp|rm|tee|patch|install) |git +(-[Cc] +.*[ \"])?(checkout|switch|reset|restore|apply|am|merge|rebase|cherry-pick|commit|rm|mv|clean|stash( +(push|pop|apply|drop|save|clear|branch|create|store)|( +-[-A-Za-z]+)*( *$| *[;&|])))|\\.write_text|\\.write_bytes|writeFileSync"))
    | ($cwd + "\u0000" + $c + "\u0000")'
PLIST=(); while IFS= read -r -d '' f; do PLIST+=("$f"); done < <(jq -nj "$FILES_JQ" "$T" 2>/dev/null; )
BASHL=(); while IFS= read -r -d '' f; do BASHL+=("$f"); done < <(jq -nj "$BASH_JQ" "$T" 2>/dev/null; )

NOTES=""
UROOTS=(); UKEYS=()
add_root() { local u; for u in ${UROOTS[@]+"${UROOTS[@]}"}; do [[ "$u" == "$1" ]] && return; done; UROOTS+=("$1"); UKEYS+=("$2"); }

# 1a. structured edits
GONE=0; CD_LAST=""; CR_LAST=""; CK_LAST=""
for f in ${PLIST[@]+"${PLIST[@]}"}; do
  if [[ ! -f "$f" ]]; then GONE=$((GONE + 1)); continue; fi
  if [[ -L "$f" ]]; then continue; fi
  d="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)" || { GONE=$((GONE + 1)); continue; }
  if [[ "$d" != "$CD_LAST" ]]; then CD_LAST="$d"; if resolve_trusted "$d"; then CR_LAST="$R_ROOT"; CK_LAST="$R_KEY"; else CR_LAST=""; fi; fi
  [[ -n "$CR_LAST" ]] && add_root "$CR_LAST" "$CK_LAST"
done
(( GONE > 0 )) && NOTES+="${GONE} written files no longer exist and were skipped. "

# 1b. Bash with a write sign that mentions a trusted checkout (or ran inside one)
if (( ${#BASHL[@]} > 0 )); then
  CANDS=()   # trusted checkouts named in the projects file, plus their linked worktrees
  while IFS= read -r p; do
    d="$(cd "$p" 2>/dev/null && pwd -P)" || continue
    CANDS+=("$d")
    while IFS= read -r line; do
      [[ "$line" == "worktree "* ]] || continue
      w="$(cd "${line#worktree }" 2>/dev/null && pwd -P)" && [[ "$w" != "$d" ]] && CANDS+=("$w")
    done < <(git -C "$d" worktree list --porcelain 2>/dev/null)
  done < <(jq -r '.[] | (.roots // [])[]? | select(type == "string")' "$CONF" 2>/dev/null)
  i=0
  while (( i + 1 < ${#BASHL[@]} )); do
    cwd="${BASHL[$i]}"; cmd="${BASHL[$((i + 1))]}"; i=$((i + 2))
    if [[ -n "$cwd" && -d "$cwd" ]]; then
      pc="$(cd "$cwd" 2>/dev/null && pwd -P)" && resolve_trusted "$pc" && add_root "$R_ROOT" "$R_KEY"
    fi
    # candidate checkouts named in the command: match on whole path components, then ask
    # resolve_trusted about the nearest existing directory of the target (a deleted file's parent)
    for d in ${CANDS[@]+"${CANDS[@]}"}; do
      for form in "$d" "${d// /\\ }"; do
        rest="$cmd"
        while [[ "$rest" == *"$form"* ]]; do
          rest="${rest#*"$form"}"
          nx="${rest:0:1}"
          if [[ -z "$nx" || "$nx" == [/\"\'\;\&\|\<\>\(\)\`] || "$nx" == [[:space:]] ]]; then
            tail="${rest%%[[:space:]\"\'\;\&\|\<\>\(\)\`]*}"
            tp="$d$tail"
            while [[ ! -d "$tp" && ${#tp} -gt ${#d} ]]; do tp="${tp%/*}"; done
            [[ -d "$tp" ]] || tp="$d"
            resolve_trusted "$tp" && add_root "$R_ROOT" "$R_KEY"
          fi
        done
      done
    done
  done
fi

if (( ${#UROOTS[@]} == 0 )); then
  led "-" no-change
  [[ -n "$NOTES" ]] && msg "$NOTES"
  exit 0
fi

# --- 2. per checkout: guard, fingerprint, run the check ---
LOCKD="$STATE_DIR/$SESSION.$AGENT.lock"
BF="$STATE_DIR/$SESSION.$AGENT.blocked"
sleep_s() { perl -e 'select(undef,undef,undef,$ARGV[0])' "$1"; }
lock_acquire() {
  local n=0
  while (( n < 100 )); do
    mkdir "$LOCKD" 2>/dev/null && return 0
    if [[ -n "$(find "$LOCKD" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then rmdir "$LOCKD" 2>/dev/null; fi
    sleep_s 0.1; n=$((n + 1))
  done
  return 1
}
lock_release() { rmdir "$LOCKD" 2>/dev/null; }
bf_count() { local n=0; [[ -f "$BF" ]] && n="$(wc -l < "$BF" 2>/dev/null | tr -d ' ')"; [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }
fingerprint() {  # root -> hash of path + HEAD + git diff HEAD + untracked paths and content hashes
  local r="$1"
  { printf '%s\0' "$r"
    git -C "$r" rev-parse HEAD 2>/dev/null || echo nohead
    git -C "$r" diff HEAD 2>/dev/null | "$HASH"
    git -C "$r" ls-files -z --others --exclude-standard 2>/dev/null | while IFS= read -r -d '' f; do
      printf '%s\0' "$f"; "$HASH" < "$r/$f" 2>/dev/null || echo unreadable
    done | "$HASH"
  } | "$HASH" | cut -c1-40
}

FAIL_TEXT=""; RC=0; PASS_TEXT=""; k=0
for ROOT in "${UROOTS[@]}"; do
  KEY="${UKEYS[$k]}"; k=$((k + 1))
  NAME="${ROOT##*/}"
  if ! jq -e --arg k "$KEY" '.[$k] | ((has("handback_verify") | not) or (.handback_verify | type) == "string") and ((has("verify") | not) or (.verify | type) == "string") and ((has("requires") | not) or (.requires | type) == "string") and ((has("handback_limit") | not) or (.handback_limit | type) == "number")' "$CONF" >/dev/null 2>&1; then
    led "$KEY" error; NOTES+="$NAME: handback_verify / verify / requires must be strings and handback_limit a number; not verified. "; continue
  fi
  VERIFY="$(pfield "$KEY" handback_verify)"; [[ -n "$VERIFY" ]] || VERIFY="$(pfield "$KEY" verify)"
  REQ="$(pfield "$KEY" requires)"
  LIMIT="$(jq -r --arg k "$KEY" '.[$k].handback_limit // 420 | floor' "$CONF" 2>/dev/null)"
  if [[ -z "$VERIFY" ]]; then led "$KEY" skip; NOTES+="$NAME: no handback_verify or verify command; not verified. "; continue; fi
  if ! { [[ "$LIMIT" =~ ^[0-9]{1,4}$ ]] && LIMIT=$((10#$LIMIT)) && (( LIMIT >= 1 && LIMIT <= BUDGET )) && (( LIMIT <= 440 )); }; then
    led "$KEY" error; NOTES+="$NAME: handback_limit must be 1-$(( BUDGET < 440 ? BUDGET : 440 )) seconds; not verified. "; continue
  fi
  if [[ -n "$REQ" && ! -e "$ROOT/$REQ" ]]; then led "$KEY" skip; NOTES+="$NAME: $REQ is missing; not verified. "; continue; fi

  FP="$(fingerprint "$ROOT")"
  if [[ ${#FP} != 40 ]]; then led "$KEY" error; NOTES+="$NAME: could not fingerprint the changes; not verified. "; continue; fi
  if grep -qxF "$FP" "$BF" 2>/dev/null; then
    led "$KEY" repeat; NOTES+="$NAME: this exact state was already blocked once and is not re-run; not verified. "; continue
  fi
  NBLK="$(bf_count)"
  if (( NBLK >= MAX_BLOCKS )); then
    led "$KEY" capped; NOTES+="$NAME: this agent was already blocked ${NBLK} times (limit ${MAX_BLOCKS}); not verified. "; continue
  fi
  LEFT=$((BUDGET - (SECONDS - START)))
  if (( LEFT < 3 )); then led "$KEY" timeout; NOTES+="$NAME: out of time; not verified. "; continue; fi
  (( LIMIT < LEFT )) && LEFT=$LIMIT

  LOG="$(mktemp "${TMPDIR:-/tmp}/subagent-verify.XXXXXX")" || { led "$KEY" error; NOTES+="Cannot create a temp file; not verified. "; continue; }
  LIST="$(mktemp "${TMPDIR:-/tmp}/subagent-verify-list.XXXXXX")" || { /bin/rm -f "$LOG"; led "$KEY" error; NOTES+="Cannot create a temp file; not verified. "; continue; }
  for f in ${PLIST[@]+"${PLIST[@]}"}; do
    pf="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)/${f##*/}"
    [[ "$pf" == "$ROOT"/* ]] && printf '%s\n' "${pf#"$ROOT"/}"
  done > "$LIST"
  T0=$SECONDS
  ( cd "$ROOT" && VERIFY_CHANGED_FILE="$LIST" run_limited "$LEFT" bash -c "$VERIFY" ) </dev/null >"$LOG" 2>&1
  TRC=$?
  EL=$((SECONDS - T0)); /bin/rm -f "$LIST"
  if (( TRC == 0 )); then VERDICT=pass
  elif (( TRC == 124 )); then VERDICT=timeout
  elif (( TRC == 126 || TRC == 127 || TRC > 128 )); then VERDICT=error
  else VERDICT=fail; fi
  case "$VERDICT" in
    pass)    led "$KEY" pass; PASS_TEXT+="$NAME: checks passed (${EL} s). " ;;
    timeout) led "$KEY" timeout; NOTES+="$NAME: checks did not finish within ${LEFT} s; not verified. " ;;
    error)   led "$KEY" error; NOTES+="$NAME: the check command could not run or was killed (rc=${TRC}); not a test failure; not verified. " ;;
    fail)
      # record the block under the lock, re-judging inside it (concurrent callbacks)
      DEC=none
      if lock_acquire; then
        if grep -qxF "$FP" "$BF" 2>/dev/null; then DEC=repeat
        elif (( $(bf_count) >= MAX_BLOCKS )); then DEC=capped
        elif printf '%s\n' "$FP" >> "$BF" 2>/dev/null && grep -qxF "$FP" "$BF" 2>/dev/null; then DEC=block
        else DEC=norecord; fi
        lock_release
      fi
      case "$DEC" in
        block)
          led "$KEY" fail
          FAIL_TEXT+="$(printf '[%s] the check command failed (exit %d, %d s). Last output:' "$NAME" "$TRC" "$EL")"$'\n'
          FAIL_TEXT+="$(tail -40 "$LOG" | LC_ALL=C cut -c1-300)"$'\n'
          RC=2 ;;
        repeat) led "$KEY" repeat; NOTES+="$NAME: the check failed, but another call already blocked this exact state; not blocking again; not verified. " ;;
        capped) led "$KEY" capped; NOTES+="$NAME: the check failed, but this agent was already blocked ${MAX_BLOCKS} times; not blocking; not verified. " ;;
        *) led "$KEY" error; NOTES+="$NAME: the check failed, but the block record could not be written or locked; not blocking, to avoid a stuck agent; not verified. " ;;
      esac ;;
  esac
  /bin/rm -f "$LOG"
done

if (( RC == 2 )); then
  WHEN="Before you hand in your report"; (( PRE )) || WHEN="Before you finish"
  { echo "[subagent-verify] $WHEN: the project's checks FAILED. Fix what your changes broke, then try again (block $(bf_count)/$MAX_BLOCKS for this agent)."
    printf '%s' "$FAIL_TEXT"; [[ -n "$NOTES" ]] && printf '%s\n' "$NOTES"
    echo "This checkout may be shared. If the failure is not from your own edits (another session can change files here), say so in your report and stop; do not edit or revert work that is not yours. This exact state is not blocked again."; } >&2
  exit 2
fi
ALLMSG="${PASS_TEXT}${NOTES}"
[[ -n "$ALLMSG" ]] && msg "$ALLMSG"
exit 0
