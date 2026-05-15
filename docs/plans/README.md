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
| 1 | Normal | [Move structural vars from inventory to role defaults](001-move-to-defaults.md) | Medium | ✅ Done (2026-05-03) |
| 2 | Low | [Harden router SSH configuration](002-harden-router.md) | Hard | In review |
| 3 | Low | [Rework Beszel playbooks](003-rework-beszel.md) | Medium | ✅ Done (2026-05-03) |
| 4 | Normal | [Remove `lab_index` — use inventory_hostname directly](004-remove-lab-index.md) | Easy | ✅ Done (2026-05-03) |
| 5a | Critical | [Deploy Kopia repository server](005a-kopia-server.md) | Hard | In review |
| 5b | Critical | [Kopia agents (lab services, PC, MacBook, Android)](005b-kopia-agents.md) | Hard | In review |
| 6 | Low | [Service docs generator approach TBD](006-docs-generator-approach.md) | — | In review |
| 7 | High | [Migrate from docker_container to Docker Compose](007-migrate-to-docker-compose.md) | Hard | ✅ Done (2026-05-07) |
| 8 | Low | [Optimize inpx-web Dockerfile (multi-stage build)](008-optimize-inpx-dockerfile.md) | Medium | In review |
| 9 | Normal | [Reconsider service playbook independence](009-service-playbook-independence.md) | Easy | ✅ Done (2026-05-05) |
| 10 | High | [CNAME name/target consistency across roles](010-cname-consistency.md) | Medium | ✅ Done (2026-05-09) |
