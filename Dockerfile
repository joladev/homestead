FROM ghcr.io/gleam-lang/gleam:v1.19.1-erlang-alpine AS build

RUN apk add --no-cache git libgcc libstdc++ nodejs npm

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY gleam.toml manifest.toml ./
RUN gleam deps download

COPY . .
RUN gleam run -m lustre/dev build --minify
RUN docker/hash-assets.sh dist

FROM caddy:2.11-alpine

COPY docker/Caddyfile /etc/caddy/Caddyfile
COPY docker/start.sh /usr/local/bin/start
COPY --from=build /app/dist /srv
COPY docker/oauth-client-metadata.json /srv/oauth-client-metadata.json
COPY docker/config.json /srv/config.json

EXPOSE 8080

CMD ["start"]
