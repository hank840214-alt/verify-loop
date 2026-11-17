#!/usr/bin/env bash
# verify-evidence.sh — run a check and print a Markdown evidence block tied to a commit.
#
# "It passed" is not evidence. This prints WHICH command ran, on WHICH commit,
# with what exit code, plus a hash of the full log, so a reviewer can match it
# to the PR head and rerun it.
#
# Usage (from inside the repo):
#   verify-evidence.sh [--tests-re <regex>] [--base <ref>] -- <command> [args...]
# Refuses to run on a dirty tree: evidence must belong to a commit.
# Saves the full log to .scratch/evidence/ and exits with the command's exit code.
set -uo pipefail
die() { echo "verify-evidence: $1" >&2; exit 64; }

tests_re="" base=""
while (($#)); do
  case "$1" in
    --tests-re) tests_re="${2:?}"; shift 2 ;;
    --base) base="${2:?}"; shift 2 ;;
    --) shift; break ;;
    *) die "unknown option $1 (put the command after --)" ;;
  esac
done
(($#)) || die "no command given (put it after --)"

root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
cd "$root" || exit 64
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || die "working tree is not clean; commit first so the evidence belongs to a commit"

sha="$(git rev-parse HEAD)"; branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ -z "$base" ]]; then
  base="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  [[ -n "$base" ]] || { git rev-parse -q --verify origin/main >/dev/null && base=origin/main; }
fi
mkdir -p .scratch/evidence
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log=".scratch/evidence/${sha:0:12}-$stamp.log"
start=$SECONDS
"$@" >"$log" 2>&1; rc=$?
secs=$((SECONDS - start))
if command -v shasum >/dev/null 2>&1; then hash="$(shasum -a 256 "$log" | cut -d' ' -f1)"; else hash="$(sha256sum "$log" | cut -d' ' -f1)"; fi
[[ "$(git rev-parse HEAD)" == "$sha" && -z "$(git status --porcelain --untracked-files=normal)" ]] || note_changed=1

cmd="$(printf '%q ' "$@")"
echo "### Verification evidence"
echo "- Commit: \`$sha\` ($branch)"
echo "- Command: \`${cmd% }\`"
echo "- Exit code: **$rc** ($([[ $rc == 0 ]] && echo pass || echo FAIL))"
echo "- Ran at (UTC): $stamp, ${secs}s"
echo "- Full log: \`$log\` (sha256 \`$hash\`)"
[[ -n "${note_changed:-}" ]] && echo "- WARNING: the tree or HEAD changed while the command ran; this evidence is not valid"
if [[ -n "$tests_re" && -n "$base" ]]; then
  touched="$(git -c core.quotePath=false diff --name-status "$base"...HEAD | awk -F'\t' '$1 ~ /^(M|D|R)/ {print $2}' | grep -E "$tests_re" || true)"
  if [[ -n "$touched" ]]; then
    echo "- Existing tests changed vs \`$base\` (need an independent reviewer):"
    printf '  - `%s`\n' $touched
  else
    echo "- Existing tests changed vs \`$base\`: none"
  fi
fi
echo
echo "<details><summary>Last 30 lines</summary>"
echo
echo '```'
tail -30 "$log"
echo '```'
echo "</details>"
exit "$rc"
