FROM oven/bun:1.3.14-alpine

ARG DGLAB_SERVER_COMMIT=497645525a9ec4e159587d3f2c463d7399ba17e5

RUN apk add --no-cache git \
    && git init /opt/dglab-websocket-server \
    && cd /opt/dglab-websocket-server \
    && git remote add origin https://github.com/dungeonlab-open/dglab-websocket-server.git \
    && git fetch --depth 1 origin "${DGLAB_SERVER_COMMIT}" \
    && git checkout --detach FETCH_HEAD \
    && rm -rf .git

WORKDIR /opt/dglab-websocket-server

ENV PORT=9998 \
    PREFIX=/ \
    LOG_LEVEL=info \
    IDLE_TIMEOUT=300000 \
    HEARTBEAT_INTERVAL=30000 \
    WS_PING_INTERVAL=10000 \
    MAX_MISSED_WS_PONGS=3

EXPOSE 9998

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD bun -e 'const r=await fetch("http://127.0.0.1:9998/");process.exit(r.status===426?0:1)' || exit 1

CMD ["bun", "run", "v4-server.ts"]
