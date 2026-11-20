---
name: add-action
description: Scaffold a new GitHub Action in this repository, or add an input, output, or behavior to an existing one, following the rules in CONTRIBUTING.md. Use when asked to create, add, or extend an action here.
---

# Add or extend an action

The rules live in `CONTRIBUTING.md` at the repository root. This skill is only the order of work; it does not repeat the rules.

1. Read `CONTRIBUTING.md` in full. Do this every time, since the rules change.
2. Read an existing action end to end (its directory and its workflows) to see how the rules are applied in practice. Its language and file structure are not a template; choose what fits the new action.
3. Confirm with the human anything the rules cannot answer: the action's name, its inputs and defaults, and which events it must support.
4. Create or change the files the Repository layout section requires. For a new action that means the action directory, its test workflow, and the row in the root `README.md`.
5. Write the tests the Testing section requires, with tooling that fits the implementation.
6. Run the tests and fix failures. Then break the logic on purpose once to confirm a test catches it, and restore it.
7. Go through every rule ID in `CONTRIBUTING.md` and check the change against it. Fix what does not comply.
8. Update the agent skill that covers the change. Use [write-evals](../write-evals/SKILL.md) to add, revise,
   or remove authoring and review cases when their expectations change. Check the evals alongside the action tests.
9. Hand off to the human: what was added, how it was tested, which rules needed a judgment call, and anything not verified (for example, that the workflows have not run on GitHub). Do not commit or open a pull request.
