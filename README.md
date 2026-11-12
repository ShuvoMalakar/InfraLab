# InfraLab

Shared infrastructure that runs on one GCP Ubuntu VM in Docker. Your other projects connect to it instead of each running their own copy.

| Service | Topology | Ports |
|---|---|---|
| Redis Cluster | 3 masters + 3 replicas (sharded, automatic failover) | 7001–7006 (client), 17001–17006 (cluster bus) |
| Kafka (KRaft) | 3 nodes, each both broker and controller; RF=3, min.insync=2 | 9092–9094 (external), 29092 (internal) |
| RedisInsight | web UI | 5540 |
| Kafka UI (kafbat) | web UI | 8080 |

> This is a lab setup. All nodes share one VM, so you get real sharding, replication and failover between nodes, but nothing survives the VM itself going down.

---

## Connecting from your projects

`HOST_IP` is the VM's **internal VPC IP**, set in `.env`. Both clusters advertise this one address, so it works from every client location listed below.

### Redis Cluster
Always use a **cluster-aware client**. A plain client fails on `MOVED` redirects.

| Where the app runs | Seed nodes | Password |
|---|---|---|
| Container on this VM (on `infra-net`) | `HOST_IP:7001,HOST_IP:7002,HOST_IP:7003` | `REDIS_PASSWORD` |
| Other GCP VM / GKE (same VPC) | same as above | same |
| Laptop (over Tailscale) | same as above | same |

```js
// Node (ioredis)
new Redis.Cluster([{ host: HOST_IP, port: 7001 }, { host: HOST_IP, port: 7002 }],
                  { redisOptions: { password: process.env.REDIS_PASSWORD } });
```
```python
# Python (redis-py)
from redis.cluster import RedisCluster
r = RedisCluster(host=HOST_IP, port=7001, password=REDIS_PASSWORD)
```
```go
// Go (go-redis)
redis.NewClusterClient(&redis.ClusterOptions{Addrs: []string{HOST_IP+":7001", HOST_IP+":7002"}, Password: pw})
```
Spring Boot: `spring.data.redis.cluster.nodes=HOST_IP:7001,HOST_IP:7002,HOST_IP:7003`

### Kafka
| Where the app runs | `bootstrap.servers` |
|---|---|
| Container on this VM (on `infra-net`) | `kafka-1:29092,kafka-2:29092,kafka-3:29092` |
| Other GCP VM / GKE / laptop | `HOST_IP:9092,HOST_IP:9093,HOST_IP:9094` |

Topics are **not** created automatically (`auto.create.topics.enable=false`). Create them explicitly, from Kafka UI or like this:
```bash
docker exec kafka-1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka-1:29092 \
  --create --topic orders --partitions 6 --replication-factor 3
```
Producers should set `acks=all`. With `min.insync.replicas=2`, writes keep working while one broker is down.

### App container on the same VM
```yaml
# in your project's docker-compose.yml
services:
  my-app:
    networks: [infra-net]
networks:
  infra-net:
    external: true
```

---

## First-time setup

### 1. GCP (one time)
- **Static internal IP:** reserve the VM's internal IP as static. It is baked into the Redis cluster state and the Kafka metadata.
- **Firewall rule:** allow TCP `7001-7006,9092-9094` **only** from your VPC CIDR and your GKE node/pod ranges:
  ```bash
  gcloud compute firewall-rules create infralab-internal \
    --network=default --direction=INGRESS --action=ALLOW \
    --rules=tcp:7001-7006,tcp:9092-9094 \
    --source-ranges=10.128.0.0/9 --target-tags=infralab
  gcloud compute instances add-tags <VM_NAME> --tags=infralab --zone=<ZONE>
  ```
- **Public internet:** open nothing beyond SSH. Reach the UIs and data ports from your laptop over Tailscale.

### 2. On the VM
```bash
git clone <this repo> ~/InfraLab && cd ~/InfraLab
sudo ./bootstrap/vm-setup.sh                         # Docker, sysctl, THP, Tailscale, .env
sudo tailscale up --advertise-routes=10.128.0.0/20   # your VPC subnet; approve it in the Tailscale admin
# log out and back in so the docker group applies
make up        # starts redis-cluster, then kafka
make health
make smoke
```

### 3. On your laptop
Install Tailscale, log in to the same tailnet, and turn on accepting routes (`tailscale up --accept-routes` on Linux; macOS accepts routes by default in the app). After that, `HOST_IP` works from the laptop:
- `redis-cli -c -h HOST_IP -p 7001 -a <pw> cluster info`
- Kafka UI: `http://HOST_IP:8080`
- RedisInsight: `http://HOST_IP:5540`

---

## Operations
```bash
make up | down [SERVICE=kafka]   # start/stop all or one (data is kept)
make status                      # containers on infra-net
make logs SERVICE=redis-cluster
make health                      # cluster state, quorum, under-replicated partitions
make smoke                       # end-to-end test through HOST_IP
make nuke SERVICE=kafka          # stop and DELETE the service's volumes
```

**Failover drills:**
- **Redis:** `docker stop redis-1`. Within about 5 seconds, `cluster nodes` shows its replica promoted. Then run `docker start redis-1`, and it rejoins as a replica.
- **Kafka:** `docker stop kafka-2`. Producing with `acks=all` keeps working. Then run `docker start kafka-2`.

**If `HOST_IP` ever changes**, the Redis cluster state goes stale. Either run `make nuke SERVICE=redis-cluster && make up SERVICE=redis-cluster`, or avoid the problem by using a static internal IP.

## Memory budget (16 GB VM)
| Component | Limit |
|---|---|
| Redis (6 × 384 MB, `maxmemory` 256 MB) | ~2.3 GB |
| Kafka (3 × 1 GB, heap 512 MB) | ~3 GB |
| RedisInsight (256 MB) + Kafka UI (384 MB) | ~0.6 GB |
| OS / Docker | ~1.5 GB |
| **Headroom** | **~8.5 GB** |

Limits are set in `.env` (`REDIS_MAXMEMORY`, `REDIS_MEM_LIMIT`, `KAFKA_HEAP_OPTS`, `KAFKA_MEM_LIMIT`). Keep each container limit about 1.5–2× the Redis `maxmemory` or the Kafka heap, so there's room for overhead.

## Adding a new technology
1. Run `cp -r services/_template services/<name>` and follow the steps in its header.
2. Keep the service on `infra-net`. If external clients need it, advertise `HOST_IP` and add its port to the firewall rule.
3. Add the service to `SERVICES` in the `Makefile` and add a row to the tables above.

**Planned next:**
- Prometheus and Grafana, with redis_exporter and kafka-exporter
- SASL/SCRAM authentication and ACLs for Kafka
- Postgres

## Layout
```
bootstrap/vm-setup.sh          one-time VM preparation
services/redis-cluster/        6 nodes + init job + RedisInsight
services/kafka/                3 KRaft nodes + Kafka UI
services/_template/            starting point for new services
scripts/healthcheck.sh         cluster health
scripts/smoke-test.sh          end-to-end test
```
