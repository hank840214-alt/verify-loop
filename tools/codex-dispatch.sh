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
#   - -C and -o are refused inside this script's repo, ~/.claude and ~/.codex (any mode).
#   - -o: a NEW .md/.txt file, not a symlink, under <-C>/.scratch/ (itself not a symlink)
#     or /tmp. Codex writes into a private temp folder; this script then creates -o
#     exclusively, so a file swapped in meanwhile is never overwritten.
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
home="$(real "$HOME")"
[[ "$rdir" != "/" && "$rdir" != "$home" ]] || die "-C cannot be / or your home folder"
if ((skip)); then
  [[ "$mode" == read-only ]] || die "--skip-git-repo-check is only allowed with read-only"
else
  top="$(git -C "$rdir" rev-parse --show-toplevel 2>/dev/null)" || die "-C must be inside a git repo (or use read-only + --skip-git-repo-check)"
  [[ "$(real "$top")" != "$home" ]] || die "-C repo cannot be your home folder"
fi
protected=()
selfrepo="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
for p in "$selfrepo" "$home/.claude" "$home/.codex"; do
  [[ -n "$p" ]] || continue; rp="$(real "$p" 2>/dev/null)" || continue; protected+=("$rp")
done
inside_protected() { local x="$1" p; for p in ${protected[@]+"${protected[@]}"}; do [[ "$x" == "$p" || "$x" == "$p"/* ]] && return 0; done; return 1; }
inside_protected "$rdir" && die "-C cannot be inside this tool's repo, ~/.claude or ~/.codex"
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

# Codex writes -o outside its sandbox, so it writes into a fresh private folder;
# this script then creates the real file exclusively (noclobber), never following
# a file that appeared in the meantime.
if [[ -n "$out" ]]; then
  stage="$(mktemp -d "${TMPDIR:-/tmp}/codex-dispatch.XXXXXX")" || die "mktemp failed" 70
  chmod 700 "$stage"; trap 'rm -rf "$stage"' EXIT
  final+=(-o "$stage/last-message.md")
fi

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  printf 'codex exec'; printf ' %q' "${final[@]}"; printf ' - < %q\n' "$prompt_file"
  [[ -n "$out" ]] && printf 'then copy to %q (exclusive create)\n' "$out"
  exit 0
fi
[[ -n "$out" ]] || exec codex exec "${final[@]}" - < "$prompt_file"
codex exec "${final[@]}" - < "$prompt_file"; rc=$?
if [[ -f "$stage/last-message.md" ]]; then
  [[ -L "$out" || -e "$out" ]] && die "-o target appeared while Codex ran; report left unsaved" 73
  ( set -C; cat "$stage/last-message.md" > "$out" ) || die "could not create $out" 73
fi
exit "$rc"
