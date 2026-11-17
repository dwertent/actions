---
name: review-action
description: Review a change in this repository (working tree, branch, or pull request) against the rules in CONTRIBUTING.md and report violations by rule ID. Use when asked to review, check, or audit an action or a pull request here.
---

# Review a change against the contributing rules

The rules live in `CONTRIBUTING.md` at the repository root. This skill is only the review procedure; it does not repeat the rules.

1. Read `CONTRIBUTING.md` in full. Do this every time, since the rules change.
2. Collect the change: the diff for the working tree, branch, or pull request named by the human, plus the full contents of every action directory and workflow it touches.
3. Check the change against every rule ID, one by one. A rule that does not apply is skipped, not passed.
4. Run the tests of each action the change touches and record the result.
5. Report findings, most severe first. For each: the rule ID, the file and line, what is wrong, and the fix. Security rules (`S*`) and fail-closed behavior outrank style.
6. State what was not checked, for example workflows that can only be exercised on GitHub.
7. If the change is sound but a rule is unclear, missing, or contradicted by existing code, say so separately as a suggested edit to `CONTRIBUTING.md`.

Do not fix findings unless the human asks. Do not post comments or reviews to GitHub unless the human asks.
