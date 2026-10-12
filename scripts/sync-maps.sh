#!/bin/bash
# Syncs ./maps (mounted at /maps) into the server, optionally downloading maps listed in maps/maps.txt,
# publishes compressed copies for FastDL (/fastdl), and generates the mapcycle.
set -uo pipefail

SERVER_DIR=${SERVER_DIR:-/home/steam/css}
CSTRIKE=$SERVER_DIR/cstrike
MAPS_SRC=/maps
FASTDL=/fastdl
MAPS_BASE_URL=${MAPS_BASE_URL:-https://main.fastdl.me/maps}
log() { echo "[maps] $*"; }

mkdir -p "$CSTRIKE/maps" "$CSTRIKE/cfg"
[ -d "$MAPS_SRC" ] || { log "no /maps mount, skipping custom maps"; MAPS_SRC=$(mktemp -d); }

is_bsp() { [ "$(head -c4 "$1" 2>/dev/null)" = "VBSP" ]; }

# --- 1. download what maps.txt asks for -----------------------------------------
if [ "${FETCH_MAPS:-1}" = "1" ] && [ -f "$MAPS_SRC/maps.txt" ]; then
    while read -r name url _; do
        case "$name" in ''|\#*) continue;; esac
        case "$url" in \#*) url="";; esac
        [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || { log "skip invalid name: $name"; continue; }
        [ -f "$MAPS_SRC/$name.bsp" ] || [ -f "$MAPS_SRC/$name.bsp.bz2" ] && continue
        url=${url:-$MAPS_BASE_URL/$name.bsp.bz2}
        tmp=$(mktemp)
        if curl -fsSL --retry 2 -m 300 "$url" -o "$tmp"; then
            case "$url" in
                *.bz2) if bzip2 -tq "$tmp" && is_bsp <(bzip2 -dc "$tmp" | head -c4); then
                           chmod 644 "$tmp"; mv "$tmp" "$MAPS_SRC/$name.bsp.bz2"; log "downloaded $name"
                       else log "FAILED $name: not a valid bz2-compressed BSP"; fi;;
                *)     if is_bsp "$tmp"; then chmod 644 "$tmp"; mv "$tmp" "$MAPS_SRC/$name.bsp"; log "downloaded $name"
                       else log "FAILED $name: not a BSP file"; fi;;
            esac
        else
            log "FAILED $name: download error ($url)"
        fi
        rm -f "$tmp"
    done < "$MAPS_SRC/maps.txt"
fi

# --- 2. install every map in /maps into the server ------------------------------
shopt -s nullglob
CUSTOM=()
for f in "$MAPS_SRC"/*.bsp "$MAPS_SRC"/*.bsp.bz2; do
    base=$(basename "$f"); name=${base%.bz2}; name=${name%.bsp}
    dest="$CSTRIKE/maps/$name.bsp"
    if [ ! -f "$dest" ] || [ "$f" -nt "$dest" ]; then
        if [[ "$f" == *.bz2 ]]; then bzip2 -dc "$f" > "$dest.tmp"; else cp "$f" "$dest.tmp"; fi
        if is_bsp "$dest.tmp"; then mv "$dest.tmp" "$dest"; else log "skipping $base (not a valid BSP)"; rm -f "$dest.tmp"; continue; fi
    fi
    CUSTOM+=("$name")
    # FastDL copy
    if [ -d "$FASTDL" ]; then
        mkdir -p "$FASTDL/maps"
        if [[ "$f" == *.bz2 ]]; then cp -n "$f" "$FASTDL/maps/$name.bsp.bz2"
        elif [ ! -f "$FASTDL/maps/$name.bsp.bz2" ]; then bzip2 -c "$f" > "$FASTDL/maps/$name.bsp.bz2"; fi
    fi
done
log "${#CUSTOM[@]} custom map(s) installed"

# --- 3. mapcycle ----------------------------------------------------------------
if [ "${AUTO_MAPCYCLE:-1}" = "1" ] && [ ! -f /config/cfg/mapcycle.txt ]; then
    {
        printf '%s\n' "${CUSTOM[@]}" | sort -u | grep -v '^$' || true
        if [ "${INCLUDE_STOCK_MAPS:-1}" = "1" ]; then
            for m in ${STOCK_MAPS:-}; do [ -f "$CSTRIKE/maps/$m.bsp" ] && echo "$m"; done
        fi
    } > "$CSTRIKE/cfg/mapcycle.txt"
    log "generated mapcycle with $(wc -l < "$CSTRIKE/cfg/mapcycle.txt") maps (put your own at config/cfg/mapcycle.txt to override)"
fi
