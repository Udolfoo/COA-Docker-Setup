#!/usr/bin/env bash
# ===========================================================================
#  check-repo-updates.sh
#  Quick read-only check (world database): which pending/module SQL updates
#  shipped in the repo are not registered yet?
#
#  For the complete check of all three databases in exact AzerothCore order:
#      DRY=1 bash apply-missing-updates.sh
#      (lists what WOULD be applied, writes nothing)
# ===========================================================================

set -uo pipefail

PW="${DB_ROOT_PASSWORD:-$(grep -E '^DOCKER_DB_ROOT_PASSWORD=' /opt/azerothcore/.env 2>/dev/null | head -1 | cut -d= -f2-)}"
[ -n "$PW" ] || { echo "DB password not found (set DB_ROOT_PASSWORD)"; exit 1; }
REPO="${AC_DIR:-/opt/azerothcore}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

db_of() {  # <path> -> database name (empty = ignore)
    case "$1" in
        */pending_db_auth/*.sql|*/data/sql/db-auth/*.sql)        echo "acore_auth" ;;
        */pending_db_characters/*.sql|*/data/sql/db-characters/*.sql) echo "acore_characters" ;;
        */pending_db_world/*.sql|*/data/sql/db-world/*.sql)      echo "acore_world" ;;
        *) echo "" ;;
    esac
}

for p in "$REPO"/data/sql/updates/pending_db_auth/*.sql \
         "$REPO"/data/sql/updates/pending_db_characters/*.sql \
         "$REPO"/data/sql/updates/pending_db_world/*.sql \
         "$REPO"/modules/*/data/sql/db-auth/*.sql \
         "$REPO"/modules/*/data/sql/db-characters/*.sql \
         "$REPO"/modules/*/data/sql/db-world/*.sql; do
    [ -f "$p" ] || continue
    db="$(db_of "$p")"
    [ -n "$db" ] || continue
    hash="$(sha1sum "$p" | cut -d' ' -f1 | tr 'a-f' 'A-F')"
    echo "$db|$(basename "$p")|$hash" >> "$tmp/repo.txt"
done
printf "Repo update files : %s\n" "$(wc -l < "$tmp/repo.txt")"

for db in acore_auth acore_characters acore_world; do
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