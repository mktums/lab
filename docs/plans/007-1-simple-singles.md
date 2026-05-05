# 007-1: Simple single-containers — postgres, vaultwarden, qbittorrent

## Parent plan

[007-migrate-to-docker-compose.md](007-migrate-to-docker-compose.md) — Migrate from `docker_container` to Docker Compose

## Status

- [ ] Create compose templates
- [ ] Replace docker_container with docker_compose_v2
- [ ] Update handlers
- [ ] Validate and deploy

## Motivation

Low-risk entry point. Three simple single-container services with no cross-stack dependencies (other than postgres being a meta-service consumed by linkwarden — but that's handled at the consumer side, not here). Proves the compose pattern works in our new directory structure before touching anything complex.

## Roles

| Role | Path | Container | Notes |
|------|------|-----------|-------|
| postgres | `roles/meta/postgres/` | 1 | Meta-service; published port 5432, data volume |
| vaultwarden | `roles/services/vaultwarden/` | 1 | Published ports, env vars, volumes |
| qbittorrent | `roles/services/qbittorrent/` | 1 | Published ports (web + API), volumes |

## Implementation steps (per role)

### Step 1: Create `templates/docker-compose.yml.j2`

Convert current `docker_container` task into compose format. Example for postgres:

```yaml
services:
  postgres:
    image: {{ postgres_image_name }}:{{ postgres_image_tag }}
    restart: unless-stopped
    ports:
      - "{{ postgres_port }}:5432"
    volumes:
      - "{{ postgres_data_dir }}:/var/lib/postgresql/data"
    environment:
      POSTGRES_PASSWORD: "{{ postgres_password }}"
    shm_size: "{{ postgres_shm_size }}"
```

### Step 2: Replace deploy task

Current:
```yaml
- name: Deploy Postgres container
  community.docker.docker_container:
    ...
```

Becomes:
```yaml
- name: Render compose file
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: "{{ postgres_data_dir }}/docker-compose.yml"
    mode: "0644"

- name: Deploy Postgres stack
  community.docker.docker_compose_v2:
    project_src: "{{ postgres_data_dir }}"
    state: present
```

### Step 3: Update handler

Current:
```yaml
- name: Restart postgres
  community.docker.docker_container:
    name: postgres
    restart: true
```

Becomes:
```yaml
- name: Restart postgres
  community.docker.docker_compose_v2:
    project_src: "{{ postgres_data_dir }}"
    state: present
```

## Per-role specifics

### Postgres

- **No cross-stack wait needed** — it's the dependency, not the consumer
- **Volume lifecycle**: compose creates/manages volume; ensure data dir path stays consistent
- **Published port**: `{{ postgres_port }}:5432` (consumers connect via hostname + this port)

### Vaultwarden

- Straightforward migration — env vars, ports, volumes all map 1:1 to compose
- No special considerations

### Qbittorrent

- Published ports include web UI + API/dht ports
- Volumes for config + downloads
- No special considerations

## Validation

```bash
# Per role after migration:
ansible-playbook playbooks/servers.yml --tags <role> --check
docker compose -f /path/to/compose.yml config  # verify rendered output matches current state
```

Full stack validation after all three roles migrated.

## Affected files (per role)

| File | Change |
|------|--------|
| `roles/<service>/tasks/deploy.yml` | Replace `docker_container` with compose template + `docker_compose_v2` |
| `roles/<service>/templates/docker-compose.yml.j2` | **New** — compose file template |
| `roles/<service>/handlers/main.yml` | Update restart handler to use `docker_compose_v2` |

## Risks

| Risk | Mitigation |
|------|-----------|
| Compose volume naming differs from docker_container (uses project name prefix) | Data dirs use host paths (bind mounts), not named volumes — no issue |
| First deploy after migration recreates container | `docker_compose_v2` is idempotent; container restarts once, data persists via bind mount |

## Rollback

Revert role files to pre-migration state, run service playbook. Container comes back via old `docker_container` task. Bind mounts preserve data regardless of deployment method.
