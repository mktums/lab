# 007-2: Portainer stacks — portainer + portainer_edge

## Parent plan

[007-migrate-to-docker-compose.md](007-migrate-to-docker-compose.md) — Migrate from `docker_container` to Docker Compose

## Status

- [ ] Create compose templates for portainer main
- [ ] Create compose template for portainer edge agent
- [ ] Replace docker_container with docker_compose_v2
- [ ] Update handlers
- [ ] Validate and deploy

## Motivation

Portainer is infrastructure management — if compose migration breaks it, we lose our Docker UI. Migrating early validates that compose works for management tools before proceeding to application services. Edge agent has a different deployment pattern (API-based registration with Portainer server) — good test case for non-standard setups.

## Roles

| Role | Path | Container(s) | Notes |
|------|------|-------------|-------|
| portainer | `roles/services/portainer/` | 1 (main instance) | Standard container, published ports, volumes |
| portainer_edge | `roles/services/portainer_edge/` | 1 (edge agent) | API-based registration; different env var pattern |

## Implementation steps

### Portainer main

Standard migration — convert docker_container to compose:

```yaml
services:
  portainer:
    image: "{{ portainer_image_name }}:{{ portainer_image_tag }}"
    restart: unless-stopped
    ports:
      - "{{ portainer_port }}:9000"
      - "{{ portainer_agent_port }}:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - "{{ portainer_data_dir }}:/data"
```

### Portainer Edge agent

Edge agent connects to Portainer server via API. Current deployment uses static env vars (ID, token). Migration is straightforward — same vars into compose environment block. Key consideration: edge agent must be able to reach `portainer.lan_domain:9443` via daemon DNS (already works with current setup, no change needed).

```yaml
services:
  portainer-edge-agent:
    image: "{{ portainer_edge_image_name }}:{{ portainer_edge_image_tag }}"
    restart: unless-stopped
    ports:
      - "8000:8000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      AGENT_PORT: "9001"
      EDGE_ID: "{{ portainer_edge_id }}"
      EDGE_KEY: "{{ portainer_edge_key }}"
      EDGE_IP: "{{ ansible_default_ipv4.address }}"
      EDGE_INSECURE: "true"
```

## Per-role specifics

### Portainer main

- Published ports map directly to compose `ports`
- Docker socket bind mount stays the same
- Data volume is host path (bind mount) — no lifecycle concern

### Portainer edge agent

- **API registration**: Edge agent registers with portainer server on first start. If container restarts during migration, it re-registers automatically (existing ID/key in env vars).
- **HOST_IP / EDGE_IP**: Uses `ansible_default_ipv4.address` or similar — must resolve at template render time, not runtime. Keep as Jinja2 var in compose template.
- **Network**: Default bridge is fine; reaches portainer server via daemon DNS (`portainer.lan_domain`).

## Validation

```bash
# After migration:
ansible-playbook playbooks/servers.yml --tags portainer --check
ansible-playbook playbooks/servers.yml --tags portainer_edge --check

# Verify edge agent connectivity
docker exec portainer-edge-agent curl -sk https://portainer.lan_domain:9443/api/endpoint  # should respond
```

## Affected files

| File | Change |
|------|--------|
| `roles/services/portainer/tasks/deploy.yml` | Replace docker_container with compose template + docker_compose_v2 |
| `roles/services/portainer/templates/docker-compose.yml.j2` | **New** |
| `roles/services/portainer/handlers/main.yml` | Update restart handler |
| `roles/services/portainer_edge/tasks/main.yml` | Replace docker_container with compose template + docker_compose_v2 |
| `roles/services/portainer_edge/templates/docker-compose.yml.j2` | **New** |
| `roles/services/portainer_edge/handlers/main.yml` | Update restart handler (if exists) or add one |

## Risks

| Risk | Mitigation |
|------|-----------|
| Portainer UI inaccessible during migration | Container restarts once; data persists via bind mount. Downtime ~30 seconds. |
| Edge agent loses registration on restart | Unlikely — ID/key are in env vars, auto-re-registers. Verify after deploy. |
| EDGE_IP resolves incorrectly at template time | Use `ansible_default_ipv4.address` (available during playbook run); test rendered compose file before deploy. |

## Rollback

Revert role files, run service playbook. Portainer data dir is bind mount — survives deployment method change. Edge agent re-registers on restart if needed.
