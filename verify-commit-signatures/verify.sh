#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026-Present The Zarf Authors
#
# Fails when a pull request contains commits without a GitHub-verified signature.
#
# Required environment: GH_TOKEN, REPO, PR_NUMBER, COMMIT_COUNT, BASE_REF, MAX_COMMITS,
# RUNNER_TEMP, GITHUB_STEP_SUMMARY.

set -euo pipefail

if [ -z "${PR_NUMBER:-}" ]; then
  echo "::error::verify-commit-signatures must run on a pull request event."
  exit 1
fi

# The PR commits API returns at most 250 commits, so a higher limit could pass commits that were never inspected.
api_limit=250
if ! [[ "$MAX_COMMITS" =~ ^[1-9][0-9]*$ ]] || [ "$MAX_COMMITS" -gt "$api_limit" ]; then
  echo "::error::max-commits must be a whole number between 1 and $api_limit, got '$MAX_COMMITS'."
  exit 1
fi

if [ "$COMMIT_COUNT" -gt "$MAX_COMMITS" ]; then
  echo "::error::This PR has $COMMIT_COUNT commits; at most $MAX_COMMITS are allowed. Squash or split the PR."
  exit 1
fi

commits="$RUNNER_TEMP/pr-commits.json"
gh api --paginate --slurp "repos/$REPO/pulls/$PR_NUMBER/commits?per_page=100" | jq 'add // []' > "$commits"

total=$(jq 'length' "$commits")
if [ "$total" -eq 0 ]; then
  echo "::error::No commits were returned for PR #$PR_NUMBER; cannot verify signatures."
  exit 1
fi

# Missing verification metadata counts as unverified.
unverified=$(jq -r '
  .[]
  | select(.commit.verification.verified != true)
  | [.sha[0:7], (.commit.verification.reason // "missing"), (.commit.message | split("\n")[0])]
  | @tsv' "$commits")

if [ -z "$unverified" ]; then
  echo "All $total commits have GitHub-verified signatures."
  exit 0
fi

count=$(printf '%s\n' "$unverified" | wc -l | tr -d ' ')

while IFS=$'\t' read -r sha reason subject; do
  echo "::error title=Unverified commit $sha::${subject//%/%25} (reason: $reason)"
done <<< "$unverified"

{
  echo "## $count of $total commits lack a GitHub-verified signature"
  echo
  echo '```'
  printf 'SHA\tREASON\tSUBJECT\n'
  printf '%s\n' "$unverified"
  echo '```'
  echo
  echo "### How to fix"
  echo
  echo "1. Set up commit signing and add the key to your GitHub account: https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits"
  echo "2. Re-sign the commits on this branch (\`-s\` keeps the DCO sign-off):"
  echo
  echo '   ```sh'
  echo "   git fetch origin $BASE_REF"
  echo "   git rebase --exec 'git commit --amend --no-edit -S -s' origin/$BASE_REF"
  echo "   git push --force-with-lease"
  echo '   ```'
  echo
  echo "Replace \`origin\` with the remote that points to $REPO if it differs."
  echo
  echo "Commit signing and DCO sign-off are separate requirements. Reasons are defined at https://docs.github.com/en/rest/commits/commits#get-a-commit"
} | tee -a "$GITHUB_STEP_SUMMARY"

exit 1
