# projects.sh — sourced by post-edit-check.sh and subagent-verify.sh (not a hook itself).
# Same projects file and same trust model as stop-verify.sh: a checkout counts only if its
# physical path is listed in "roots" of its project (key owner/repo from the origin remote),
# or it is a linked worktree that the listed checkout itself reports. Nothing here reads
# trust from the environment. Needs: $CONF, jq, git.

project_of() {  # repo root -> project key, or empty
  local url name
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 0
  name="${url%/}"; name="${name%.git}"; name="${name%/}"; name="${name##*:}"   # git@host:owner/repo -> owner/repo
  name="$(printf '%s' "$name" | awk -F/ 'NF>=2{print $(NF-1)"/"$NF}')"
  [[ -n "$name" ]] || return 0
  jq -e --arg k "$name" 'has($k)' "$CONF" >/dev/null 2>&1 && printf '%s' "$name"
}
pfield() { jq -r --arg k "$1" --arg f "$2" '.[$k][$f] // empty' "$CONF"; }   # key, field
in_roots() { [[ -n "$2" ]] && jq -e --arg k "$1" --arg r "$2" '(.[$k].roots // []) | map(sub("/+$";"")) | index($r) != null' "$CONF" >/dev/null 2>&1; }   # key, physical path

# resolve_trusted DIR -> 0 and sets R_ROOT (physical repo root) and R_KEY when DIR is inside a
# trusted checkout of a registered project. Otherwise returns 1 and sets R_WHY to
# nogit | unregistered | untrusted.
resolve_trusted() {
  local d="$1" top common main line p
  R_ROOT=""; R_KEY=""; R_WHY=nogit
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 1
  R_ROOT="$(cd "$top" 2>/dev/null && pwd -P)" || return 1
  R_KEY="$(project_of "$R_ROOT")"
  [[ -n "$R_KEY" ]] || { R_WHY=unregistered; return 1; }
  R_WHY=untrusted
  in_roots "$R_KEY" "$R_ROOT" && return 0
  # A worktree counts only if the trusted checkout itself lists it (a crafted .git file is not enough).
  common="$(git -C "$R_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  main="$( [[ -n "$common" ]] && cd "$common/.." 2>/dev/null && pwd -P)"
  if [[ -n "$main" && "$main" != "$R_ROOT" ]] && in_roots "$R_KEY" "$main"; then
    while IFS= read -r line; do
      [[ "$line" == "worktree "* ]] || continue
      p="$(cd "${line#worktree }" 2>/dev/null && pwd -P)" && [[ "$p" == "$R_ROOT" ]] && return 0
    done < <(git -C "$main" worktree list --porcelain 2>/dev/null)
  fi
  return 1
}

re_ok() { [[ -z "$1" ]] && return 0; [[ "" =~ $1 ]]; [[ $? -le 1 ]]; }

run_limited() {  # seconds, command...  -> exit 124 on time limit, kills the whole group
  perl -e '
    my $t = shift; $t = 1 if $t < 1; my $pid = fork();
    if (!$pid) { setpgrp(0,0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "TERM", -$pid; select(undef,undef,undef,0.5); kill "KILL", -$pid; exit 124 };
    alarm $t; waitpid($pid, 0); my $s = $?; exit(($s & 127) ? 128 + ($s & 127) : $s >> 8);
  ' "$@"
}
clean_tabs() { printf '%s' "${1//[$'\t\r\n']/_}"; }
