#!/usr/bin/env bash
# ===========================================================================
#  coa-fix-network.sh  - one script for both network problems of this stack
# ---------------------------------------------------------------------------
#  Two different failures that look similar but are not:
#
#  --build    (former fix-build-network.sh; runs automatically before an image
#              build)  "make build containers reach the distribution mirrors"
#              Symptom:  E: Unable to locate package tzdata
#                        W: Some index files failed to download (after ~240 s)
#              Cause 1 - DNS: with systemd-resolved, /etc/resolv.conf holds only
#                the 127.0.0.53 stub. Docker drops loopback resolvers and falls
#                back to 8.8.8.8, which some providers filter (OVH: use
#                213.186.33.99). The real upstream is only visible via resolvectl.
#              Cause 2 - IPv6: apt resolves an IPv6 mirror although the host has
#                no IPv6 route, so every package list waits for the timeout.
#              Never pulls an image and never blocks: the container test runs
#              detached and is polled (a docker CLI waiting on dead DNS cannot be
#              interrupted by "timeout"). Fixes come from the evidence first, the
#              container test only verifies them.
#
#  --runtime  (former fix-container-dns.sh)  "a running stack cannot resolve its
#              database"
#              Symptom:  Could not connect to MySQL database at ac-database:
#                        Unknown MySQL server host 'ac-database' (-3)
#                        DatabasePool Login NOT opened.
#              MySQL error -3 is CR_UNKNOWN_HOST: a NAME RESOLUTION failure
#              inside the container, not a database problem. Every container on a
#              user-defined network gets Docker's embedded resolver 127.0.0.11 in
#              /etc/resolv.conf, and that resolver answers the compose service
#              names. It is missing when the container was created while
#              /etc/docker/daemon.json carried a custom "dns" entry, or after a
#              Docker daemon restart left the sandbox and the DNS alias
#              registration stale. The smallest fix is tried first: restart the
#              application containers, recreate the stack, remove a custom dns
#              entry. Accounts, characters and CoA data stay in the volumes.
#
#  Usage
#    bash coa-fix-network.sh                # both: build preflight + runtime
#    bash coa-fix-network.sh --build        # only the apt-mirror / build side
#    bash coa-fix-network.sh --runtime      # only the container DNS side
#    DRY=1 bash coa-fix-network.sh          # report only, change nothing
#    SKIP_REPAIR=1 bash coa-fix-network.sh --runtime   # diagnose only
#
#  Environment
#    DRY=1                 report only, never change anything
#    SKIP_IPV6_FIX=1       do not disable IPv6
#    TEST_IMAGE=debian:12  image for the apt test (default ubuntu:24.04)
#    REMOVE_GLOBAL_DNS=1   remove a custom "dns" entry from daemon.json
#    ALLOW_GLOBAL_DNS=1    opt-in: write one (merged) into daemon.json
#    MAX_STEP=1            runtime mode: only the smallest repair step
#    AC_DIR=/opt/azerothcore   WORLD_PORT=8085
# ===========================================================================
set -uo pipefail

MODE="all"
while [ $# -gt 0 ]; do
    case "$1" in
        --build)   MODE="build" ;;
        --runtime) MODE="runtime" ;;
        --all)     MODE="all" ;;
        -h|--help) sed -n '2,60p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^$/d'; exit 0 ;;
        *)         printf 'unknown option: %s (try: bash %s --help)\n' "$1" "$0" >&2; exit 2 ;;
    esac
    shift
done

TEST_IMAGE="${TEST_IMAGE:-ubuntu:24.04}"
TEST_TIMEOUT="${TEST_TIMEOUT:-45}"
DRY="${DRY:-0}"
SKIP_IPV6_FIX="${SKIP_IPV6_FIX:-0}"
SKIP_REPAIR="${SKIP_REPAIR:-0}"
MAX_STEP="${MAX_STEP:-3}"
AC_DIR="${AC_DIR:-/opt/azerothcore}"
WORLD_PORT="${WORLD_PORT:-8085}"
CHANGED=0
APT_RC=2

ok()   { printf '\033[0;32m[ OK  ]\033[0m %s\n' "$*"; }
info() { printf '\033[0;36m[INFO ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN ]\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m[FAIL ]\033[0m %s\n' "$*"; }
step() { printf '\n\033[0;36m=== %s ===\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { fail "please run as root (sudo bash $0)"; exit 1; }
command -v docker >/dev/null 2>&1 || { fail "docker is not installed"; exit 1; }
[ "$DRY" = "1" ] && info "DRY-RUN: nothing will be changed"

# ---------------------------------------------------------------------------
#  --build : a build container must be able to reach the apt mirrors
#            (logic unchanged from fix-build-network.sh)
# ---------------------------------------------------------------------------
mode_build() {

host_resolvers() {  # host upstream resolvers (resolvectl knows per-link DNS)
    {
        resolvectl dns 2>/dev/null | sed -n 's/.*: //p'
        sed -n 's/^nameserver[[:space:]]*//p' /run/systemd/resolve/resolv.conf 2>/dev/null
        sed -n 's/^nameserver[[:space:]]*//p' /etc/resolv.conf 2>/dev/null
    } | tr ' ' '\n' \
      | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+$' \
      | grep -v '^127\.' | grep -v '^::1$' | grep -v '^0\.0\.0\.0$' \
      | sort -u | head -3
}

stub_only_resolv_conf() {  # does /etc/resolv.conf contain nothing but loopback?
    local ns
    ns="$(sed -n 's/^nameserver[[:space:]]*//p' /etc/resolv.conf 2>/dev/null)"
    [ -n "$ns" ] || return 1
    ! printf '%s\n' "$ns" | grep -qv '^127\.'
}

ipv6_usable() {
    [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = "0" ] || return 1
    timeout 8 curl -6 -sI http://archive.ubuntu.com/ >/dev/null 2>&1
}

have_image() { timeout 15 docker image inspect "$1" >/dev/null 2>&1; }

fw_forward_info() {  # FORWARD policy + number of Docker rules
    local pol rules
    pol="$(iptables -S FORWARD 2>/dev/null | sed -n 's/^-P FORWARD //p' | head -1)"
    rules="$(iptables -S FORWARD 2>/dev/null | grep -c DOCKER)"
    if [ -z "$pol" ] && command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
        pol="nftables(FORWARD chains: $(nft list ruleset 2>/dev/null | grep -c 'chain FORWARD'))"
    fi
    echo "policy=${pol:-unknown} dockerRules=${rules}"
}

nft_forward_drop() {  # 0 = an nftables forward chain drops everything (docker broken)
    command -v nft >/dev/null 2>&1 || return 1
    nft list ruleset 2>/dev/null | awk '
        /chain [^ ]*forward/ { fwd=1; pol=0; rules=0; next }
        /chain /             { fwd=0; pol=0; rules=0; next }
        fwd && /policy drop/ { pol=1; next }
        fwd && /^[[:space:]]*\}/ {
            if (pol && rules == 0) print "empty-drop"
            fwd=0; pol=0; rules=0; next }
        fwd && /(accept|jump|return|drop|reject|log)/ { rules++; next }
    ' | grep -q empty-drop
}

nft_fw_fix_runtime() {  # allow container forwarding in the running ruleset
    nft add rule inet filter forward iifname "docker0" accept
    nft add rule inet filter forward oifname "docker0" accept
    nft add rule inet filter forward iifname "br-*" accept
    nft add rule inet filter forward oifname "br-*" accept
    nft add rule inet filter forward iifname "veth*" accept
    nft add rule inet filter forward oifname "veth*" accept
}

nft_fw_fix_persist() {  # add the same rules to /etc/nftables.conf (survives reboot)
    local conf=/etc/nftables.conf
    [ -f "$conf" ] || return 0
    grep -q docker0 "$conf" && { info "already present in $conf"; return 0; }
    cp -f "$conf" "$conf.bak"
    awk '
        { lines[NR] = $0 }
        END {
            start = 0
            for (i = 1; i <= NR; i++)
                if (lines[i] ~ /chain .*forward/ && start == 0) start = i
            end = 0
            if (start > 0)
                for (i = start + 1; i <= NR; i++)
                    if (lines[i] ~ /^[[:space:]]*}/ && end == 0) { end = i; break }
            for (i = 1; i <= NR; i++) {
                if (end > 0 && i == end) {
                    print "        # Docker/Containers: sonst wird der gesamte Container-Verkehr (inkl. DNS) verworfen"
                    print "        iifname \"docker0\" accept"
                    print "        oifname \"docker0\" accept"
                    print "        iifname \"br-*\" accept"
                    print "        oifname \"br-*\" accept"
                    print "        iifname \"veth*\" accept"
                    print "        oifname \"veth*\" accept"
                }
                print lines[i]
            }
        }' "$conf.bak" > "$conf"
    if nft -c -f "$conf" >/dev/null 2>&1; then
        ok "added docker rules to $conf (backup: $conf.bak)"
        systemctl reload-or-restart nftables >/dev/null 2>&1 || true
    else
        warn "the patched $conf has a syntax error - restoring the backup"
        mv -f "$conf.bak" "$conf"
    fi
}

restart_docker() {
    if [ "$DRY" = "1" ]; then
        info "would restart the Docker daemon"
        return 0
    fi
    info "restarting the Docker daemon (a few seconds) ..."
    timeout 90 systemctl restart docker >/dev/null 2>&1 || warn "docker restart timed out"
    sleep 4
}

container_apt_test() {  # 0 = works, 1 = fails, 2 = not testable
    have_image "$TEST_IMAGE" || return 2
    local cid state
    info "verifying with a short container test (max ${TEST_TIMEOUT}s, non blocking) ..."
    cid="$(timeout 20 docker run -d --name coa_nettest "$TEST_IMAGE" \
            sh -c 'apt-get update -qq' 2>/dev/null)" || return 1
    [ -n "$cid" ] || return 1
    local waited=0
    while [ "$waited" -lt "$TEST_TIMEOUT" ]; do
        state="$(timeout 10 docker inspect -f '{{.State.Status}}:{{.State.ExitCode}}' coa_nettest 2>/dev/null)"
        case "$state" in
            "exited:0") ok "apt-get update works inside a container"
                        timeout 15 docker rm -f coa_nettest >/dev/null 2>&1; return 0 ;;
            exited:*)   warn "apt-get update failed inside a container (exit ${state#exited:})"
                        timeout 10 docker logs coa_nettest 2>&1 | tail -3 | sed 's/^/        /'
                        timeout 15 docker rm -f coa_nettest >/dev/null 2>&1; return 1 ;;
        esac
        sleep 1; waited=$((waited + 1))
    done
    warn "the container test did not finish within ${TEST_TIMEOUT}s (likely a dead DNS lookup)"
    timeout 10 docker logs coa_nettest 2>&1 | tail -3 | sed 's/^/        /'
    timeout 15 docker kill coa_nettest >/dev/null 2>&1
    timeout 15 docker rm -f coa_nettest >/dev/null 2>&1
    return 1
}

# ---------------------------------------------------------------- diagnosis
info "host resolvers: $(host_resolvers | tr '\n' ' ')"
NEED_DNS=0
if stub_only_resolv_conf; then
    NEED_DNS=1
    warn "/etc/resolv.conf only holds the systemd-resolved stub (127.0.0.53)"
    info "-> Docker falls back to 8.8.8.8, which some providers filter"
else
    ok "/etc/resolv.conf lists real resolvers"
fi
if ipv6_usable; then
    ok "IPv6 is usable"
    NEED_IPV6=0
else
    NEED_IPV6=1
    warn "IPv6 is not usable (no route, even though addresses may resolve)"
    info "-> apt waits for the connection timeout on every package list"
fi

NEED_NFT=0
if nft_forward_drop; then
    NEED_NFT=1
    warn "an nftables forward chain drops everything (policy drop, no rules)"
    info "-> build containers have no internet at all; DNS and apt hang instead of failing"
fi

# ------------------------------------------------------------------- repair
if [ "$NEED_DNS" = "1" ]; then
    # Root cause: /etc/resolv.conf points at the loopback stub. The fix belongs on
    # the host - BuildKit copies /etc/resolv.conf verbatim into build containers,
    # so that file has to be usable there.
    if grep -q '^nameserver' /run/systemd/resolve/resolv.conf 2>/dev/null \
       && ! grep -q '^nameserver 127\.' /run/systemd/resolve/resolv.conf; then
        if [ "$DRY" = "1" ]; then
            info "would link /etc/resolv.conf -> /run/systemd/resolve/resolv.conf"
        else
            cp -f /etc/resolv.conf /etc/resolv.conf.stub-backup 2>/dev/null || true
            ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
            ok "linked /etc/resolv.conf -> /run/systemd/resolve/resolv.conf (backup: .stub-backup)"
            CHANGED=1
        fi
    else
        warn "no usable uplink resolv.conf found - check the host resolver manually"
    fi

    # A global "dns" entry in daemon.json is deliberately NOT written any more.
    # It replaces the embedded resolver 127.0.0.11 in every container that is
    # created afterwards - and that resolver is what answers the compose service
    # names (ac-database, ac-authserver). Observed failure:
    #   Could not connect to MySQL database at ac-database:
    #   Unknown MySQL server host 'ac-database' (-3)   + worldserver restart loop
    # The containers get their working DNS from the host resolv.conf repaired
    # above, which is enough for image builds and for the running stack.
    if [ -f /etc/docker/daemon.json ] && grep -q '"dns"' /etc/docker/daemon.json 2>/dev/null; then
        warn "/etc/docker/daemon.json sets a global dns - that breaks the compose service names"
        warn "   containers created afterwards lose 127.0.0.11 and cannot resolve ac-database"
        if [ "${REMOVE_GLOBAL_DNS:-0}" = "1" ]; then
            if [ "$DRY" = "1" ]; then
                info "would remove the dns entry (backup: /etc/docker/daemon.json.bak-dns)"
            elif command -v python3 >/dev/null 2>&1; then
                cp -f /etc/docker/daemon.json /etc/docker/daemon.json.bak-dns 2>/dev/null || true
                python3 - <<'PYEOF'
import json, pathlib
p = pathlib.Path('/etc/docker/daemon.json')
data = json.loads(p.read_text() or '{}')
data.pop('dns', None)
p.write_text(json.dumps(data, indent=2) + '\n')
print('kept keys: ' + (', '.join(sorted(data)) or 'none'))
PYEOF
                ok "dns entry removed (backup: /etc/docker/daemon.json.bak-dns)"
                CHANGED=1
            else
                warn "python3 missing - edit /etc/docker/daemon.json manually"
            fi
            info "recreate the containers afterwards: cd $AC_DIR && docker compose up -d --force-recreate"
        else
            info "remove it with: REMOVE_GLOBAL_DNS=1 bash $0 --build   (or: bash coa-fix-network.sh --runtime)"
        fi
    elif [ "${ALLOW_GLOBAL_DNS:-0}" = "1" ]; then
        # opt-in only, and merged into the file instead of overwriting it
        RESOLVERS="$(host_resolvers | tr '\n' ' ' | sed 's/ *$//')"
        [ -n "$RESOLVERS" ] || RESOLVERS="1.1.1.1 8.8.8.8"
        IFS=' ' read -r -a DNS_LIST <<< "$RESOLVERS"
        DNS_JSON=""
        for d in "${DNS_LIST[@]}"; do
            [ -n "$DNS_JSON" ] && DNS_JSON="$DNS_JSON, "
            DNS_JSON="$DNS_JSON\"$d\""
        done
        if [ "$DRY" = "1" ]; then
            info "would merge dns=[$DNS_JSON] into /etc/docker/daemon.json (ALLOW_GLOBAL_DNS=1)"
        elif command -v python3 >/dev/null 2>&1; then
            [ -f /etc/docker/daemon.json ] && cp -f /etc/docker/daemon.json /etc/docker/daemon.json.bak
            DNS_JSON="$DNS_JSON" python3 - <<'PYEOF'
import json, os, pathlib
p = pathlib.Path('/etc/docker/daemon.json')
data = json.loads(p.read_text() or '{}') if p.exists() else {}
data['dns'] = [x.strip() for x in os.environ['DNS_JSON'].split(',') if x.strip()]
p.write_text(json.dumps(data, indent=2) + '\n')
print('daemon.json keys: ' + ', '.join(sorted(data)))
PYEOF
            warn "dns merged into daemon.json - recreate the containers afterwards, otherwise the"
            warn "running stack keeps its old resolver config: cd $AC_DIR && docker compose up -d --force-recreate"
            CHANGED=1
        else
            warn "python3 missing - cannot merge daemon.json"
        fi
    else
        info "no global dns entry needed - containers use the host resolv.conf plus the embedded 127.0.0.11"
    fi

    if [ "$CHANGED" = "1" ]; then
        restart_docker
    fi
fi

if [ "$NEED_NFT" = "1" ]; then
    if [ "$DRY" = "1" ]; then
        info "would allow docker0/br-*/veth* in the nftables forward chain (runtime + /etc/nftables.conf)"
    else
        info "allowing container forwarding in nftables"
        nft_fw_fix_runtime
        nft_fw_fix_persist
        CHANGED=1
    fi
fi

if [ "$NEED_IPV6" = "1" ] && [ "$SKIP_IPV6_FIX" != "1" ]; then
    if [ "$DRY" = "1" ]; then
        info "would disable IPv6 so apt uses IPv4 immediately"
    else
        info "disabling IPv6 so apt uses IPv4 immediately"
        echo "net.ipv6.conf.all.disable_ipv6 = 1" > /etc/sysctl.d/99-no-ipv6.conf
        sysctl -q -w net.ipv6.conf.all.disable_ipv6=1
        CHANGED=1
        restart_docker
    fi
fi

# ------------------------------------------------------------- verification
if [ "$DRY" = "1" ]; then
    info "DRY-RUN: skipping the container verification"
elif [ "$CHANGED" = "1" ]; then
    container_apt_test; APT_RC=$?
else
    info "no repair was needed based on the evidence"
fi

if [ "$APT_RC" = "1" ]; then
    info "FORWARD chain: $(fw_forward_info)   (a DROP policy is fine as long as dockerRules>0)"
    info "ip_forward: $(sysctl -n net.ipv4.ip_forward 2>/dev/null)   (must be 1)"
fi

info "manual checks:"
info "  host:      curl -sI http://archive.ubuntu.com/ubuntu/ | head -1"
info "  container: docker run --rm $TEST_IMAGE sh -c 'cat /etc/resolv.conf'"
info "  provider:  resolvectl dns | grep -v ':\$'"
info "  IPv6:      curl -6 -sI http://archive.ubuntu.com/ | head -1   (empty/hanging = broken)"
info "  firewall:  iptables -S FORWARD | head -3   (policy + DOCKER rules)"
info "  routing:   sysctl -n net.ipv4.ip_forward  (must be 1)"
info "  proxy?     export HTTP_PROXY/HTTPS_PROXY and add \"proxies\" to /etc/docker/daemon.json"
return 0
}

# ---------------------------------------------------------------------------
#  --runtime : a running stack must be able to resolve ac-database
#              (logic unchanged from fix-container-dns.sh)
# ---------------------------------------------------------------------------
mode_runtime() {
    [ -f "$AC_DIR/docker-compose.yml" ] || { fail "no deployment found at $AC_DIR"; return 1; }
    command -v python3 >/dev/null 2>&1 || warn "python3 not found - a custom dns entry in daemon.json cannot be edited"
# image for the throwaway probe container: the one ac-database already uses, so
# nothing has to be downloaded (fallback only if it cannot be inspected)
DB_IMAGE="$(docker inspect -f '{{.Config.Image}}' ac-database 2>/dev/null)"
[ -n "$DB_IMAGE" ] || DB_IMAGE="mysql:8.4"
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
    local net="$1" out rc img="${DB_IMAGE:-mysql:8.4}"
    [ -n "$net" ] || return 2
    command -v timeout >/dev/null 2>&1 || return 2
    out="$(timeout 60 docker run --rm --network "$net" --entrypoint /bin/sh "$img" \
            -c 'getent hosts ac-database' 2>&1)"
    rc=$?
    printf '%s\n' "$out" > /tmp/coa_dns_probe.txt
    [ "$rc" -eq 127 ] && return 2          # getent is not available in the image
    [ "$rc" -eq 0 ] && [ -n "$out" ] && return 0
    return 1
}
probe_worldserver_networks() {   # 0 = a container next to ac-worldserver resolves ac-database
    local n nets
    nets="$(net_names ac-worldserver)"
    if [ -z "${nets// /}" ]; then
        # a restarting container reports no networks in inspect - the network of
        # ac-database is the same one, so probe that instead of reporting a false
        # "does not resolve"
        info "ac-worldserver is currently $(state_of ac-worldserver) and reports no network - probing the network of ac-database"
        nets="$(net_names ac-database)"
    fi
    for n in $nets; do
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

# ------------------------------------------------------------ repair helpers
compose_recreate() {   # <timeout> <logfile>
    local t="${1:-600}" log="${2:-/tmp/coa_compose_recreate.log}" rc=0
    ( cd "$AC_DIR" && timeout "$t" docker compose up -d --force-recreate ) >"$log" 2>&1 || rc=$?
    tail -6 "$log" | sed 's/^/      /'
    [ "$rc" -eq 0 ] || warn "docker compose up --force-recreate returned ${rc} (124 = ${t}s limit) - log: $log"
    return 0
}
compose_restart_app() {
    ( cd "$AC_DIR" && timeout 180 docker compose restart ac-worldserver ac-authserver ) 2>&1 | tail -3 | sed 's/^/      /'
}
clean_daemon_dns() {   # remove the dns key (backup kept) and restart the daemon
    cp -f /etc/docker/daemon.json /etc/docker/daemon.json.bak-dns 2>/dev/null || true
    if command -v python3 >/dev/null 2>&1 && strip_daemon_json_dns; then
        ok "dns entry removed (backup: /etc/docker/daemon.json.bak-dns)"
    else
        warn "daemon.json left untouched - check it: cat /etc/docker/daemon.json"
    fi
    info "restarting the Docker daemon ..."
    timeout 120 systemctl restart docker >/dev/null 2>&1 || warn "systemctl restart docker timed out"
    for _i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
}

# ------------------------------------------------------------------ 3) repair
step "3/5  Repair"
DB_OK=0
if [ "$DRY" = "1" ]; then
    if ! has_embedded_dns ac-worldserver; then
        info "would recreate the stack (ac-worldserver has no 127.0.0.11 in its resolv.conf)"
        [ -n "$(daemon_json_dns)" ] && info "would remove the dns entry from daemon.json and restart Docker first"
    elif [ "$PROBE" = "0" ]; then
        info "would run: docker compose restart ac-worldserver ac-authserver"
    else
        info "would run: docker compose up -d --force-recreate"
    fi
elif [ "$SKIP_REPAIR" = "1" ]; then
    warn "SKIP_REPAIR=1 - nothing is changed"
elif ! has_embedded_dns ac-worldserver; then
    # the case seen in the field: the container was created while daemon.json
    # carried a custom "dns" entry, so its resolv.conf holds only that server -
    # the embedded resolver 127.0.0.11, which answers the compose service names,
    # is missing. It resolves external names but never 'ac-database'.
    # A restart does not help here (the resolver config stays), the container has
    # to be created again - after cleaning up the cause.
    warn "ac-worldserver has no 127.0.0.11 in its resolv.conf (resolves external names only)"
    if [ -n "$(daemon_json_dns)" ]; then
        warn "cause: daemon.json sets $(daemon_json_dns) - every container created after that gets no embedded resolver"
        clean_daemon_dns
    else
        info "no custom dns entry found - recreating the containers with a fresh resolver config"
    fi
    compose_recreate 600
elif [ "$PROBE" = "0" ]; then
    info "the name resolves on the network - only the container of the worldserver is stale"
    info "restarting ac-worldserver and ac-authserver ..."
    compose_restart_app
else
    info "the name does not resolve on the network - recreating the stack"
    info "(same network, fresh resolver config, re-registered DNS aliases)"
    compose_recreate 600
fi

if [ "$DRY" != "1" ] && [ "$SKIP_REPAIR" != "1" ]; then
    info "waiting for the worldserver to reach the database ..."
    wait_for_db_connection 240 && DB_OK=1
fi

# -------------------------------------------------------------- 4) escalation
if [ "$DRY" != "1" ] && [ "$SKIP_REPAIR" != "1" ] && [ "$DB_OK" = "0" ]; then
    step "4/5  Escalation"
    if [ "$MAX_STEP" -lt 2 ] 2>/dev/null; then
        warn "MAX_STEP=1 - escalation skipped"
    elif [ -n "$(daemon_json_dns)" ]; then
        warn "still failing - cleaning up the custom dns entry and restarting Docker"
        clean_daemon_dns
        compose_recreate 600
        wait_for_db_connection 300 && DB_OK=1
    else
        info "no custom dns entry left - nothing to escalate to"
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
    return 0
fi
if [ "$DRY" = "1" ] || [ "$SKIP_REPAIR" = "1" ]; then
    info "nothing was changed (DRY=1 / SKIP_REPAIR=1) - the checks above show the current state"
    return 0
fi
warn "Not repaired automatically. Please send the output of:"
warn "  docker inspect -f '{{json .NetworkSettings.Networks}}' ac-worldserver ac-database"
warn "  docker inspect -f '{{.ResolvConfPath}}' ac-worldserver | xargs cat"
warn "  journalctl -u docker --since '30 min ago' | tail -30"
return 1

}

# ---------------------------------------------------------------- dispatcher
rc=0
case "$MODE" in
    build)
        mode_build; rc=$?
        ;;
    runtime)
        mode_runtime; rc=$?
        ;;
    all)
        mode_build || true
        echo
        mode_runtime; rc=$?
        ;;
esac
exit "$rc"
