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
# ---------------------------------------------------------------------------
#  Worldserver helpers
# ---------------------------------------------------------------------------
#  "docker compose up" does not return before every depends_on condition is met
#  (ac-database healthy, ac-db-import and ac-client-data-init completed) and it
#  keeps waiting for a service that never becomes ready. Older versions piped
#  that output into "tail" and then polled the port in complete silence, so a
#  stuck or crash-looping stack looked exactly like a frozen script. These
#  helpers make every wait visible and abort with the real log lines.
#  WARNING: never use "cmd | grep -q" for a decision in this script. With
#  `set -o pipefail` the early exit of grep makes the pipeline fail with SIGPIPE
#  (141), so a log line that IS present looks like "not found" - the diagnostics
#  stay silent and "World Initialized" is never detected. Every check therefore
#  captures the output and matches it with a bash pattern, no pipeline involved.
contains()    { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
port_open()   { local o; o="$(ss -ltn 2>/dev/null)"; contains "$o" ":$1 "; }
ws_state()    { docker inspect -f '{{.State.Status}}' ac-worldserver 2>/dev/null || echo missing; }
ws_restarts() { docker inspect -f '{{.RestartCount}}' ac-worldserver 2>/dev/null || echo 0; }
ws_log()      { docker logs --tail 300 ac-worldserver 2>&1; }
ws_last_log() { local o; o="$(docker logs --tail 1 ac-worldserver 2>&1)"; printf '%s\n' "${o: -90}"; }
ws_up() {
    local o
    o="$(ws_log)"
    contains "$o" 'World Initialized' && return 0
    port_open "$WORLD_PORT" && return 0
    return 1
}
ws_dns_diag() {   # prints facts only when the database container cannot be resolved
    local log c rc
    log="$(ws_log)"
    if ! contains "$log" 'Unknown MySQL server host' \
       && ! contains "$log" 'Could not connect to MySQL'; then
        return 0
    fi
    echo "      --- container DNS / network (ac-database is not resolvable) ---"
    for c in ac-worldserver ac-database; do
        rc="$(docker inspect -f '{{.ResolvConfPath}}' "$c" 2>/dev/null)"
        if [ -n "$rc" ] && [ -f "$rc" ]; then
            printf "      %-14s resolv.conf: %s\n" "$c" \
                "$(grep -v '^#' "$rc" 2>/dev/null | grep -v '^$' | tr '\n' ' ')"
            grep -q '127\.0\.0\.11' "$rc" 2>/dev/null \
                || echo "                     -> 127.0.0.11 (embedded DNS) MISSING in this container"
        fi
        printf "      %-14s networks  : %s\n" "$c" \
            "$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}({{$v.IPAddress}}) {{end}}' "$c" 2>/dev/null)"
        printf "      %-14s aliases   : %s\n" "$c" \
            "$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$v.Aliases}} {{end}}' "$c" 2>/dev/null)"
    done
    [ -f /etc/docker/daemon.json ] && \
        printf "      daemon.json    : %s\n" "$(tr -d '\n' < /etc/docker/daemon.json)"
    echo "      repair: bash /root/fix-container-dns.sh   (recreates the containers with clean DNS)"
}
ws_diag() {
    echo "      --- diagnostics ---"
    docker ps -a --format '      {{.Names}}: {{.Status}}' 2>/dev/null \
        | grep -E 'ac-(worldserver|authserver|database|db-import|client-data-init)' || true
    ws_dns_diag
    echo "      last log lines of ac-worldserver:"
    docker logs --tail 30 ac-worldserver 2>&1 | sed 's/^/        /' || true
    echo "      details: docker logs ac-worldserver   /   df -h /"
}
ws_wait() {   # <max_seconds> -> 0 = up, 1 = not up (diagnostics printed)
    local max="${1:-420}" waited=0 state restarts
    while [ "$waited" -lt "$max" ]; do
        if ws_up; then
            printf "  Worldserver is up after %ss.\n" "$waited"
            return 0
        fi
        state="$(ws_state)"
        restarts="$(ws_restarts)"
        case "$state" in
            running|created|starting|paused|restarting) ;;
            *)
                printf "  Worldserver container state is '%s' after %ss - it did not start.\n" "$state" "$waited"
                ws_diag
                return 1 ;;
        esac
        if [ "${restarts:-0}" -gt 2 ] 2>/dev/null; then
            printf "  Worldserver restarted %s times without coming up - crash loop.\n" "$restarts"
            ws_diag
            return 1
        fi
        if [ $((waited % 15)) -eq 0 ]; then
            printf "  ... waiting %ss (state=%s restarts=%s) last log: %s\n" \
                "$waited" "$state" "$restarts" "$(ws_last_log)"
        fi
        sleep 3
        waited=$((waited + 3))
    done
    printf "  Worldserver did not come up within %ss.\n" "$max"
    ws_diag
    return 1
}

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
# "docker compose up -d" waits for ac-database to be healthy and for ac-db-import
# and ac-client-data-init to complete. Its output is written to a log file
# instead of "| tail -5" (tail prints nothing until the command has finished) and
# the wait is limited, so a blocked dependency cannot freeze the update silently.
COMPOSE_LOG="/tmp/coa_compose_up.log"
rc=0
(timeout 300 docker compose up -d) >"$COMPOSE_LOG" 2>&1 || rc=$?
tail -6 "$COMPOSE_LOG" | sed 's/^/      /'
if [ "$rc" -ne 0 ]; then
    warn "docker compose up returned ${rc} (124 = 5 minute limit: a dependency never became ready)"
    tail -20 "$COMPOSE_LOG" | sed 's/^/      /'
fi

log "Waiting for the worldserver (progress below, limit 7 minutes) ..."
if ws_wait 420; then
    ok "Worldserver is up"
else
    warn "Worldserver is NOT up - fix the cause shown above, then watch: docker logs -f ac-worldserver"
fi

# The core marks a realm offline when the worldserver stops and sets a
# version-mismatch bit on startup. Both make the client show "Realm Offline",
# so the flag is cleared only once the world is really running - a start that
# happens later would set the bits again.
PW="${DB_ROOT_PASSWORD:-$(grep -E '^DOCKER_DB_ROOT_PASSWORD=' .env 2>/dev/null | head -1 | cut -d= -f2-)}"
if ws_up; then
    CUR_FLAG="$(docker exec -i ac-database mysql -uroot -p"$PW" acore_auth -N -B \
        -e 'SELECT flag FROM realmlist WHERE id=1' 2>/dev/null | head -1)"
    if [ "${CUR_FLAG:-0}" != "0" ]; then
        docker exec -i ac-database mysql -uroot -p"$PW" acore_auth \
            -e 'UPDATE realmlist SET flag = flag & ~3 WHERE id=1' >/dev/null 2>&1
        ok "Realm flag cleared (was ${CUR_FLAG}; offline/mismatch bits removed)"
    else
        ok "Realm flag is 0 (online)"
    fi
else
    warn "Realm flag left untouched (worldserver not running) - it clears itself once the world is up"
fi

step "5/5  Status"
docker ps -a --format '{{.Names}}: {{.Status}}' | grep -E 'ac-' || true
printf "Commit         : %s\n" "$(git rev-parse --short HEAD)"
printf "Worldserver    : %s, port %s %s\n" "$(ws_state)" "$WORLD_PORT" \
    "$(port_open "$WORLD_PORT" && echo open || echo closed)"
printf "Item templates : %s\n" "$(docker exec -i ac-database mysql -uroot -p"$DB_ROOT_PASSWORD" acore_world -N -B -e 'SELECT COUNT(1) FROM item_template' 2>/dev/null | head -1)"
printf "Errors in log  : %s\n" "$(docker logs --since 10m ac-worldserver 2>&1 | grep -ac -i error)"
printf "Disk           : %s\n" "$(df -h / | awk 'NR==2 {print $4 " free (" $5 " used)"}')"
echo
ok "Update finished. Live log: docker logs -f ac-worldserver"