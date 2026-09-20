#!/usr/bin/env bash
# ============================================================================
#  enable-playerbots.sh  -  optional player bots (mod-playerbots, CoA fork)
# ----------------------------------------------------------------------------
#  Adds the optional playerbot module to an existing deployment - at any time,
#  not only during the first installation. Safe to re-run (idempotent).
#
#  Steps (mode "all"):
#    1/6 Module   : clone/update modules/mod-playerbots (branch "coa" of
#                   Zyth45/mod-playerbots = the CoA port of mod-playerbots)
#    2/6 Config   : create/repair env/dist/etc/modules/playerbots.conf
#                   (CoA defaults, database, bot count) and MapUpdate.Threads
#    3/6 Database : create acore_playerbots, import the module base data
#                   (names, texts, travel nodes) and apply every missing
#                   module update (acore_playerbots + world + characters)
#    4/6 Images   : rebuild the docker images (the module must be compiled in)
#    5/6 Start    : start/restart the stack
#    6/6 Verify   : bots log in, databases filled, log lines
#
#  Why the database work happens here (and not in the container):
#  mod-playerbots normally populates and updates its own database at worldserver
#  startup, but the runtime image contains no module sources - only the
#  db-import image gets "data/" and "modules/". With an empty source directory
#  the worldserver would refuse to start (DBUpdater::Populate fails), so this
#  deployment keeps the module updater off (Playerbots.Updates.EnableDatabases
#  = 0) and applies the SQL from the host - exactly like
#  apply-missing-updates.sh does for auth/characters/world.
#
#  Usage:
#    bash enable-playerbots.sh             # module + config + DB + build + start
#    bash enable-playerbots.sh --prepare   # module + config only (before a build)
#    bash enable-playerbots.sh --config    # config only (sync keys, CoA values)
#    bash enable-playerbots.sh --db        # database only (create + base + updates)
#    bash enable-playerbots.sh --status    # read-only report, changes nothing
#
#  Environment variables (all optional):
#    AC_DIR=/opt/azerothcore          PLAYERBOTS_REPO=<git url>
#    PLAYERBOTS_BRANCH=coa           PLAYERBOTS_REF=<tag or commit> (optional pin)
#    PLAYERBOTS_COUNT=200            random bots (200 ~ 3.5 GB RAM, 1000 ~ 10 GB)
#    PLAYERBOTS_AUTOLOGIN=1          0 = no random bots (only ".playerbots coa ...")
#    PLAYERBOTS_MAP_THREADS=8        (0 = leave worldserver.conf alone)
#    SKIP_BUILD=1                    do not rebuild the images
#    BASE_FORCE=1                    re-import the base data even if the DB exists
#
#  The PLAYERBOTS_* values are remembered in <ac-dir>/.env, so a later update
#  (coa-update.sh) keeps them instead of falling back to the defaults.
# ============================================================================

set -uo pipefail

MODE="all"
case "${1:-}" in
    ""|--all)       MODE="all" ;;
    --prepare)      MODE="prepare" ;;
    --config)       MODE="config" ;;
    --db)           MODE="db" ;;
    --status)       MODE="status" ;;
    -h|--help|help) sed -n '2,50p' "$0"; exit 0 ;;
    *)              echo "Unknown option: $1  (bash $0 --help)"; exit 1 ;;
esac

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
AC_DIR="${AC_DIR:-/opt/azerothcore}"
# Values passed to the script win; otherwise the values stored in
# <ac-dir>/.env (written on the first run) apply; the fallbacks below are the
# documented defaults. This keeps a custom bot count or a pinned module
# revision over module/core updates - coa-update.sh uses "--config" as well.
PLAYERBOTS_REPO="${PLAYERBOTS_REPO:-}"
PLAYERBOTS_BRANCH="${PLAYERBOTS_BRANCH:-}"
PLAYERBOTS_REF="${PLAYERBOTS_REF:-}"
PLAYERBOTS_COUNT="${PLAYERBOTS_COUNT:-}"
PLAYERBOTS_AUTOLOGIN="${PLAYERBOTS_AUTOLOGIN:-}"
PLAYERBOTS_MAP_THREADS="${PLAYERBOTS_MAP_THREADS:-}"
SKIP_BUILD="${SKIP_BUILD:-0}"
BASE_FORCE="${BASE_FORCE:-0}"
WORLD_PORT="${WORLD_PORT:-8085}"

MOD_DIR="$AC_DIR/modules/mod-playerbots"
MOD_SQL="$MOD_DIR/data/sql"
ETC="$AC_DIR/env/dist/etc"
CONF="$ETC/modules/playerbots.conf"
DIST="$MOD_DIR/conf/playerbots.conf.dist"
PB_DB="acore_playerbots"

# ------------------------------------------------------------------ Helpers
c_red='\033[0;31m'; c_grn='\033[0;32m'; c_yel='\033[1;33m'; c_blu='\033[0;36m'; c_off='\033[0m'
log()  { printf "${c_blu}[INFO ]${c_off} %s\n" "$*"; }
ok()   { printf "${c_grn}[ OK  ]${c_off} %s\n" "$*"; }
warn() { printf "${c_yel}[WARN ]${c_off} %s\n" "$*"; }
die()  { printf "${c_red}[FAIL ]${c_off} %s\n" "$*" >&2; exit 1; }
step() { printf "\n${c_grn}=== %s ===${c_off}\n" "$*"; }

# WARNING: never use "cmd | grep -q" for a decision in this script. With
# `set -o pipefail` the early exit of grep makes the pipeline fail with SIGPIPE
# (141), so a log line that IS present looks like "not found".
contains()  { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
port_open() { local o; o="$(ss -ltn 2>/dev/null)"; contains "$o" ":$1 "; }

# ------------------------------------------------- Settings (.env persistence)
env_get() {   # env_get <KEY> -> value or empty
    grep -E "^$1=" "$AC_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-
}
env_put() {   # env_put <KEY> <value>  (adds or replaces the line in .env)
    local key="$1" value="$2" file="$AC_DIR/.env" tmp esc
    [ -f "$file" ] || return 0
    esc="${value//&/\\&}"
    if grep -qE "^${key}=" "$file"; then
        tmp="$(mktemp)"
        sed "s|^${key}=.*|${key}=${esc}|" "$file" > "$tmp" && cat "$tmp" > "$file"
        rm -f "$tmp"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}
resolve_settings() {   # command line > .env > documented default
    PLAYERBOTS_REPO="${PLAYERBOTS_REPO:-$(env_get PLAYERBOTS_REPO)}"
    PLAYERBOTS_REPO="${PLAYERBOTS_REPO:-https://github.com/Zyth45/mod-playerbots.git}"
    PLAYERBOTS_BRANCH="${PLAYERBOTS_BRANCH:-$(env_get PLAYERBOTS_BRANCH)}"
    PLAYERBOTS_BRANCH="${PLAYERBOTS_BRANCH:-coa}"
    PLAYERBOTS_REF="${PLAYERBOTS_REF:-$(env_get PLAYERBOTS_REF)}"
    PLAYERBOTS_COUNT="${PLAYERBOTS_COUNT:-$(env_get PLAYERBOTS_COUNT)}"
    PLAYERBOTS_COUNT="${PLAYERBOTS_COUNT:-200}"
    PLAYERBOTS_AUTOLOGIN="${PLAYERBOTS_AUTOLOGIN:-$(env_get PLAYERBOTS_AUTOLOGIN)}"
    PLAYERBOTS_AUTOLOGIN="${PLAYERBOTS_AUTOLOGIN:-1}"
    PLAYERBOTS_MAP_THREADS="${PLAYERBOTS_MAP_THREADS:-$(env_get PLAYERBOTS_MAP_THREADS)}"
    PLAYERBOTS_MAP_THREADS="${PLAYERBOTS_MAP_THREADS:-8}"
}
store_settings() {     # remember the settings for the next run / update
    env_put PLAYERBOTS_REPO "$PLAYERBOTS_REPO"
    env_put PLAYERBOTS_BRANCH "$PLAYERBOTS_BRANCH"
    env_put PLAYERBOTS_COUNT "$PLAYERBOTS_COUNT"
    env_put PLAYERBOTS_AUTOLOGIN "$PLAYERBOTS_AUTOLOGIN"
    env_put PLAYERBOTS_MAP_THREADS "$PLAYERBOTS_MAP_THREADS"
    [ -n "$PLAYERBOTS_REF" ] && env_put PLAYERBOTS_REF "$PLAYERBOTS_REF"
    return 0
}

mysql_q() {     # mysql_q "<sql>" [db]
    local sql="$1" db="${2:-}"
    if [ -n "$db" ]; then
        docker exec -i ac-database mysql -uroot -p"$DB_ROOT_PASSWORD" "$db" -N -B -e "$sql" 2>/dev/null
    else
        docker exec -i ac-database mysql -uroot -p"$DB_ROOT_PASSWORD" -N -B -e "$sql" 2>/dev/null
    fi
}
mysql_file() {  # mysql_file <file> [db]
    local file="$1" db="${2:-}"
    if [ -n "$db" ]; then
        docker exec -i ac-database mysql -uroot -p"$DB_ROOT_PASSWORD" "$db" < "$file"
    else
        docker exec -i ac-database mysql -uroot -p"$DB_ROOT_PASSWORD" < "$file"
    fi
}

ws_state()    { docker inspect -f '{{.State.Status}}' ac-worldserver 2>/dev/null || echo missing; }
ws_restarts() { docker inspect -f '{{.RestartCount}}' ac-worldserver 2>/dev/null || echo 0; }
ws_log()      { docker logs --tail 300 ac-worldserver 2>&1; }
ws_last_log() { local o; o="$(docker logs --tail 1 ac-worldserver 2>&1)"; printf '%s\n' "${o: -90}"; }
ws_running() {   # 0 = the container exists and runs
    local o n
    o="$(docker ps --format '{{.Names}}' 2>/dev/null)"
    for n in $o; do [ "$n" = 'ac-worldserver' ] && return 0; done
    return 1
}
ws_up() {
    local o
    o="$(ws_log)"
    contains "$o" 'World Initialized' && return 0
    port_open "$WORLD_PORT" && return 0
    return 1
}
ws_diag() {
    echo "  --- diagnostics ---"
    docker ps -a --format '  {{.Names}}: {{.Status}}' 2>/dev/null \
        | grep -E 'ac-(worldserver|authserver|database|db-import|client-data-init)' || true
    echo "  last log lines of ac-worldserver:"
    docker logs --tail 30 ac-worldserver 2>&1 | sed 's/^/    /' || true
    echo "  details: docker logs ac-worldserver   /   df -h /"
}
ws_wait() {   # <max_seconds> -> 0 = up, 1 = not up (diagnostics printed)
    local max="${1:-420}" waited=0 state restarts
    while [ "$waited" -lt "$max" ]; do
        if ws_up; then
            printf "  worldserver is up after %ss.\n" "$waited"
            return 0
        fi
        state="$(ws_state)"; restarts="$(ws_restarts)"
        case "$state" in
            running|created|starting|paused|restarting) ;;
            *)
                printf "  worldserver container state is '%s' after %ss - it did not start.\n" "$state" "$waited"
                ws_diag
                return 1 ;;
        esac
        if [ "${restarts:-0}" -gt 2 ] 2>/dev/null; then
            printf "  worldserver restarted %s times without coming up - crash loop.\n" "$restarts"
            ws_diag
            return 1
        fi
        if [ $((waited % 15)) -eq 0 ]; then
            printf "  ... waiting for worldserver: %ss (state=%s restarts=%s) last log: %s\n" \
                "$waited" "$state" "$restarts" "$(ws_last_log)"
        fi
        sleep 3
        waited=$((waited + 3))
    done
    printf "  worldserver did not come up within %ss.\n" "$max"
    ws_diag
    return 1
}


# ------------------------------------------------------- 2) Config sync
# Sets in ~10 lines of python (work order matters):
#   a) every key of the module template that playerbots.conf does not have yet
#      is appended with its default value - a module update adds new keys, and
#      a key that is not defined anywhere logs "Missing property" on every read
#      (tens of thousands of lines per day) and silently falls back to the code
#      default. This deployment never defines a key twice ("Duplicate key name"
#      is logged and the first definition wins).
#   b) the values this deployment manages: CoA values from README_COA.md of the
#      module, the playerbots database on the compose network, bot count.
#   c) MapUpdate.Threads in worldserver.conf (the stock default is 1 - hundreds
#      of bots need several map threads; the value is only raised, never
#      lowered, and 0 switches it off).
WS_CONF_CHANGED=0
WS_CONF_PENDING=0

sync_config() {
    [ -d "$MOD_DIR" ] || die "module not installed: $MOD_DIR (run this script without --config first)"
    [ -f "$DIST" ]    || die "module config template missing: $DIST"
    mkdir -p "$ETC/modules"
    if [ ! -f "$CONF" ]; then
        cp "$DIST" "$CONF"
        ok "playerbots.conf created from the module template"
    else
        ok "playerbots.conf present (values are synced below)"
    fi
    # keep the reference next to it in sync with the installed module (the
    # entrypoint only copies templates with "no clobber", so this file wins)
    cp -f "$DIST" "$ETC/modules/playerbots.conf.dist"

    case "$DB_ROOT_PASSWORD" in
        *';'*) warn "the DB password contains ';' - PlayerbotsDatabaseInfo cannot be written safely" ;;
    esac

    local dbspec="ac-database;3306;root;${DB_ROOT_PASSWORD};${PB_DB}"
    local out rc=0
    out="$(python3 - "$DIST" "$CONF" "$dbspec" "$PLAYERBOTS_COUNT" "$PLAYERBOTS_AUTOLOGIN" \
                        "$ETC/worldserver.conf" "$PLAYERBOTS_MAP_THREADS" <<'PYEOF'
import pathlib, re, sys

dist_p, conf_p, dbspec, count, autologin, ws_p, map_threads = sys.argv[1:8]
KEY = re.compile(r'^([A-Za-z][A-Za-z0-9_.\-]*)\s*=\s*(.*)$')

def read_lines(path):
    return pathlib.Path(path).read_text(encoding='utf-8', errors='replace').split('\n')

def key_of(line):
    if line.lstrip().startswith('#'):
        return None
    m = KEY.match(line)
    return m.group(1) if m else None

MANAGED = {
    'AiPlayerbot.Enabled': '1',
    'AiPlayerbot.RandomBotAutologin': autologin,
    'AiPlayerbot.MinRandomBots': count,
    'AiPlayerbot.MaxRandomBots': count,
    'AiPlayerbot.ZoneChannelId': '3',
    'AiPlayerbot.BroadcastWorldChannelName': '"Ascension"',
    'AiPlayerbot.CoaSpecRotations': '1',
    'AiPlayerbot.BotActiveAlone': '60',
    'AiPlayerbot.GroupInvitationPermission': '2',
    'PlayerbotsDatabaseInfo': '"%s"' % dbspec,
    'Playerbots.Updates.EnableDatabases': '0',
}

out, seen, set_keys, added_keys = [], set(), [], []
for line in read_lines(conf_p):
    key = key_of(line)
    if key and key in MANAGED:
        seen.add(key)
        new = '%s = %s' % (key, MANAGED[key])
        if line.strip() != new:
            set_keys.append(key)
        out.append(new)
    else:
        if key:
            seen.add(key)
        out.append(line.rstrip())
for key, value in MANAGED.items():
    if key not in seen:
        out.append('%s = %s' % (key, value))
        added_keys.append(key)
        seen.add(key)
appended = []
for line in read_lines(dist_p):
    key = key_of(line)
    if not key or key in seen:
        continue
    out.append(line.rstrip())
    seen.add(key)
    appended.append(key)
while out and out[-1] == '':
    out.pop()
pathlib.Path(conf_p).write_text('\n'.join(out) + '\n', encoding='utf-8', newline='\n')
print('playerbots.conf : %d managed value(s) set, %d key(s) added, %d default(s) taken from the template'
      % (len(set_keys), len(added_keys), len(appended)))
if set_keys:
    print('    set      : ' + ', '.join(sorted(set_keys)))
if appended:
    print('    new      : ' + ', '.join(appended[:8]) + (' ...' if len(appended) > 8 else ''))

changed = 0
try:
    threads = int(map_threads)
except ValueError:
    threads = 0
ws = pathlib.Path(ws_p)
if threads > 0 and ws.exists():
    lines = read_lines(ws_p)
    index, current = None, None
    for i, line in enumerate(lines):
        if key_of(line) == 'MapUpdate.Threads':
            index = i
            try:
                current = int(KEY.match(line).group(2).split('#')[0].strip())
            except ValueError:
                current = 0
            break
    if current is None:
        lines.append('MapUpdate.Threads = %d' % threads)
        changed = 1
        print('worldserver.conf : MapUpdate.Threads = %d added (bots need map threads)' % threads)
    elif current < threads:
        lines[index] = 'MapUpdate.Threads = %d # raised by enable-playerbots.sh' % threads
        changed = 1
        print('worldserver.conf : MapUpdate.Threads %d -> %d (bots need map threads)' % (current, threads))
    else:
        print('worldserver.conf : MapUpdate.Threads = %d (ok)' % current)
    if changed:
        pathlib.Path(ws_p).write_text('\n'.join(l.rstrip() for l in lines).rstrip() + '\n',
                                      encoding='utf-8', newline='\n')
else:
    print('worldserver.conf : not created yet - MapUpdate.Threads is set on the next run')
    print('WORLDSERVER_PENDING=1')
if changed:
    print('WORLDSERVER_CHANGED=1')
PYEOF
    )" || rc=$?
    [ "$rc" -eq 0 ] || die "config sync failed (python3 missing? rc=$rc)"
    printf '%s\n' "$out" | sed 's/^/      /'
    contains "$out" 'WORLDSERVER_CHANGED=1' && WS_CONF_CHANGED=1
    contains "$out" 'WORLDSERVER_PENDING=1' && WS_CONF_PENDING=1
    chown 1000:1000 "$CONF" "$ETC/modules/playerbots.conf.dist" 2>/dev/null || true
    return 0
}


# ------------------------------------------------------------ 1) Module
module_sync() {
    mkdir -p "$AC_DIR/modules"
    if [ ! -d "$MOD_DIR" ]; then
        log "Cloning ${PLAYERBOTS_REPO} (branch ${PLAYERBOTS_BRANCH})"
        git clone --branch "$PLAYERBOTS_BRANCH" "$PLAYERBOTS_REPO" "$MOD_DIR" >/dev/null 2>&1 \
            || die "git clone failed - check the network and PLAYERBOTS_REPO"
    elif [ -d "$MOD_DIR/.git" ]; then
        log "Fetching module updates (branch ${PLAYERBOTS_BRANCH})"
        if git -C "$MOD_DIR" fetch --prune origin "$PLAYERBOTS_BRANCH" >/dev/null 2>&1; then
            git -C "$MOD_DIR" checkout -q -B "$PLAYERBOTS_BRANCH" FETCH_HEAD >/dev/null 2>&1 \
                || warn "checkout failed - keeping the current revision (local changes?)"
        else
            warn "git fetch failed - keeping the current revision"
        fi
    else
        warn "$MOD_DIR exists but is not a git clone - using it as it is"
    fi
    if [ -n "$PLAYERBOTS_REF" ]; then
        log "Switching to PLAYERBOTS_REF=${PLAYERBOTS_REF}"
        git -C "$MOD_DIR" checkout -q "$PLAYERBOTS_REF" >/dev/null 2>&1 \
            || die "cannot check out PLAYERBOTS_REF=${PLAYERBOTS_REF} (try: git -C $MOD_DIR fetch --tags)"
    fi
    [ -f "$MOD_SQL/playerbots/base/updates.sql" ] \
        || die "unexpected module layout: $MOD_SQL/playerbots/base/updates.sql is missing"
    ok "module installed: $(git -C "$MOD_DIR" rev-parse --short HEAD 2>/dev/null || echo 'no git revision')"
    local tags
    tags="$(git -C "$MOD_DIR" tag --list 'bots-*' 2>/dev/null | tail -3 | tr '\n' ' ')"
    [ -n "$tags" ] && log "CoA bot releases available for pinning: $tags"
    return 0
}

# ------------------------------------------------------------ 3) Database
# The module ships its own database. AzerothCore fills an empty database from
# the module base files (DBUpdater::Populate) and then applies every file of the
# include paths; this is that step, done from the host:
#   base   -> modules/mod-playerbots/data/sql/playerbots/base/*.sql (sorted by name)
#   update -> .../playerbots/{updates,archive,custom} (RELEASED/ARCHIVED/CUSTOM,
#             registered in acore_playerbots.updates) plus the module SQL for the
#             world and characters database (applied as MODULE by the same helper
#             the core updates use: apply-missing-updates.sh)
db_sync() {
    docker compose up -d ac-database >/dev/null 2>&1
    for _i in $(seq 1 30); do
        [ "$(docker inspect --format '{{.State.Health.Status}}' ac-database 2>/dev/null)" = "healthy" ] && break
        sleep 2
    done
    [ "$(docker inspect --format '{{.State.Health.Status}}' ac-database 2>/dev/null)" = "healthy" ] \
        || warn "ac-database is not healthy - the import may fail (docker logs ac-database)"

    local tables has_updates
    tables="$(mysql_q "SELECT COUNT(1) FROM information_schema.tables WHERE table_schema='${PB_DB}'" | head -1)"
    if [ "${tables:-0}" = "0" ]; then
        log "Creating the database ${PB_DB}"
        mysql_q "CREATE DATABASE IF NOT EXISTS \`${PB_DB}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci" >/dev/null \
            || die "cannot create ${PB_DB} (is ac-database running?)"
        ok "database ${PB_DB} created (utf8mb4 / utf8mb4_general_ci, like the module's create_mysql.sql)"
    else
        ok "database ${PB_DB} present (${tables} tables)"
    fi

    has_updates="$(mysql_q "SELECT COUNT(1) FROM information_schema.tables WHERE table_schema='${PB_DB}' AND table_name='updates'" | head -1)"
    if [ "${has_updates:-0}" = "0" ] || [ "$BASE_FORCE" = "1" ]; then
        log "Importing the module base data (names, texts, travel nodes - a few minutes)"
        local f n=0 start="$SECONDS" err size
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            n=$((n + 1))
            size="$(du -h "$f" 2>/dev/null | cut -f1)"
            printf "      [%2d] %-46s %s\n" "$n" "$(basename "$f")" "$size"
            # Judge by the exit code, never by stderr: the mysql client always
            # writes "Using a password on the command line interface can be
            # insecure" to stderr, which used to look like a failed import.
            err="$(mysql_file "$f" "$PB_DB" 2>&1 >/dev/null)"; rc=$?
            err="$(printf '%s\n' "$err" \
                   | grep -v 'Using a password on the command line interface' \
                   | grep -v '^$' | tail -3)"
            if [ "$rc" -ne 0 ]; then
                case "$err" in
                    *'Duplicate entry'*) warn "$(basename "$f"): rows already present - treated as imported" ;;
                    *'already exists'*)  warn "$(basename "$f"): objects already present - treated as imported" ;;
                    *) die "base import failed at $(basename "$f") (mysql exit ${rc}): ${err:-no message}" ;;
                esac
            fi
        done < <(find "$MOD_SQL/playerbots/base" -maxdepth 1 -name '*.sql' | LC_ALL=C sort)
        ok "${n} base file(s) imported in $((SECONDS - start))s"
    else
        ok "base data already in ${PB_DB} (BASE_FORCE=1 imports it again)"
    fi

    if [ -f "$SCRIPT_DIR/apply-missing-updates.sh" ]; then
        log "Applying missing module updates (acore_playerbots + world + characters) ..."
        DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" AC_DIR="$AC_DIR" NO_START=1 \
            bash "$SCRIPT_DIR/apply-missing-updates.sh" \
            || warn "update run reported errors - log: /root/apply-missing-updates.log"
    else
        warn "apply-missing-updates.sh not found next to this script - module updates are NOT applied"
    fi
    return 0
}


# --------------------------------------------------------------- Status
status_report() {
    if [ ! -d "$MOD_DIR" ]; then
        warn "module     : not installed ($MOD_DIR)"
        echo "             install it with: bash $(basename "$0")"
        return 0
    fi
    ok "module     : $(git -C "$MOD_DIR" rev-parse --short HEAD 2>/dev/null || echo '?') ($(git -C "$MOD_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?'))"
    if [ -f "$CONF" ]; then
        ok "config     : playerbots.conf ($(grep -c -E '^[A-Za-z][A-Za-z0-9_.-]*[[:space:]]*=' "$CONF" 2>/dev/null) keys, bots ${PLAYERBOTS_COUNT}, autologin ${PLAYERBOTS_AUTOLOGIN})"
    else
        warn "config     : playerbots.conf missing -> bash $(basename "$0") --config"
    fi

    local tag img
    tag="$(grep -E '^DOCKER_IMAGE_TAG=' "$AC_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)"
    img="acore/ac-wotlk-worldserver:${tag:-coa}"
    if docker image inspect "$img" >/dev/null 2>&1; then
        if docker run --rm --entrypoint /bin/ls "$img" /azerothcore/env/ref/etc/modules 2>/dev/null \
             | grep -q '^playerbots\.conf\.dist$'; then
            ok "image      : $img contains the module"
        else
            warn "image      : $img was built WITHOUT the module -> docker compose build"
        fi
    else
        warn "image      : $img does not exist yet -> docker compose build"
    fi

    local tables
    tables="$(mysql_q "SELECT COUNT(1) FROM information_schema.tables WHERE table_schema='${PB_DB}'" | head -1)"
    if [ "${tables:-0}" != "0" ]; then
        ok "database   : ${PB_DB} (${tables} tables)"
        local q_names q_texts q_nodes q_acc
        q_names="$(mysql_q 'SELECT COUNT(1) FROM playerbots_names' "$PB_DB" | head -1)"
        q_texts="$(mysql_q 'SELECT COUNT(1) FROM ai_playerbot_texts' "$PB_DB" | head -1)"
        q_nodes="$(mysql_q 'SELECT COUNT(1) FROM playerbots_travelnode' "$PB_DB" | head -1)"
        q_acc="$(mysql_q "SELECT COUNT(1) FROM account WHERE username LIKE 'rndbot%'" acore_auth | head -1)"
        printf "             base rows : names=%s texts=%s travelnodes=%s\n" \
            "${q_names:-n/a}" "${q_texts:-n/a}" "${q_nodes:-n/a}"
        printf "             bot pool  : %s bot accounts (rndbot*)\n" "${q_acc:-n/a}"
    else
        warn "database   : ${PB_DB} missing or empty -> bash $(basename "$0") --db"
    fi

    ok "worldserver: $(ws_state), port ${WORLD_PORT} $(port_open "$WORLD_PORT" && echo open || echo closed)"
    printf "             playerbot log lines (last 60 min): %s\n" \
        "$(docker logs --since 60m ac-worldserver 2>&1 | grep -aci playerbot)"
    if [ -f "$AC_DIR/env/dist/logs/Playerbots.log" ]; then
        printf "             %s (%s)\n" "env/dist/logs/Playerbots.log" \
            "$(du -h "$AC_DIR/env/dist/logs/Playerbots.log" 2>/dev/null | cut -f1)"
    fi
    docker logs --since 60m ac-worldserver 2>&1 \
        | grep -ai 'randombot accounts\|new bots prepared to login' | tail -3 | sed 's/^/             /'
    return 0
}


# ============================================================================
#  Main
# ============================================================================
echo "=== $(date '+%F %T')  enable-playerbots.sh  (mode: ${MODE}) ==="

step "0/6  Preflight"
[ "$(id -u)" -eq 0 ] || warn "not running as root - use: sudo bash $(basename "$0")"
[ -d "$AC_DIR" ]     || die "no deployment at $AC_DIR (set AC_DIR=...)"
[ -d "$AC_DIR/.git" ]|| die "$AC_DIR is not a git clone - run coa-oneclick.sh first"
[ -f "$AC_DIR/.env" ]|| die ".env missing in $AC_DIR - run coa-oneclick.sh first"
DB_ROOT_PASSWORD="$(grep -E '^DOCKER_DB_ROOT_PASSWORD=' "$AC_DIR/.env" | head -1 | cut -d= -f2-)"
[ -n "$DB_ROOT_PASSWORD" ] || die "DOCKER_DB_ROOT_PASSWORD not found in $AC_DIR/.env"
cd "$AC_DIR" || die "cannot enter $AC_DIR"
resolve_settings

if [ "$MODE" = "status" ]; then
    if ! command -v docker >/dev/null 2>&1; then
        warn "docker not found - the report is limited to files and git"
    fi
    step "Status"
    status_report
    exit 0
fi

if [ "$MODE" = "all" ] || [ "$MODE" = "db" ]; then
    command -v docker >/dev/null 2>&1 || die "docker not found"
    docker compose version >/dev/null 2>&1 || die "docker compose not available"
else
    # --prepare / --config only touch files (module, configs)
    command -v docker >/dev/null 2>&1 || warn "docker not found - the image/database checks are skipped"
fi
ok "deployment: $AC_DIR"
log "bots: ${PLAYERBOTS_COUNT} random bots (autologin ${PLAYERBOTS_AUTOLOGIN}), map threads ${PLAYERBOTS_MAP_THREADS}"

if [ "$MODE" = "all" ] || [ "$MODE" = "prepare" ]; then
    step "1/6  Module: mod-playerbots (CoA fork)"
    module_sync
fi

if [ "$MODE" = "all" ] || [ "$MODE" = "prepare" ] || [ "$MODE" = "config" ]; then
    step "2/6  Config: playerbots.conf"
    sync_config
    store_settings
fi

if [ "$MODE" = "all" ] || [ "$MODE" = "db" ]; then
    step "3/6  Database: ${PB_DB}"
    db_sync
fi

if [ "$MODE" = "all" ]; then
    step "4/6  Docker images"
    if [ "$SKIP_BUILD" = "1" ]; then
        warn "build skipped (SKIP_BUILD=1) - the bots stay inactive until the module is compiled in"
    else
        # A fresh VPS often fails here: a build container cannot reach the apt
        # mirrors (broken IPv6 or a DNS stub). Same preflight as coa-update.sh.
        if [ -f "$SCRIPT_DIR/fix-build-network.sh" ]; then
            log "Network preflight: checking container DNS/IPv6 (hard limit 5 minutes) ..."
            timeout 300 bash "$SCRIPT_DIR/fix-build-network.sh" \
                || warn "Network preflight reported a problem - trying the build anyway"
        fi
        log "docker compose build (the module must be compiled in; cached rebuild: 1-15 minutes)"
        if ! docker compose build; then
            warn "Build failed - retrying once (transient mirror/network problems)"
            sleep 10
            docker compose build || die "image build failed (see README troubleshooting: apt/DNS/IPv6)"
        fi
        ok "Images rebuilt (tag: $(grep -E '^DOCKER_IMAGE_TAG=' .env | head -1 | cut -d= -f2-))"
        docker image prune -f >/dev/null 2>&1 || true
        docker builder prune -f --keep-storage 8GB >/dev/null 2>&1 || true
    fi
    if [ "$WS_CONF_CHANGED" = "1" ]; then
        warn "worldserver.conf was changed (MapUpdate.Threads) - the restart below applies it"
    fi

    step "5/6  Start"
    COMPOSE_LOG="/tmp/coa_compose_up.log"
    rc=0
    ( timeout 300 docker compose up -d ) >"$COMPOSE_LOG" 2>&1 || rc=$?
    tail -6 "$COMPOSE_LOG" | sed 's/^/      /'
    if [ "$rc" -ne 0 ]; then
        warn "docker compose up returned ${rc} (124 = 5 minute limit: a dependency never became ready)"
        tail -20 "$COMPOSE_LOG" | sed 's/^/      /'
    fi
    log "Waiting for the worldserver (progress below, limit 7 minutes) ..."
    ws_wait 420 && ok "worldserver is up" \
                || warn "worldserver is NOT up - fix the cause shown above, then watch: docker logs -f ac-worldserver"

    # The core marks a realm offline when the worldserver stops and sets a
    # version-mismatch bit on startup; both make the client show "Realm
    # Offline", so the flag is cleared once the world is really running.
    if ws_up; then
        CUR_FLAG="$(mysql_q 'SELECT flag FROM realmlist WHERE id=1' acore_auth | head -1)"
        if [ "${CUR_FLAG:-0}" != "0" ]; then
            mysql_q 'UPDATE realmlist SET flag = flag & ~3 WHERE id=1' acore_auth >/dev/null 2>&1
            ok "realm flag cleared (was ${CUR_FLAG}; offline/mismatch bits removed)"
        else
            ok "realm flag is 0 (online)"
        fi
    fi

    # On the very first start the container creates env/dist/etc from the image
    # (the entrypoint). worldserver.conf did not exist during the config step
    # then, so apply the map threads now and restart once if it changed.
    if [ "$WS_CONF_PENDING" = "1" ]; then
        if [ -f "$ETC/worldserver.conf" ]; then
            log "worldserver.conf was created by the container - applying the remaining settings"
            WS_CONF_CHANGED=0
            sync_config
            if [ "$WS_CONF_CHANGED" = "1" ]; then
                log "Restarting the worldserver (MapUpdate.Threads)"
                docker compose restart ac-worldserver >/dev/null 2>&1
                ws_wait 420 && ok "worldserver restarted with the new settings" \
                            || warn "please check the restart: docker logs ac-worldserver"
            fi
        else
            warn "worldserver.conf still missing - run 'bash $(basename "$0") --config' after the first start"
        fi
    fi

    step "6/6  Verify"
    status_report
    echo
    log "in game : .playerbots coa tank|heal|dps   recruits a CoA bot into your group"
    log "          .playerbots rndbot stats         shows the random bot pool"
    log "bot log : docker exec ac-worldserver tail -30 /azerothcore/env/dist/logs/Playerbots.log"
    echo
    ok "Done. Update later with: bash coa-update.sh"
else
    echo
    ok "mode '${MODE}' finished - no image build and no restart (that is what the full run does)"
fi

