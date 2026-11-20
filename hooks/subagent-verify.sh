#!/usr/bin/env bash
# subagent-verify.sh — layer 2: check a subagent's work before it hands in its report.
#
# Input, two events, both registered by the plugin:
#   PreToolUse with tool_name SubagentHandback: the tool a subagent calls to hand in its report.
#     exit 2 blocks the hand-back and stderr goes to the subagent, which keeps working. Any other
#     PreToolUse call exits 0 at once.
#   SubagentStop: for hosts without that tool (Claude Code 2.1.329 sessions were seen without it).
#     exit 2 keeps the subagent running. On a host that has the tool, SubagentStop arrives after
#     the report is in, so exit 2 there is useless; hence the dedupe below.
# Dedupe: each hand-back starts a fresh snapshot. Stop skips checkouts whose fingerprint the
#   latest hand-back checked. An unfinished check stays unverified. A delivered report cannot
#   be recalled at stop. Later changes to the shared checkout are reported as unverified.
#   On a SubagentStop-only host nothing writes that record, so every check runs as before.
#   Loop guard: the cap of 2 blocks per agent (and once per fingerprint) bounds SubagentStop too,
#   whatever stop_hook_active says; no second mechanism.
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
# Config, same projects file as stop-verify.sh ($STOP_VERIFY_CONFIG is used only when it is an
# absolute path to a file under ~/.claude or ~/.config). Opt-in per project: a project without "handback_verify" is never checked here.
#   handback_verify   bash command to run at the checkout root (no fallback to "verify")
#   handback_limit    seconds before the run is stopped as "not verified" (1..440, default 420)
#   requires          optional path that must exist under the root, as for stop-verify.sh
# $VERIFY_CHANGED_FILE names a file listing the repo-relative paths the subagent wrote with the
# edit tools (empty when only Bash wrote).
#   exit 2   only when the command exits non-zero (not 124 / 126 / 127 / killed by a signal, and it
#            must have been started), at most 2 blocks per agent, once per fingerprint (path +
#            HEAD + diff + untracked files; a repo with no commit, or any step that cannot be
#            listed or hashed, means "not verified", never a fingerprint).
#            The block record is written under a lock and re-checked inside it; if it cannot be
#            written the hook exits 0 instead.
#   exit 0   everything else (no transcript, no change, untrusted path, timeout, missing tool,
#            signal, own error), with a systemMessage saying "not verified" where it matters.
# Known limit: checkouts are shared between sessions, so a failure may come from another
#   session's edit. The block message says so.
#
# The whole hook, including reading stdin, runs under a 460 s budget (the plugin hook timeout is
# 480); the inner process is started by us with --inner and a TERM is forwarded to the check.
# Test-only overrides SUBVERIFY_STATE and SUBVERIFY_TOTAL are ignored when this script lives under
# ~/.claude. They never touch trust: trust is only "roots".
# Ledger: ~/.claude/state/subagent-verify/ledger.tsv  (time, project, agent, result, seconds)
#   result: pass | fail | timeout | error | repeat | capped | no-change | no-transcript | skip | handback-done
set -uo pipefail
START=$SECONDS
SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd -P)"
# shellcheck source=lib/projects.sh
source "$SELF_DIR/lib/projects.sh" 2>/dev/null || exit 0
CONF="$(pick_conf)"
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

msg() { run_limited 2 jq -cn --arg m "[subagent-verify] $1" '{systemMessage:$m}' 2>/dev/null; }
led() {  # project, result   (needs AGENT, START)
  ledger_append "$STATE_DIR" "$1" "${AGENT:0:8}" "$2" "$((SECONDS - START))"
}
WARN='{"systemMessage":"[subagent-verify] %s; subagent check skipped"}\n'

# ---------- outer: watchdog around the whole decision ----------
if (( INNER == 0 )); then
  trap 'exit 143' TERM INT
  # Without perl nothing can be bounded: warn and leave before touching stdin.
  command -v perl >/dev/null 2>&1 || { printf "$WARN" "perl missing"; exit 0; }
  RC=0; INPUT="$(run_limited 5 cat)"; RC=$?   # reading stdin is bounded too
  # Cheap exit for every other tool call: nothing else is started.
  case "$INPUT" in *SubagentHandback*|*SubagentStop*) ;; *) exit 0 ;; esac
  command -v jq >/dev/null 2>&1 || { printf "$WARN" "jq missing"; exit 0; }
  (( RC == 0 )) || { printf "$WARN" "stdin was not complete in 5 s"; exit 0; }
  OUTF="$(mktemp "${TMPDIR:-/tmp}/sv-out.XXXXXX")" || exit 0
  ERRF="$(mktemp "${TMPDIR:-/tmp}/sv-err.XXXXXX")" || { /bin/rm -f "$OUTF"; exit 0; }
  trap '/bin/rm -f "$OUTF" "$ERRF"' EXIT
  LEFT=$((TOTAL_LIMIT - (SECONDS - START))); (( LEFT >= 1 )) || LEFT=1
  printf '%s' "$INPUT" | run_limited "$LEFT" bash "$SELF" --inner >"$OUTF" 2>"$ERRF"; RC=$?
  if (( RC == 124 || (RC != 0 && RC != 2) )); then
    AGENT="$(printf '%s' "$INPUT" | run_limited 2 jq -r '.agent_id // "noagent"' 2>/dev/null)"; AGENT="${AGENT//[^A-Za-z0-9_-]/_}"
    if (( RC == 124 )); then led_bounded "$STATE_DIR" "-" "${AGENT:0:8}" timeout "$((SECONDS - START))"; msg "Subagent check timed out (${TOTAL_LIMIT} s); not verified."
    else led_bounded "$STATE_DIR" "-" "${AGENT:0:8}" error "$((SECONDS - START))"; msg "Subagent check failed by itself (rc=${RC}); not verified."; fi
    exit 0
  fi
  cat "$OUTF"; cat "$ERRF" >&2
  exit "$RC"
fi

# ---------- inner ----------
START=$SECONDS
LOG=""; LIST=""; STARTED=""; SDIR=""; XF1=""; XF2=""; FPD=""; FPU=""; FPF=""; LOCKHELD=0; LOCKD=""; HF_TMP=""
cleanup() {
  /bin/rm -f "$LOG" "$LIST" "$XF1" "$XF2" "$FPD" "$FPU" "$FPF" "$HF_TMP" 2>/dev/null
  [[ -n "$SDIR" ]] && /bin/rm -rf "$SDIR" 2>/dev/null
  (( LOCKHELD )) && [[ -n "$LOCKD" ]] && rmdir "$LOCKD" 2>/dev/null
  return 0
}
trap cleanup EXIT
trap 'exit 143' TERM INT
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
  PRE=1
fi
if [[ -z "$T" ]]; then
  MT="$(j '.transcript_path // empty')"; MT="${MT/#\~/$HOME}"; RAWS="$(j '.session_id // empty')"
  if [[ "$MT" == /* && "$RAWS" =~ ^[A-Za-z0-9_-]+$ && "$AGENT" =~ ^[A-Za-z0-9_-]+$ ]]; then
    T="$(dirname "$MT")/$RAWS/subagents/agent-$AGENT.jsonl"
  fi
fi
[[ -n "$AGENT" ]] || AGENT="$(basename "${T:-noagent}" .jsonl)"
AGENT="${AGENT//[^A-Za-z0-9_-]/_}"

(umask 077; mkdir -p "$STATE_DIR") 2>/dev/null || { msg "Cannot create the state folder; not verified."; exit 0; }
HF="$STATE_DIR/$SESSION.$AGENT.handback"
RECORD_HANDBACK=0
NOTES=""
if (( PRE )); then
  # Publish an empty snapshot before reading the transcript. An overlapping older callback
  # keeps its own file descriptor, so its later verdicts cannot enter the new snapshot.
  if HF_TMP="$(mktemp "$HF.XXXXXX")" && { exec 3>"$HF_TMP"; } && [[ ! -d "$HF" ]] && mv -f "$HF_TMP" "$HF"; then
    HF_TMP=""; RECORD_HANDBACK=1
    CALL_ID="$(j '.tool_use_id // empty')"
    [[ "$CALL_ID" =~ ^[A-Za-z0-9_:-]+$ ]] && printf 'call %s\n' "$CALL_ID" >&3
  else
    /bin/rm -f "$HF" 2>/dev/null || { : > "$HF"; } 2>/dev/null
    NOTES+="Could not refresh the hand-back record. "
  fi
fi
# prune only this hook's own block records (<session>.<agent>.blocked, this folder only), after 30 days
find "$STATE_DIR" -maxdepth 1 -type f \( -name '[A-Za-z0-9_-]*.[A-Za-z0-9_-]*.blocked' -o -name '[A-Za-z0-9_-]*.[A-Za-z0-9_-]*.handback' \) -mtime +30 -delete 2>/dev/null
[[ -n "$HASH" ]] || { led "-" error; msg "shasum/sha1sum missing; not verified."; exit 0; }
# No fallback to the main session transcript: it would blame the subagent for the parent's edits.
if [[ -z "$T" || ! -f "$T" ]]; then
  led "-" no-transcript
  msg "Cannot read the subagent's transcript; not verified."
  exit 0
fi
# Only a successful tool result in this agent's transcript confirms delivery. A later
# tool call starts new work and invalidates the receipt. A PreToolUse allow is not delivery.
DELIVERED=""
if (( PRE )); then
  TRANSCRIPT_QUERY='reduce inputs as $row (0; .)'
else
  TRANSCRIPT_QUERY='
    reduce (inputs | . as $row | .message.content? | arrays | .[] | objects | [$row.type, .]) as [$role, $c]
      ({id:null, delivered:false};
       if $role == "assistant" and $c.type == "tool_use" then
         {id:(if $c.name == "SubagentHandback" then $c.id else null end), delivered:false}
       elif $role == "user" and $c.type == "tool_result" and .id != null and $c.tool_use_id == .id then
         .delivered = (($c.is_error // false) == false)
       else . end)
    | if .delivered then (.id | strings | select(test("^[A-Za-z0-9_:-]+$"))) else empty end'
fi
if ! RESULT="$(jq -nr "$TRANSCRIPT_QUERY" "$T" 2>/dev/null)"; then
  led "-" error; msg "The subagent's transcript could not be parsed; not verified."; exit 0
fi
SNAPSHOT=""
if (( ! PRE )); then
  DELIVERED="$RESULT"
  if [[ -f "$HF" && -w "$STATE_DIR" ]]; then SNAPSHOT="$(cat "$HF" 2>/dev/null)" || SNAPSHOT=""; fi
  # A receipt from a different attempt cannot authenticate these results.
  if [[ -n "$DELIVERED" ]] && ! grep -qxF "call $DELIVERED" <<< "$SNAPSHOT"; then SNAPSHOT=""; fi
fi

# --- 1. what the subagent changed, from its own transcript ---
OK_JQ='
  [inputs] as $all
  | (reduce ($all[] | select(.type == "user") | .message.content? | arrays | .[]
        | select(type == "object" and .type == "tool_result" and (.is_error // false) == true
          and ((.content | if type == "string" then . elif type == "array" then (map(.text? // "") | join("")) else "" end) | startswith("Permission to use Bash denied")))
        | .tool_use_id) as $id ({}; .[$id] = true)) as $denied
  | (reduce ($all[] | select(.type == "user") | .message.content? | arrays | .[]
        | select(type == "object" and .type == "tool_result")
        | .tool_use_id) as $id ({}; .[$id] = true)) as $seen
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
# Bash calls with a write sign: prints cwd NUL command NUL. A call whose result was an error still
# counts (a command can write and then fail); a call with no result at all does not (it may never
# have run), and neither does one the host or a hook refused to run. Observed in real transcripts:
# the tool_result has is_error true and content starting with
#   Permission to use Bash denied by plugin <name>: This call was refused: ...
# Only that text is matched; no other refusal wording has been seen, so none is guessed.
BASH_JQ="$OK_JQ"'
  | $all[] | select(.type == "assistant") | (.cwd // "") as $cwd | .message.content? | arrays | .[]
    | select(type == "object" and .type == "tool_use" and .name == "Bash" and ($seen[.id // ""] == true) and ($denied[.id // ""] != true))
    | (.input.command // "" | tostring) as $c
    | ($c | gsub("[0-9]?>&[0-9]"; "") | gsub("[0-9]?>>? ?/dev/null"; "")) as $x
    | select($x | test(">|>>|sed +(-[A-Za-z]+ +)*-i|git apply|(^|[;&|(] *)(mv|cp|rm|tee|patch|install) |git +(-[Cc] +.*[ \"])?(checkout|switch|reset|restore|apply|am|merge|rebase|cherry-pick|commit|rm|mv|clean|stash( +(push|pop|apply|drop|save|clear|branch|create|store)|( +-[-A-Za-z]+)*( *$| *[;&|])))|\\.write_text|\\.write_bytes|writeFileSync"))
    | ($cwd + "\u0000" + $c + "\u0000")'
XF1="$(mktemp "${TMPDIR:-/tmp}/sv-x1.XXXXXX")" && XF2="$(mktemp "${TMPDIR:-/tmp}/sv-x2.XXXXXX")" || { led "-" error; msg "Cannot create a temp file; not verified."; exit 0; }
if ! jq -nj "$FILES_JQ" "$T" >"$XF1" 2>/dev/null || ! jq -nj "$BASH_JQ" "$T" >"$XF2" 2>/dev/null; then
  led "-" error; msg "The subagent's transcript could not be read for edits; not verified."; exit 0
fi
PLIST=(); while IFS= read -r -d '' f; do PLIST+=("$f"); done < "$XF1"
BASHL=(); while IFS= read -r -d '' f; do BASHL+=("$f"); done < "$XF2"

UROOTS=(); UKEYS=(); EF=(); ER=()   # EF/ER: validated edited files and their checkout
add_root() { local u; for u in ${UROOTS[@]+"${UROOTS[@]}"}; do [[ "$u" == "$1" ]] && return; done; UROOTS+=("$1"); UKEYS+=("$2"); }

# 1a. structured edits
GONE=0; CD_LAST=""; CR_LAST=""; CK_LAST=""
for f in ${PLIST[@]+"${PLIST[@]}"}; do
  [[ "$f" == *$'\n'* ]] && continue   # a newline anywhere in the path: never trusted, never listed
  if [[ ! -f "$f" ]]; then GONE=$((GONE + 1)); continue; fi
  if [[ -L "$f" ]]; then continue; fi
  d="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)" || { GONE=$((GONE + 1)); continue; }
  if [[ "$d" != "$CD_LAST" ]]; then CD_LAST="$d"; if resolve_trusted "$d"; then CR_LAST="$R_ROOT"; CK_LAST="$R_KEY"; else CR_LAST=""; fi; fi
  if [[ -n "$CR_LAST" ]]; then
    add_root "$CR_LAST" "$CK_LAST"
    # only a regular file, inside the checkout, with a name a one-per-line list can carry
    pf="$d/${f##*/}"
    if [[ "$pf" == "$CR_LAST"/* && "$pf" != *$'\n'* ]]; then EF+=("$pf"); ER+=("$CR_LAST"); fi
  fi
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
        rest="$cmd"; acc=""
        while [[ "$rest" == *"$form"* ]]; do
          acc="$acc${rest%%"$form"*}"; lc="${acc: -1}"
          rest="${rest#*"$form"}"; acc="$acc$form"
          nx="${rest:0:1}"
          # left boundary: the path starts the word (a quote, space, =, :, ; & | ( ` < > or the start)
          if [[ -n "$lc" && "$lc" != [[:space:]] && "$lc" != [\"\'=:\;\&\|\(\`\<\>] ]]; then continue; fi
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
    if mkdir "$LOCKD" 2>/dev/null; then LOCKHELD=1; return 0; fi
    if [[ -n "$(find "$LOCKD" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then rmdir "$LOCKD" 2>/dev/null; fi
    sleep_s 0.1; n=$((n + 1))
  done
  return 1
}
lock_release() { rmdir "$LOCKD" 2>/dev/null; LOCKHELD=0; }
bf_count() {  # prints the number of blocks recorded; fails if the record exists but cannot be read
  local n=0
  if [[ -e "$BF" ]]; then n="$(wc -l 2>/dev/null < "$BF")" || return 1; n="${n//[[:space:]]/}"; fi
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$n"
}
fingerprint() {  # root -> sets FPRES to a hash; fails (FPRES empty) if any step cannot be listed or hashed
  local r="$1" rc
  FPRES=""; : > "$FPD"; : > "$FPU"; : > "$FPF"
  (
    printf '%s\0' "$r" 'bash -o pipefail' "$VERIFY" "$LIMIT"
    git -C "$r" rev-parse -q --verify HEAD || exit 1                       # no commit yet -> not verified
    git -C "$r" -c core.fsmonitor=false diff --no-ext-diff --no-textconv HEAD >"$FPD" 2>/dev/null || exit 1
    "$HASH" < "$FPD" || exit 1
    git -C "$r" -c core.fsmonitor=false ls-files -z --others --exclude-standard >"$FPU" 2>/dev/null || exit 1
    while IFS= read -r -d '' f; do
      printf '%s\0' "$f"
      if [[ -L "$r/$f" ]]; then
        printf 'link '                                                     # never follow a link: its exact text, bytes as they are
        perl -e 'my $l = readlink($ARGV[0]); defined $l or exit 1; print $l' "$r/$f" || exit 1
        printf '\0'
      elif [[ -f "$r/$f" ]]; then "$HASH" < "$r/$f" || exit 1
      else echo other; fi                                                  # fifo, socket, device
    done < "$FPU"
  ) >"$FPF" 2>/dev/null; rc=$?
  if (( rc == 0 )); then FPRES="$("$HASH" < "$FPF" | cut -c1-40)"; fi
  return $rc
}

# temp files for the fingerprint live in this shell, so the EXIT/TERM cleanup knows them
FPD="$(mktemp "${TMPDIR:-/tmp}/sv-fd.XXXXXX")" && FPU="$(mktemp "${TMPDIR:-/tmp}/sv-fu.XXXXXX")" && FPF="$(mktemp "${TMPDIR:-/tmp}/sv-ff.XXXXXX")" || { led "-" error; msg "Cannot create a temp file; not verified."; exit 0; }
SDIR="$(mktemp -d "${TMPDIR:-/tmp}/sv-d.XXXXXX")" || { SDIR=""; led "-" error; msg "Cannot create a temp folder; not verified."; exit 0; }   # private: the start marker lives here
FAIL_TEXT=""; RC=0; PASS_TEXT=""; k=0
for ROOT in "${UROOTS[@]}"; do
  KEY="${UKEYS[$k]}"; k=$((k + 1))
  NAME="${ROOT##*/}"
  if ! jq -e --arg k "$KEY" '.[$k] | ((has("handback_verify") | not) or (.handback_verify | type) == "string") and ((has("requires") | not) or (.requires | type) == "string") and ((has("handback_limit") | not) or (.handback_limit | type) == "number")' "$CONF" >/dev/null 2>&1; then
    led "$KEY" error; NOTES+="$NAME: handback_verify / requires must be strings and handback_limit a number; not verified. "; continue
  fi
  VERIFY="$(pfield "$KEY" handback_verify)"
  # Opt-in: a project without handback_verify is not checked here, and says nothing.
  if ! jq -e --arg k "$KEY" '.[$k] | has("handback_verify")' "$CONF" >/dev/null 2>&1; then led "$KEY" skip; continue; fi
  REQ="$(pfield "$KEY" requires)"
  LIMIT="$(jq -r --arg k "$KEY" '.[$k].handback_limit // 420 | floor' "$CONF" 2>/dev/null)"
  if [[ -z "$VERIFY" ]]; then led "$KEY" error; NOTES+="$NAME: handback_verify is empty; not verified. "; continue; fi
  if ! { [[ "$LIMIT" =~ ^[0-9]{1,4}$ ]] && LIMIT=$((10#$LIMIT)) && (( LIMIT >= 1 && LIMIT <= 440 )); }; then
    led "$KEY" error; NOTES+="$NAME: handback_limit must be 1-440 seconds; not verified. "; continue
  fi
  if [[ -n "$REQ" && ! -e "$ROOT/$REQ" ]]; then led "$KEY" skip; NOTES+="$NAME: $REQ is missing; not verified. "; continue; fi

  fingerprint "$ROOT"; FP="$FPRES"
  if [[ ${#FP} != 40 ]]; then led "$KEY" error; NOTES+="$NAME: could not list or hash the changes (a repo with no commit, or an unreadable file); not verified. "; continue; fi
  if (( ! PRE )); then
    if grep -qxF "failed $FP" <<< "$SNAPSHOT"; then
      led "$KEY" handback-done; NOTES+="$NAME: the hand-back check failed; not verified. "; continue
    fi
    if grep -qxF "passed $FP" <<< "$SNAPSHOT"; then led "$KEY" handback-done; continue; fi
    if grep -qxF "started $FP" <<< "$SNAPSHOT"; then
      led "$KEY" handback-done; NOTES+="$NAME: the hand-back check did not finish with a verdict; not verified. "; continue
    fi
    if [[ -n "$DELIVERED" ]]; then
      led "$KEY" handback-done; NOTES+="$NAME: the report was delivered without a verified result for this checkout state; not verified. "; continue
    fi
  fi
  if grep -qxF "$FP" "$BF" 2>/dev/null; then
    led "$KEY" repeat; NOTES+="$NAME: this exact state was already blocked once and is not re-run; not verified. "; continue
  fi
  NBLK="$(bf_count)" || { led "$KEY" error; NOTES+="$NAME: the block record cannot be read; not verified. "; continue; }
  if (( NBLK >= MAX_BLOCKS )); then
    led "$KEY" capped; NOTES+="$NAME: this agent was already blocked ${NBLK} times (limit ${MAX_BLOCKS}); not verified. "; continue
  fi

  LOG="$(mktemp "${TMPDIR:-/tmp}/subagent-verify.XXXXXX")" || { LOG=""; led "$KEY" error; NOTES+="Cannot create a temp file; not verified. "; continue; }
  LIST="$(mktemp "${TMPDIR:-/tmp}/subagent-verify-list.XXXXXX")" || { LIST=""; led "$KEY" error; NOTES+="Cannot create a temp file; not verified. "; continue; }
  STARTED="$SDIR/started"; /bin/rm -f "$STARTED"
  # the list holds only files that passed validation, for this checkout
  i=0
  while (( i < ${#EF[@]} )); do
    pf="${EF[$i]}"
    if [[ "${ER[$i]}" == "$ROOT" && -f "$pf" && ! -L "$pf" ]]; then printf '%s\n' "${pf#"$ROOT"/}"; fi
    i=$((i + 1))
  done > "$LIST"
  (( RECORD_HANDBACK )) && printf 'started %s\n' "$FP" >&3
  LEFT=$((BUDGET - (SECONDS - START)))   # recomputed right before the run
  if (( LEFT < 3 )); then led "$KEY" timeout; NOTES+="$NAME: out of time; not verified. "; /bin/rm -f "$LOG" "$LIST"; LOG=""; LIST=""; continue; fi
  (( LIMIT < LEFT )) && LEFT=$LIMIT
  T0=$SECONDS
  # STARTED is created inside the subshell, after cd and after the redirections to $LOG worked. If
  # either failed, the verifier never ran and its status says nothing about the project.
  { ( cd "$ROOT" 2>/dev/null && [[ "$(pwd -P)" == "$ROOT" ]] || exit 1
      : > "$STARTED" || exit 1
      VERIFY_CHANGED_FILE="$LIST" run_limited "$LEFT" bash -o pipefail -c "$VERIFY" ) 3>&- </dev/null >"$LOG" 2>&1; } 2>/dev/null
  TRC=$?
  EL=$((SECONDS - T0))
  if [[ ! -e "$STARTED" ]]; then
    led "$KEY" error; NOTES+="$NAME: the check did not start (cannot enter the checkout or open the log); not verified. "
    /bin/rm -f "$LOG" "$LIST" "$STARTED"; LOG=""; LIST=""; continue
  fi
  if (( TRC == 0 )); then VERDICT=pass
  elif (( TRC == 124 )); then VERDICT=timeout
  elif (( TRC == 126 || TRC == 127 || TRC > 128 )); then VERDICT=error
  else VERDICT=fail; fi
  case "$VERDICT" in
    pass)    led "$KEY" pass; (( RECORD_HANDBACK )) && printf 'passed %s\n' "$FP" >&3; PASS_TEXT+="$NAME: checks passed (${EL} s). " ;;
    timeout) led "$KEY" timeout; NOTES+="$NAME: checks did not finish within ${LEFT} s; not verified. " ;;
    error)   led "$KEY" error; NOTES+="$NAME: the check command could not run or was killed (rc=${TRC}); not a test failure; not verified. " ;;
    fail)
      # record the block under the lock, re-judging inside it (concurrent callbacks)
      DEC=none
      if lock_acquire; then
        NB="$(bf_count)" || NB=""
        if [[ -z "$NB" ]]; then DEC=unreadable
        elif grep -qxF "$FP" "$BF" 2>/dev/null; then DEC=repeat
        elif (( NB >= MAX_BLOCKS )); then DEC=capped
        elif printf '%s\n' "$FP" >> "$BF" 2>/dev/null && grep -qxF "$FP" "$BF" 2>/dev/null; then DEC=block
        else DEC=norecord; fi
        lock_release
      fi
      case "$DEC" in
        block)
          if (( RECORD_HANDBACK )); then
            printf 'failed %s\n' "$FP" >&3
            # Coverage and other output can change the checkout during the failing run.
            # Remember that state only as a failure notice, never as a passing result.
            if fingerprint "$ROOT" && [[ ${#FPRES} == 40 && "$FPRES" != "$FP" ]]; then
              printf 'failed %s\n' "$FPRES" >&3
            fi
          fi
          led "$KEY" fail
          FAIL_TEXT+="$(printf '[%s] the check command failed (exit %d, %d s). Last output:' "$NAME" "$TRC" "$EL")"$'\n'
          FAIL_TEXT+="$(tail -40 "$LOG" | LC_ALL=C cut -c1-300)"$'\n'
          RC=2 ;;
        repeat) led "$KEY" repeat; NOTES+="$NAME: the check failed, but another call already blocked this exact state; not blocking again; not verified. " ;;
        capped) led "$KEY" capped; NOTES+="$NAME: the check failed, but this agent was already blocked ${MAX_BLOCKS} times; not blocking; not verified. " ;;
        unreadable) led "$KEY" error; NOTES+="$NAME: the check failed, but the block count could not be read reliably; not blocking; not verified. " ;;
        *) led "$KEY" error; NOTES+="$NAME: the check failed, but the block record could not be written or locked; not blocking, to avoid a stuck agent; not verified. " ;;
      esac ;;
  esac
  /bin/rm -f "$LOG" "$LIST" "$STARTED"; LOG=""; LIST=""
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
