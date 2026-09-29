# TESTING.md — L4D2 Invasion Mode manual test checklist

13 checks, run in order. Each has an explicit pass condition and a blank **Result** line to fill in. Everything here is manual; the plugin has no automated test harness.

---

## Before you start

**Server paths** (as installed by `deploy/setup_lxc.sh`):

| Thing | Path |
|---|---|
| Game root | `/home/steam/l4d2` |
| Mod dir | `/home/steam/l4d2/left4dead2` |
| Plugins | `/home/steam/l4d2/left4dead2/addons/sourcemod/plugins` |
| SourceMod logs | `/home/steam/l4d2/left4dead2/addons/sourcemod/logs` |
| Our cvar config | `/home/steam/l4d2/left4dead2/cfg/sourcemod/l4d2_invasion.cfg` |
| l4dinfectedbots data config | `/home/steam/l4d2/left4dead2/addons/sourcemod/data/l4dinfectedbots/coop.cfg` |
| SQLite DB | `/home/steam/l4d2/left4dead2/addons/sourcemod/data/sqlite/l4d2_invasion.sq3` |

### Seeing console output

The server runs under systemd as `l4d2.service`, so its console goes to the journal:

```bash
sudo journalctl -u l4d2 -f                  # live tail
sudo journalctl -u l4d2 -n 200 --no-pager   # last 200 lines
sudo systemctl restart l4d2                 # restart
```

SourceMod's own logs are separate from the console:

```bash
ls -la /home/steam/l4d2/left4dead2/addons/sourcemod/logs/
tail -n 100 /home/steam/l4d2/left4dead2/addons/sourcemod/logs/errors_*.log
```

### Opening the SQLite DB

```bash
sqlite3 /home/steam/l4d2/left4dead2/addons/sourcemod/data/sqlite/l4d2_invasion.sq3
```

Then, inside the shell:

```sql
.headers on
.mode column
.tables
SELECT * FROM players;
SELECT * FROM invasions ORDER BY id DESC LIMIT 10;
.quit
```

Or in one shot, without the interactive shell:

```bash
sqlite3 -header -column \
  /home/steam/l4d2/left4dead2/addons/sourcemod/data/sqlite/l4d2_invasion.sq3 \
  "SELECT steamid,name,invasions,kills,incaps,damage,deaths FROM players;"
```

### Verbose logging

`sm_inv_debug` is an admin toggle (`ADMFLAG_CONFIG`). Turn it on before any check where you care about timing or about why a gate rejected a join; it is what logs the respawn-time values needed for check 5.

```
sm_inv_debug
```

Run it from the server console, from rcon, or in chat as an admin. It toggles, so run it again to turn verbose logging back off.

### Changing cvars live

Do not edit `cfg/sourcemod/l4d2_invasion.cfg` and expect a mid-session effect; that file is only read on plugin load. Change values live instead:

```
sm_cvar l4d2_invasion_time 30          # server console
rcon sm_cvar l4d2_invasion_lives 3     # remote
!sm_cvar l4d2_invasion_lives 3         # in-game chat, as an admin
```

All 8 of our cvars have change hooks, so a live change applies immediately with no reload.

### Baseline before each run

```
sm plugins list
sm cvarlist l4d2_invasion
```

To start from a clean slate, stop the server, delete the DB (it is recreated on next load), and/or wait out `l4d2_invasion_cooldown`:

```bash
sudo systemctl stop l4d2
rm -f /home/steam/l4d2/left4dead2/addons/sourcemod/data/sqlite/l4d2_invasion.sq3
sudo systemctl start l4d2
```

---

## Checklist

### [ ] 1. Server boots with all three core plugins loaded

Start the server, then run `sm plugins list` in the console.

**Pass condition:** `l4d2_invasion`, `l4dinfectedbots` and `left4dhooks` all show as loaded/running, and today's `addons/sourcemod/logs/errors_*.log` contains no new entries from any of the three.

**Result:**

---

### [ ] 1b. Companion plugins and the Source Scramble extension loaded

Run `sm exts list` and `sm plugins list`.

**Pass condition:** `sm exts list` shows **Source Scramble** as running, and `sm plugins list` also shows `l4d_unrestrict_panic_battlefield`, `l4d_fix_deathfall_cam`, `l4d2_scripted_tank_stage_fix`, `l4d_ghost_spawn_exploit`, `spawn_infected_nolimit` and `sourcescramble_manager` loaded, with no new gamedata/signature errors in `errors_*.log`.

Two expected exceptions, neither a failure:

- `zombie_spawn_fix` will be **absent** unless you installed it by hand — `setup_lxc.sh` prints a warning about it (it is a Cloudflare-protected forum attachment). See README "Known issues (b)".
- If you did add `zombie_spawn_fix`, check `errors_*.log` specifically for **patch verification** errors; users report these after game updates. If they appear, remove it — nothing else depends on it.

A signature/gamedata failure in any companion should not stop `l4d2_invasion` from working. If one fails to load, note which and carry on with the rest of the checklist.

**Result:**

---

### [ ] 2. Join is blocked when nobody has opted in

With zero survivors opted in (fresh map, nobody has typed `!invadable`), have a human player try to join the infected team.

**Pass condition:** the player is moved to spectator and chat shows `Invasions are closed. Survivors must opt in with !invadable.`

**Result:**

---

### [ ] 3. Join works once the opt-in ratio is met

Have at least 50% of the human survivors type `!invadable` (default `l4d2_invasion_optin_ratio 0.5`), then have a player join infected.

**Pass condition:** `!invadable` prints the opted-in count out of the human-survivor total to everyone; the infected join succeeds; chat shows `[INVASION] <name> has invaded the campaign!`; the invader receives a hint stating the rules.

**Result:**

---

### [ ] 4. Hint HUD counts down and lives update on death

Watch the invader's hint text for several seconds, then die once.

**Pass condition:** the hint reads `Lives: X/10 | Time left: M:SS`, the time left decrements roughly once per second, and the lives number increases by exactly 1 on the death (`Lives: 1/10` after the first death).

**Result:**

---

### [ ] 5. Respawn after death happens at ~10s — measure it and note any override

Die as the invader and time the gap until you can spawn again. Have `sm_inv_debug` on so both the requested and the effective respawn values are logged.

**Pass condition:** respawn happens at roughly 10s. Record the measured value. If it is not ~10s, note what it actually was — see README "Known issues (a)": in coop the real control is `coop_versus_spawn_time_min`/`_max` in `data/l4dinfectedbots/coop.cfg`, not `l4d2_invasion_respawn`, and l4dinfectedbots clamps it to a 3.0s floor. This check confirms whether the two are in sync. Do not patch l4dinfectedbots.

**Result:** measured respawn = ______ s; override observed? ______

---

### [ ] 6. The 10th death ends the invasion

Die 10 times as the invader, with `l4d2_invasion_lives` at its default of 10.

**Pass condition:** on the 10th death the invasion ends; chat shows `[INVASION] <name>'s invasion ended (Out of lives). Kills: K | Incaps: I | Damage: D`; with the default `l4d2_invasion_end_action 1` the player is kicked with a message naming the reason and the kill count.

**Result:**

---

### [ ] 7. The time budget ends the invasion

Set `sm_cvar l4d2_invasion_time 30`, start an invasion, and let it run.

**Pass condition:** the invasion ends after 30 seconds of *active* time (round running, invader on the infected team) with the reason `Time's up`. Reset the cvar to 360 afterwards.

**Result:**

---

### [ ] 8. The timer pauses across a map transition and the session resumes

Start an invasion, note the lives used and the time left, then finish the map and go through the transition to the next one.

**Pass condition:** elapsed time does not advance during the transition/load, nor between `round_end` and `round_start`; on the next map the same SteamID resumes the same session with the same lives used and the same time remaining (not a fresh 10 lives / 360s).

**Result:**

---

### [ ] 9. Cooldown blocks a reconnect after an invasion ends

After an invasion ends for any reason, reconnect and try to join infected again inside `l4d2_invasion_cooldown` (default 600s).

**Pass condition:** the join is refused, the player is moved to spectator, and chat shows `You can invade again in M:SS.` with a plausible remaining time.

**Result:**

---

### [ ] 10. Disconnecting mid-invasion writes the stats, and a rejoin is blocked

Start an invasion, take some kills and deal some damage, then disconnect from the server outright (quit, not spectate). Reconnect and try to invade.

**Pass condition:** the partial invasion's stats are written to the DB (a new row in `invasions`, and the `players` totals incremented — verify with `sqlite3`), and the rejoin is refused by the cooldown message. Leaving must not reset the lives/time budget.

**Result:**

---

### [ ] 11. `!invtop` and `!invstats` return correct numbers

Run both commands in chat, then cross-check against the DB:

```bash
sqlite3 -header -column \
  /home/steam/l4d2/left4dead2/addons/sourcemod/data/sqlite/l4d2_invasion.sq3 \
  "SELECT steamid,name,invasions,kills,incaps,damage,deaths FROM players ORDER BY kills DESC LIMIT 10;"
```

**Pass condition:** `!invstats` shows the caller's own lifetime totals and they match that caller's `players` row; `!invtop` lists up to 10 invaders ordered by kills descending, and the names and numbers match the query above.

**Result:**

---

### [ ] 12. `sm_inv_end` and `sm_inv_status` work for an admin

As an admin with `ADMFLAG_KICK`, run `sm_inv_status` during an active invasion, then `sm_inv_end <target>` on the invader.

**Pass condition:** `sm_inv_status` lists the current invader(s) with lives used and time left; `sm_inv_end` force-ends that invasion, producing the normal end announcement, DB write and cooldown. A non-admin running `sm_inv_end` is refused.

**Result:**

---

### [ ] 13. Changing a cvar live applies to the invasion in progress

During an active invasion run `sm_cvar l4d2_invasion_lives 3` (with the invader already at 3 or more deaths, or die up to it).

**Pass condition:** the new limit takes effect on the invader's next death — the invasion ends with `Out of lives` instead of continuing to 10. No plugin reload required.

**Result:**

---

## What to send back

For any check that fails, send all four of these. A report without them is not actionable.

1. **The SourceMod error log** for the day of the test:

   ```bash
   ls -la /home/steam/l4d2/left4dead2/addons/sourcemod/logs/
   cat /home/steam/l4d2/left4dead2/addons/sourcemod/logs/errors_*.log
   ```

2. **Server console output around the failure** — roughly 100 lines either side, not just the error line:

   ```bash
   sudo journalctl -u l4d2 -n 400 --no-pager > /tmp/l4d2-console.txt
   ```

3. **`sm plugins list`** output, so load state and versions are unambiguous.

4. **`sm cvarlist l4d2_invasion`** output, so the effective cvar values at failure time are known.

Also useful when relevant:

```bash
cat /home/steam/l4d2/left4dead2/addons/sourcemod/data/l4dinfectedbots/coop.cfg
sqlite3 -header -column \
  /home/steam/l4d2/left4dead2/addons/sourcemod/data/sqlite/l4d2_invasion.sq3 \
  "SELECT * FROM invasions ORDER BY id DESC LIMIT 10;"
```

plus the measured numbers recorded for checks 5, 7 and 8.
