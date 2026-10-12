/**
 * GunGame FFA helper for CS:S
 *
 * Counter-Strike: Source has no free-for-all mode, so this plugin makes a team-less gun game:
 *  - hides the team / class menus and auto-assigns joiners to the smaller team
 *  - respawns players shortly after they die (no waiting for the round to end)
 *  - gives a short spawn protection
 * Pair it with mp_friendlyfire 1 (server.cfg) and "FFA" "1" (gungame.config.txt) so everybody is an enemy.
 *
 * ConVars (written to cfg/sourcemod/gg_ffa.cfg on first run):
 *   sm_ggffa_enabled           1     master switch
 *   sm_ggffa_respawn_delay     2.0   seconds before a dead player respawns (0 = off)
 *   sm_ggffa_spawn_protection  2.0   seconds of invulnerability after spawning (0 = off)
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <cstrike>

public Plugin myinfo =
{
    name        = "GunGame FFA helper",
    author      = "css-gun-game",
    description = "No team selection, auto respawn and spawn protection for gun game on CS:S",
    version     = "1.0.0",
    url         = "https://github.com/UnheardOTP/css-gun-game"
};

ConVar g_cvEnabled;
ConVar g_cvRespawnDelay;
ConVar g_cvProtection;

bool g_bWantsSpec[MAXPLAYERS + 1];
int  g_iAssignTries[MAXPLAYERS + 1];

public void OnPluginStart()
{
    g_cvEnabled      = CreateConVar("sm_ggffa_enabled", "1", "Enable the GunGame FFA helper", _, true, 0.0, true, 1.0);
    g_cvRespawnDelay = CreateConVar("sm_ggffa_respawn_delay", "2.0", "Seconds before a dead player respawns (0 = disabled)", _, true, 0.0, true, 30.0);
    g_cvProtection   = CreateConVar("sm_ggffa_spawn_protection", "2.0", "Seconds of spawn protection (0 = disabled)", _, true, 0.0, true, 10.0);
    AutoExecConfig(true, "gg_ffa");

    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_death", Event_PlayerDeath);

    AddCommandListener(Cmd_JoinTeam, "jointeam");
    AddCommandListener(Cmd_ChooseTeam, "chooseteam");

    // swallow the team and class selection screens
    HookUserMessage(GetUserMessageId("VGUIMenu"), Hook_VGUIMenu, true);
}

public void OnClientDisconnect(int client)
{
    g_bWantsSpec[client] = false;
    g_iAssignTries[client] = 0;
}

public Action Hook_VGUIMenu(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init)
{
    if (!g_cvEnabled.BoolValue)
    {
        return Plugin_Continue;
    }

    char name[32];
    msg.ReadString(name, sizeof(name));
    if (StrEqual(name, "team") || StrEqual(name, "class_ter") || StrEqual(name, "class_ct"))
    {
        return Plugin_Handled;
    }
    return Plugin_Continue;
}

public Action Cmd_JoinTeam(int client, const char[] command, int argc)
{
    if (!g_cvEnabled.BoolValue || client < 1 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Continue;
    }

    char arg[8];
    GetCmdArg(1, arg, sizeof(arg));
    if (StringToInt(arg) == CS_TEAM_SPECTATOR)
    {
        g_bWantsSpec[client] = true;
        return Plugin_Continue;
    }

    // any attempt to pick a side just means "let me play"
    g_bWantsSpec[client] = false;
    if (GetClientTeam(client) < CS_TEAM_T)
    {
        AssignToTeam(client);
    }
    return Plugin_Handled;
}

public Action Cmd_ChooseTeam(int client, const char[] command, int argc)
{
    if (!g_cvEnabled.BoolValue || client < 1 || IsFakeClient(client))
    {
        return Plugin_Continue;
    }
    return Plugin_Handled;
}

public void OnClientPutInServer(int client)
{
    if (client < 1 || IsFakeClient(client))
    {
        return;
    }

    g_bWantsSpec[client] = false;
    g_iAssignTries[client] = 0;
    CreateTimer(1.0, Timer_Assign, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Assign(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client) || !g_cvEnabled.BoolValue || g_bWantsSpec[client])
    {
        return Plugin_Stop;
    }
    if (GetClientTeam(client) >= CS_TEAM_T)
    {
        return Plugin_Stop;
    }
    if (++g_iAssignTries[client] > 15)
    {
        return Plugin_Stop;
    }

    AssignToTeam(client);
    return Plugin_Continue;
}

void AssignToTeam(int client)
{
    int t  = GetTeamClientCount(CS_TEAM_T);
    int ct = GetTeamClientCount(CS_TEAM_CT);
    ChangeClientTeam(client, (t <= ct) ? CS_TEAM_T : CS_TEAM_CT);
    CreateTimer(0.3, Timer_Respawn, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    float delay = g_cvRespawnDelay.FloatValue;
    if (!g_cvEnabled.BoolValue || delay <= 0.0)
    {
        return;
    }

    int userid = event.GetInt("userid");
    CreateTimer(delay, Timer_Respawn, userid, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Respawn(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client) || IsPlayerAlive(client) || GetClientTeam(client) < CS_TEAM_T)
    {
        return Plugin_Stop;
    }

    CS_RespawnPlayer(client);
    return Plugin_Stop;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    float time = g_cvProtection.FloatValue;
    if (!g_cvEnabled.BoolValue || time <= 0.0)
    {
        return;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || !IsPlayerAlive(client))
    {
        return;
    }

    SetEntProp(client, Prop_Data, "m_takedamage", 0, 1);
    CreateTimer(time, Timer_EndProtection, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_EndProtection(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client))
    {
        SetEntProp(client, Prop_Data, "m_takedamage", 2, 1);
    }
    return Plugin_Stop;
}
