#!/usr/bin/env bash
# ===========================================================================
#  fix-container-dns.sh
#  Repairs a worldserver that cannot start because its container cannot
#  resolve the database container:
#
#     Could not connect to MySQL database at ac-database:
#     Unknown MySQL server host 'ac-database' (-3)
#     DatabasePool Login NOT opened. There were errors opening the MySQL connections.
#
#  What this error means: MySQL error -3 is CR_UNKNOWN_HOST, a NAME RESOLUTION
#  failure inside the container - not a database problem. The image, the
#  database and its data are intact; only the network/resolver state of
#  ac-worldserver is broken.
#
#  How containers resolve each other: on a user-defined network every container
#  gets Docker's embedded resolver 127.0.0.11 in /etc/resolv.conf (libnetwork
#  rebuildDNS() writes exactly that address), and it answers the service names
#  and aliases of that network from its registry. "ac-database" therefore cannot
#  be resolved when
#    * ac-worldserver is not attached to the same network as ac-database, or
#    * the container was created before a Docker daemon restart, so its sandbox
#      and the DNS alias registration are stale (a daemon restart is done by
#      fix-build-network.sh / fix-resolv.sh), or
#    * the container's /etc/resolv.conf was rewritten and 127.0.0.11 is gone.
#
#  Repair strategy - evidence first, smallest change first, every step verified
#  with a real name lookup from a throwaway container in the same network:
#    1. facts: container states, networks, DNS aliases, resolv.conf, daemon.json
#    2. resolution probe for ac-database
#    3. name resolves on the network  -> restart the application containers
#       name does not resolve          -> recreate the whole stack
#    4. still broken -> remove a custom "dns" entry from /etc/docker/daemon.json
#       (backup kept), restart the Docker daemon, recreate the stack again
#    5. verify: resolution, database connection, world port
#
#  Accounts, characters and the CoA world data live in Docker volumes and are
#  never touched. Downtime = container restart plus the worldserver start.
#
#  Usage: bash fix-container-dns.sh           # check, repair, verify
#         DRY=1 bash fix-container-dns.sh     # only show what would change
#         SKIP_REPAIR=1 ...                   # diagnose only, change nothing
#         MAX_STEP=1 ...                      # only the smallest repair step
# ===========================================================================
set -uo pipefail

AC_DIR="${AC_DIR:-/opt/azerothcore}"
WORLD_PORT="${WORLD_PORT:-8085}"
DRY="${DRY:-0}"
SKIP_REPAIR="${SKIP_REPAIR:-0}"
MAX_STEP="${MAX_STEP:-3}"

ok()   { printf '\033[0;32m[ OK  ]\033[0m %s\n' "$*"; }
info() { printf '\033[0;36m[INFO ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN ]\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m[FAIL ]\033[0m %s\n' "$*"; }
step() { printf '\n\033[0;36m=== %s ===\033[0m\n' "$*"; }
contains()    { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
port_open()   { local o; o="$(ss -ltn 2>/dev/null)"; contains "$o" ":$1 "; }
state_of()   { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo missing; }
nets_of()    { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}({{$v.IPAddress}}) {{end}}' "$1" 2>/dev/null; }
net_names()  { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1" 2>/dev/null; }
alias_of()   { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$v.Aliases}} {{end}}' "$1" 2>/dev/null; }
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
daemon_json_dns() {   # prints the dns entry of daemon.json (empty when absent)
    [ -f /etc/docker/daemon.json ] || return 0
    tr -d '\n' < /etc/docker/daemon.json | grep -o '"dns"[^]]*]' || true
}
strip_daemon_json_dns() {   # remove only the "dns" key, keep every other key
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
probe_resolve() {   # <network> -> 0 = ac-database resolves, 1 = no, 2 = not testable
    local net="$1" out rc
    [ -n "$net" ] || return 2
    command -v timeout >/dev/null 2>&1 || return 2
    out="$(timeout 60 docker run --rm --network "$net" --entrypoint /bin/sh "$DB_IMAGE" \
            -c 'getent hosts ac-database' 2>&1)"
    rc=$?
    printf '%s\n' "$out" > /tmp/coa_dns_probe.txt
    [ "$rc" -eq 127 ] && return 2          # getent is not available in the image
    [ "$rc" -eq 0 ] && [ -n "$out" ] && return 0
    return 1
}
probe_worldserver_networks() {   # 0 = a container next to ac-worldserver resolves ac-database
    local n
    for n in $(net_names ac-worldserver); do
        probe_resolve "$n" && return 0
    done
    return 1
}
worldserver_db_error() {   # 0 = the log still shows the name resolution failure
    # no "| grep -q" here: with `set -o pipefail` the early exit of grep makes
    # the pipeline fail with SIGPIPE (141) although the line IS present
    local o; o="$(docker logs --tail 200 ac-worldserver 2>&1)"
    contains "$o" 'Unknown MySQL server host'
}
worldserver_db_ok() {      # 0 = the worldserver opened the database pool
    local o; o="$(docker logs --tail 200 ac-worldserver 2>&1)"
    contains "$o" "Opening DatabasePool 'acore_auth'" && ! contains "$o" 'Unknown MySQL server host'
}
wait_for_db_connection() {  # <seconds> -> 0 = connected
    local max="${1:-300}" waited=0
    while [ "$waited" -lt "$max" ]; do
        if worldserver_db_ok; then
            printf '  connected after %ss\n' "$waited"
            return 0
        fi
        [ $((waited % 30)) -eq 0 ] && printf '  ... %ss (state=%s)\n' "$waited" "$(state_of ac-worldserver)"
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

# ------------------------------------------------------------------ 1) facts
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
if worldserver_db_error; then
    fail "worldserver log: $(docker logs --tail 200 ac-worldserver 2>&1 | grep -a 'Unknown MySQL server host' | tail -1 | tr -d '\r' | tail -c 120)"
    info "mysql error -3 is CR_UNKNOWN_HOST: the image and the database are fine, the NAME LOOKUP fails"
else
    ok "worldserver log: no 'Unknown MySQL server host' in the last 200 lines"
fi

# -------------------------------------------------------- 2) resolution probe
step "2/5  Resolution probe"
probe_worldserver_networks; PROBE=$?
case "$PROBE" in
    0) ok "ac-database resolves next to ac-worldserver: $(tr '\n' ' ' < /tmp/coa_dns_probe.txt)" ;;
    1) fail "ac-database does NOT resolve inside the network of ac-worldserver" ;;
    *) warn "probe not possible (no timeout, or no shell in $DB_IMAGE) - repairing anyway" ;;
esac

# ------------------------------------------------------------------ 3) repair
step "3/5  Repair"
DB_OK=0
if [ "$DRY" = "1" ]; then
    if [ "$PROBE" = "0" ]; then
        info "would run: docker compose restart ac-worldserver ac-authserver"
    else
        info "would run: docker compose up -d --force-recreate"
    fi
elif [ "$SKIP_REPAIR" = "1" ]; then
    warn "SKIP_REPAIR=1 - nothing is changed"
elif [ "$PROBE" = "0" ]; then
    info "the name resolves on the network - only the container of the worldserver is stale"
    info "restarting ac-worldserver and ac-authserver ..."
    ( cd "$AC_DIR" && timeout 180 docker compose restart ac-worldserver ac-authserver ) 2>&1 | tail -3 | sed 's/^/      /'
else
    info "the name does not resolve on the network - recreating the stack"
    info "(same network, fresh resolver config, re-registered DNS aliases)"
    LOG=/tmp/coa_compose_recreate.log
    rc=0
    ( cd "$AC_DIR" && timeout 600 docker compose up -d --force-recreate ) >"$LOG" 2>&1 || rc=$?
    tail -6 "$LOG" | sed 's/^/      /'
    [ "$rc" -eq 0 ] || warn "docker compose up --force-recreate returned ${rc} (124 = the 10 minute limit)"
fi

if [ "$DRY" != "1" ] && [ "$SKIP_REPAIR" != "1" ]; then
    info "waiting for the worldserver to reach the database ..."
    if wait_for_db_connection 240; then
        DB_OK=1
    fi
fi

# -------------------------------------------------------------- 4) escalation
if [ "$DRY" != "1" ] && [ "$SKIP_REPAIR" != "1" ] && [ "$DB_OK" = "0" ]; then
    step "4/5  Escalation"
    if [ "$MAX_STEP" -lt 2 ] 2>/dev/null; then
        warn "MAX_STEP=1 - escalation skipped"
    elif [ -n "$(daemon_json_dns)" ]; then
        warn "still failing - a custom dns entry is present, cleaning it up"
        info "the entry: $(daemon_json_dns)   (it is only needed for image builds)"
        cp -f /etc/docker/daemon.json /etc/docker/daemon.json.bak-dns 2>/dev/null || true
        if command -v python3 >/dev/null 2>&1 && strip_daemon_json_dns; then
            ok "dns entry removed (backup: /etc/docker/daemon.json.bak-dns)"
        else
            warn "daemon.json left untouched - check it: cat /etc/docker/daemon.json"
        fi
        info "restarting the Docker daemon ..."
        timeout 120 systemctl restart docker >/dev/null 2>&1 || warn "systemctl restart docker timed out"
        for _i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
        info "recreating the stack ..."
        ( cd "$AC_DIR" && timeout 600 docker compose up -d --force-recreate ) >/tmp/coa_compose_recreate.log 2>&1 \
            || warn "docker compose up --force-recreate returned an error - log: /tmp/coa_compose_recreate.log"
        wait_for_db_connection 300 && DB_OK=1
    else
        info "no custom dns entry in daemon.json - nothing left to escalate to"
    fi
fi

# -------------------------------------------------------------- 5) verification
step "5/5  Verification"
printf '%-14s state=%s networks=%s\n' ac-worldserver "$(state_of ac-worldserver)" "$(nets_of ac-worldserver)"
printf '%-14s resolv.conf: %s\n' ac-worldserver "$(resolv_of ac-worldserver)"
if has_embedded_dns ac-worldserver; then
    ok "ac-worldserver uses the embedded DNS 127.0.0.11"
else
    warn "127.0.0.11 is missing in ac-worldserver's resolv.conf"
fi
probe_worldserver_networks; PROBE2=$?
case "$PROBE2" in
    0) ok "name lookup works: $(tr '\n' ' ' < /tmp/coa_dns_probe.txt)" ;;
    1) fail "name lookup still fails" ;;
    *) warn "name lookup could not be tested" ;;
esac
if worldserver_db_error; then
    fail "worldserver log still shows 'Unknown MySQL server host'"
else
    ok "worldserver log has no name resolution error"
fi
printf 'world port %s: %s\n' "$WORLD_PORT" "$(port_open "$WORLD_PORT" && echo open || echo closed)"

echo
if [ "$DB_OK" = "1" ]; then
    ok "Repaired. The worldserver still loads the CoA data for a few minutes."
    if [ "$(ss -ltn 2>/dev/null | grep -c ":$WORLD_PORT ")" = "0" ]; then
        info "watch it: docker logs -f ac-worldserver   (wait for 'World Initialized')"
    fi
    info "the client shows 'Realm Offline' until the realm flag is cleared: bash /root/coa-update.sh"
    exit 0
fi
warn "Not repaired automatically. Please send the output of:"
warn "  docker inspect -f '{{json .NetworkSettings.Networks}}' ac-worldserver ac-database"
warn "  docker inspect -f '{{.ResolvConfPath}}' ac-worldserver | xargs cat"
warn "  journalctl -u docker --since '30 min ago' | tail -30"
exit 1

[ "$(id -u)" -eq 0 ] || { fail "please run as root (sudo bash $0)"; exit 1; }
command -v docker >/dev/null 2>&1 || { fail "docker is not installed"; exit 1; }
[ -f "$AC_DIR/docker-compose.yml" ] || { fail "no deployment found at $AC_DIR"; exit 1; }
command -v python3 >/dev/null 2>&1 || warn "python3 not found - a custom dns entry in daemon.json cannot be edited"
[ "$DRY" = "1" ] && info "DRY-RUN: nothing will be changed"

DB_IMAGE="$(docker inspect -f '{{.Config.Image}}' ac-database 2>/dev/null)"
[ -n "$DB_IMAGE" ] || DB_IMAGE="mysql:8.4"