# Plans

This folder serves as a collection of plans for the homelab-ansible project — essentially GitHub Issues stored as markdown files, since this repo will move away from GitHub eventually.

Each file describes a single change or refactoring effort: the motivation, affected files, and implementation steps. Use these to track what's been done and what's pending before diving in.

## Difficulty key

| Rating | What it means |
|--------|---------------|
| Easy   | 1-3 files, straightforward changes, low risk of breakage |
| Medium | 4-8 files, some interdependencies, moderate testing needed |
| Hard   | Requires research, new infrastructure, or high risk of breaking existing services |

## Plans

| # | Priority | Plan | Difficulty | Status |
|---|----------|------|------------|--------|
| 0 | Critical | Revival of LANs communities (Altair/OrNet/ZNet style) | Impossible | Dreaming |
| 1 | Normal | [Move structural vars from inventory to role defaults](001-move-to-defaults.md) | Medium | In review |
| 2 | Low | [Harden router SSH configuration](002-harden-router.md) | Hard | In review |
| 3 | Low | [Rework Beszel playbooks](003-rework-beszel.md) | Medium | In review |
| 4 | Normal | [Remove `lab_index` — use inventory_hostname directly](004-remove-lab-index.md) | Easy | ✅ Done (2026-05-03) |
| 5 | Critical | [Kopia backup server + agents (labs, PC, MacBook, Android)](005-kopia-backup.md) | Hard | In review |
| 6 | Low | [Service docs generator approach TBD](006-docs-generator-approach.md) | — | In review |
| 7 | High | [Migrate from docker_container to Docker Compose](007-migrate-to-docker-compose.md) | Hard | In review |
