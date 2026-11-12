#!/bin/sh
# Renders redis.conf from environment, then starts redis-server.
# Required env: NODE_PORT, HOST_IP, REDIS_PASSWORD, REDIS_MAXMEMORY
set -eu

: "${NODE_PORT:?}" "${HOST_IP:?}" "${REDIS_PASSWORD:?}" "${REDIS_MAXMEMORY:=512mb}"
BUS_PORT=$((NODE_PORT + 10000))
mkdir -p /usr/local/etc

cat > /usr/local/etc/redis.conf <<EOF
port ${NODE_PORT}
bind 0.0.0.0
protected-mode no
dir /data

cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 5000
cluster-port ${BUS_PORT}
cluster-announce-ip ${HOST_IP}
cluster-announce-port ${NODE_PORT}
cluster-announce-bus-port ${BUS_PORT}

requirepass ${REDIS_PASSWORD}
masterauth ${REDIS_PASSWORD}

appendonly yes
maxmemory ${REDIS_MAXMEMORY}
maxmemory-policy allkeys-lru
EOF

chmod 644 /usr/local/etc/redis.conf
# The image's entrypoint fixes /data ownership and drops root before starting redis.
exec docker-entrypoint.sh redis-server /usr/local/etc/redis.conf
