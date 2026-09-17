#!/usr/bin/env bash
# ===========================================================================
#  check-db-access.sh
#  READ-ONLY diagnosis of the two questions behind
#     "Could not connect to MySQL database at ac-database:
#      Unknown MySQL server host 'ac-database' (-3)"
#
#  A) Does the MySQL container have the databases, and do the user/password
#     that the worldserver uses work?  (checked from inside the compose
#     network, with a throwaway container of the database image - so the
#     result is independent of the broken worldserver container)
#  B) Can the containers resolve each other?  (resolv.conf, embedded DNS
#     127.0.0.11, networks, aliases, real name lookup)
#
#  This script changes NOTHING. It only reads and prints.
#  Usage: bash check-db-access.sh
# ===========================================================================
set -uo pipefail

AC_DIR="${AC_DIR:-/opt/azerothcore}"
cd "$AC_DIR" || { echo "cannot enter $AC_DIR"; exit 1; }

hdr()  { printf '\n\033[0;36m=== %s ===\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m[ OK  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN ]\033[0m %s\n' "$*"; }
bad()  { printf '\033[0;31m[FAIL ]\033[0m %s\n' "$*"; }
mask() { sed -E 's#(;[^;]*;)[^;]*;#\1***#g'; }

hdr "0) Environment"
PW="$(grep -E '^DOCKER_DB_ROOT_PASSWORD=' .env 2>/dev/null | head -1 | cut -d= -f2-)"
if [ -n "$PW" ]; then
    ok "DOCKER_DB_ROOT_PASSWORD found in $AC_DIR/.env (not printed)"
else
    bad "DOCKER_DB_ROOT_PASSWORD not found in $AC_DIR/.env"
fi
DB_IMAGE="$(docker inspect -f '{{.Config.Image}}' ac-database 2>/dev/null)"
[ -n "$DB_IMAGE" ] || DB_IMAGE=mysql:8.4
echo "database image: $DB_IMAGE"

hdr "1) Containers"
docker ps -a --format '  {{.Names}}: {{.Status}}' | grep -E 'ac-' || true

hdr "2) What the worldserver expects (env of its container)"
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' ac-worldserver 2>/dev/null \
    | grep -E '^AC_(LOGIN|WORLD|CHARACTER)_DATABASE_INFO' | sed 's/^/  /' | mask

hdr "3) A) MySQL: databases present?"
if [ -n "$PW" ]; then
    docker exec -i ac-database mysql -uroot -p"$PW" -N -B \
        -e "SELECT table_schema, COUNT(1) FROM information_schema.tables
            WHERE table_schema LIKE 'acore%' GROUP BY table_schema ORDER BY table_schema;" \
        2>/dev/null | sed 's/^/  /' || bad "login as root inside ac-database failed"
    echo "  (name, number of tables)"
else
    warn "no password - skipped"
fi

hdr "4) A) MySQL: users + the account the worldserver uses"
docker exec -i ac-database mysql -uroot -p"$PW" -N -B \
    -e "SELECT user, host FROM mysql.user ORDER BY user, host;" 2>/dev/null | sed 's/^/  /' || true

hdr "5) A) Real connection test over the compose network (DNS + credentials)"
NET="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' ac-database 2>/dev/null | awk '{print $1}')"
echo "  network: ${NET:-unknown}"
if [ -n "$NET" ] && [ -n "$PW" ]; then
    timeout 60 docker run --rm --network "$NET" "$DB_IMAGE" \
        mysql -h ac-database -P 3306 -uroot -p"$PW" -N -B \
        -e "SELECT CONCAT('connected as ', CURRENT_USER(), ' to ', DATABASE()); SHOW DATABASES;" 2>&1 \
        | sed 's/^/  /'
    echo "  (mysql exit above; 'connected as' = credentials + DNS in the network are fine)"
else
    warn "network or password missing - skipped"
fi

hdr "6) B) resolv.conf of the containers"
for c in ac-worldserver ac-database ac-authserver; do
    p="$(docker inspect -f '{{.ResolvConfPath}}' "$c" 2>/dev/null)"
    if [ -n "$p" ] && [ -f "$p" ]; then
        printf '  %-14s %s\n' "$c" "$(grep -v '^#' "$p" | grep -v '^$' | tr '\n' ' ')"
        if grep -q '127\.0\.0\.11' "$p"; then
            ok "$c has the embedded DNS 127.0.0.11"
        else
            bad "$c has NO 127.0.0.11 -> cannot resolve compose service names"
        fi
    else
        warn "$c: resolv.conf not found"
    fi
done

hdr "7) B) Networks and DNS aliases"
for c in ac-worldserver ac-database ac-authserver; do
    printf '  %-14s networks: %s\n' "$c" \
        "$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}({{$v.IPAddress}}) {{end}}' "$c" 2>/dev/null)"
    printf '  %-14s aliases : %s\n' "$c" \
        "$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$v.Aliases}} {{end}}' "$c" 2>/dev/null)"
done

hdr "8) B) Name lookup from inside the network (throwaway container)"
if [ -n "$NET" ]; then
    timeout 60 docker run --rm --network "$NET" --entrypoint /bin/sh "$DB_IMAGE" \
        -c 'getent hosts ac-database || echo "NOT RESOLVABLE"' 2>&1 | sed 's/^/  /'
else
    warn "no network - skipped"
fi

hdr "9) B) Name lookup from the working authserver container"
docker exec ac-authserver sh -c 'cat /etc/resolv.conf; getent hosts ac-database || echo NOT-RESOLVABLE' 2>&1 | sed 's/^/  /'

hdr "10) daemon.json (does it set dns?)"
if [ -f /etc/docker/daemon.json ]; then
    cat /etc/docker/daemon.json | sed 's/^/  /'
else
    echo "  (no /etc/docker/daemon.json)"
fi

hdr "11) Last worldserver errors"
docker logs --tail 40 ac-worldserver 2>&1 | grep -a -E 'Unknown MySQL server host|DatabasePool|Could not connect' | tail -5 | sed 's/^/  /' || true

echo
echo "=== DONE (nothing was changed) ==="