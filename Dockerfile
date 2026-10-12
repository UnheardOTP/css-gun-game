# syntax=docker/dockerfile:1
# Counter-Strike: Source dedicated server + Metamod:Source + SourceMod + GunGame:SM
#
# Build args (all optional):
#   MMS_BRANCH / SM_BRANCH  Metamod / SourceMod stable branch to track (latest build of it is fetched)
#   GUNGAME_REPO / GUNGAME_REF  GunGame:SM source repo + git ref (default: master)
#   INSTALL_GAME=0          skip baking the ~3GB game install into the image (first start downloads it)
# To pick up newer Metamod/SourceMod/GunGame builds: docker compose build --no-cache

############################ 1) compile GunGame:SM ############################
FROM debian:bookworm-slim AS plugins
ARG SM_BRANCH=1.12
ARG GUNGAME_REPO=https://github.com/altexdim/sourcemod-plugin-gungame.git
ARG GUNGAME_REF=master
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git libc6:i386 libstdc++6:i386 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN set -eux; \
    f="$(curl -fsSL https://sm.alliedmods.net/smdrop/${SM_BRANCH}/sourcemod-latest-linux)"; \
    curl -fsSL "https://sm.alliedmods.net/smdrop/${SM_BRANCH}/${f}" | tar xz; \
    echo "${f}" > /build/sourcemod.version
RUN git clone "${GUNGAME_REPO}" gungame \
 && git -C gungame checkout "${GUNGAME_REF}" \
 && git -C gungame rev-parse HEAD > /build/gungame.version
RUN set -eux; \
    SP=/build/addons/sourcemod/scripting; \
    cd /build/gungame/addons/sourcemod/scripting; \
    mkdir -p /out/plugins; \
    for p in gungame gungame_afk gungame_bot gungame_config gungame_display_winner gungame_logging \
             gungame_mapvoting gungame_stats gungame_tk gungame_warmup_configs gungame_winner_effects; do \
        $SP/spcomp -i$SP/include -iinclude "$p.sp" -o"/out/plugins/$p.smx" | tail -n 3; \
        test -s "/out/plugins/$p.smx"; \
    done
# Our own plugins (src/*.sp) are compiled the same way; drop another .sp into src/ and rebuild to add it.
COPY src/ /build/src/
RUN set -eux; \
    SP=/build/addons/sourcemod/scripting; \
    for f in /build/src/*.sp; do \
        p="$(basename "$f" .sp)"; \
        $SP/spcomp -i$SP/include "$f" -o"/out/plugins/$p.smx" | tail -n 5; \
        test -s "/out/plugins/$p.smx"; \
    done

############################ 2) runtime ############################
FROM debian:bookworm-slim
ARG MMS_BRANCH=1.12
ARG SM_BRANCH=1.12
ARG INSTALL_GAME=1
ARG PUID=1000
ARG PGID=1000

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl bzip2 procps tini nano \
        lib32gcc-s1 lib32stdc++6 libc6:i386 libcurl4:i386 libsdl2-2.0-0:i386 \
 && rm -rf /var/lib/apt/lists/* \
 && (getent group ${PGID} >/dev/null || groupadd -g ${PGID} steam) \
 && useradd -m -u ${PUID} -g ${PGID} -s /bin/bash steam

USER steam
ENV HOME=/home/steam \
    STEAMCMD_DIR=/home/steam/steamcmd \
    SERVER_DIR=/home/steam/css \
    APPID=232330
RUN mkdir -p ${STEAMCMD_DIR} ${SERVER_DIR} /home/steam/.steam/sdk32 \
 && curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar xz -C ${STEAMCMD_DIR} \
 && ${STEAMCMD_DIR}/steamcmd.sh +quit || true

# Bake the dedicated server into the image (steamcmd's first run often needs a retry).
RUN if [ "${INSTALL_GAME}" = "1" ]; then \
      for i in 1 2 3 4 5; do \
        ${STEAMCMD_DIR}/steamcmd.sh +force_install_dir ${SERVER_DIR} +login anonymous +app_update ${APPID} validate +quit \
          && test -f ${SERVER_DIR}/srcds_run && break; \
        echo "steamcmd attempt $i failed, retrying"; sleep 10; \
      done; test -f ${SERVER_DIR}/srcds_run; \
    fi

# Metamod:Source + SourceMod + compiled GunGame:SM go into an overlay that is copied over the
# server on every start (so they survive game updates and are never stale in the data volume).
RUN set -eux; mkdir -p /home/steam/overlay; cd /home/steam/overlay; \
    f="$(curl -fsSL https://mms.alliedmods.net/mmsdrop/${MMS_BRANCH}/mmsource-latest-linux)"; \
    curl -fsSL "https://mms.alliedmods.net/mmsdrop/${MMS_BRANCH}/${f}" | tar xz; echo "$f" > /home/steam/overlay/metamod.version; \
    f="$(curl -fsSL https://sm.alliedmods.net/smdrop/${SM_BRANCH}/sourcemod-latest-linux)"; \
    curl -fsSL "https://sm.alliedmods.net/smdrop/${SM_BRANCH}/${f}" | tar xz; echo "$f" > /home/steam/overlay/sourcemod.version
COPY --from=plugins --chown=steam:steam /out/plugins/ /home/steam/overlay/addons/sourcemod/plugins/
COPY --from=plugins --chown=steam:steam /build/gungame/addons/sourcemod/translations/ /home/steam/overlay/addons/sourcemod/translations/
COPY --from=plugins --chown=steam:steam /build/gungame/sound/ /home/steam/overlay/sound/
COPY --from=plugins /build/gungame.version /home/steam/overlay/gungame.version
COPY --chown=steam:steam scripts/ /home/steam/scripts/
COPY --chown=steam:steam config/ /home/steam/default-config/
COPY --chown=steam:steam maps/maps.txt /home/steam/default-maps/maps.txt
RUN chmod +x /home/steam/scripts/*.sh

WORKDIR ${SERVER_DIR}
EXPOSE 27015/udp 27015/tcp
ENTRYPOINT ["/usr/bin/tini", "--", "/home/steam/scripts/entrypoint.sh"]
