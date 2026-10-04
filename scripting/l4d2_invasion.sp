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

// Tanks are made playable only during the finale by swapping which data config
// l4dinfectedbots reads. That plugin exposes no cvar for coop_versus_tank_playable
// - it is a KeyValues key - but l4d_infectedbots_read_data has a change hook that
// live-reloads the whole data config. So we ship two configs that differ only in
// that one key and flip between them. l4dinfectedbots itself is never modified.
#define IB_DATA_CVAR        "l4d_infectedbots_read_data"
#define IB_DATA_FINALE      "coop_finale"       // data/l4dinfectedbots/coop_finale.cfg
#define IB_DATA_DEFAULT     ""                  // empty = <gamemode>.cfg, i.e. coop.cfg

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
ConVar g_cvTankFinaleOnly;
ConVar g_cvMenu;

ConVar g_cvForceDifficulty;

ConVar g_cvIbReadData;      // l4dinfectedbots' own cvar, looked up at load
ConVar g_cvZDifficulty;     // the game's z_difficulty, looked up at load

bool  g_bEnable;
int   g_iLives;
int   g_iTime;
float g_fRespawn;
int   g_iEndAction;
int   g_iCooldown;
float g_fOptInRatio;
int   g_iMaxInvaders;
bool  g_bTankFinaleOnly;
bool  g_bTankEnabled;       // whether the finale data config is currently loaded
bool  g_bMenuEnabled;
char  g_sForceDifficulty[16];   // empty = leave z_difficulty alone

bool g_bOptIn[MAXPLAYERS + 1];
bool g_bMenuShown[MAXPLAYERS + 1];      // side menu already offered this round
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

	// l4dinfectedbots may load after us, so this can be null here; OnAllPluginsLoaded
	// picks it up. Without it, Tank swapping is skipped rather than erroring.
	g_cvIbReadData = FindConVar(IB_DATA_CVAR);
	g_cvZDifficulty = FindConVar("z_difficulty");
	if (g_cvZDifficulty == null)
		LogError("Could not find \"z_difficulty\" - l4d2_invasion_force_difficulty will do nothing.");
}

public void OnAllPluginsLoaded()
{
	if (g_cvIbReadData == null)
		g_cvIbReadData = FindConVar(IB_DATA_CVAR);

	if (g_cvIbReadData == null)
		LogError("Could not find \"%s\". l4dinfectedbots may not be loaded - finale-only Tank access is disabled.", IB_DATA_CVAR);
	else
		SetTankPlayable(false);      // always start a session with Tanks off
}

public void OnPluginEnd()
{
	// Never leave the finale data config loaded behind us.
	SetTankPlayable(false);
}

void CreateCvars()
{
	g_cvEnable      = CreateConVar("l4d2_invasion_enable",       "1",    "Master switch for invasion mode.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvLives       = CreateConVar("l4d2_invasion_lives",        "10",   "Deaths allowed per invasion.", FCVAR_NOTIFY, true, 1.0);
	g_cvTime        = CreateConVar("l4d2_invasion_time",         "360",  "Invasion length in seconds of active time. 0 = no time limit, lives only.", FCVAR_NOTIFY, true, 0.0);
	g_cvRespawn     = CreateConVar("l4d2_invasion_respawn",      "10.0", "Invader respawn time in seconds.", FCVAR_NOTIFY, true, 0.0);
	g_cvEndAction   = CreateConVar("l4d2_invasion_end_action",   "1",    "When the budget runs out: 0 = move to spectator, 1 = kick.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvCooldown    = CreateConVar("l4d2_invasion_cooldown",     "600",  "Seconds before the same SteamID can invade again.", FCVAR_NOTIFY, true, 0.0);
	g_cvOptInRatio  = CreateConVar("l4d2_invasion_optin_ratio",  "0.5",  "Fraction of human survivors who must have !invadable on.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvMaxInvaders = CreateConVar("l4d2_invasion_max_invaders", "1",    "Max simultaneous human invaders.", FCVAR_NOTIFY, true, 1.0);
	g_cvTankFinaleOnly = CreateConVar("l4d2_invasion_tank_finale", "1", "1 = invaders can play Tank during the finale only, 0 = never.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvMenu = CreateConVar("l4d2_invasion_menu", "1", "1 = offer the side-select menu on each player's first spawn of the round.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvForceDifficulty = CreateConVar("l4d2_invasion_force_difficulty", "", "Re-apply this difficulty on every round start. Easy/Normal/Hard/Impossible (\"Expert\" is accepted and means Impossible). Empty = leave z_difficulty alone.", FCVAR_NOTIFY);

	g_cvEnable.AddChangeHook(OnCvarChanged);
	g_cvLives.AddChangeHook(OnCvarChanged);
	g_cvTime.AddChangeHook(OnCvarChanged);
	g_cvRespawn.AddChangeHook(OnCvarChanged);
	g_cvEndAction.AddChangeHook(OnCvarChanged);
	g_cvCooldown.AddChangeHook(OnCvarChanged);
	g_cvOptInRatio.AddChangeHook(OnCvarChanged);
	g_cvMaxInvaders.AddChangeHook(OnCvarChanged);
	g_cvTankFinaleOnly.AddChangeHook(OnCvarChanged);
	g_cvMenu.AddChangeHook(OnCvarChanged);
	g_cvForceDifficulty.AddChangeHook(OnCvarChanged);

	AutoExecConfig(true, "l4d2_invasion");
	CacheCvars();
}

void RegisterCommands()
{
	RegConsoleCmd("sm_invade",     Cmd_Invade,    "Reopen the side-select menu.");
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
	HookEvent("player_spawn",         Event_PlayerSpawn);
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

	// Tank access is granted on either finale trigger. Not every finale map
	// fires "finale_start", but they all fire "finale_radio_start", so both are
	// hooked; SetTankPlayable is a no-op when it is already enabled.
	HookEvent("finale_start",         Event_FinaleStart);
	HookEvent("finale_radio_start",   Event_FinaleStart);
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
	g_bTankFinaleOnly = g_cvTankFinaleOnly.BoolValue;
	g_bMenuEnabled = g_cvMenu.BoolValue;
	CacheForcedDifficulty();

	// Turning the feature off mid-campaign must not strand the finale config.
	if (!g_bTankFinaleOnly && g_bTankEnabled)
		SetTankPlayable(false);
}

// ---------------------------------------------------------------------------
// Forced difficulty
// ---------------------------------------------------------------------------
// z_difficulty does not stick on a dedicated server. Difficulty normally comes
// from the lobby, and with direct-IP joins there is no lobby, so the Director
// resets it to Normal as the map loads - after server.cfg has already run. The
// only reliable fix is to re-apply it once the map is up, which is what this
// does, on every round start.

void CacheForcedDifficulty()
{
	char raw[16];
	g_cvForceDifficulty.GetString(raw, sizeof(raw));
	TrimString(raw);

	if (raw[0] == '\0')
	{
		g_sForceDifficulty[0] = '\0';
		return;
	}

	// "Expert" is the name the game's own UI uses; the cvar wants "Impossible".
	// Accepting both avoids setting a value that silently does nothing.
	if (StrEqual(raw, "Expert", false))
		strcopy(raw, sizeof(raw), "Impossible");

	if (!StrEqual(raw, "Easy", false) && !StrEqual(raw, "Normal", false)
		&& !StrEqual(raw, "Hard", false) && !StrEqual(raw, "Impossible", false))
	{
		LogError("l4d2_invasion_force_difficulty: \"%s\" is not a valid difficulty. Use Easy, Normal, Hard or Impossible (or Expert). Ignoring it.", raw);
		g_sForceDifficulty[0] = '\0';
		return;
	}

	strcopy(g_sForceDifficulty, sizeof(g_sForceDifficulty), raw);
	ApplyForcedDifficulty();
}

void ApplyForcedDifficulty()
{
	if (g_sForceDifficulty[0] == '\0' || g_cvZDifficulty == null)
		return;

	char current[16];
	g_cvZDifficulty.GetString(current, sizeof(current));
	if (StrEqual(current, g_sForceDifficulty, false))
		return;

	g_cvZDifficulty.SetString(g_sForceDifficulty);
	DebugLog("Difficulty re-applied: \"%s\" -> \"%s\"", current, g_sForceDifficulty);
}

// round_start usually lands after the Director has set its own value, but the
// ordering is not guaranteed, so check once more a few seconds in.
Action Timer_ReassertDifficulty(Handle timer)
{
	ApplyForcedDifficulty();
	return Plugin_Stop;
}

// ---------------------------------------------------------------------------
// Playable Tank, finale only
// ---------------------------------------------------------------------------

// Swap which data config l4dinfectedbots reads. The two files are identical
// except for coop_versus_tank_playable, so this toggles Tank access and nothing
// else. Writing the cvar fires l4dinfectedbots' own change hook, which reloads.
void SetTankPlayable(bool enable)
{
	if (g_cvIbReadData == null)
		return;

	char current[64];
	g_cvIbReadData.GetString(current, sizeof(current));

	char wanted[64];
	strcopy(wanted, sizeof(wanted), enable ? IB_DATA_FINALE : IB_DATA_DEFAULT);

	// Reloading the data config is not free, so only write on an actual change.
	if (StrEqual(current, wanted))
	{
		g_bTankEnabled = enable;
		return;
	}

	g_cvIbReadData.SetString(wanted);
	g_bTankEnabled = enable;
	DebugLog("Playable Tank %s (l4dinfectedbots data config -> \"%s\")",
		enable ? "ENABLED for the finale" : "disabled", wanted);
}

void Event_FinaleStart(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bTankFinaleOnly || g_bTankEnabled)
		return;

	SetTankPlayable(true);
	PrintToChatAll("%s \x05Finale!\x01 Invaders can now become the Tank.", TAG);
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
	g_bMenuShown[client] = false;
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

// Can this player invade right now, and if not, why not? The menu uses the
// reason as the greyed-out item's label, so a player is never moved to the
// infected team only to be bounced to spectator a tenth of a second later.
// Mirrors the checks in Timer_CheckJoin, in the same order.
bool CanInvade(int client, char[] reason, int maxlen)
{
	InvasionSession session;
	if (GetSession(client, session))
	{
		strcopy(reason, maxlen, "already invading");
		return false;
	}

	if (!g_bEnable)
	{
		strcopy(reason, maxlen, "disabled");
		return false;
	}

	int remaining = GetCooldownRemaining(client);
	if (remaining > 0)
	{
		char clock[16];
		FormatClock(remaining, clock, sizeof(clock));
		Format(reason, maxlen, "available in %s", clock);
		return false;
	}

	int active = CountActiveInvaders();
	if (active >= g_iMaxInvaders)
	{
		Format(reason, maxlen, "slots full, %d/%d", active, g_iMaxInvaders);
		return false;
	}

	int optedIn;
	int total = CountHumanSurvivors(optedIn);

	// The invader stops counting as a survivor the moment they switch, so a
	// lone human can never invade - there would be nobody left to invade.
	if (total <= 1)
	{
		strcopy(reason, maxlen, "needs another survivor");
		return false;
	}

	// Judge the ratio against the survivor count after this player leaves.
	int remainingSurvivors = total - 1;
	int remainingOptedIn = optedIn - (g_bOptIn[client] ? 1 : 0);
	int needed = RoundToCeil(float(remainingSurvivors) * g_fOptInRatio);

	if (remainingOptedIn < needed)
	{
		Format(reason, maxlen, "needs %d more survivor%s to opt in",
			needed - remainingOptedIn, (needed - remainingOptedIn) == 1 ? "" : "s");
		return false;
	}

	strcopy(reason, maxlen, "");
	return true;
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

	SetOptIn(client, !g_bOptIn[client]);
	return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// Side-select menu
// ---------------------------------------------------------------------------
// Shown on each player's first spawn of the round, so picking a side is the
// first thing anyone does and no chat command is needed. !invade reopens it.
// The opt-in toggle is folded into the survivor choices: people kept forgetting
// !invadable, which is what made invasions look broken.

void ShowSideMenu(int client)
{
	if (!g_bMenuEnabled || client < 1 || !IsClientInGame(client) || IsFakeClient(client))
		return;

	g_bMenuShown[client] = true;

	Menu menu = new Menu(MenuHandler_Side);
	menu.SetTitle("L4D2 INVASION - choose your side");

	menu.AddItem("optin",  "Survivor - open to invasion");
	menu.AddItem("optout", "Survivor - no invasions");

	char reason[96];
	char display[128];
	if (CanInvade(client, reason, sizeof(reason)))
	{
		if (g_iTime > 0)
		{
			char clock[16];
			FormatClock(g_iTime, clock, sizeof(clock));
			Format(display, sizeof(display), "INVADE  (%d lives / %s)", g_iLives, clock);
		}
		else
		{
			Format(display, sizeof(display), "INVADE  (%d lives)", g_iLives);
		}
		menu.AddItem("invade", display);
	}
	else
	{
		Format(display, sizeof(display), "INVADE  (%s)", reason);
		menu.AddItem("invade", display, ITEMDRAW_DISABLED);
	}

	menu.ExitButton = true;
	menu.Display(client, 30);
}

int MenuHandler_Side(Menu menu, MenuAction action, int client, int param2)
{
	if (action == MenuAction_End)
	{
		delete menu;
		return 0;
	}
	if (action != MenuAction_Select)
		return 0;
	if (client < 1 || !IsClientInGame(client) || IsFakeClient(client))
		return 0;

	char choice[16];
	menu.GetItem(param2, choice, sizeof(choice));

	if (StrEqual(choice, "invade"))
	{
		StartInvadeFromMenu(client);
		return 0;
	}

	SetOptIn(client, StrEqual(choice, "optin"));
	return 0;
}

// Shared by the menu and sm_invadable so both announce identically.
void SetOptIn(int client, bool optIn)
{
	g_bOptIn[client] = optIn;

	int optedIn;
	int total = CountHumanSurvivors(optedIn);

	PrintToChatAll("%s \x05%N\x01 is %s invasions. (\x04%d\x01/\x04%d\x01 survivors opted in)",
		TAG, client, optIn ? "open to" : "closed to", optedIn, total);
}

void StartInvadeFromMenu(int client)
{
	// Re-check: the menu may have been open for a while and state can change.
	char reason[96];
	if (!CanInvade(client, reason, sizeof(reason)))
	{
		PrintToChat(client, "%s Cannot invade right now (\x05%s\x01).", TAG, reason);
		return;
	}

	// Hand the actual team move to l4dinfectedbots, which owns infected slots
	// in coop. Our player_team gate then validates and opens the session, so
	// there is exactly one code path for starting an invasion.
	FakeClientCommand(client, "sm_ji");
	DebugLog("Side menu: %N chose to invade", client);
}

Action Cmd_Invade(int client, int args)
{
	if (client < 1 || !IsClientInGame(client))
		return Plugin_Handled;

	if (!g_bMenuEnabled)
	{
		PrintToChat(client, "%s The side menu is disabled. Use \x05!ji\x01 to invade.", TAG);
		return Plugin_Handled;
	}

	ShowSideMenu(client);
	return Plugin_Handled;
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1 || !IsClientInGame(client) || IsFakeClient(client))
		return;

	// Once per player per round, and never to someone already invading or
	// already on the infected team - their choice is made.
	if (g_bMenuShown[client] || !g_bMenuEnabled)
		return;
	if (GetClientTeam(client) != TEAM_SURVIVOR)
		return;

	CreateTimer(1.5, Timer_ShowMenu, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

// A short delay: the client is not ready for a menu the instant it spawns.
Action Timer_ShowMenu(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client < 1 || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Stop;
	if (GetClientTeam(client) != TEAM_SURVIVOR || g_bMenuShown[client])
		return Plugin_Stop;

	ShowSideMenu(client);
	return Plugin_Stop;
}

// ---------------------------------------------------------------------------
// Joining the infected team
// ---------------------------------------------------------------------------

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (event.GetBool("disconnect") || event.GetBool("isbot"))
		return;

	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	if (client < 1 || !IsClientInGame(client) || IsFakeClient(client))
		return;

	// Leaving the infected team has to end the invasion. Without this the
	// session stays open, keeps counting against max_invaders, and - now that
	// the time budget can be disabled - never closes at all, so the slot is
	// held forever by someone who is back to playing survivor.
	if (event.GetInt("team") != TEAM_INFECTED)
	{
		InvasionSession session;
		if (GetSession(client, session))
			CreateTimer(0.5, Timer_CheckLeave, userid, TIMER_FLAG_NO_MAPCHANGE);
		return;
	}

	// Run the gate after l4dinfectedbots has finished its own join handling.
	CreateTimer(0.1, Timer_CheckJoin, userid, TIMER_FLAG_NO_MAPCHANGE);
}

// Confirm the player really left rather than flickering teams. The timer is
// NO_MAPCHANGE so it is dropped during a transition, which keeps a session
// alive across maps instead of ending it on the way through.
Action Timer_CheckLeave(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client < 1 || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Stop;
	if (GetClientTeam(client) == TEAM_INFECTED)
		return Plugin_Stop;

	InvasionSession session;
	if (!GetSession(client, session))
		return Plugin_Stop;

	// applyEndAction is false: they have already picked a team, so moving them
	// again would undo their own choice.
	FinishInvasion(client, "Left the infected team", false);
	return Plugin_Stop;
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
	if (g_iTime <= 0)
	{
		PrintHintText(client, "YOU ARE THE INVADER\n%d lives. Every death counts.\nNo time limit - play them how you like.", g_iLives);
		return;
	}

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

	// Offer the side choice again next time each player spawns.
	for (int i = 1; i <= MAXPLAYERS; i++)
		g_bMenuShown[i] = false;

	ApplyForcedDifficulty();
	CreateTimer(5.0, Timer_ReassertDifficulty, _, TIMER_FLAG_NO_MAPCHANGE);

	// A new round means the finale has not started yet, including a finale
	// restart after a wipe. Revoke Tank access until it triggers again.
	if (g_bTankFinaleOnly)
		SetTankPlayable(false);
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

		// g_iTime 0 means lives are the only budget.
		if (g_iTime > 0 && session.secondsElapsed >= g_iTime)
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
	int livesLeft = g_iLives - session.livesUsed;
	if (livesLeft < 0)
		livesLeft = 0;

	if (g_iTime <= 0)
	{
		PrintHintText(client, "Lives: %d/%d", livesLeft, g_iLives);
		return;
	}

	char clock[16];
	FormatClock(g_iTime - session.secondsElapsed, clock, sizeof(clock));
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
		if (g_iTime > 0)
			FormatClock(g_iTime - session.secondsElapsed, clock, sizeof(clock));
		else
			strcopy(clock, sizeof(clock), "no limit");

		PrintToChat(client, "\x05%N\x01 - Lives: \x04%d\x01/\x04%d\x01 | Time left: \x04%s\x01 | Kills: \x04%d\x01 | Incaps: \x04%d\x01 | %s",
			i, g_iLives - session.livesUsed, g_iLives, clock, session.kills, session.incaps,
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
