---
name: write-evals
description: >-
  Write or revise behavioral evals for agents that author or review GitHub Actions in this repository,
  including the add-action and review-action skills. Use for eval case design, evidence-backed grading,
  and skill regression coverage.
---

# Write evals for GitHub Actions skills

Read [CONTRIBUTING.md](../../../CONTRIBUTING.md) in full and read the skill being evaluated. Name the decision
the eval will inform and the behavior that would change that decision. These evals measure the agent's review
or edits. For ordinary action runtime tests, follow A2 and T1–T4 and use the affected action's README.

## Maintain coverage

Update the affected skill and its eval cases together. Use the changed inputs, outputs, behavior, or
rule IDs to find cases that need attention. Add coverage for new expectations, revise affected
fixtures and assertions, and remove cases that only cover retired expectations. Keep cases that
protect supported behavior, even when an implementation changes. Use the [eval runbook](../../../evals/README.md)
to check fixtures and graders locally and run the live suite when credentials are available.

## Write cases

- Give each case a stable ID, a realistic user request, an exact base commit, and any diff, files, or tool
  access the agent needs. Use synthetic event and API data and disposable local workspaces. Keep expected
  findings, grader instructions, and reference solutions outside the evaluated agent's inputs and workspace.
- Pair a known failure or hard requirement with a nearby passing control. For review, use the same request
  over two small diffs so the grader can catch both missed findings and false alarms. For authoring, check
  the requested behavior under relevant success and failure conditions. When extending an action, also
  check behavior callers rely on. Seed one targeted difference where practical.
- Establish the expected result independently of the agent. Cite the relevant rule IDs and pinned source
  or diff. For claims about action behavior, verify them using the documented local entry point and
  fixtures, such as the stubbed `gh` used by `verify-commit-signatures`. Record what evidence each check
  establishes and distinguish source inspection from execution.

## Write and check the grader

- Grade one observable outcome per assertion. For reviews, check the rule ID, affected file and line, and
  correctness of the finding. For edits, inspect the resulting diff, parse structured files, and run the
  affected action's documented tests when relevant. Check authorization and scope when they are part of the task.
- Prefer deterministic assertions for facts. Use human review or a model rubric for judgments such as
  whether a proposed fix addresses the finding. Require evidence for each judgment and check it against
  the fixture. Try the grader on a known-good result and a plausible wrong result before comparing skills.
- For evals of this skill, exercise the proposed grading expectations against independently verified
  responses. Check that the proposed eval accepts both correct responses and rejects both a missed finding
  and a false alarm. Run trusted graders against the submitted expectations as data.
- Reuse an existing runner and result format when available. If there is no runner, provide the case
  inputs, grading instructions, and a repeatable manual check. Use fresh sessions for a baseline and
  candidate. Keep the prompt, inputs, model settings, tool access, and grader fixed, and change only the
  skill under test. Repeat representative cases when running a comparison.
- Keep a record of the case and skill revisions, model settings, grader, and results by assertion. Track
  missed findings, false alarms, and execution failures separately. Mark cases that were only drafted as unrun.
  Keep cases skipped after an exhausted API quota out of the behavioral failure count.

## Example review pair

Use a pinned base where `verify-commit-signatures/action.yaml` sets `max-commits` to `"250"`. Give both
runs the request “Review this PR for backward compatibility.” In one fixture the diff lowers the default
to `"200"` without declaring a breaking change. In the paired control the diff edits only the input's
description. Independently compare the parsed defaults and the supplied PR metadata. Grade whether the
review cites C1 at the changed default in the first case and avoids a default-change finding in the control.
