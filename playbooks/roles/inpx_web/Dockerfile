FROM node:lts-slim

# System deps: converters + supervisor + zip
RUN apt-get update && apt-get install -y --no-install-recommends \
    git zip unzip \
    supervisor \
    calibre \
    libreoffice-core libreoffice-writer \
    poppler-utils \
    djvulibre-bin \
    libtiff-tools \
    graphicsmagick \
    unrar-free \
    && rm -rf /var/lib/apt/lists/*

# Build inpx-web
RUN git clone --depth=1 https://github.com/bookpauk/inpx-web.git /srv/inpx-web
WORKDIR /srv/inpx-web
RUN npm ci && npm run build:client && node build/prepkg.js linux && \
    rm -f server/config/application_env

# Build liberama
RUN git clone --depth=1 https://github.com/bookpauk/liberama.git /srv/liberama
WORKDIR /srv/liberama
RUN npm ci && npm run build:client && node build/prepkg.js linux && \
    rm -f server/config/application_env

COPY supervisord.conf /etc/supervisor/conf.d/apps.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 12380 44080

ENTRYPOINT ["/entrypoint.sh"]
