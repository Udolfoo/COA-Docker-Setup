#!/usr/bin/env bash
# ============================================================================
#  coa-oneclick.sh  -  one-click deployment: Conquest of AzerothCore (Docker)
# ----------------------------------------------------------------------------
#  Sets up exactly the deployment this toolchain was tested with:
#    1. Base: Docker + Compose (installed if missing) + swap file
#    2. Repo: clone/update /opt/azerothcore + apply the build fix
#    3. Config: write .env (random DB password), activate module configs
#    4. Client data: from archive/folder (CLIENT_DATA) or download v20.0
#    5. Images: docker compose build
#    6. Database: import only the acore_world part of a CoA dump, disable the
#       AzerothCore auto-updater, apply all missing repo SQL updates
#    7. Start the stack, add missing core options, set the realm address
#    8. Optional GM account
#    9. Status report
#
#  Usage:
#    bash coa-oneclick.sh
#        -> installs what is missing; existing data is left untouched
#
#    COA_WORLD_DUMP=/root/databases.sql.gz CLIENT_DATA=/root/Data.rar \
#    GM_ACCOUNT=MyName:MyPass:3 bash coa-oneclick.sh
#
#  Environment variables (all optional):
#    AC_DIR=/opt/azerothcore            PUBLIC_IP=<auto-detected>
#    DB_ROOT_PASSWORD=<random when empty>
#    WORLD_PORT=8085  AUTH_PORT=3724  SOAP_PORT=7878
#    DB_EXTERNAL_PORT=127.0.0.1:13306   (avoids conflicts with a host MariaDB)
#    COA_WORLD_DUMP=<.sql/.sql.gz>      CLIENT_DATA=<.rar/.zip/folder>
#    GM_ACCOUNT=<user:pass[:level]>
#    FORCE_BUILD=0 FORCE_IMPORT=0 FORCE_CLIENT_DATA=0 FORCE_CONFIG=0 SKIP_SWAP=0
# ============================================================================

set -uo pipefail

# ------------------------------------------------------------------- Config
REPO_URL="${REPO_URL:-https://github.com/jealous-sound/azerothcore-wotlk-coa.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
AC_DIR="${AC_DIR:-/opt/azerothcore}"
# Empty = a random password is generated on the first run and stored in
# /root/coa-db-password.txt + .env; later runs read it from .env.
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}"
DB_EXTERNAL_PORT="${DB_EXTERNAL_PORT:-127.0.0.1:13306}"
WORLD_PORT="${WORLD_PORT:-8085}"
AUTH_PORT="${AUTH_PORT:-3724}"
SOAP_PORT="${SOAP_PORT:-7878}"
IMAGE_TAG="${IMAGE_TAG:-coa}"
PUBLIC_IP="${PUBLIC_IP:-}"
COA_WORLD_DUMP="${COA_WORLD_DUMP:-}"
CLIENT_DATA="${CLIENT_DATA:-}"
GM_ACCOUNT="${GM_ACCOUNT:-}"
FORCE_BUILD="${FORCE_BUILD:-0}"
FORCE_IMPORT="${FORCE_IMPORT:-0}"
FORCE_CLIENT_DATA="${FORCE_CLIENT_DATA:-0}"
FORCE_CONFIG="${FORCE_CONFIG:-0}"
SKIP_SWAP="${SKIP_SWAP:-0}"
SWAP_SIZE="${SWAP_SIZE:-4G}"

DATA_VOL="azerothcore_ac-client-data"

# Directory this script lives in (needed for its helper scripts)
SELF_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# ------------------------------------------------------------------ Helpers
c_red='\033[0;31m'; c_grn='\033[0;32m'; c_yel='\033[1;33m'; c_blu='\033[0;36m'; c_off='\033[0m'
log()  { printf "${c_blu}[INFO ]${c_off} %s\n" "$*"; }
ok()   { printf "${c_grn}[ OK  ]${c_off} %s\n" "$*"; }
warn() { printf "${c_yel}[WARN ]${c_off} %s\n" "$*"; }
die()  { printf "${c_red}[FAIL ]${c_off} %s\n" "$*" >&2; exit 1; }
step() { printf "\n${c_grn}=== %s ===${c_off}\n" "$*"; }

mysql_q() {  # mysql_q "<sql>" [db]
    local sql="$1" db="${2:-}"
    if [ -n "$db" ]; then
        docker exec -i ac-database mysql -uroot -p"$DB_ROOT_PASSWORD" "$db" -N -B -e "$sql" 2>/dev/null
    else
        docker exec -i ac-database mysql -uroot -p"$DB_ROOT_PASSWORD" -N -B -e "$sql" 2>/dev/null
    fi
}
mysql_file() {  # mysql_file <file>
    docker exec -i ac-database mysql -uroot -p"$DB_ROOT_PASSWORD" < "$1"
}

# ------------------------------------------- Data file auto-detection
# Users only need to upload the files to /root - no environment variables required.
if [ -z "$COA_WORLD_DUMP" ]; then
    for c in /root/databases.sql.gz /root/database.sql.gz /root/coa_world.sql.gz \
             /root/coa-world.sql.gz /root/databases.sql /root/coa_world.sql /root/coa-world.sql; do
        if [ -f "$c" ]; then COA_WORLD_DUMP="$c"; break; fi
    done
fi
if [ -z "$CLIENT_DATA" ]; then
    for c in /root/Data.rar /root/data.rar /root/Data.zip /root/data.zip \
             /root/client-data /root/Data; do
        if [ -e "$c" ]; then CLIENT_DATA="$c"; break; fi
    done
fi
log "World database dump : ${COA_WORLD_DUMP:-none found (standard AzerothCore world will be used)}"
log "Client data         : ${CLIENT_DATA:-none found (v20.0 will be downloaded automatically)}"

# ------------------------------------------------------------- 1. Base
step "1/9  Base: Docker, swap"
[ "$(id -u)" -eq 0 ] || die "Please run as root (sudo bash $0)"
[ -r /etc/os-release ] && . /etc/os-release
FREE_GB="$(df -Pk / | awk 'NR==2 {print int($4/1024/1024)}')"
log "System: ${PRETTY_NAME:-unknown} | free on /: ${FREE_GB} GB"
[ "$FREE_GB" -lt 12 ] && warn "Less than 12 GB free - build and client data need space!"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker present: $(docker --version)"
else
    log "Installing Docker + Compose ..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends ca-certificates curl gnupg git
    install -m 0755 -d /etc/apt/keyrings
    . /etc/os-release
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker >/dev/null 2>&1
ok "Docker service: $(systemctl is-active docker)"

if [ "$SKIP_SWAP" = "1" ]; then
    warn "Swap skipped (SKIP_SWAP=1)"
elif swapon --show 2>/dev/null | grep -q .; then
    ok "Swap already active: $(swapon --show --noheadings | head -1 | tr -s ' ')"
else
    # mkswap/swapon ship with util-linux; minimal clouds images may not have it
    if ! command -v mkswap >/dev/null 2>&1 || ! command -v swapon >/dev/null 2>&1; then
        log "Installing util-linux (provides mkswap/swapon) ..."
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y --no-install-recommends util-linux >/dev/null 2>&1 || true
    fi
    if command -v mkswap >/dev/null 2>&1 && command -v swapon >/dev/null 2>&1; then
        log "Creating a ${SWAP_SIZE} swap file (protects the build from OOM)"
        if command -v fallocate >/dev/null 2>&1; then
            fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null \
                || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
        else
            dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
        fi
        chmod 600 /swapfile
        if mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null \
           && swapon --show 2>/dev/null | grep -q /swapfile; then
            grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            ok "Swap active ($(swapon --show --noheadings | head -1 | tr -s ' ')) and added to /etc/fstab"
        else
            rm -f /swapfile
            warn "Swap could not be created - continuing without it (fine with enough RAM)"
        fi
    else
        warn "mkswap/swapon unavailable - continuing without swap (fine with enough RAM)"
    fi
fi

# ------------------------------------------------- 2. Repo + build fix
step "2/9  Repository + build fix (mod-ascension-compat)"
if [ -d "$AC_DIR/.git" ]; then
    git -C "$AC_DIR" fetch --prune origin "$REPO_BRANCH" >/dev/null 2>&1
    # drop the local build-fix change so the checkout can succeed
    git -C "$AC_DIR" checkout -- modules/mod-ascension-compat/src/AscensionCompat.cpp 2>/dev/null || true
    if git -C "$AC_DIR" checkout -B "$REPO_BRANCH" FETCH_HEAD >/dev/null 2>&1; then
        ok "Repo updated: $(git -C "$AC_DIR" rev-parse --short HEAD)"
    else
        warn "git checkout failed - keeping current revision: $(git -C "$AC_DIR" rev-parse --short HEAD)"
    fi
else
    mkdir -p "$(dirname "$AC_DIR")"
    log "Cloning: $REPO_URL"
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$AC_DIR" || die "git clone failed"
    ok "Repo cloned: $(git -C "$AC_DIR" rev-parse --short HEAD)"
fi

# Upstream bug: the fork removed SPELL_EFFECT_NONE from enum SpellEffects but
# mod-ascension-compat still uses the name -> the build fails.
# Value 0 equals SPELL_EFFECT_NONE.
FIXFILE="$AC_DIR/modules/mod-ascension-compat/src/AscensionCompat.cpp"
if [ -f "$FIXFILE" ] && grep -q 'SPELL_EFFECT_NONE' "$FIXFILE"; then
    sed -i 's/Effects\[EFFECT_2\]\.Effect = SPELL_EFFECT_NONE;/Effects[EFFECT_2].Effect = 0;/' "$FIXFILE"
    grep -q 'SPELL_EFFECT_NONE' "$FIXFILE" && die "Build fix failed: $FIXFILE"
    ok "Build fix applied (SPELL_EFFECT_NONE -> 0)"
else
    ok "Build fix not required (already patched or fixed upstream)"
fi

# ------------------------------------------------------------ 3. Config
step "3/9  Configuration (.env, module configs)"
cd "$AC_DIR" || die "$AC_DIR not found"
mkdir -p env/dist/etc/modules env/dist/logs var/client
chown -R 1000:1000 env/dist/etc env/dist/logs var/client 2>/dev/null || true

if [ -f .env ] && [ "$FORCE_CONFIG" != "1" ]; then
    ok ".env present (FORCE_CONFIG=1 forces a rewrite)"
    DB_ROOT_PASSWORD="$(grep -E '^DOCKER_DB_ROOT_PASSWORD=' .env | head -1 | cut -d= -f2-)"
    [ -n "$DB_ROOT_PASSWORD" ] || die "DOCKER_DB_ROOT_PASSWORD missing in $AC_DIR/.env"
    ok "DB root password taken from .env"
else
    if [ -z "$DB_ROOT_PASSWORD" ]; then
        DB_ROOT_PASSWORD="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
        printf '%s\n' "$DB_ROOT_PASSWORD" > /root/coa-db-password.txt
        chmod 600 /root/coa-db-password.txt 2>/dev/null || true
        ok "Random DB root password generated -> /root/coa-db-password.txt"
    fi
    cat > .env <<EOF
# AzerothCore / CoA docker-compose configuration (created by coa-oneclick.sh)
DOCKER_AC_ENV_FILE=conf/dist/env.ac

DOCKER_VOL_ETC=./env/dist/etc
DOCKER_VOL_LOGS=./env/dist/logs
DOCKER_VOL_DATA=ac-client-data
DOCKER_VOL_ROOT=.

DOCKER_WORLD_EXTERNAL_PORT=${WORLD_PORT}
DOCKER_SOAP_EXTERNAL_PORT=${SOAP_PORT}
DOCKER_AUTH_EXTERNAL_PORT=${AUTH_PORT}
DOCKER_DB_EXTERNAL_PORT=${DB_EXTERNAL_PORT}
DOCKER_DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}

DOCKER_IMAGE_TAG=${IMAGE_TAG}
DOCKER_USER=acore
DOCKER_USER_ID=1000
DOCKER_GROUP_ID=1000
EOF
    ok ".env written (DB port ${DB_EXTERNAL_PORT} -> no conflict with host MariaDB)"
fi

# ------------------------------------------------------------ 4. Client data
step "4/9  Client data"
DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
[ -n "$DOCKER_ROOT" ] || DOCKER_ROOT="/var/lib/docker"
VOL_DIR="$DOCKER_ROOT/volumes/${DATA_VOL}/_data"
log "Docker data root: $DOCKER_ROOT"

extract_client_archive() {  # <archive> <target dir>
    local src="$1" dst="$2"
    case "${src,,}" in
        *.rar)
            command -v unrar >/dev/null 2>&1 || {
                log "installing unrar (for RAR5 / WinRAR 7 archives)"
                DEBIAN_FRONTEND=noninteractive apt-get install -y unrar
            }
            unrar x -o+ "$src" "$dst/" >/dev/null || die "unrar failed: $src"
            ;;
        *.zip)
            command -v unzip >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y unzip
            unzip -q -o "$src" -d "$dst/" || die "unzip failed: $src"
            ;;
        *)
            die "Unknown archive format: $src (expected .rar or .zip)"
            ;;
    esac
}

client_data_complete() {
    [ -d "$VOL_DIR/dbc" ] && [ -d "$VOL_DIR/maps" ] && [ -d "$VOL_DIR/vmaps" ] && [ -d "$VOL_DIR/mmaps" ]
}

if client_data_complete && [ "$FORCE_CLIENT_DATA" != "1" ]; then
    ok "Client data present ($(du -sh "$VOL_DIR" 2>/dev/null | cut -f1)) - left untouched"
elif [ -n "$CLIENT_DATA" ]; then
    [ -e "$CLIENT_DATA" ] || die "CLIENT_DATA not found: $CLIENT_DATA"
    TMPD="$(mktemp -d /tmp/coa-clientdata.XXXXXX)"
    if [ -d "$CLIENT_DATA" ]; then
        log "Copying folder $CLIENT_DATA -> $TMPD"
        cp -r "$CLIENT_DATA/." "$TMPD/"
    else
        log "Extracting $(du -h "$CLIENT_DATA" | cut -f1) to $TMPD"
        extract_client_archive "$CLIENT_DATA" "$TMPD"
    fi
    SRCROOT="$(find "$TMPD" -maxdepth 3 -type d -name mmaps -printf '%h\n' 2>/dev/null | head -1)"
    [ -n "$SRCROOT" ] || die "No client data found in the archive (dbc/maps/vmaps/mmaps)"
    log "Data found in: $SRCROOT"
    docker compose stop ac-worldserver >/dev/null 2>&1 || true
    log "Replacing old client data in the volume ..."
    rm -rf "$VOL_DIR/Cameras" "$VOL_DIR/dbc" "$VOL_DIR/maps" "$VOL_DIR/vmaps" "$VOL_DIR/mmaps"
    for d in Cameras dbc maps vmaps mmaps; do
        [ -d "$SRCROOT/$d" ] && mv "$SRCROOT/$d" "$VOL_DIR/"
    done
    chown -R 1000:1000 "$VOL_DIR"
    echo "INSTALLED_VERSION=v20.0" > "$VOL_DIR/data-version"   # prevents a re-download
    rm -rf "$TMPD"
    ok "Client data installed: $(du -sh "$VOL_DIR" | cut -f1)"
else
    warn "No custom client data - ac-client-data-init will download v20.0 automatically"
fi

# ------------------------------------------------------------ 5. Images
step "5/9  Docker images"
NEED_BUILD=1
if docker image inspect "acore/ac-wotlk-worldserver:${IMAGE_TAG}" >/dev/null 2>&1; then NEED_BUILD=0; fi
[ "$FORCE_BUILD" = "1" ] && NEED_BUILD=1
if [ "$NEED_BUILD" = "1" ]; then
    # Network preflight: on a fresh VPS the build often fails because a container
    # cannot reach the apt mirrors (broken IPv6 or a DNS stub). Takes up to ~2 min.
    if [ -f "$SELF_DIR/fix-build-network.sh" ]; then
        log "Network preflight: checking container DNS/IPv6 (max ~2 minutes) ..."
        bash "$SELF_DIR/fix-build-network.sh" \
            || warn "Network preflight reported a problem - trying the build anyway"
    fi
    log "docker compose build (30-120 minutes)"
    if ! docker compose build; then
        warn "Build failed - retrying once (transient mirror/network problems)"
        sleep 10
        docker compose build \
            || die "Image build failed (see README troubleshooting: apt/DNS/IPv6)"
    fi
    ok "Images built (tag: ${IMAGE_TAG})"
    docker image prune -f >/dev/null 2>&1 || true
    docker builder prune -f --keep-storage 8GB >/dev/null 2>&1 || true
    ok "Old images and build cache cleaned up (check: docker system df)"
else
    ok "Images present (FORCE_BUILD=1 forces a rebuild)"
fi

# ------------------------------------------------------------ 6. Database
step "6/9  Database"
cd "$AC_DIR"
world_items() { mysql_q "SELECT COUNT(1) FROM item_template" acore_world 2>/dev/null | head -1; }

docker compose up -d ac-database >/dev/null 2>&1
for _i in $(seq 1 60); do
    [ "$(docker inspect --format '{{.State.Health.Status}}' ac-database 2>/dev/null)" = "healthy" ] && break
    sleep 2
done
[ "$(docker inspect --format '{{.State.Health.Status}}' ac-database 2>/dev/null)" = "healthy" ] \
    || die "ac-database does not become healthy (see: docker logs ac-database)"
ok "ac-database healthy"

if [ -n "$COA_WORLD_DUMP" ]; then
    [ -f "$COA_WORLD_DUMP" ] || die "COA_WORLD_DUMP not found: $COA_WORLD_DUMP"
    ITEMS_NOW="$(world_items)"; ITEMS_NOW="${ITEMS_NOW:-0}"
    if [ "$ITEMS_NOW" -gt 400000 ] && [ "$FORCE_IMPORT" != "1" ]; then
        ok "CoA world already imported (${ITEMS_NOW} items) - import skipped (FORCE_IMPORT=1 forces it)"
    else
        log "Extracting the acore_world section from $(du -h "$COA_WORLD_DUMP" | cut -f1)"
        python3 - "$COA_WORLD_DUMP" /tmp/coa_world_part.sql <<'PYEOF'
import gzip, re, sys
src, out = sys.argv[1], sys.argv[2]
opener = gzip.open if src.endswith(".gz") else open
marker = re.compile(rb"^-- Current Database: `([^`]+)`")
cur = None; lines = 0
with opener(src, "rb") as f, open(out, "wb") as g:
    for line in f:
        m = marker.match(line)
        if m:
            cur = m.group(1)
            if cur == b"acore_world":
                g.write(b"USE `acore_world`;\n")
            continue
        if cur == b"acore_world":
            g.write(line); lines += 1
print("   extracted to %s (%d lines)" % (out, lines))
PYEOF
        [ -s /tmp/coa_world_part.sql ] || die "Extraction empty - is this a mysqldump containing acore_world?"
        docker compose stop ac-worldserver >/dev/null 2>&1 || true
        if [ "$(mysql_q "SELECT COUNT(1) FROM information_schema.tables WHERE table_schema='acore_world_old'" | head -1)" = "0" ]; then
            mysql_q "CREATE DATABASE IF NOT EXISTS acore_world_old DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
            mysql_q "SELECT CONCAT('RENAME TABLE acore_world.\`', table_name, '\` TO acore_world_old.\`', table_name, '\`;') FROM information_schema.tables WHERE table_schema='acore_world'" > /tmp/rename_world.sql
            mysql_file /tmp/rename_world.sql >/dev/null 2>&1
            ok "Backup of the old world: acore_world_old ($(wc -l < /tmp/rename_world.sql) tables)"
        else
            warn "acore_world_old already exists - keeping the previous backup"
        fi
        log "Importing the CoA world dump (2-10 minutes) ..."
        mysql_file /tmp/coa_world_part.sql >/dev/null 2>&1
        warn "Note: the last line of the dump (session restore) may report an error - harmless"
        IMPORTED="$(world_items)"; IMPORTED="${IMPORTED:-0}"
        [ "$IMPORTED" -gt 400000 ] || die "Import failed (only $IMPORTED items in item_template)"
        ok "CoA world imported: ${IMPORTED} item templates"
        rm -f /tmp/coa_world_part.sql
    fi

    if [ ! -f docker-compose.override.yml ]; then
        if [ -f "$SELF_DIR/docker-compose.override.yml" ]; then
            cp "$SELF_DIR/docker-compose.override.yml" ./docker-compose.override.yml
            ok "docker-compose.override.yml installed (auto-updater disabled)"
        else
            warn "docker-compose.override.yml not found next to this script - copy it manually!"
        fi
    else
        ok "docker-compose.override.yml present"
    fi

    # Apply missing repo/module SQL updates (core fixes not contained in the dump)
    if [ -f "$SELF_DIR/apply-missing-updates.sh" ]; then
        log "Applying missing repo SQL updates (core/module fixes) ..."
        DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" AC_DIR="$AC_DIR" \
            bash "$SELF_DIR/apply-missing-updates.sh" \
            || warn "Update run reported errors - log: /root/apply-missing-updates.log"
        ok "Repo updates checked and applied"
    else
        warn "apply-missing-updates.sh not found - repo updates skipped"
    fi
else
    warn "COA_WORLD_DUMP not set -> standard AzerothCore world (auto-updater stays active)"
    [ -f docker-compose.override.yml ] && warn "Note: docker-compose.override.yml exists and disables ac-db-import"
fi

# ------------------------------------- 7. Module and server configuration
step "7/9  Module and server configuration"
cd "$AC_DIR"
ETC="env/dist/etc"

if [ ! -f "$ETC/worldserver.conf.dist" ]; then
    log "Fetching config templates from the image (like the entrypoint does)"
    mkdir -p "$ETC/modules"
    docker run --rm --entrypoint tar "acore/ac-wotlk-worldserver:${IMAGE_TAG}" \
        -cf - -C /azerothcore/env/ref/etc . 2>/dev/null | tar -xf - -C "$ETC" 2>/dev/null
fi
[ -f "$ETC/worldserver.conf.dist" ] && ok "Config templates present" || warn "Templates missing (created on first start)"

for m in mod_ascension_compat mod_teleport_actionbar coa_bugreport; do
    if [ -f "$ETC/modules/$m.conf" ]; then
        ok "Module config active: $m.conf"
    elif [ -f "$ETC/modules/$m.conf.dist" ]; then
        cp "$ETC/modules/$m.conf.dist" "$ETC/modules/$m.conf"
        ok "Module config activated: $m.conf"
    else
        warn "Module config template missing: $m.conf.dist"
    fi
done

# Ascension compat: allow remote clients + absolute DBC path
ACA="$ETC/modules/mod_ascension_compat.conf"
if [ -f "$ACA" ]; then
    sed -i 's/^AscensionCompat\.AllowRemoteClients *=.*/AscensionCompat.AllowRemoteClients = 1/' "$ACA"
    sed -i 's|^AscensionCompat\.DbcDirectory *=.*|AscensionCompat.DbcDirectory = "/azerothcore/env/dist/data/dbc/Ascension"|' "$ACA"
    grep -q '^AscensionCompat.AllowRemoteClients = 1' "$ACA" \
        && ok "AscensionCompat: AllowRemoteClients=1 + absolute DBC path set" \
        || warn "Please check the AscensionCompat config: $ACA"
fi
chown -R 1000:1000 "$ETC" 2>/dev/null || true

# ------------------------------------------------------------ 8. Start
step "8/9  Start + realm address"
log "docker compose up -d"
docker compose up -d 2>&1 | tail -4

wait_init() {
    # waits until the worldserver port is listening
    for _i in $(seq 1 80); do
        ss -ltn 2>/dev/null | grep -q ":${WORLD_PORT} " && return 0
        sleep 3
    done
    return 1
}
log "Waiting for the worldserver ..."
wait_init && ok "Worldserver is up" || warn "Not detected - check: docker logs ac-worldserver"

WSC="env/dist/etc/worldserver.conf"
if [ -f "$WSC" ] && ! grep -q 'coa-oneclick.sh additions' "$WSC"; then
    log "Adding missing options to worldserver.conf"
    cat >> "$WSC" <<'EOF'

#
# ---------------------------------------------------------------------------
# coa-oneclick.sh additions (these keys are missing in this fork's .dist)
# ---------------------------------------------------------------------------
Cluster.Enabled = 0
MinWorldUpdateTime = 1
MaxCoreStuckTime = 60
BeepAtStart = 1
Network.UseSocketActivation = 0

TeleportActionBar.Enable = 1
TeleportActionBar.CastFromItem = 1
TeleportActionBar.EnforceFaction = 1
TeleportActionBar.OnLogin = 0
TeleportActionBar.OnLearnSpell = 0
TeleportActionBar.OnSpecChange = 0
TeleportActionBar.LearnCarriedTokens = 0
TeleportActionBar.LearnCarriedTokensFromBank = 0
TeleportActionBar.MaxButtons = 24
TeleportActionBar.FirstButton = 0
TeleportActionBar.LastButton = 143
TeleportActionBar.ItemNameFilter = "Stone of Retreat%"

CoAGameplayTest.Enable = 0
EOF
    chown 1000:1000 "$WSC" 2>/dev/null || true
    ok "worldserver.conf extended -> restarting worldserver"
    docker compose restart ac-worldserver >/dev/null 2>&1
    wait_init && ok "Worldserver restarted" || warn "Please check the restart"
else
    [ -f "$WSC" ] && ok "worldserver.conf already contains the additions" || warn "worldserver.conf not created yet"
fi

REALM_IP="${PUBLIC_IP:-$(curl -fsS --max-time 8 https://api.ipify.org || true)}"
if [ -n "$REALM_IP" ]; then
    CUR_IP="$(mysql_q "SELECT address FROM realmlist WHERE id=1" acore_auth | head -1)"
    if [ "$CUR_IP" = "$REALM_IP" ]; then
        ok "Realm address already correct: ${REALM_IP}:${WORLD_PORT}"
    else
        log "Setting realm address ${CUR_IP:-?} -> ${REALM_IP}:${WORLD_PORT}"
        mysql_q "UPDATE realmlist SET address='${REALM_IP}', port=${WORLD_PORT}, localAddress='127.0.0.1' WHERE id=1" acore_auth
        docker compose restart ac-authserver >/dev/null 2>&1
        ok "Realm address set + authserver restarted"
    fi
else
    warn "Public IP not detected - set it manually (PUBLIC_IP=<ip>)"
fi

# ------------------------------------------------------- 9. GM + summary
step "9/9  Summary"
if [ -n "$GM_ACCOUNT" ]; then
    IFS=: read -r gmu gmp gml <<< "$GM_ACCOUNT"
    gml="${gml:-3}"
    if [ -n "$gmu" ] && [ -n "$gmp" ]; then
        log "Creating account '$gmu' (GM level $gml)"
        python3 - "$gmu" "$gmp" "$gml" <<'PYEOF' > /tmp/coa_account.sql
import binascii, hashlib, os, sys
N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)
user, pwd, gm = sys.argv[1].upper(), sys.argv[2], sys.argv[3]
salt = os.urandom(32)
inner = hashlib.sha1((user + ":" + pwd.upper()).encode()).digest()
x = int.from_bytes(hashlib.sha1(salt + inner).digest(), "little")
ver = pow(7, x, N).to_bytes(32, "little")
print("USE acore_auth;")
print("INSERT INTO account (username, salt, verifier, email, reg_mail, expansion) VALUES "
      "('%s', UNHEX('%s'), UNHEX('%s'), '', '', 2) "
      "ON DUPLICATE KEY UPDATE salt=VALUES(salt), verifier=VALUES(verifier);"
      % (user, binascii.hexlify(salt).decode(), binascii.hexlify(ver).decode()))
print("SET @a := (SELECT id FROM account WHERE username='%s');" % user)
print("DELETE FROM account_access WHERE id=@a AND RealmID=-1;")
print("INSERT INTO account_access (id, gmlevel, RealmID, comment) VALUES (@a, %s, -1, 'coa-oneclick');" % gm)
PYEOF
        mysql_file /tmp/coa_account.sql >/dev/null 2>&1 \
            && ok "Account '$gmu' ready (GM level $gml)" \
            || warn "Account creation failed"
        rm -f /tmp/coa_account.sql
    else
        warn "GM_ACCOUNT format: user:pass[:level]"
    fi
fi

echo
echo "===================== STATUS ====================="
docker ps --format '{{.Names}}: {{.Status}}'
echo
echo "=== KEY FIGURES ==="
printf "Item templates : %s\n" "$(mysql_q "SELECT COUNT(1) FROM item_template" acore_world | head -1)"
printf "Realm          : %s\n" "$(mysql_q "SELECT CONCAT(address, ':', port) FROM realmlist WHERE id=1" acore_auth | head -1)"
printf "DB root passw. : %s\n" "$( [ -f /root/coa-db-password.txt ] && echo 'see /root/coa-db-password.txt' || echo 'from /opt/azerothcore/.env' )"
printf "Accounts       : %s\n" "$(mysql_q "SELECT COUNT(1) FROM account" acore_auth | head -1)"
printf "Errors in log  : %s\n" "$(docker logs --since 30m ac-worldserver 2>&1 | grep -ac -i error)"
printf "Disk           : %s\n" "$(df -h / | awk 'NR==2 {print $4 " free (" $5 " used)"}')"
echo
printf "Client: realmlist.wtf -> set realmlist %s\n" "${REALM_IP:-<server-ip>}"
printf "Ports : %s (auth), %s (world), %s (SOAP)\n" "$AUTH_PORT" "$WORLD_PORT" "$SOAP_PORT"
echo
ok "Done. Update later with: bash coa-update.sh"