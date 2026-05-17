# 007-3: Beszel split-role service — hub + agent

## Parent plan

[007-migrate-to-docker-compose.md](007-migrate-to-docker-compose.md) — Migrate from `docker_container` to Docker Compose

## Status: ⏸️ Hub complete, agent partially migrated — 1 bug + 1 task

### Beszel hub ✅ Complete
- [x] Split into `beszel_hub` + `beszel` roles (done as part of 007-0 restructure)
- [x] Create compose template (`roles/services/beszel_hub/templates/docker-compose.yml.j2`)
- [x] Update handler to docker_compose_v2
- [x] Register CNAME via `include_role: common, tasks_from: register_cname`
- [x] HUB_URL in agent uses `{{ beszel_hub_cname }}` (not hardcoded)

### Beszel agent ✅ Complete
- [x] Split agent into separate role (`roles/services/beszel/`)
- [x] Create compose template (`roles/services/beszel/templates/docker-compose.yml.j2`)
- [x] Deploy task uses `docker_compose_v2` with correct `beszel_agent_opt_dir`
- [x] Fix handler variable: `beszel_hub_opt_dir` → `beszel_agent_opt_dir` (007-9)


### Compose template content (current):
- Image: conditional on `nvidia_gpu` flag (`beszel_agent_image_nvidia_name` vs `beszel_agent_image_name`)
- Volumes: docker.sock (ro), data dir, extra volumes loop
- Environment: LISTEN 45876, HUB_URL via `{{ beszel_hub_cname }}`, TOKEN, KEY, GPU_COLLECTOR
- GPU support: `deploy.resources.reservations.devices` with nvidia driver + `cap_add`
- Labels: `io.beszel.agent: "true"`, `io.beszel.hostname: {{ inventory_hostname }}`
- **Missing**: wait-for-hub probe, `restart: on-failure` fallback

## Motivation

Beszel has two parts: hub (monitoring server) and agent (runs on each host, reports to hub). They're in the same role but separate task files (`hub.yml`, `agent.yml`). This batch tests multi-part service migration.

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

Agent connects to hub via hostname (`beszel.lan_domain:port`) — resolves through daemon DNS.

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
    environment:
      LISTEN: "45876"
      HUB_URL: "http://beszel.lan_domain:{{ beszel_port }}"
      TOKEN: "{{ beszel_token }}"
      KEY: "{{ beszel_hub_key }}"
      DISK_USAGE_CACHE: "{{ beszel_disk_cache }}"
```

Alternative if `depends_on` causes issues: use `restart: on-failure` instead of `unless-stopped` on the agent, letting it retry until hub is up. Less elegant but simpler.

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
ansible-playbook playbooks/servers.yml --tags beszel_hub,beszel_agent --check
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
| `depends_on` condition not respected by all Docker versions | Use wait-for-hub probe as fallback; test with `docker compose ps beszel-agent` |
| Agent loses connection during hub restart | Agent reconnects automatically; transient gap in metrics only |
| GPU_COLLECTOR conditional breaks template rendering | Keep Jinja2 for env var; test with and without nvidia_gpu flag |

---

## Next Steps — Fix agent bugs before validation

### 1. Fix handler variable (`roles/services/beszel/handlers/main.yml`)
```yaml
# Change:
project_src: "{{ beszel_hub_opt_dir }}"
# To:
project_src: "{{ beszel_agent_opt_dir }}"
```

### 2. Add wait-for-hub probe (optional — only needed if hub + agent deploy simultaneously)
```yaml
services:
  wait-for-hub:
    image: alpine:3.23
    restart: "no"
    command: >
      sh -c "until nc -z {{ beszel_hub_cname }}.{{ lan_domain }} {{ beszel_port | string }}; do sleep 3; done"

  beszel-agent:
    depends_on:
      wait-for-hub:
        condition: service_completed_successfully
```

### 3. Consider `restart: on-failure` for agent
If hub restarts, the agent may temporarily lose connection. Using `restart: on-failure` with a short backoff lets Docker handle reconnection automatically.

## Rollback

Revert role files, run service playbook. Hub data dir is bind mount — survives deployment method change. Agent re-registers on restart if needed (uses static token/key from vault).
