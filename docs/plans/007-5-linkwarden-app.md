# 007-5: Linkwarden application — meta dependencies + db_init

## Parent plan

[007-migrate-to-docker-compose.md](007-migrate-to-docker-compose.md) — Migrate from `docker_container` to Docker Compose

## Status

- [ ] Create compose template for linkwarden app (single container)
- [ ] Add wait-for-postgres probe
- [ ] Add wait-for-meilisearch probe
- [ ] Convert docker_container_exec db_init to entrypoint or init container
- [ ] Remove custom Docker network tasks
- [ ] Update handlers
- [ ] Validate and deploy

## Motivation

Linkwarden is the most complex current service: 3 containers (app + meilisearch), custom Docker network, and `docker_container_exec` for database initialization. After 007-0 extracts meilisearch to its own stack, linkwarden becomes a single-container app with two cross-stack dependencies (postgres + meilisearch). This batch tests the full pattern: compose deployment + wait-for probes + db init conversion.

## Role

| Component | Container | Notes |
|-----------|-----------|-------|
| Linkwarden app | 1 | Single container; traefik labels for reverse proxy |
| Meilisearch | *(removed, now in meta/meilisearch)* | Connected via `meili.lan_domain:port` |
| Postgres DB init | *(converted from docker_container_exec)* | Init container or entrypoint script |

## Implementation steps

### Step 1: Create `templates/docker-compose.yml.j2`

```yaml
services:
  wait-for-postgres:
    image: alpine
    restart: "no"
    command: sh -c "until nc -z db.{{ lan_domain }} {{ postgres_port }}; do sleep 3; done"

  wait-for-meilisearch:
    image: alpine
    restart: "no"
    command: sh -c "until nc -z meili.{{ lan_domain }} {{ meilisearch_port }}; do sleep 3; done"

{% if linkwarden_db_init | default(true) %}
  db-init:
    image: "{{ postgres_image_name }}:{{ postgres_image_tag }}"
    restart: "no"
    environment:
      PGPASSWORD: "{{ linkwarden_db_password }}"
    command: >
      sh -c "until pg_isready -h db.{{ lan_domain }} -p {{ postgres_port }}; do sleep 2; done &&
             psql -h db.{{ lan_domain }} -p {{ postgres_port }} -U linkwarden -d postgres -c 'CREATE DATABASE linkwarden;' || true"
{% endif %}

  linkwarden:
    image: "{{ linkwarden_image_name }}:{{ linkwarden_image_tag }}"
    restart: unless-stopped
    depends_on:
      wait-for-postgres:
        condition: service_completed_successfully
      wait-for-meilisearch:
        condition: service_completed_successfully
      db-init:
        condition: service_completed_successfully
    volumes:
      - "{{ linkwarden_data_dir }}/data:/data/data"
    env_file: "{{ linkwarden_data_dir }}/.env"
    labels:
      traefik.enable: "true"
      traefik.http.routers.linkwarden.rule: "Host(`{{ linkwarden_cname }}.{{ lan_domain }}`)"
      traefik.http.routers.linkwarden.entrypoints: "websecure"
      traefik.http.routers.linkwarden.tls: "true"
      traefik.http.routers.linkwarden.tls.certresolver: "step-ca"
      traefik.http.services.linkwarden.loadbalancer.server.port: "3000"
```

### Step 2: Convert docker_container_exec db_init

Current `tasks/db_init.yml` uses `docker_container_exec` to run SQL commands inside the postgres container. With compose, we can't exec into another stack's container easily. Two options:

**Option A — Init container with pg client:**
A one-shot service in linkwarden's compose that connects to postgres via hostname and creates the database/user. Uses official postgres image (has `pg_isready` + `psql` built-in). Runs once, exits.

**Option B — Keep as Ansible task post-deploy:**
Run db_init as a separate ansible step after compose deploy, using `community.docker.docker_compose_v2.exec` or direct `postgresql_db` module against the host port.

Decision: **Option A** (init container) keeps everything in one compose file. If postgres image is already pulled on the host, no extra download needed.

### Step 3: Remove custom Docker network tasks

Current role creates a "linkwarden" Docker network for internal DNS resolution between app and meilisearch. With meilisearch extracted to its own stack and all communication via host-level DNS (daemon `lan_dns`), this network is no longer needed.

Remove from `tasks/deploy.yml`:
```yaml
- name: Ensure linkwarden Docker network exists
  community.docker.docker_network:
    name: linkwarden
    state: present
```

### Step 4: Update .env template

Already updated in 007-0 (MEILI_HOST changed to hostname). Verify no other internal DNS references remain.

## Per-role specifics

### Linkwarden app

- **Single container** after meilisearch extraction — significantly simpler than current state
- **Traefik labels**: Stay as-is; traefik discovers containers via Docker socket, works with compose
- **env_file**: Rendered by ansible before compose deploy (current behavior, no change)
- **Wait-for probes**: TCP checks on postgres (`db.lan_domain:5432`) and meilisearch (`meili.lan.domain:7700`)

### DB init (converted from exec to container)

- Uses official postgres image — already present if postgres meta-service is deployed
- Connects via hostname to the shared postgres stack
- `|| true` on CREATE DATABASE so it's idempotent (doesn't fail if db exists)
- `restart: "no"` — runs once per compose up, doesn't restart

## Validation

```bash
# Deploy linkwarden
ansible-playbook playbooks/servers.yml --tags linkwarden

# Verify containers
docker compose -f /path/to/linkwarden/compose.yml ps  # all services exited/running as expected

# Verify app reaches dependencies
curl -s https://linkwarden.lan_domain/api/v1/auth  # should respond (not 502)

# Verify no orphan "linkwarden" Docker network
docker network ls | grep linkwarden  # should be empty after migration
```

## Affected files

| File | Change |
|------|--------|
| `roles/services/linkwarden/tasks/deploy.yml` | Replace docker_container with compose template + docker_compose_v2; remove meilisearch container task (done in 007-0); remove docker_network task |
| `roles/services/linkwarden/tasks/db_init.yml` | **Remove** — converted to init container in compose |
| `roles/services/linkwarden/templates/docker-compose.yml.j2` | **New** — compose file with wait probes + db-init + app |
| `roles/services/linkwarden/handlers/main.yml` | Update restart handler to use docker_compose_v2 |

## Risks

| Risk | Mitigation |
|------|-----------|
| DB init container can't reach postgres (auth/network) | Test psql connectivity from host first; verify postgres accepts connections on published port, not just localhost |
| `pg_isready` / `psql` not available in postgres image variant | Official postgres image includes both. Verify image tag matches between meta/postgres role and init container. |
| Traefik discovers linkwarden container before it's ready (502 errors) | Normal behavior — traefik retries health checks. Wait probes ensure DB/search are up, app startup is fast after that. |
| Custom "linkwarden" Docker network has lingering state | `docker network rm linkwarden` after migration; or let compose clean it up on first deploy (no services reference it anymore) |

## Rollback

Revert role files, run service playbook. Linkwarden data dir is bind mount — survives deployment method change. If rollback happens before meilisearch meta-service is stable, temporarily restore inline meilisearch container in linkwarden compose (revert 007-0 extraction for this role only).
