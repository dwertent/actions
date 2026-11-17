# close-on-labels

Closes an issue or pull request when its labels match a rule. Rules use `or`, `and` and `not` label lists and are
checked in order: **the first rule that applies decides, and no later rule is looked at.**

## Usage

```yaml
on:
  issues:
    types: [labeled]
  pull_request_target:
    types: [labeled]

permissions: {}

jobs:
  close-on-labels:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      issues: write
      pull-requests: write
    steps:
      - uses: zarf-dev/actions/close-on-labels@<commit-sha>
        with:
          rules-file: .github/close-rules.yaml
```

```yaml
# .github/close-rules.yaml
rules: # checked in order, the first rule that applies decides
  - name: keep
    not: [keep-open]
    target: issues
  - name: rejected
    or: [wontfix, invalid, duplicate]
    comment: "Closing because this was labeled {{matched}}."
  - name: superseded
    and: [duplicate, has-replacement]
    target: prs
```

Use `pull_request_target` so the workflow runs from the base branch and a pull request cannot change the rules that
judge it. The action only calls the GitHub API and never checks out or executes pull request code. Without a checkout,
the rules file is read through the API at the commit the workflow runs on, which for `pull_request_target` is the base
branch; this needs `contents: read`.

A single rule can be given inline instead of in a file:

```yaml
      - uses: zarf-dev/actions/close-on-labels@<commit-sha>
        with:
          or: wontfix, invalid
          not: keep-open
```

## Rules

### Order

Rules are checked from top to bottom. The first rule that applies decides what happens, and the rules after it are
never checked. Moving a rule changes the result.

With the rules file above:

| Labels on the item | Result |
| --- | --- |
| `wontfix` | Closed by `rejected`. |
| `wontfix`, `keep-open` | Kept open by `keep`. The later rules are never checked. |
| `duplicate`, `has-replacement` | Closed by `rejected`, because it comes before `superseded`. |
| `has-replacement` | No rule applies. Left open. |

If `keep` were moved to the bottom, an item labeled `wontfix` and `keep-open` would be closed, because `rejected`
would apply first. The action warns about a rule with only `not` that comes after every rule that can close, since it
can never have an effect.

The run log lists each rule in order with whether it was skipped, did not apply, or applied, and how many rules after
it were not checked.

### Keys

| Key | Meaning |
| --- | --- |
| `or` | At least one of these labels is on the item. |
| `and` | Every one of these labels is on the item. |
| `not` | None of these labels is on the item. |
| `name` | Shown in the log, the `matched-rule` output and `{{rule}}`. Defaults to `rule-N`, counted from 1 in the file. |
| `target` | `issues`, `prs` or `all`. Defaults to the `target` input. |
| `reason` | `completed` or `not_planned`. Defaults to the `close-reason` input. |
| `comment` | Defaults to the `comment` input. `""` turns the default comment off for this rule. |
| `lock` | `true` or `false`. Defaults to the `lock` input. |

Label lists are YAML lists or comma separated strings.

There are two kinds of rule:

- **A rule with `or` or `and`** closes the item when every list it sets is satisfied. A `not` in the same rule only
  stops that rule; if it does not apply, the next rule is checked.
- **A rule with only `not`** applies when the item has one of the listed labels. The item stays open and the rules
  after it are not checked. It protects the item only from the rules below it. `reason`, `comment` and `lock` are not
  allowed on it.

At least one rule must be able to close. Labels match case-insensitively. A rule whose `target` does not match the
item is skipped, and the next rule is checked.

### Inline rule

The `or`, `and` and `not` inputs form one rule named `inline`, with the same meaning as above. It is checked before
the rules in `rules-file`, so an inline `not` alone protects the item from every rule in the file.

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `or` | | Labels, separated by commas or newlines. |
| `and` | | Labels, separated by commas or newlines. |
| `not` | | Labels, separated by commas or newlines. |
| `rules-file` | | Path to a YAML rules file, relative to the workspace. |
| `target` | `all` | `issues`, `prs` or `all`. Default for rules that do not set their own. |
| `comment` | | Comment posted before closing. `{{matched}}` becomes the matched labels and `{{rule}}` the rule name. Empty means no comment. |
| `close-reason` | `not_planned` | `completed` or `not_planned`. Issues only. |
| `lock` | `false` | Lock the conversation after closing. |
| `dry-run` | `false` | Log the result without commenting, closing or locking. |
| `number` | from the event | Issue or pull request number to check. |
| `token` | `${{ github.token }}` | Token used to read and close the item. Needs `issues: write`, `pull-requests: write`, and `contents: read` to fetch a rules file. |

## Outputs

| Name | Description |
| --- | --- |
| `closed` | `true` if this run closed the item, otherwise `false`. |
| `result` | `closed`, `kept` (a rule with only `not` applied), `would-close` (dry-run) or `none`. |
| `matched-rule` | Name of the rule that applied, or empty. |
| `matched-labels` | Comma separated labels that made the rule apply, or empty. |
| `number` | The number that was checked. |

## Behavior

- Labels are read from the API when the action runs, not from the event payload.
- An item that is already closed is skipped.
- When a rule closes the item, the order is: comment, close, lock. Pull requests are closed without a reason.
- The rules file is read from the workspace when it is there, otherwise from the repository at `github.sha`.
- Every rule is validated before the item is read. Any invalid rule fails the step and changes nothing.
- A failed GitHub API call fails the step. If the comment was posted but closing failed, the error says the item is
  still open.
- The action needs `bash`, `gh`, `jq` and `yq` ([mikefarah/yq](https://github.com/mikefarah/yq) v4). GitHub-hosted
  Ubuntu runners include them; install them on self-hosted runners.
- Closing with the default `GITHUB_TOKEN` does not trigger other workflows.

## Testing

```sh
bash close-on-labels/close_test.sh
```

The tests run `close.sh` against canned API responses using a fake `gh`. They need `bash`, `jq` and `yq`.
