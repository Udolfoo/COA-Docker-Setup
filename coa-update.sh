#!/usr/bin/env bash
# ============================================================================
#  coa-update.sh  -  one-command update for an existing CoA deployment
# ----------------------------------------------------------------------------
#  Flow:
#    1. Update the repo (git fetch/checkout) + re-apply the build fix
#    2. Apply missing core/module SQL updates from the repo to the databases
#       (tolerant; uses apply-missing-updates.sh from the same folder)
#    3. Rebuild docker images - only if the code changed (or if FULL=1 is set)
#    4. Restart the stack + print a status report
#
#  Usage:
#    bash coa-update.sh            # normal update
#    FULL=1 bash coa-update.sh     # always rebuild images
#    SKIP_DB=1 bash coa-update.sh  # without database update
#
#  Requires: a deployment created with coa-oneclick.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_URL="${REPO_URL:-https://github.com/jealous-sound/azerothcore-wotlk-coa.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
AC_DIR="${AC_DIR:-/opt/azerothcore}"
IMAGE_TAG="${IMAGE_TAG:-coa}"
WORLD_PORT="${WORLD_PORT:-8085}"
FULL="${FULL:-0}"
SKIP_DB="${SKIP_DB:-0}"

c_red='\033[0;31m'; c_grn='\033[0;32m'; c_yel='\033[1;33m'; c_blu='\033[0;36m'; c_off='\033[0m'
log()  { printf "${c_blu}[INFO ]${c_off} %s\n" "$*"; }
ok()   { printf "${c_grn}[ OK  ]${c_off} %s\n" "$*"; }
warn() { printf "${c_yel}[WARN ]${c_off} %s\n" "$*"; }
die()  { printf "${c_red}[FAIL ]${c_off} %s\n" "$*" >&2; exit 1; }
step() { printf "\n${c_grn}=== %s ===${c_off}\n" "$*"; }

[ "$(id -u)" -eq 0 ] || die "Please run as root (sudo bash $0)"
[ -d "$AC_DIR/.git" ] || die "No deployment found at $AC_DIR - run coa-oneclick.sh first"
cd "$AC_DIR" || die "Cannot enter $AC_DIR"
[ -f .env ] || die ".env missing - run coa-oneclick.sh first"

DB_ROOT_PASSWORD="$(grep -E '^DOCKER_DB_ROOT_PASSWORD=' .env | head -1 | cut -d= -f2-)"
[ -n "$DB_ROOT_PASSWORD" ] || die "DOCKER_DB_ROOT_PASSWORD not found in $AC_DIR/.env"

BEFORE="$(git rev-parse HEAD)"
step "1/5  Repository: checking for updates"
git fetch --prune origin "$REPO_BRANCH" >/dev/null 2>&1 || die "git fetch failed"
REMOTE="$(git rev-parse FETCH_HEAD)"

CODE_CHANGED=0
if [ "$BEFORE" = "$REMOTE" ]; then
    ok "No new update - already on ${BEFORE:0:9} (${REPO_BRANCH})"
else
    log "New update found: ${BEFORE:0:9} -> ${REMOTE:0:9}"
    git log --oneline "${BEFORE}..${REMOTE}" 2>/dev/null | head -10 | sed 's/^/      /'
    # Drop the local build-fix change so the checkout can succeed
    # (the fix is re-applied automatically further down).
    FIXREL="modules/mod-ascension-compat/src/AscensionCompat.cpp"
    FIXREL2="modules/mod-ascension-compat/src/AscensionChronomancerMovement.cpp"
    git checkout -- "$FIXREL" "$FIXREL2" 2>/dev/null || true
    if git checkout -B "$REPO_BRANCH" FETCH_HEAD >/dev/null 2>&1; then
        AFTER="$(git rev-parse HEAD)"
        ok "Repo updated: ${BEFORE:0:9} -> ${AFTER:0:9}"
        CODE_CHANGED=1
    else
        warn "checkout failed - please check: git -C $AC_DIR status"
        git -C "$AC_DIR" status --short | head -5 | sed 's/^/      /'
        die "Update aborted (nothing changed). Back up local changes, then run again."
    fi
fi

# Upstream build breakers in mod-ascension-compat (the module lags behind the
# core API). Each fix is applied only while its pattern is still present.
COMPAT="modules/mod-ascension-compat/src"

# 1) SPELL_EFFECT_NONE was removed from enum SpellEffects; 0 is the same value.
FIXFILE="$COMPAT/AscensionCompat.cpp"
if [ -f "$FIXFILE" ] && grep -q 'SPELL_EFFECT_NONE' "$FIXFILE"; then
    sed -i 's/Effects\[EFFECT_2\]\.Effect = SPELL_EFFECT_NONE;/Effects[EFFECT_2].Effect = 0;/' "$FIXFILE"
    grep -q 'SPELL_EFFECT_NONE' "$FIXFILE" && die "Build fix failed: $FIXFILE"
    CODE_CHANGED=1
    ok "Build fix 1 re-applied (SPELL_EFFECT_NONE -> 0)"
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
    CODE_CHANGED=1
    ok "Build fix 2 re-applied (NearTeleportTo temporary -> named Position)"
else
    ok "Build fix 2 not required (NearTeleportTo)"
fi

step "2/5  Database updates (core/module fixes)"
if [ "$SKIP_DB" = "1" ]; then
    warn "skipped (SKIP_DB=1)"
elif [ -f "$SCRIPT_DIR/apply-missing-updates.sh" ]; then
    DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" AC_DIR="$AC_DIR" \
        bash "$SCRIPT_DIR/apply-missing-updates.sh" \
        || warn "Update run reported errors - log: /root/apply-missing-updates.log"
    ok "DB updates checked and applied"
else
    warn "apply-missing-updates.sh not found - DB updates skipped"
fi

step "3/5  Docker images"
if [ "$CODE_CHANGED" = "1" ] || [ "$FULL" = "1" ]; then
    # Network preflight: a fresh VPS can fail here because a build container
    # cannot reach the apt mirrors (broken IPv6 or a DNS stub). Max ~2 minutes.
    if [ -f "$SCRIPT_DIR/fix-build-network.sh" ]; then
        log "Network preflight: checking container DNS/IPv6 (hard limit 5 minutes) ..."
        timeout 300 bash "$SCRIPT_DIR/fix-build-network.sh" \
            || warn "Network preflight reported a problem - trying the build anyway"
    fi
    log "Building images (30-120 minutes) ..."
    if ! docker compose build; then
        warn "Build failed - retrying once (transient mirror/network problems)"
        sleep 10
        docker compose build \
            || die "Image build failed (see README troubleshooting: apt/DNS/IPv6)"
    fi
    ok "Images rebuilt"
    # Free old images + cap the build cache (prevents the disk filling up over time)
    docker image prune -f >/dev/null 2>&1 || true
    docker builder prune -f --keep-storage 8GB >/dev/null 2>&1 || true
    ok "Old images and build cache cleaned up (check: docker system df)"
else
    ok "No code change -> images unchanged (FULL=1 forces a rebuild)"
fi

step "4/5  Restarting stack"
docker compose up -d 2>&1 | tail -5
log "Waiting for worldserver port ..."
for _i in $(seq 1 80); do
    ss -ltn 2>/dev/null | grep -q ":${WORLD_PORT} " && break
    sleep 3
done

step "5/5  Status"
docker ps --format '{{.Names}}: {{.Status}}'
printf "Commit         : %s\n" "$(git rev-parse --short HEAD)"
printf "Item templates : %s\n" "$(docker exec -i ac-database mysql -uroot -p"$DB_ROOT_PASSWORD" acore_world -N -B -e 'SELECT COUNT(1) FROM item_template' 2>/dev/null | head -1)"
printf "Errors in log  : %s\n" "$(docker logs --since 10m ac-worldserver 2>&1 | grep -ac -i error)"
printf "Disk           : %s\n" "$(df -h / | awk 'NR==2 {print $4 " free (" $5 " used)"}')"
echo
ok "Update finished. Live log: docker logs -f ac-worldserver"