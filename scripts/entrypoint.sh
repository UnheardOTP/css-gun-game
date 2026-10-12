#!/bin/bash
# Container entrypoint: update game -> install addons -> sync maps -> overlay config -> run srcds.
set -euo pipefail

SERVER_DIR=${SERVER_DIR:-/home/steam/css}
CSTRIKE=$SERVER_DIR/cstrike
OVERLAY=/home/steam/overlay
SCRIPTS=/home/steam/scripts

: "${SRCDS_AUTO_UPDATE:=1}"        # 1 = run steamcmd app_update on every start
: "${SRCDS_VALIDATE:=0}"           # 1 = also validate game files (slower)
: "${SRCDS_PORT:=27015}"
: "${SRCDS_MAXPLAYERS:=24}"
: "${SRCDS_TICKRATE:=66}"
: "${SRCDS_STARTMAP:=}"            # empty = first map of the mapcycle
: "${SRCDS_HOSTNAME:=CS:S GunGame}"
: "${SRCDS_RCON_PASSWORD:=}"       # empty = rcon disabled
: "${SRCDS_PASSWORD:=}"
: "${SRCDS_FASTDL_URL:=}"
: "${SRCDS_LAN:=0}"
: "${SRCDS_EXTRA_ARGS:=}"
: "${AUTO_MAPCYCLE:=1}"            # 1 = build cfg/mapcycle.txt from maps (unless config/cfg/mapcycle.txt exists)
: "${FETCH_MAPS:=1}"               # 1 = download maps listed in maps/maps.txt that are missing
: "${INCLUDE_STOCK_MAPS:=1}"       # 1 = stock CS:S maps are added to the generated mapcycle
: "${STOCK_MAPS:=cs_italy cs_office cs_assault cs_militia de_dust2 de_dust de_aztec de_inferno de_nuke de_train de_cbble de_prodigy de_piranesi}"
: "${ENABLE_SM_PLUGINS:=mapchooser rockthevote nominations}"  # stock SourceMod plugins to enable (from plugins/disabled)
: "${MAPS_BASE_URL:=https://main.fastdl.me/maps}"

log() { echo "[entrypoint] $*"; }

# --- 1. game update ---------------------------------------------------------
if [ "$SRCDS_AUTO_UPDATE" = "1" ] || [ ! -f "$SERVER_DIR/srcds_run" ]; then
    log "Updating Counter-Strike: Source dedicated server (app 232330)..."
    validate=""; [ "$SRCDS_VALIDATE" = "1" ] && validate="validate"
    for i in 1 2 3; do
        "$STEAMCMD_DIR/steamcmd.sh" +force_install_dir "$SERVER_DIR" +login anonymous +app_update 232330 $validate +quit
        [ -f "$SERVER_DIR/srcds_run" ] && break
        log "srcds_run not found after steamcmd attempt $i; retrying with validate"; validate="validate"; sleep 5
    done
fi
if [ ! -f "$SERVER_DIR/srcds_run" ]; then
    log "ERROR: server is not installed ($SERVER_DIR/srcds_run is missing)."
    log "Running as: $(id)"
    log "Mount: $(stat -f -c '%T' "$SERVER_DIR" 2>&1)  owner: $(stat -c '%U:%G %a' "$SERVER_DIR" 2>&1)"
    log "Free space: $(df -h "$SERVER_DIR" | tail -n1)"
    log "Contents of $SERVER_DIR:"; ls -la "$SERVER_DIR" | head -30
    log "Contents of $SERVER_DIR/steamapps:"; ls -la "$SERVER_DIR/steamapps" 2>&1 | head -20
    found=$(find "$SERVER_DIR" -maxdepth 4 -name srcds_run 2>/dev/null | head -3)
    log "srcds_run found elsewhere: ${found:-nowhere}"
    log "Tip: on Unraid use a direct path such as /mnt/cache/appdata/... instead of /mnt/user/... for the game folder."
    exit 1
fi

# steamclient.so for the Steam API
mkdir -p "$HOME/.steam/sdk32"
for f in "$STEAMCMD_DIR/linux32/steamclient.so" "$SERVER_DIR/bin/steamclient.so"; do
    [ -f "$f" ] && ln -sf "$f" "$HOME/.steam/sdk32/steamclient.so" && break
done

# --- 2. Metamod / SourceMod / GunGame (always refreshed from the image) ------
log "Installing $(cat $OVERLAY/metamod.version), $(cat $OVERLAY/sourcemod.version), GunGame:SM $(cut -c1-8 $OVERLAY/gungame.version)"
cp -a "$OVERLAY/." "$CSTRIKE/"
# We run the 32-bit srcds; the 64-bit Metamod loader only logs a harmless "wrong ELF class" error.
rm -f "$CSTRIKE/addons/metamod_x64.vdf"
# GunGame's end-of-game map vote needs SourceMod's mapchooser, which ships disabled.
for plugin in ${ENABLE_SM_PLUGINS}; do
    src="$CSTRIKE/addons/sourcemod/plugins/disabled/$plugin.smx"
    [ -f "$src" ] && mv -f "$src" "$CSTRIKE/addons/sourcemod/plugins/$plugin.smx"
done

# --- 3. maps -----------------------------------------------------------------
"$SCRIPTS/sync-maps.sh"

# --- 4. user config overlay (config/ mirrors cstrike/) ------------------------
# First run: seed /config with the image defaults for anything missing, so the host folder is the single source of truth.
if [ -d /config ]; then
    cp -rn /home/steam/default-config/. /config/ 2>/dev/null || true
    cp -a /config/. "$CSTRIKE/"
fi
# generated settings from environment variables (server.cfg ends with: exec docker_env.cfg)
{
    echo "// Generated from environment variables on every start. Edit .env, not this file."
    echo "hostname \"$SRCDS_HOSTNAME\""
    echo "rcon_password \"$SRCDS_RCON_PASSWORD\""
    echo "sv_password \"$SRCDS_PASSWORD\""
    echo "sv_lan $SRCDS_LAN"
    if [ -n "$SRCDS_FASTDL_URL" ]; then
        echo "sv_downloadurl \"$SRCDS_FASTDL_URL\""
        echo "sv_allowdownload 1"
        echo "sv_allowupload 0"
    fi
} > "$CSTRIKE/cfg/docker_env.cfg"

# --- 5. launch ---------------------------------------------------------------
if [ -z "$SRCDS_STARTMAP" ]; then
    SRCDS_STARTMAP=$(grep -v '^\s*\(//\|$\)' "$CSTRIKE/cfg/mapcycle.txt" | head -n1 | awk '{print $1}')
    SRCDS_STARTMAP=${SRCDS_STARTMAP:-de_dust2}
fi
cd "$SERVER_DIR"
log "Starting srcds on port $SRCDS_PORT, map $SRCDS_STARTMAP, $SRCDS_MAXPLAYERS slots"
# shellcheck disable=SC2086
exec ./srcds_run -game cstrike -console -usercon -norestart \
    -port "$SRCDS_PORT" -tickrate "$SRCDS_TICKRATE" +maxplayers "$SRCDS_MAXPLAYERS" \
    +map "$SRCDS_STARTMAP" $SRCDS_EXTRA_ARGS
