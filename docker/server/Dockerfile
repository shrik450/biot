# Builds the `server` mix release. The build stage compiles the umbrella, installs esbuild, and
# runs `mix release`, whose steps build and digest the web assets. The runtime stage carries only
# the self-contained release directory, an unprivileged user, and the libraries the BEAM needs.
FROM elixir:1.20.4-otp-28 AS build

ENV MIX_ENV=prod

WORKDIR /build

# Dependency inputs first, so `mix deps.get` and the esbuild download stay cached until the
# lockfile or an app's dependencies change.
COPY mix.exs mix.lock ./
COPY mix ./mix
COPY config ./config
COPY apps/biot_protocol/mix.exs apps/biot_protocol/
COPY apps/biot_server/mix.exs apps/biot_server/
COPY apps/biot_node/mix.exs apps/biot_node/
COPY apps/biot_web/mix.exs apps/biot_web/

RUN mix local.hex --force \
    && mix local.rebar --force \
    && mix deps.get --only prod

# `assets.deploy` runs during `mix release` and needs the platform esbuild binary already present.
RUN mix esbuild.install --if-missing

COPY . .

RUN mix release server

FROM debian:trixie-slim AS runtime

# libssl3t64 and libstdc++6 and libtinfo6 and zlib1g are what the release's BEAM and NIFs link
# against; ca-certificates is for the server's outbound HTTPS calls; curl is for the health check.
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
      ca-certificates \
      curl \
      libssl3t64 \
      libstdc++6 \
      libtinfo6 \
      zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 biot \
    && useradd --uid 10001 --gid biot --create-home --shell /usr/sbin/nologin biot \
    && install -d -o biot -g biot /var/lib/biot \
    && install -d /etc/biot

# The release is self-contained and reads its location, so it runs from wherever it is copied.
WORKDIR /opt/biot/server
COPY --from=build /build/_build/prod/rel/server/ /opt/biot/server/

# A release that writes a runtime system config does so under RELEASE_TMP; /tmp is writable for the
# unprivileged user and survives a read-only root filesystem. The slim base has no UTF-8 locale in
# the environment, and the BEAM otherwise falls back to latin1 native names; a crash dump also
# cannot be written into the root-owned release directory.
ENV RELEASE_TMP=/tmp
ENV HOME=/home/biot
ENV LANG=C.UTF-8
ENV ERL_CRASH_DUMP=/tmp/erl_crash.dump

USER biot

# The container runtime has no session and no edge proxy, so it checks the endpoint directly. The
# endpoint answers on loopback, and plain HTTP reaches it because /health is excluded from the
# application's HTTPS redirect.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl --fail --silent --show-error "http://127.0.0.1:${PORT:-4000}/health"

CMD ["/opt/biot/server/bin/server", "start"]
