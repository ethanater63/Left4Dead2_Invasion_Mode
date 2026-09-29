# L4D2 Invasion Mode — Implementation Plan

All design decisions below are final. Do not redesign, add features, or ask clarifying questions. Only stop if a hard blocker comes up (e.g., a cvar name can't be verified). Ethan does all in-game testing and will feed back logs and bugs.

## Goal

A SourceMod plugin for Left 4 Dead 2 **coop** where a human player can join the infected team as an "invader" with a limited budget: **10 lives or 6 minutes, whichever comes first**. When the budget runs out, the invader is removed. Invader stats (kills, incaps, damage) are saved to SQLite for a leaderboard.

## Scope

**Phase 1 (this build):**
- One dedicated server
- One plugin: `l4d2_invasion.sp`
- Configs
- A Proxmox LXC setup script

**Out of scope — do NOT build:**
- Cross-server matchmaking or queue
- Web leaderboard
- Cosmetics
- Changes to third-party plugins
- Custom gamedata

## Stack (pin versions after checking latest stable)

| Component | Source | Notes |
|---|---|---|
| L4D2 Dedicated Server | SteamCMD app `222860` | Linux, 32-bit deps |
| Metamod:Source | metamodsource.net | Latest **stable** 1.12.x |
| SourceMod | sourcemod.net | Latest **stable** 1.12.x |
| Left 4 DHooks Direct | AlliedModders (Silvers) | Required by l4dinfectedbots and by us (`L4D_SetPlayerSpawnTime`) |
| l4dinfectedbots | github.com/fbef0102/L4D1_2-Plugins/tree/master/l4dinfectedbots | Provides playable SI in coop |

Build-time check on each download: use the latest stable release and write the exact versions into `README.md`.

## Repo layout

```
l4d2-invasion/
├── CLAUDE.md                 (this file)
├── README.md                 (versions, install steps, cvar table)
├── scripting/
│   ├── l4d2_invasion.sp
│   └── include/              (left4dhooks.inc + deps copied from its release)
├── plugins/                  (compiled .smx output)
├── cfg/
│   ├── server.cfg
│   └── sourcemod/l4d2_invasion.cfg   (AutoExecConfig output, committed with defaults)
├── configs/
│   └── databases.cfg.snippet
├── deploy/
│   ├── setup_lxc.sh          (runs inside a Debian 12 LXC)
│   └── deploy_plugin.sh      (copies .smx/cfg to server, restarts)
└── TESTING.md                (manual test checklist, copied from below)
```

## Step 1 — Server setup script (`deploy/setup_lxc.sh`)

Target is a Debian 12 LXC on Proxmox. The script must be idempotent.

1. `dpkg --add-architecture i386 && apt update`
2. Install: `lib32gcc-s1 lib32stdc++6 libc6-i386 curl tar screen sqlite3 ca-certificates`
3. Create a user `steam` with home `/home/steam`.
4. Install SteamCMD into `/home/steam/steamcmd`.
5. Install the server:
   `+force_install_dir /home/steam/l4d2 +login anonymous +app_update 222860 validate +quit`
   - **Known issue:** anonymous Linux installs of 222860 can fail with "Missing configuration."
   - If that happens, run once with `+@sSteamCmdForcePlatformType windows`, then run again with `+@sSteamCmdForcePlatformType linux ... validate`.
   - Include this fallback automatically.
6. Extract Metamod and SourceMod into `/home/steam/l4d2/left4dead2/`.
7. Install left4dhooks: `.smx`, gamedata, and its extension or deps, per its install instructions.
8. Install l4dinfectedbots: `.smx`, `data/l4dinfectedbots/`, and gamedata.
9. Write a systemd unit `l4d2.service`:
   `./srcds_run -game left4dead2 -console -port 27015 +map c1m1_hotel +maxplayers 8 -tickrate 30`
   - Runs as the `steam` user, with `Restart=on-failure`.
10. Open UDP/TCP 27015.

## Step 2 — Configure l4dinfectedbots for human infected in coop

Set these in `cfg/sourcemod/l4dinfectedbots.cfg`, or wherever the plugin's AutoExecConfig writes.

**VERIFY EVERY CVAR NAME against the current l4dinfectedbots readme and source before writing.** The names below come from older forum posts, and the changelog shows at least one rename (`l4d_infectedbots_human_coop_survival_limit`). Use the current names.

Intended behavior:
- Human players can join infected in coop: `l4d_infectedbots_coop_versus "1"` (or the current equivalent)
- Non-admins can join: `l4d_infectedbots_admin_coop_versus "0"`
- Human infected slots = 1: `l4d_infectedbots_coop_versus_human_limit "1"` (or the current equivalent)
- Humans can't play Tank: `l4d_infectedbots_coop_versus_tank_playable "0"`
- Leave bot spawn counts at their defaults.

Put a table in `README.md` mapping each intended behavior to the verified cvar name.

## Step 3 — The plugin (`scripting/l4d2_invasion.sp`)

### Includes / requirements
- `#include <sourcemod>`, `#include <sdktools>`, `#include <left4dhooks>`
- `#pragma semicolon 1` and `#pragma newdecls required`
- Use no other third-party includes. For colors, use raw `\x01` (default), `\x04` (green), and `\x05` (olive) chat codes.

### Cvars (create with `CreateConVar`, then call `AutoExecConfig(true, "l4d2_invasion")`)

| Cvar | Default | Meaning |
|---|---|---|
| `l4d2_invasion_enable` | `1` | Master switch |
| `l4d2_invasion_lives` | `10` | Deaths allowed per invasion |
| `l4d2_invasion_time` | `360` | Invasion length in seconds (active time only, see timer rules) |
| `l4d2_invasion_respawn` | `10.0` | Invader respawn time in seconds |
| `l4d2_invasion_end_action` | `1` | 0 = move to spectator, 1 = kick |
| `l4d2_invasion_cooldown` | `600` | Seconds before the same SteamID can invade again |
| `l4d2_invasion_optin_ratio` | `0.5` | Fraction of human survivors who must have `!invadable` on |
| `l4d2_invasion_max_invaders` | `1` | Max simultaneous human invaders |

Hook `OnConVarChanged` for all cvars so changes apply live.

### Constants
- Teams: `TEAM_SPEC = 1`, `TEAM_SURVIVOR = 2`, `TEAM_INFECTED = 3`
- Ghost check: `GetEntProp(client, Prop_Send, "m_isGhost") == 1`

### State
- `bool g_bOptIn[MAXPLAYERS+1]`: per-survivor opt-in. Defaults to `false` and is reset on disconnect.
- Session per invader, stored in a `StringMap` keyed by SteamID2 (`GetClientAuthId(client, AuthId_Steam2, ...)`) so it survives map transitions. Each session holds:
  - `livesUsed`
  - `secondsElapsed`
  - `kills`
  - `incaps`
  - `damage`
  - `startTimestamp`
- `StringMap g_Cooldowns`: SteamID → unix time the invasion ended.
- `bool g_bRoundActive`: set true on `round_start`, false on `round_end` and `map_transition`.

### Opt-in logic

**`sm_invadable` command:**
- Only survivors can use it.
- It toggles `g_bOptIn`.
- It prints the current status, and the count of opted-in survivors out of the total, to all players.

**`InvasionsAllowed()`** returns true only when all of these hold:
1. `enable == 1`
2. At least 1 human survivor exists.
3. (opted-in human survivors / human survivors) >= `optin_ratio`

### Joining (gate)

Hook `player_team`. Skip the check if the player is a bot or the event is `disconnect`.

When `team == TEAM_INFECTED`, first create a 0.1s timer carrying the userid, then run these checks in the timer callback:
1. If `!InvasionsAllowed()`: move to spectator and show chat "Invasions are closed. Survivors must opt in with !invadable."
2. If the player is in cooldown: move to spectator and show chat "You can invade again in M:SS."
3. If the active invader count >= `max_invaders`: move to spectator and show chat "Invader slot full."
4. Otherwise:
   - Create the session, or resume it if the SteamID already has an active one.
   - Announce to everyone: `\x04[INVASION]\x01 \x05<name>\x01 has invaded the campaign!`
   - Show the invader a hint with the rules.

**Survivors turning off opt-in mid-invasion does NOT end current invasions.** It only blocks new ones.

### Death counting

Hook `player_death`. If the victim is a human on `TEAM_INFECTED` with an active session:
- Increment `livesUsed`. All deaths count, including suicide, fall damage, and world damage.
- If `livesUsed >= lives`, run `EndInvasion(client, "Out of lives")`.
- Otherwise, create a 0.1s timer and then call `L4D_SetPlayerSpawnTime(client, respawn)`.
  - The 0.1s delay runs after l4dinfectedbots sets its own timer, so our value wins.
  - Log both values once in debug mode. If l4dinfectedbots still overrides ours, note it in `README.md` under "Known issues." Do not patch l4dinfectedbots.

If the victim is a survivor and the attacker is an active invader: increment the invader's `kills`.

### Incaps / damage
- `player_incapacitated`: victim is a survivor and the attacker is an active invader → increment `incaps`.
- `player_hurt`: victim is a survivor and the attacker is an active invader → add `dmg_health` to `damage`.

### Timer (1s repeating, created in `OnPluginStart`, `TIMER_REPEAT`)

For each client with an active session:
- If `g_bRoundActive` and the client is in-game on `TEAM_INFECTED`:
  - Increment `secondsElapsed`. Time counts while the invader is a ghost, alive, or waiting to respawn.
  - Show a hint: `Lives: X/10 | Time left: M:SS`
- If `secondsElapsed >= time`: run `EndInvasion(client, "Time's up")`.

Time does NOT count during map transitions, loading, or between `round_end` and `round_start`.

### `EndInvasion(client, reason)`
1. Announce to everyone: `\x04[INVASION]\x01 \x05<name>\x01's invasion ended (<reason>). Kills: K | Incaps: I | Damage: D`
2. Write stats to the DB (async).
3. Set the cooldown for the SteamID and remove the session.
4. If `end_action == 1`: `KickClient(client, "Invasion over — %s. Kills: %d", reason, kills)`
   Otherwise: `ChangeClientTeam(client, TEAM_SPEC)`

### Disconnect mid-invasion
`OnClientDisconnect`: if the client has an active session, run the same path as `EndInvasion` without the kick. Save stats, set the cooldown, remove the session. This means leaving can't be used to reset the budget.

### Database (SQLite, async only)

Add to `databases.cfg`:
```
"l4d2_invasion" { "driver" "sqlite" "database" "l4d2_invasion" }
```

Connect with `Database.Connect(OnDbConnect, "l4d2_invasion")` in `OnPluginStart`.

Tables (create if they don't exist):
```sql
CREATE TABLE IF NOT EXISTS players (
  steamid TEXT PRIMARY KEY,
  name TEXT,
  invasions INTEGER DEFAULT 0,
  kills INTEGER DEFAULT 0,
  incaps INTEGER DEFAULT 0,
  damage INTEGER DEFAULT 0,
  deaths INTEGER DEFAULT 0,
  last_seen INTEGER
);
CREATE TABLE IF NOT EXISTS invasions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  steamid TEXT,
  map TEXT,
  started INTEGER,
  ended INTEGER,
  reason TEXT,
  kills INTEGER, incaps INTEGER, damage INTEGER, deaths INTEGER
);
```

On `EndInvasion`:
- `INSERT INTO invasions` once.
- Upsert `players`: `INSERT ... ON CONFLICT(steamid) DO UPDATE SET` to add to the totals.
- Escape names with `db.Escape`.

If the DB is unavailable, log an error and keep playing. Do not block gameplay.

### Commands
- `sm_invadable`: survivor opt-in toggle
- `sm_invstats`: the caller's lifetime totals
- `sm_invtop`: top 10 by kills, shown in chat
- `sm_inv_status`: current invader(s), lives, and time left
- `sm_inv_end <target>`: admin (`ADMFLAG_KICK`) force-ends an invasion
- `sm_inv_debug`: admin toggle for verbose `LogMessage` output

### Code quality bar
- Validate every client with `IsClientInGame` / `!IsFakeClient` before use, and pass userids (not client indexes) through timers.
- Call no blocking SQL.
- The build must have zero compiler warnings.
- Each handler stays under ~40 lines, with helpers extracted.

## Step 4 — Build

- Use `spcomp` from the same SourceMod version as the server: `spcomp scripting/l4d2_invasion.sp -i scripting/include -o plugins/l4d2_invasion.smx`
- Add a `Makefile` or `build.sh` wrapper.
- The build must compile clean before Step 5.

## Step 5 — Deploy script (`deploy/deploy_plugin.sh`)

- Target host is set by an env var `L4D2_HOST` (default `steam@l4d2.local`).
- rsync `plugins/*.smx` → `addons/sourcemod/plugins/`, and the cfg files into place.
- Append the `databases.cfg` entry if it's missing (grep first).
- `systemctl restart l4d2`, then tail the last 50 lines of the SourceMod error log.

## Step 6 — Write `TESTING.md` with this checklist

Ethan runs these checks. Each has a pass condition.

1. The server boots. `sm plugins list` shows l4d2_invasion, l4dinfectedbots, and left4dhooks loaded, and there are no errors in `logs/errors_*.log`.
2. With no survivors opted in, a player joining infected is moved to spectator with the "closed" message.
3. After `!invadable` by ≥50% of human survivors, an infected join works and the announcement shows.
4. The invader's hint HUD counts down and the lives counter updates on death.
5. Respawn after death happens at ~10s. Measure it, and note if l4dinfectedbots overrides it.
6. The 10th death ends the invasion: the player is kicked with the reason, and the stats announcement shows.
7. With `l4d2_invasion_time 30`, the invasion ends at 30s of active time.
8. The timer pauses during a map transition, and the session resumes with the same lives and time on the next map.
9. Reconnecting after an invasion ends is blocked by the cooldown message.
10. Disconnecting mid-invasion writes the stats, and a rejoin is blocked by the cooldown.
11. `!invtop` and `!invstats` return correct numbers. Cross-check with `sqlite3 addons/sourcemod/data/sqlite/l4d2_invasion.sq3`.
12. `sm_inv_end` and `sm_inv_status` work for an admin.
13. Changing a cvar live (e.g., `l4d2_invasion_lives 3`) applies to the current invasion on its next death.

## Definition of done
- All files in the repo layout exist.
- The plugin compiles with zero warnings.
- `README.md` lists pinned versions, the verified l4dinfectedbots cvar table, and install/deploy steps.
- `TESTING.md` exists.
- A summary at the end lists anything unverified that needs to be checked in-game.
