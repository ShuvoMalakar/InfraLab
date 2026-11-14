# InfraLab

Shared infrastructure that runs on one GCP Ubuntu VM in Docker. Your other projects connect to it instead of each running their own copy.

| Service | Topology | Ports |
|---|---|---|
| Redis Cluster | 3 masters, no replicas (sharded, no failover) | 7001–7003 (client), 17001–17003 (cluster bus) |
| Kafka (KRaft) | 3 nodes, each both broker and controller; RF=3, min.insync=2 | 9092–9094 (external), 29092 (internal) |
| RedisInsight | web UI | 5540 |
| Kafka UI (kafbat) | web UI | 8080 |

> This is a lab setup. All nodes share one VM, so you get real Redis sharding and Kafka replication/failover between nodes, but nothing survives the VM itself going down.

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

## How to START everything (step by step)

### Part A: First time only (do once)

**Step 1. GCP console / gcloud, from your laptop**
1. Make the VM's internal IP **static**: VPC network → IP addresses → your VM's internal IP → **Promote to static**. Redis and Kafka store this IP, so it must never change.
2. Create the firewall rule. It allows the Redis and Kafka ports **only from inside your VPC**:
   ```bash
   gcloud compute firewall-rules create infralab-internal \
     --network=default --direction=INGRESS --action=ALLOW \
     --rules=tcp:7001-7003,tcp:9092-9094 \
     --source-ranges=10.128.0.0/9 --target-tags=infralab
   gcloud compute instances add-tags <VM_NAME> --tags=infralab --zone=<ZONE>
   ```
3. Do **not** open any of these ports to the public internet. Only SSH stays public.

**Step 2. SSH into the VM and clone the repo**
```bash
git clone https://<github-user>@github.com/ShuvoMalakar/InfraLab.git ~/InfraLab
cd ~/InfraLab
```

**Step 3. Run the VM setup script**
```bash
sudo ./bootstrap/vm-setup.sh
```
This installs Docker and Tailscale, tunes the kernel, creates the `infra-net` network, and writes `.env` with `HOST_IP`, a Redis password and the Kafka cluster ID.

**Step 4. Log out and SSH back in**, so your user can run `docker` without `sudo`.
```bash
exit
# then SSH into the VM again
docker ps        # must work without sudo
```

**Step 5. Connect the VM to Tailscale** (needed only for laptop access)
```bash
sudo tailscale up --advertise-routes=10.128.0.0/20   # use your own VPC subnet range
```
Open the login link it prints. Then, at https://login.tailscale.com/admin/machines, find the VM, click **…**, choose **Edit route settings**, and approve the subnet.

**Step 6. On your laptop:** install Tailscale (`brew install --cask tailscale`) and log in with the **same** Tailscale account.

### Part B: Start the services (first time, and any time after stopping)

Run these on the VM, in this order:
```bash
cd ~/InfraLab

# 1. Start Redis Cluster (3 masters). The init job forms the cluster on first run.
make up SERVICE=redis-cluster

# 2. Start Kafka (3 brokers) and Kafka UI
make up SERVICE=kafka

# 3. Check that all containers are running
make status

# 4. Check cluster health (Redis cluster_state, Kafka quorum)
make health

# 5. Run the end-to-end test (Redis set/get, Kafka produce/consume)
make smoke
```
`make up` with no `SERVICE` starts both services in this same order.

Kafka needs about 30–60 seconds to become healthy. If `make health` fails right after starting, wait a minute and run it again.

**Check from your laptop** (Tailscale must be connected):
- `redis-cli -c -h <HOST_IP> -p 7001 -a <REDIS_PASSWORD> cluster info`
- Kafka UI: `http://<HOST_IP>:8080`
- RedisInsight: `http://<HOST_IP>:5540`

`HOST_IP` and `REDIS_PASSWORD` are in `~/InfraLab/.env` on the VM: `cat ~/InfraLab/.env`.

---

## How to STOP everything

Pick the level you need. Levels 1–3 **keep your data**. Level 4 **deletes it**.

**Level 1: Stop one service** (data kept)
```bash
cd ~/InfraLab
make down SERVICE=kafka           # stops kafka-1..3 and Kafka UI
make down SERVICE=redis-cluster   # stops redis-1..3 and RedisInsight
```

**Level 2: Stop all services** (data kept)
```bash
cd ~/InfraLab
make down
make status    # should list nothing
```
Start again later with Part B above.

**Level 3: Stop the whole VM to save GCP cost** (data kept)
```bash
cd ~/InfraLab && make down        # on the VM first, so everything shuts down cleanly
gcloud compute instances stop <VM_NAME> --zone=<ZONE>    # from your laptop, or use the GCP console
```
After you start the VM again, SSH in and run Part B.

If you stop or reboot the VM **without** running `make down` first, the containers start again automatically at boot (`restart: unless-stopped`).

**Level 4: Delete everything, including all data** ⚠️ cannot be undone
```bash
cd ~/InfraLab
make nuke SERVICE=kafka            # asks y/N, then deletes Kafka topics and messages
make nuke SERVICE=redis-cluster    # asks y/N, then deletes all Redis keys
docker network rm infra-net        # optional: remove the shared network too
```
Run `make up` afterwards to get a fresh, empty cluster.

---

## Daily commands (quick reference)
| Command | What it does |
|---|---|
| `make up` | Start everything (Redis, then Kafka) |
| `make up SERVICE=kafka` | Start one service |
| `make down` | Stop everything, keep data |
| `make down SERVICE=kafka` | Stop one service, keep data |
| `make status` | List running containers |
| `make health` | Check Redis and Kafka cluster health |
| `make smoke` | End-to-end test |
| `make logs SERVICE=kafka` | Follow a service's logs (Ctrl+C to exit) |
| `make pull` | Download newer images, after changing versions in `.env` |
| `git pull && make up` | Apply changes pushed from your laptop |
| `make nuke SERVICE=<name>` | ⚠️ Stop **and delete all data** of a service |

**Failover drills:**
- **Redis:** there are no replicas, so stopping a node (`docker stop redis-1`) makes the keys in its slots unavailable. The other two masters keep serving their keys (`cluster-require-full-coverage no`). When you run `docker start redis-1`, it comes back with its data from its AOF file.
- **Kafka:** `docker stop kafka-2`. Producing with `acks=all` keeps working. Then run `docker start kafka-2`.

**If `HOST_IP` ever changes**, the Redis cluster state goes stale. Either run `make nuke SERVICE=redis-cluster && make up SERVICE=redis-cluster`, or avoid the problem by using a static internal IP.

## Memory budget (16 GB VM)
| Component | Limit |
|---|---|
| Redis (3 × 384 MB, `maxmemory` 256 MB) | ~1.2 GB |
| Kafka (3 × 1 GB, heap 512 MB) | ~3 GB |
| RedisInsight (256 MB) + Kafka UI (384 MB) | ~0.6 GB |
| OS / Docker | ~1.5 GB |
| **Headroom** | **~9.5 GB** |

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
services/redis-cluster/        3 master nodes + init job + RedisInsight
services/kafka/                3 KRaft nodes + Kafka UI
services/_template/            starting point for new services
scripts/healthcheck.sh         cluster health
scripts/smoke-test.sh          end-to-end test
```
