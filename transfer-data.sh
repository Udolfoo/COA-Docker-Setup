#!/usr/bin/env bash
# Copy the client data (dbc/maps/vmaps/mmaps/Cameras) from the old server to
# this one. The CoA world database no longer travels as a file: it is imported
# on this server from the versioned package in the repository checkout
# (bash coa-world-data.sh bootstrap, see apps/coa-world/README.md).
#
# Run this ON THE NEW SERVER. It downloads over plain HTTP from a temporary
# python http.server started on the old server (only while the copy runs).
#
#   1) on the OLD server, in a screen/tmux or detached:
#        VOL=/var/lib/docker/volumes/azerothcore_ac-client-data/_data
#        cd "$VOL" && for s in dbc maps vmaps mmaps Cameras; do tar -cf "/root/client-data-$s.tar" "$s"; done
#        nohup python3 -m http.server 9999 --directory /root >/tmp/http.log 2>&1 &
#   2) on the NEW server:
#        sudo bash transfer-data.sh 85.190.241.176 9999
#
set -uo pipefail

OLD_HOST="${1:-85.190.241.176}"
PORT="${2:-9999}"
AC_DIR="${AC_DIR:-/opt/azerothcore}"
VERSION_MARKER="${VERSION_MARKER:-v20.0}"

ok()   { printf '\033[0;32m[ OK  ]\033[0m %s\n' "$*"; }
info() { printf '\033[0;36m[INFO ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN ]\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m[FAIL ]\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { fail "run as root"; exit 1; }

PROJ="$(grep -E '^COMPOSE_PROJECT_NAME=' "$AC_DIR/.env" 2>/dev/null | cut -d= -f2-)"
VOLNAME="$(grep -E '^DOCKER_VOL_DATA=' "$AC_DIR/.env" 2>/dev/null | cut -d= -f2-)"
[ -n "$VOLNAME" ] || VOLNAME="ac-client-data"
[ -n "$PROJ" ] || PROJ="azerothcore"
VOLUME="$(docker volume inspect "${PROJ}_${VOLNAME}" --format '{{.Mountpoint}}' 2>/dev/null)"
if [ -z "$VOLUME" ]; then
    info "creating docker volume ${PROJ}_${VOLNAME}"
    docker volume create "${PROJ}_${VOLNAME}" >/dev/null
    VOLUME="$(docker volume inspect "${PROJ}_${VOLNAME}" --format '{{.Mountpoint}}')"
fi
[ -n "$VOLUME" ] || { fail "cannot determine the client data volume"; exit 1; }
ok "volume ${PROJ}_${VOLNAME} -> $VOLUME"

echo "=== 1) CoA world database (versioned package in the checkout) ==="
info "no upload needed - imported on this server from the repository package"
if [ -f /root/coa-world-data.sh ]; then
    AC_DIR="$AC_DIR" bash /root/coa-world-data.sh verify \
        && ok "world package present and verified" \
        || warn "world package check failed - see apps/coa-world/README.md"
    info "import it after the base databases exist:  bash /root/coa-world-data.sh bootstrap"
else
    warn "coa-world-data.sh not found in /root - copy it together with the other scripts"
fi

echo
echo "=== 2) client data (dbc, maps, vmaps, mmaps, Cameras) ==="
info "target: $VOLUME"
for sub in dbc maps vmaps mmaps Cameras; do
    info "  $sub ..."
    if curl -fL "http://$OLD_HOST:$PORT/client-data-$sub.tar" -o "/tmp/client-data-$sub.tar"; then
        # replace the directory completely: a mix of two data sets breaks the server
        rm -rf "${VOLUME:?}/$sub"
        mkdir -p "$VOLUME/$sub"
        if tar -xf "/tmp/client-data-$sub.tar" -C "$VOLUME"; then
            ok "  $sub: $(du -sh "$VOLUME/$sub" | cut -f1)"
        else
            warn "  $sub: extraction failed"
        fi
        rm -f "/tmp/client-data-$sub.tar"
    else
        warn "  $sub: not offered by the old server"
    fi
done

echo
echo "=== 3) ownership + version marker (so the init container does not re-download) ==="
chown -R 1000:1000 "$VOLUME"
printf 'INSTALLED_VERSION=%s\n' "$VERSION_MARKER" > "$VOLUME/data-version"
ok "marker: $(cat "$VOLUME/data-version")   owner: $(stat -c '%u:%g' "$VOLUME")"

echo
echo "=== 4) summary ==="
du -sh "$VOLUME"/* 2>/dev/null
echo
echo "next: verify the DBC guard rows, then run the deployment"
echo "  bash /root/coa-check.sh dbc          # 5 required DBC rows"
echo "  bash /root/coa-check.sh world        # CoA world package status + audit"
echo "  bash /root/coa-oneclick.sh           # imports the CoA world if needed, starts the stack"