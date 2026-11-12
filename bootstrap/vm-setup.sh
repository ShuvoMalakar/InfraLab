#!/usr/bin/env bash
# One-time setup for the InfraLab GCP VM (Ubuntu 22.04/24.04).
#   cd InfraLab && sudo ./bootstrap/vm-setup.sh
# Safe to re-run.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_USER="${SUDO_USER:-$USER}"

echo "==> 1/6 Docker Engine + compose plugin"
if ! command -v docker >/dev/null; then
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg make openssl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
apt-get install -y make openssl >/dev/null
usermod -aG docker "$TARGET_USER"
systemctl enable --now docker

echo "==> 2/6 Kernel settings (Redis + Kafka)"
cat > /etc/sysctl.d/99-infralab.conf <<'EOF'
vm.overcommit_memory = 1
net.core.somaxconn = 1024
vm.max_map_count = 262144
vm.swappiness = 1
EOF
sysctl --system >/dev/null

echo "==> 3/6 Disable Transparent Huge Pages (Redis latency)"
cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages
Before=docker.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag'
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now disable-thp.service

echo "==> 4/6 Shared docker network: infra-net"
docker network inspect infra-net >/dev/null 2>&1 || docker network create infra-net

echo "==> 5/6 Tailscale (laptop access without public ports)"
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
echo "    Next (manual, once): sudo tailscale up --advertise-routes=<VPC subnet, e.g. 10.128.0.0/20>"
echo "    then approve the route in the Tailscale admin console."

echo "==> 6/6 .env"
ENV_FILE="$REPO_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  cp "$REPO_DIR/.env.example" "$ENV_FILE"
  HOST_IP=$(curl -fs -H 'Metadata-Flavor: Google' \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip || hostname -I | awk '{print $1}')
  REDIS_PW=$(openssl rand -hex 24)
  KAFKA_ID=$(openssl rand -base64 16 | tr '+/' '-_' | tr -d '=')
  sed -i "s|^HOST_IP=.*|HOST_IP=${HOST_IP}|; s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=${REDIS_PW}|; s|^KAFKA_CLUSTER_ID=.*|KAFKA_CLUSTER_ID=${KAFKA_ID}|" "$ENV_FILE"
  chown "$TARGET_USER" "$ENV_FILE"; chmod 600 "$ENV_FILE"
  echo "    Wrote $ENV_FILE (HOST_IP=${HOST_IP}). Keep it; KAFKA_CLUSTER_ID must never change."
else
  echo "    $ENV_FILE exists, leaving it alone."
fi

echo
echo "Done. Log out/in (docker group), then: make up && make smoke"
