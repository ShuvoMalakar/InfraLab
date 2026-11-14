#!/usr/bin/env bash
# What's up in InfraLab?
#
#   scripts/status.sh               colored text (on the VM, or over ssh)
#   scripts/status.sh --html FILE   writes a self-refreshing HTML status page
#
# Lists every docker compose container on the VM (including your own apps),
# plus Redis Cluster / Kafka summaries and VM resources. New services added
# under services/ show up automatically.
set -uo pipefail
cd "$(dirname "$0")/.."

MODE=text; OUT=""
case "${1:-}" in
  --html) MODE=html; OUT="${2:?usage: status.sh --html FILE}" ;;
  "")     ;;
  *)      echo "usage: status.sh [--html FILE]"; exit 2 ;;
esac

HOST_IP=""; STATUS_PUBLIC=true
[ -f .env ] && HOST_IP=$(grep -E '^HOST_IP=' .env | cut -d= -f2-)
[ -f .env ] && grep -qE '^STATUS_PUBLIC=false' .env && STATUS_PUBLIC=false
NOW=$(date '+%Y-%m-%d %H:%M:%S %Z'); NOW_EPOCH=$(date +%s)
VM_NAME=$(hostname)

# ---------- collect ----------
ROWS=$(docker ps -a --filter label=com.docker.compose.project \
  --format '{{.Label "com.docker.compose.project"}}|{{.Names}}|{{.State}}|{{.Status}}' 2>/dev/null | sort)

declare -A MEM CPU
while IFS='|' read -r n m c; do
  [ -n "$n" ] && { MEM[$n]="${m%% /*}"; CPU[$n]="$c"; }
done < <(docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}|{{.CPUPerc}}' 2>/dev/null)

# level|label from docker State + Status
classify() {
  case "$1" in
    running)
      case "$2" in
        *"(unhealthy)"*)       echo "bad|unhealthy" ;;
        *"health: starting"*)  echo "warn|starting" ;;
        *"(healthy)"*)         echo "ok|healthy" ;;
        *)                     echo "ok|running" ;;
      esac ;;
    exited)
      case "$2" in "Exited (0)"*) echo "done|completed" ;; *) echo "bad|stopped" ;; esac ;;
    restarting) echo "bad|restarting" ;;
    *)          echo "warn|$1" ;;
  esac
}

rank() { case "$1" in bad) echo 3 ;; warn) echo 2 ;; *) echo 0 ;; esac; }
WORST=ok
bump() { [ "$(rank "$1")" -gt "$(rank "$WORST")" ] && WORST="$1"; return 0; }

# Redis Cluster summary
REDIS_LVL=bad; REDIS_MSG="not running"
if info=$(docker exec redis-1 redis-cli -p 7001 cluster info 2>/dev/null | tr -d '\r') && [ -n "$info" ]; then
  st=$(awk -F: '/^cluster_state/{print $2}' <<<"$info")
  sok=$(awk -F: '/^cluster_slots_ok/{print $2}' <<<"$info")
  sfail=$(awk -F: '/^cluster_slots_fail/{print $2}' <<<"$info")
  kn=$(awk -F: '/^cluster_known_nodes/{print $2}' <<<"$info")
  if [ "$st" = "ok" ] && [ "$sok" = "16384" ]; then REDIS_LVL=ok
  elif [ "$st" = "ok" ]; then REDIS_LVL=warn
  fi
  REDIS_MSG="state=$st, slots ok=$sok/16384, failing=$sfail, nodes=$kn"
fi
bump "$REDIS_LVL"

# Kafka summary (uses the containers' own healthchecks: cheap)
kh=$(grep -cE '^kafka\|kafka-[0-9]+\|running\|.*\(healthy\)' <<<"$ROWS" || true)
kt=$(grep -cE '^kafka\|kafka-[0-9]+\|' <<<"$ROWS" || true)
if   [ "$kt" -eq 0 ];  then KAFKA_LVL=bad;  KAFKA_MSG="not running"
elif [ "$kh" -ge 3 ];  then KAFKA_LVL=ok;   KAFKA_MSG="$kh/$kt brokers healthy"
elif [ "$kh" -eq 2 ];  then KAFKA_LVL=warn; KAFKA_MSG="$kh/$kt brokers healthy (still writable, min.insync=2)"
else                        KAFKA_LVL=bad;  KAFKA_MSG="$kh/$kt brokers healthy (acks=all writes FAIL)"
fi
bump "$KAFKA_LVL"

# Cassandra summary: only shown once the service has been started at least once
CASS_LVL=""; CASS_MSG=""
ct=$(grep -cE '^cassandra\|cassandra-[0-9]+\|' <<<"$ROWS" || true)
if [ "$ct" -gt 0 ]; then
  ch=$(grep -cE '^cassandra\|cassandra-[0-9]+\|running\|.*\(healthy\)' <<<"$ROWS" || true)
  if   [ "$ch" -ge 3 ]; then CASS_LVL=ok;   CASS_MSG="$ch/$ct nodes healthy"
  elif [ "$ch" -eq 2 ]; then CASS_LVL=warn; CASS_MSG="$ch/$ct nodes healthy (QUORUM still works with RF=3)"
  else                       CASS_LVL=bad;  CASS_MSG="$ch/$ct nodes healthy (QUORUM reads/writes FAIL)"
  fi
  bump "$CASS_LVL"
fi

# VM resources
SYS_UP=$(uptime -p 2>/dev/null || echo "?")
SYS_LOAD=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "?")
SYS_MEM=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d / %d MB (%d%%)", $3, $2, $3*100/$2}')
SYS_DISK=$(df -h / 2>/dev/null | awk 'NR==2{print $3" / "$2" ("$5")"}')

while IFS='|' read -r _ _ state status; do
  [ -z "$state" ] && continue
  bump "$(classify "$state" "$status" | cut -d'|' -f1)"
done <<<"$ROWS"

# ---------- render: text ----------
render_text() {
  local G="" Y="" R="" D="" B="" N=""
  if [ -t 1 ] || [ -n "${FORCE_COLOR:-}" ]; then
    G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[90m'; B=$'\e[1m'; N=$'\e[0m'
  fi
  col() { case "$1" in ok) printf '%s' "$G";; warn) printf '%s' "$Y";; bad) printf '%s' "$R";; *) printf '%s' "$D";; esac; }
  dot() { printf '%s●%s' "$(col "$1")" "$N"; }

  printf '%sInfraLab status%s  %s  %s(%s, HOST_IP=%s)%s\n' "$B" "$N" "$(dot "$WORST")" "$D" "$NOW" "${HOST_IP:-?}" "$N"
  printf '\n%sClusters%s\n' "$B" "$N"
  printf '  %s Redis Cluster  %s\n' "$(dot "$REDIS_LVL")" "$REDIS_MSG"
  printf '  %s Kafka          %s\n' "$(dot "$KAFKA_LVL")" "$KAFKA_MSG"
  [ -n "$CASS_LVL" ] && printf '  %s Cassandra      %s\n' "$(dot "$CASS_LVL")" "$CASS_MSG"

  local last=""
  while IFS='|' read -r proj name state status; do
    [ -z "$name" ] && continue
    [ "$proj" != "$last" ] && { printf '\n%s%s%s\n' "$B" "$proj" "$N"; last="$proj"; }
    IFS='|' read -r lvl label <<<"$(classify "$state" "$status")"
    printf '  %s %-20s %s%-10s%s %-28s %s%8s %7s%s\n' "$(dot "$lvl")" "$name" "$(col "$lvl")" "$label" "$N" \
      "$status" "$D" "${MEM[$name]:--}" "${CPU[$name]:--}" "$N"
  done <<<"$ROWS"
  [ -z "$ROWS" ] && printf '\n  (no containers)\n'

  printf '\n%sVM%s  %s · up: %s · load: %s · mem: %s · disk: %s\n' "$B" "$N" "$VM_NAME" "$SYS_UP" "$SYS_LOAD" "$SYS_MEM" "$SYS_DISK"
}

# ---------- render: html ----------
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

render_html() {
  local overall_label
  case "$WORST" in ok) overall_label="All systems up";; warn) overall_label="Degraded";; *) overall_label="Problem detected";; esac
  # Public page (STATUS_PUBLIC=true): hide the internal IP and links to the
  # private, password-less admin UIs.
  local meta_ip="" links=""
  if [ "$STATUS_PUBLIC" != true ]; then
    meta_ip=" · HOST_IP $(esc "${HOST_IP:-?}")"
    links="<h2>Open</h2><div class=\"links\"><a href=\"http://$(esc "$HOST_IP"):8080\">Kafka UI</a><a href=\"http://$(esc "$HOST_IP"):5540\">RedisInsight</a></div>"
  fi
  cat <<EOF
<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="15">
<title>InfraLab Status</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--fg:#1b1f24;--mut:#6a737d;--line:#e3e6ea;--ok:#1f9d55;--warn:#d69e2e;--bad:#e53e3e;--done:#8a94a0}
@media (prefers-color-scheme:dark){:root{--bg:#0f1216;--card:#171b21;--fg:#e6e9ed;--mut:#8b949e;--line:#262c34}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
main{max-width:920px;margin:0 auto;padding:20px 16px 40px}
h1{font-size:20px;margin:0}h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);margin:22px 0 8px}
.top{display:flex;flex-wrap:wrap;gap:8px 16px;align-items:center;justify-content:space-between}
.pill{display:inline-flex;align-items:center;gap:8px;padding:6px 12px;border-radius:999px;background:var(--card);border:1px solid var(--line);font-weight:600}
.meta{color:var(--mut);font-size:12px;margin-top:4px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden}
.row{display:grid;grid-template-columns:18px minmax(120px,1.2fr) 96px minmax(0,2fr) 70px 60px;gap:10px;align-items:center;padding:9px 14px;border-top:1px solid var(--line)}
.row:first-child{border-top:0}.row .s{color:var(--mut);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.num{color:var(--mut);text-align:right;font-variant-numeric:tabular-nums}
.dot{width:10px;height:10px;border-radius:50%;display:inline-block}
.ok{background:var(--ok)}.warn{background:var(--warn)}.bad{background:var(--bad)}.done{background:var(--done)}
.lbl{font-weight:600;font-size:12px}.lbl.ok{background:none;color:var(--ok)}.lbl.warn{background:none;color:var(--warn)}.lbl.bad{background:none;color:var(--bad)}.lbl.done{background:none;color:var(--done)}
.sum{display:grid;grid-template-columns:18px 130px 1fr;gap:10px;align-items:center;padding:10px 14px;border-top:1px solid var(--line)}.sum:first-child{border-top:0}
.links a{color:inherit;margin-right:14px}
.stale{display:none;margin-top:12px;padding:10px 14px;border-radius:8px;background:var(--bad);color:#fff;font-weight:600}
@media (max-width:640px){.row{grid-template-columns:18px 1fr auto}.row .s,.row .num{display:none}.sum{grid-template-columns:18px 1fr}.sum b{grid-column:2}.sum span:last-child{grid-column:2}}
</style></head><body><main>
<div class="top">
  <div><h1>InfraLab</h1><div class="meta">$(esc "$VM_NAME")${meta_ip} · updated $(esc "$NOW") · auto-refresh 15s</div></div>
  <div class="pill"><span class="dot $WORST"></span>$overall_label</div>
</div>
<div class="stale" id="stale">This page has not been updated for over 2 minutes. The VM or the status timer may be down.</div>

<h2>Clusters</h2>
<div class="card">
  <div class="sum"><span class="dot $REDIS_LVL"></span><b>Redis Cluster</b><span>$(esc "$REDIS_MSG")</span></div>
  <div class="sum"><span class="dot $KAFKA_LVL"></span><b>Kafka</b><span>$(esc "$KAFKA_MSG")</span></div>
EOF
  [ -n "$CASS_LVL" ] && echo "  <div class=\"sum\"><span class=\"dot $CASS_LVL\"></span><b>Cassandra</b><span>$(esc "$CASS_MSG")</span></div>"
  echo "</div>"

  local last="" open=0
  while IFS='|' read -r proj name state status; do
    [ -z "$name" ] && continue
    if [ "$proj" != "$last" ]; then
      [ "$open" = 1 ] && echo "</div>"
      echo "<h2>$(esc "$proj")</h2><div class=\"card\">"; open=1; last="$proj"
    fi
    IFS='|' read -r lvl label <<<"$(classify "$state" "$status")"
    echo "<div class=\"row\"><span class=\"dot $lvl\"></span><b>$(esc "$name")</b><span class=\"lbl $lvl\">$(esc "$label")</span><span class=\"s\">$(esc "$status")</span><span class=\"num\">$(esc "${MEM[$name]:--}")</span><span class=\"num\">$(esc "${CPU[$name]:--}")</span></div>"
  done <<<"$ROWS"
  [ "$open" = 1 ] && echo "</div>"
  [ -z "$ROWS" ] && echo "<h2>Containers</h2><div class=\"card\"><div class=\"sum\">No containers running.</div></div>"

  cat <<EOF
<h2>VM</h2>
<div class="card">
  <div class="sum"><span></span><b>Uptime</b><span>$(esc "$SYS_UP")</span></div>
  <div class="sum"><span></span><b>Load (1/5/15m)</b><span>$(esc "$SYS_LOAD")</span></div>
  <div class="sum"><span></span><b>Memory</b><span>$(esc "$SYS_MEM")</span></div>
  <div class="sum"><span></span><b>Disk /</b><span>$(esc "$SYS_DISK")</span></div>
</div>

${links}
</main>
<script>
var gen=${NOW_EPOCH};
function chk(){if(Date.now()/1000-gen>120)document.getElementById('stale').style.display='block'}
chk();setInterval(chk,10000);
</script>
</body></html>
EOF
}

if [ "$MODE" = html ]; then
  mkdir -p "$(dirname "$OUT")"
  render_html > "$OUT.tmp" && chmod 644 "$OUT.tmp" && mv -f "$OUT.tmp" "$OUT"
else
  render_text
fi
