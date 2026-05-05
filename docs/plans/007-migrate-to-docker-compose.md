# 007: Migrate from `docker_container` to Docker Compose for deployment

## Sub-plans

| File | Description | Status |
|------|-------------|--------|
| [007-0-restructure-directories.md](007-0-restructure-directories.md) | Directory reorg + meilisearch extraction | ✅ Done (2026-05-05) |
| [007-1-simple-singles.md](007-1-simple-singles.md) | postgres, vaultwarden, qbittorrent | Pending |
| [007-2-portainer-stacks.md](007-2-portainer-stacks.md) | portainer + portainer_edge | Pending |
| [007-3-beszel-split-role.md](007-3-beszel-split-role.md) | beszel hub + agent | Pending |
| [007-4-meilisearch-meta.md](007-4-meilisearch-meta.md) | meilisearch meta-service | Pending |
| [007-5-linkwarden-app.md](007-5-linkwarden-app.md) | linkwarden (app only, meta deps) | Pending |
| [007-6-core-infra-order.md](007-6-core-infra-order.md) | step_ca + traefik (order-critical) | Pending |
| [007-7-inpx-build-pipeline.md](007-7-inpx-build-pipeline.md) | inpx_web (custom build) | Pending |

## Motivation

All service roles currently use `community.docker.docker_container` module directly (10 roles). This means:
- Each container is defined inline in YAML — no compose file, no `docker-compose.yml` equivalent committed
- No `docker_compose_v2` usage despite the plugin being installed (`playbooks/roles/docker/tasks/main.yml`)
- Multi-container services (e.g., Linkwarden with DB) are managed as separate containers without orchestration
- Harder to reason about service composition; no `docker compose config` for inspection

## Current state

| Role | Containers | Network mode | Uses Compose? |
|------|-----------|-------------|---------------|
| step_ca | 1 + exec (trust) | bridge + published port | No |
| traefik | 1 | **host** (TLS-ALPN-01 requirement) | No |
| portainer | 2 (main + edge agent) | default | No |
| vaultwarden | 1 | default | No |
| qbittorrent | 1 | default | No |
| linkwarden | 3 (app, meilisearch) + db_init exec | custom "linkwarden" network | No |
| postgres | 1 | bridge + published port | No |
| beszel | 2 (hub + agent separate roles) | host (agent), default (hub) | No |
| inpx_web | 1 + docker build step | default | No |

**Total: ~10 service roles → all `docker_container`, zero Compose files.**

## Architecture decisions

### Directory structure reorganization

Currently everything is flat under `playbooks/roles/` and `playbooks/services/`. Meta-services (shared infrastructure) are visually indistinguishable from application services.

**New structure:**

```
playbooks/roles/
  meta/
    postgres/          ← shared infra, consumed by other stacks via hostname
    meilisearch/       ← extracted from linkwarden; future-proofed for new consumers
  services/
    step_ca/           ← application services (may depend on meta)
    traefik/
    portainer/
    portainer_edge/
    vaultwarden/
    qbittorrent/
    linkwarden/
    beszel/
    inpx_web/
  infra/               ← host-level setup, not stack-based
    server_base/
    docker/
    install_ca_cert/
    openwrt_base/
    openwrt_adblock/
  common/              ← shared utilities (stays top-level for Ansible default lookup)

playbooks/services/
  meta/
    postgres.yml
    meilisearch.yml    ← future
  infra/
    step_ca.yml
    traefik.yml
    portainer.yml
    portainer_edge.yml
    vaultwarden.yml
    qbittorrent.yml
    linkwarden.yml
    beszel.yml
    inpx_web.yml
```

| Folder | What goes there | Examples |
|--------|-----------------|----------|
| `roles/meta/` | Shared infrastructure consumed by other services via hostname | postgres, meilisearch |
| `roles/services/` | Application deployments (may depend on meta) | linkwarden, vaultwarden, qbittorrent, beszel, inpx_web |
| `roles/infra/` | Host-level setup, not stack-based | server_base, docker, install_ca_cert, openwrt_* |
| `roles/common/` | Shared utilities (CNAME registration, etc.) — stays top-level for Ansible default lookup |

**Requires:** Update `ansible.cfg` roles path or role imports to account for subdirectories. Validate with `--list-tasks` after move.

### Networking model

Docker daemon is configured with custom DNS (`lan_dns`) — containers resolve `.lan` hostnames through the router. This means:
- Cross-stack communication uses **host-level DNS**, not Docker internal DNS
- No need for shared compose networks between stacks
- `network_mode: host` stays where required (traefik, beszel agent)

### Meta-services (shared infrastructure)

Standalone stacks in `roles/meta/`, not bundled into any service. Other stacks connect by hostname via daemon DNS:

| Meta-service | Current users | Port | Connection pattern |
|-------------|---------------|------|--------------------|
| **postgres** | linkwarden (+ external projects) | 5432 | `postgresql://db.lan_domain:port/dbname` |
| **meilisearch** | linkwarden (for now) | 7700 | `http://meili.lan_domain:port` |

Adding a new consumer = point at the hostname, no local container needed. Meilisearch extracted from linkwarden role even though it's the only current user — future-proofed from day one.

### Startup ordering

After Docker daemon restart, all stacks come up simultaneously. Without enforcement:
- Traefik starts before step-ca → ACME challenge fails → cert issuance broken (chicken/egg)
- Other services may see transient connection errors but retry on their own

**Chosen approach: init wait service in compose.**

A lightweight `alpine` container runs first, polls the dependency, then exits. The main service uses `depends_on` with `condition: service_completed_successfully`. Docker-native, survives reboots, zero systemd overhead.

Probe strategy per dependency:

| Dependent | Needs | Probe | Priority |
|-----------|-------|-------|----------|
| traefik | step-ca | HTTP GET `/health` → 200 + body check (`curl`) | 🔴 Critical — ACME chicken/egg |
| linkwarden | postgres | TCP 5432 (`nc -z`) | 🟡 Medium — noisy restarts without it |
| linkwarden | meilisearch | TCP 7700 (`nc -z`) | 🟡 Medium — app fails if search unavailable at startup |
| beszel agent | beszel hub | TCP on hub port (`nc -z`) | 🟢 Low — agent self-reconnects |

### Compose approach: Option C — Hybrid

Each role produces a `templates/docker-compose.yml.j2`. Tasks deploy via `community.docker.docker_compose_v2` with `project_src` pointing to the rendered template directory. Role defaults/vars control image tags, ports, volumes, environment.

**Why:** Docker-native syntax + Ansible flexibility for env-specific values. Compose files are human-readable and runnable manually (`docker compose -f ...`).

**Note on future evolution:** C → A (full Jinja2 templating) is a minimal migration path — template already exists, just add more `{{ vars }}`/conditionals as roles need them. Starting with values-only keeps things simple; go deeper only when a role actually demands it.

## Migration batches

Split by risk — simple single-containers first, core infra last. Each batch is a separate sub-plan (007-1 through 007-7).

| Batch | Plan | Roles | Containers | Rationale |
|-------|------|-------|-----------|-----------|
| **007-0** | Directory structure reorg + meilisearch extraction | all roles moved, meilisearch split from linkwarden | — | Establish new folder layout. Extract meilisearch role from linkwarden. Update imports in `servers.yml`. Validate with `--list-tasks`. Zero functional change — pure refactor. |
| **007-1** | Simple single-containers | postgres, vaultwarden, qbittorrent | 3 | Low risk, easy rollback. Proves the pattern works in new structure. No cross-stack dependencies to worry about. Postgres promoted to meta-service status. |
| **007-2** | Infra management | portainer (+ portainer_edge) | 2 | Validates compose for management tools. Edge agent has different deployment pattern — good test case. |
| **007-3** | Split-role service | beszel (hub + agent) | 2 | Tests multi-role awareness. Agent uses host network — validates that compose handles mixed networking. Add wait-for-hub probe on agent side. |
| **007-4** | Meilisearch meta-service | meilisearch (new standalone role from 007-0 extraction) | 1 | Standalone full-text search stack. Simple single-container, but establishes the pattern for new meta-services. Published port + daemon DNS for consumers. |
| **007-5** | Application with meta deps | linkwarden | 1 (app only) + wait services | Meilisearch removed to own stack (done in 007-0). No custom Docker network needed — all comms via host DNS. Wait-for-postgres + wait-for-meilisearch probes. `docker_container_exec` for db_init → convert to entrypoint script or init container. Significantly simpler than current state. |
| **007-6** | Core infra (order-critical) | step_ca, traefik | 2 (+ wait service) | ACME networking quirks. Traefik stays on host network. Wait-for-stepca init service in traefik compose. Last because everything depends on them — migrate after pattern is proven. |
| **007-7** | Custom build pipeline | inpx_web | 1 + build step | Standalone concern. Requires `docker_build` task before compose deploy (or Dockerfile-based image reference). Different workflow from the rest. |

### Batch execution order

```
007-0 → 007-1 → 007-2 → 007-3 → 007-4 → 007-5 → validate full stack → 007-6 → 007-7
```

Each batch: migrate one role, test `docker compose config` output, deploy, verify service works. Rollback is simply reverting to previous commit + running old playbook.

## Per-batch checklist

For each role migration:
1. [ ] Create `templates/docker-compose.yml.j2` from current `docker_container` task
2. [ ] Replace `community.docker.docker_container` with `community.docker.docker_compose_v2`
3. [ ] Move volume/network definitions into compose (remove standalone `docker_network` tasks)
4. [ ] Handle `docker_container_exec` — convert to entrypoint script, init container, or post-deploy task
5. [ ] Add wait-for-X service if cross-stack dependency exists
6. [ ] Verify with `docker compose config` → diff against current running state
7. [ ] Deploy, test service functionality
8. [ ] Remove old handler (`Restart <service>` via `docker_container`)

## Risks and mitigations

| Risk | Mitigation |
|------|-----------|
| Directory reorg breaks role imports | 007-0 is zero-functional-change — validate with `--list-tasks` before any compose migration begins |
| `docker_compose_v2` differs from CLI in edge cases (volume lifecycle, network creation) | Test each batch thoroughly; compose files are committed and auditable |
| Traefik ACME with step-ca has host-network quirks | Keep traefik on `network_mode: host`; wait-for-stepca enforces ordering |
| Portainer Edge agent uses different deployment pattern (API-based registration) | Migrate in 007-2 early; validate edge connectivity before proceeding |
| `docker_container_exec` tasks (linkwarden db_init, step_ca trust) don't map to compose directly | Convert to init containers or post-deploy Ansible tasks (`community.docker.docker_compose_v2` + separate exec task) |
| Role becomes unusable standalone during migration | Migrate incrementally per batch; each commit is a working state |

## Rollback

Each batch is independent. To roll back: revert the role's tasks/handlers/templates to pre-migration state, run the service playbook again. Old `docker_container` modules remain available in Ansible — no dependency on compose being "all or nothing."
