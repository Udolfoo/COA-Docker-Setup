#!/usr/bin/env bash
# ===========================================================================
#  fix-container-dns.sh
#  Repairs a worldserver that cannot start because it cannot resolve the
#  database container:
#
#     Could not connect to MySQL database at ac-database:
#     Unknown MySQL server host 'ac-database' (-3)
#     DatabasePool Login NOT opened. There were errors opening the MySQL connections.
#
#  Cause: the container has no working name resolution for the compose network.
#  A container on a user-defined network resolves other containers through
#  Docker's embedded DNS (127.0.0.11). If that entry is missing in the
#  container's resolv.conf - or the container is not attached to the network of
#  ac-database - the service name cannot be resolved and every start fails with
#  error -3. Typical trigger: /etc/docker/daemon.json carries a custom "dns"
#  entry (written by fix-build-network.sh) and the daemon was restarted
#  afterwards, so freshly created containers got a different resolver
#  configuration than the containers that were already running.
#
#  What it does:
#    1. shows the facts (resolv.conf, networks and aliases of both containers)
#    2. removes a custom "dns" entry from daemon.json (backup is kept)
#    3. restarts the Docker daemon if daemon.json changed
#    4. recreates the stack so every container joins the same network with a
#       fresh resolver configuration and DNS alias
#    5. verifies: 127.0.0.11 present, name resolvable, worldserver reaches the DB
#
#  Accounts, characters and the CoA world data live in Docker volumes and are
#  not touched. Downtime = the worldserver start (a few minutes).
#
#  Usage: bash fix-container-dns.sh           # check, repair, verify
#         DRY=1 bash fix-container-dns.sh     # only show what would change
#         SKIP_RECREATE=1 ...                 # leave the containers as they are
# ===========================================================================
set -uo pipefail

AC_DIR="${AC_DIR:-/opt/azerothcore}"
WORLD_PORT="${WORLD_PORT:-8085}"
DRY="${DRY:-0}"
SKIP_RECREATE="${SKIP_RECREATE:-0}"

ok()   { printf '\033[0;32m[ OK  ]\033[0m %s\n' "$*"; }
info() { printf '\033[0;36m[INFO ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN ]\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m[FAIL ]\033[0m %s\n' "$*"; }
step() { printf '\n\033[0;36m=== %s ===\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { fail "please run as root (sudo bash $0)"; exit 1; }
command -v docker >/dev/null 2>&1 || { fail "docker is not installed"; exit 1; }
[ -f "$AC_DIR/docker-compose.yml" ] || { fail "no deployment found at $AC_DIR"; exit 1; }
command -v python3 >/dev/null 2>&1 || warn "python3 not found - a custom dns entry in daemon.json cannot be edited"
[ "$DRY" = "1" ] && info "DRY-RUN: nothing will be changed"

state_of()  { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo missing; }
nets_of()   { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}({{$v.IPAddress}}) {{end}}' "$1" 2>/dev/null; }
alias_of()  { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$v.Aliases}} {{end}}' "$1" 2>/dev/null; }
resolv_of() {  # <container> -> the nameserver lines of its resolv.conf
    local p
    p="$(docker inspect -f '{{.ResolvConfPath}}' "$1" 2>/dev/null)"
    if [ -n "$p" ] && [ -f "$p" ]; then
        grep -v '^#' "$p" 2>/dev/null | grep -v '^$' | tr '\n' ' '
    else
        echo "(resolv.conf not found)"
    fi
}
has_embedded_dns() {  # <container> -> 0 if 127.0.0.11 is configured
    local p
    p="$(docker inspect -f '{{.ResolvConfPath}}' "$1" 2>/dev/null)"
    [ -n "$p" ] && grep -q '127\.0\.0\.11' "$p" 2>/dev/null
}
daemon_json_dns() {  # prints the dns entry of daemon.json (empty when absent)
    [ -f /etc/docker/daemon.json ] || return 0
    tr -d '\n' < /etc/docker/daemon.json | grep -o '"dns"[^]]*]' || true
}
strip_daemon_json_dns() {  # remove only the "dns" key
    python3 - <<'PYEOF'
import json, pathlib, sys
p = pathlib.Path('/etc/docker/daemon.json')
try:
    data = json.loads(p.read_text() or '{}')
except Exception as exc:
    print('daemon.json is not valid JSON (%s) - left untouched' % exc)
    sys.exit(1)
if 'dns' not in data:
    print('no dns entry')
    sys.exit(2)
data.pop('dns')
p.write_text(json.dumps(data, indent=2) + '\n')
keys = ', '.join(sorted(data)) or 'none'
print('dns entry removed, kept keys: ' + keys)
PYEOF
}

# ----------------------------------------------------------------- 1) facts
step "1/5  Facts"
printf '%-14s state=%s networks=%s\n' ac-worldserver "$(state_of ac-worldserver)" "$(nets_of ac-worldserver)"
printf '%-14s state=%s networks=%s\n' ac-database    "$(state_of ac-database)"    "$(nets_of ac-database)"
echo
printf '%-14s resolv.conf: %s\n' ac-worldserver "$(resolv_of ac-worldserver)"
printf '%-14s resolv.conf: %s\n' ac-database    "$(resolv_of ac-database)"
echo
printf '%-14s aliases: %s\n' ac-database    "$(alias_of ac-database)"
printf '%-14s aliases: %s\n' ac-worldserver "$(alias_of ac-worldserver)"
echo
info "daemon.json dns: $(daemon_json_dns)"
last_err="$(docker logs --tail 200 ac-worldserver 2>&1 | grep -a 'Unknown MySQL server host' | tail -1)"
if [ -n "$last_err" ]; then
    fail "worldserver log: ${last_err#*] }"
else
    ok "worldserver log: no 'Unknown MySQL server host' in the last 200 lines"
fi

# ------------------------------------------------------------ 2) Docker DNS
step "2/5  Docker DNS configuration"
CHANGED=0
if [ -n "$(daemon_json_dns)" ]; then
    warn "/etc/docker/daemon.json sets a custom dns entry: $(daemon_json_dns)"
    info "Custom DNS servers go into the container instead of the embedded resolver"
    info "(127.0.0.11) - and exactly that entry knows the name 'ac-database'."
    if [ "$DRY" = "1" ]; then
        info "would remove the dns entry (backup: /etc/docker/daemon.json.bak-dns)"
        CHANGED=1
    else
        cp -f /etc/docker/daemon.json /etc/docker/daemon.json.bak-dns 2>/dev/null || true
        if command -v python3 >/dev/null 2>&1 && strip_daemon_json_dns; then
            CHANGED=1
            ok "dns entry removed (backup: /etc/docker/daemon.json.bak-dns)"
        else
            warn "daemon.json left untouched - check it manually: cat /etc/docker/daemon.json"
        fi
    fi
else
    ok "no custom dns entry in daemon.json"
fi

# ------------------------------------------------------- 3) Docker daemon
step "3/5  Docker daemon"
if [ "$CHANGED" = "1" ]; then
    if [ "$DRY" = "1" ]; then
        info "would restart the Docker daemon (containers with a restart policy come back)"
    else
        info "restarting the Docker daemon (a few seconds) ..."
        timeout 120 systemctl restart docker >/dev/null 2>&1 || warn "systemctl restart docker timed out"
        for _i in $(seq 1 30); do
            docker info >/dev/null 2>&1 && break
            sleep 2
        done
        if docker info >/dev/null 2>&1; then
            ok "Docker daemon is up again"
        else
            fail "Docker daemon is NOT running - check: systemctl status docker"
        fi
    fi
else
    ok "no daemon restart needed"
fi

# ----------------------------------------------------------- 4) Containers
step "4/5  Containers"
if [ "$SKIP_RECREATE" = "1" ]; then
    warn "SKIP_RECREATE=1 - containers are left untouched"
elif [ "$DRY" = "1" ]; then
    info "would run: docker compose up -d --force-recreate   (in $AC_DIR)"
else
    info "recreating the containers (same network + fresh resolver config + DNS aliases)"
    LOG=/tmp/coa_compose_recreate.log
    rc=0
    ( cd "$AC_DIR" && timeout 600 docker compose up -d --force-recreate ) >"$LOG" 2>&1 || rc=$?
    tail -8 "$LOG" | sed 's/^/      /'
    if [ "$rc" -eq 0 ]; then
        ok "containers recreated (accounts, characters and world data stay in the volumes)"
    else
        fail "docker compose up --force-recreate returned ${rc} (124 = the 10 minute limit)"
        tail -20 "$LOG" | sed 's/^/      /'
    fi
fi

# --------------------------------------------------------- 5) Verification
step "5/5  Verification"
printf '%-14s resolv.conf: %s\n' ac-worldserver "$(resolv_of ac-worldserver)"
if has_embedded_dns ac-worldserver; then
    ok "ac-worldserver is configured to use the embedded DNS 127.0.0.11"
elif [ "$DRY" != "1" ]; then
    warn "127.0.0.11 is still missing in ac-worldserver's resolv.conf"
fi

NET="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' ac-database 2>/dev/null | awk '{print $1}')"
if [ "$DRY" = "1" ] || [ -z "$NET" ]; then
    info "skipping the name resolution probe"
else
    info "resolving 'ac-database' inside the network '$NET' (probe container, no pull) ..."
    if docker image inspect mysql:8.4 >/dev/null 2>&1; then
        if timeout 90 docker run --rm --network "$NET" --entrypoint /usr/bin/getent \
                mysql:8.4 hosts ac-database >/tmp/coa_dns_probe.txt 2>&1; then
            ok "ac-database resolves: $(tr '\n' ' ' < /tmp/coa_dns_probe.txt)"
        else
            fail "ac-database still does not resolve inside '$NET'"
            tail -3 /tmp/coa_dns_probe.txt | sed 's/^/      /'
            info "also check the firewall: iptables -S FORWARD | head -3  /  nft list ruleset"
        fi
    else
        warn "image mysql:8.4 is not present locally - skipping the probe"
    fi
fi

info "waiting for the worldserver to reach the database (limit 7 minutes) ..."
CONNECTED=0
waited=0
while [ "$waited" -lt 420 ]; do
    if docker logs --tail 200 ac-worldserver 2>&1 | grep -q "Opening DatabasePool 'acore_auth'" \
       && ! docker logs --tail 200 ac-worldserver 2>&1 | grep -q 'Unknown MySQL server host'; then
        CONNECTED=1
        ok "worldserver connected to the database (after ${waited}s)"
        break
    fi
    [ $((waited % 30)) -eq 0 ] && info "  ... ${waited}s (state=$(state_of ac-worldserver))"
    sleep 5
    waited=$((waited + 5))
done

if [ "$CONNECTED" = "1" ]; then
    info "the worldserver still needs a few minutes to load the world data"
    printf 'port %s: %s\n' "$WORLD_PORT" "$(ss -ltn 2>/dev/null | grep -q ":$WORLD_PORT " && echo open || echo closed)"
else
    fail "the worldserver did not reach the database"
    docker ps -a --format '  {{.Names}}: {{.Status}}' | grep -E 'ac-' || true
    docker logs --tail 30 ac-worldserver 2>&1 | sed 's/^/      /'
fi

echo
if [ "$CONNECTED" = "1" ]; then
    ok "Done. The client keeps showing 'Realm Offline' until the realm flag is cleared, run: bash /root/coa-update.sh"
else
    warn "Unresolved. Please send the output of:"
    warn "  docker inspect -f '{{json .NetworkSettings.Networks}}' ac-worldserver"
    warn "  journalctl -u docker --since '30 min ago' | tail -30"
fi
