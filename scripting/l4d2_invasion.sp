/**
 * L4D2 Invasion Mode
 * Copyright (C) 2026 Ethan
 *
 * Lets a human player join the infected team in coop as an "invader" on a fixed
 * budget: N lives or N seconds of active time, whichever runs out first. When the
 * budget is gone the invader is removed. Invasion stats are written to SQLite.
 *
 * Requires: Left 4 DHooks Direct, and l4dinfectedbots to provide playable SI in coop.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION      "1.0.0"

#define TEAM_SPEC           1
#define TEAM_SURVIVOR       2
#define TEAM_INFECTED       3

#define TAG                 "\x04[INVASION]\x01"
#define DB_CONFIG           "l4d2_invasion"

enum struct InvasionSession
{
	int livesUsed;
	int secondsElapsed;
	int kills;
	int incaps;
	int damage;
	int startTimestamp;
}

enum InvStat
{
	Stat_Kill = 0,
	Stat_Incap,
	Stat_Damage
}

ConVar g_cvEnable;
ConVar g_cvLives;
ConVar g_cvTime;
ConVar g_cvRespawn;
ConVar g_cvEndAction;
ConVar g_cvCooldown;
ConVar g_cvOptInRatio;
ConVar g_cvMaxInvaders;

bool  g_bEnable;
int   g_iLives;
int   g_iTime;
float g_fRespawn;
int   g_iEndAction;
int   g_iCooldown;
float g_fOptInRatio;
int   g_iMaxInvaders;

bool g_bOptIn[MAXPLAYERS + 1];
bool g_bRoundActive;
bool g_bDebug;
bool g_bSchemaReady;        // true once a CREATE TABLE has actually come back OK

StringMap g_Sessions;       // SteamID2 -> InvasionSession. Present means the invasion is active.
StringMap g_Cooldowns;      // SteamID2 -> unix time the invasion ended.

Database g_hDb;

public Plugin myinfo =
{
	name = "L4D2 Invasion Mode",
	author = "Ethan",
	description = "Budgeted human infected invasions in coop, with SQLite stats.",
	version = PLUGIN_VERSION,
	url = ""
};

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

public void OnPluginStart()
{
	g_Sessions = new StringMap();
	g_Cooldowns = new StringMap();

	CreateCvars();
	RegisterCommands();
	HookEvents();

	CreateTimer(1.0, Timer_Invasion, 0, TIMER_REPEAT);
	Database.Connect(OnDbConnect, DB_CONFIG);
}

void CreateCvars()
{
	g_cvEnable      = CreateConVar("l4d2_invasion_enable",       "1",    "Master switch for invasion mode.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvLives       = CreateConVar("l4d2_invasion_lives",        "10",   "Deaths allowed per invasion.", FCVAR_NOTIFY, true, 1.0);
	g_cvTime        = CreateConVar("l4d2_invasion_time",         "360",  "Invasion length in seconds of active time.", FCVAR_NOTIFY, true, 1.0);
	g_cvRespawn     = CreateConVar("l4d2_invasion_respawn",      "10.0", "Invader respawn time in seconds.", FCVAR_NOTIFY, true, 0.0);
	g_cvEndAction   = CreateConVar("l4d2_invasion_end_action",   "1",    "When the budget runs out: 0 = move to spectator, 1 = kick.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvCooldown    = CreateConVar("l4d2_invasion_cooldown",     "600",  "Seconds before the same SteamID can invade again.", FCVAR_NOTIFY, true, 0.0);
	g_cvOptInRatio  = CreateConVar("l4d2_invasion_optin_ratio",  "0.5",  "Fraction of human survivors who must have !invadable on.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvMaxInvaders = CreateConVar("l4d2_invasion_max_invaders", "1",    "Max simultaneous human invaders.", FCVAR_NOTIFY, true, 1.0);

	g_cvEnable.AddChangeHook(OnCvarChanged);
	g_cvLives.AddChangeHook(OnCvarChanged);
	g_cvTime.AddChangeHook(OnCvarChanged);
	g_cvRespawn.AddChangeHook(OnCvarChanged);
	g_cvEndAction.AddChangeHook(OnCvarChanged);
	g_cvCooldown.AddChangeHook(OnCvarChanged);
	g_cvOptInRatio.AddChangeHook(OnCvarChanged);
	g_cvMaxInvaders.AddChangeHook(OnCvarChanged);

	AutoExecConfig(true, "l4d2_invasion");
	CacheCvars();
}

void RegisterCommands()
{
	RegConsoleCmd("sm_invadable",  Cmd_Invadable, "Toggle whether you are open to being invaded.");
	RegConsoleCmd("sm_invstats",   Cmd_InvStats,  "Show your lifetime invasion totals.");
	RegConsoleCmd("sm_invtop",     Cmd_InvTop,    "Show the top 10 invaders by kills.");
	RegConsoleCmd("sm_inv_status", Cmd_InvStatus, "Show the current invader(s), lives and time left.");

	RegAdminCmd("sm_inv_end",   Cmd_InvEnd,   ADMFLAG_KICK,   "sm_inv_end <target> - force-end an invasion.");
	RegAdminCmd("sm_inv_debug", Cmd_InvDebug, ADMFLAG_CONFIG, "Toggle verbose invasion logging.");
}

void HookEvents()
{
	HookEvent("player_team",          Event_PlayerTeam);
	HookEvent("player_death",         Event_PlayerDeath);
	HookEvent("player_hurt",          Event_PlayerHurt);
	HookEvent("player_incapacitated", Event_PlayerIncap);
	HookEvent("round_start",          Event_RoundStart);
	HookEvent("round_end",            Event_RoundEnd);

	// In coop, "round_end" is not the only way a round ends. "map_transition"
	// fires on a saferoom exit without firing "round_end" at all, and
	// "finale_win" ends the campaign. Both must pause the budget timer, or time
	// would keep draining while nothing is playable. ("mission_lost" also fires
	// "round_end", but is hooked here so the pause does not depend on that.)
	HookEvent("map_transition",       Event_RoundEnd);
	HookEvent("mission_lost",         Event_RoundEnd);
	HookEvent("finale_win",           Event_RoundEnd);
}

void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	CacheCvars();
}

void CacheCvars()
{
	g_bEnable      = g_cvEnable.BoolValue;
	g_iLives       = g_cvLives.IntValue;
	g_iTime        = g_cvTime.IntValue;
	g_fRespawn     = g_cvRespawn.FloatValue;
	g_iEndAction   = g_cvEndAction.IntValue;
	g_iCooldown    = g_cvCooldown.IntValue;
	g_fOptInRatio  = g_cvOptInRatio.FloatValue;
	g_iMaxInvaders = g_cvMaxInvaders.IntValue;
}

public void OnConfigsExecuted()
{
	// Safety net for the schema. An L4D2 server with nobody on it reports
	// "(hibernating)" in `status` and stops running game frames, which stalls
	// everything SourceMod dispatches per-frame - threaded database callbacks
	// included. A connect issued from OnPluginStart on an empty server therefore
	// sits pending, leaving a 0-byte database with no tables until someone joins.
	// That is harmless in practice, but retrying here means the schema is in
	// place from the first map load rather than depending on connect timing.
	if (!g_bSchemaReady)
		Database.Connect(OnDbConnect, DB_CONFIG);
}

public void OnMapEnd()
{
	g_bRoundActive = false;
}

public void OnClientConnected(int client)
{
	g_bOptIn[client] = false;
}

public void OnClientDisconnect(int client)
{
	InvasionSession session;
	if (GetSession(client, session))
		FinishInvasion(client, "Disconnected", false);

	g_bOptIn[client] = false;
}

// ---------------------------------------------------------------------------
// Session and player helpers
// ---------------------------------------------------------------------------

bool GetAuth(int client, char[] auth, int maxlen)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return false;

	return GetClientAuthId(client, AuthId_Steam2, auth, maxlen);
}

bool GetSession(int client, InvasionSession session)
{
	char auth[32];
	if (!GetAuth(client, auth, sizeof(auth)))
		return false;

	return g_Sessions.GetArray(auth, session, sizeof(session));
}

bool SetSession(int client, InvasionSession session)
{
	char auth[32];
	if (!GetAuth(client, auth, sizeof(auth)))
		return false;

	return g_Sessions.SetArray(auth, session, sizeof(session), true);
}

bool IsSurvivor(int client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client)
		&& GetClientTeam(client) == TEAM_SURVIVOR);
}

bool IsInvader(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return false;
	if (GetClientTeam(client) != TEAM_INFECTED)
		return false;

	InvasionSession session;
	return GetSession(client, session);
}

bool IsGhost(int client)
{
	return (IsClientInGame(client) && GetClientTeam(client) == TEAM_INFECTED
		&& GetEntProp(client, Prop_Send, "m_isGhost") == 1);
}

int CountHumanSurvivors(int &optedIn)
{
	optedIn = 0;
	int total = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		total++;
		if (g_bOptIn[i])
			optedIn++;
	}

	return total;
}

int CountActiveInvaders()
{
	int count = 0;
	InvasionSession session;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;
		if (GetSession(i, session))
			count++;
	}

	return count;
}

bool InvasionsAllowed()
{
	if (!g_bEnable)
		return false;

	int optedIn;
	int total = CountHumanSurvivors(optedIn);
	if (total < 1)
		return false;

	return (float(optedIn) / float(total)) >= g_fOptInRatio;
}

int GetCooldownRemaining(int client)
{
	char auth[32];
	if (!GetAuth(client, auth, sizeof(auth)))
		return 0;

	int ended;
	if (!g_Cooldowns.GetValue(auth, ended))
		return 0;

	int remaining = g_iCooldown - (GetTime() - ended);
	return (remaining > 0) ? remaining : 0;
}

void FormatClock(int seconds, char[] buffer, int maxlen)
{
	if (seconds < 0)
		seconds = 0;

	Format(buffer, maxlen, "%d:%02d", seconds / 60, seconds % 60);
}

void DebugLog(const char[] format, any ...)
{
	if (!g_bDebug)
		return;

	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 2);
	LogMessage("%s", buffer);
}

// ---------------------------------------------------------------------------
// Opt-in
// ---------------------------------------------------------------------------

Action Cmd_Invadable(int client, int args)
{
	if (client < 1 || !IsClientInGame(client))
		return Plugin_Handled;

	if (GetClientTeam(client) != TEAM_SURVIVOR)
	{
		PrintToChat(client, "%s Only survivors can use \x05!invadable\x01.", TAG);
		return Plugin_Handled;
	}

	g_bOptIn[client] = !g_bOptIn[client];

	int optedIn;
	int total = CountHumanSurvivors(optedIn);

	PrintToChatAll("%s \x05%N\x01 is %s invasions. (\x04%d\x01/\x04%d\x01 survivors opted in)",
		TAG, client, g_bOptIn[client] ? "open to" : "closed to", optedIn, total);

	return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// Joining the infected team
// ---------------------------------------------------------------------------

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (event.GetBool("disconnect") || event.GetBool("isbot"))
		return;
	if (event.GetInt("team") != TEAM_INFECTED)
		return;

	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	if (client < 1 || !IsClientInGame(client) || IsFakeClient(client))
		return;

	// Run the gate after l4dinfectedbots has finished its own join handling.
	CreateTimer(0.1, Timer_CheckJoin, userid, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_CheckJoin(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client < 1 || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Stop;
	if (GetClientTeam(client) != TEAM_INFECTED)
		return Plugin_Stop;

	// An existing session means this is a resume: map transition, or a rejoin
	// while the budget is still running. Resumes bypass the slot and cooldown
	// checks, otherwise the invader would lose their own slot on every map.
	InvasionSession session;
	if (GetSession(client, session))
	{
		ShowRulesHint(client);
		DebugLog("Invasion resumed for %N: lives=%d/%d elapsed=%d/%d",
			client, session.livesUsed, g_iLives, session.secondsElapsed, g_iTime);
		return Plugin_Stop;
	}

	if (!InvasionsAllowed())
	{
		RejectJoin(client, "Invasions are closed. Survivors must opt in with !invadable.");
		return Plugin_Stop;
	}

	int remaining = GetCooldownRemaining(client);
	if (remaining > 0)
	{
		char clock[16];
		FormatClock(remaining, clock, sizeof(clock));
		RejectJoin(client, "You can invade again in %s.", clock);
		return Plugin_Stop;
	}

	if (CountActiveInvaders() >= g_iMaxInvaders)
	{
		RejectJoin(client, "Invader slot full.");
		return Plugin_Stop;
	}

	StartInvasion(client);
	return Plugin_Stop;
}

void RejectJoin(int client, const char[] format, any ...)
{
	char buffer[256];
	VFormat(buffer, sizeof(buffer), format, 3);

	ChangeClientTeam(client, TEAM_SPEC);
	PrintToChat(client, "%s \x05%s", TAG, buffer);
	DebugLog("Join rejected for %N: %s", client, buffer);
}

void StartInvasion(int client)
{
	InvasionSession session;
	session.startTimestamp = GetTime();

	if (!SetSession(client, session))
		return;

	PrintToChatAll("%s \x05%N\x01 has invaded the campaign!", TAG, client);
	ShowRulesHint(client);
	DebugLog("Invasion started for %N: lives=%d time=%d respawn=%.1f",
		client, g_iLives, g_iTime, g_fRespawn);
}

void ShowRulesHint(int client)
{
	char clock[16];
	FormatClock(g_iTime, clock, sizeof(clock));

	PrintHintText(client, "YOU ARE THE INVADER\n%d lives or %s of play, whichever runs out first.\nEvery death counts. Time pauses between rounds.",
		g_iLives, clock);
}

// ---------------------------------------------------------------------------
// Scoring
// ---------------------------------------------------------------------------

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));

	if (IsInvader(victim))
	{
		HandleInvaderDeath(victim);
		return;
	}

	if (IsSurvivor(victim))
		AddInvaderStat(GetClientOfUserId(event.GetInt("attacker")), Stat_Kill, 1);
}

void HandleInvaderDeath(int client)
{
	InvasionSession session;
	if (!GetSession(client, session))
		return;

	// Every death counts: suicide, fall damage and world damage included.
	session.livesUsed++;
	SetSession(client, session);

	if (session.livesUsed >= g_iLives)
	{
		EndInvasion(client, "Out of lives");
		return;
	}

	CreateTimer(0.1, Timer_ApplyRespawn, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_ApplyRespawn(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client < 1 || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Stop;
	if (GetClientTeam(client) != TEAM_INFECTED)
		return Plugin_Stop;

	float existing = L4D_GetPlayerSpawnTime(client);
	L4D_SetPlayerSpawnTime(client, g_fRespawn, true);

	DebugLog("Respawn override for %N: existing=%.1fs ours=%.1fs readback=%.1fs",
		client, existing, g_fRespawn, L4D_GetPlayerSpawnTime(client));

	return Plugin_Stop;
}

void Event_PlayerIncap(Event event, const char[] name, bool dontBroadcast)
{
	if (!IsSurvivor(GetClientOfUserId(event.GetInt("userid"))))
		return;

	AddInvaderStat(GetClientOfUserId(event.GetInt("attacker")), Stat_Incap, 1);
}

void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	if (!IsSurvivor(GetClientOfUserId(event.GetInt("userid"))))
		return;

	AddInvaderStat(GetClientOfUserId(event.GetInt("attacker")), Stat_Damage, event.GetInt("dmg_health"));
}

void AddInvaderStat(int client, InvStat stat, int amount)
{
	if (amount <= 0 || !IsInvader(client))
		return;

	InvasionSession session;
	if (!GetSession(client, session))
		return;

	switch (stat)
	{
		case Stat_Kill:   session.kills += amount;
		case Stat_Incap:  session.incaps += amount;
		case Stat_Damage: session.damage += amount;
	}

	SetSession(client, session);
}

// ---------------------------------------------------------------------------
// Budget timer
// ---------------------------------------------------------------------------

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundActive = true;
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundActive = false;
}

Action Timer_Invasion(Handle timer)
{
	InvasionSession session;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;
		if (!GetSession(i, session))
			continue;

		// Time does not count during transitions, loading, or between rounds.
		if (!g_bRoundActive || GetClientTeam(i) != TEAM_INFECTED)
			continue;

		session.secondsElapsed++;
		SetSession(i, session);

		if (session.secondsElapsed >= g_iTime)
		{
			EndInvasion(i, "Time's up");
			continue;
		}

		ShowInvaderHud(i, session);
	}

	return Plugin_Continue;
}

void ShowInvaderHud(int client, InvasionSession session)
{
	char clock[16];
	FormatClock(g_iTime - session.secondsElapsed, clock, sizeof(clock));

	int livesLeft = g_iLives - session.livesUsed;
	if (livesLeft < 0)
		livesLeft = 0;

	PrintHintText(client, "Lives: %d/%d | Time left: %s", livesLeft, g_iLives, clock);
}

// ---------------------------------------------------------------------------
// Ending an invasion
// ---------------------------------------------------------------------------

void EndInvasion(int client, const char[] reason)
{
	FinishInvasion(client, reason, true);
}

void FinishInvasion(int client, const char[] reason, bool applyEndAction)
{
	char auth[32];
	InvasionSession session;
	if (!GetAuth(client, auth, sizeof(auth)) || !g_Sessions.GetArray(auth, session, sizeof(session)))
		return;

	char clientName[MAX_NAME_LENGTH];
	GetClientName(client, clientName, sizeof(clientName));

	PrintToChatAll("%s \x05%s\x01's invasion ended (%s). Kills: %d | Incaps: %d | Damage: %d",
		TAG, clientName, reason, session.kills, session.incaps, session.damage);

	SaveSession(auth, clientName, reason, session);

	g_Cooldowns.SetValue(auth, GetTime(), true);
	g_Sessions.Remove(auth);

	DebugLog("Invasion ended for %s (%s): lives=%d elapsed=%d kills=%d incaps=%d damage=%d",
		clientName, reason, session.livesUsed, session.secondsElapsed,
		session.kills, session.incaps, session.damage);

	if (!applyEndAction)
		return;

	if (g_iEndAction == 1)
		KickClient(client, "Invasion over - %s. Kills: %d", reason, session.kills);
	else
		ChangeClientTeam(client, TEAM_SPEC);
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

void OnDbConnect(Database db, const char[] error, any data)
{
	if (db == null)
	{
		LogError("Database connection failed (config \"%s\"): %s. Invasions still work, stats will not be saved.",
			DB_CONFIG, error);
		return;
	}

	g_hDb = db;

	g_hDb.Query(OnSchemaReady, "CREATE TABLE IF NOT EXISTS players ("
		... "steamid TEXT PRIMARY KEY, "
		... "name TEXT, "
		... "invasions INTEGER DEFAULT 0, "
		... "kills INTEGER DEFAULT 0, "
		... "incaps INTEGER DEFAULT 0, "
		... "damage INTEGER DEFAULT 0, "
		... "deaths INTEGER DEFAULT 0, "
		... "last_seen INTEGER)");

	g_hDb.Query(OnSchemaReady, "CREATE TABLE IF NOT EXISTS invasions ("
		... "id INTEGER PRIMARY KEY AUTOINCREMENT, "
		... "steamid TEXT, "
		... "map TEXT, "
		... "started INTEGER, "
		... "ended INTEGER, "
		... "reason TEXT, "
		... "kills INTEGER, incaps INTEGER, damage INTEGER, deaths INTEGER)");
}

void OnSchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
	if (results == null)
	{
		LogError("Invasion schema creation failed: %s", error);
		return;
	}

	// Only now is the database genuinely usable. OnConfigsExecuted watches this
	// flag and keeps retrying the connect until it flips.
	if (!g_bSchemaReady)
	{
		g_bSchemaReady = true;
		DebugLog("Database schema confirmed, stats will be saved.");
	}
}

void SaveSession(const char[] auth, const char[] clientName, const char[] reason, InvasionSession session)
{
	if (g_hDb == null)
	{
		LogError("No database connection, invasion stats for %s were not saved.", auth);
		return;
	}

	char safeName[MAX_NAME_LENGTH * 2 + 1];
	char safeReason[128];
	char map[64];
	char safeMap[129];
	char query[1024];

	g_hDb.Escape(clientName, safeName, sizeof(safeName));
	g_hDb.Escape(reason, safeReason, sizeof(safeReason));
	GetCurrentMap(map, sizeof(map));
	g_hDb.Escape(map, safeMap, sizeof(safeMap));

	Format(query, sizeof(query),
		"INSERT INTO invasions (steamid, map, started, ended, reason, kills, incaps, damage, deaths) "
		... "VALUES ('%s', '%s', %d, %d, '%s', %d, %d, %d, %d)",
		auth, safeMap, session.startTimestamp, GetTime(), safeReason,
		session.kills, session.incaps, session.damage, session.livesUsed);
	g_hDb.Query(OnStatsWritten, query);

	Format(query, sizeof(query),
		"INSERT INTO players (steamid, name, invasions, kills, incaps, damage, deaths, last_seen) "
		... "VALUES ('%s', '%s', 1, %d, %d, %d, %d, %d) "
		... "ON CONFLICT(steamid) DO UPDATE SET "
		... "name = excluded.name, "
		... "invasions = players.invasions + 1, "
		... "kills = players.kills + excluded.kills, "
		... "incaps = players.incaps + excluded.incaps, "
		... "damage = players.damage + excluded.damage, "
		... "deaths = players.deaths + excluded.deaths, "
		... "last_seen = excluded.last_seen",
		auth, safeName, session.kills, session.incaps, session.damage, session.livesUsed, GetTime());
	g_hDb.Query(OnStatsWritten, query);
}

void OnStatsWritten(Database db, DBResultSet results, const char[] error, any data)
{
	if (results == null)
		LogError("Failed to write invasion stats: %s", error);
}

// ---------------------------------------------------------------------------
// Stats and status commands
// ---------------------------------------------------------------------------

Action Cmd_InvStats(int client, int args)
{
	char auth[32];
	if (!GetAuth(client, auth, sizeof(auth)))
	{
		ReplyToCommand(client, "[SM] sm_invstats must be run by a player.");
		return Plugin_Handled;
	}

	if (g_hDb == null)
	{
		PrintToChat(client, "%s Stats are unavailable (no database).", TAG);
		return Plugin_Handled;
	}

	char query[256];
	Format(query, sizeof(query),
		"SELECT invasions, kills, incaps, damage, deaths FROM players WHERE steamid = '%s'", auth);
	g_hDb.Query(OnMyStats, query, GetClientUserId(client));

	return Plugin_Handled;
}

void OnMyStats(Database db, DBResultSet results, const char[] error, any data)
{
	int client = GetClientOfUserId(data);
	if (client < 1 || !IsClientInGame(client))
		return;

	if (results == null)
	{
		LogError("sm_invstats query failed: %s", error);
		PrintToChat(client, "%s Could not read your stats.", TAG);
		return;
	}

	if (!results.FetchRow())
	{
		PrintToChat(client, "%s You have not invaded yet.", TAG);
		return;
	}

	PrintToChat(client, "%s Your totals - Invasions: \x04%d\x01 | Kills: \x04%d\x01 | Incaps: \x04%d\x01 | Damage: \x04%d\x01 | Deaths: \x04%d\x01",
		TAG, results.FetchInt(0), results.FetchInt(1), results.FetchInt(2),
		results.FetchInt(3), results.FetchInt(4));
}

Action Cmd_InvTop(int client, int args)
{
	if (client < 1 || !IsClientInGame(client))
		return Plugin_Handled;

	if (g_hDb == null)
	{
		PrintToChat(client, "%s The leaderboard is unavailable (no database).", TAG);
		return Plugin_Handled;
	}

	g_hDb.Query(OnTopStats,
		"SELECT name, kills, incaps, damage FROM players ORDER BY kills DESC, damage DESC LIMIT 10",
		GetClientUserId(client));

	return Plugin_Handled;
}

void OnTopStats(Database db, DBResultSet results, const char[] error, any data)
{
	int client = GetClientOfUserId(data);
	if (client < 1 || !IsClientInGame(client))
		return;

	if (results == null)
	{
		LogError("sm_invtop query failed: %s", error);
		PrintToChat(client, "%s Could not read the leaderboard.", TAG);
		return;
	}

	PrintToChat(client, "%s Top invaders by kills:", TAG);

	int rank = 0;
	char name[MAX_NAME_LENGTH];
	while (results.FetchRow())
	{
		results.FetchString(0, name, sizeof(name));
		PrintToChat(client, "\x01%d. \x05%s\x01 - Kills: \x04%d\x01 | Incaps: \x04%d\x01 | Damage: \x04%d\x01",
			++rank, name, results.FetchInt(1), results.FetchInt(2), results.FetchInt(3));
	}

	if (rank == 0)
		PrintToChat(client, "%s No invasions recorded yet.", TAG);
}

Action Cmd_InvStatus(int client, int args)
{
	if (client < 1 || !IsClientInGame(client))
		return Plugin_Handled;

	int optedIn;
	int total = CountHumanSurvivors(optedIn);
	PrintToChat(client, "%s Invasions %s - \x04%d\x01/\x04%d\x01 survivors opted in (need %.0f%%).",
		TAG, InvasionsAllowed() ? "\x04OPEN\x01" : "\x04CLOSED\x01", optedIn, total, g_fOptInRatio * 100.0);

	int found = 0;
	InvasionSession session;
	char clock[16];

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || !GetSession(i, session))
			continue;

		found++;
		FormatClock(g_iTime - session.secondsElapsed, clock, sizeof(clock));
		PrintToChat(client, "\x05%N\x01 - Lives: \x04%d\x01/\x04%d\x01 | Time left: \x04%s\x01 | Kills: \x04%d\x01 | %s",
			i, g_iLives - session.livesUsed, g_iLives, clock, session.kills,
			IsGhost(i) ? "ghost" : "spawned");
	}

	if (found == 0)
		PrintToChat(client, "%s No active invaders.", TAG);

	return Plugin_Handled;
}

Action Cmd_InvEnd(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[SM] Usage: sm_inv_end <target>");
		return Plugin_Handled;
	}

	char arg[MAX_NAME_LENGTH];
	GetCmdArg(1, arg, sizeof(arg));

	int target = FindTarget(client, arg, true);
	if (target == -1)
		return Plugin_Handled;

	InvasionSession session;
	if (!GetSession(target, session))
	{
		ReplyToCommand(client, "[SM] %N has no active invasion.", target);
		return Plugin_Handled;
	}

	EndInvasion(target, "Ended by admin");
	return Plugin_Handled;
}

Action Cmd_InvDebug(int client, int args)
{
	g_bDebug = !g_bDebug;

	ReplyToCommand(client, "[SM] Invasion debug logging is now %s.", g_bDebug ? "ON" : "OFF");
	LogMessage("Invasion debug logging %s.", g_bDebug ? "enabled" : "disabled");

	return Plugin_Handled;
}
