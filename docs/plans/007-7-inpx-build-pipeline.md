# 007-7: Inpx-web custom build pipeline

## Parent plan

[007-migrate-to-docker-compose.md](007-migrate-to-docker-compose.md) — Migrate from `docker_container` to Docker Compose

## Status

- [ ] Create compose template for inpx_web
- [ ] Handle docker build step (before or alongside compose deploy)
- [ ] Replace docker_container with docker_compose_v2
- [ ] Update handlers
- [ ] Validate and deploy

## Motivation

Inpx-web is the only service that builds its own Docker image (custom Dockerfile, npm/node build steps). Unlike other roles that pull pre-built images from registries, this role runs `docker_build` before deploying. This batch tests how compose handles locally-built images and validates the build-then-deploy workflow.

## Role

| Component | Container(s) | Notes |
|-----------|-------------|-------|
| inpx_web | 1 + docker build step | Custom Dockerfile; node:lts base, git clone sources, npm build |

## Implementation steps

### Step 1: Determine image reference strategy

Two options for referencing the locally-built image in compose:

**Option A — Compose `build` directive:**
```yaml
services:
  inpx-web:
    build:
      context: "{{ inpx_web_dockerfile_dir }}"
      dockerfile: Dockerfile
    restart: unless-stopped
    # ... ports, volumes, env
```

Compose handles the build automatically on `up`. Rebuilds only when Dockerfile/context changes (or force with `--build`).

**Option B — Separate ansible `docker_build` task:**
Keep current `tasks/build.yml` as-is. Compose references the image by name:tag:
```yaml
services:
  inpx-web:
    image: "{{ inpx_web_image_name }}:{{ inpx_web_image_tag }}"
    restart: unless-stopped
    # ... ports, volumes, env
```

Ansible builds → Ansible deploys via compose. Two-step but explicit control over build timing.

Decision needed — lean toward **Option B** (separate task) because:
- Current build logic has conditional steps and cache management already in ansible
- `docker_compose_v2` build handling can be finicky with context paths on Windows/Ansible controller
- Explicit separation: build only when Dockerfile changes, deploy always

### Step 2: Create `templates/docker-compose.yml.j2`

```yaml
services:
  inpx-web:
    image: "{{ inpx_web_image_name }}:{{ inpx_web_image_tag }}"
    restart: unless-stopped
    ports:
      - "{{ inpx_web_port }}:80"
    volumes:
      - "{{ inpx_web_data_dir }}/data:/srv/data"
{% if inpx_web_env %}
    environment:
{%- for key, value in inpx_web_env.items() %}
      {{ key }}: "{{ value }}"
{%- endfor %}
{% endif %}
```

### Step 3: Keep build task separate

Current `tasks/build.yml` uses `community.docker.docker_image`:
```yaml
- name: Build inpx-web image
  community.docker.docker_image:
    name: "{{ inpx_web_image_name }}:{{ inpx_web_image_tag }}"
    source: build
    build:
      path: "{{ inpx_web_dockerfile_dir }}"
      dockerfile: Dockerfile
    force_source: "{{ inpx_web_force_rebuild | default(false) }}"
```

This stays unchanged. Compose deploy runs after build task completes, referencing the same image name:tag.

### Step 4: Replace deploy task

Current `tasks/deploy.yml` uses `docker_container`. Replace with compose template + `docker_compose_v2`. Order in role: build → deploy (compose).

## Per-role specifics

### Inpx-web

- **Build step**: Separate ansible task, runs before compose deploy. Image name:tag must match between build and compose.
- **Force rebuild**: Controlled by `inpx_web_force_rebuild` var — works with current `docker_image` module, no change needed.
- **No cross-stack dependencies** — standalone service
- **Traefik labels**: If behind reverse proxy (check current config), labels stay the same in compose

## Validation

```bash
# Build + deploy
ansible-playbook playbooks/servers.yml --tags inpx_web

# Verify image exists and container runs
docker images | grep inpx-web  # should show the built image
docker ps | grep inpx-web      # should be running

# Test service
curl -s http://inpx.lan_domain:{{ inpx_web_port }}  # or through traefik if proxied
```

## Affected files

| File | Change |
|------|--------|
| `roles/services/inpx_web/tasks/deploy.yml` | Replace docker_container with compose template + docker_compose_v2 |
| `roles/services/inpx_web/tasks/build.yml` | No change (stays as separate ansible task) |
| `roles/services/inpx_web/templates/docker-compose.yml.j2` | **New** — compose file referencing pre-built image |
| `roles/services/inpx_web/handlers/main.yml` | Update restart handler to use docker_compose_v2 |

## Risks

| Risk | Mitigation |
|------|-----------|
| Compose tries to pull image instead of using local build | Image name:tag must match exactly between build task and compose. Use `pull: missing` or no pull policy — image is local. |
| Build context path differs on controller vs target host | `docker_image.build.path` uses ansible facts (absolute paths). Compose doesn't do the build — only references result. No conflict. |
| Force rebuild not triggered after Dockerfile change | Current ansible logic handles this via `force_source` var. Unchanged in migration. |

## Rollback

Revert role files, run service playbook. Inpx-web data dir is bind mount — survives deployment method change. Built image remains in local registry until explicitly removed (`docker rmi`). Old docker_container task pulls from same local image.
