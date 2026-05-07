# 007-8: Service Healthchecks — audit + create missing

## Parent plan

[007-migrate-to-docker-compose.md](007-migrate-to-docker-compose.md) — Migrate from `docker_container` to Docker Compose

## Status

- [x] Audit all services for existing healthcheck support
- [x] Create compose template healthchecks where missing
- [x] Update deploy tasks with `wait: true` + `wait_timeout`
- [x] Deploy and verify across both hosts

## Motivation

Docker Compose supports `healthcheck` which enables:
1. **Ansible `docker_compose_v2.wait: true`** — waits for container to become healthy before returning (more reliable than `state: present`)
2. **Traefik health-aware routing** — only routes traffic to healthy backends
3. **Automatic restart on failure** — Docker can restart unhealthy containers automatically

Currently, migrated services relied on:
- Manual wait tasks (`uri` module polling HTTP) — fragile and slow
- `docker_compose_v2.wait: true` without healthchecks — just waits for "running" state, not application readiness
- No service-level health monitoring in the compose layer

## Scope

Audit all services and create healthchecks where applicable.

**When:** Audit began after 007-6 (step-ca + traefik) was complete — core infra must be stable before auditing downstream services.

> **Note:** Every service that gets a healthcheck must also have `wait: true` added to its `docker_compose_v2` deploy task. Without it, compose returns as soon as the container is "running" and ignores the healthcheck entirely.

## Results

### Services with image-level healthchecks (no action needed)

| Service | Endpoint | Method |
|---------|----------|--------|
| step-ca | `step ca health` | Image default: `CMD-SHELL step ca health \| grep "^ok"` |
| vaultwarden | `/health/ready` | Image default: `CMD /healthcheck.sh` |
| postgres | `pg_isready -U postgres` :5432 | Image default: built-in HEALTHCHECK instruction |
| linkwarden | root :3000 | Image default: `curl http://127.0.0.1:3000/` |

### Services with custom healthchecks added (ours)

| Service | Endpoint | Method | Interval |
|---------|----------|--------|----------|
| traefik | `/ping` on :80 → `OK` | `CMD-SHELL wget -qO- http://localhost:80/ping \| grep -q OK` | 30s |
| portainer | `/api/system/status` :9000 | `CMD-SHELL wget --spider -q http://127.0.0.1:9000/api/system/status` | 30s |
| beszel-hub | `/beszel health --url localhost:8090` | `CMD /beszel health --url http://localhost:8090` | 120s |
| beszel-agent | `/agent health` | `CMD /agent health` | 120s |
| qbittorrent | root → HTTP 200 :8080 | `CMD-SHELL wget --server-response -qO /dev/null \| grep "HTTP/1.1 200"` | 60s |
| meilisearch | `/health` → `{"status":"available"}` :7700 | `CMD-SHELL wget -qO- http://127.0.0.1:7700/health \| grep -q available` | 30s |
| inpx-web | inpx `:12380/` + liberama `:44080/read` | `CMD-SHELL curl -sf http://localhost:12380/ && curl -sf http://localhost:44080/read` | 60s |

### Services without healthchecks (unavoidable)

| Service | Reason |
|---------|--------|
| portainer-edge | Portainer agent has no documented health endpoint. Listens on obscure ports (:9001 for WebSocket to main, :9005 internal API with no standard routes). The maintainers chose not to expose any healthcheck mechanism — a container that's "running" is all they consider healthy. You can't verify the agent is actually functional from inside or outside its own network namespace without hitting undocumented internals. |

## Key findings

- **portainer CE v2.39** removed `/system/status` endpoint (moved to `/api/system/status`) — had to fix existing healthcheck
- **traefik** required `--ping.entryPoint=web` CLI flag to reuse port 80 instead of default :8080 (which conflicted with qbittorrent)
- **inpx-web** CRLF line endings from Windows autocrlf caused entrypoint crash (`#!/bin/sh\r`) — fixed with `.gitattributes eol=lf`
- **beszel_hub** was deploying on both hosts due to `beszel_agent` pulling it as meta dependency — fixed with internal block guard

## Affected files

| File | Change |
|------|--------|
| `playbooks/roles/services/portainer/templates/docker-compose.yml.j2` | Fixed healthcheck endpoint `/api/system/status` |
| `playbooks/roles/services/traefik/tasks/deploy.yml` | Added `--ping.entryPoint=web` + healthcheck block |
| `playbooks/roles/services/beszel_hub/templates/docker-compose.yml.j2` | Added healthcheck using binary command |
| `playbooks/roles/services/beszel_agent/templates/docker-compose.yml.j2` | Added healthcheck using binary command |
| `playbooks/roles/services/qbittorrent/templates/docker-compose.yml.j2` | Added HTTP status code check |
| `playbooks/roles/meta/meilisearch/templates/docker-compose.yml.j2` | Added health endpoint grep check |
| `playbooks/roles/services/inpx_web/templates/docker-compose.yml.j2` | Added dual-service curl check |
| `.gitattributes` | Added `* text eol=lf` to prevent CRLF issues |

## Rollback

Revert role files, run service playbook. Healthchecks are additive — removing them has no side effects on existing containers (Docker ignores unknown healthcheck keys).
