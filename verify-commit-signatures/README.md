# verify-commit-signatures

Fails a pull request check when any commit in the pull request lacks a GitHub-verified signature. Each unverified commit is reported as an error annotation, and the job summary lists the commits with the steps to re-sign them.

Commit signing and DCO sign-off are separate requirements; this action checks only signatures.

## Usage

```yaml
on:
  pull_request_target:
    types: [opened, reopened, synchronize]

permissions: {}

jobs:
  verify-commit-signatures:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
    steps:
      - uses: zarf-dev/actions/verify-commit-signatures@<commit-sha>
```

Use `pull_request_target` so the workflow runs from the base branch and a pull request cannot alter its own check. The action only calls the GitHub API and never checks out or executes pull request code.

The action must run on a pull request event. If the check is required and the repository uses a merge queue, add a `merge_group` trigger with a step that reports success, because merge queue events carry no pull request to inspect.

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `max-commits` | `250` | Maximum number of commits a pull request may contain. The GitHub API lists at most 250 commits per pull request, so larger values are rejected. |
| `token` | `${{ github.token }}` | Token used to list the pull request commits. Needs pull-requests read access. |

## Behavior

- A commit passes only when GitHub reports its signature as verified. Missing verification metadata counts as unverified.
- A pull request with more commits than `max-commits` fails without being inspected.
- A failed GitHub API call fails the check.

## Testing

```sh
bash verify-commit-signatures/verify_test.sh
```

The tests run `verify.sh` against canned API responses using a fake `gh`. They need only `bash` and `jq`.
