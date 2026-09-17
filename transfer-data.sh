#!/usr/bin/env bash
# Copy the CoA world dump + client data from the old server to this one.
#
# Run this ON THE NEW SERVER. It downloads over plain HTTP from a temporary
# python http.server started on the old server (only while the copy runs).
#
#   1) on the OLD server (85.190.241.176), in a screen/tmux or detached:
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

echo "=== 1) CoA world dump ==="
if [ -s /root/databases.sql.gz ]; then
    ok "already present: $(du -h /root/databases.sql.gz | cut -f1)"
else
    info "downloading http://$OLD_HOST:$PORT/databases.sql.gz"
    curl -fL --progress-bar "http://$OLD_HOST:$PORT/databases.sql.gz" -o /root/databases.sql.gz \
        || { fail "download failed - is the http.server running on the old server?"; exit 1; }
    ok "downloaded $(du -h /root/databases.sql.gz | cut -f1)"
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
echo "next: verify the DBC guard rows, then import the CoA world"
echo "  python3 /root/check-dbc-rows.py $VOLUME/dbc"
echo "  FORCE_IMPORT=1 COA_WORLD_DUMP=/root/databases.sql.gz bash coa-oneclick.sh"