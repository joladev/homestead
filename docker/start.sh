#!/bin/sh
set -eu

: "${HOMESTEAD_HOST:?Set HOMESTEAD_HOST to the hostname Homestead is served from, for example homestead.at}"

case "$HOMESTEAD_HOST" in
  *[!A-Za-z0-9.-]*)
    echo "HOMESTEAD_HOST must be a hostname only, without scheme, port or path: $HOMESTEAD_HOST" >&2
    exit 1
    ;;
esac

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
