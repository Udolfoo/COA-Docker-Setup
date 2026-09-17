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
#  Cause 1 - DNS: many servers use systemd-resolved, so /etc/resolv.conf only
#    holds the stub 127.0.0.53. Docker drops loopback resolvers and falls back
#    to 8.8.8.8, which some providers filter (e.g. OVH). The real upstream
#    (e.g. 213.186.33.99) is only visible through `resolvectl`.
#  Cause 2 - IPv6: apt resolves an IPv6 mirror address but the host has no
#    IPv6 route, so every package list waits for the connection timeout.
#
#  Never pulls an image and never blocks: everything is timeout-guarded.
#
#  Usage:  bash fix-build-network.sh          # check, repair what is broken
#          DRY=1 bash fix-build-network.sh    # report only, change nothing
#          SKIP_IPV6_FIX=1 bash fix-build-network.sh
#          TEST_IMAGE=debian:12 bash fix-build-network.sh   # container test image
# ===========================================================================
set -uo pipefail

TEST_IMAGE="${TEST_IMAGE:-ubuntu:24.04}"
TEST_TIMEOUT="${TEST_TIMEOUT:-45}"
DRY="${DRY:-0}"
SKIP_IPV6_FIX="${SKIP_IPV6_FIX:-0}"
CHANGED=0

ok()   { printf '\033[0;32m[ OK  ]\033[0m %s\n' "$*"; }
info() { printf '\033[0;36m[INFO ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN ]\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m[FAIL ]\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { fail "please run as root (sudo bash $0)"; exit 1; }
command -v docker >/dev/null 2>&1 || { fail "docker is not installed"; exit 1; }
[ "$DRY" = "1" ] && info "DRY-RUN: nothing will be changed"

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

restart_docker() {
    if [ "$DRY" = "1" ]; then
        info "would restart the Docker daemon"
        return 0
    fi
    info "restarting the Docker daemon (a few seconds) ..."
    timeout 90 systemctl restart docker >/dev/null 2>&1 || warn "docker restart timed out"
    sleep 4
}

ipv6_usable() {
    [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = "0" ] || return 1
    timeout 8 curl -6 -sI http://archive.ubuntu.com/ >/dev/null 2>&1
}

have_image() { docker image inspect "$1" >/dev/null 2>&1; }

fw_forward_policy() {  # FORWARD policy + number of Docker rules (Docker inserts its own ACCEPTs)
    local pol rules
    pol="$(iptables -S FORWARD 2>/dev/null | sed -n 's/^-P FORWARD //p' | head -1)"
    rules="$(iptables -S FORWARD 2>/dev/null | grep -c DOCKER)"
    if [ -z "$pol" ] && command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
        pol="nftables(FORWARD chains: $(nft list ruleset 2>/dev/null | grep -c 'chain FORWARD'))"
    fi
    echo "policy=${pol:-unknown} dockerRules=${rules}"
}

container_dns_test() {  # 0 = the container resolves names, 1 = it cannot, 2 = no image
    have_image "$TEST_IMAGE" || return 2
    timeout "$TEST_TIMEOUT" docker run --rm "$TEST_IMAGE" \
        sh -c 'getent hosts archive.ubuntu.com >/dev/null 2>&1'
}

container_apt_test() {  # 0 = works, 1 = fails, 2 = not testable (no local image)
    have_image "$TEST_IMAGE" || return 2
    local out=/tmp/coa_apt_test.log attempt rc=1
    for attempt in 1 2; do
        info "apt-get update inside a container (attempt $attempt, max ${TEST_TIMEOUT}s) ..."
        timeout "$TEST_TIMEOUT" docker run --rm "$TEST_IMAGE" \
            sh -c 'apt-get update -qq' > "$out" 2>&1
        rc=$?
        [ "$rc" -eq 0 ] && return 0
        sleep 2
    done
    warn "container apt test failed (rc=$rc) - last output:"
    tail -3 "$out" 2>/dev/null | sed 's/^/        /'
    return 1
}

# ---------------------------------------------------------------- diagnosis
info "host resolvers: $(host_resolvers | tr '\n' ' ')"

if stub_only_resolv_conf; then
    warn "/etc/resolv.conf only holds the systemd-resolved stub (127.0.0.53)"
    info "-> Docker would fall back to 8.8.8.8, which some providers filter"
else
    ok "/etc/resolv.conf lists real resolvers"
fi

if ipv6_usable; then
    ok "IPv6 is usable"
else
    warn "IPv6 is not usable (no route, although addresses may resolve)"
    info "-> apt would wait for the connection timeout on every package list"
fi

container_apt_test
APT_RC=$?
case "$APT_RC" in
    0) ok "apt works inside a container - the build should work" ;;
    2) warn "test image $TEST_IMAGE is not present locally - skipping the container test"
       info "the build itself is the real check; the fixes below use the evidence above" ;;
    *) warn "apt-get update fails inside a container" ;;
esac

if [ "$APT_RC" != "0" ]; then
    # Split the failure: DNS inside the container vs. routing/firewall.
    container_dns_test
    case "$?" in
        0) info "the container resolves names -> DNS is fine, so it is routing/firewall" ;;
        1) warn "the container cannot resolve names -> DNS is the problem" ;;
        2) : ;;
    esac
    info "FORWARD chain: $(fw_forward_policy)   (a DROP policy is fine as long as dockerRules>0)"
    info "ip_forward: $(sysctl -n net.ipv4.ip_forward 2>/dev/null)   (must be 1)"
fi

# ------------------------------------------------------------------- repair
if stub_only_resolv_conf; then
    RESOLVERS="$(host_resolvers | tr '\n' ' ' | sed 's/ *$//')"
    [ -n "$RESOLVERS" ] || RESOLVERS="1.1.1.1 8.8.8.8"
    if [ -f /etc/docker/daemon.json ] && grep -q '"dns"' /etc/docker/daemon.json 2>/dev/null; then
        info "/etc/docker/daemon.json already sets dns - leaving it untouched"
    else
        IFS=' ' read -r -a DNS_LIST <<< "$RESOLVERS"
        DNS_JSON=""
        for d in "${DNS_LIST[@]}"; do
            [ -n "$DNS_JSON" ] && DNS_JSON="$DNS_JSON, "
            DNS_JSON="$DNS_JSON\"$d\""
        done
        if [ "$DRY" = "1" ]; then
            info "would set the Docker DNS servers to [$DNS_JSON] in /etc/docker/daemon.json"
        else
            [ -f /etc/docker/daemon.json ] && cp -f /etc/docker/daemon.json /etc/docker/daemon.json.bak
            info "setting the Docker DNS servers to [$DNS_JSON]"
            printf '{\n  "dns": [%s]\n}\n' "$DNS_JSON" > /etc/docker/daemon.json
            CHANGED=1
            restart_docker
        fi
    fi
fi

if ! ipv6_usable && [ "$SKIP_IPV6_FIX" != "1" ]; then
    if [ "$DRY" = "1" ]; then
        info "would disable IPv6 so apt uses IPv4 immediately (sysctl + /etc/sysctl.d/99-no-ipv6.conf)"
    else
        info "disabling IPv6 so apt uses IPv4 immediately"
        echo "net.ipv6.conf.all.disable_ipv6 = 1" > /etc/sysctl.d/99-no-ipv6.conf
        sysctl -q -w net.ipv6.conf.all.disable_ipv6=1
        CHANGED=1
        restart_docker
    fi
elif ! ipv6_usable; then
    warn "IPv6 is not usable but SKIP_IPV6_FIX=1 - not touching it"
fi

# ------------------------------------------------------------------ verdict
if [ "$CHANGED" = "1" ] && [ "$DRY" != "1" ]; then
    container_apt_test
    case "$?" in
        0) ok "repaired - apt works inside a container now" ;;
        2) ok "repairs applied; verify them with the build (no local test image)" ;;
        *) warn "still failing - see the hints below" ;;
    esac
fi

info "manual checks:"
info "  host:      curl -sI http://archive.ubuntu.com/ubuntu/ | head -1"
info "  container: docker run --rm $TEST_IMAGE sh -c 'cat /etc/resolv.conf'"
info "  provider:  resolvectl dns | grep -v ':\$'"
info "  IPv6:      curl -6 -sI http://archive.ubuntu.com/ | head -1   (empty/hanging = broken)"
info "  firewall:  iptables -S FORWARD | head -3   (policy must be ACCEPT, docker adds its own rules)"
info "  routing:   sysctl -n net.ipv4.ip_forward  (must be 1)"
info "  proxy?     export HTTP_PROXY/HTTPS_PROXY and add \"proxies\" to /etc/docker/daemon.json"
exit 0