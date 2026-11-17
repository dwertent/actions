#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026-Present The Zarf Authors
#
# Tests verify.sh against canned GitHub API responses by placing a fake `gh` first on PATH.
# Requires bash and jq. Run: verify-commit-signatures/verify_test.sh

set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The fake gh prints $FAKE_GH_RESPONSE (the `--paginate --slurp` shape: an array of pages)
# and records that it was called, or fails when $FAKE_GH_EXIT is non-zero.
mkdir "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_GH_CALLS"
if [ "${FAKE_GH_EXIT:-0}" -ne 0 ]; then
  echo "fake gh failure" >&2
  exit "$FAKE_GH_EXIT"
fi
cat "$FAKE_GH_RESPONSE"
EOF
chmod +x "$work/bin/gh"

# commit <sha> <subject> <verification-json>
commit() {
  jq -n --arg sha "$1" --arg msg "$2" --argjson verification "$3" \
    '{sha: $sha, commit: ({message: $msg} + (if $verification == null then {} else {verification: $verification} end))}'
}
signed='{"verified": true, "reason": "valid"}'
unsigned='{"verified": false, "reason": "unsigned"}'

good=$(commit aaaaaaa1111111111111111111111111111111aa "feat: signed commit" "$signed")
bad=$(commit bbbbbbb2222222222222222222222222222222bb "fix: unsigned commit" "$unsigned")
bare=$(commit ccccccc3333333333333333333333333333333cc "chore: no verification metadata" null)
percent=$(commit ddddddd4444444444444444444444444444444dd $'docs: 100% done\n\nbody line' "$unsigned")

failures=0
output=""
status=0

# run_verify <response-json> [VAR=value...] runs verify.sh with defaults that the overrides can replace.
run_verify() {
  local response=$1
  shift
  printf '%s' "$response" > "$work/response.json"
  : > "$work/calls"
  : > "$work/summary.md"
  output=$(env \
    PATH="$work/bin:$PATH" \
    FAKE_GH_RESPONSE="$work/response.json" \
    FAKE_GH_CALLS="$work/calls" \
    GH_TOKEN=test-token \
    REPO=zarf-dev/zarf \
    PR_NUMBER=1 \
    COMMIT_COUNT=1 \
    BASE_REF=main \
    MAX_COMMITS=250 \
    RUNNER_TEMP="$work" \
    GITHUB_STEP_SUMMARY="$work/summary.md" \
    "$@" \
    "$script_dir/verify.sh" 2>&1)
  status=$?
}

fail() {
  failures=$((failures + 1))
  echo "FAIL: $test_name: $1"
  echo "$output" | sed 's/^/    /'
}

expect_status() {
  if [ "$1" = "nonzero" ]; then
    [ "$status" -ne 0 ] || fail "expected a non-zero exit, got 0"
  else
    [ "$status" -eq "$1" ] || fail "expected exit $1, got $status"
  fi
}

expect_output() {
  [[ "$output" == *"$1"* ]] || fail "expected output to contain: $1"
}

expect_no_output() {
  [[ "$output" != *"$1"* ]] || fail "expected output not to contain: $1"
}

expect_summary() {
  grep -qF -- "$1" "$work/summary.md" || fail "expected step summary to contain: $1"
}

expect_gh_calls() {
  local calls
  calls=$(wc -l < "$work/calls" | tr -d ' ')
  [ "$calls" -eq "$1" ] || fail "expected $1 gh calls, got $calls"
}

test_name="all commits verified"
run_verify "[[$good, $good]]" COMMIT_COUNT=2
expect_status 0
expect_output "All 2 commits have GitHub-verified signatures."
expect_gh_calls 1

test_name="unsigned commit"
run_verify "[[$good, $bad]]" COMMIT_COUNT=2
expect_status 1
expect_output "::error title=Unverified commit bbbbbbb::fix: unsigned commit (reason: unsigned)"
expect_no_output "aaaaaaa"
expect_summary "1 of 2 commits lack a GitHub-verified signature"
expect_summary "git rebase --exec 'git commit --amend --no-edit -S -s' origin/main"

test_name="missing verification metadata"
run_verify "[[$bare]]"
expect_status 1
expect_output "::error title=Unverified commit ccccccc::chore: no verification metadata (reason: missing)"

test_name="unsigned commit on a later page"
run_verify "[[$good], [$good, $bad]]" COMMIT_COUNT=3
expect_status 1
expect_output "Unverified commit bbbbbbb"
expect_summary "1 of 3 commits lack a GitHub-verified signature"

test_name="only the subject line is reported and percent signs are escaped"
run_verify "[[$percent]]"
expect_status 1
expect_output "::error title=Unverified commit ddddddd::docs: 100%25 done (reason: unsigned)"
expect_no_output "body line"

test_name="base ref is used in the remediation steps"
run_verify "[[$bad]]" BASE_REF=release-1.0
expect_status 1
expect_summary "git fetch origin release-1.0"

test_name="commit count at the limit"
run_verify "[[$good]]" COMMIT_COUNT=5 MAX_COMMITS=5
expect_status 0

test_name="commit count over the limit"
run_verify "[[$good]]" COMMIT_COUNT=6 MAX_COMMITS=5
expect_status 1
expect_output "This PR has 6 commits; at most 5 are allowed."
expect_gh_calls 0

for value in 251 0 abc -1 ""; do
  test_name="invalid max-commits '$value'"
  run_verify "[[$good]]" MAX_COMMITS="$value"
  expect_status 1
  expect_output "max-commits must be a whole number between 1 and 250, got '$value'."
  expect_gh_calls 0
done

test_name="not a pull request event"
run_verify "[[$good]]" PR_NUMBER= COMMIT_COUNT=
expect_status 1
expect_output "must run on a pull request event"
expect_gh_calls 0

test_name="no commits returned"
run_verify "[[]]"
expect_status 1
expect_output "No commits were returned for PR #1"

test_name="GitHub API failure"
run_verify "[[$good]]" FAKE_GH_EXIT=1
expect_status nonzero
expect_no_output "have GitHub-verified signatures"

if [ "$failures" -gt 0 ]; then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "All verify-commit-signatures tests passed"
