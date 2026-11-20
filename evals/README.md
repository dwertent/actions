# Skill evals

The cases in [cases.json](cases.json) evaluate the current repository skills with the current
repository guidance and action files from a pinned revision. The review pair checks for both a missed undeclared
default change (C1) and a false alarm on a description-only change. The authoring case checks the edited
action metadata, the README update (D3), and the breaking-change marker in the proposed PR title (C2).
The `write-evals` case grades a proposed eval by running its expectations against known-good and wrong reviews.

The model receives the case prompt and supplied files or diff. The runner keeps expected results in the grader
and evaluates returned findings and file contents as data. The cases cover source-level work. The
[action's tests](../verify-commit-signatures/README.md#testing) cover runtime behavior.

## Run locally

Use a full checkout that contains the fixture revision. Install the dependencies in the same Python environment
you use to run the tests. The `yaml` import comes from the pinned PyYAML package.

```sh
python3 -m venv /tmp/actions-evals-venv
/tmp/actions-evals-venv/bin/python -m pip install -r evals/requirements.txt
/tmp/actions-evals-venv/bin/python -B -m unittest discover -s evals -p 'test_*.py'
```

With `OPENAI_API_KEY` set in your environment, run the live suite. It defaults to `gpt-6.2-sol`.

```sh
/tmp/actions-evals-venv/bin/python -B evals/run.py
```

Use `--without-skills` for a baseline that receives the same repository guidance and case inputs. Each
case reports individual assertions. The runner exits nonzero for failed assertions and distinguishes
those failures from missing credentials or invalid model responses.

HTTP 429 can indicate a temporary rate limit or an API billing or usage limit. If the response identifies
exhausted quota, the runner lists the unattempted cases as skipped and exits with an execution error.
Check API billing and usage limits for quota errors. For temporary rate limits, wait before rerunning.

## Maintain cases

Use the [eval authoring skill](../.agents/skills/write-evals/SKILL.md) when changing the suite.
Update `cases.json` for changes covered by the existing graders. When adding a different behavior,
add its grading logic and exercise it with both a correct response and a plausible wrong response
in `test_run.py`. Keep the pinned fixture revision stable until the case needs different source.

## GitHub Actions

The [Skill evals workflow](../.github/workflows/skill-evals.yaml) triggers on pull requests and pushes to
`main` that touch skills, `AGENTS.md`, `CONTRIBUTING.md`, the eval directory, or the workflow itself.
It runs the fixture and grader checks on each trigger. Set the repository Actions secret `OPENAI_API_KEY`
to run live cases on same-repository pull requests, pushes to `main`, and manual runs. Fork and Dependabot
pull requests run the offline checks.
