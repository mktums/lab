# 007-4: Meilisearch meta-service

## Parent plan

[007-migrate-to-docker-compose.md](007-migrate-to-docker-compose.md) — Migrate from `docker_container` to Docker Compose

## Status

- [ ] Create compose template for meilisearch
- [ ] Replace docker_container with docker_compose_v2
- [ ] Update handlers
- [ ] Validate and deploy

## Motivation

Meilisearch is extracted from the linkwarden role (done in 007-0) into its own standalone meta-service. Even though linkwarden is the only current consumer, this establishes the pattern for future services that need full-text search. Simple single-container migration — straightforward compose file with published port and data volume.

## Role

| Component | Path | Container | Notes |
|-----------|------|-----------|-------|
| meilisearch | `roles/meta/meilisearch/` | 1 | Published port 7700, data volume, API key env var |

## Implementation steps

### Step 1: Create `templates/docker-compose.yml.j2`

```yaml
services:
  meilisearch:
    image: "{{ meilisearch_image_name }}:{{ meilisearch_image_tag }}"
    restart: unless-stopped
    ports:
      - "{{ meilisearch_port }}:7700"
    volumes:
      - "{{ meilisearch_data_dir }}/meilisearch:/meili_data"
    environment:
      MEILI_MASTER_KEY: "{{ meilisearch_master_key }}"
      MEILI_NO_ANALYTICS: "true"
```

### Step 2: Replace deploy task

Current (extracted from linkwarden role in 007-0):
```yaml
- name: Deploy Meilisearch container
  community.docker.docker_container:
    ...
```

Becomes:
```yaml
- name: Render compose file
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: "{{ meilisearch_data_dir }}/docker-compose.yml"
    mode: "0644"

- name: Deploy Meilisearch stack
  community.docker.docker_compose_v2:
    project_src: "{{ meilisearch_data_dir }}"
    state: present
```

### Step 3: Update handler

```yaml
- name: Restart meilisearch
  community.docker.docker_compose_v2:
    project_src: "{{ meilisearch_data_dir }}"
    state: present
```

## Per-role specifics

### Meilisearch

- **No cross-stack wait needed** — it's a meta-service (dependency, not consumer)
- **Published port**: `{{ meilisearch_port }}:7700` (consumers connect via `meili.lan_domain:port`)
- **Data volume**: Host bind mount for index persistence
- **MEILI_MASTER_KEY**: From vault; consumers use this to authenticate
- **No traefik labels** — accessed directly by services via HTTP, not through reverse proxy

## Linkwarden consumer update (done in 007-0)

Linkwarden's `.env` template must reference meilisearch by hostname instead of Docker internal DNS:

```diff
-MEILI_HOST=http://meilisearch:7700
+MEILI_HOST=http://meili.{{ lan_domain }}:{{ meilisearch_port }}
```

This change is made during the 007-0 extraction, not here. By the time this batch runs, linkwarden already points at the new hostname.

## Validation

```bash
# Deploy meilisearch
ansible-playbook playbooks/servers.yml --tags meilisearch

# Verify it responds
curl -s http://meili.lan_domain:{{ meilisearch_port }}/health

# Verify linkwarden can reach it (if already migrated)
docker exec linkwarden curl -s http://meili.lan.domain:7700/health  # or equivalent check
```

## Affected files

| File | Change |
|------|--------|
| `roles/meta/meilisearch/tasks/main.yml` | Replace docker_container with compose template + docker_compose_v2 |
| `roles/meta/meilisearch/templates/docker-compose.yml.j2` | **New** — compose file template |
| `roles/meta/meilisearch/handlers/main.yml` | Update restart handler to use docker_compose_v2 |

## Risks

| Risk | Mitigation |
|------|-----------|
| Linkwarden can't reach meilisearch after migration | Hostname change done in 007-0; validate linkwarden connectivity before marking this batch complete |
| Meili data dir path differs from current (was under linkwarden_data_dir) | Migration script/data move needed if paths differ. Plan: use same path initially, normalize later. |

## Rollback

Revert role files, run service playbook. Meilisearch index data is bind mount — survives deployment method change. If rollback needed after 007-5 (linkwarden compose), also temporarily revert linkwarden's MEILI_HOST to Docker internal DNS or ensure meilisearch stays up during transition.
