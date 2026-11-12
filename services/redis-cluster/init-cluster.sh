#!/bin/sh
# Idempotent cluster bootstrap. Auth comes from REDISCLI_AUTH.
set -eu
: "${HOST_IP:?}"

NODES=""
for p in 7001 7002 7003 7004 7005 7006; do NODES="$NODES ${HOST_IP}:$p"; done

state=$(redis-cli -h "$HOST_IP" -p 7001 cluster info | tr -d '\r' | awk -F: '/^cluster_state/{print $2}')
slots=$(redis-cli -h "$HOST_IP" -p 7001 cluster info | tr -d '\r' | awk -F: '/^cluster_slots_assigned/{print $2}')

if [ "$state" = "ok" ]; then
  echo "Cluster already formed (cluster_state:ok). Nothing to do."
  exit 0
fi

if [ "${slots:-0}" != "0" ]; then
  echo "Slots already assigned but cluster_state=$state. Nodes may still be converging."
  echo "Check: redis-cli -h $HOST_IP -p 7001 cluster nodes"
  exit 1
fi

echo "Creating cluster:$NODES"
# shellcheck disable=SC2086
redis-cli --cluster create $NODES --cluster-replicas 1 --cluster-yes

echo "Waiting for cluster_state:ok ..."
i=0
until redis-cli -h "$HOST_IP" -p 7001 cluster info | grep -q 'cluster_state:ok'; do
  i=$((i + 1)); [ "$i" -gt 30 ] && { echo "Timed out"; exit 1; }
  sleep 1
done
echo "Redis Cluster ready."
