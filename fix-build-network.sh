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
#  cause is a DNS stub (127.0.0.53 from systemd-resolved) that is not
#  reachable from inside the container network namespace.
#
#  Usage:  bash fix-build-network.sh          # diagnose, repair, verify
# ===========================================================================
set -uo pipefail

TEST_IMAGE="${TEST_IMAGE:-ubuntu:24.04}"
ok()   { printf '\033[0;32m[ OK  ]\033[0m %s\n' "$*"; }
info() { printf '\033[0;36m[INFO ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN ]\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m[FAIL ]\033[0m %s\n' "$*"; }

apt_works() {  # can a fresh container run apt-get update?
    timeout 150 docker run --rm "$TEST_IMAGE" \
        sh -c 'apt-get update -qq >/dev/null 2>&1' >/dev/null 2>&1
}

[ "$(id -u)" -eq 0 ] || { fail "please run as root (sudo bash $0)"; exit 1; }
command -v docker >/dev/null 2>&1 || { fail "docker is not installed"; exit 1; }

info "checking whether a build container can reach the apt mirrors ..."
if apt_works; then
    ok "apt works inside containers - nothing to fix"
    exit 0
fi
warn "apt-get update fails inside a container - repairing"

# --- 1) DNS: pin public resolvers (a 127.0.0.53 stub is not reachable from
#        a container network namespace) -------------------------------------
if [ ! -f /etc/docker/daemon.json ]; then
    info "writing /etc/docker/daemon.json with public DNS servers"
    printf '{\n  "dns": ["1.1.1.1", "8.8.8.8"]\n}\n' > /etc/docker/daemon.json
    systemctl restart docker
    sleep 5
    if apt_works; then ok "fixed by pinning the Docker DNS servers"; exit 0; fi
fi

# --- 2) IPv6 without connectivity: disable it so apt falls back to IPv4 ---
IPV6_USABLE=0
if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = "0" ] \
   && timeout 8 curl -6 -sI http://archive.ubuntu.com/ >/dev/null 2>&1; then
    IPV6_USABLE=1
fi

if [ "$IPV6_USABLE" = "0" ]; then
    info "IPv6 is not usable -> disabling it so apt uses IPv4 at once"
    echo "net.ipv6.conf.all.disable_ipv6 = 1" > /etc/sysctl.d/99-no-ipv6.conf
    sysctl -q -w net.ipv6.conf.all.disable_ipv6=1
    systemctl restart docker
    sleep 5
    if apt_works; then ok "fixed by disabling IPv6"; exit 0; fi
fi

# --- 3) Last resort: does it work with the host network namespace? --------
info "trying the same test with --network=host ..."
if timeout 150 docker run --rm --network=host "$TEST_IMAGE" \
        sh -c 'apt-get update -qq >/dev/null 2>&1'; then
    ok "works with --network=host"
    info "build with:   docker compose build   after adding 'network: host' to the build section"
    exit 0
fi

fail "still failing - the host itself cannot reach the mirrors"
info "check with:  curl -sI http://archive.ubuntu.com/ubuntu/ | head -1"
info "behind a proxy? export HTTP_PROXY/HTTPS_PROXY and add them to /etc/docker/daemon.json"
exit 1