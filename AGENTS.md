# Repository Guidelines

This repository holds GitHub Actions shared across Zarf repositories. Each action is a top-level directory.

## Rules

[CONTRIBUTING.md](CONTRIBUTING.md) is the single source of truth for how actions are laid out, written, secured, tested, and documented. Read it in full before creating, changing, or reviewing anything in this repository, and cite its rule IDs (for example `S1`, `T2`) when explaining a decision or a review finding. Do not restate its rules elsewhere; link to them.

If a change needs to break a rule, stop and raise it with the human instead of working around it. If a rule is missing or wrong, propose an edit to CONTRIBUTING.md.

## Skills

- `add-action` scaffolds a new action that follows CONTRIBUTING.md.
- `review-action` checks a change against CONTRIBUTING.md.

Both live in `.agents/skills/`, each as a `SKILL.md`. Read the matching file before starting that kind of task.

## Commands

Each action's README says how to run its tests.

## Human Handoff

Humans own commits, issues, and pull requests. Agents may prepare changes and handoff material, but must not author or create them. Give the human author factual context on the change, user impact, tests, and follow-up.
