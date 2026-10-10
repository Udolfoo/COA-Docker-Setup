#!/usr/bin/env bash
# ============================================================================
#  coa-world-data.sh  -  CoA world database per the official documentation
# ----------------------------------------------------------------------------
#  The CoA world content is a versioned package inside the checked-out fork
#  (jealous-sound/azerothcore-wotlk-coa):
#
#     apps/coa-world/README.md       the procedure implemented here
#     apps/coa-world/world_data.py   verify | bootstrap | audit
#     data/coa-world/baseline.json   package manifest (id + checksums)
#     data/coa-world/coa-world-<date>.zip
#
#  This replaces the world dump upload (COA_WORLD_DUMP / databases.sql.gz):
#  acore_world is built from the repository package, fully checksummed, and
#  the only file that still has to be uploaded is the client data
#  (Data.rar = dbc/maps/vmaps/mmaps).
#
#  The host has no MySQL client of its own. world_data.py talks to the server
#  through the MySQL 8.4 client inside the running ac-database container: the
#  proxy /root/coa-mysql maps the --defaults-file contract of the tool onto
#  `docker exec -i ac-database mysql` with the credentials from
#  /opt/azerothcore/.env. The client version always matches the server and
#  nothing has to be installed on the host.
#
#  Usage:
#    bash coa-world-data.sh install     # (re)install the /root/coa-mysql proxy
#    bash coa-world-data.sh verify      # package self-check (no database)
#    bash coa-world-data.sh status      # what is installed in acore_world?
#    bash coa-world-data.sh bootstrap   # import into an EMPTY acore_world
#    bash coa-world-data.sh audit       # compare acore_world with the package
#
#  Options:
#    FORCE=1 bash coa-world-data.sh bootstrap   # drop acore_world first
#
#  Per the documentation: bootstrap requires an empty schema and never
#  replaces installed data - FORCE=1 is the explicit "recreate that
#  partially imported schema" path after a failed import.
# ============================================================================
set -uo pipefail

AC_DIR="${AC_DIR:-/opt/azerothcore}"
MODE=""
case "${1:-}" in
    verify|status|bootstrap|audit|install) MODE="$1" ;;
    -h|--help|"") sed -n '2,39p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^$/d'; exit 0 ;;
    *) echo "unknown mode: $1   (bash $0 --help)" >&2; exit 2 ;;
esac

c_red='\033[0;31m'; c_grn='\033[0;32m'; c_yel='\033[1;33m'; c_blu='\033[0;36m'; c_off='\033[0m'
log()  { printf "${c_blu}[INFO ]${c_off} %s\n" "$*"; }
ok()   { printf "${c_grn}[ OK  ]${c_off} %s\n" "$*"; }
warn() { printf "${c_yel}[WARN ]${c_off} %s\n" "$*"; }
die()  { printf "${c_red}[FAIL ]${c_off} %s\n" "$*" >&2; exit 1; }
step() { printf "\n${c_grn}=== %s ===${c_off}\n" "$*"; }

PY="python3"
TOOL="$AC_DIR/apps/coa-world/world_data.py"
WRAPPER="/root/coa-mysql"
CNF="/root/coa-world-client.cnf"

# ------------------------------------------------------------------ helpers
need_tool() {
    [ -f "$TOOL" ] || die "not found: $TOOL (is AC_DIR=$AC_DIR the CoA checkout?)"
    "$PY" - <<'PYEOF' || die "Python 3.11+ is required (world_data.py)"
import sys
raise SystemExit(0 if sys.version_info >= (3, 11) else 1)
PYEOF
}

# MySQL-client proxy: world_data.py calls a local `mysql`; the host has none,
# so this wrapper forwards every call into the ac-database container.
install_wrapper() {
    local pw env_file="$AC_DIR/.env"
    pw="$(grep -E '^DOCKER_DB_ROOT_PASSWORD=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2-)"
    [ -n "$pw" ] || die "DOCKER_DB_ROOT_PASSWORD not found in $env_file"
    cat > "$WRAPPER" <<'WRAPPER_EOF'
#!/usr/bin/env bash
# MySQL-client proxy for apps/coa-world/world_data.py (installed by
# coa-world-data.sh). The host has no MySQL client: every invocation runs the
# MySQL 8.4 client inside the ac-database container. --defaults-file /
# --no-defaults are dropped and replaced by the credentials from .env;
# MYSQL_PWD keeps the password out of the process argument list.
set -uo pipefail
ENV_FILE="${COA_DB_ENV_FILE:-/opt/azerothcore/.env}"
PW="$(grep -E '^DOCKER_DB_ROOT_PASSWORD=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)"
[ -n "$PW" ] || { echo "coa-mysql: DOCKER_DB_ROOT_PASSWORD not found in $ENV_FILE" >&2; exit 1; }
args=()
for a in "$@"; do
    case "$a" in
        # The MySQL 8.4 client does not accept --no-login-paths (8.0 did) and
        # the container has no login paths anyway - drop it with the defaults
        # options the tool passes.
        --no-defaults|--no-login-paths|--defaults-extra-file=*|--defaults-file=*) continue ;;
    esac
    args+=("$a")
done
exec docker exec -i -e MYSQL_PWD="$PW" ac-database mysql --no-defaults -h 127.0.0.1 -u root "${args[@]}"
WRAPPER_EOF
    chmod 0755 "$WRAPPER"
    # The client option file world_data.py expects. The proxy already carries
    # the credentials; this file documents the connection (host-side port
    # 13306, see DOCKER_DB_EXTERNAL_PORT) and keeps the two in sync.
    cat > "$CNF" <<EOF
# CoA world import - MySQL client option file (read by the coa-mysql proxy)
[client]
host = 127.0.0.1
port = 13306
user = root
password = $pw
default-character-set = utf8mb4
EOF
    chmod 0600 "$CNF"
}

need_db() {
    docker inspect -f '{{.State.Status}}' ac-database 2>/dev/null | grep -q running \
        || die "ac-database is not running: cd $AC_DIR && docker compose up -d ac-database"
}

db_query() {  # <database> <sql>
    "$WRAPPER" --batch --raw --skip-column-names --database="$1" --execute "$2" 2>/dev/null
}

package_id() {
    "$PY" - "$AC_DIR/data/coa-world/baseline.json" <<'PYEOF'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["id"])
PYEOF
}


# -------------------------------------------------------------------- modes
need_tool

if [ "$MODE" = "install" ]; then
    step "Install the ac-database MySQL client proxy"
    install_wrapper
    ok "proxy installed: $WRAPPER (credentials from $AC_DIR/.env)"
    "$WRAPPER" --batch --raw --skip-column-names --database=mysql --execute "SELECT VERSION()" 2>&1 | head -2
    log "client option file: $CNF (host port 13306 - documentation; the proxy uses the container)"
    exit 0
fi

if [ "$MODE" = "verify" ]; then
    step "Package self-check (world_data.py verify)"
    "$PY" "$TOOL" verify || die "package verification failed"
    ok "package verified (baseline $(package_id))"
    exit 0
fi

if [ "$MODE" = "status" ]; then
    step "Installed CoA world content"
    printf "  package baseline : %s\n" "$(package_id)"
    need_db
    install_wrapper
    tables="$(db_query information_schema "SELECT COUNT(1) FROM tables WHERE table_schema='acore_world'")"
    tables="${tables:-0}"
    printf "  acore_world      : %s tables\n" "$tables"
    if [ "$tables" = "0" ]; then
        warn "acore_world is empty (or missing) - import with: bash $0 bootstrap"
        exit 1
    fi
    items="$(db_query acore_world "SELECT COUNT(1) FROM item_template")"
    printf "  item templates   : %s\n" "${items:-?}"
    echo
    log "full comparison (read-only):  bash $0 audit"
    exit 0
fi

if [ "$MODE" = "bootstrap" ]; then
    step "Bootstrap acore_world from the CoA package"
    need_db
    install_wrapper

    tables_now="$(db_query information_schema "SELECT COUNT(1) FROM tables WHERE table_schema='acore_world'")"
    tables_now="${tables_now:-0}"

    if [ "${FORCE:-0}" = "1" ] && [ "$tables_now" != "0" ]; then
        log "FORCE=1: recreating acore_world (the documented path after a failed import)"
        db_query mysql "DROP DATABASE IF EXISTS acore_world" >/dev/null
        db_query mysql "CREATE DATABASE acore_world DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" >/dev/null
        tables_now=0
    fi

    if [ "$tables_now" != "0" ]; then
        warn "acore_world is not empty ($tables_now tables) - bootstrap requires an empty schema"
        log  "read-only comparison :  bash $0 audit"
        log  "recreate and import  :  FORCE=1 bash $0 bootstrap"
        exit 1
    fi

    "$PY" "$TOOL" verify || die "package verification failed"
    log "importing the package (table by table, a few minutes) ..."
    "$PY" "$TOOL" bootstrap --defaults-file "$CNF" --database acore_world --mysql "$WRAPPER" \
        || die "bootstrap failed - recreate the schema and retry: FORCE=1 bash $0 bootstrap"
    ok "CoA world package imported and verified against baseline $(package_id)"
    log "later migrations: bash apply-missing-updates.sh  (normal updater semantics)"
    exit 0
fi

# MODE = audit
step "Audit acore_world against the package (read-only)"
need_db
install_wrapper
"$PY" "$TOOL" audit --defaults-file "$CNF" --database acore_world --mysql "$WRAPPER"
rc=$?
if [ "$rc" -eq 0 ]; then
    ok "content matches the package"
else
    warn "differences found (see the JSON above) - later migrations and local customizations produce expected differences"
fi
exit "$rc"
