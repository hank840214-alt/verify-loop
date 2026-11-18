#!/bin/bash
# codex-dispatch.sh — run `codex exec` with the work order read from a file.
#
# Why: Claude Code's sandbox keeps a Bash call sandboxed when it has a redirect,
# $(...), cd, subshell or heredoc, so `codex exec ... </dev/null` can never match
# `sandbox.excludedCommands`. Calling this script with plain arguments can.
# Because the script runs outside Claude's sandbox, it accepts an ALLOWLIST only.
#
# Usage:
#   codex-dispatch.sh -f <prompt-file> -s <read-only|workspace-write> -C <dir> [-o <report>]
#                     [-m <model>] [-i <image>]... [--json] [--net] [--skip-git-repo-check]
#                     [-c model_reasoning_effort=<value>]
#
# Enforced:
#   - Every other flag is refused.
#   - Codex runs with --ignore-user-config (no MCP servers, no notify hooks, no
#     full-access default). Model and effort are copied from ~/.codex/config.toml
#     unless -m / -c model_reasoning_effort= is given, so Codex keeps its own choice.
#   - Network is off unless --net (workspace-write only).
#   - -C: needs a git toplevel unless read-only + --skip-git-repo-check; never $HOME or /.
#     workspace-write: -C must be the repo of the current folder, or a repo listed (one
#     path per line) in ~/.config/codex-dispatch/repos; never a repo
#     that contains a protected folder. $HOME comes from the user database.
#   - -C and -o are refused inside this script's repo, ~/.claude and ~/.codex (any mode).
#   - -o: a NEW .md/.txt file, not a symlink, under <-C>/.scratch/ (itself not a symlink)
#     or /tmp. Codex writes into a folder under ~/.local/state; this script then
#     re-checks the target folder and creates -o exclusively inside it. If -o was given
#     and Codex wrote no report, the exit code is non-zero.
#   - Note: read-only Codex can still READ any file your user can read, and the prompt
#     file and -i images are sent to the model service. "Network off" applies to the
#     commands Codex runs, not to the model call itself.
#   - The work order goes in on stdin.
#   - DRY_RUN=1 prints the command instead of running it.
set -euo pipefail

die() { echo "codex-dispatch: $1" >&2; exit "${2:-65}"; }
real() { (cd "$1" 2>/dev/null && pwd -P); }

prompt_file="" mode="" dir="" out="" model="" effort="" net=0 skip=0 json=0
images=()
while (($#)); do
  case "$1" in
    -f) prompt_file="${2:?-f needs a file}"; shift 2 ;;
    -s|--sandbox) mode="${2:?-s needs a value}"; shift 2 ;;
    --sandbox=*) mode="${1#--sandbox=}"; shift ;;
    -C|--cd) dir="${2:?-C needs a dir}"; shift 2 ;;
    -o|--output-last-message) out="${2:?-o needs a file}"; shift 2 ;;
    -m|--model) model="${2:?-m needs a model}"; [[ "$model" != -* ]] || die "-m value cannot start with -"; shift 2 ;;
    -i|--image) [[ -n "${2:-}" && "${2:-}" != -* ]] || die "-i needs a file"; images+=("$1" "$2"); shift 2 ;;
    -c) case "${2:-}" in
          model_reasoning_effort=*) effort="${2#model_reasoning_effort=}"; shift 2 ;;
          *) die "-c ${2:-} is not allowed (only model_reasoning_effort=...)" ;;
        esac ;;
    --json) json=1; shift ;;
    --net) net=1; shift ;;
    --skip-git-repo-check) skip=1; shift ;;
    *) die "$1 is not allowed" ;;
  esac
done

[[ -n "$prompt_file" && -f "$prompt_file" ]] || die "-f <prompt-file> is required and must exist" 64
case "$mode" in
  read-only|workspace-write) ;;
  "") die "-s is required (read-only or workspace-write)" 64 ;;
  *) die "-s must be read-only or workspace-write, not '$mode'" ;;
esac
[[ -n "$dir" ]] || die "-C <dir> is required" 64
rdir="$(real "$dir")" || die "-C $dir does not exist" 64
# Protect both $HOME and the home from the user database, so HOME=/elsewhere cannot
# move the protected folders.
home="$(real "$HOME")"
pwhome="$(perl -e 'print((getpwuid($<))[7])' 2>/dev/null || true)"; pwhome="$(real "${pwhome:-$HOME}" || echo "$home")"
[[ "$rdir" != "/" && "$rdir" != "$home" && "$rdir" != "$pwhome" ]] || die "-C cannot be / or your home folder"
if ((skip)); then
  [[ "$mode" == read-only ]] || die "--skip-git-repo-check is only allowed with read-only"
else
  top="$(git -C "$rdir" rev-parse --show-toplevel 2>/dev/null)" || die "-C must be inside a git repo (or use read-only + --skip-git-repo-check)"
  rtop="$(real "$top")"
  [[ "$(real "$top")" != "$home" && "$(real "$top")" != "$pwhome" ]] || die "-C repo cannot be your home folder"
fi
protected=()
selfrepo="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
selfdir="$(real "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null || true)"
for p in "$selfrepo" "$selfdir" "$home/.claude" "$home/.codex" "$pwhome/.claude" "$pwhome/.codex"; do
  [[ -n "$p" ]] || continue; rp="$(real "$p" 2>/dev/null)" || continue; protected+=("$rp")
done
inside_protected() { local x="$1" p; for p in ${protected[@]+"${protected[@]}"}; do [[ "$x" == "$p" || "$x" == "$p"/* ]] && return 0; done; return 1; }
inside_protected "$rdir" && die "-C cannot be inside this tool's repo, ~/.claude or ~/.codex"
if [[ "$mode" == workspace-write ]]; then
  # Codex may only write the repo you are working in, or one you listed on purpose.
  here="$(git rev-parse --show-toplevel 2>/dev/null || true)"; [[ -n "$here" ]] && here="$(real "$here")"
  allow="$pwhome/.config/codex-dispatch/repos"   # not $HOME or $XDG_*: the caller controls those
  listed=0
  if [[ -f "$allow" ]]; then
    while IFS= read -r line; do [[ -n "$line" && "$(real "$line" 2>/dev/null)" == "$rtop" ]] && listed=1; done < "$allow"
  fi
  [[ "$rtop" == "$here" ]] || ((listed)) || die "workspace-write -C must be the repo of the current folder, or listed in $allow"
  for p in ${protected[@]+"${protected[@]}"}; do [[ "$p" == "$rtop"/* ]] && die "-C repo contains a protected folder ($p)"; done
fi
if ((net)) && [[ "$mode" != workspace-write ]]; then die "--net is only allowed with workspace-write"; fi

if [[ -n "$out" ]]; then
  case "$out" in *.md|*.txt) ;; *) die "-o must end in .md or .txt" ;; esac
  odir="$(dirname "$out")"; [[ "$odir" = /* ]] || odir="$PWD/$odir"
  rodir="$(real "$odir")" || die "-o folder does not exist"
  ok=0
  [[ -L "$rdir/.scratch" ]] && die "<-C>/.scratch is a symlink; refusing"
  for base in "$rdir/.scratch" /tmp /private/tmp; do
    b="$(real "$base" 2>/dev/null)" || continue
    [[ "$rodir" == "$b" || "$rodir" == "$b"/* ]] && ok=1
  done
  ((ok)) || die "-o must be under <-C>/.scratch/ or /tmp"
  if [[ "$rodir" == "$rdir" || "$rodir" == "$rdir"/* ]]; then
    [[ "$rodir" == "$rdir/.scratch" || "$rodir" == "$rdir/.scratch"/* ]] || die "-o inside the -C repo must be under .scratch/"
  fi
  inside_protected "$rodir" && die "-o cannot be inside this tool's repo, ~/.claude or ~/.codex"
  out="$rodir/$(basename "$out")"
  [[ -L "$out" ]] && die "-o target is a symlink"
  [[ -e "$out" ]] && die "-o target already exists; pick a new file name"
fi

cfg="$home/.codex/config.toml"
toml_top() { [[ -f "$cfg" ]] && awk -v k="$1" '/^\[/{exit} $0 ~ "^"k"[ \t]*=" {sub(/^[^=]*=[ \t]*/,""); sub(/[ \t]*#.*$/,""); gsub(/"/,""); print; exit}' "$cfg"; }
[[ -n "$model" ]] || model="$(toml_top model || true)"
[[ -n "$effort" ]] || effort="$(toml_top model_reasoning_effort || true)"

final=(--ignore-user-config "${images[@]+"${images[@]}"}" -s "$mode" -C "$rdir")
[[ -n "$model" ]] && final+=(-m "$model")
[[ -n "$effort" ]] && final+=(-c "model_reasoning_effort=$effort")
if ((net)); then final+=(-c sandbox_workspace_write.network_access=true); else final+=(-c sandbox_workspace_write.network_access=false); fi
((skip)) && final+=(--skip-git-repo-check)
((json)) && final+=(--json)

# Codex writes -o outside its sandbox, so it writes into a fresh folder under
# ~/.local/state (not /tmp or $TMPDIR, which the workspace-write sandbox can write).
# Before delivery this script re-checks the target folder and creates the real file
# exclusively (noclobber), never following a link that appeared in the meantime.
if [[ -n "$out" ]]; then
  sbase="$pwhome/.local/state/codex-dispatch"   # not $HOME or $TMPDIR: the caller controls those
  mkdir -p "$sbase" && chmod 700 "$sbase" || die "cannot create $sbase" 70
  rsbase="$(real "$sbase")" || die "cannot resolve $sbase" 70
  [[ "$rsbase" == "$rdir" || "$rsbase" == "$rdir"/* ]] && die "the staging folder $rsbase is inside the -C repo; set XDG_STATE_HOME elsewhere" 70
  stage="$(mktemp -d "$rsbase/run.XXXXXX")" || die "mktemp failed" 70
  chmod 700 "$stage"; trap 'rm -rf "$stage"' EXIT
  final+=(-o "$stage/last-message.md")
fi

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  printf 'codex exec'; printf ' %q' "${final[@]}"; printf ' - < %q\n' "$prompt_file"
  [[ -n "$out" ]] && printf 'then copy to %q (exclusive create)\n' "$out"
  exit 0
fi
[[ -n "$out" ]] || exec codex exec "${final[@]}" - < "$prompt_file"
rc=0; codex exec "${final[@]}" - < "$prompt_file" || rc=$?
msg="$stage/last-message.md"
if [[ -e "$msg" || -L "$msg" ]]; then
  [[ -L "$msg" || ! -f "$msg" ]] && die "the staged report is not a plain file; report left unsaved" 73
  [[ -L "$rdir/.scratch" ]] && die "<-C>/.scratch became a symlink while Codex ran; report left unsaved" 73
  [[ "$(real "$(dirname "$out")" 2>/dev/null)" == "$rodir" ]] || die "the -o folder moved while Codex ran; report left unsaved" 73
  inside_protected "$rodir" && die "-o folder is now inside a protected folder; report left unsaved" 73
  # Write through the directory we just checked: cd into it, confirm where we are,
  # then create the file relative to that folder, so a swapped path cannot redirect it.
  ( cd -P -- "$rodir" 2>/dev/null && [[ "$(pwd -P)" == "$rodir" ]] && ! inside_protected "$(pwd -P)" \
      && set -C && cat < "$msg" > "./$(basename "$out")" ) || die "could not create $out (folder changed or file exists); report left unsaved" 73
elif [[ -n "$out" ]]; then
  echo "codex-dispatch: Codex wrote no report" >&2; ((rc)) || rc=74
fi
exit "$rc"
