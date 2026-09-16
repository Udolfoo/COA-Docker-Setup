#!/usr/bin/env bash
# ===========================================================================
#  apply-missing-updates.sh
#  Applies SQL updates from the repo to the matching databases
#  (auth / characters / world). Typical case: a CoA world dump was imported
#  and the AzerothCore auto-updater is disabled.
#
#  Routing by source folder (= AzerothCore table `updates_include`):
#    data/sql/updates/db_<db>         -> <db>  RELEASED   (apply pass 1)
#    data/sql/archive/db_<db>         -> <db>  ARCHIVED   (apply pass 1)
#    data/sql/custom/db_<db>          -> <db>  CUSTOM     (apply pass 2)
#    data/sql/updates/pending_db_<db> -> <db>  PENDING    (apply pass 2)
#    modules/*/data/sql/db-<db>       -> <db>  MODULE     (apply pass 2)
#  (data/sql/manual/ and *.sh are ignored - these are manual tools)
#
#  Application order mirrors UpdateFetcher::Update():
#    pass 1: RELEASED + ARCHIVED       - sorted byte-wise by file name
#    pass 2: PENDING + CUSTOM + MODULE - sorted byte-wise by file name
#
#  Registration matches AzerothCore exactly:
#    name = file name including .sql, hash = SHA1 UPPERCASE, state as above.
#  Duplicate key means "content already present" -> registered as applied.
# ===========================================================================

set -uo pipefail

PW="${DB_ROOT_PASSWORD:-$(grep -E '^DOCKER_DB_ROOT_PASSWORD=' /opt/azerothcore/.env 2>/dev/null | head -1 | cut -d= -f2-)}"
[ -n "$PW" ] || { echo "DB password not found (set DB_ROOT_PASSWORD)"; exit 1; }
REPO="${AC_DIR:-/opt/azerothcore}"
LOG="/root/apply-missing-updates.log"

exec > >(tee "$LOG") 2>&1

echo "=== $(date '+%F %T') start ==="
[ "${DRY:-0}" = "1" ] && echo "*** DRY-RUN: nothing is written to the databases ***"

# --- 1) Collect repo files (target DB + state) -----------------------------
# Recursive, exactly like AzerothCore's UpdateFetcher::FillFileListRecursively.
LIST="/tmp/coa_update_files.txt"
ORDERED="/tmp/coa_update_ordered.txt"
: > "$LIST"

collect() {  # <state> <db> <dir>
    local state="$1" db="$2" dir="$3" f
    [ -d "$dir" ] || return 0
    while IFS= read -r f; do
        printf '%s|%s|%s\n' "$state" "$db" "$f" >> "$LIST"
    done < <(find "$dir" -type f -name '*.sql' 2>/dev/null)
}

# Directory -> state mapping taken from the AzerothCore table `updates_include`
# (= UpdateFetcher::ReceiveIncludedDirectories()):
#   data/sql/updates/db_<db>         RELEASED  (pass 1)
#   data/sql/archive/db_<db>         ARCHIVED  (pass 1)
#   data/sql/custom/db_<db>          CUSTOM    (pass 2)
#   data/sql/updates/pending_db_<db> PENDING   (pass 2)
for db in auth characters world; do
    collect RELEASED "acore_$db" "$REPO/data/sql/updates/db_$db"
    collect ARCHIVED "acore_$db" "$REPO/data/sql/archive/db_$db"
    collect CUSTOM   "acore_$db" "$REPO/data/sql/custom/db_$db"
    collect PENDING  "acore_$db" "$REPO/data/sql/updates/pending_db_$db"
done

# Module SQL: any module directory named db-auth / db-characters / db-world
while IFS= read -r mdir; do
    case "$(basename "$mdir")" in
        db-auth)       collect MODULE acore_auth       "$mdir" ;;
        db-characters) collect MODULE acore_characters "$mdir" ;;
        db-world)      collect MODULE acore_world      "$mdir" ;;
    esac
done < <(find "$REPO/modules" -type d \
            \( -name db-auth -o -name db-characters -o -name db-world \) 2>/dev/null)

# --- 1b) Order exactly like AzerothCore's UpdateFetcher::Update() ----------
#   pass 1: RELEASED + ARCHIVED       - sorted byte-wise by file name
#   pass 2: PENDING + CUSTOM + MODULE - sorted byte-wise by file name
#   (C++ compares std::string byte-wise, therefore LC_ALL=C.)
: > "$ORDERED"
for db in acore_auth acore_characters acore_world; do
    awk -F'|' -v d="$db" '$2==d && ($1=="RELEASED" || $1=="ARCHIVED") {n=split($3,a,"/"); print a[n]"|"$1"|"$2"|"$3}' "$LIST" \
        | LC_ALL=C sort -t'|' -k1,1 | cut -d'|' -f2- >> "$ORDERED"
    awk -F'|' -v d="$db" '$2==d && ($1=="PENDING" || $1=="CUSTOM" || $1=="MODULE") {n=split($3,a,"/"); print a[n]"|"$1"|"$2"|"$3}' "$LIST" \
        | LC_ALL=C sort -t'|' -k1,1 | cut -d'|' -f2- >> "$ORDERED"
done

echo "Update files in repo : $(wc -l < "$LIST")"
printf "  auth=%s  characters=%s  world=%s\n" \
    "$(grep -c '|acore_auth|' "$LIST")" \
    "$(grep -c '|acore_characters|' "$LIST")" \
    "$(grep -c '|acore_world|' "$LIST")"
printf "  by state: RELEASED=%s  ARCHIVED=%s  CUSTOM=%s  PENDING=%s  MODULE=%s\n" \
    "$(grep -c '^RELEASED|' "$LIST")" \
    "$(grep -c '^ARCHIVED|' "$LIST")" \
    "$(grep -c '^CUSTOM|' "$LIST")" \
    "$(grep -c '^PENDING|' "$LIST")" \
    "$(grep -c '^MODULE|' "$LIST")"
if [ "${DEBUG_ORDER:-0}" = "1" ]; then
    echo "--- application order (preview) ---"
    head -20 "$ORDERED" | sed 's/^/  /'
fi

# --- 2) Load already registered updates per database (name -> hash) -------
REG="/tmp/coa_registered.txt"
HASHES="/tmp/coa_hashes.txt"
ACTIONS="/tmp/coa_actions.txt"
: > "$REG"
for db in acore_auth acore_characters acore_world; do
    docker exec -i ac-database mysql -uroot -p"$PW" "$db" -N -B \
        -e "SELECT CONCAT(name, '|', IFNULL(hash,'')) FROM updates" 2>/dev/null \
        > "/tmp/coa_db_$db.txt"
    printf "Registered in %-18s: %s\n" "$db" "$(wc -l < "/tmp/coa_db_$db.txt")"
    awk -v d="$db" -F'|' '{ print d "|" $1 "|" $2 }' "/tmp/coa_db_$db.txt" >> "$REG"
done

# SHA1 of every update file in a single pass (AzerothCore uses SHA1 UPPERCASE)
cut -d'|' -f3 "$ORDERED" | LC_ALL=C sort -u > /tmp/coa_paths.txt
xargs -a /tmp/coa_paths.txt sha1sum 2>/dev/null \
    | awk '{ h=toupper($1); p=$0; sub(/^[0-9A-Fa-f]+[ ]+/, "", p); print p "|" h }' > "$HASHES"

# --- 2b) Decide what to apply - one awk pass, mirrors AzerothCore's logic --
#   not registered              -> NEW
#   registered, hash differs    -> CHANGED
#   registered, identical hash  -> already in sync, skip
awk -F'|' '
    FNR==1 { f++ }
    f==1 { h[$1]=$2; next }
    f==2 { r[$1"|"$2]=toupper($3); next }
    f==3 {
        n=split($3,a,"/"); name=a[n]
        hh=h[$3]; rr=r[$2"|"name]
        if (hh == "") next
        if (rr == "")       print $1"|"$2"|"$3"|"name"|"hh"|NEW"
        else if (rr != hh)  print $1"|"$2"|"$3"|"name"|"hh"|CHANGED"
    }' "$HASHES" "$REG" "$ORDERED" > "$ACTIONS"
printf "Updates to apply     : %s NEW / %s CHANGED\n" \
    "$(grep -c '|NEW$' "$ACTIONS")" "$(grep -c '|CHANGED$' "$ACTIONS")"
if [ "${DEBUG_ORDER:-0}" = "1" ]; then
    echo "--- actions (preview) ---"
    head -20 "$ACTIONS" | sed 's/^/  /'
fi

# --- 3) Backup + stop worldserver ----------------------------------------
echo "Backing up updates tables ..."
for db in acore_auth acore_characters acore_world; do
    docker exec -i ac-database mysqldump -uroot -p"$PW" "$db" updates \
        > "/root/updates_backup_$db.sql" 2>/dev/null
    printf "  -> /root/updates_backup_%s.sql (%s lines)\n" "$db" "$(wc -l < "/root/updates_backup_$db.sql")"
done

if [ "${DRY:-0}" = "1" ]; then
    echo "DRY-RUN: worldserver stays running, nothing will be applied"
elif docker ps --format '{{.Names}}' | grep -qx ac-worldserver; then
    echo "Stopping worldserver ..."
    ( cd "$REPO" && docker compose stop ac-worldserver >/dev/null 2>&1 )
fi

# --- 4) Apply missing / changed updates to the matching database ----------
APPLIED=0; DUP=0; FAILED=0; RECHASH=0

apply_and_register() {  # <state> <db> <file> <name> <hash> <tag>
    local state="$1" db="$2" file="$3" name="$4" hash="$5" tag="$6"
    local err
    if [ "${DRY:-0}" = "1" ]; then
        echo "  [WOULD APPLY] ${db#acore_} $tag $name"
        return 0
    fi
    err="$(docker exec -i ac-database mysql -uroot -p"$PW" "$db" < "$file" 2>&1 >/dev/null)"
    if [ $? -eq 0 ]; then
        APPLIED=$((APPLIED+1)); echo "  [OK]       ${db#acore_} $tag $name"
    elif echo "$err" | grep -qi 'Duplicate entry'; then
        DUP=$((DUP+1)); echo "  [EXISTS]   ${db#acore_} $tag $name"
    else
        FAILED=$((FAILED+1)); echo "  [ERROR]    ${db#acore_} $tag $name"
        echo "$err" | tail -3 | sed 's/^/               /'
        return 1
    fi
    echo "INSERT INTO updates (name, hash, state) VALUES ('$name', '$hash', '$state') "\
"ON DUPLICATE KEY UPDATE hash=VALUES(hash), state=VALUES(state);" \
        | docker exec -i ac-database mysql -uroot -p"$PW" "$db" -N -B >/dev/null 2>&1
    return 0
}

while IFS='|' read -r state db file name hash tag; do
    [ -n "${file:-}" ] || continue
    [ "$tag" = "CHANGED" ] && RECHASH=$((RECHASH+1))
    apply_and_register "$state" "$db" "$file" "$name" "$hash" "$tag"
done < "$ACTIONS"

echo
echo "=== Result ==="
printf "  applied        : %s\n" "$APPLIED"
printf "  already present: %s (duplicate entry -> registered)\n" "$DUP"
printf "  hash updated   : %s\n" "$RECHASH"
printf "  errors         : %s\n" "$FAILED"

# --- 5) Start worldserver again ------------------------------------------
if ! docker ps --format '{{.Names}}' | grep -qx ac-worldserver; then
    echo "Starting worldserver ..."
    ( cd "$REPO" && docker compose up -d ac-worldserver >/dev/null 2>&1 )
    for _i in $(seq 1 80); do
        ss -ltn 2>/dev/null | grep -q ":8085 " && break
        sleep 3
    done
fi
printf "Worldserver port 8085 active: %s\n" "$(ss -ltn 2>/dev/null | grep -c ':8085 ')"
echo "=== $(date '+%F %T') end ==="