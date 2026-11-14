#!/usr/bin/env bash
# End-to-end smoke test through the *advertised* addresses (HOST_IP),
# i.e. the same path external clients use.
set -euo pipefail
cd "$(dirname "$0")/.."
HOST_IP=$(grep -E '^HOST_IP=' .env | cut -d= -f2-)

echo "== Redis: write/read keys that hash to different shards"
for k in user:1 order:42 session:abc cart:7 product:99; do
  docker exec redis-1 redis-cli -c -h "$HOST_IP" -p 7001 SET "smoke:$k" "v-$k" >/dev/null
  v=$(docker exec redis-1 redis-cli -c -h "$HOST_IP" -p 7002 GET "smoke:$k" | tr -d '\r')
  slot=$(docker exec redis-1 redis-cli -h "$HOST_IP" -p 7001 CLUSTER KEYSLOT "smoke:$k" | tr -d '\r')
  [ "$v" = "v-$k" ] || { echo "FAIL $k"; exit 1; }
  echo "  ok  smoke:$k  slot=$slot"
done
docker exec redis-1 redis-cli -c -h "$HOST_IP" -p 7001 DEL smoke:user:1 >/dev/null

echo "== Kafka: create topic, produce, consume via EXTERNAL listener"
K=/opt/kafka/bin
BOOT="$HOST_IP:9092,$HOST_IP:9093,$HOST_IP:9094"
docker exec -e KAFKA_HEAP_OPTS=-Xmx128m kafka-1 $K/kafka-topics.sh --bootstrap-server "$BOOT" \
  --create --if-not-exists --topic smoke-test --partitions 6 --replication-factor 3
docker exec -e KAFKA_HEAP_OPTS=-Xmx128m kafka-1 $K/kafka-topics.sh --bootstrap-server "$BOOT" --describe --topic smoke-test

MSG="hello-$(date +%s)"
echo "$MSG" | docker exec -i -e KAFKA_HEAP_OPTS=-Xmx128m kafka-1 $K/kafka-console-producer.sh \
  --bootstrap-server "$BOOT" --topic smoke-test --producer-property acks=all
got=$(docker exec -e KAFKA_HEAP_OPTS=-Xmx128m kafka-1 $K/kafka-console-consumer.sh --bootstrap-server "$BOOT" \
  --topic smoke-test --from-beginning --timeout-ms 15000 2>/dev/null | grep -c "$MSG" || true)
[ "$got" -ge 1 ] && echo "  ok  consumed $MSG" || { echo "FAIL: message not consumed"; exit 1; }

if docker ps --format '{{.Names}}' | grep -q '^cassandra-1$'; then
  echo "== Cassandra: write via node 1 (:9042), read via node 3 (:9044), RF=3, QUORUM"
  CQ="cassandra-$(date +%s)"
  docker exec cassandra-1 cqlsh "$HOST_IP" 9042 -e "
    CREATE KEYSPACE IF NOT EXISTS infralab_smoke
      WITH replication = {'class': 'NetworkTopologyStrategy', 'dc1': 3};
    CREATE TABLE IF NOT EXISTS infralab_smoke.kv (id text PRIMARY KEY, v text);
    CONSISTENCY QUORUM;
    INSERT INTO infralab_smoke.kv (id, v) VALUES ('smoke', '$CQ');" >/dev/null
  got=$(docker exec cassandra-1 cqlsh "$HOST_IP" 9044 -e "
    CONSISTENCY QUORUM;
    SELECT v FROM infralab_smoke.kv WHERE id = 'smoke';" | grep -c "$CQ" || true)
  [ "$got" -ge 1 ] && echo "  ok  read back $CQ" || { echo "FAIL: Cassandra value not read back"; exit 1; }
fi

echo "All smoke tests passed."
