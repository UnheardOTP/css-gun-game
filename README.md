# Counter-Strike: Source GunGame server (Docker)

A dedicated CS:S server with **Metamod:Source + SourceMod 1.12 + GunGame:SM**, a curated set of gun game maps, and one folder (`config/`) for everything you'd want to tweak.

| Component | Source | Version policy |
|---|---|---|
| CS:S dedicated server | SteamCMD app **232330** (anonymous) | baked in at build, **updated on every container start** |
| Metamod:Source / SourceMod | alliedmods.net stable `1.12` branch | newest build at image build time |
| GunGame:SM | [altexdim/sourcemod-plugin-gungame](https://github.com/altexdim/sourcemod-plugin-gungame) (compiled from source at build) | `master` (last upstream commit is from 2017, but it compiles and loads cleanly on SM 1.12) |

## Quick start

```bash
cp .env.example .env        # set SRCDS_HOSTNAME and SRCDS_RCON_PASSWORD
docker compose up -d --build
docker compose logs -f      # first start downloads the maps in maps/maps.txt
```

Connect with `connect <host-ip>:27015`. Open **27015 UDP** (play) and **27015 TCP** (rcon) on your firewall.
Server console: `docker attach css-gungame` (detach with `Ctrl-p Ctrl-q`).

## Where to change things

| You want to… | Edit |
|---|---|
| Hostname, rcon/join password, port, slots, FastDL URL | `.env` |
| General server settings (rates, friendly fire, bots…) | `config/cfg/server.cfg` |
| **GunGame rules** (win conditions, warmup, level-down, etc.) | `config/cfg/gungame/css/gungame.config.txt` |
| **Weapon ladder** (order / kills per level) | `config/cfg/gungame/css/gungame.equip.txt` |
| Commands run when GunGame is active / warmup start+end | `config/cfg/gungame/css/gungame.mapconfig.cfg`, `gungame.warmupstart.cfg`, `gungame.warmupend.cfg` |
| Per-map or per-prefix GunGame settings | `config/cfg/gungame/maps/<map or prefix>.config.txt` (see upstream `doc/faq/map_prefixes_config.txt`) |
| **Free-for-all / team behaviour** (no team menu, respawn delay, spawn protection) | `config/cfg/sourcemod/gg_ffa.cfg` |
| Admins | `config/addons/sourcemod/configs/admins_simple.ini` |
| Map rotation | automatic (see below), or create `config/cfg/mapcycle.txt` |

`config/` **mirrors `cstrike/`** — every file in it is copied over the server on each container start, so you can also drop in any other file (e.g. `config/addons/sourcemod/configs/maplists.cfg`, extra `.smx` plugins under `config/addons/sourcemod/plugins/`). Apply changes with `docker compose restart`.

## Free-for-all (no team selection)

CS:S has no real FFA mode, so this setup fakes one: the team and class menus are hidden, joiners are auto-assigned to the smaller team, dead players respawn after ~2 s, and friendly fire is on with GunGame's `"FFA" "1"`, so everybody can shoot everybody and every kill counts. The `gg_ffa` plugin (`src/gg_ffa.sp`) does the join/respawn part; rounds never end on their own (`mp_ignore_round_win_conditions 1`). Note that **bots never shoot their own team**, so with bots you effectively get T vs CT among bots.

To go back to classic team-based gun game: `sm_ggffa_enabled "0"` in `config/cfg/sourcemod/gg_ffa.cfg`, `mp_friendlyfire 0` in `server.cfg`, and `"FFA" "0"` in `gungame.config.txt`. Any extra `.sp` you drop into `src/` is compiled into the image on the next build.

## Adding maps

- **Easiest:** drop a `.bsp` or `.bsp.bz2` into `maps/` and restart. It is installed and added to the mapcycle automatically.
- **By name:** add a line to `maps/maps.txt` (`mapname`, or `mapname https://direct/url.bsp.bz2`); missing ones are downloaded on start (default source: [fastdl.me](https://fastdl.me), which mirrors GameBanana maps).
- **Extra content** (models, materials, sounds a map needs): put it in `custom/` (mounted as `cstrike/custom/user`).
- Mapcycle is regenerated from `maps/` unless `config/cfg/mapcycle.txt` exists.
- Players download maps from the game server by default, which is slow. For fast transfers: `docker compose --profile fastdl up -d`, then set `SRCDS_FASTDL_URL=http://<host>:8080` in `.env` and restart.

### Starter set (`maps/maps.txt`, 23 maps)
16 `gg_` maps (`gg_sandstorm`, `gg_dust2`, `gg_snow`, `gg_bunker`, `gg_apollo`, `gg_underpass`, `gg_temple`, `gg_lego`, `gg_office`, `gg_crossfire`, `gg_tunnel`, `gg_trainstation`, `gg_cs_arena`, `gg_mansion`, `gg_village`, `gg_simpsons`) plus classic small arenas (`aim_ag_texture2`, `aim_ag_texture_city`, `aim_ak-colt`, `aim_map`, `fy_iceworld`, `fy_snow`, `fy_dust`), The stock CS:S maps are **not** in the rotation by default (set `INCLUDE_STOCK_MAPS=1` to add them); they are used only if `maps/` is empty, so the mapcycle is never empty.

How they were picked: valid BSP, at least ~15 spawns per team, small download (≤ ~9 MB), and each one **loaded on the running server** during testing. Candidates that failed were dropped (`gg_island` crashes srcds; `gg_complex` has no CT spawns). **They have not been playtested with players** — judge layout quality yourself and comment out duds with `#`. Map credits are on GameBanana (the id is next to each entry).

## Prebuilt image (GHCR)

GitHub Actions (`.github/workflows/publish.yml`) builds and pushes `ghcr.io/<owner>/<repo>` on every push to `main`, weekly (from scratch, to pick up new game/Metamod/SourceMod builds), and on demand. Tags: `latest`, short commit sha, and the build date.

On the server you only need `docker-compose.ghcr.yml`, `.env`, `config/` and `maps/`:

```bash
echo 'CSS_IMAGE=ghcr.io/<owner>/<repo>:latest' >> .env
docker compose -f docker-compose.ghcr.yml pull
docker compose -f docker-compose.ghcr.yml up -d
```
New GHCR packages are private by default: either make the package public (repo → Packages → Package settings) or `docker login ghcr.io` on the server with a token that has `read:packages`.

## Updating

```bash
docker compose build --no-cache && docker compose up -d   # newest Metamod/SourceMod/GunGame
```
The game itself updates on every start (`SRCDS_AUTO_UPDATE=1`). Game files live in the `css-data` volume; `docker compose down -v` wipes them (config, maps and fastdl are on the host and stay).

## Notes
- Containers run as uid/gid 1000 (`PUID`/`PGID` in `.env` if your host user differs) so `maps/` and `config/` stay writable.
- The container's `sv_pure` is `0` so custom map content works; raise it in `server.cfg` if you only run stock-content maps.
- Harmless startup noise: `vscript_convar_allowlist.txt`, `mapspawn.nut`, `info_ladder` messages come from the stock game / old maps.
