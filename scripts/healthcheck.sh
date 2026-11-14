#!/usr/bin/env bash
# Quick status of Redis Cluster and Kafka. Run on the VM.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
FAILED=0

echo "Redis Cluster"
info=$(docker exec redis-1 redis-cli -h "$HOST_IP" -p 7001 cluster info 2>/dev/null | tr -d '\r')
grep -q 'cluster_state:ok' <<<"$info" && ok "cluster_state:ok" || fail "cluster_state not ok"
size=$(awk -F: '/^cluster_size/{print $2}' <<<"$info")
[ "$size" = "3" ] && ok "3 masters own slots" || fail "cluster_size=$size (want 3)"
nodes=$(docker exec redis-1 redis-cli -p 7001 cluster nodes 2>/dev/null)
m=$(grep -c 'master' <<<"$nodes" || true)
[ "$m" = "3" ] && ok "3 master nodes" || fail "masters=$m (want 3)"
grep -q 'fail' <<<"$nodes" && fail "some node is flagged fail" || ok "no failed nodes"

echo "Kafka"
for n in 1 2 3; do
  if docker exec "kafka-$n" /opt/kafka/bin/kafka-broker-api-versions.sh \
       --bootstrap-server "kafka-$n:29092" >/dev/null 2>&1; then ok "kafka-$n reachable"
  else fail "kafka-$n unreachable"; fi
done
quorum=$(docker exec kafka-1 /opt/kafka/bin/kafka-metadata-quorum.sh \
  --bootstrap-server kafka-1:29092 describe --status 2>/dev/null)
if [ -n "$quorum" ]; then
  ok "KRaft quorum: $(grep -E 'LeaderId' <<<"$quorum" | tr -s ' ')"
else
  fail "cannot describe KRaft quorum"
fi
urp=$(docker exec kafka-1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka-1:29092 \
  --describe --under-replicated-partitions 2>/dev/null | grep -c 'Topic:' || true)
[ "$urp" = "0" ] && ok "no under-replicated partitions" || fail "$urp under-replicated partitions"

exit $FAILED
