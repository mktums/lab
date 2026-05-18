# ── Stage 1: Build standalone binaries ────────────────────────────────
FROM node:lts-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git zip unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Build inpx-web → dist/linux/inpx-web (pkg standalone binary)
RUN cd /build && git clone --depth=1 https://github.com/bookpauk/inpx-web.git inpx-web
WORKDIR /build/inpx-web
RUN npm install && npm run build:linux

# Build liberama → dist/linux/liberama (pkg standalone binary)
RUN cd /build && git clone --depth=1 https://github.com/bookpauk/liberama.git liberama
WORKDIR /build/liberama
RUN npm install && npm run build:linux

# ── Stage 2: Runtime — conversion tools + compiled binaries ───────────
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
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

# Copy only compiled binaries (no source, no node_modules)
COPY --from=builder /build/inpx-web/dist/linux/inpx-web /srv/inpx-web
COPY --from=builder /build/liberama/dist/linux/liberama /srv/liberama

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 12380 44080

ENTRYPOINT ["/entrypoint.sh"]
