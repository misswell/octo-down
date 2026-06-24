FROM node:22-slim

ENV HOST=0.0.0.0 \
    PORT=8787 \
    DOWNLOAD_DIR=/data/downloads \
    YT_DLP=/usr/local/bin/yt-dlp \
    RESOLVER_TOKEN= \
    YT_DLP_COOKIES_FILE= \
    YT_DLP_DOWNLOADER= \
    YT_DLP_DOWNLOADER_ARGS=

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        aria2 \
        ca-certificates \
        curl \
        ffmpeg \
        python3 \
    && curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
        -o /usr/local/bin/yt-dlp \
    && chmod +x /usr/local/bin/yt-dlp \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./
COPY server.mjs resolver-core.mjs ./

RUN mkdir -p /data/downloads \
    && node --check server.mjs \
    && node --check resolver-core.mjs

EXPOSE 8787

CMD ["npm", "start"]
