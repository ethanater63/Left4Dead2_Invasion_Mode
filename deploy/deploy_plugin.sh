#!/usr/bin/env bash
# ============================================================================
# deploy_plugin.sh - push the compiled plugin and configs to the L4D2 server,
#                    restart it, and show the newest SourceMod error log.
#
# Run from the REPO ROOT:
#     ./deploy/deploy_plugin.sh
#
# Environment:
#     L4D2_HOST   ssh target        (default: steam@l4d2.local)
#     L4D2_PATH   game dir on host  (default: /home/steam/l4d2/left4dead2)
#
# Requires: ssh and scp locally (rsync is used when present; without it, e.g. in
# Git Bash on Windows, files are copied with scp instead), key-based ssh to
# L4D2_HOST, and passwordless sudo on the host for `systemctl restart l4d2`.
#
# Implements CLAUDE.md Step 5.
# ============================================================================
set -euo pipefail

L4D2_HOST="${L4D2_HOST:-steam@l4d2.local}"
L4D2_PATH="${L4D2_PATH:-/home/steam/l4d2/left4dead2}"

readonly SM_PATH="${L4D2_PATH}/addons/sourcemod"
readonly REMOTE_DB="${SM_PATH}/configs/databases.cfg"
readonly LOG_DIR="${SM_PATH}/logs"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m!!  WARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m!!  FATAL: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v ssh   >/dev/null 2>&1 || die "ssh is not installed locally."

if command -v rsync >/dev/null 2>&1; then
    HAVE_RSYNC=1
else
    HAVE_RSYNC=0
    command -v scp >/dev/null 2>&1 || die "neither rsync nor scp is installed locally."
    warn "rsync not found - copying with scp (every file is sent, not just changed ones)"
fi

# push SRC... DEST - copy local files to a remote path. rsync skips unchanged
# files; scp sends everything, which is fine for a handful of small files.
push() {
    if ((HAVE_RSYNC)); then
        rsync -av --checksum "$@"
    else
        local f
        for f in "${@:1:$#-1}"; do info "$(basename "$f")"; done
        scp -q "$@"
    fi
}

if [[ ! -f "${REPO_ROOT}/plugins/l4d2_invasion.smx" ]]; then
    die "plugins/l4d2_invasion.smx not found.
    Compile it first:   ./build.sh
    (then re-run this script from the repo root)"
fi

log "Deploying to ${L4D2_HOST}:${L4D2_PATH}"
info "plugin: $(basename "${REPO_ROOT}/plugins/l4d2_invasion.smx")"

ssh -o BatchMode=yes "${L4D2_HOST}" "test -d '${SM_PATH}/plugins'" \
    || die "cannot reach ${L4D2_HOST} or ${SM_PATH}/plugins does not exist.
    Check ssh keys, L4D2_HOST, L4D2_PATH, and that deploy/setup_lxc.sh has run."

# ---------------------------------------------------------------------------
# Plugins
# ---------------------------------------------------------------------------
log "copy plugins/*.smx -> addons/sourcemod/plugins/"
push "${REPO_ROOT}"/plugins/*.smx "${L4D2_HOST}:${SM_PATH}/plugins/"

# ---------------------------------------------------------------------------
# Third-party gamedata
# ---------------------------------------------------------------------------
# zombie_spawn_fix is built from third_party/ into plugins/, so the copy above
# already ships its .smx - but it SetFailStates without its gamedata, so that
# has to go too. Every other companion plugin is installed server-side by
# setup_lxc.sh along with its own gamedata, so nothing else belongs here.
if compgen -G "${REPO_ROOT}/third_party/*/gamedata/*.txt" >/dev/null; then
    log "copy third_party gamedata -> addons/sourcemod/gamedata/"
    push "${REPO_ROOT}"/third_party/*/gamedata/*.txt \
        "${L4D2_HOST}:${SM_PATH}/gamedata/"
else
    info "no third_party gamedata to deploy"
fi

# ---------------------------------------------------------------------------
# Configs
# ---------------------------------------------------------------------------
log "copy configs"
if [[ -f "${REPO_ROOT}/cfg/server.cfg" ]]; then
    push "${REPO_ROOT}/cfg/server.cfg" "${L4D2_HOST}:${L4D2_PATH}/cfg/"
else
    warn "cfg/server.cfg missing locally - not deployed"
fi

if compgen -G "${REPO_ROOT}/cfg/sourcemod/*.cfg" >/dev/null; then
    ssh -o BatchMode=yes "${L4D2_HOST}" "mkdir -p '${L4D2_PATH}/cfg/sourcemod'"
    push "${REPO_ROOT}"/cfg/sourcemod/*.cfg \
        "${L4D2_HOST}:${L4D2_PATH}/cfg/sourcemod/"
else
    warn "no cfg/sourcemod/*.cfg locally - not deployed"
fi

# ---------------------------------------------------------------------------
# databases.cfg - append the l4d2_invasion block only when it is missing
# ---------------------------------------------------------------------------
log "databases.cfg - l4d2_invasion SQLite entry"
SNIPPET="${REPO_ROOT}/configs/databases.cfg.snippet"

if [[ ! -f "${SNIPPET}" ]]; then
    warn "configs/databases.cfg.snippet missing locally - skipping the DB entry"
elif ssh -o BatchMode=yes "${L4D2_HOST}" "grep -q '\"l4d2_invasion\"' '${REMOTE_DB}'" 2>/dev/null; then
    info "entry already present on the host, nothing to do"
else
    info "entry absent - appending it"
    # Ship the snippet, then insert it before the LAST closing brace (the end of
    # the "Databases" section), skipping the snippet's comment and blank lines.
    push "${SNIPPET}" "${L4D2_HOST}:/tmp/l4d2_invasion_db.snippet"
    ssh -o BatchMode=yes "${L4D2_HOST}" \
        "DB='${REMOTE_DB}' SNIP=/tmp/l4d2_invasion_db.snippet bash -s" <<'REMOTE'
set -euo pipefail
if [ ! -f "$DB" ]; then
    echo "!!  WARNING: $DB not found on the host - add the snippet by hand" >&2
    exit 0
fi
[ -f "${DB}.bak" ] || cp "$DB" "${DB}.bak"
awk -v snip="$SNIP" '
    { lines[NR] = $0; if ($0 ~ /^[[:space:]]*}[[:space:]]*$/) last = NR }
    END {
        for (i = 1; i <= NR; i++) {
            if (i == last) {
                while ((getline s < snip) > 0) {
                    if (s !~ /^[[:space:]]*\/\// && s !~ /^[[:space:]]*$/)
                        print s
                }
                close(snip)
            }
            print lines[i]
        }
    }
' "$DB" > "${DB}.new"
if grep -q '"l4d2_invasion"' "${DB}.new"; then
    mv "${DB}.new" "$DB"
    echo "    appended (original saved as databases.cfg.bak)"
else
    rm -f "${DB}.new"
    echo "!!  WARNING: could not insert the block - merge it into $DB by hand" >&2
fi
rm -f "$SNIP"
REMOTE
fi

# ---------------------------------------------------------------------------
# Restart
# ---------------------------------------------------------------------------
log "Restarting the l4d2 service"
RESTART_OK=1
if ssh -o BatchMode=yes "${L4D2_HOST}" "sudo -n systemctl restart l4d2"; then
    info "restart issued"
else
    RESTART_OK=0
    warn "could not restart l4d2 over ssh (passwordless sudo missing, or the unit failed).
    Run on the host:   sudo systemctl restart l4d2 && systemctl status l4d2"
fi

if ((RESTART_OK)); then
    # Give srcds a moment to load Metamod/SourceMod before reading the log.
    sleep 8
    ssh -o BatchMode=yes "${L4D2_HOST}" "systemctl is-active l4d2" \
        && info "unit is active" \
        || warn "unit is not active - check: journalctl -u l4d2 -n 100"
fi

# ---------------------------------------------------------------------------
# Newest SourceMod error log
# ---------------------------------------------------------------------------
log "Last 50 lines of the newest SourceMod error log"
ssh -o BatchMode=yes "${L4D2_HOST}" "LOG_DIR='${LOG_DIR}' bash -s" <<'REMOTE'
set -uo pipefail
newest="$(ls -1t "$LOG_DIR"/errors_*.log 2>/dev/null | head -n 1 || true)"
if [ -z "$newest" ]; then
    echo "    no error log - clean"
    exit 0
fi
echo "    $newest"
echo "    ----------------------------------------------------------------"
tail -n 50 "$newest" | sed 's/^/    /'
REMOTE

log "Deploy finished"
if ((RESTART_OK)); then
    info "Verify in the server console or via rcon:   sm plugins list"
else
    info "Restart the service by hand, then run:      sm plugins list"
    exit 1
fi
