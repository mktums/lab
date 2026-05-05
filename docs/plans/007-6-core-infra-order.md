# 007-6: Core infra (order-critical) — step_ca + traefik

## Parent plan

[007-migrate-to-docker-compose.md](007-migrate-to-docker-compose.md) — Migrate from `docker_container` to Docker Compose

## Status

- [ ] Create compose template for step-ca
- [ ] Create compose template for traefik (host network + wait-for-stepca)
- [ ] Replace docker_container with docker_compose_v2
- [ ] Handle step_ca trust.yml (docker_container_exec → post-deploy task)
- [ ] Update handlers
- [ ] Validate and deploy

## Motivation

The most critical batch. Step-ca and traefik form the foundation of HTTPS in the homelab — every service with `traefik.enable: "true"` depends on them. The chicken/egg problem (traefik needs step-ca for ACME, but step-ca's TLS challenge requires traefik to be listening on 443) makes startup ordering mandatory after Docker daemon restart. This batch validates the wait-for-X pattern in production conditions.

## Roles

| Component | Path | Container(s) | Network mode | Notes |
|-----------|------|-------------|-------------|-------|
| step_ca | `roles/services/step_ca/` | 1 + trust exec | bridge + published port | ACME CA server; `/health` endpoint available |
| traefik | `roles/services/traefik/` | 1 (+ wait service) | **host** (TLS-ALPN-01 requirement) | Reverse proxy; needs step-ca before first cert request |

## Implementation steps

### Step 1: Step-ca compose

```yaml
services:
  step-ca:
    image: "{{ step_ca_image_name }}:{{ step_ca_image_tag }}"
    restart: unless-stopped
    ports:
      - "{{ step_ca_port }}:9000"
    volumes:
      - "{{ step_ca_data_dir }}:/home/step"
      - "{{ step_ca_config_dir }}/secrets/password:/run/secrets/password:ro"
    environment:
      DOCKER_STEPCA_INIT_NAME: "{{ step_ca_name }}"
      DOCKER_STEPCA_INIT_DNS_NAMES: "localhost,{{ step_ca_cname }}.{{ lan_domain }},{{ inventory_hostname }}.{{ lan_domain }}"
      DOCKER_STEPCA_INIT_ACME: "true"
      DOCKER_STEPCA_INIT_PASSWORD_FILE: /run/secrets/password
```

Straightforward migration — single container, published port, volumes, env vars. No cross-stack dependencies (step-ca is the foundation).

### Step 2: Traefik compose with wait-for-stepca

Traefik uses `network_mode: host` (required for TLS-ALPN-01 challenge). The wait service runs on default bridge and polls step-ca via daemon DNS-resolved hostname.

```yaml
services:
  wait-for-stepca:
    image: alpine/curl
    restart: "no"
    command: >
      sh -c "until curl -sk https://step-ca.{{ lan_domain }}:{{ step_ca_port }}/health | grep -q ok; do sleep 3; done"

  traefik:
    image: "{{ traefik_image_name }}:{{ traefik_image_tag }}"
    restart: unless-stopped
    depends_on:
      wait-for-stepca:
        condition: service_completed_successfully
    network_mode: host
    command: >
      --global.checknewversion=false
      --global.sendanonymoususage=false
      --log.level=INFO
      --api.dashboard=true
      --entrypoints.web.address=:80
      --entrypoints.web.http.redirections.entrypoint.to=websecure
      --entrypoints.web.http.redirections.entrypoint.scheme=https
      --entrypoints.web.http.redirections.entrypoint.permanent=true
      --entrypoints.websecure.address=:443
      --providers.docker.exposedbydefault=false
      --providers.docker.watch=true
      --providers.file.filename={{ traefik_config_dir }}/traefik-dynamic.yml
      --providers.file.watch=true
      --certificatesresolvers.step-ca.acme.email={{ traefik_acme_email }}
      --certificatesresolvers.step-ca.acme.storage=/acme/acme.json
      --certificatesresolvers.step-ca.acme.caserver=https://step-ca.{{ lan_domain }}:{{ step_ca_port }}/acme/acme/directory
      --certificatesresolvers.step-ca.acme.tlschallenge=true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - "{{ traefik_config_dir }}/traefik-dynamic.yml:/traefik-dynamic.yml:ro"
      - "{{ traefik_data_dir }}/acme:/acme"
      - /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro
    labels:
      traefik.enable: "false"
```

### Step 3: Handle step_ca trust.yml (docker_container_exec)

Current `tasks/trust.yml` uses `docker_container_exec` to run commands inside the running step-ca container (e.g., certificate provisioning). With compose, this becomes a post-deploy task using either:

**Option A — `community.docker.docker_compose_v2` exec:**
```yaml
- name: Run CA trust setup in step-ca container
  community.docker.docker_compose_v2:
    project_src: "{{ step_ca_data_dir }}"
    services:
      - step-ca
    state: present
  # Then use docker_container_exec against the running container (name stays "step-ca")
```

**Option B — Keep `docker_container_exec` as-is:**
The container name doesn't change with compose migration. `docker_container_exec` targets a running container by name, regardless of how it was started. If the compose service is named `step-ca`, exec still works.

Decision: **Option B** — no change needed to trust.yml tasks. Container name stays the same, exec works against it. Only the deployment method changes (compose vs docker_container), not the container identity.

### Step 4: Update handlers

Both roles use `docker_container` restart handlers. Replace with `docker_compose_v2`:

```yaml
- name: Restart step-ca
  community.docker.docker_compose_v2:
    project_src: "{{ step_ca_data_dir }}"
    state: present

- name: Restart traefik
  community.docker.docker_compose_v2:
    project_src: "{{ traefik_config_dir }}"
    state: present
```

## Per-role specifics

### Step-ca

- **No cross-stack wait needed** — it's the foundation, nothing blocks it
- **Health endpoint**: `/health` on published port — used by traefik's wait service
- **Trust tasks (exec)**: No change needed — container name stays "step-ca"
- **Published port**: `{{ step_ca_port }}:9000` — must match what traefik's ACME config references

### Traefik

- **Host network mandatory** — TLS-ALPN-01 requires step-ca to reach host:443, not a bridge IP
- **Wait-for-stepca**: HTTP probe with body check (`/health` returns "ok"). Uses `alpine/curl` image (smaller than full alpine + apk add curl).
- **ACME config**: CLI arguments stay the same — compose doesn't change how traefik runs, only how it's deployed
- **Dynamic config file**: Rendered by ansible before compose deploy (current behavior, no change)

## Validation

```bash
# Deploy step-ca first
ansible-playbook playbooks/servers.yml --tags step_ca

# Verify health endpoint
curl -sk https://step-ca.lan_domain:{{ step_ca_port }}/health  # should return "ok"

# Deploy traefik (waits for step-ca)
ansible-playbook playbooks/servers.yml --tags traefik

# Simulate Docker restart scenario
systemctl restart docker
sleep 30
docker ps | grep -E 'traefik|step-ca'  # both should be running
curl -s https://<any-service>.lan_domain  # should return valid response (not ACME error)

# Check traefik logs for clean startup (no "certificate issuance failed" errors)
docker logs traefik | grep -i acme | tail -20
```

## Affected files

| File | Change |
|------|--------|
| `roles/services/step_ca/tasks/deploy.yml` | Replace docker_container with compose template + docker_compose_v2 |
| `roles/services/step_ca/templates/docker-compose.yml.j2` | **New** — step-ca compose file |
| `roles/services/step_ca/handlers/main.yml` | Update restart handler to use docker_compose_v2 |
| `roles/services/step_ca/tasks/trust.yml` | No change (docker_container_exec still works by container name) |
| `roles/services/traefik/tasks/deploy.yml` | Replace docker_container with compose template + docker_compose_v2 |
| `roles/services/traefik/templates/docker-compose.yml.j2` | **New** — traefik compose file (with wait-for-stepca service) |
| `roles/services/traefik/handlers/main.yml` | Update restart handler to use docker_compose_v2 |

## Risks

| Risk | Mitigation |
|------|-----------|
| Wait-for-stepca fails on first deploy (step-ca not up yet) | Playbook order ensures step_ca deploys before traefik. Wait service is a safety net for Docker restarts, not initial deploy. |
| `network_mode: host` + wait container on bridge causes compose issues | Tested pattern — services in same project can mix network modes. Wait container uses default bridge (resolves step-ca via daemon DNS), traefik uses host. No conflict. |
| ACME cert renewal fails after migration | Traefik config is identical (same CLI args, same volumes). Only deployment method changes. Monitor acme.json for new certs after first renewal cycle. |
| Downtime during migration (step-ca + traefik restart) | ~30-60 seconds per service. All existing services lose HTTPS briefly. Schedule maintenance window. |

## Rollback

Revert role files, run service playbook. Step-ca data dir and traefik acme.json are bind mounts — survive deployment method change. Existing certificates in acme.json remain valid; only container restart causes brief downtime.
