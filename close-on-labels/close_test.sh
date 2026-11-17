#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026-Present The Zarf Authors
#
# Tests close.sh against canned GitHub API responses by placing a fake `gh` first on PATH.
# Requires bash, jq and yq (mikefarah v4). Run: close-on-labels/close_test.sh

# Expected messages contain literal backticks, so single quotes are intended.
# shellcheck disable=SC2016

set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The fake gh records every call. `gh api repos/<repo>/issues/<n>` prints $FAKE_GH_ITEM, a contents request prints
# $FAKE_GH_CONTENT (or fails with 404 when it is unset), and any call whose arguments contain $FAKE_GH_FAIL_ON fails.
mkdir "$work/bin" "$work/ws"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_CALLS"
if [ -n "${FAKE_GH_FAIL_ON:-}" ] && [[ "$*" == *"$FAKE_GH_FAIL_ON"* ]]; then
  echo "HTTP 500: fake failure" >&2
  exit 1
fi
case "$*" in
  *"/contents/"*)
    if [ -n "${FAKE_GH_CONTENT:-}" ]; then cat "$FAKE_GH_CONTENT"; else echo "Not Found (HTTP 404)" >&2; exit 1; fi ;;
  "api repos/zarf-dev/zarf/issues/"+([0-9]))
    cat "$FAKE_GH_ITEM" ;;
esac
EOF
# The +([0-9]) pattern needs extglob in the fake.
sed -i.bak '2i\
shopt -s extglob' "$work/bin/gh" && rm "$work/bin/gh.bak"
chmod +x "$work/bin/gh"

# item <state> <issue|pr> [label...] writes the item the fake gh returns.
item() {
  local state=$1 kind=$2
  shift 2
  jq -n --arg state "$state" --arg kind "$kind" '{
    state: $state,
    labels: [$ARGS.positional[] | {name: .}]
  } + (if $kind == "pr" then {pull_request: {url: "x"}} else {} end)' --args "$@" > "$work/item.json"
}

# rules <yaml> writes the rules file into the fake workspace.
rules() {
  printf '%s\n' "$1" > "$work/ws/rules.yaml"
}

failures=0
passed=0
failed=0
test_name=""
test_failures=0

# report prints one line for the test that just finished.
report() {
  [ -n "$test_name" ] || return 0
  if [ "$test_failures" -eq 0 ]; then
    echo "[PASS] $test_name"
    passed=$((passed + 1))
  else
    echo "[FAIL] $test_name"
    failed=$((failed + 1))
  fi
}

# begin <name> finishes the previous test and starts a new one.
begin() {
  report
  test_name=$1
  test_failures=0
}
output=""
status=0

# run_close [VAR=value...] runs close.sh with defaults that the overrides can replace.
run_close() {
  : > "$work/calls"
  : > "$work/out"
  output=$(env \
    PATH="$work/bin:$PATH" \
    FAKE_GH_ITEM="$work/item.json" \
    FAKE_GH_CALLS="$work/calls" \
    GH_TOKEN=test-token \
    REPO=zarf-dev/zarf \
    SHA=0123456789abcdef \
    WORKSPACE="$work/ws" \
    EVENT_NAME=issues \
    EVENT_NUMBER=7 \
    GITHUB_OUTPUT="$work/out" \
    INPUT_OR= \
    INPUT_AND= \
    INPUT_NOT= \
    INPUT_RULES_FILE= \
    INPUT_TARGET=all \
    INPUT_COMMENT= \
    INPUT_CLOSE_REASON=not_planned \
    INPUT_LOCK=false \
    INPUT_DRY_RUN=false \
    INPUT_NUMBER= \
    "$@" \
    "$script_dir/close.sh" 2>&1)
  status=$?
}

fail() {
  failures=$((failures + 1))
  test_failures=$((test_failures + 1))
  echo "FAIL: $test_name: $1"
  printf '    %s\n' "${output//$'\n'/$'\n    '}"
}

expect_status() {
  [ "$status" -eq "$1" ] || fail "expected exit $1, got $status"
}

expect_output() {
  [[ "$output" == *"$1"* ]] || fail "expected output to contain: $1"
}

expect_no_output() {
  [[ "$output" != *"$1"* ]] || fail "expected output not to contain: $1"
}

# output_value <name> reads a value written in the GITHUB_OUTPUT heredoc format.
output_value() {
  awk -v name="$1" '
    $0 ~ "^" name "<<" { delim = substr($0, length(name) + 3); reading = 1; next }
    reading && $0 == delim { exit }
    reading { print }
  ' "$work/out"
}

expect_out() {
  local actual
  actual=$(output_value "$1")
  [ "$actual" = "$2" ] || fail "expected output $1 to be '$2', got '$actual'"
}

# expect_result <result> <closed> <matched-rule> <matched-labels>
expect_result() {
  expect_out result "$1"
  expect_out closed "$2"
  expect_out matched-rule "$3"
  expect_out matched-labels "$4"
  expect_out number "${5:-7}"
}

expect_call() {
  grep -qF -- "$1" "$work/calls" || fail "expected a gh call containing: $1"
}

expect_no_call() {
  ! grep -qF -- "$1" "$work/calls" || fail "expected no gh call containing: $1"
}

# Write calls are the ones that change state: comment, close, lock.
write_calls() {
  grep -cE -- '/comments|-X PATCH|-X PUT' "$work/calls" || true
}

expect_no_writes() {
  [ "$(write_calls)" -eq 0 ] \
    || fail "expected no write calls, got: $(grep -E -- '/comments|-X PATCH|-X PUT' "$work/calls")"
}

expect_gh_calls() {
  local calls
  calls=$(wc -l < "$work/calls" | tr -d ' ')
  [ "$calls" -eq "$1" ] || fail "expected $1 gh calls, got $calls"
}

# --- inline rules -----------------------------------------------------------------------------------------------

begin "or: one label present closes the issue"
item open issue bug wontfix
run_close INPUT_OR="wontfix, invalid"
expect_status 0
expect_result closed true inline wontfix
expect_call "-X PATCH repos/zarf-dev/zarf/issues/7 -f state=closed -f state_reason=not_planned"
expect_no_call "/comments"
expect_no_call "/lock"

begin "or: no label present leaves the issue open"
item open issue bug
run_close INPUT_OR="wontfix, invalid"
expect_status 0
expect_result none false "" ""
expect_no_writes
expect_output 'does not apply, none of "wontfix", "invalid" is present.'
expect_output "No rule applies. Issue #7 stays open."

begin "and: one label missing leaves the issue open"
item open issue duplicate
run_close INPUT_AND=$'duplicate\nhas-replacement'
expect_status 0
expect_result none false "" ""
expect_no_writes
expect_output 'missing "has-replacement"'

begin "and: all labels present closes the issue"
item open issue has-replacement duplicate
run_close INPUT_AND=$'duplicate\nhas-replacement' INPUT_CLOSE_REASON=Completed
expect_status 0
expect_result closed true inline has-replacement,duplicate
expect_call "state_reason=completed"

begin "or + and: both must hold"
item open issue a c
run_close INPUT_OR="a, b" INPUT_AND="c, d"
expect_result none false "" ""
item open issue b c d
run_close INPUT_OR="a, b" INPUT_AND="c, d"
expect_result closed true inline b,c,d

begin "not inside a close rule blocks that rule"
item open issue wontfix keep-open
run_close INPUT_OR=wontfix INPUT_NOT=keep-open
expect_status 0
expect_result none false "" ""
expect_no_writes
expect_output 'does not apply, has "keep-open".'

begin "not inside a close rule does not block when absent"
item open issue wontfix
run_close INPUT_OR=wontfix INPUT_NOT=keep-open
expect_result closed true inline wontfix

begin "labels match case-insensitively and keep the item's casing"
item open issue "WontFix"
run_close INPUT_OR="wontfix"
expect_result closed true inline WontFix

begin "labels with spaces and punctuation"
item open issue "good first issue" "kind/bug" "priority: high" "a (b)"
run_close INPUT_AND="good first issue, kind/bug, priority: high, a (b)"
expect_result closed true inline "good first issue,kind/bug,priority: high,a (b)"

# --- order ------------------------------------------------------------------------------------------------------

rules '
rules: # checked in order, the first rule that applies decides
  - name: keep
    not: [keep-open]
  - name: close if one
    or: [wontfix, invalid, duplicate]
  - name: close if all
    and: [duplicate, has-replacement]'

begin "order: wontfix is closed by the first close rule"
item open issue wontfix
run_close INPUT_RULES_FILE=rules.yaml
expect_status 0
expect_result closed true "close if one" wontfix
expect_output 'Rule "keep": does not apply, none of "keep-open" is present.'
expect_output 'Rule "close if one": applies ("wontfix").'
expect_output "The 1 rule(s) after it were not checked."
expect_no_output 'Rule "close if all"'

begin "order: keep rule first keeps the item open and stops"
item open issue wontfix keep-open
run_close INPUT_RULES_FILE=rules.yaml
expect_status 0
expect_result kept false keep keep-open
expect_no_writes
expect_output 'Rule "keep": applies (has "keep-open"), keeping the item open.'
expect_output "The 2 rule(s) after it were not checked."
expect_no_output 'Rule "close if one"'

begin "order: the earlier of two matching close rules wins"
item open issue duplicate has-replacement
run_close INPUT_RULES_FILE=rules.yaml
expect_result closed true "close if one" duplicate

begin "order: nothing applies"
item open issue has-replacement
run_close INPUT_RULES_FILE=rules.yaml
expect_result none false "" ""
expect_no_writes
expect_output 'Rule "close if all": does not apply, missing "duplicate".'

begin "order: the same rules with keep last close the item and warn"
rules '
rules:
  - name: close if one
    or: [wontfix, invalid, duplicate]
  - name: close if all
    and: [duplicate, has-replacement]
  - name: keep
    not: [keep-open]'
item open issue wontfix keep-open
run_close INPUT_RULES_FILE=rules.yaml
expect_status 0
expect_result closed true "close if one" wontfix
expect_output '::warning title=close-on-labels::Rule "keep" only has `not` and comes after every rule that can close'

begin "order: inline rule is checked before file rules"
rules '
rules:
  - name: from-file
    or: [wontfix]'
item open issue wontfix
run_close INPUT_RULES_FILE=rules.yaml INPUT_OR=wontfix
expect_result closed true inline wontfix

begin "order: an inline keep rule protects from file rules"
item open issue wontfix keep-open
run_close INPUT_RULES_FILE=rules.yaml INPUT_NOT=keep-open
expect_result kept false inline keep-open
expect_no_writes

# --- target -----------------------------------------------------------------------------------------------------

begin "target: a close rule for prs skips an issue"
item open issue wontfix
run_close INPUT_OR=wontfix INPUT_TARGET=prs
expect_result none false "" ""
expect_output 'Rule "inline": skipped, it only applies to pull requests.'

begin "target: a close rule for issues skips a pull request"
item open pr wontfix
run_close INPUT_OR=wontfix INPUT_TARGET=issues
expect_result none false "" ""

begin "target: a keep rule for prs does not protect an issue"
rules '
rules:
  - name: keep prs
    not: [keep-open]
    target: prs
  - name: close
    or: [wontfix]'
item open issue wontfix keep-open
run_close INPUT_RULES_FILE=rules.yaml
expect_result closed true close wontfix

begin "target: the same keep rule protects a pull request"
item open pr wontfix keep-open
run_close INPUT_RULES_FILE=rules.yaml
expect_result kept false "keep prs" keep-open

# --- pull requests, comment, lock -------------------------------------------------------------------------------

begin "pull request is closed without a state reason"
item open pr wontfix
run_close INPUT_OR=wontfix
expect_result closed true inline wontfix
expect_call "-X PATCH repos/zarf-dev/zarf/issues/7 -f state=closed"
expect_no_call "state_reason"
expect_output "Closed pull request #7."

begin "comment, close and lock happen in that order"
item open issue invalid wontfix
run_close INPUT_OR="wontfix, invalid" INPUT_LOCK=TRUE \
  INPUT_COMMENT='Closed by {{rule}}: {{matched}}. ({{rule}})'
expect_status 0
expect_result closed true inline invalid,wontfix
order=$(grep -oE '/comments|-X PATCH|-X PUT' "$work/calls" | tr '\n' ' ')
[ "$order" = "/comments -X PATCH -X PUT " ] || fail "expected comment, close, lock; got: $order"
expect_call 'body=Closed by inline: `invalid`, `wontfix`. (inline)'
expect_call "-X PUT repos/zarf-dev/zarf/issues/7/lock"

begin "placeholders are replaced once, not inside label or rule names"
rules '
rules:
  - name: "{{matched}}"
    or: ["{{rule}}"]
    comment: "{{rule}} / {{matched}}"'
item open issue "{{rule}}"
run_close INPUT_RULES_FILE=rules.yaml
expect_call 'body={{matched}} / `{{rule}}`'

begin "file rules take input defaults and can override them"
rules '
rules:
  - name: defaults
    or: [a]
  - name: overrides
    or: [b]
    reason: completed
    comment: ""
    lock: false'
item open issue a
run_close INPUT_RULES_FILE=rules.yaml INPUT_COMMENT="default {{rule}}" INPUT_LOCK=true
expect_call "body=default defaults"
expect_call "state_reason=not_planned"
expect_call "/lock"
item open issue b
run_close INPUT_RULES_FILE=rules.yaml INPUT_COMMENT="default {{rule}}" INPUT_LOCK=true
expect_result closed true overrides b
expect_no_call "/comments"
expect_no_call "/lock"
expect_call "state_reason=completed"

begin "rule lists may be comma separated strings"
rules '
rules:
  - name: csv
    or: "wontfix, invalid"
    not: keep-open'
item open issue invalid
run_close INPUT_RULES_FILE=rules.yaml
expect_result closed true csv invalid

# --- dry run, closed items, numbers -----------------------------------------------------------------------------

begin "dry-run reports the match without changing anything"
item open issue wontfix
run_close INPUT_OR=wontfix INPUT_DRY_RUN=true INPUT_COMMENT=bye INPUT_LOCK=true
expect_status 0
expect_result would-close false inline wontfix
expect_no_writes
expect_output "Dry run: Issue #7 would be closed. Nothing was changed."

begin "dry-run with a keep rule reports kept"
item open issue keep-open wontfix
run_close INPUT_NOT=keep-open INPUT_RULES_FILE=rules.yaml INPUT_DRY_RUN=true
expect_result kept false inline keep-open

begin "an item that is already closed is skipped"
item closed issue wontfix
run_close INPUT_OR=wontfix
expect_status 0
expect_result none false "" ""
expect_no_writes
expect_output "Issue #7 is closed. Nothing to do."

begin "number input overrides the event"
item open issue wontfix
run_close INPUT_OR=wontfix INPUT_NUMBER=" 42 "
expect_result closed true inline wontfix 42
expect_call "api repos/zarf-dev/zarf/issues/42"

# --- rules file location ----------------------------------------------------------------------------------------

begin "rules file is read from the workspace with a ./ prefix"
rules '
rules:
  - or: [wontfix]'
item open issue wontfix
run_close INPUT_RULES_FILE=./rules.yaml
expect_result closed true rule-1 wontfix
expect_no_call "/contents/"

begin "rules file missing from the workspace is fetched from the repository"
printf 'rules:\n  - name: remote\n    or: [wontfix]\n' > "$work/remote.yaml"
item open issue wontfix
run_close INPUT_RULES_FILE=.github/close-rules.yaml FAKE_GH_CONTENT="$work/remote.yaml"
expect_status 0
expect_result closed true remote wontfix
expect_call "repos/zarf-dev/zarf/contents/.github/close-rules.yaml?ref=0123456789abcdef"

begin "rules file missing everywhere fails"
run_close INPUT_RULES_FILE=.github/missing.yaml
expect_status 1
expect_output "Could not read rules-file '.github/missing.yaml'. It is not in the workspace"
expect_output "Not Found (HTTP 404)"
expect_no_writes

# --- validation (no item is read and nothing changes) -----------------------------------------------------------

# invalid_rules <name> <yaml> <expected error>
invalid_rules() {
  begin "invalid rules: $1"
  rules "$2"
  item open issue wontfix
  run_close INPUT_RULES_FILE=rules.yaml
  expect_status 1
  expect_output "$3"
  expect_output "The rules are invalid. Fix the errors above."
  expect_gh_calls 0
}

invalid_rules "missing rules list" 'other: 1' 'rules.yaml: expected a non-empty `rules` list.'
invalid_rules "empty rules list" 'rules: []' 'rules.yaml: expected a non-empty `rules` list.'
invalid_rules "empty file" '' 'rules.yaml: expected a non-empty `rules` list.'
invalid_rules "rule is not a mapping" $'rules:\n  - wontfix' 'rules.yaml: rules[0] must be a mapping'
invalid_rules "unknown key" $'rules:\n  - or: [a]\n    labels: [b]' \
  'rules.yaml: rules[0] (rule-1) has unknown key(s): labels.'
invalid_rules "no or, and or not" $'rules:\n  - name: x' 'rules.yaml: rules[0] (x) needs `or`, `and` or `not`.'
invalid_rules "empty list" $'rules:\n  - or: []' 'rules.yaml: rules[0] (rule-1): `or` is empty.'
invalid_rules "list of mappings" $'rules:\n  - or: [{a: 1}]' \
  'rules.yaml: rules[0] (rule-1): `or` must be a list of labels.'
invalid_rules "empty name" $'rules:\n  - name: " "\n    or: [a]' 'rules.yaml: rules[0] (): `name` is empty.'
invalid_rules "name is a list" $'rules:\n  - name: [a]\n    or: [a]' \
  'rules.yaml: rules[0] (?): `name` must be a string.'
invalid_rules "duplicate names" $'rules:\n  - {name: x, or: [a]}\n  - {name: x, or: [b]}' \
  'Duplicate rule name "x".'
invalid_rules "bad target" $'rules:\n  - or: [a]\n    target: both' \
  'rules.yaml: rules[0] (rule-1): `target` must be one of issues, prs, all (got "both").'
invalid_rules "bad reason" $'rules:\n  - or: [a]\n    reason: spam' \
  'rules.yaml: rules[0] (rule-1): `reason` must be one of completed, not_planned (got "spam").'
invalid_rules "comment not a string" $'rules:\n  - or: [a]\n    comment: [x]' \
  'rules.yaml: rules[0] (rule-1): `comment` must be a string.'
invalid_rules "lock not a boolean" $'rules:\n  - or: [a]\n    lock: "yes"' \
  'rules.yaml: rules[0] (rule-1): `lock` must be true or false (got "yes").'
invalid_rules "comment on a keep rule" $'rules:\n  - not: [a]\n    comment: x\n  - or: [b]' \
  'rules.yaml: rules[0] (rule-1): `comment` only applies to rules with `or` or `and`.'
invalid_rules "only keep rules" $'rules:\n  - not: [keep-open]' 'No rule can close anything.'

begin "invalid rules: invalid YAML"
rules 'rules: ['
run_close INPUT_RULES_FILE=rules.yaml
expect_status 1
expect_output "rules.yaml: invalid YAML:"
expect_output "line 2"
expect_no_output "$work"
expect_gh_calls 0

begin "invalid inputs: only not, and no rules file"
item open issue wontfix
run_close INPUT_NOT=keep-open
expect_status 1
expect_output "No rule can close anything."
expect_gh_calls 0

begin "invalid inputs: no rules at all"
run_close
expect_status 1
expect_output "No rules. Set or, and, not, or rules-file."
expect_gh_calls 0

# invalid_input <VAR=value> <expected error>
invalid_input() {
  begin "invalid input: $1"
  item open issue wontfix
  run_close INPUT_OR=wontfix "$1"
  expect_status 1
  expect_output "$2"
  expect_gh_calls 0
}

invalid_input INPUT_TARGET=both "target must be one of: issues prs all. Got 'both'."
invalid_input INPUT_CLOSE_REASON=spam "close-reason must be one of: completed not_planned. Got 'spam'."
invalid_input INPUT_LOCK=yes "lock must be one of: true false. Got 'yes'."
invalid_input INPUT_DRY_RUN=1 "dry-run must be one of: true false. Got '1'."
invalid_input INPUT_NUMBER=abc "number must be a positive whole number. Got 'abc'."
invalid_input INPUT_NUMBER=0 "number must be a positive whole number. Got '0'."

begin "no number in the event and no number input"
run_close INPUT_OR=wontfix EVENT_NUMBER= EVENT_NAME=schedule
expect_status 1
expect_output "The 'schedule' event has no issue or pull request. Set the number input."
expect_gh_calls 0

# --- API failures -----------------------------------------------------------------------------------------------

begin "failure reading the item"
item open issue wontfix
run_close INPUT_OR=wontfix FAKE_GH_FAIL_ON="issues/7"
expect_status 1
expect_output "Could not read #7 in zarf-dev/zarf: HTTP 500: fake failure"
expect_no_writes

begin "failure posting the comment does not close"
run_close INPUT_OR=wontfix INPUT_COMMENT=bye FAKE_GH_FAIL_ON="/comments"
expect_status 1
expect_output "Could not comment on #7, so it was not closed"
expect_no_call "-X PATCH"

begin "failure closing after the comment says the item is still open"
run_close INPUT_OR=wontfix INPUT_COMMENT=bye FAKE_GH_FAIL_ON="-X PATCH"
expect_status 1
expect_output "Posted the comment but could not close #7, so it is still open"

begin "failure locking"
run_close INPUT_OR=wontfix INPUT_LOCK=true FAKE_GH_FAIL_ON="-X PUT"
expect_status 1
expect_output "Closed #7 but could not lock it"

# --- escaping ---------------------------------------------------------------------------------------------------

begin "workflow command values are escaped"
rules '
rules:
  - or: [a]
  - name: "100% kept"
    not: [b]'
item open issue x
run_close INPUT_RULES_FILE=rules.yaml
expect_output 'Rule "100%25 kept" only has `not`'

# --- this repository's own rules ---------------------------------------------------------------------------------

repo_rules="$script_dir/../.github/close-rules.yaml"
mkdir -p "$work/ws/.github"
cp "$repo_rules" "$work/ws/.github/close-rules.yaml"

begin "repository rules: wontfix closes with a comment"
item open issue wontfix
run_close INPUT_RULES_FILE=.github/close-rules.yaml
expect_status 0
expect_result closed true rejected wontfix
expect_call 'body=Closing because this was labeled `wontfix`.'
expect_no_output "::warning"

begin "repository rules: keep-open keeps the item open"
item open pr duplicate keep-open
run_close INPUT_RULES_FILE=.github/close-rules.yaml
expect_result kept false keep keep-open
expect_no_writes

begin "repository rules: other labels are left alone"
item open issue bug enhancement
run_close INPUT_RULES_FILE=.github/close-rules.yaml
expect_result none false "" ""
expect_no_writes

# --- action.yaml ------------------------------------------------------------------------------------------------

begin "action.yaml passed all checks"
output=""
manifest="$script_dir/action.yaml"
for input in $(yq '.inputs | keys | .[]' "$manifest"); do
  [ "$input" = token ] && continue
  var="INPUT_$(tr 'a-z-' 'A-Z_' <<< "$input")"
  [ "$(yq ".runs.steps[0].env.$var" "$manifest")" = "\${{ inputs.$input }}" ] \
    || fail "input $input is not passed as $var"
  grep -q "\$$var\|{$var" "$script_dir/close.sh" || fail "close.sh does not read $var"
done
for out in $(yq '.outputs | keys | .[]' "$manifest"); do
  [ "$(yq ".outputs.\"$out\".value" "$manifest")" = "\${{ steps.close.outputs.$out }}" ] \
    || fail "output $out is not mapped to steps.close.outputs.$out"
  grep -q "set_output $out " "$script_dir/close.sh" || fail "close.sh never sets output $out"
done

report
echo
if [ "$failures" -gt 0 ]; then
  echo "$passed passed, $failed failed ($failures assertion(s))"
  exit 1
fi
echo "All $passed close-on-labels tests passed"
