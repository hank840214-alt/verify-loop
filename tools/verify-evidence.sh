#!/usr/bin/env bash
# verify-evidence.sh — run a check and print a Markdown evidence block tied to a commit.
#
# "It passed" is not evidence. This prints WHICH command ran, on WHICH commit,
# with what exit code, plus a hash of the full log, so a reviewer can match it
# to the PR head and rerun it. Local evidence helps a reviewer; it is not a gate.
# The real gate is CI rerunning the checks on that SHA in a clean checkout.
#
# Usage (from inside the repo):
#   verify-evidence.sh [--tests-re <regex>] [--base <ref>] [--log-dir <dir>] -- <command> [args...]
# Exit: the command's exit code; 3 if the evidence is invalid (tree or HEAD changed
# during the run); 64 for usage errors or a dirty tree.
set -uo pipefail
die() { echo "verify-evidence: $1" >&2; exit "${2:-64}"; }
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
dirty() { [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; }

tests_re="" base="" logdir="${XDG_STATE_HOME:-$HOME/.local/state}/verify-evidence"
while (($#)); do
  case "$1" in
    --tests-re) tests_re="${2:?}"; shift 2 ;;
    --base) base="${2:?}"; shift 2 ;;
    --log-dir) logdir="${2:?}"; shift 2 ;;
    --) shift; break ;;
    *) die "unknown option $1 (put the command after --)" ;;
  esac
done
(($#)) || die "no command given (put it after --)"
if [[ -n "$tests_re" ]]; then printf '' | grep -E "$tests_re" >/dev/null 2>&1; [[ $? -le 1 ]] || die "--tests-re is not a valid regex"; fi

root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
cd "$root" || exit 64
status="$(git status --porcelain --untracked-files=normal)" || die "git status failed"
[[ -z "$status" ]] || die "working tree is not clean; commit first so the evidence belongs to a commit"
sha="$(git rev-parse --verify HEAD)" || die "no HEAD commit"
branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ -z "$base" ]]; then
  base="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  [[ -n "$base" ]] || { git rev-parse -q --verify origin/main >/dev/null && base=origin/main; }
fi

# The log lives outside the work tree so writing it never dirties the tree.
mkdir -p "$logdir" || die "cannot create $logdir"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log="$(mktemp "$logdir/${sha:0:12}-$stamp.XXXXXX")" || die "mktemp failed"
start=$SECONDS
"$@" >"$log" 2>&1; rc=$?
secs=$((SECONDS - start))
hash="$(sha256 "$log")"; [[ ${#hash} == 64 ]] || die "could not hash the log" 3
valid=1
[[ "$(git rev-parse --verify HEAD 2>/dev/null)" == "$sha" ]] || valid=0
dirty && valid=0

cmd="$(printf '%q ' "$@")"
echo "### Verification evidence"
echo "- Commit: \`$sha\` ($branch)"
echo "- Command: \`${cmd% }\`"
echo "- Exit code: **$rc** ($([[ $rc == 0 ]] && echo pass || echo FAIL))"
echo "- Ran at (UTC): $stamp, ${secs}s"
echo "- Full log: \`$log\` (sha256 \`$hash\`)"
((valid)) || echo "- **INVALID**: the tree or HEAD changed while the command ran. Do not use this evidence."
if [[ -n "$tests_re" ]]; then
  if [[ -z "$base" ]] || ! mb="$(git merge-base "$base" HEAD 2>/dev/null)"; then
    echo "- Existing tests changed: **UNKNOWN** (no valid base; pass --base)"
  elif ! ns="$(git -c core.quotePath=false diff --name-status "$mb" HEAD)"; then
    echo "- Existing tests changed: **UNKNOWN** (diff failed)"
  else
    touched="$(printf '%s\n' "$ns" | awk -F'\t' '$1 ~ /^(M|D|R|T)/ {print $2}' | grep -E "$tests_re" || true)"
    if [[ -n "$touched" ]]; then
      echo "- Existing tests changed vs \`$base\` (need an independent reviewer):"
      printf '%s\n' "$touched" | sed 's/^/  - `/; s/$/`/'
    else
      echo "- Existing tests changed vs \`$base\`: none"
    fi
    echo "  (A test added and later weakened inside this PR shows as added. Compare against the independent test commit with --base <that commit>.)"
  fi
fi
echo
echo "<details><summary>Last 30 lines</summary>"
echo
echo '```'
tail -30 "$log"
echo '```'
echo "</details>"
((valid)) || exit 3
exit "$rc"
