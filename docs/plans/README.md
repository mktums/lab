# Plans

This folder serves as a collection of plans for the homelab-ansible project — essentially GitHub Issues stored as markdown files, since this repo doesn't have an issue tracker.

Each file describes a single change or refactoring effort: the motivation, affected files, and implementation steps. Use these to track what's been done and what's pending before diving in.

## Difficulty key

| Rating | What it means |
|--------|---------------|
| Easy   | 1-3 files, straightforward changes, low risk of breakage |
| Medium | 4-8 files, some interdependencies, moderate testing needed |
| Hard   | Requires research, new infrastructure, or high risk of breaking existing services |

## Plans (pending)

| # | Plan | Difficulty |
|---|------|------------|
| 1 | [Move structural vars from inventory to role defaults](001-move-to-defaults.md) | Medium |
| 2 | [Harden router SSH configuration](002-harden-router.md) | Hard |
| 3 | [Rework Beszel playbooks](003-rework-beszel.md) | Medium |
| 4 | [Remove `lab_index` — use inventory_hostname directly](004-remove-lab-index.md) | Easy |
| 5 | [Kopia backup server + agents (labs, PC, MacBook, Android)](005-kopia-backup.md) | Hard |
