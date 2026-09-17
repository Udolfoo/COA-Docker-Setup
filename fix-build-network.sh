#!/usr/bin/env bash
# ===========================================================================
#  fix-build-network.sh
#  Makes Docker build containers able to reach the distribution mirrors.
#
#  Symptom it fixes:
#     > [skeleton 3/4] RUN apt-get update && apt-get install -y tzdata ...
#     E: Unable to locate package tzdata
#     W: Some index files failed to download (after ~240 s)
#
#  Cause: the container resolves the mirror to an IPv6 address but has no
#  working IPv6 route, so apt waits for the connection to time out. A second
#  cause is a DNS server that is not reachable from inside the container.
#
#  It uses the resolvers the host already uses - never hardcoded public ones,
#  because some providers filter third party resolvers (e.g. OVH).
#
#  Usage:  bash fix-build-network.sh          # diagnose, repair, verify
#          TEST_TIMEOUT=30 bash fix-build-network.sh   # shorter tests
# ===========================================================================
set -uo pipefail

TEST_IMAGE="${TEST_IMAGE:-ubuntu:24.04}"
TEST_TIMEOUT="${TEST_TIMEOUT:-60}"          # seconds per connectivity test
ok()   { printf '\033[0;32m[ OK  ]\033[0m %s\n' "$*"; }
info() { printf '\033[0;36m[INFO ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN ]\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m[FAIL ]\033[0m %s\n' "$*"; }

apt_works() {  # can a fresh container run apt-get update?
    timeout "$TEST_TIMEOUT" docker run --rm "$TEST_IMAGE" \
        sh -c 'apt-get update -qq >/dev/null 2>&1' >/dev/null 2>&1
}

restart_docker() {
    info "restarting the Docker daemon (a few seconds) ..."
    timeout 90 systemctl restart docker >/dev/null 2>&1 || warn "docker restart timed out"
    sleep 5
}

host_resolvers() {  # host upstream resolvers, robust for systemd-resolved per-link DNS
    #  resolvectl dns   ->  "Link 3 (eno1): 213.186.33.99 2001:db8::1"
    #  /run/systemd/resolve/resolv.conf and /etc/resolv.conf as fallbacks
    {
        resolvectl dns 2>/dev/null | sed -n 's/.*: //p'
        sed -n 's/^nameserver[[:space:]]*//p' /run/systemd/resolve/resolv.conf 2>/dev/null
        sed -n 's/^nameserver[[:space:]]*//p' /etc/resolv.conf 2>/dev/null
    } | tr ' ' '\n' \
      | grep -E '^[0-9a-fA-F:.]+$' \
      | grep -v '^127\.' | grep -v '^::1$' | grep -v '^0\.0\.0\.0$' \
      | sort -u | head -3
}

[ "$(id -u)" -eq 0 ] || { fail "please run as root (sudo bash $0)"; exit 1; }
command -v docker >/dev/null 2>&1 || { fail "docker is not installed"; exit 1; }

info "checking whether a build container can reach the apt mirrors (max ${TEST_TIMEOUT}s) ..."
if apt_works; then
    ok "apt works inside containers - nothing to fix"
    exit 0
fi
warn "apt-get update fails inside a container - repairing"
info "host resolvers: $(host_resolvers | tr '\n' ' ')"

# --- 1) DNS ---------------------------------------------------------------
RESOLVERS="$(host_resolvers | tr '\n' ' ')"
[ -n "${RESOLVERS// /}" ] || RESOLVERS="1.1.1.1 8.8.8.8"

if [ -f /etc/docker/daemon.json ]; then
    if grep -q '"dns"' /etc/docker/daemon.json 2>/dev/null; then
        info "/etc/docker/daemon.json already sets dns - leaving it untouched"
        DNS_DONE=1
    else
        info "/etc/docker/daemon.json exists without dns - backing it up and adding dns"
        cp -f /etc/docker/daemon.json /etc/docker/daemon.json.bak 2>/dev/null || true
        DNS_DONE=0
    fi
else
    DNS_DONE=0
fi

if [ "$DNS_DONE" = "0" ]; then
    IFS=' ' read -r -a DNS_LIST <<< "$RESOLVERS"
    DNS_JSON=""
    for d in "${DNS_LIST[@]}"; do
        [ -n "$DNS_JSON" ] && DNS_JSON="$DNS_JSON, "
        DNS_JSON="$DNS_JSON\"$d\""
    done
    info "writing /etc/docker/daemon.json with dns = [$DNS_JSON]"
    printf '{\n  "dns": [%s]\n}\n' "$DNS_JSON" > /etc/docker/daemon.json
    restart_docker
    info "testing again (max ${TEST_TIMEOUT}s) ..."
    if apt_works; then
        ok "fixed by setting the Docker DNS servers"
        exit 0
    fi
    warn "the DNS servers did not help - removing them again"
    mv /etc/docker/daemon.json /etc/docker/daemon.json.rejected 2>/dev/null \
        || rm -f /etc/docker/daemon.json
    restart_docker
fi

# --- 2) IPv6 without connectivity: disable it so apt uses IPv4 at once ----
IPV6_USABLE=0
if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = "0" ] \
   && timeout 10 curl -6 -sI http://archive.ubuntu.com/ >/dev/null 2>&1; then
    IPV6_USABLE=1
fi

if [ "$IPV6_USABLE" = "0" ]; then
    info "IPv6 is not usable -> disabling it so apt uses IPv4 immediately"
    echo "net.ipv6.conf.all.disable_ipv6 = 1" > /etc/sysctl.d/99-no-ipv6.conf
    sysctl -q -w net.ipv6.conf.all.disable_ipv6=1
    restart_docker
    info "testing again (max ${TEST_TIMEOUT}s) ..."
    if apt_works; then
        ok "fixed by disabling IPv6"
        exit 0
    fi
else
    ok "IPv6 works - not touching it"
fi

# --- 3) Last resort: does it work with the host network namespace? --------
info "trying the same test with --network=host (max ${TEST_TIMEOUT}s) ..."
if timeout "$TEST_TIMEOUT" docker run --rm --network=host "$TEST_IMAGE" \
        sh -c 'apt-get update -qq >/dev/null 2>&1'; then
    ok "works with --network=host"
    info "add 'network: host' to the build section of docker-compose.yml"
    info "or build manually with:  docker build --network=host"
    exit 0
fi

fail "still failing - the host itself cannot reach the apt mirrors"
info "check with:   curl -sI http://archive.ubuntu.com/ubuntu/ | head -1"
info "provider DNS: resolvectl status 2>/dev/null || cat /etc/resolv.conf"
info "behind a proxy? export HTTP_PROXY/HTTPS_PROXY and add \"proxies\" to /etc/docker/daemon.json"
exit 1