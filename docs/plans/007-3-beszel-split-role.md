# 007-3: Beszel split-role service — hub + agent

## Parent plan

[007-migrate-to-docker-compose.md](007-migrate-to-docker-compose.md) — Migrate from `docker_container` to Docker Compose

## Status

- [ ] Create compose template for beszel hub
- [ ] Create compose template for beszel agent (host network)
- [ ] Replace docker_container with docker_compose_v2
- [ ] Add wait-for-hub probe on agent side
- [ ] Update handlers
- [ ] Validate and deploy

## Motivation

Beszel has two parts: hub (monitoring server) and agent (runs on each host, reports to hub). They're in the same role but separate task files (`hub.yml`, `agent.yml`). This batch tests multi-part service migration and validates that compose handles mixed networking (hub on bridge, agent on host network).

## Roles

| Component | Task file | Container | Network mode | Notes |
|-----------|-----------|-----------|-------------|-------|
| Hub | `tasks/hub.yml` | 1 | default bridge + published port | Monitoring server UI |
| Agent | `tasks/agent.yml` | 1 | **host** (to reach hub on other hosts) | Reports metrics to hub |

## Implementation steps

### Beszel hub

Standard migration:

```yaml
services:
  beszel-hub:
    image: "{{ beszel_hub_image_name }}:{{ beszel_hub_image_tag }}"
    restart: unless-stopped
    ports:
      - "{{ beszel_port }}:8080"
    volumes:
      - "{{ beszel_data_dir }}/hub:/data"
```

### Beszel agent

Uses `network_mode: host`. In compose, this maps to top-level `network_mode` on the service (not `ports`). Agent connects to hub via hostname (`beszel.lan_domain:port`) — resolves through daemon DNS.

**Wait-for-hub probe:** Agent starts before hub is ready → connection errors in logs. Add init container that polls hub port:

```yaml
services:
  wait-for-hub:
    image: alpine
    restart: "no"
    command: sh -c "until nc -z beszel.lan_domain {{ beszel_port }}; do sleep 3; done"

  beszel-agent:
    depends_on:
      wait-for-hub:
        condition: service_completed_successfully
    network_mode: host
    environment:
      LISTEN: "45876"
      HUB_URL: "http://beszel.lan_domain:{{ beszel_port }}"
      TOKEN: "{{ beszel_token }}"
      KEY: "{{ beszel_hub_key }}"
      DISK_USAGE_CACHE: "{{ beszel_disk_cache }}"
```

**Note:** `network_mode: host` on the agent means the wait container also runs with host networking (compose applies it per-service, not globally). Actually — need to verify: does `depends_on` work when one service has `network_mode: host` and another doesn't? The wait container uses default bridge, agent uses host. They're separate services in same project — should be fine, but validate.

Alternative if `depends_on` + mixed networking causes issues: use `restart: on-failure` instead of `unless-stopped` on the agent, letting it retry until hub is up. Less elegant but simpler.

## Per-component specifics

### Hub

- Published port for UI access
- Data volume (host bind mount) for metrics storage
- Traefik labels for reverse proxy (if behind traefik — check current config)

### Agent

- **Host network required** — agent needs to reach hub on other hosts via LAN DNS; also binds local port for GPU collector
- **GPU_COLLECTOR env var**: Conditional (`nvml` if nvidia_gpu). Keep as Jinja2 in template.
- **Wait-for-hub**: TCP probe on `beszel.lan_domain:{{ beszel_port }}`. Only needed if hub and agent deploy simultaneously (same playbook run). If hub is already running, agent starts fine without wait.

## Validation

```bash
# Hub
ansible-playbook playbooks/servers.yml --tags beszel --check
curl -s http://beszel.lan_domain:{{ beszel_port }}/health  # or equivalent endpoint

# Agent (after hub migration)
docker ps | grep beszel-agent  # should be running, no repeated restarts
```

## Affected files

| File | Change |
|------|--------|
| `roles/services/beszel/tasks/hub.yml` | Replace docker_container with compose template + docker_compose_v2 |
| `roles/services/beszel/tasks/agent.yml` | Replace docker_container with compose template + docker_compose_v2 |
| `roles/services/beszel/templates/docker-compose-hub.yml.j2` | **New** — hub compose file |
| `roles/services/beszel/templates/docker-compose-agent.yml.j2` | **New** — agent compose file (with wait-for-hub) |
| `roles/services/beszel/handlers/main.yml` | Update restart handler(s) to use docker_compose_v2 |

## Risks

| Risk | Mitigation |
|------|-----------|
| `depends_on` + mixed network_mode in same compose project | Test locally; fallback to `restart: on-failure` if issues arise |
| Agent loses connection during hub restart | Agent reconnects automatically; transient gap in metrics only |
| GPU_COLLECTOR conditional breaks template rendering | Keep Jinja2 for env var; test with and without nvidia_gpu flag |

## Rollback

Revert role files, run service playbook. Hub data dir is bind mount — survives deployment method change. Agent re-registers on restart if needed (uses static token/key from vault).
