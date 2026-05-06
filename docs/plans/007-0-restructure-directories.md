# 007-0: Directory structure reorg + meilisearch extraction

## Parent plan

[007-migrate-to-docker-compose.md](007-migrate-to-docker-compose.md) — Migrate from `docker_container` to Docker Compose

## Status: ✅ DONE (2026-05-05)

- [x] Move roles into subdirectories
- [x] Extract meilisearch from linkwarden role
- [x] Split playbooks/services/ into meta/ + infra/
- [x] Update servers.yml imports
- [x] Validate with `ansible-playbook --check`
- [x] Resolve cross-role variable dependencies (meta deps, no shared_vars)
- [x] Fix check-mode compatibility (`block: when: not ansible_check_mode`)

## Motivation

Currently all roles and service playbooks are flat under their directories. Meta-services (shared infrastructure consumed by other stacks) are visually indistinguishable from application services. This batch establishes the structure before any compose migration begins — zero functional change, pure refactor.

## Current → Target mapping

### Roles

| Now | Becomes | Why |
|-----|---------|-----|
| `roles/postgres/` | `roles/meta/postgres/` | Shared DB consumed by other stacks via hostname |
| *(linkwarden meilisearch tasks)* | `roles/meta/meilisearch/` | Extract to standalone; future-proof for new consumers |
| `roles/step_ca/` | `roles/services/step_ca/` | Application service (CA provider) |
| `roles/traefik/` | `roles/services/traefik/` | Application service (reverse proxy) |
| `roles/portainer/` | `roles/services/portainer/` | Application service |
| `roles/portainer_edge/` | `roles/services/portainer_edge/` | Application service |
| `roles/vaultwarden/` | `roles/services/vaultwarden/` | Application service |
| `roles/qbittorrent/` | `roles/services/qbittorrent/` | Application service |
| `roles/linkwarden/` | `roles/services/linkwarden/` | Application service (meilisearch removed) |
| `roles/beszel/` | `roles/services/beszel_hub/` + `roles/services/beszel/` | Split hub+agent (like portainer/portainer_edge) |
| `roles/inpx_web/` | `roles/services/inpx_web/` | Application service |
| `roles/server_base/` | `roles/infra/server_base/` | Host-level setup, not stack-based |
| `roles/docker/` | `roles/infra/docker/` | Host-level setup |
| `roles/install_ca_cert/` | `roles/infra/install_ca_cert/` | Host-level setup |
| `roles/openwrt_base/` | `roles/infra/openwrt_base/` | Router-level setup |
| `roles/openwrt_adblock/` | `roles/infra/openwrt_adblock/` | Router-level setup |
| `roles/common/` | *(stays top-level)* | Ansible default lookup; shared utilities |

### Service playbooks

| Now | Becomes |
|-----|---------|
| `services/postgres.yml` | `services/meta/postgres.yml` |
| `services/step_ca.yml` | `services/infra/step_ca.yml` |
| `services/traefik.yml` | `services/infra/traefik.yml` |
| `services/portainer.yml` | `services/infra/portainer.yml` |
| `services/portainer_edge.yml` | `services/infra/portainer_edge.yml` |
| `services/vaultwarden.yml` | `services/infra/vaultwarden.yml` |
| `services/qbittorrent.yml` | `services/infra/qbittorrent.yml` |
| `services/linkwarden.yml` | `services/infra/linkwarden.yml` |
| `services/beszel.yml` | `services/infra/beszel.yml` |
| `services/inpx_web.yml` | `services/infra/inpx_web.yml` |

## Implementation steps

### Step 1: Update ansible.cfg roles path

```ini
roles_path = ~/.ansible/roles:playbooks/roles/meta:playbooks/roles/services:playbooks/roles/infra
```

Or keep current and use explicit role paths in playbooks — whichever works with existing `include_role` syntax. Test first.

### Step 2: Move roles (git mv)

```bash
# Meta services
git mv playbooks/roles/postgres playbooks/roles/meta/postgres

# Application services
mkdir -p playbooks/roles/services
git mv playbooks/roles/{step_ca,traefik,portainer,portainer_edge,vaultwarden,qbittorrent,beszel,inpx_web} playbooks/roles/services/

# Infra roles
mkdir -p playbooks/roles/infra
git mv playbooks/roles/{server_base,docker,install_ca_cert,openwrt_base,openwrt_adblock} playbooks/roles/infra/
```

### Step 3: Extract meilisearch from linkwarden

Current linkwarden role has meilisearch container in `tasks/deploy.yml`. Split into:

**New `playbooks/roles/meta/meilisearch/`:**
- `tasks/main.yml` — deploy meilisearch container (extracted from current linkwarden)
- `handlers/main.yml` — restart handler
- Vars move to group_vars or new role defaults

**Updated `playbooks/roles/services/linkwarden/tasks/deploy.yml`:**
- Remove meilisearch container task
- Change `MEILI_HOST` from `http://meilisearch:7700` → `http://meili.{{ lan_domain }}:{{ meilisearch_port }}`
- Remove custom Docker network tasks (no longer needed — all comms via host DNS)

### Step 4: Split playbooks/services/

```bash
mkdir -p playbooks/services/{meta,infra}
git mv playbooks/services/postgres.yml playbooks/services/meta/postgres.yml
# meilisearch.yml will be created in this step (new file)
git mv playbooks/services/*.yml playbooks/services/infra/  # remaining
```

### Step 5: Consolidate into single play

Replaced 14 `import_playbook` entries with a single play using roles + meta deps:

```yaml
- name: Deploy homelab services
  hosts: servers
  become: true
  vars_files:
    - ../vault/secrets.yml
  roles:
    - role: server_base
      tags: [server_base]
    - role: docker
      tags: [docker]
    # ... etc (see servers.yml for full list)
```

### Step 6: Validate

```bash
ansible-playbook playbooks/servers.yml --list-tasks
ansible-playbook playbooks/servers.yml --check  # dry-run, should show no errors
```

## Affected files

| File | Change |
|------|--------|
| `ansible.cfg` | Update `roles_path` for subdirectories |
| `playbooks/roles/meta/postgres/` | Moved from `roles/postgres/` |
| `playbooks/roles/meta/meilisearch/` | **New** — extracted from linkwarden |
| `playbooks/roles/services/*` | Moved from `roles/*` (9 roles) |
| `playbooks/roles/infra/*` | Moved from `roles/*` (5 roles) |
| `playbooks/roles/common/` | Unchanged (stays top-level) |
| `playbooks/services/meta/postgres.yml` | Moved + new meilisearch.yml created |
| `playbooks/services/infra/*.yml` | Moved (9 playbooks) |
| `playbooks/servers.yml` | Update all import paths |

## Implementation notes

### Cross-role variables — meta dependency approach

Roles that consume another role's vars (traefik → step_ca_port, linkwarden → postgres_port + meilisearch_port) depend via `meta/main.yml`.

Key discovery: Ansible's meta dependencies resolve both defaults AND execute tasks. Within a single play this is fine — roles are deduplicated (`play.role_cache`). Between separate plays (old architecture) it caused double execution.

Solution: consolidate to one play with `hosts: servers`, use role meta deps for cross-role vars, and rely on Ansible's built-in deduplication.

### Playbook consolidation

Replaced 14 individual imported playbooks with a single play in `servers.yml`. Benefits:
- Meta dependency resolution works (single `play.role_cache`)
- No shared_vars role needed — defaults cascade naturally
- Simpler structure, easier to understand dependency chain

### Check-mode fixes

Multiple roles had URI/exec chains that fail when tasks are skipped but conditionals still evaluate registered vars. Fixed with `block: when: not ansible_check_mode` pattern in:
- install_ca_cert/tasks/main.yml
- qbittorrent/tasks/deploy.yml
- portainer_edge/tasks/edge_register.yml
- beszel/tasks/register.yml
- portainer/tasks/init_envs.yml
- linkwarden/tasks/db_init.yml

## Risks

| Risk | Mitigation |
|------|-----------|
| Role path change breaks existing imports | Validate with `--list-tasks` before deploying; git mv preserves history for easy revert |
| Meilisearch extraction changes linkwarden behavior | Linkwarden currently resolves meilisearch via Docker internal DNS (`meilisearch:7700`) — must switch to host DNS (`meili.lan_domain:port`). Test thoroughly. |
| Custom "linkwarden" Docker network removal | Only used for internal meilisearch→app DNS. With host DNS, it's no longer needed. Verify no other services use it. |

## Rollback

`git revert` — every move is a `git mv`, fully tracked and reversible in one commit.
