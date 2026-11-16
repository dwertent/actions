# Contributing to zarf-dev/actions

This repository holds GitHub Actions shared across Zarf repositories. The rules below apply to every change, whether written by a person or an agent. Each rule has an ID so reviews can cite them.

The rules say what every action must provide, not how to build it. Language, file structure, and test tooling are the action author's decision.

## Repository layout

```
<action-name>/
  action.yaml    # action metadata
  README.md      # usage, inputs, behavior
  ...            # everything else is up to the implementation
.github/workflows/
  <action-name>-test.yaml   # runs the action's tests
  <action-name>.yaml        # only if this repository itself uses the action
```

- **L1.** Each action lives in its own top-level directory, named in lowercase kebab-case, so it is referenced as `zarf-dev/actions/<action-name>@<ref>`.
- **L2.** Each action directory contains the action metadata file and a `README.md`. The rest of the directory is structured as the implementation needs.
- **L3.** Workflows for an action are named after it: `<action-name>-test.yaml` runs its tests, and `<action-name>.yaml` uses the action on this repository when that applies.
- **L4.** The root [README.md](README.md) lists every action with a one-line description. Add or update the row when adding or renaming an action.

## Writing an action

- **A1.** Pick the action type (composite, JavaScript/TypeScript, container) and structure that fit the job.
- **A2.** Every action must be testable: its logic can be exercised by automated tests without a live workflow run, network access, or real credentials.
- **A3.** Fail closed. If the action cannot complete its job (API error, missing data, unsupported event, invalid input), it fails rather than passing.
- **A4.** A failure tells the contributor what went wrong and how to fix it without reading the source.
- **A5.** Source files carry the SPDX header in the comment syntax of their language:

  ```
  SPDX-License-Identifier: MIT
  SPDX-FileCopyrightText: 2026-Present The Zarf Authors
  ```

## Security

- **S1.** Never interpolate `${{ }}` expressions into a `run:` block. Pass values through `env:` and read them as variables.
- **S2.** Treat all event data (titles, branch names, commit messages) as untrusted. Escape it before writing workflow commands or passing it to a shell.
- **S3.** Pin every third-party action to a full commit SHA with the version in a trailing comment, for example `actions/checkout@<sha> # v7.0.1`.
- **S4.** Workflows set `permissions: {}` at the top level and grant the minimum per job. Each action's README states the permissions it needs.
- **S5.** An action that takes a token accepts it as an input that defaults to `${{ github.token }}`. Never print tokens or secrets.
- **S6.** A workflow triggered by `pull_request_target` must not check out or execute pull request code. If it needs repository files, it checks out the base branch only, and a comment in the workflow says so.
- **S7.** Set `persist-credentials: false` on `actions/checkout` unless a later step needs to push.

## Testing

- **T1.** Every action has automated tests. How they are written is the action author's decision.
- **T2.** The tests run in CI from `.github/workflows/<action-name>-test.yaml` on pull requests that touch the action.
- **T3.** A behavior change comes with a test that fails without it.
- **T4.** The action's README says how to run its tests locally.

## Documentation

- **D1.** Each action's `README.md` covers what it does, a usage example with the required trigger and permissions, its inputs and outputs with defaults, behavior worth knowing (limits, failure modes), and how to run the tests.
- **D2.** Usage examples reference the action as `zarf-dev/actions/<action-name>@<commit-sha>`.
- **D3.** Update the README in the same pull request as any change to inputs, outputs, or behavior.

## Compatibility

- **C1.** Other repositories pin these actions by commit SHA, but keep changes backward compatible anyway: do not remove or rename inputs or outputs, or change a default, without calling it out as a breaking change in the pull request.
- **C2.** Mark breaking changes with `!` in the pull request title, and describe the impact and the migration.

## Commits and pull requests

- **P1.** Sign every commit so GitHub shows it as verified. See [GitHub's signing guide](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits). The `verify-commit-signatures` check enforces this.
- **P2.** Sign off every commit with `git commit -s` to agree to the [Developer Certificate of Origin](https://developercertificate.org/). Signing and sign-off are separate requirements.
- **P3.** Pull request titles follow [Conventional Commits](https://www.conventionalcommits.org/), with the action name as the scope where one applies, for example `feat(verify-commit-signatures): add max-commits input`.
- **P4.** Keep each pull request to one action or one concern.
- **P5.** Run the tests for every action you changed before opening a pull request.
