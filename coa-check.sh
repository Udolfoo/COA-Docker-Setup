#!/usr/bin/env bash
# ===========================================================================
#  coa-check.sh  -  read-only checks for this deployment (changes nothing)
# ---------------------------------------------------------------------------
#  Merged from check-db-access.sh + check-repo-updates.sh; the DBC check that
#  used to live in check-dbc-rows.py is inline in the `dbc` mode now:
#
#   db        databases, MySQL users and a REAL login over the compose network,
#             plus the container resolver state. Answers:
#                "Could not connect to MySQL database at ac-database:
#                 Unknown MySQL server host 'ac-database' (-3)"
#             -> A) does the MySQL container have the databases, and does the
#                   root account work?  B) can the containers resolve each
#                   other (resolv.conf, embedded DNS 127.0.0.11, networks,
#                   aliases, real name lookup)?
#
#   updates   which SQL files shipped in the repo are not registered in the
#             matching updates table yet (auth, characters, world - and
#             acore_playerbots when the optional mod-playerbots is installed).
#             For the complete check in exactly AzerothCore's order:
#                 DRY=1 bash apply-missing-updates.sh
#
#   dbc [dir] verifies the CoA client DBC set the core requires (5 rows);
#             without a directory the client-data volume is used.
#
#   containers  short container status report
#
#   (no argument = all of the above)
#
#  Usage: bash coa-check.sh [db|updates|dbc|containers|all] [dbc-dir]
# ===========================================================================
set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
AC_DIR="${AC_DIR:-/opt/azerothcore}"
MODE="all"
[ $# -gt 0 ] && { MODE="$1"; shift; }
DBC_DIR="${1:-}"

case "$MODE" in
    -h|--help) sed -n '2,40p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^$/d'; exit 0 ;;
    all|db|updates|dbc|containers) ;;
    *) printf 'unknown mode: %s   (bash %s --help)\n' "$MODE" "$0" >&2; exit 2 ;;
esac

cd "$AC_DIR" 2>/dev/null || { echo "cannot enter $AC_DIR (set AC_DIR=...)"; exit 1; }

hdr()  { printf '\n\033[0;36m=== %s ===\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m[ OK  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN ]\033[0m %s\n' "$*"; }
bad()  { printf '\033[0;31m[FAIL ]\033[0m %s\n' "$*"; }
mask() { sed -E 's#(;[^;]*;)[^;]*;#\1***#g'; }

# --- containers -------------------------------------------------------------
mode_containers() {
    hdr "Containers"
    docker ps -a --format '  {{.Names}}: {{.Status}}' | grep -E 'ac-' || true
}

# --- databases + network ----------------------------------------------------
#  from check-db-access.sh - same checks, same output
mode_db() {
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
}

# --- repository SQL updates -------------------------------------------------
#  from check-repo-updates.sh - same checks, same output
mode_updates() {
    PW="${DB_ROOT_PASSWORD:-$(grep -E '^DOCKER_DB_ROOT_PASSWORD=' "$AC_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)}"
    [ -n "$PW" ] || { bad "DB password not found (set DB_ROOT_PASSWORD)"; return 1; }
    REPO="$AC_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/repo.txt"

# collect <db> <dir> - recursive, exactly like apply-missing-updates.sh
collect() {
    local db="$1" dir="$2" p hash
    [ -d "$dir" ] || return 0
    while IFS= read -r p; do
        hash="$(sha1sum "$p" | cut -d' ' -f1 | tr 'a-f' 'A-F')"
        echo "$db|$(basename "$p")|$hash" >> "$tmp/repo.txt"
    done < <(find "$dir" -type f -name '*.sql' 2>/dev/null)
}

for db in auth characters world; do
    collect "acore_$db" "$REPO/data/sql/updates/pending_db_$db"
done
# module SQL (recursive): every directory below modules/<mod>/data/sql/ whose
# name contains the database part - db-world/db-characters/db-auth as well as
# mod-playerbots' data/sql/world and data/sql/characters
for mdir in "$REPO"/modules/*/data/sql/*/; do
    [ -d "$mdir" ] || continue
    case "$(basename "${mdir%/}")" in
        *auth*)       collect acore_auth       "${mdir%/}" ;;
        *characters*) collect acore_characters "${mdir%/}" ;;
        *world*)      collect acore_world      "${mdir%/}" ;;
    esac
done
DBS="acore_auth acore_characters acore_world"
# optional mod-playerbots: the directories its own base SQL registers in
# updates_include (updates/archive/custom of the playerbots database)
PB_SQL="$REPO/modules/mod-playerbots/data/sql/playerbots"
if [ -f "$PB_SQL/base/updates.sql" ]; then
    collect acore_playerbots "$PB_SQL/updates"
    collect acore_playerbots "$PB_SQL/archive"
    collect acore_playerbots "$PB_SQL/custom"
    DBS="$DBS acore_playerbots"
fi
printf "Repo update files : %s%s\n" "$(wc -l < "$tmp/repo.txt")" \
    "$( [ -f "$PB_SQL/base/updates.sql" ] && echo "" || echo "   (mod-playerbots not installed)" )"

for db in $DBS; do
    docker exec -i ac-database mysql -uroot -p"$PW" "$db" -N -B \
        -e "SELECT CONCAT(name, '|', IFNULL(hash,'')) FROM updates" 2>/dev/null \
        > "$tmp/up_$db.txt"
    printf "Registered in %-18s: %s\n" "$db" "$(wc -l < "$tmp/up_$db.txt")"
done

MISSING=0; CHANGED=0
: > "$tmp/report.txt"
while IFS='|' read -r db name hash; do
    [ -n "${name:-}" ] || continue
    dbhash="$(grep -F "$name|" "$tmp/up_$db.txt" | head -1 | cut -d'|' -f2)"
    if [ -z "$dbhash" ]; then
        MISSING=$((MISSING+1)); echo "  MISSING  ${db#acore_}  $name" >> "$tmp/report.txt"
    elif [ "$dbhash" != "$hash" ]; then
        CHANGED=$((CHANGED+1)); echo "  CHANGED  ${db#acore_}  $name" >> "$tmp/report.txt"
    fi
done < "$tmp/repo.txt"

echo "=== Result ==="
printf "  missing (not registered): %s\n" "$MISSING"
printf "  changed (hash differs)  : %s\n" "$CHANGED"
if [ -s "$tmp/report.txt" ]; then
    head -30 "$tmp/report.txt"
    echo "  ... run apply-missing-updates.sh to apply them"
else
    echo "  all repo updates are registered in the matching database"
fi

}

# --- CoA client DBC set -----------------------------------------------------
#  the five rows the fork's DBC guard needs (Rune of Ascension, Blood Parasite,
#  Worldforged pickup, ItemLimitCategory 2414, Map 3690 = Brawler's Guild)
mode_dbc() {
    local proj vol mount dir
    if [ -z "$DBC_DIR" ]; then
        proj="$(grep -E '^COMPOSE_PROJECT_NAME=' .env 2>/dev/null | head -1 | cut -d= -f2-)"
        proj="${proj:-azerothcore}"
        vol="$(grep -E '^DOCKER_VOL_DATA=' .env 2>/dev/null | head -1 | cut -d= -f2-)"
        vol="${vol:-ac-client-data}"
        mount="$(docker volume inspect "${proj}_${vol}" --format '{{.Mountpoint}}' 2>/dev/null)"
        dir="$mount/dbc"
    else
        dir="$DBC_DIR"
    fi
    hdr "CoA client DBC rows"
    if [ ! -d "$dir" ]; then
        bad "DBC directory not found: $dir"
        warn "pass it directly: bash $0 dbc /path/to/dbc"
        return 1
    fi
    echo "  directory: $dir"
    # The id offset per table comes from the core's DBCfmt.h: CurrencyTypes uses
    # "xnxi" (first field skipped), the others start with "n".
    if python3 - "$dir" <<'PYEOF'
import struct
import sys
from pathlib import Path

# (file, required id, id byte offset inside the record, label)
REQUIRED = [
    ("CurrencyTypes.dbc", 375250, 4, "Rune of Ascension"),
    ("CreatureDisplayInfo.dbc", 236827, 0, "Blood Parasite"),
    ("GameObjectDisplayInfo.dbc", 87226, 0, "Worldforged pickup"),
    ("ItemLimitCategory.dbc", 2414, 0, "ItemLimitCategory"),
    ("Map.dbc", 3690, 0, "Brawler's Guild"),
]
HEADER = struct.Struct("<4s4I")

directory = Path(sys.argv[1])
missing = 0
for name, wanted, offset, label in REQUIRED:
    path = directory / name
    if not path.is_file():
        print(f"{name:26} MISSING FILE")
        missing += 1
        continue
    data = path.read_bytes()
    _, rows, fields, record_size, _ = HEADER.unpack_from(data)
    found = [struct.unpack_from("<I", data, HEADER.size + i * record_size + offset)[0]
             for i in range(rows)]
    ok = wanted in found
    missing += 0 if ok else 1
    print(f"{name:26} {'OK' if ok else 'MISSING':7} id {wanted:>8} at offset {offset}  "
          f"({rows} rows, {fields} fields, {record_size} B/record, max id {max(found)})")
print(f"\n{len(REQUIRED) - missing}/{len(REQUIRED)} required rows present")
sys.exit(1 if missing else 0)
PYEOF
    then
        ok "the core's DBC guard is satisfied"
    else
        bad "the client data is missing rows the core requires (see the list above)"
        warn "the client data package must match the core version (CoA Discord)"
        return 1
    fi
}

# ---------------------------------------------------------------- dispatcher
rc=0
case "$MODE" in
    db)         mode_db; rc=$? ;;
    updates)    mode_updates; rc=$? ;;
    dbc)        mode_dbc; rc=$? ;;
    containers) mode_containers; rc=$? ;;
    all)
        mode_containers
        mode_db;        rc=$?
        mode_updates
        mode_dbc || rc=1
        echo
        echo "=== all checks done (nothing was changed) ==="
        ;;
esac
exit "$rc"
