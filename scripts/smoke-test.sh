#!/usr/bin/env bash
# End-to-end smoke test through the *advertised* addresses (HOST_IP),
# i.e. the same path external clients use.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

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
docker exec kafka-1 $K/kafka-topics.sh --bootstrap-server "$BOOT" \
  --create --if-not-exists --topic smoke-test --partitions 6 --replication-factor 3
docker exec kafka-1 $K/kafka-topics.sh --bootstrap-server "$BOOT" --describe --topic smoke-test

MSG="hello-$(date +%s)"
echo "$MSG" | docker exec -i kafka-1 $K/kafka-console-producer.sh \
  --bootstrap-server "$BOOT" --topic smoke-test --producer-property acks=all
got=$(docker exec kafka-1 $K/kafka-console-consumer.sh --bootstrap-server "$BOOT" \
  --topic smoke-test --from-beginning --timeout-ms 15000 2>/dev/null | grep -c "$MSG" || true)
[ "$got" -ge 1 ] && echo "  ok  consumed $MSG" || { echo "FAIL: message not consumed"; exit 1; }

echo "All smoke tests passed."
