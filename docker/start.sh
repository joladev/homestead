#!/bin/sh
set -eu

: "${HOMESTEAD_HOST:?Set HOMESTEAD_HOST to the hostname Homestead is served from, for example homestead.at}"

case "$HOMESTEAD_HOST" in
  *[!A-Za-z0-9.-]*)
    echo "HOMESTEAD_HOST must be a hostname only, without scheme, port or path: $HOMESTEAD_HOST" >&2
    exit 1
    ;;
esac

export HOMESTEAD_DNS="${HOMESTEAD_DNS:-https://dns10.quad9.net/dns-query}"

case "${HOMESTEAD_DNS#https://}" in
  "$HOMESTEAD_DNS" | "" | *[!A-Za-z0-9.:/_~-]*)
    echo "HOMESTEAD_DNS must be an https address without a query, for example https://dns10.quad9.net/dns-query: $HOMESTEAD_DNS" >&2
    exit 1
    ;;
esac

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
