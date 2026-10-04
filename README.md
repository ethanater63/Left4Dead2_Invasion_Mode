# L4D2 Invasion Mode

A SourceMod plugin for Left 4 Dead 2 **coop** that lets one human player join the infected team as an "invader" on a fixed budget: **10 lives or 6 minutes of active play, whichever comes first**. When the budget runs out the invader is removed (kicked by default, or moved to spectator). Invader stats — kills, incaps, damage, deaths — are written to SQLite for a leaderboard.

Survivors control whether invasions are possible at all: enough of them must opt in with `!invadable` before the infected team accepts a human.

---

## Pinned versions

Verified as of 2026-09-28. Use exactly these; the plugin is built against them.

| Component | Version | Source |
|---|---|---|
| L4D2 Dedicated Server | SteamCMD app `222860` | `steamcmd +app_update 222860 validate` |
| Metamod:Source | 1.12.0 build 1227 (stable) | `https://mms.alliedmods.net/mmsdrop/1.12/mmsource-1.12.0-git1227-linux.tar.gz` |
| SourceMod | 1.12.0 build 7253 (stable) | `https://sm.alliedmods.net/smdrop/1.12/sourcemod-1.12.0-git7253-linux.tar.gz` |
| Left 4 DHooks Direct | `master` — **1.168 when pinned, 1.169 as installed** (see note) | `https://github.com/SilvDev/Left4DHooks` (branch `master`) |
| l4dinfectedbots | `master` @ 2026-09-28 (no tagged releases; ships a prebuilt `.smx`) | `https://github.com/fbef0102/L4D1_2-Plugins/tree/master/l4dinfectedbots` |
| Source Scramble (extension) | 0.8.2.2 — use `package.tar.gz`, **not** `-api10` | `https://github.com/nosoop/SMExt-SourceScramble/releases` |
| MoYu companion fixes | release tag `20260925134758`, asset `MoYu-Plugins-1.12.zip` | `https://github.com/Target5150/MoYu_Server_Stupid_Plugins/releases` |
| fbef0102 companion fixes | `master` @ 2026-09-28 (prebuilt `.smx`) | `l4d_ghost_spawn_exploit`, `spawn_infected_nolimit` |
| `zombie_spawn_fix` | v1.0.9 — vendored in `third_party/`, no mirror exists | [AlliedModders thread 333351](https://forums.alliedmods.net/showthread.php?t=333351) |

See [Known issues (b)](#b-companion-plugins--all-six-installed-zombie_spawn_fix-is-vendored) for what each companion fixes and why `zombie_spawn_fix` is vendored rather than downloaded.

Two notes that affect install:

- **Left 4 DHooks Direct 1.168 needs no separate extension.** It is plugin + gamedata + data config only (`left4dhooks.smx`, `gamedata/left4dhooks.txt`, and its `data/left4dhooks.*.cfg` files). Older install instructions referencing a `left4dhooks.ext.so` do not apply to this version.
- **Left4DHooks is not truly pinned.** Upstream publishes no tagged releases, so `setup_lxc.sh` fetches the prebuilt `.smx` from `master`. It was 1.168 when this repo was written; the live server reports **1.169**, because master moved. The includes in `scripting/include/` are still the 1.168 copies. That mismatch is benign — the natives we use (`L4D_GetPlayerSpawnTime`, `L4D_SetPlayerSpawnTime`) are unchanged — but if a future master bumps further and the plugin misbehaves, re-copy the includes from the same commit the server is running.
- **l4dinfectedbots is distributed as a prebuilt `.smx`.** We do not compile it, so its own compile-time dependencies (Multi Colors include, etc.) are not needed anywhere in this repo or on the server.

---

## Install

### 1. Server (Debian 12 LXC on Proxmox)

Run `deploy/setup_lxc.sh` inside the LXC. It is idempotent — safe to re-run. It:

- adds the i386 architecture and installs the 32-bit runtime deps plus `curl`, `tar`, `screen`, `sqlite3`, `ca-certificates`
- creates the `steam` user with home `/home/steam`
- installs SteamCMD to `/home/steam/steamcmd` and the game server to `/home/steam/l4d2`
- extracts Metamod:Source and SourceMod into `/home/steam/l4d2/left4dead2/`
- installs Left 4 DHooks Direct and l4dinfectedbots (plugins, gamedata, data configs)
- installs the Source Scramble extension and all six companion plugins, including `zombie_spawn_fix` from `third_party/` — see [Known issues (b)](#b-companion-plugins--all-six-installed-zombie_spawn_fix-is-vendored)
- writes and enables the `l4d2.service` systemd unit:
  `./srcds_run -game left4dead2 -console -port 27015 +map c1m1_hotel +maxplayers 8 -tickrate 30`, running as `steam`, with `Restart=on-failure`
- opens UDP/TCP 27015

**SteamCMD "Missing configuration" fallback is automatic.** Anonymous Linux installs of app `222860` sometimes fail with `Missing configuration`. The setup script detects this and retries: once with `+@sSteamCmdForcePlatformType windows`, then again with `+@sSteamCmdForcePlatformType linux ... validate`. No manual intervention needed.

### 2. Build the plugin on the dev box

```bash
./build.sh
```

See [Build](#build) below.

### 3. Deploy

```bash
L4D2_HOST=steam@l4d2.local deploy/deploy_plugin.sh
```

`L4D2_HOST` defaults to `steam@l4d2.local`; if that name doesn't resolve, point it at an SSH alias or `steam@<ip>`. The script copies `plugins/*.smx` (with rsync, or with scp when rsync is missing, e.g. in Git Bash on Windows) into `addons/sourcemod/plugins/`, puts the cfg files in place, restarts `l4d2.service`, and tails the last 50 lines of the SourceMod error log so a load failure is visible immediately.

### 4. Database registration

The plugin needs a `databases.cfg` entry. `deploy/deploy_plugin.sh` appends it if it is missing (it greps first, so re-running is safe). The entry, also kept in `configs/databases.cfg.snippet`:

```
"l4d2_invasion"
{
    "driver"    "sqlite"
    "database"  "l4d2_invasion"
}
```

goes inside the `Databases { ... }` block of `addons/sourcemod/configs/databases.cfg`. The DB file itself is created on first connect at `addons/sourcemod/data/sqlite/l4d2_invasion.sq3`; the `players` and `invasions` tables are created with `CREATE TABLE IF NOT EXISTS` on load. If the DB is unavailable the plugin logs an error and keeps running — gameplay never blocks on SQL.

### 5. l4dinfectedbots data config

Human infected in coop is enabled in l4dinfectedbots' **data config**, not by cvars. See [l4dinfectedbots configuration](#l4dinfectedbots-configuration) — this step is required, and the keys must be merged into the upstream file rather than overwriting it.

---

## Build

```bash
spcomp scripting/l4d2_invasion.sp -i scripting/include -o plugins/l4d2_invasion.smx
```

`build.sh` wraps exactly that, and also compiles the one vendored companion:

```bash
spcomp third_party/zombie_spawn_fix/scripting/zombie_spawn_fix.sp \
       -i scripting/include -o plugins/zombie_spawn_fix.smx
```

Requirements:

- Use `spcomp` from the **same SourceMod version as the server** — 1.12.0-git7253. A compiler from a different branch can produce a plugin the server refuses to load.
- The build must be warning-free. Warnings are treated as failures, for both targets.
- `zombie_spawn_fix` is skipped without failing the build if `third_party/` is not checked out.

`scripting/include/` holds:

| File | Role | From |
|---|---|---|
| `left4dhooks.inc` | main include | Left 4 DHooks Direct 1.168 |
| `left4dhooks_anim.inc` | dependency | Left 4 DHooks Direct 1.168 |
| `left4dhooks_silver.inc` | dependency | Left 4 DHooks Direct 1.168 |
| `left4dhooks_lux_library.inc` | dependency | Left 4 DHooks Direct 1.168 |
| `left4dhooks_stocks.inc` | dependency | Left 4 DHooks Direct 1.168 |
| `sourcescramble.inc` | needed only by `zombie_spawn_fix` | Source Scramble 0.8.2.2 |

`sourcemod.inc` and `sdktools.inc` come from the SourceMod compiler's own include path, not from this repo.

**`spcomp` output is not byte-reproducible.** Consecutive builds of identical source can differ by a byte or two, so the committed `.smx` files under `plugins/` will intermittently show as modified after a rebuild with no source change behind it. `git checkout -- plugins/` discards that noise.

---

## Our cvars

Created with `CreateConVar` and written to `cfg/sourcemod/l4d2_invasion.cfg` by `AutoExecConfig`. That file is committed with the defaults below.

| Cvar | Default | Meaning |
|---|---|---|
| `l4d2_invasion_enable` | `1` | Master switch |
| `l4d2_invasion_lives` | `10` | Deaths allowed per invasion |
| `l4d2_invasion_time` | `360` | Invasion length in seconds (active time only, see timer rules). `0` = no time limit; lives are the only budget |
| `l4d2_invasion_respawn` | `10.0` | Invader respawn time in seconds |
| `l4d2_invasion_end_action` | `1` | 0 = move to spectator, 1 = kick |
| `l4d2_invasion_cooldown` | `600` | Seconds before the same SteamID can invade again |
| `l4d2_invasion_optin_ratio` | `0.5` | Fraction of human survivors who must have `!invadable` on |
| `l4d2_invasion_max_invaders` | `1` | Max simultaneous human invaders |
| `l4d2_invasion_tank_finale` | `1` | `1` = invaders may become the Tank during the finale only, `0` = never |
| `l4d2_invasion_menu` | `1` | `1` = offer the side-select menu on each player's first spawn of the round |

**All 10 apply live.** Each has an `OnConVarChanged` hook, so `sm_cvar l4d2_invasion_lives 3` takes effect on the running invasion (on its next death, for the lives check) with no reload. Editing `cfg/sourcemod/l4d2_invasion.cfg` only matters at load time.

**Leaving the infected team ends the invasion.** If an invader switches to survivor or spectator mid-invasion, the invasion ends with the reason `Left the infected team`: stats are saved, the cooldown starts and the slot frees up. The player stays on the team they picked. A map transition does not count as leaving, so sessions still carry over between maps.

Caveat: `l4d2_invasion_respawn` does not actually control the coop respawn delay — see [Known issues (a)](#a-l4d_setplayerspawntime-does-not-control-the-coop-respawn-delay).

---

## Commands

| Command | Access | Effect |
|---|---|---|
| `!invade` / `sm_invade` | anyone | Reopen the side-select menu (survivor / invader) |
| `!invadable` / `sm_invadable` | survivors only | Toggle your opt-in; prints the opted-in count to everyone |
| `!invstats` / `sm_invstats` | anyone | Your lifetime totals |
| `!invtop` / `sm_invtop` | anyone | Top 10 invaders by kills |
| `!inv_status` / `sm_inv_status` | anyone | Current invader(s), lives and time left |
| `sm_inv_end <target>` | admin, `ADMFLAG_KICK` | Force-end an invasion |
| `sm_inv_debug` | admin, `ADMFLAG_CONFIG` | Toggle verbose `LogMessage` output |

---

## How it works

**Opt-in gate.** `InvasionsAllowed()` returns true only when all three hold: `l4d2_invasion_enable` is `1`; at least one human survivor is in the game; and `opted-in human survivors / human survivors >= l4d2_invasion_optin_ratio`. `!invadable` is survivors-only and toggles that player's opt-in, printing the new count out of the total to everyone.

**Join gate.** `player_team` is hooked; bots and `disconnect` events are ignored. On a join to the infected team the plugin schedules a 0.1s timer (carrying the userid, not the client index) and runs the checks in that callback, so it lands after l4dinfectedbots' own join handling. The checks, in order: invasions closed → move to spectator with `Invasions are closed. Survivors must opt in with !invadable.`; SteamID still in cooldown → spectator with `You can invade again in M:SS.`; invader slots full → spectator with `Invader slot full.` Otherwise a session is created (or an existing one for that SteamID resumed), everyone gets `[INVASION] <name> has invaded the campaign!`, and the invader gets a rules hint.

**Budget is lives AND time.** Whichever runs out first ends the invasion. Every death counts against lives — suicide, fall damage and world damage included. Elapsed time advances only while the round is active *and* the invader is in-game on the infected team; it counts through ghost state, alive and waiting-to-respawn alike. It pauses on `round_end`, on `map_transition`, and during map load, resuming at `round_start`. A 1s repeating timer does the counting and refreshes the `Lives: X/10 | Time left: M:SS` hint.

**Sessions survive map transitions.** Sessions live in a `StringMap` keyed by SteamID2, not by client index, so a campaign-level change carries the same lives used and time elapsed onto the next map.

**Leaving cannot reset the budget.** `OnClientDisconnect` for a client with an active session runs the same path as `EndInvasion` minus the kick: stats are written, the cooldown is set for that SteamID, the session is removed. Reconnecting therefore hits the cooldown rather than starting a fresh 10 lives.

**Survivors revoking opt-in mid-invasion does not end it.** The ratio gates *new* invasions only.

---

## l4dinfectedbots configuration

**Read this section before deploying.** CLAUDE.md Step 2 asked for a verified cvar table, and the cvar names it listed **no longer exist**. Verified against the current upstream readme *and* source on 2026-09-28: current l4dinfectedbots **removed** the `l4d_infectedbots_coop_versus*` and `l4d_infectedbots_admin_coop_versus` cvars and moved those settings into its per-gamemode KeyValues **data config** at `addons/sourcemod/data/l4dinfectedbots/coop.cfg`. The source reads them as KeyValues, e.g. `hData.GetNum("coop_versus_enable", 0)` and `hData.GetString("coop_versus_join_access", ..., "z")` — not as console variables.

| Intended behavior | Name in CLAUDE.md (outdated) | Verified current name | Where it lives | Value we set |
|---|---|---|---|---|
| Human players can join infected in coop | `l4d_infectedbots_coop_versus` | `coop_versus_enable` | `data/l4dinfectedbots/coop.cfg` | `1` |
| Non-admins can join | `l4d_infectedbots_admin_coop_versus` | `coop_versus_join_access` | `data/l4dinfectedbots/coop.cfg` | `""` (empty = everyone; upstream default `"z"` is root-admin-only, `"-1"` = nobody) |
| Human infected slots = 1 | `l4d_infectedbots_coop_versus_human_limit` | `coop_versus_human_limit` | `data/l4dinfectedbots/coop.cfg` | `1` |
| Humans can't play Tank | `l4d_infectedbots_coop_versus_tank_playable` | `coop_versus_tank_playable` | `data/l4dinfectedbots/coop.cfg` | `0` |
| Invader respawn delay (coop) | not in CLAUDE.md | `coop_versus_spawn_time_min` / `coop_versus_spawn_time_max` | `data/l4dinfectedbots/coop.cfg` | `10.0` / `10.0` |

Additional facts about this file:

- **`coop_versus_cool_down`** (upstream default `60.0`) is l4dinfectedbots' *own* rejoin cooldown for human infected. It is separate from, and much shorter than, our `l4d2_invasion_cooldown` (default `600`). Both apply; ours is the binding one in practice. Leave it at its default unless you specifically want to loosen the upstream gate.
- **Bot spawn counts, healths and weights are left at upstream defaults.** We change nothing about AI infected behavior.
- **Merge, do not overwrite.** `coop.cfg` also holds bot limits, healths and class weights that must be preserved. `configs/l4dinfectedbots_coop.cfg` in this repo is the **merge fragment** — the keys above only. The operator merges those keys into the upstream `coop.cfg`; dropping our file over the upstream one would wipe the bot tuning.
- **The cvars that DO still exist** are only the 13 in `cfg/sourcemod/l4dinfectedbots.cfg`: `l4d_infectedbots_allow`, `l4d_infectedbots_modes`, `l4d_infectedbots_modes_off`, `l4d_infectedbots_modes_tog`, `l4d_infectedbots_announce_chat`, `l4d_infectedbots_announce_server`, `l4d_infectedbots_infhud_enable`, `l4d_infectedbots_infhud_announce`, `l4d_infectedbots_versus_coop`, `l4d_infectedbots_sm_zss_disable_gamemode`, `l4d_infectedbots_calculate_including_dead`, `l4d_infectedbots_dispose_cowards`, `l4d_infectedbots_read_data`. None of them is the coop human-infected switch.

---

## Known issues

### (a) `L4D_SetPlayerSpawnTime` does not control the coop respawn delay

Verified by reading l4dinfectedbots' source. In coop it respawns human infected on **its own SourceMod timer**:

```
SpawnTime = GetRandomFloat(coop_versus_spawn_time_min, coop_versus_spawn_time_max);
CreateTimer(SpawnTime + 0.1, Timer_Spawn_InfectedBot, ...);
```

Its single `L4D_SetPlayerSpawnTime()` call sits in its `ghost_spawn_time` handler behind an `if (L4D_HasPlayerControlledZombies())` guard, which is **false in coop**. So our own `L4D_SetPlayerSpawnTime(client, l4d2_invasion_respawn)` call — made 0.1s after death, per spec — affects the ghost HUD countdown, not the actual coop respawn.

**The real control is `coop_versus_spawn_time_min` / `coop_versus_spawn_time_max` in `data/l4dinfectedbots/coop.cfg`**, which we set to `10.0` / `10.0` to match the `l4d2_invasion_respawn 10.0` default. Consequences:

- If you change `l4d2_invasion_respawn`, change those two data-config keys to match, or the HUD and the real respawn will disagree.
- l4dinfectedbots clamps that value to a **3.0s floor**, so respawn cannot go below 3s regardless of what is configured.
- Enable `sm_inv_debug` to see both the requested and the effective values logged (once per death).
- Per CLAUDE.md, **l4dinfectedbots is not patched.** This is documented, not worked around.

### (b) Companion plugins — all six installed, `zombie_spawn_fix` is vendored

These sit outside CLAUDE.md's stack table but are recommended by the l4dinfectedbots readme, and they fix problems that bite specifically when a human plays infected in coop. `deploy/setup_lxc.sh` installs all six.

| Plugin | What it fixes | Installed by |
|---|---|---|
| `l4d_unrestrict_panic_battlefield` | SI spawn blocking during panic events / finale battlefields | `setup_lxc.sh` (MoYu release zip) |
| `l4d_fix_deathfall_cam` | In coop, the infected player's screen freezes while watching a survivor deathfall or a failed rescue | `setup_lxc.sh` (MoYu release zip) |
| `l4d2_scripted_tank_stage_fix` | Scripted tank stages misbehaving in finales | `setup_lxc.sh` (MoYu release zip) |
| `l4d_ghost_spawn_exploit` | A ghost-spawn/teleport exploit for human infected | `setup_lxc.sh` (prebuilt `.smx` from repo) |
| `spawn_infected_nolimit` | Provides the API l4dinfectedbots uses to spawn SI past director limits | `setup_lxc.sh` (prebuilt `.smx` from repo) |
| `zombie_spawn_fix` | Special infected failing to spawn at all in some situations | `setup_lxc.sh`, from `third_party/` in this repo (see below) |

**Source Scramble is a hard dependency.** `l4d_unrestrict_panic_battlefield` requires the [Source Scramble](https://github.com/nosoop/SMExt-SourceScramble) memory-patching extension, so `setup_lxc.sh` installs it (`0.8.2.2`, `extensions/sourcescramble.ext.so` plus `sourcescramble_manager.smx`). Upstream's release notes are explicit that SourceMod 1.12 stable takes the plain `package.tar.gz`, **not** the `-api10` package (that one is for SM 1.13.0.7451+). Do not swap them.

`l4d2_scripted_tank_stage_fix` requires DHooks, which ships with SourceMod 1.12 — nothing extra to install.

**`zombie_spawn_fix` is vendored in this repo.** It is published only as an attachment on [AlliedModders thread 333351](https://forums.alliedmods.net/showthread.php?t=333351), and that site sits behind a Cloudflare challenge — a scripted download receives an HTML challenge page, not the plugin. There is no GitHub mirror (the author has no public repos). So its source and gamedata are committed here instead:

```
third_party/zombie_spawn_fix/
├── scripting/zombie_spawn_fix.sp      v1.0.9, sorallll & Psyk0tik (Crasher_3637)
└── gamedata/zombie_spawn_fix.txt      memory-patch offsets + signatures
```

`build.sh` compiles it to `plugins/zombie_spawn_fix.smx` (it needs `sourcescramble.inc`, which is in `scripting/include/`), and both `setup_lxc.sh` and `deploy_plugin.sh` install the `.smx` plus the gamedata. Nothing manual is left.

The gamedata is **not optional** — the plugin calls `SetFailState` and refuses to load without it. The four `MemPatches` entries in the gamedata were checked against the four patch names in the source, and all three referenced signatures are defined.

**It patches game memory, so it is the most fragile thing installed.** Its offsets and byte signatures go stale whenever Valve ships a server update. On failure it does *not* crash — it logs `Failed to verify patch: "<name>"` per patch and carries on. After any game update, grep `errors_*.log` for that string; if it appears, either update `third_party/zombie_spawn_fix/gamedata/zombie_spawn_fix.txt` from the forum thread or delete the plugin. Nothing else depends on it.

The MoYu plugins are pinned to release tag `20260925134758` (`MoYu-Plugins-1.12.zip`), because that repo ships no prebuilt `.smx` in its source tree — only in release zips.

### (c) `coop_versus_join_access` defaults to `"z"` (root admin only)

If the invader gets **no infected-team option at all**, check this first. The upstream default restricts joining infected in coop to root admins; we set it to `""` (everyone). A missed merge into `coop.cfg` looks exactly like the plugin being broken.

### (d) Tank is never playable by the invader

`coop_versus_tank_playable 0` means the human invader will never become the Tank; Tanks stay AI. This is intentional per CLAUDE.md.

### (e) A slot / `maxplayers` budget applies

Per upstream, infected limit + survivors + spectators must not exceed **31**, and the default server slot cap is **18** without `l4dtoolz`. We run `-maxplayers 8`, which is well inside both, but raising infected limits or player counts later has to respect them.

---

## Verified on a live server

Confirmed on Debian 12 / Proxmox against L4D2 build `2.2.4.3 10097`, SourceMod 1.12.0-git7253:

- **Checks 1 and 1b pass.** All 26 plugins load, including all ten of ours plus the Source Scramble extension and the SQLite driver. The only load error is stock `nextmap.smx`, which is genuinely incompatible with L4D2 and is moved to `plugins/disabled/`.
- **All four `zombie_spawn_fix` memory patches enable** against this game build — four `Enabled patch:` lines, no `Failed to verify patch`.
- **The SteamCMD "Missing configuration" fallback is load-bearing.** The real install failed exactly as CLAUDE.md predicted (`ERROR! Failed to install app '222860' (Missing configuration)`) and the automatic windows→linux retry recovered it. Without that fallback the install dead-ends.
- **The SQLite upsert works.** `INSERT ... ON CONFLICT(steamid) DO UPDATE` was exercised on the bundled SQLite: totals accumulate correctly across repeat writes.
- **All 8 cvars register** with the documented defaults, and `cfg/sourcemod/l4d2_invasion.cfg` is generated.

### Gotcha: an empty server hibernates

An L4D2 server with nobody on it reports `(hibernating)` in `status` and stops running game frames. That stalls everything SourceMod dispatches per-frame, **threaded database callbacks included** — so on an empty server the SQLite file sits at 0 bytes with no tables, and `OnConfigsExecuted` never fires. Nothing is wrong; the schema is created the moment a player connects. There is no `sv_hibernate*` cvar in L4D2 to disable it.

This is worth knowing before concluding the database is broken. `OnConfigsExecuted` retries the connect as a safety net so the schema lands on the first map load with a player.

---

## Unverified / needs in-game confirmation

Everything below still needs a live invasion with two human players. Checks 2–13 in [TESTING.md](TESTING.md) are what settle them.

1. **Gate timing.** Whether the 0.1s-after-`player_team` timer lands after l4dinfectedbots' own join handling in *every* case, including late joins, joins during a transition, and joins while a round is ending. If it ever lands first, the gate could be overridden.
2. **`player_death` coverage for infected.** Whether `player_death` fires reliably for a human infected who dies **as a ghost** or to **world damage** (fall, drowning, crush). If it does not, those deaths would not count against the lives budget.
3. **Hint intrusiveness.** Whether `PrintHintText` once per second is too intrusive in practice (hint flicker / audible tick on some clients). May need to drop to a lower refresh rate or a different HUD channel.
4. **Respawn override behavior** — see [Known issues (a)](#a-l4d_setplayerspawntime-does-not-control-the-coop-respawn-delay). The measured respawn delay from check 5 confirms or refutes the source reading.
5. **Two human players are mandatory for testing.** `InvasionsAllowed()` requires at least one human survivor, and the invader stops counting as one the moment they switch teams. Solo, every join is refused — survivor *bots* do not count toward the opt-in ratio. Only checks 2, 11a and 12a are testable alone.

---

## Repo layout

```
l4d2-invasion/
├── CLAUDE.md                             (authoritative spec)
├── README.md                             (this file: versions, install, cvars, known issues)
├── TESTING.md                            (manual test checklist)
├── build.sh                              (spcomp wrapper)
├── scripting/
│   ├── l4d2_invasion.sp
│   └── include/                          (left4dhooks.inc + its 4 deps, from Left4DHooks 1.168)
│       ├── left4dhooks.inc
│       ├── left4dhooks_anim.inc
│       ├── left4dhooks_silver.inc
│       ├── left4dhooks_lux_library.inc
│       ├── left4dhooks_stocks.inc
│       └── sourcescramble.inc            (to compile zombie_spawn_fix; from Source Scramble 0.8.2.2)
├── third_party/
│   └── zombie_spawn_fix/                 (vendored: forum-only, Cloudflare-blocked, no mirror)
│       ├── scripting/zombie_spawn_fix.sp
│       └── gamedata/zombie_spawn_fix.txt
├── plugins/                              (compiled .smx output)
│   ├── l4d2_invasion.smx
│   └── zombie_spawn_fix.smx
├── cfg/
│   ├── server.cfg
│   └── sourcemod/
│       └── l4d2_invasion.cfg             (AutoExecConfig output, committed with defaults)
├── configs/
│   ├── databases.cfg.snippet             (SQLite entry for databases.cfg)
│   └── l4dinfectedbots_coop.cfg          (merge fragment for data/l4dinfectedbots/coop.cfg)
└── deploy/
    ├── setup_lxc.sh                      (runs inside a Debian 12 LXC; idempotent)
    └── deploy_plugin.sh                  (copy .smx/cfg, restart l4d2, tail error log)
```

---

## License

**GPLv3.** See [LICENSE](LICENSE) for the full text.

Copyleft is not a stylistic choice here — this repo redistributes GPLv3 code, so the whole work has to be GPLv3. Take it, fork it, run it, change it, ship your own version; the one condition is that derivatives stay GPLv3 and keep the source available.

### Third-party components

Only the first three are actually redistributed in this repo. The rest are downloaded at install time by `deploy/setup_lxc.sh` and are never part of this source tree, so their licenses govern them on your server, not here.

| Component | In this repo? | License |
|---|---|---|
| `scripting/l4d2_invasion.sp` | yes — our code | GPLv3 |
| `scripting/include/left4dhooks*.inc` (5 files) | yes — vendored | GPLv3 ([Left4DHooks](https://github.com/SilvDev/Left4DHooks) ships a verbatim GPLv3 `LICENSE`) |
| `scripting/include/sourcescramble.inc` | yes — vendored | GPL-3.0 ([SMExt-SourceScramble](https://github.com/nosoop/SMExt-SourceScramble)) |
| `third_party/zombie_spawn_fix/` | yes — vendored | **not stated** — see the caveat below |
| Source Scramble extension binary | no — downloaded at install | GPL-3.0 |
| MoYu companion plugins | no — downloaded at install | see [MoYu_Server_Stupid_Plugins](https://github.com/Target5150/MoYu_Server_Stupid_Plugins) |
| l4dinfectedbots, `l4d_ghost_spawn_exploit`, `spawn_infected_nolimit` | no — downloaded at install | see [L4D1_2-Plugins](https://github.com/fbef0102/L4D1_2-Plugins) |
| Metamod:Source, SourceMod | no — downloaded at install | their own terms |

**Caveat on `zombie_spawn_fix`.** Its source carries **no license header**, and its author (sorallll) has no public repos, so there is no upstream license file to point at. AlliedModders plugins are GPL by convention and it is freely distributed on [thread 333351](https://forums.alliedmods.net/showthread.php?t=333351), but that convention is not a licence grant in writing. It is vendored here only because Cloudflare makes it undownloadable by script — it is not our code, and we claim nothing over it. If you want the repo unambiguously clean, delete `third_party/zombie_spawn_fix/` and `plugins/zombie_spawn_fix.smx`; `build.sh` skips it when absent and nothing else depends on it.

---

## Choosing a side

By default (`l4d2_invasion_menu 1`) every player is offered a menu on their first spawn of the round, so picking a side needs no chat command:

```
L4D2 INVASION - choose your side
  1. Survivor - open to invasion
  2. Survivor - no invasions
  3. INVADE  (10 lives / 6:00)
```

`!invade` reopens it at any time.

**The opt-in is folded into the survivor choices.** Previously people had to remember `!invadable` as a separate step, and forgetting it made invasions look broken — the first live session produced three `Join rejected ... Invasions are closed` entries before anyone worked it out. `!invadable` still works and still toggles the same flag.

**The INVADE option is greyed out with the reason when it is unavailable**, instead of letting someone join the infected team and get bounced to spectator a tenth of a second later:

| Shown | Meaning |
|---|---|
| `INVADE (needs another survivor)` | you are the only human survivor, so there would be nobody to invade |
| `INVADE (needs 2 more survivors to opt in)` | the opt-in ratio is not met |
| `INVADE (slots full, 2/2)` | `l4d2_invasion_max_invaders` reached |
| `INVADE (available in 1:23)` | your cooldown is still running |
| `INVADE (already invading)` | you have a session open |

`CanInvade()` mirrors the checks in `Timer_CheckJoin` in the same order, and judges the opt-in ratio against the survivor count **after** the player would leave — which is what the real gate sees. Selecting INVADE re-checks before acting, since the menu may have been open a while.

Choosing INVADE runs `sm_ji`, so l4dinfectedbots still owns the actual team move and there remains exactly one code path for starting an invasion.
