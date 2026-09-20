#!/usr/bin/env bash
# ===========================================================================
#  check-repo-updates.sh
#  Quick read-only check: which SQL updates shipped in the repo are not
#  registered yet? Covers auth, characters, world - and acore_playerbots when
#  the optional mod-playerbots module is installed.
#
#  For the complete check of all databases in exact AzerothCore order:
#      DRY=1 bash apply-missing-updates.sh
#      (lists what WOULD be applied, writes nothing)
# ===========================================================================

set -uo pipefail

PW="${DB_ROOT_PASSWORD:-$(grep -E '^DOCKER_DB_ROOT_PASSWORD=' /opt/azerothcore/.env 2>/dev/null | head -1 | cut -d= -f2-)}"
[ -n "$PW" ] || { echo "DB password not found (set DB_ROOT_PASSWORD)"; exit 1; }
REPO="${AC_DIR:-/opt/azerothcore}"

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
