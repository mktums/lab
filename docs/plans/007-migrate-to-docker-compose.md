# 007: Migrate from `docker_container` to Docker Compose for deployment

## Motivation

All service roles currently use `community.docker.docker_container` module directly (14 roles). This means:
- Each container is defined inline in YAML — no compose file, no `docker-compose.yml` equivalent committed
- No `docker_compose_v2` usage despite the plugin being installed (`playbooks/roles/docker/tasks/main.yml`)
- Multi-container services (e.g., Linkwarden with DB) are managed as separate containers without orchestration
- Harder to reason about service composition; no `docker compose config` for inspection

## Current state

| Role | Containers | Uses Compose? |
|------|-----------|---------------|
| step_ca | 1 (container + exec) | No |
| traefik | 1 | No |
| portainer | 2 (main + edge agent) | No |
| vaultwarden | 1 | No |
| qbittorrent | 1 | No |
| linkwarden | 2+ (app, db, meilisearch) | No |
| postgres | 1 | No |
| beszel | 1 (hub + agent roles separate) | No |
| inpx_web | 1 | No |

**Total: ~14 service roles → all `docker_container`, zero Compose files.**

## Migration approach

### Option A: Generate compose files from role vars, deploy via `docker_compose_v2`
- Each role produces a `templates/docker-compose.yml.j2`
- Tasks use `community.docker.docker_compose_v2` to manage it
- Volumes/networks defined in compose, not inline

**Pros:** Single source of truth (compose file); matches Docker ecosystem expectations  
**Cons:** Jinja2 in compose YAML is awkward; some features don't translate well

### Option B: Static compose files + role vars for env-specific overrides
- Compose files committed as static YAML with `{{ variable }}` placeholders only where needed
- Role vars control image tags, ports, volumes, environment

**Pros:** Clean compose syntax; easy to read/run manually  
**Cons:** Two places to update when changing config

### Option C: Hybrid — compose for structure, role vars for values
- Compose defines containers, networks, basic mounts
- `environment` and volume paths come from role defaults/group_vars
- `docker_compose_v2` with `project_src` pointing to the template dir

**Pros:** Best of both worlds; Docker-native syntax + Ansible flexibility  
**Cons:** Slightly more complex variable passing

## Implementation steps (for chosen option)

1. Pick approach and define conventions for compose file structure
2. Migrate simplest role first (e.g., postgres → single container, easy to verify)
3. Migrate multi-container services next (linkwarden is the big one)
4. Handle traefik last (ACME cert workflow may have Compose-specific quirks)
5. Update step_ca trust.yml (uses `docker_container_exec` — needs compose networking awareness)

## Risks

- `docker_compose_v2` behavior differs from CLI in edge cases (network creation, volume lifecycle)
- Traefik ACME with step-ca may have Compose-specific networking issues
- Portainer Edge agent uses a different deployment pattern than normal containers
