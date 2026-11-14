# InfraLab

Shared infrastructure that runs on one GCP Ubuntu VM in Docker. Your other projects connect to it instead of each running their own copy.

| Service | Topology | Ports |
|---|---|---|
| Redis Cluster | 3 masters, no replicas (sharded, no failover) | 7001–7003 (client), 17001–17003 (cluster bus) |
| Kafka (KRaft) | 3 nodes, each both broker and controller; RF=3, min.insync=2 | 9092–9094 (external), 29092 (internal) |
| Cassandra | 3 nodes, 1 datacenter (`dc1`), use RF=3 + QUORUM | 9042–9044 (CQL, one port per node) |
| RedisInsight | web UI | 5540 |
| Kafka UI (kafbat) | web UI | 8080 |
| Status page | what's up: **public**, read-only, any browser | 8090 |

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

### Cassandra
| Where the app runs | Contact points | Local DC |
|---|---|---|
| Anywhere: VM container, other GCP VM / GKE, laptop over Tailscale | `HOST_IP:9042` (add `:9043`, `:9044` as backups) | `dc1` |

All 3 nodes share one IP and use **different ports** (9042, 9043, 9044). Use a driver that reads `system.peers_v2`, so it discovers the other two ports by itself: DataStax Java driver 4.x, Python `cassandra-driver` 3.25+, gocql, or the Node.js `cassandra-driver`. An older driver still works, but it may send every request through node 1.

```python
# Python
from cassandra.cluster import Cluster
cluster = Cluster([HOST_IP], port=9042)
session = cluster.connect()
```
```java
// Java (DataStax driver 4.x)
CqlSession.builder()
  .addContactPoint(new InetSocketAddress(HOST_IP, 9042))
  .withLocalDatacenter("dc1").build();
```
Create keyspaces with RF=3 and use `QUORUM` (or `LOCAL_QUORUM`). Reads and writes then keep working while one node is down:
```sql
CREATE KEYSPACE myapp WITH replication = {'class': 'NetworkTopologyStrategy', 'dc1': 3};
```
Open a CQL shell on the VM: `docker exec -it cassandra-1 cqlsh`

There's no login yet: authentication is off, as for Kafka. The ports are reachable only inside your VPC and over Tailscale.

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
1. Make the VM's internal IP **static**: VPC network → IP addresses → your VM's internal IP → **Promote to static**. Redis, Kafka and Cassandra store this IP, so it must never change.
2. Create the firewall rule. It allows the Redis, Kafka and Cassandra ports **only from inside your VPC**. You can skip this if your VM is on the `default` network: its built-in `default-allow-internal` rule already allows this traffic.
   ```bash
   gcloud compute firewall-rules create infralab-internal \
     --network=default --direction=INGRESS --action=ALLOW \
     --rules=tcp:7001-7003,tcp:9092-9094,tcp:9042-9044 \
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

# 3. Start Cassandra (3 nodes). They join one at a time: this takes about 3-5 minutes.
make up SERVICE=cassandra

# 4. Start the status page (first time only: installs a 30s refresh timer, asks for sudo)
make status-page

# 5. See what's up (containers, Redis, Kafka, Cassandra, VM memory/disk)
make status

# 6. Check cluster health (Redis cluster_state, Kafka quorum, Cassandra ring)
make health

# 7. Run the end-to-end test (Redis set/get, Kafka produce/consume, Cassandra write/read)
make smoke
```
`make up` with no `SERVICE` starts Redis, Kafka, Cassandra and the status page in this order. You need step 3 only once: the timer keeps running across reboots.

Kafka needs about 30–60 seconds to become healthy. If `make health` fails right after starting, wait a minute and run it again.

**Check from your laptop** (Tailscale must be connected):
- `redis-cli -c -h <HOST_IP> -p 7001 -a <REDIS_PASSWORD> cluster info`
- Kafka UI: `http://<HOST_IP>:8080`
- RedisInsight: `http://<HOST_IP>:5540`
- Status page: `http://<VM external IP>:8090`. It's public, so it works without Tailscale too.

`HOST_IP` and `REDIS_PASSWORD` are in `~/InfraLab/.env` on the VM: `cat ~/InfraLab/.env`.

---

## See what's up, from any device

### Web status page: any browser, like a normal website
Open **`http://<VM external IP>:8090`** from any phone, laptop or computer. You don't need Tailscale or a login.

**One-time setup to make it public:**
1. **Reserve the external IP** so the URL never changes. Console → VPC network → IP addresses → your VM's **External** address → **Promote to static**. Or run:
   ```bash
   gcloud compute addresses create infralab-ip --addresses=<current-external-ip> --region=<REGION>
   ```
2. **Open port 8090 only**, to the internet, for this VM:
   ```bash
   gcloud compute firewall-rules create infralab-status-public \
     --network=default --direction=INGRESS --action=ALLOW \
     --rules=tcp:8090 --source-ranges=0.0.0.0/0 --target-tags=infralab-status
   gcloud compute instances add-tags <VM_NAME> --tags=infralab-status --zone=<ZONE>
   ```
3. On the VM, run `make status-page`. It prints the public URL at the end.

To find the external IP on the VM:
```bash
curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip
```

**What is public and what is not:**
- ✅ **Public:** only the status page on port 8090. It's read-only, nginx serves one static file, it accepts only GET requests, and the container has no access to Docker.
- 🔒 **Still private:** Redis (7001–7003), Kafka (9092–9094), Kafka UI (8080) and RedisInsight (5540). Kafka UI and RedisInsight have **no login**, so **never** add their ports to a public firewall rule.
- **Hidden:** the public page leaves out the internal IP and the links to the private UIs (`STATUS_PUBLIC=true` in `.env`). It still shows container names, health and VM stats.
- The page uses plain HTTP, so there's no padlock in the browser. That's fine here, because it has no password and no private data to protect. If you later want HTTPS or a login, add a domain with Caddy, or use Tailscale Funnel.

**To make it private again:**
```bash
gcloud compute firewall-rules delete infralab-status-public
```
Then set `STATUS_PUBLIC=false` in `.env`. The page is then reachable only over Tailscale, at `http://<HOST_IP>:8090`.

The page shows:
- **Overall status:** All systems up / Degraded / Problem detected.
- **Redis Cluster:** cluster state and how many of the 16384 slots are being served.
- **Kafka:** how many brokers are healthy (3/3 = ok, 2/3 = still writable, fewer = writes fail).
- **Every container on the VM**, grouped by project and including your own apps: healthy / starting / unhealthy / stopped, uptime, memory, CPU.
- **VM:** uptime, load, memory and disk.
- Links to Kafka UI and RedisInsight.

The page reloads itself every 15 seconds, and the VM regenerates it every 30 seconds. If the page turns red with "not updated for over 2 minutes", the VM or the timer is down.

How it works:
1. A systemd timer (`infralab-status.timer`) runs `scripts/status.sh --html` on the VM every 30 seconds.
2. A tiny nginx container (`status-page`, 32 MB) serves the resulting file.
3. The web container has **no access to Docker**; it only serves a static file.

### In the terminal
```bash
# on the VM
make status

# from your laptop, without opening an SSH session first
gcloud compute ssh <VM_NAME> --zone=<ZONE> -- -t '~/InfraLab/scripts/status.sh'
```

### Status page troubleshooting
```bash
systemctl list-timers infralab-status.timer      # is the timer scheduled?
journalctl -u infralab-status.service -n 20      # errors from the last runs
sudo ./scripts/install-status-timer.sh --remove  # uninstall the timer
```

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
make ps        # should list nothing
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
| `make up` | Start everything (Redis, Kafka, Cassandra, status page) |
| `make up SERVICE=kafka` | Start one service |
| `make down` | Stop everything, keep data |
| `make down SERVICE=kafka` | Stop one service, keep data |
| `make status` | What's up: containers, Redis, Kafka, Cassandra, VM resources |
| `make status-page` | Install the refresh timer and start the web status page (once) |
| `make ps` | Plain `docker ps` list of InfraLab containers |
| `make health` | Check Redis, Kafka and Cassandra cluster health |
| `make smoke` | End-to-end test |
| `make logs SERVICE=kafka` | Follow a service's logs (Ctrl+C to exit) |
| `make pull` | Download newer images, after changing versions in `.env` |
| `git pull && make up` | Apply changes pushed from your laptop |
| `make nuke SERVICE=<name>` | ⚠️ Stop **and delete all data** of a service |

**Failover drills:**
- **Redis:** there are no replicas, so stopping a node (`docker stop redis-1`) makes the keys in its slots unavailable. The other two masters keep serving their keys (`cluster-require-full-coverage no`). When you run `docker start redis-1`, it comes back with its data from its AOF file.
- **Kafka:** `docker stop kafka-2`. Producing with `acks=all` keeps working. Then run `docker start kafka-2`.
- **Cassandra:** `docker stop cassandra-2`. `QUORUM` reads and writes keep working, because 2 of the 3 replicas are still up. `nodetool status` shows the stopped node as `DN`. Then run `docker start cassandra-2`; it catches up through hinted handoff.

**If `HOST_IP` ever changes**, the Redis cluster state goes stale. Either run `make nuke SERVICE=redis-cluster && make up SERVICE=redis-cluster`, or avoid the problem by using a static internal IP.

## Memory budget (16 GB VM)
| Component | Limit |
|---|---|
| Redis (3 × 384 MB, `maxmemory` 256 MB) | ~1.2 GB |
| Kafka (3 × 1 GB, heap 512 MB) | ~3 GB |
| Cassandra (3 × 1.25 GB, heap 512 MB) | ~3.75 GB |
| RedisInsight (256 MB) + Kafka UI (384 MB) + status page (32 MB) | ~0.7 GB |
| OS / Docker | ~1.5 GB |
| **Headroom** | **~5.8 GB** |

Limits are set in `.env` (`REDIS_MAXMEMORY`, `REDIS_MEM_LIMIT`, `KAFKA_HEAP_OPTS`, `KAFKA_MEM_LIMIT`, `CASSANDRA_MAX_HEAP`, `CASSANDRA_HEAP_NEWSIZE`, `CASSANDRA_MEM_LIMIT`). Keep each container limit about 1.5–2.5× the Redis `maxmemory` or the Java heap, so there's room for overhead. Cassandra uses a lot of memory outside its heap.

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
services/cassandra/            3 Cassandra nodes (dc1)
services/status-page/          nginx serving the generated status page (:8090)
services/_template/            starting point for new services
scripts/status.sh              what's up (text, or --html for the web page)
scripts/install-status-timer.sh  systemd timer that refreshes the page every 30s
scripts/healthcheck.sh         cluster health
scripts/smoke-test.sh          end-to-end test
```
