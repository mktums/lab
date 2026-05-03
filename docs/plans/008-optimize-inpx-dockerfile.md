# 008: Optimize inpx-web Dockerfile

## Motivation

Current Dockerfile installs build dependencies (git, node/npm) and clones source repos, but keeps all artifacts in the final image. This bloats the image with unnecessary layers and tools not needed at runtime.

### Current issues

- `git` installed but only used during build (clone sources)
- `zip`/`unzip` — **keep at runtime**: liberama uses `unzip` for CBR/CBZ comic reading, `zip` status TBD (check liberama docs)
- Node.js LTS base + npm used for building, apps run as pre-built binaries after
- Source repos (`/srv/inpx-web`, `/srv/liberama`) remain with `node_modules/`, source code, etc.
- No multi-stage build — everything in one layer

## Plan

### Option A: Multi-stage build (cleanest)

```dockerfile
# Stage 1: Build both apps
FROM node:lts-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends git zip unzip
WORKDIR /build
RUN git clone --depth=1 https://github.com/bookpauk/inpx-web.git && \
    cd inpx-web && npm ci && npm run build:client && node build/prepkg.js linux
RUN git clone --depth=1 https://github.com/bookpauk/liberama.git && \
    cd liberama && npm ci && npm run build:client && node build/prepkg.js linux

# Stage 2: Runtime
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    supervisor calibre libreoffice-core poppler-utils graphicsmagick unrar-free \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/inpx-web /srv/inpx-web
COPY --from=builder /build/liberama /srv/liberama
# ... supervisord, entrypoint
```

### Option B: Single-stage with cleanup (simpler)

Keep current structure but add cleanup step after builds:
```dockerfile
RUN rm -rf /srv/inpx-web/node_modules /srv/inpx-web/src \
    /srv/liberama/node_modules /srv/liberama/src \
    && apt-get remove --purge -y git zip unzip nodejs npm \
    && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
```

## Recommendation

**Option A (multi-stage)** — standard Docker practice, smaller image, cleaner separation of build/runtime concerns.

## Rollback

Keep current Dockerfile as `Dockerfile.bak` in role files until optimized version is tested and confirmed working.
