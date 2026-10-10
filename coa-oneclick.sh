#!/usr/bin/env bash
# ============================================================================
#  coa-oneclick.sh  -  one-click deployment: Conquest of AzerothCore (Docker)
# ----------------------------------------------------------------------------
#  Sets up exactly the deployment this toolchain was tested with:
#    1. Base: Docker + Compose (installed if missing) + swap file
#    2. Repo: clone/update /opt/azerothcore + apply the build fix
#    3. Config: write .env (random DB password), activate module configs
#    3b. Optional: player bots (WITH_PLAYERBOTS=1 -> module + acore_playerbots)
#    4. Client data: from archive/folder (CLIENT_DATA) or download v20.0
#    5. Images: docker compose build
#    6. Database: import the versioned CoA world package with the official
#       tool (apps/coa-world/world_data.py), disable the AzerothCore
#       auto-updater, apply all missing repo SQL updates
#    7. Start the stack, add missing core options, set the realm address
#    8. Optional GM account
#    9. Status report
#
#  Usage:
#    bash coa-oneclick.sh
#        -> installs what is missing; existing data is left untouched
#
#    CLIENT_DATA=/root/Data.rar GM_ACCOUNT=MyName:MyPass:3 bash coa-oneclick.sh
#
#  Only the client data is uploaded (drop Data.rar into /root - the script
#  finds it). The CoA world database is imported from the versioned package
#  inside the repository checkout with the official tool
#  (apps/coa-world/world_data.py, driven by coa-world-data.sh) - no world
#  dump upload is needed anymore.
#
#  Player bots (optional, can also be added later with enable-playerbots.sh):
#    WITH_PLAYERBOTS=1 bash coa-oneclick.sh
#    PLAYERBOTS_COUNT=200 WITH_PLAYERBOTS=1 bash coa-oneclick.sh
#
#  Environment variables (all optional):
#    AC_DIR=/opt/azerothcore            PUBLIC_IP=<auto-detected>
#    DB_ROOT_PASSWORD=<random when empty>
#    WORLD_PORT=8085  AUTH_PORT=3724  SOAP_PORT=7878
#    DB_EXTERNAL_PORT=127.0.0.1:13306   (avoids conflicts with a host MariaDB)
#    CLIENT_DATA=<.rar/.zip/folder>
#    GM_ACCOUNT=<user:pass[:level]>
#    FORCE_BUILD=0 FORCE_IMPORT=0 FORCE_CLIENT_DATA=0 FORCE_CONFIG=0 SKIP_SWAP=0
#    WITH_PLAYERBOTS=0                  (1 = install the player bots as well)
#    PLAYERBOTS_COUNT=200 PLAYERBOTS_AUTOLOGIN=1 PLAYERBOTS_MAP_THREADS=8
#    PLAYERBOTS_REPO=... PLAYERBOTS_BRANCH=coa PLAYERBOTS_REF=<tag/commit>
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
CLIENT_DATA="${CLIENT_DATA:-}"
GM_ACCOUNT="${GM_ACCOUNT:-}"
FORCE_BUILD="${FORCE_BUILD:-0}"
FORCE_IMPORT="${FORCE_IMPORT:-0}"
FORCE_CLIENT_DATA="${FORCE_CLIENT_DATA:-0}"
FORCE_CONFIG="${FORCE_CONFIG:-0}"
SKIP_SWAP="${SKIP_SWAP:-0}"
SWAP_SIZE="${SWAP_SIZE:-4G}"
# Optional player bots (mod-playerbots, CoA fork) - see enable-playerbots.sh
WITH_PLAYERBOTS="${WITH_PLAYERBOTS:-0}"

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
# Users only need to upload the client data to /root - no environment variables
# required. The CoA world database comes from the versioned package in the
# repository checkout (apps/coa-world/world_data.py), not from an upload.
if [ -z "$CLIENT_DATA" ]; then
    for c in /root/Data.rar /root/data.rar /root/Data.zip /root/data.zip \
             /root/client-data /root/Data; do
        if [ -e "$c" ]; then CLIENT_DATA="$c"; break; fi
    done
fi
log "Client data         : ${CLIENT_DATA:-none found (v20.0 will be downloaded automatically)}"
log "CoA world database  : versioned package in the repository checkout (apps/coa-world)"

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

# Docker's build cache garbage collection deletes BuildKit cache mounts (its
# policy 1 counts them as "easily regenerated") and shrinks the cache to a small
# default budget. That is what emptied the ccache and turned every rebuild into a
# full 45-120 minute compile (measured: "Hits: 0 / 2239 (0.00%)"). Raise the
# budget here, while the stack is usually not running yet - coa-build.sh keeps a
# second, GC-independent copy of the ccache (see /root/.coa-build/ccache.tar).
if [ -f "$SELF_DIR/coa-build.sh" ]; then
    bash "$SELF_DIR/coa-build.sh" --gc-config >/dev/null 2>&1 \
        && ok "Build cache GC configured (cache mounts are kept for 14 days)" \
        || warn "build cache GC could not be configured - see: bash $SELF_DIR/coa-build.sh --gc-config"
    if [ "$(docker ps -q 2>/dev/null | wc -l)" -eq 0 ]; then
        systemctl restart docker >/dev/null 2>&1 && sleep 3 \
            && ok "Docker restarted - the build cache GC policy is active"
    else
        warn "GC policy takes effect after the next Docker restart (systemctl restart docker)"
    fi
fi

if [ "$SKIP_SWAP" = "1" ]; then
    warn "Swap skipped (SKIP_SWAP=1)"
elif [ -n "$(swapon --show 2>/dev/null)" ]; then
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
    # drop the local build-fix changes so the checkout can succeed
    git -C "$AC_DIR" checkout -- \
        modules/mod-ascension-compat/src/AscensionCompat.cpp \
        modules/mod-ascension-compat/src/AscensionChronomancerMovement.cpp 2>/dev/null || true
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

# Upstream build breakers in mod-ascension-compat (the module lags behind the
# core API). Each fix is applied only while its pattern is still present.
COMPAT="$AC_DIR/modules/mod-ascension-compat/src"

# 1) SPELL_EFFECT_NONE was removed from enum SpellEffects; 0 is the same value.
FIXFILE="$COMPAT/AscensionCompat.cpp"
if [ -f "$FIXFILE" ] && grep -q 'SPELL_EFFECT_NONE' "$FIXFILE"; then
    sed -i 's/Effects\[EFFECT_2\]\.Effect = SPELL_EFFECT_NONE;/Effects[EFFECT_2].Effect = 0;/' "$FIXFILE"
    grep -q 'SPELL_EFFECT_NONE' "$FIXFILE" && die "Build fix failed: $FIXFILE"
    ok "Build fix 1 applied (SPELL_EFFECT_NONE -> 0)"
else
    ok "Build fix 1 not required (SPELL_EFFECT_NONE)"
fi

# 2) Unit::NearTeleportTo takes a non-const Position&, the module passes a temporary.
FIXFILE2="$COMPAT/AscensionChronomancerMovement.cpp"
if [ -f "$FIXFILE2" ] && grep -q 'NearTeleportTo(caster->GetNearPosition' "$FIXFILE2"; then
    python3 - "$FIXFILE2" <<'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); t = p.read_text()
old = "        target->NearTeleportTo(caster->GetNearPosition(2.0f, 0.0f), true);"
new = ("        {\n            Position dest = caster->GetNearPosition(2.0f, 0.0f);\n"
       "            target->NearTeleportTo(dest, true);\n        }")
p.write_text(t.replace(old, new))
PYEOF
    grep -q 'Position dest = caster->GetNearPosition' "$FIXFILE2" || die "Build fix failed: $FIXFILE2"
    ok "Build fix 2 applied (NearTeleportTo temporary -> named Position)"
else
    ok "Build fix 2 not required (NearTeleportTo)"
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

# -------------------------------------------------- 3b. Player bots (opt.)
# WITH_PLAYERBOTS=1 installs the optional playerbot module in the same run:
# the module has to be cloned before the image build (the worldserver compiles
# it in) and its config is created here so step 7 only has to keep it. The
# database (acore_playerbots) is created in step 6b - before the first start.
if [ "$WITH_PLAYERBOTS" = "1" ]; then
    step "3b/9  Player bots (mod-playerbots, optional)"
    if [ -f "$SELF_DIR/enable-playerbots.sh" ]; then
        AC_DIR="$AC_DIR" bash "$SELF_DIR/enable-playerbots.sh" --prepare \
            || die "Playerbots setup failed (see the output above)"
    else
        warn "enable-playerbots.sh not found next to this script - player bots are skipped"
        WITH_PLAYERBOTS=0
    fi
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
# the playerbot module has to be compiled in, even when an image already exists
if [ "$WITH_PLAYERBOTS" = "1" ]; then
    log "Player bots requested -> image rebuild is forced (the module must be compiled in)"
    NEED_BUILD=1
fi
if [ "$NEED_BUILD" = "1" ]; then
    # coa-build.sh does the whole image build: network preflight, BuildKit build,
    # and the ccache handling (restore the snapshot into the BuildKit mount when
    # Docker's GC emptied it, save it again afterwards). Details: coa-build.sh.
    if [ -f "$SELF_DIR/coa-build.sh" ]; then
        AC_DIR="$AC_DIR" bash "$SELF_DIR/coa-build.sh" \
            || die "Image build failed (see /root/coa-build.log + README troubleshooting)"
    else
        warn "coa-build.sh not found next to this script - building without the ccache snapshot"
        docker compose build \
            || die "Image build failed (see README troubleshooting: apt/DNS/IPv6)"
    fi
    ok "Images ready (tag: ${IMAGE_TAG})"
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

# The AzerothCore importer creates acore_auth/characters/world with the base
# data; the CoA world content then comes from the versioned package inside the
# repository checkout (apps/coa-world/world_data.py, see coa-world-data.sh).
if [ "$(mysql_q "SELECT COUNT(1) FROM information_schema.tables WHERE table_schema='acore_world'" | head -1)" = "0" ]; then
    log "Base databases missing -> running the AzerothCore importer once (a few minutes) ..."
    # -d + poll: an attached "docker compose up ac-db-import" follows the
    # dependency ac-database as well and would never return while it runs
    docker compose up -d ac-db-import >/dev/null 2>&1
    for _i in $(seq 1 360); do
        [ "$(docker inspect -f '{{.State.Status}}' ac-db-import 2>/dev/null)" = "exited" ] && break
        sleep 5
    done
    [ "$(docker inspect -f '{{.State.ExitCode}}' ac-db-import 2>/dev/null)" = "0" ] \
        || die "ac-db-import failed - see: docker logs ac-db-import"
    ok "Base databases created (auth/characters/world)"
fi

# From here on acore_world belongs to the CoA package: the AzerothCore
# auto-updater (ac-db-import) is turned into a no-op so that AC update SQL
# cannot overwrite the CoA content; later migrations are applied below with
# apply-missing-updates.sh (normal updater semantics).
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

# CoA world database: the official package flow (apps/coa-world/README.md).
# Verify + bootstrap + the final audit run inside coa-world-data.sh; it needs
# Python 3.11+ and uses the MySQL client of the ac-database container.
if [ ! -f "$SELF_DIR/coa-world-data.sh" ]; then
    die "coa-world-data.sh not found next to this script - it performs the CoA world import"
fi
ITEMS_NOW="$(world_items)"; ITEMS_NOW="${ITEMS_NOW:-0}"
if [ "$ITEMS_NOW" -gt 400000 ] && [ "$FORCE_IMPORT" != "1" ]; then
    ok "CoA world already installed (${ITEMS_NOW} items) - package import skipped (FORCE_IMPORT=1 re-imports)"
    log "full check any time:  bash coa-world-data.sh audit"
else
    if [ "$FORCE_IMPORT" = "1" ]; then
        log "FORCE_IMPORT=1 -> acore_world is recreated and imported from the package"
        FORCE=1 AC_DIR="$AC_DIR" bash "$SELF_DIR/coa-world-data.sh" bootstrap \
            || die "CoA world package import failed (see output above)"
    else
        AC_DIR="$AC_DIR" bash "$SELF_DIR/coa-world-data.sh" bootstrap \
            || die "CoA world package import failed (see output above)"
    fi
    IMPORTED="$(world_items)"; IMPORTED="${IMPORTED:-0}"
    [ "$IMPORTED" -gt 400000 ] || die "Import failed (only $IMPORTED items in item_template)"
    ok "CoA world imported from the package: ${IMPORTED} item templates"
fi

# Apply missing repo/module SQL updates (migrations after the package baseline)
if [ -f "$SELF_DIR/apply-missing-updates.sh" ]; then
    log "Applying missing repo SQL updates (core/module fixes) ..."
    DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" AC_DIR="$AC_DIR" \
        bash "$SELF_DIR/apply-missing-updates.sh" \
        || warn "Update run reported errors - log: /root/apply-missing-updates.log"
    ok "Repo updates checked and applied"
else
    warn "apply-missing-updates.sh not found - repo updates skipped"
fi

# ---------------------------------------------------- 6b. Player bots (opt.)
# acore_playerbots is the module's own database. mod-playerbots normally fills
# it at worldserver startup, but the runtime image contains no module sources
# (only the db-import image gets data/ + modules/), so this deployment keeps the
# module updater off and imports the base data + the module updates from the
# host - the same place where auth/characters/world updates are applied.
if [ "$WITH_PLAYERBOTS" = "1" ] || [ -d "$AC_DIR/modules/mod-playerbots" ]; then
    step "6b/9  Player bots: acore_playerbots"
    AC_DIR="$AC_DIR" bash "$SELF_DIR/enable-playerbots.sh" --db \
        || warn "Playerbots database setup reported errors - bots may stay offline"
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

# The core loads <name>.conf only, never the .conf.dist template. A template that
# was never copied means the module is not configured at all: every key it reads
# falls back to the code default and writes
#   "> Config: Missing property <KEY> in config file ... or module config"
# to the log - on every read, which is tens of thousands of lines per day. So do
# not list three modules here (that is exactly how mod-coa-challenges and
# mod-dynamic-xp were missed and flooded the log) - activate every template.
# Module configs: the script pulls the templates from the image, activates every
# missing <module>.conf and removes duplicate keys from worldserver.conf. A
# missing module config logs one "Config: Missing property" line per key read -
# tens of thousands per day, which buries real errors.
if [ -f "$SELF_DIR/fix-config-warnings.py" ] && command -v python3 >/dev/null 2>&1; then
    python3 "$SELF_DIR/fix-config-warnings.py" --no-restart --ac-dir "$AC_DIR" \
        || warn "config fix reported a problem (see the output above)"
else
    warn "fix-config-warnings.py or python3 missing - only the basic step below runs"
fi
for dist in "$ETC"/modules/*.conf.dist; do
    if [ ! -e "$dist" ]; then
        warn "No module config templates found in $ETC/modules"
        break
    fi
    conf="${dist%.dist}"
    if [ -f "$conf" ]; then
        ok "Module config active: $(basename "$conf")"
    else
        cp "$dist" "$conf"
        ok "Module config activated: $(basename "$conf")"
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
# Player bots (optional): keep the values this deployment manages (CoA zone
# channel, Ascension world channel, database, bot count) and MapUpdate.Threads
# in sync. Runs whenever the module is installed - also on a later re-run of
# this script on an existing server.
if [ -f "$SELF_DIR/enable-playerbots.sh" ] && [ -d "$AC_DIR/modules/mod-playerbots" ]; then
    AC_DIR="$AC_DIR" bash "$SELF_DIR/enable-playerbots.sh" --config \
        || warn "playerbots.conf sync reported errors - please check the output above"
fi
chown -R 1000:1000 "$ETC" 2>/dev/null || true

# ------------------------------------------------------------ 8. Start
step "8/9  Start + realm address"
log "docker compose up -d"
# output into a log file instead of "| tail -4" (tail prints only when the command
# is done) so a blocking dependency is visible instead of looking like a freeze
COMPOSE_LOG="/tmp/coa_compose_up.log"
rc=0
(timeout 300 docker compose up -d) >"$COMPOSE_LOG" 2>&1 || rc=$?
tail -6 "$COMPOSE_LOG" | sed 's/^/      /'
if [ "$rc" -ne 0 ]; then
    warn "docker compose up returned ${rc} (124 = 5 minute limit: a dependency never became ready)"
    tail -20 "$COMPOSE_LOG" | sed 's/^/      /'
fi

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
port_open() { local o; o="$(ss -ltn 2>/dev/null)"; contains "$o" ":$1 "; }

wait_init() {
    # waits until the worldserver port is listening
    # (no "ss | grep -q": with `set -o pipefail` grep's early exit raises SIGPIPE
    #  and the pipeline fails even though the port is open)
    for _i in $(seq 1 80); do
        port_open "$WORLD_PORT" && return 0
        sleep 3
    done
    return 1
}
log "Waiting for the worldserver ..."
wait_init && ok "Worldserver is up" || warn "Not detected - check: docker logs ac-worldserver"

WSC="env/dist/etc/worldserver.conf"
if [ -f "$WSC" ] && ! grep -q -e 'coa-oneclick.sh additions' -e 'coa-oneclick.sh Ergaenzungen' "$WSC"; then
    log "Adding missing options to worldserver.conf"
    # a file that ends without a newline would glue the first appended line onto
    # the last existing one
    [ -n "$(tail -c 1 "$WSC")" ] && printf '\n' >> "$WSC"
    cat >> "$WSC" <<'EOF'

#
# ---------------------------------------------------------------------------
# coa-oneclick.sh additions / Ergaenzungen
# ---------------------------------------------------------------------------
# Only keys that no config of this fork defines belong here. Keys a module
# config already handles (TeleportActionBar.*, CoAChallenges.*, Dynamic.XP.*)
# belong in env/dist/etc/modules/<module>.conf: a second definition is logged as
# "Config::LoadFile: Duplicate key name ..." and the first value wins anyway.
# The Ascension-compat self test is off (code default = false); this line only
# documents that.
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

# The core marks a realm offline when the worldserver stops and sets a
# version-mismatch bit on startup. Both make the client show "Realm Offline",
# so clear them once the worldserver is up.
CUR_FLAG="$(mysql_q "SELECT flag FROM realmlist WHERE id=1" acore_auth | head -1)"
if [ "${CUR_FLAG:-0}" != "0" ]; then
    mysql_q "UPDATE realmlist SET flag = flag & ~3 WHERE id=1" acore_auth >/dev/null 2>&1
    ok "Realm flag cleared (was ${CUR_FLAG}; offline/mismatch bits removed)"
else
    ok "Realm flag is 0 (online)"
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
if [ -d "$AC_DIR/modules/mod-playerbots" ]; then
    printf "Player bots    : installed (%s) - details: bash enable-playerbots.sh --status\n" \
        "$(git -C "$AC_DIR/modules/mod-playerbots" rev-parse --short HEAD 2>/dev/null || echo '?')"
else
    printf "Player bots    : not installed (optional) - add them later: bash enable-playerbots.sh\n"
fi
echo
printf "Client: realmlist.wtf -> set realmlist %s\n" "${REALM_IP:-<server-ip>}"
printf "Ports : %s (auth), %s (world), %s (SOAP)\n" "$AUTH_PORT" "$WORLD_PORT" "$SOAP_PORT"
echo
ok "Done. Update later with: bash coa-update.sh"