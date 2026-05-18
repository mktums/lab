# 008: Optimize inpx-web Dockerfile + Compose migration

**Status:** ✅ Done (2026-05-18)

## Implementation notes

Deviations from original plan:

- **`npm install` instead of `npm ci`** — liberama's lockfile caused issues in the builder container; `npm install` works reliably.
- **`ca-certificates` added to builder stage** — Russia DPI blocks GitHub TLS without system CA store.
- **`cd /build &&` before each clone** — fixed WORKDIR nesting bug where liberama cloned into `/build/inpx-web/liberama` instead of `/build/liberama`.
- **Entrypoint handles `.inpx` detection** — preserved the original supervisord logic (`find /downloads -maxdepth 1 -name "*.inpx"`) in entrypoint.sh, auto-appends `--inpx=<path>` for inpx-web service.
- **Compose uses `/downloads/{{ inpx_web_lib_dir | basename }}`** — single volume mount at `/downloads`, container path derived from inventory var via `basename` filter.

## Motivation

Current Dockerfile installs build dependencies (git, node/npm) and clones source repos, but keeps all artifacts in the final image. This bloats the image with unnecessary layers and tools not needed at runtime. Additionally, both apps run via supervisord instead of native Compose services.

### Current issues

- `git` installed but only used during build (clone sources)
- Node.js LTS base (~200MB) kept at runtime even though apps can be compiled to standalone binaries via [`pkg`](https://github.com/vercel/pkg)
- Source repos (`/srv/inpx-web`, `/srv/liberama`) remain with `node_modules/`, source code, etc.
- No multi-stage build — everything in one layer
- supervisord manages two processes instead of native Compose services (no per-service health checks, logs, restarts)

### Discovery: both repos produce standalone binaries

Both `inpx-web` and `liberama` have `npm run build:linux` scripts that use `pkg` to compile a single executable with Node.js embedded:

| Repo | Build command | Output |
|------|--------------|--------|
| inpx-web | `npm run build:linux` | `dist/linux/inpx-web` |
| liberama | `npm run build:linux` | `dist/linux/liberama` |

The current Dockerfile runs only `prepkg.js` (asset prep) and skips the actual `pkg` compilation, which is why it needs Node.js at runtime. Running `build:linux` eliminates that dependency entirely.

## Plan

### Multi-stage build + Compose services

**Stage 1 (builder):** Clone repos, run `npm ci && npm run build:linux` for each app — produces standalone binaries.

**Stage 2 (runtime):** `debian:bookworm-slim` with conversion tools only — no Node.js, no git, no source code. Copy compiled binaries from builder stage.

```dockerfile
# Stage 1: Build both apps into standalone binaries
FROM node:lts-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends git zip unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Build inpx-web
RUN git clone --depth=1 https://github.com/bookpauk/inpx-web.git inpx-web
WORKDIR /build/inpx-web
RUN npm ci && npm run build:linux

# Build liberama
RUN git clone --depth=1 https://github.com/bookpauk/liberama.git liberama
WORKDIR /build/liberama
RUN npm ci && npm run build:linux

# Stage 2: Runtime — conversion tools + compiled binaries
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    supervisor \
    calibre \
    libreoffice-core \
    poppler-utils \
    djvulibre-bin \
    libtiff-tools \
    graphicsmagick \
    unrar-free \
    zip unzip \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled binaries (no source, no node_modules)
COPY --from=builder /build/inpx-web/dist/linux/inpx-web /srv/inpx-web
COPY --from=builder /build/liberama/dist/linux/liberama /srv/liberama

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 12380 44080

ENTRYPOINT ["/entrypoint.sh"]
```

### Compose migration (replaces supervisord)

Two services sharing the same image, each with own command/healthcheck:

```yaml
services:
  inpx-web:
    image: "{{ inpx_web_image_name }}:{{ inpx_web_image_tag }}"
    restart: unless-stopped
    command: >-
      /srv/inpx-web --data-dir=/data/inpx-web --lib-dir={{ inpx_web_lib_dir }}
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:12380/ || exit 1"]
      interval: 60s
      timeout: 5s
      retries: 3
    ports:
      - "{{ inpx_web_port }}:12380"
    volumes:
      - "{{ inpx_web_data_dir }}/inpx-web:/data/inpx-web"
      - "{{ downloads_dir }}:/downloads:ro"
      - /etc/localtime:/etc/localtime:ro
    environment:
      LIB_DOMAIN: "{{ inpx_web_cname }}.{{ lan_domain }}"
    labels:
      traefik.enable: "true"
      traefik.http.routers.inpx-web.rule: "Host(`{{ inpx_web_cname }}.{{ lan_domain }}`)"
      # ... TLS + loadbalancer for port 12380

  liberama:
    image: "{{ inpx_web_image_name }}:{{ inpx_web_image_tag }}"
    restart: unless-stopped
    command: /srv/liberama --app-dir=/data/liberama
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:44080/read || exit 1"]
      interval: 60s
      timeout: 5s
      retries: 3
    ports:
      - "{{ inpx_web_liberama_port }}:44080"
    volumes:
      - "{{ inpx_web_data_dir }}/liberama:/data/liberama"
      - /etc/localtime:/etc/localtime:ro
    environment:
      LIB_DOMAIN: "{{ inpx_web_cname }}.{{ lan_domain }}"
    labels:
      traefik.enable: "true"
      traefik.http.routers.liberama.rule: "Host(`{{ inpx_web_cname }}.{{ lan_domain }}`) && PathPrefix(`/read`)"
      # ... TLS + loadbalancer for port 44080
```

### New inventory variable

| Variable | Default | Description |
|----------|---------|-------------|
| `inpx_web_lib_dir` | `{{ downloads_dir }}/Flibusta.Net` | Library directory path passed as `--lib-dir` to inpx-web |

Override per-host in `inventory/host_vars/lab2.yml` if needed.

### Files to change

| File | Change |
|------|--------|
| `files/Dockerfile` | Multi-stage build with pkg compilation, debian runtime |
| `files/supervisord.conf` | **Remove** — replaced by Compose services |
| `files/entrypoint.sh` | Keep (config init + data dirs) — no supervisord exec needed when using Compose command override |
| `templates/docker-compose.yml.j2` | Two services, each with own command/healthcheck/volumes |
| `defaults/main.yml` | Add `inpx_web_lib_dir`, remove supervisor references if any |
| `tasks/build.yml` | Update file list (remove supervisord.conf from checksum) |

## Rollback

Keep current Dockerfile as `Dockerfile.bak` in role files until optimized version is tested and confirmed working. Same for supervisord.conf → `supervisord.conf.bak`.
