#!/usr/bin/env bash
# Installs a systemd timer that regenerates the status page every 30 seconds.
#   sudo ./scripts/install-status-timer.sh            # install / update
#   sudo ./scripts/install-status-timer.sh --remove   # uninstall
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }

UNIT=infralab-status
if [ "${1:-}" = "--remove" ]; then
  systemctl disable --now "$UNIT.timer" 2>/dev/null || true
  rm -f "/etc/systemd/system/$UNIT.service" "/etc/systemd/system/$UNIT.timer"
  systemctl daemon-reload
  echo "Removed $UNIT timer."
  exit 0
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_USER="${SUDO_USER:?run this with sudo from your normal user (it must be in the docker group)}"
OUT="$REPO_DIR/services/status-page/www/index.html"

cat > "/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=InfraLab status page generator
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
User=$RUN_USER
ExecStart="$REPO_DIR/scripts/status.sh" --html "$OUT"
EOF

cat > "/etc/systemd/system/$UNIT.timer" <<EOF
[Unit]
Description=Refresh InfraLab status page every 30s

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "$UNIT.timer"
systemctl start "$UNIT.service"
echo "Installed. Page file: $OUT"
echo "Check: systemctl list-timers $UNIT.timer   |   journalctl -u $UNIT.service -n 20"
