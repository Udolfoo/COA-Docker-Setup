#!/usr/bin/env bash
# ===========================================================================
#  coa-build.sh  -  build the CoA docker images (with a ccache that survives)
# ---------------------------------------------------------------------------
#  Why this script exists - measured on this deployment (Docker 29, 8 cores):
#
#  1) The AzerothCore Dockerfile compiles into a throw-away build directory:
#     /azerothcore/build is empty at the start of EVERY build, so ninja can
#     never continue where the last build stopped. The only thing that keeps a
#     rebuild short is ccache - a fully cold compile is ~2239 compiler calls
#     (45-120 minutes).
#  2) That ccache lives in a BuildKit cache mount (/ccache). Docker's build
#     cache garbage collection classifies cache mounts as "easily regenerated"
#     and deletes them together with the cache record that created them
#     (docs.docker.com/build/cache/garbage-collection, policy 1).
#     Measured on this server: "Cacheable calls: 2239 ..., Hits: 0 (0.00%)" -
#     the build of the day compiled from zero because the mount was empty.
#  3) This script keeps the ccache OUTSIDE of Docker's build cache:
#       restore -> the tar is unpacked into the BuildKit mount (only when the
#                  mount is empty; a filled mount costs nothing)
#       build   -> docker compose build (BuildKit, ccache hits)
#       save    -> the mount is packed back into the tar after a build
#     A wiped cache mount is therefore refilled instead of recompiled. The tar
#     is a normal host file: `docker builder prune` does not touch it.
#     `--gc-config` additionally keeps Docker's automatic GC away from the
#     build cache (daemon.json), so the 5 GB compile layers survive as well.
#
#  Usage
#    bash coa-build.sh                # restore + build all images + save
#    bash coa-build.sh --stats        # ccache hit rate, mount + snapshot (read-only)
#    bash coa-build.sh --restore      # only refill the ccache mount
#    bash coa-build.sh --save         # only write the snapshot
#    bash coa-build.sh --gc-config    # keep Docker's GC away from the ccache
#    bash coa-build.sh --no-snapshot  # build without restore/save
#    bash coa-build.sh --full         # ignore the layer cache (ccache still helps)
#
#  Environment
#    AC_DIR=/opt/azerothcore          deployment directory (git checkout + .env)
#    COA_STATE_DIR=/root/.coa-build   snapshot + probe files (small, own folder)
#    COA_CCACHE_FILE=<state>/ccache.tar
#    COA_CCACHE_SNAPSHOT=0            disable restore/save
#    COA_SKIP_PREFLIGHT=1             skip the network preflight
#    COA_BUILD_LOG=/root/coa-build.log
# ===========================================================================
set -uo pipefail

AC_DIR="${AC_DIR:-/opt/azerothcore}"
STATE_DIR="${COA_STATE_DIR:-/root/.coa-build}"
SNAP="${COA_CCACHE_FILE:-$STATE_DIR/ccache.tar}"
BUILD_LOG="${COA_BUILD_LOG:-/root/coa-build.log}"
SNAP_ENABLED="${COA_CCACHE_SNAPSHOT:-1}"
PROBE_IMAGE="acore/coa-ccache-probe:latest"
MODE="build"
FULL=0

# Directory this script lives in (its helpers sit next to it)
SELF_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

c_red='\033[0;31m'; c_grn='\033[0;32m'; c_yel='\033[1;33m'; c_blu='\033[0;36m'; c_off='\033[0m'
log()  { printf "${c_blu}[INFO ]${c_off} %s\n" "$*"; }
ok()   { printf "${c_grn}[ OK  ]${c_off} %s\n" "$*"; }
warn() { printf "${c_yel}[WARN ]${c_off} %s\n" "$*"; }
die()  { printf "${c_red}[FAIL ]${c_off} %s\n" "$*" >&2; exit 1; }
step() { printf "\n${c_grn}=== %s ===${c_off}\n" "$*"; }

usage() {
    sed -n '2,40p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^$/d'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --stats)       MODE="stats" ;;
        --restore)     MODE="restore" ;;
        --save)        MODE="save" ;;
        --gc-config)   MODE="gc-config" ;;
        --no-snapshot) SNAP_ENABLED=0 ;;
        --full)        FULL=1 ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1   (try: bash $0 --help)" ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || die "please run as root (sudo bash $0)"
command -v docker >/dev/null 2>&1 || die "docker is not installed"
[ -f "$AC_DIR/docker-compose.yml" ] || die "no deployment found at $AC_DIR (run coa-oneclick.sh first)"
mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
cd "$AC_DIR" || die "cannot enter $AC_DIR"

IMAGE_TAG="$(grep -E '^DOCKER_IMAGE_TAG=' .env 2>/dev/null | head -1 | cut -d= -f2-)"
IMAGE_TAG="${IMAGE_TAG:-coa}"
# the compose project name decides the container prefix (ac-*) and networks
PROJECT="$(grep -E '^COMPOSE_PROJECT_NAME=' .env 2>/dev/null | head -1 | cut -d= -f2-)"
PROJECT="${PROJECT:-azerothcore}"

# ------------------------------------------------------------------ helpers
# Any image that exists is enough to run the tiny probe builds below (they only
# need /bin/sh, tar and du).
probe_base_image() {
    local t
    for t in "acore/ac-wotlk-worldserver:${IMAGE_TAG}" \
             "acore/ac-wotlk-authserver:${IMAGE_TAG}" \
             "acore/ac-wotlk-db-import:${IMAGE_TAG}" \
             ubuntu:24.04; do
        if docker image inspect "$t" >/dev/null 2>&1; then printf '%s' "$t"; return 0; fi
    done
    return 1
}

human() {   # <file> -> size like "546M"
    [ -e "$1" ] || { printf 'missing'; return 0; }
    du -h "$1" 2>/dev/null | cut -f1
}

kb_human() { # <kbytes> -> "553 MB" / "2.1 GB"
    awk -v k="${1:-0}" 'BEGIN { if (k >= 1048576) printf "%.1f GB", k/1048576; else printf "%.0f MB", k/1024 }'
}

# "files kbytes" of the BuildKit ccache mount - one tiny build that writes
# nothing (--output type=cacheonly). Prints nothing when it cannot be measured.
ccache_mount_probe() {
    local base out
    base="$(probe_base_image)" || return 1
    out="$(docker build --output type=cacheonly --progress=plain \
            --build-arg COA_NONCE="$(date +%s%N)" -f - "$STATE_DIR" 2>&1 <<EOF
FROM $base
USER root
ARG COA_NONCE=0
RUN --mount=type=cache,target=/ccache,sharing=locked \\
    echo "probe=\$COA_NONCE" >/dev/null && \
    printf 'COA_PROBE=%s %s\n' "\$(find /ccache -type f 2>/dev/null | wc -l)" "\$(du -sk /ccache 2>/dev/null | cut -f1)"
EOF
)" || return 1
    printf '%s' "$(printf '%s\n' "$out" | sed -n 's/.*COA_PROBE=//p' | tail -1)"
}

# ------------------------------------------------------------------ snapshot
# The BuildKit cache mount is not a reliable place to keep ~0.5 GB of ccache:
# its data is deleted together with the cache record that created it. The tar
# written here is a normal host file - Docker's GC never touches it.
ccache_save() {
    local base tmp out rc=0
    base="$(probe_base_image)" || { warn "no CoA image available to run the snapshot helper"; return 1; }
    tmp="$STATE_DIR/export.$$"
    rm -rf "$tmp"; mkdir -p "$tmp" || return 1
    log "packing the ccache mount -> $SNAP"
    out="$(docker build --progress=plain -f - --output "type=local,dest=$tmp" "$STATE_DIR" 2>&1 <<EOF
FROM $base AS export
USER root
ARG COA_NONCE=0
RUN --mount=type=cache,target=/ccache,sharing=locked \\
    echo "snapshot nonce=\$COA_NONCE" >/dev/null && \\
    mkdir -p /out && tar cf /out/ccache.tar -C / ccache && \\
    printf '[coa] packed %s (%s files)\n' "\$(du -sh /out/ccache.tar | cut -f1)" "\$(find /ccache -type f | wc -l)"

FROM scratch
COPY --from=export /out/ccache.tar /ccache.tar
EOF
)" || rc=$?
    printf '%s\n' "$out" | sed -n 's/^#\?[0-9]* *[0-9.]* \[coa\]/      [coa]/p'
    if [ "$rc" -eq 0 ] && [ -s "$tmp/ccache.tar" ]; then
        mv -f "$tmp/ccache.tar" "$SNAP" 2>/dev/null || cp -f "$tmp/ccache.tar" "$SNAP"
        rm -rf "$tmp"
        ok "ccache snapshot written: $SNAP ($(human "$SNAP"))"
        return 0
    fi
    rm -rf "$tmp"
    warn "snapshot export failed (rc=$rc) - the ccache stays inside Docker only"
    printf '%s\n' "$out" | tail -5 | sed 's/^/      /'
    return 1
}

# Refill an empty mount from the tar. Called only when the mount really is
# empty, so the untar (seconds) is never paid on a healthy cache.
ccache_restore() {
    local base out rc=0
    [ -s "$SNAP" ] || { warn "no ccache snapshot at $SNAP"; return 1; }
    base="$(probe_base_image)" || { warn "no CoA image available to run the restore helper"; return 1; }
    log "unpacking $SNAP ($(human "$SNAP")) into the ccache mount"
    out="$(docker build --progress=plain --output type=cacheonly \
            --build-arg COA_NONCE="$(date +%s%N)" -f - "$STATE_DIR" 2>&1 <<EOF
FROM $base
USER root
ARG COA_NONCE=0
RUN --mount=type=cache,target=/ccache,sharing=locked \\
    --mount=type=bind,source=ccache.tar,target=/seed.tar \\
    echo "restore nonce=\$COA_NONCE" >/dev/null && \\
    tar xf /seed.tar -C / && \\
    printf '[coa] mounted %s files\n' "\$(find /ccache -type f | wc -l)"
EOF
)" || rc=$?
    printf '%s\n' "$out" | sed -n 's/^#\?[0-9]* *[0-9.]* \[coa\]/      [coa]/p'
    if [ "$rc" -eq 0 ]; then
        ok "ccache mount filled from the snapshot"
        return 0
    fi
    warn "restore failed (rc=$rc) - this build would compile from zero"
    printf '%s\n' "$out" | tail -5 | sed 's/^/      /'
    return 1
}


# ------------------------------------------------------------ ccache numbers
# The runtime images contain no ccache binary, so a small helper image is built
# once and reused: it can run "ccache -s" against the very same mount. Building
# it needs the apt mirrors (the network preflight runs before the image build).
ensure_probe_image() {
    local base
    docker image inspect "$PROBE_IMAGE" >/dev/null 2>&1 && return 0
    base="$(probe_base_image)" || return 1
    mkdir -p "$STATE_DIR/probe"
    cat > "$STATE_DIR/probe/Dockerfile" <<EOF
FROM $base
USER root
ENV CCACHE_DIR=/ccache
RUN apt-get update -qq && apt-get install -y --no-install-recommends ccache >/dev/null 2>&1 \\
    || echo "[coa] ccache could not be installed (apt mirrors unreachable?)"
EOF
    log "creating the ccache probe image (once, uses the apt mirrors) ..."
    if docker build -q -t "$PROBE_IMAGE" "$STATE_DIR/probe" >/dev/null 2>&1; then
        ok "probe image ready: $PROBE_IMAGE"
        return 0
    fi
    warn "probe image could not be created - only the mount numbers are shown"
    return 1
}

ccache_stats_output() {
    docker build --output type=cacheonly --progress=plain \
        --build-arg COA_NONCE="$(date +%s%N)" -f - "$STATE_DIR" 2>&1 <<EOF \
        | sed -n 's/^#\?[0-9]* *[0-9.]* //p'
FROM $PROBE_IMAGE
USER root
ENV CCACHE_DIR=/ccache
ARG COA_NONCE=0
RUN --mount=type=cache,target=/ccache,sharing=locked \\
    echo "stats nonce=\$COA_NONCE" >/dev/null && ccache -s 2>&1 || true
EOF
}

report_ccache() {   # [--full]
    local info files kb
    step "ccache / build cache"
    info="$(ccache_mount_probe || true)"
    files="${info%% *}"; kb="${info##* }"
    if [ -n "${info:-}" ]; then
        if [ "${files:-0}" -gt 0 ] 2>/dev/null; then
            printf '  BuildKit mount  : %s files, %s\n' "$files" "$(kb_human "$kb")"
        else
            printf '  BuildKit mount  : EMPTY -> the next build would compile from zero\n'
        fi
    else
        printf '  BuildKit mount  : not measurable (no image for the probe build)\n'
    fi
    if [ -s "$SNAP" ]; then
        printf '  snapshot        : %s (%s, %s)\n' "$SNAP" "$(human "$SNAP")" \
            "$(date -r "$SNAP" '+%F %T' 2>/dev/null || echo '?')"
    else
        printf '  snapshot        : none yet - the next build creates %s\n' "$SNAP"
    fi
    if [ "${1:-}" = "--full" ]; then
        if ensure_probe_image; then
            printf '\n  ccache statistics (counted since the mount was last empty):\n'
            ccache_stats_output |
                grep -E 'Cacheable|Hits|Misses|Cache size|Files|Errors|Uncacheable' |
                sed 's/^/    /' | head -20
            printf '    (100%% misses = the mount was empty when the last build started)\n'
        fi
    fi
}

# --------------------------------------------------------------- build flow
preflight_network() {
    local helper
    [ "${COA_SKIP_PREFLIGHT:-0}" = "1" ] && { log "network preflight skipped (COA_SKIP_PREFLIGHT=1)"; return 0; }
    if [ -f "$SELF_DIR/coa-fix-network.sh" ]; then
        helper="$SELF_DIR/coa-fix-network.sh --build"
    elif [ -f "$SELF_DIR/fix-build-network.sh" ]; then
        helper="$SELF_DIR/fix-build-network.sh"
    else
        log "no network preflight script found - building anyway"
        return 0
    fi
    log "network preflight: container DNS / IPv6 / apt mirrors (hard limit 5 minutes) ..."
    # shellcheck disable=SC2086
    timeout 300 bash $helper || warn "network preflight reported a problem - trying the build anyway"
}

do_build() {
    local rc=0 info files extra=""
    step "Building the CoA images (tag: ${IMAGE_TAG})"

    # 1) refill the BuildKit ccache mount when Docker's GC emptied it
    if [ "$SNAP_ENABLED" = "1" ]; then
        info="$(ccache_mount_probe || true)"
        files="${info%% *}"
        if [ -z "${info:-}" ]; then
            warn "the ccache mount cannot be measured - snapshot handling skipped"
        elif [ "${files:-0}" -eq 0 ] 2>/dev/null; then
            if [ -s "$SNAP" ]; then
                ccache_restore || warn "without the restore this build compiles everything"
            else
                warn "no ccache snapshot yet: THIS build compiles everything (45-120 min)"
                warn "  it writes $SNAP at the end - all later rebuilds are short"
            fi
        else
            ok "ccache mount already filled ($files files) - no restore needed"
        fi
    fi

    # 2) the apt mirrors have to be reachable from inside a build container
    preflight_network

    # 3) build (-cache stays on: ccache lives in the mount, not in the layers)
    [ "$FULL" = "1" ] && extra="--no-cache"
    log "docker compose build${extra:+ --no-cache} - log: $BUILD_LOG"
    log "  cold: 45-120 min | with a warm ccache: a few minutes"
    ( export DOCKER_BUILDKIT=1 BUILDKIT_PROGRESS=plain; docker compose build $extra ) \
        2>&1 | tee "$BUILD_LOG" || rc=1
    if [ "$rc" -ne 0 ]; then
        warn "build failed - retrying once (transient mirror/network problems)"
        sleep 10
        ( export DOCKER_BUILDKIT=1 BUILDKIT_PROGRESS=plain; docker compose build $extra ) \
            2>&1 | tee -a "$BUILD_LOG" \
            || die "image build failed - see $BUILD_LOG and the README (apt mirrors / DNS / IPv6)"
    fi
    ok "images built (tag: ${IMAGE_TAG})"
    docker image prune -f >/dev/null 2>&1 || true
    ok "dangling images removed (the builder cache is kept - it holds the ccache)"

    # 4) keep the ccache outside of Docker
    if [ "$SNAP_ENABLED" = "1" ]; then
        ccache_save || warn "the snapshot could not be written (see above)"
    fi
    report_ccache
}

# ------------------------------------------------------------------ GC config
# Docker's automatic build cache GC prunes "cache mounts" (its policy 1, they
# count as "easily regenerated") and shrinks the cache to a default budget -
# that is what emptied the ccache and made every build a full rebuild. This
# raises the budget and keeps cache mounts for 14 days. It is written into
# /etc/docker/daemon.json (backup + validation included) and needs a daemon
# restart to take effect.
gc_config() {
    local f=/etc/docker/daemon.json out rc=0
    step "Docker build cache GC (keep the ccache)"
    [ -f "$f" ] || { printf '{}\n' > "$f"; ok "created $f"; }
    cp -f "$f" "$f.bak-coa-gc" 2>/dev/null && log "backup: $f.bak-coa-gc"
    out="$(python3 - "$f" <<'PYEOF'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
raw = p.read_text().strip() if p.exists() else ""
try:
    data = json.loads(raw) if raw else {}
except Exception as exc:
    print("daemon.json is not valid JSON (%s) - NOT touched" % exc)
    sys.exit(1)
builder = data.setdefault("builder", {})
gc = builder.setdefault("gc", {})
if gc.get("policy"):
    print("builder.gc.policy already configured (defaultKeepStorage=%s) - left untouched"
          % gc.get("defaultKeepStorage"))
    sys.exit(3)
gc["enabled"] = True
gc.setdefault("defaultKeepStorage", "40GB")
gc["policy"] = [
    {"keepStorage": "20GB", "filter": ["type==exec.cachemount", "unused-for=336h"]},
    {"keepStorage": "30GB", "filter": ["unused-for=336h"]},
    {"keepStorage": "40GB"},
]
p.write_text(json.dumps(data, indent=2) + "\n")
print("written: cache mounts are kept for 14 days, cache budget 40GB")
PYEOF
)" || rc=$?
    printf '%s\n' "$out" | sed 's/^/  /'
    [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || { warn "daemon.json left unchanged"; return 1; }

    if command -v dockerd >/dev/null 2>&1 && ! dockerd --validate --config-file="$f" >/dev/null 2>&1; then
        warn "dockerd --validate rejected $f - restoring the backup"
        [ -f "$f.bak-coa-gc" ] && cp -f "$f.bak-coa-gc" "$f"
        return 1
    fi
    ok "daemon.json is valid (dockerd --validate)"
    if [ "$rc" -eq 3 ]; then
        return 0
    fi
    log "takes effect after the next Docker daemon restart: systemctl restart docker"
    log "  a restart also renews the container network state - afterwards check:"
    log "  bash coa-fix-network.sh --runtime"
}

# ---------------------------------------------------------------- dispatcher
case "$MODE" in
    build)   do_build ;;
    restore) ccache_restore && report_ccache ;;
    save)    ccache_save && report_ccache ;;
    stats)   report_ccache --full ;;
    gc-config) gc_config ;;
    *)       die "unknown mode: $MODE" ;;
esac

