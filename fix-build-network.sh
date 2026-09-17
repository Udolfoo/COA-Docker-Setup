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
#  Cause 1 - DNS: with systemd-resolved, /etc/resolv.conf only holds the stub
#    127.0.0.53. Docker drops loopback resolvers and falls back to 8.8.8.8,
#    which some providers filter (e.g. OVH: use 213.186.33.99). The real
#    upstream is only visible through `resolvectl`.
#  Cause 2 - IPv6: apt resolves an IPv6 mirror but the host has no IPv6 route,
#    so every package list waits for the connection timeout.
#
#  Design notes: never pulls an image, never blocks. The container test runs
#  detached and is polled, because a docker CLI waiting on a dead DNS cannot
#  be interrupted by `timeout`. Fixes are applied from the evidence first,
#  the container test only verifies them.
#
#  Usage:  bash fix-build-network.sh          # diagnose, repair, verify
#          DRY=1 bash fix-build-network.sh    # report only, change nothing
#          SKIP_IPV6_FIX=1 bash fix-build-network.sh
#          TEST_IMAGE=debian:12 bash fix-build-network.sh
# ===========================================================================
set -uo pipefail

TEST_IMAGE="${TEST_IMAGE:-ubuntu:24.04}"
TEST_TIMEOUT="${TEST_TIMEOUT:-45}"
DRY="${DRY:-0}"
SKIP_IPV6_FIX="${SKIP_IPV6_FIX:-0}"
CHANGED=0
APT_RC=2

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
    # Root cause: /etc/resolv.conf points at the loopback stub. `docker run`
    # can be helped through daemon.json, but BuildKit copies that file verbatim
    # into build containers, so it must be usable as well.
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
        warn "no usable uplink resolv.conf found - fixing the Docker DNS only"
    fi

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
            info "would set the Docker DNS servers to [$DNS_JSON]"
        else
            [ -f /etc/docker/daemon.json ] && cp -f /etc/docker/daemon.json /etc/docker/daemon.json.bak
            info "setting the Docker DNS servers to [$DNS_JSON]"
            printf '{\n  "dns": [%s]\n}\n' "$DNS_JSON" > /etc/docker/daemon.json
            CHANGED=1
        fi
    fi
    restart_docker
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
exit 0