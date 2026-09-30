#!/usr/bin/env bash
# ============================================================================
# setup_lxc.sh - provision a Debian 12 LXC (Proxmox) as an L4D2 Invasion Mode
#                dedicated server.
#
# Run as root INSIDE the container:
#     bash deploy/setup_lxc.sh
#
# Idempotent: safe to re-run. Re-running updates the game server, re-installs
# the plugin/gamedata files, and re-applies the config merges.
#
# Implements CLAUDE.md Step 1 (items 1-10) and Step 2 (l4dinfectedbots config).
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned versions (verified stable at time of writing)
# ---------------------------------------------------------------------------
readonly APPID=222860                       # Left 4 Dead 2 Dedicated Server
readonly MM_VER="1.12.0-git1227"
readonly SM_VER="1.12.0-git7253"
readonly MM_TARBALL="mmsource-${MM_VER}-linux.tar.gz"
readonly SM_TARBALL="sourcemod-${SM_VER}-linux.tar.gz"
readonly MM_URL="https://mms.alliedmods.net/mmsdrop/1.12/${MM_TARBALL}"
readonly SM_URL="https://sm.alliedmods.net/smdrop/1.12/${SM_TARBALL}"
readonly STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"

# Left 4 DHooks Direct 1.168 (plugin + gamedata + data cfg only; no extension)
readonly L4DH_VER="1.168"
readonly L4DH_RAW="https://raw.githubusercontent.com/SilvDev/Left4DHooks/master"

# l4dinfectedbots (fbef0102/L4D1_2-Plugins, master branch)
readonly IB_RAW="https://raw.githubusercontent.com/fbef0102/L4D1_2-Plugins/master/l4dinfectedbots"

# Companion plugins recommended by the l4dinfectedbots readme.
#
# fbef0102/L4D1_2-Plugins ships prebuilt .smx per plugin folder.
readonly FB_RAW="https://raw.githubusercontent.com/fbef0102/L4D1_2-Plugins/master"

# Target5150/MoYu_Server_Stupid_Plugins has NO prebuilt .smx in the repo tree,
# only in its release zips. MoYu-Plugins-1.12.zip is the SourceMod 1.12 build.
# Pinned to a release tag so a new upstream release cannot change what installs.
readonly MOYU_TAG="20260925134758"
readonly MOYU_ZIP="MoYu-Plugins-1.12.zip"
readonly MOYU_URL="https://github.com/Target5150/MoYu_Server_Stupid_Plugins/releases/download/${MOYU_TAG}/${MOYU_ZIP}"
# Plugin folders to lift out of that zip (all under "The Last Stand/").
readonly MOYU_PLUGINS=(
    l4d_unrestrict_panic_battlefield
    l4d_fix_deathfall_cam
    l4d2_scripted_tank_stage_fix
)

# Source Scramble extension - required by l4d_unrestrict_panic_battlefield, and
# by zombie_spawn_fix if you add it by hand. For SourceMod 1.12 (stable) the
# upstream release notes say use "package.tar.gz"; the "-api10" packages are for
# SourceMod 1.13.0.7451+ only. Do not swap these without re-reading that note.
readonly SCRAMBLE_VER="0.8.2.2"
readonly SCRAMBLE_TARBALL="sourcescramble-${SCRAMBLE_VER}.tar.gz"
readonly SCRAMBLE_URL="https://github.com/nosoop/SMExt-SourceScramble/releases/download/${SCRAMBLE_VER}/package.tar.gz"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
readonly STEAM_USER="steam"
readonly STEAM_HOME="/home/steam"
readonly STEAMCMD_DIR="${STEAM_HOME}/steamcmd"
readonly SRV_DIR="${STEAM_HOME}/l4d2"                 # srcds_run lives here
readonly GAME_DIR="${SRV_DIR}/left4dead2"             # addons/ and cfg/ live here
readonly SM_DIR="${GAME_DIR}/addons/sourcemod"
readonly CACHE_DIR="${STEAM_HOME}/cache"              # tarball download cache
readonly UNIT_FILE="/etc/systemd/system/l4d2.service"
readonly PORT=27015

# Repo checkout this script was run from (deploy/setup_lxc.sh -> repo root)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

# Collected non-fatal problems, printed again in the final summary.
WARNINGS=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m!!  WARNING: %s\033[0m\n' "$*" >&2; WARNINGS+=("$*"); }
die()  { printf '\033[1;31m!!  FATAL: %s\033[0m\n' "$*" >&2; exit 1; }

# Run a command as the steam user.
as_steam() { runuser -u "${STEAM_USER}" -- "$@"; }

# Download $1 to $2 unless $2 already exists and is non-empty.
cached_download() {
    local url="$1" dest="$2"
    if [[ -s "${dest}" ]]; then
        info "cached, skipping download: $(basename "${dest}")"
        return 0
    fi
    info "downloading $(basename "${dest}")"
    curl -fsSL --retry 3 --retry-delay 2 -o "${dest}.part" "${url}" \
        || die "download failed: ${url}"
    mv "${dest}.part" "${dest}"
}

# Fetch $1 (URL) to $2 (absolute dest path), owned by steam:steam, mode 644.
# Always re-fetches, so re-running the script picks up upstream fixes.
fetch_file() {
    local url="$1" dest="$2" tmp
    tmp="$(mktemp)"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "${tmp}" "${url}"; then
        rm -f "${tmp}"
        die "could not fetch ${url}"
    fi
    install -D -o "${STEAM_USER}" -g "${STEAM_USER}" -m 644 "${tmp}" "${dest}"
    rm -f "${tmp}"
    info "installed ${dest}"
}

[[ "$(id -u)" -eq 0 ]] || die "run this script as root inside the LXC."

# ---------------------------------------------------------------------------
# Steps 1 and 2 - i386 architecture and packages
# ---------------------------------------------------------------------------
step_packages() {
    log "Step 1/2: i386 architecture + 32-bit runtime packages"

    if dpkg --print-foreign-architectures | grep -qx 'i386'; then
        info "i386 architecture already added"
    else
        dpkg --add-architecture i386
        info "i386 architecture added"
    fi

    apt-get update -qq

    # srcds is a 32-bit binary: lib32gcc-s1, lib32stdc++6 and libc6-i386 are required.
    # Beyond CLAUDE.md's list: unzip, so step_companions can lift the MoYu plugins
    # out of their release zip; and sudo, which the Debian 12 standard LXC template
    # does NOT ship and which deploy_plugin.sh needs for `sudo -n systemctl restart`.
    local pkgs=(lib32gcc-s1 lib32stdc++6 libc6-i386 curl tar unzip sudo screen sqlite3 ca-certificates)
    local missing=()
    local p
    for p in "${pkgs[@]}"; do
        dpkg-query -W -f='${Status}' "${p}" 2>/dev/null | grep -q 'ok installed' \
            || missing+=("${p}")
    done
    if ((${#missing[@]})); then
        info "installing: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    else
        info "all required packages already installed"
    fi
}

# ---------------------------------------------------------------------------
# Step 3 - the steam user
# ---------------------------------------------------------------------------
step_user() {
    log "Step 3: user '${STEAM_USER}'"
    if id -u "${STEAM_USER}" >/dev/null 2>&1; then
        info "user already exists"
    else
        adduser --disabled-password --gecos "L4D2 server" --home "${STEAM_HOME}" "${STEAM_USER}"
        info "created user ${STEAM_USER} (home ${STEAM_HOME})"
    fi
    install -d -o "${STEAM_USER}" -g "${STEAM_USER}" -m 755 \
        "${STEAM_HOME}" "${STEAMCMD_DIR}" "${CACHE_DIR}" "${SRV_DIR}"
}

# ---------------------------------------------------------------------------
# Deploy access - what deploy_plugin.sh needs to work from a workstation
# ---------------------------------------------------------------------------
# deploy_plugin.sh connects as steam@ and runs `sudo -n systemctl restart l4d2`.
# Neither works on a fresh container: the Debian 12 LXC template ships no sudo
# (now installed in step 1/2), and the steam user has no authorized_keys. Both
# are set up here so a deploy works straight after setup.
step_deploy_access() {
    log "Deploy access: steam SSH key + scoped sudo rule"

    # sudo rule, deliberately scoped to this one unit rather than blanket root.
    local sudoers="/etc/sudoers.d/steam-l4d2"
    cat > "${sudoers}" <<SUDOERS
# Installed by deploy/setup_lxc.sh so deploy_plugin.sh can restart the server.
# Scoped to the l4d2 unit on purpose - this is NOT general root access.
${STEAM_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl restart l4d2, /usr/bin/systemctl start l4d2, /usr/bin/systemctl stop l4d2, /usr/bin/systemctl status l4d2
SUDOERS
    chmod 440 "${sudoers}"
    # Never leave a broken sudoers file behind - it can lock the box out of sudo.
    if visudo -c -f "${sudoers}" >/dev/null 2>&1; then
        info "installed ${sudoers} (restart/start/stop/status of l4d2 only)"
    else
        rm -f "${sudoers}"
        die "generated sudoers file failed validation and was removed"
    fi

    # SSH key for steam. DEPLOY_PUBKEY wins; otherwise inherit root's keys, which
    # is how a Proxmox-created container already has the operator's key.
    install -d -o "${STEAM_USER}" -g "${STEAM_USER}" -m 700 "${STEAM_HOME}/.ssh"
    local authkeys="${STEAM_HOME}/.ssh/authorized_keys"

    if [[ -n "${DEPLOY_PUBKEY:-}" ]]; then
        printf '%s\n' "${DEPLOY_PUBKEY}" > "${authkeys}"
        info "steam authorized_keys written from \$DEPLOY_PUBKEY"
    elif [[ -s /root/.ssh/authorized_keys ]]; then
        cp /root/.ssh/authorized_keys "${authkeys}"
        info "steam authorized_keys inherited from root"
    else
        warn "no SSH key for ${STEAM_USER}: \$DEPLOY_PUBKEY is unset and
    /root/.ssh/authorized_keys is empty or missing. deploy_plugin.sh will not be
    able to log in until you add a public key to ${authkeys}."
        touch "${authkeys}"
    fi

    chown "${STEAM_USER}:${STEAM_USER}" "${authkeys}"
    chmod 600 "${authkeys}"
}

# ---------------------------------------------------------------------------
# Step 4 - SteamCMD
# ---------------------------------------------------------------------------
step_steamcmd() {
    log "Step 4: SteamCMD in ${STEAMCMD_DIR}"
    if [[ -x "${STEAMCMD_DIR}/steamcmd.sh" ]]; then
        info "steamcmd.sh already present"
    else
        cached_download "${STEAMCMD_URL}" "${CACHE_DIR}/steamcmd_linux.tar.gz"
        tar -xzf "${CACHE_DIR}/steamcmd_linux.tar.gz" -C "${STEAMCMD_DIR}"
        info "extracted SteamCMD"
    fi
    chown -R "${STEAM_USER}:${STEAM_USER}" "${STEAMCMD_DIR}" "${CACHE_DIR}"
    # First run self-updates and exits; harmless on re-run.
    as_steam "${STEAMCMD_DIR}/steamcmd.sh" +quit >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Step 5 - game server install, with the "Missing configuration" fallback
# ---------------------------------------------------------------------------
# CLAUDE.md known issue: anonymous Linux installs of app 222860 can fail with
# "Missing configuration". Workaround: run once forcing the windows platform
# type (which populates the app config), then run again forcing linux with
# validate. Both paths are attempted automatically below.
steamcmd_install() {
    local platform="${1:-}"
    local -a args=()
    if [[ -n "${platform}" ]]; then
        args+=("+@sSteamCmdForcePlatformType" "${platform}")
    fi
    args+=(+force_install_dir "${SRV_DIR}" +login anonymous
           +app_update "${APPID}" validate +quit)
    as_steam "${STEAMCMD_DIR}/steamcmd.sh" "${args[@]}"
}

step_server() {
    log "Step 5: install/update the L4D2 dedicated server (app ${APPID})"
    if steamcmd_install ""; then
        info "PATH TAKEN: normal anonymous linux install succeeded"
    else
        warn "normal install failed (likely the 'Missing configuration' bug) - using the windows/linux fallback"
        log "Step 5 fallback A: forcing platform type 'windows'"
        steamcmd_install "windows" \
            || warn "windows-platform pass also reported an error; continuing to the linux pass"
        log "Step 5 fallback B: forcing platform type 'linux' with validate"
        steamcmd_install "linux" \
            || die "server install failed on all attempts - check the SteamCMD output above"
        info "PATH TAKEN: windows-then-linux fallback"
    fi

    [[ -x "${SRV_DIR}/srcds_run" ]] || die "srcds_run missing in ${SRV_DIR} after install"
    install -d -o "${STEAM_USER}" -g "${STEAM_USER}" -m 755 "${GAME_DIR}" "${GAME_DIR}/cfg"
}

# ---------------------------------------------------------------------------
# Step 6 - Metamod:Source + SourceMod
# ---------------------------------------------------------------------------
step_mm_sm() {
    log "Step 6: Metamod:Source ${MM_VER} + SourceMod ${SM_VER}"
    cached_download "${MM_URL}" "${CACHE_DIR}/${MM_TARBALL}"
    cached_download "${SM_URL}" "${CACHE_DIR}/${SM_TARBALL}"

    # Both tarballs contain an addons/ tree rooted at the game dir.
    tar -xzf "${CACHE_DIR}/${MM_TARBALL}" -C "${GAME_DIR}"
    info "extracted Metamod into ${GAME_DIR}"
    tar -xzf "${CACHE_DIR}/${SM_TARBALL}" -C "${GAME_DIR}"
    info "extracted SourceMod into ${GAME_DIR}"

    # Some Metamod builds ship addons/metamod.vdf, some do not. Without it srcds
    # never loads Metamod, and therefore never loads SourceMod.
    if [[ ! -f "${GAME_DIR}/addons/metamod.vdf" ]]; then
        printf '"Plugin"\n{\n\t"file"\t"addons/metamod/bin/server"\n}\n' \
            > "${GAME_DIR}/addons/metamod.vdf"
        info "wrote addons/metamod.vdf (it was not in the tarball)"
    fi

    chown -R "${STEAM_USER}:${STEAM_USER}" "${GAME_DIR}/addons"
}

# ---------------------------------------------------------------------------
# Step 7 - Left 4 DHooks Direct 1.168
# ---------------------------------------------------------------------------
# Plugin + gamedata + data cfg only. Verified: the repo has no extensions/
# directory, so there is no separate .so extension to install.
step_left4dhooks() {
    log "Step 7: Left 4 DHooks Direct ${L4DH_VER}"
    fetch_file "${L4DH_RAW}/sourcemod/plugins/left4dhooks.smx"       "${SM_DIR}/plugins/left4dhooks.smx"
    fetch_file "${L4DH_RAW}/sourcemod/gamedata/left4dhooks.l4d2.txt" "${SM_DIR}/gamedata/left4dhooks.l4d2.txt"
    fetch_file "${L4DH_RAW}/sourcemod/gamedata/lux_library.txt"      "${SM_DIR}/gamedata/lux_library.txt"
    fetch_file "${L4DH_RAW}/sourcemod/data/left4dhooks.l4d2.cfg"     "${SM_DIR}/data/left4dhooks.l4d2.cfg"
}

# ---------------------------------------------------------------------------
# Step 8 - l4dinfectedbots
# ---------------------------------------------------------------------------
step_infectedbots() {
    log "Step 8: l4dinfectedbots (plugin, gamedata, translations, data configs)"
    fetch_file "${IB_RAW}/plugins/l4dinfectedbots.smx"  "${SM_DIR}/plugins/l4dinfectedbots.smx"
    fetch_file "${IB_RAW}/gamedata/l4dinfectedbots.txt" "${SM_DIR}/gamedata/l4dinfectedbots.txt"
    fetch_file "${IB_RAW}/translations/l4dinfectedbots.phrases.txt" \
               "${SM_DIR}/translations/l4dinfectedbots.phrases.txt"
    # The plugin reads data/l4dinfectedbots/<gamemode>.cfg; fetch all four so no
    # gamemode is left without its data file.
    local mode
    for mode in coop versus realism survival; do
        fetch_file "${IB_RAW}/data/l4dinfectedbots/${mode}.cfg" \
                   "${SM_DIR}/data/l4dinfectedbots/${mode}.cfg"
    done
}

# ---------------------------------------------------------------------------
# CLAUDE.md Step 2 - merge coop_versus_* keys into the coop data config
# ---------------------------------------------------------------------------
# The old l4d_infectedbots_coop_versus* CVARS NO LONGER EXIST. The current
# plugin reads these settings from the KeyValues data config
# addons/sourcemod/data/l4dinfectedbots/coop.cfg, e.g.
# hData.GetNum("coop_versus_enable", ...).
#
# Merge strategy, deliberately conservative: rewrite the VALUE of a key only
# when that key already exists in the file, so upstream bot spawn counts,
# limits, weights and healths are never touched. Any key we cannot find is
# reported as a loud WARNING for manual entry from
# configs/l4dinfectedbots_coop.cfg. Idempotent: re-running writes the same
# values again.
kv_set_existing() {
    local file="$1" key="$2" value="$3"

    # Exact key match: the key name is matched with both quotes, so
    # "coop_versus_enable" cannot match a longer key sharing that prefix.
    if ! grep -qE "^[[:space:]]*\"${key}\"" "${file}"; then
        return 1
    fi

    awk -v key="${key}" -v val="${value}" '
        {
            if ($0 ~ "^[[:space:]]*\"" key "\"") {
                match($0, /^[[:space:]]*/)                 # keep the original indent
                printf "%s\"%s\"\t\t\"%s\"\n", substr($0, 1, RLENGTH), key, val
                next
            }
            print
        }
    ' "${file}" > "${file}.new"

    if [[ -s "${file}.new" ]]; then
        mv "${file}.new" "${file}"
        chown "${STEAM_USER}:${STEAM_USER}" "${file}"
        return 0
    fi
    rm -f "${file}.new"
    return 1
}

# ---------------------------------------------------------------------------
# Companion plugins recommended by the l4dinfectedbots readme
# ---------------------------------------------------------------------------
# These are not in CLAUDE.md's stack table; they are installed because upstream
# lists them as required or as fixes for problems that bite specifically when a
# human plays infected in coop. Each is independent - none is needed for
# l4d2_invasion itself to load.
step_companions() {
    log "Companion plugins (Source Scramble, MoYu fixes, fbef0102 fixes)"

    # --- Source Scramble extension (dependency of panic_battlefield) ---------
    info "Source Scramble ${SCRAMBLE_VER} (extension)"
    cached_download "${SCRAMBLE_URL}" "${CACHE_DIR}/${SCRAMBLE_TARBALL}"
    # The tarball is already laid out as addons/sourcemod/{extensions,plugins,scripting}.
    tar -xzf "${CACHE_DIR}/${SCRAMBLE_TARBALL}" -C "${GAME_DIR}" \
        || die "could not extract ${SCRAMBLE_TARBALL}"
    [[ -s "${SM_DIR}/extensions/sourcescramble.ext.so" ]] \
        || die "sourcescramble.ext.so missing after extract"
    info "installed extensions/sourcescramble.ext.so + plugins/sourcescramble_manager.smx"

    # --- MoYu plugins, lifted out of the pinned 1.12 release zip ------------
    info "MoYu plugins from ${MOYU_ZIP} (release ${MOYU_TAG})"
    command -v unzip >/dev/null 2>&1 || die "unzip is required but not installed."
    cached_download "${MOYU_URL}" "${CACHE_DIR}/${MOYU_ZIP}"

    local p zipdir
    for p in "${MOYU_PLUGINS[@]}"; do
        # "The Last Stand" contains a space, so the pattern must stay quoted.
        zipdir="MoYu-Plugins-1.12/The Last Stand/${p}"

        # -j junks the zip's directory structure so files land flat in -d.
        if ! unzip -j -o -q "${CACHE_DIR}/${MOYU_ZIP}" "${zipdir}/plugins/${p}.smx" \
                -d "${SM_DIR}/plugins"; then
            warn "${p}: .smx not found in ${MOYU_ZIP} - install it by hand"
            continue
        fi
        # Not every MoYu plugin ships gamedata; a miss here is not an error.
        unzip -j -o -q "${CACHE_DIR}/${MOYU_ZIP}" "${zipdir}/gamedata/${p}.txt" \
            -d "${SM_DIR}/gamedata" 2>/dev/null \
            || info "${p}: no gamedata in the zip (expected for some)"

        chown "${STEAM_USER}:${STEAM_USER}" "${SM_DIR}/plugins/${p}.smx"
        [[ -f "${SM_DIR}/gamedata/${p}.txt" ]] \
            && chown "${STEAM_USER}:${STEAM_USER}" "${SM_DIR}/gamedata/${p}.txt"
        info "installed ${p}"
    done

    # --- fbef0102 plugins, prebuilt .smx straight from the repo --------------
    for p in l4d_ghost_spawn_exploit spawn_infected_nolimit; do
        fetch_file "${FB_RAW}/${p}/plugins/${p}.smx"  "${SM_DIR}/plugins/${p}.smx"
        fetch_file "${FB_RAW}/${p}/gamedata/${p}.txt" "${SM_DIR}/gamedata/${p}.txt"
    done

    # --- zombie_spawn_fix: shipped in this repo, not downloadable -------------
    # It is published only as an AlliedModders forum attachment (thread 333351),
    # and that site sits behind a Cloudflare challenge, so a scripted download
    # gets an HTML challenge page instead of the plugin. The .sp and its gamedata
    # are therefore committed under third_party/, build.sh compiles the .smx into
    # plugins/, and both are installed from the checkout here. Its Source Scramble
    # dependency is installed above.
    local zsf_smx="${REPO_ROOT}/plugins/zombie_spawn_fix.smx"
    local zsf_gd="${REPO_ROOT}/third_party/zombie_spawn_fix/gamedata/zombie_spawn_fix.txt"

    if [[ -s "${zsf_smx}" && -s "${zsf_gd}" ]]; then
        install -D -o "${STEAM_USER}" -g "${STEAM_USER}" -m 644 \
            "${zsf_smx}" "${SM_DIR}/plugins/zombie_spawn_fix.smx"
        install -D -o "${STEAM_USER}" -g "${STEAM_USER}" -m 644 \
            "${zsf_gd}" "${SM_DIR}/gamedata/zombie_spawn_fix.txt"
        info "installed zombie_spawn_fix (plugin + gamedata) from the checkout"
        info "  it memory-patches the game: check errors_*.log for \"Failed to verify patch\""
    elif [[ -s "${SM_DIR}/plugins/zombie_spawn_fix.smx" ]]; then
        info "zombie_spawn_fix already on the server, leaving it alone"
    else
        warn "zombie_spawn_fix NOT installed. Expected both of:
      ${zsf_smx}
      ${zsf_gd}
    The .smx is produced by ./build.sh from the .sp under third_party/. Run
    build.sh first, or copy both files onto the server by hand:
      ${SM_DIR}/plugins/  and  ${SM_DIR}/gamedata/
    Source Scramble (its dependency) is already installed."
    fi
}

step_coop_config() {
    log "CLAUDE.md Step 2: merging coop_versus_* keys into data/l4dinfectedbots/coop.cfg"
    local cfg="${SM_DIR}/data/l4dinfectedbots/coop.cfg"
    [[ -f "${cfg}" ]] || die "missing ${cfg} - did step 8 run?"

    # One-time pristine backup so the operator can always diff or restore.
    if [[ ! -f "${cfg}.upstream" ]]; then
        install -o "${STEAM_USER}" -g "${STEAM_USER}" -m 644 "${cfg}" "${cfg}.upstream"
        info "backed the upstream file up to coop.cfg.upstream"
    else
        info "coop.cfg.upstream backup already exists (kept)"
    fi

    # key=value pairs to apply. configs/l4dinfectedbots_coop.cfg documents why.
    local -a kvs=(
        "coop_versus_enable=1"            # humans may join infected in coop
        "coop_versus_join_access="        # empty = everyone (upstream default "z" = root admin only)
        "coop_versus_human_limit=2"       # two simultaneous human infected slots
        "coop_versus_tank_playable=0"     # Tank off here; coop_finale.cfg turns it on
        "coop_versus_spawn_time_min=10.0" # match l4d2_invasion_respawn (upstream clamps to a 3.0s floor)
        "coop_versus_spawn_time_max=10.0"
        "coop_versus_announce=1"          # upstream default
        "coop_versus_human_light=1"       # upstream default
        "coop_versus_human_ghost=1"       # upstream default: ghost first, then spawn
        "coop_versus_cool_down=60.0"      # l4dinfectedbots' own rejoin cooldown (ours is separate)
    )

    local pair key value
    local -a not_found=()
    for pair in "${kvs[@]}"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        if kv_set_existing "${cfg}" "${key}" "${value}"; then
            info "set ${key} = \"${value}\""
        else
            not_found+=("${key} = \"${value}\"")
        fi
    done

    if ((${#not_found[@]})); then
        printf '\n\033[1;33m'
        printf '!!  WARNING: the following keys were NOT found in\n'
        printf '!!      %s\n' "${cfg}"
        printf '!!  and were therefore NOT set. Add each one BY HAND inside the same\n'
        printf '!!  block as the other coop_versus_* keys, then restart the server:\n'
        local nf
        for nf in "${not_found[@]}"; do printf '!!      "%s"\n' "${nf}"; done
        printf '!!  Reference: %s/configs/l4dinfectedbots_coop.cfg\n' "${REPO_ROOT}"
        printf '\033[0m\n'
        WARNINGS+=("coop.cfg: ${#not_found[@]} key(s) not found and not set: ${not_found[*]}")
    else
        info "all coop_versus_* keys applied"
    fi

    step_coop_finale_config "${cfg}"
}

# ---------------------------------------------------------------------------
# coop_finale.cfg - the "Tanks are playable" variant of coop.cfg
# ---------------------------------------------------------------------------
# l4d2_invasion grants Tank access only during the finale. coop_versus_tank_playable
# is a KeyValues key with no cvar behind it, so it cannot be flipped live - but
# l4d_infectedbots_read_data has a change hook that reloads the whole data config.
# The plugin therefore switches between two files that differ in exactly that one
# key. This generates the second one from the first, so they cannot drift.
step_coop_finale_config() {
    local src="$1"
    local dst="${SM_DIR}/data/l4dinfectedbots/coop_finale.cfg"

    log "Generating coop_finale.cfg (Tank-playable variant of coop.cfg)"

    if ! grep -qE '^[[:space:]]*"coop_versus_tank_playable"' "${src}"; then
        warn "coop_versus_tank_playable not found in $(basename "${src}"), so
    coop_finale.cfg cannot be generated. Finale Tank access will not work until
    that key exists and this script is re-run."
        return 0
    fi

    sed 's|^\([[:space:]]*\)"coop_versus_tank_playable"\([[:space:]]*\)"0"|\1"coop_versus_tank_playable"\2"1"|' \
        "${src}" > "${dst}.tmp"

    # The two files must differ in nothing but that key, or switching configs
    # mid-finale would quietly change spawn times, limits or access as well.
    if diff <(grep -v 'coop_versus_tank_playable' "${src}") \
            <(grep -v 'coop_versus_tank_playable' "${dst}.tmp") >/dev/null; then
        install -o "${STEAM_USER}" -g "${STEAM_USER}" -m 644 "${dst}.tmp" "${dst}"
        rm -f "${dst}.tmp"
        info "wrote $(basename "${dst}") ($(grep -c '"coop_versus_tank_playable"[[:space:]]*"1"' "${dst}") blocks with Tank enabled)"
    else
        rm -f "${dst}.tmp"
        die "generated coop_finale.cfg differs from coop.cfg by more than coop_versus_tank_playable - refusing to install it"
    fi
}

# ---------------------------------------------------------------------------
# Repo configs - server.cfg, cfg/sourcemod/*.cfg, compiled plugins
# ---------------------------------------------------------------------------
step_repo_configs() {
    log "Installing configs from the repo checkout (${REPO_ROOT})"

    if [[ -f "${REPO_ROOT}/cfg/server.cfg" ]]; then
        install -o "${STEAM_USER}" -g "${STEAM_USER}" -m 644 \
            "${REPO_ROOT}/cfg/server.cfg" "${GAME_DIR}/cfg/server.cfg"
        info "installed cfg/server.cfg"
    else
        warn "cfg/server.cfg not found in the checkout - server.cfg not installed"
    fi

    if compgen -G "${REPO_ROOT}/cfg/sourcemod/*.cfg" >/dev/null; then
        install -d -o "${STEAM_USER}" -g "${STEAM_USER}" -m 755 "${GAME_DIR}/cfg/sourcemod"
        local f
        for f in "${REPO_ROOT}"/cfg/sourcemod/*.cfg; do
            install -o "${STEAM_USER}" -g "${STEAM_USER}" -m 644 "${f}" "${GAME_DIR}/cfg/sourcemod/"
            info "installed cfg/sourcemod/$(basename "${f}")"
        done
    else
        warn "no cfg/sourcemod/*.cfg in the checkout - plugin cvar configs not installed"
    fi

    if compgen -G "${REPO_ROOT}/plugins/*.smx" >/dev/null; then
        local p
        for p in "${REPO_ROOT}"/plugins/*.smx; do
            install -o "${STEAM_USER}" -g "${STEAM_USER}" -m 644 "${p}" "${SM_DIR}/plugins/"
            info "installed plugins/$(basename "${p}")"
        done
    else
        warn "no plugins/*.smx in the checkout - run ./build.sh, then deploy/deploy_plugin.sh"
    fi
}

step_databases_cfg() {
    log "databases.cfg - l4d2_invasion SQLite entry"
    local db="${SM_DIR}/configs/databases.cfg"
    local snippet="${REPO_ROOT}/configs/databases.cfg.snippet"

    if [[ ! -f "${db}" ]]; then
        warn "${db} missing - skipping the DB entry"
        return 0
    fi
    if [[ ! -f "${snippet}" ]]; then
        warn "${snippet} missing - skipping the DB entry"
        return 0
    fi

    if grep -q '"l4d2_invasion"' "${db}"; then
        info "entry already present, nothing to do"
        return 0
    fi

    [[ -f "${db}.bak" ]] || cp "${db}" "${db}.bak"

    # Insert the block before the LAST closing brace, i.e. the end of the
    # "Databases" section. Comment and blank lines from the snippet are skipped.
    awk -v snip="${snippet}" '
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
    ' "${db}" > "${db}.new"

    if grep -q '"l4d2_invasion"' "${db}.new"; then
        mv "${db}.new" "${db}"
        chown "${STEAM_USER}:${STEAM_USER}" "${db}"
        info "appended the l4d2_invasion block (original saved as databases.cfg.bak)"
    else
        rm -f "${db}.new"
        warn "could not insert the l4d2_invasion block - merge ${snippet} into ${db} by hand"
    fi
}

# ---------------------------------------------------------------------------
# Step 9 - systemd unit
# ---------------------------------------------------------------------------
step_systemd() {
    log "Step 9: systemd unit ${UNIT_FILE}"
    cat > "${UNIT_FILE}" <<UNIT
[Unit]
Description=Left 4 Dead 2 Dedicated Server (Invasion Mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${STEAM_USER}
Group=${STEAM_USER}
WorkingDirectory=${SRV_DIR}
ExecStart=${SRV_DIR}/srcds_run -game left4dead2 -console -port ${PORT} +map c1m1_hotel +maxplayers 8 -tickrate 30
Restart=on-failure
RestartSec=10
KillSignal=SIGINT
# srcds keeps a lot of map/vpk files open
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable l4d2.service >/dev/null
    info "unit written and enabled (NOT started - start it yourself, see the summary)"
}

# ---------------------------------------------------------------------------
# Step 10 - firewall (never fatal)
# ---------------------------------------------------------------------------
step_firewall() {
    log "Step 10: open UDP+TCP ${PORT}"
    set +e
    if command -v ufw >/dev/null 2>&1; then
        if ufw allow "${PORT}/udp" >/dev/null 2>&1; then
            info "ufw: allowed ${PORT}/udp"
        else
            warn "ufw could not allow ${PORT}/udp"
        fi
        if ufw allow "${PORT}/tcp" >/dev/null 2>&1; then
            info "ufw: allowed ${PORT}/tcp"
        else
            warn "ufw could not allow ${PORT}/tcp"
        fi
        info "note: clients also use UDP 27005, and SourceTV (if enabled) UDP 27020"
    else
        info "ufw is not installed - not touching nftables/iptables rules automatically."
        info "If this container or its Proxmox host filters traffic, run there:"
        info "    iptables -A INPUT -p udp --dport ${PORT} -j ACCEPT"
        info "    iptables -A INPUT -p tcp --dport ${PORT} -j ACCEPT"
        info "  nftables equivalent:"
        info "    nft add rule inet filter input udp dport ${PORT} accept"
        info "    nft add rule inet filter input tcp dport ${PORT} accept"
        info "A default Debian LXC with no firewall needs no action here."
    fi
    set -e
    return 0
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
summary() {
    log "Done"
    cat <<SUMMARY
Installed:
  L4D2 dedicated server (app ${APPID})  ${SRV_DIR}
  Metamod:Source ${MM_VER}        ${GAME_DIR}/addons/metamod
  SourceMod ${SM_VER}             ${SM_DIR}
  Left 4 DHooks Direct ${L4DH_VER}           plugins/left4dhooks.smx + gamedata + data cfg
  l4dinfectedbots (master)              plugins/l4dinfectedbots.smx + gamedata + translations + data configs
  Source Scramble ${SCRAMBLE_VER}             extensions/sourcescramble.ext.so + sourcescramble_manager.smx
  MoYu fixes (release ${MOYU_TAG})   l4d_unrestrict_panic_battlefield, l4d_fix_deathfall_cam,
                                        l4d2_scripted_tank_stage_fix
  fbef0102 fixes (master)               l4d_ghost_spawn_exploit, spawn_infected_nolimit
  Repo configs                          cfg/server.cfg, cfg/sourcemod/*.cfg
  Coop human-infected settings          ${SM_DIR}/data/l4dinfectedbots/coop.cfg (backup: coop.cfg.upstream)
  systemd unit                          ${UNIT_FILE} (enabled, not started)
  Deploy access                         ${STEAM_HOME}/.ssh/authorized_keys + /etc/sudoers.d/steam-l4d2

Next commands:
  1. Set a real rcon password:
       nano ${GAME_DIR}/cfg/server.cfg          # replace CHANGEME_rcon_password
  2. Build and deploy the plugin from your workstation checkout:
       ./build.sh && L4D2_HOST=${STEAM_USER}@<this-host> deploy/deploy_plugin.sh
     (or copy plugins/l4d2_invasion.smx into ${SM_DIR}/plugins/ by hand)
  3. Start the server and watch it come up:
       systemctl start l4d2
       journalctl -u l4d2 -f
  4. Verify the plugins loaded (server console or rcon):
       sm plugins list
  5. Check for load errors:
       tail -n 50 ${SM_DIR}/logs/errors_*.log
SUMMARY

    if ((${#WARNINGS[@]})); then
        printf '\n\033[1;33mWarnings raised during setup (%d):\033[0m\n' "${#WARNINGS[@]}"
        local w
        for w in "${WARNINGS[@]}"; do printf '  - %s\n' "${w}"; done
    else
        printf '\nNo warnings.\n'
    fi
}

main() {
    step_packages
    step_user
    step_steamcmd
    step_server
    step_mm_sm
    step_left4dhooks
    step_infectedbots
    step_companions
    step_coop_config
    step_repo_configs
    step_databases_cfg
    step_systemd
    step_deploy_access
    step_firewall
    chown -R "${STEAM_USER}:${STEAM_USER}" "${SRV_DIR}"
    summary
}

main "$@"
