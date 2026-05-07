# 007-8: Service Healthchecks — audit + create missing

## Parent plan

[007-migrate-to-docker-compose.md](007-migrate-to-docker-compose.md) — Migrate from `docker_container` to Docker Compose

## Status

- [x] Audit all services for existing healthcheck support
- [x] Create compose template healthchecks where missing
- [x] Update deploy tasks with `wait: true` + `wait_timeout`

## Motivation

Docker Compose supports `healthcheck` which enables:
1. **Ansible `docker_compose_v2.wait: true`** — waits for container to become healthy before returning (reliable than `state: present`)
2. **Traefik health-aware routing** — only routes traffic to healthy backends
3. **Automatic restart on failure** — Docker can restart unhealthy containers automatically

Currently, migrated services rely on:
- Manual wait tasks (`uri` module polling HTTP) — fragile and slow
- `docker_compose_v2.wait: true` without healthchecks — just waits for "running" state, not application readiness
- No service-level health monitoring in the compose layer

## Scope

Audit all services and create healthchecks where applicable.

**When:** Audit will begin after 007-6 (step-ca + traefik) is complete — core infra must be stable before auditing downstream services.

> **Note:** Every service that gets a healthcheck must also have `wait: true` added to its `docker_compose_v2` deploy task. Without it, compose returns as soon as the container is "running" and ignores the healthcheck entirely.

## Implementation steps

### Step 1: Audit existing healthchecks

Check each service's compose template for `healthcheck:` key. Document what exists vs what's missing.

```bash
grep -r "healthcheck" playbooks/roles/*/templates/docker-compose.yml.j2
```

### Step 2: Create healthchecks where missing

For services without native health endpoints, use port/HTTP probes:

**PostgreSQL** (highest priority — dependency for vaultwarden + linkwarden):
```yaml
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U postgres"]
  interval: 10s
  timeout: 5s
  retries: 5
  start_period: 30s
```

**Meilisearch**:
```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:7700/health"]
  interval: 10s
  timeout: 5s
  retries: 5
  start_period: 30s
```

**Vaultwarden**:
```yaml
healthcheck:
  test: ["CMD-SHELL", "curl -f http://localhost:8085/health || exit 1"]
  interval: 10s
  timeout: 5s
  retries: 5
  start_period: 30s
```

**Beszel Hub**:
```yaml
healthcheck:
  test: ["CMD-SHELL", "curl -f http://localhost:8090/ || exit 1"]
  interval: 10s
  timeout: 5s
  retries: 5
  start_period: 30s
```

### Step 3: Update deploy tasks with `wait`

For services that are dependencies (postgres, meilisearch), add to compose task:
```yaml
community.docker.docker_compose_v2:
  project_src: "{{ svc_opt_dir }}"
  files:
    - docker-compose.yml
  state: present
  pull: missing
  wait: true          # NEW — wait for healthcheck success
  wait_timeout: 300   # NEW — max seconds to wait (5 min)
```

For services with dependents waiting on them, also add `depends_on` with condition in the compose template.

### Step 4: Update dependent services' depends_on

Services that depend on health-checked services should use:
```yaml
depends_on:
  postgres:
    condition: service_healthy
  meilisearch:
    condition: service_healthy
```

Replace `service_completed_successfully` (wait-for probes) with `service_healthy` where appropriate.

## Validation

```bash
# Full deploy
ansible-playbook playbooks/servers.yml --tags postgres,meilisearch,vaultwarden,beszel,linkwarden,qbittorrent

# Verify healthchecks are running
docker compose -f /opt/ansible/<svc>/docker-compose.yml ps  # check STATUS column for "healthy"

# Manual health test
docker exec <container> pg_isready -U postgres   # postgres
curl -s http://localhost:7700/health | jq .      # meilisearch
```

## Risks

| Risk | Mitigation |
|------|------------|
| Healthcheck makes deploy slow (start_period + retries) | Use reasonable start_period (30-60s for heavy services like postgres); keep intervals at 10s |
| HTTP health endpoints not available on all images | Some images don't expose health checks — use port probes as fallback (`curl -f http://localhost:<port>`) |
| `wait: true` causes deploy to hang if service never becomes healthy | Set adequate `wait_timeout`; monitor first run carefully; can remove per-service later if needed |

## Affected files (tentative)

| File | Change |
|------|--------|
| All migrated compose templates (`templates/docker-compose.yml.j2`) | Add `healthcheck:` section where applicable |
| All deploy tasks for dependency services | Add `wait: true` + `wait_timeout` to `docker_compose_v2` task |
| linkwarden compose template | Update depends_on conditions from `service_completed_successfully` → `service_healthy` |

## Rollback

Revert role files, run service playbook. Healthchecks are additive — removing them has no side effects on existing containers (Docker ignores unknown healthcheck keys).
