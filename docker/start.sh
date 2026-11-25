#!/bin/sh
set -eu

: "${HOMESTEAD_HOST:?Set HOMESTEAD_HOST to the hostname Homestead is served from, for example homestead.at}"

case "$HOMESTEAD_HOST" in
  *[!A-Za-z0-9.-]*)
    echo "HOMESTEAD_HOST must be a hostname only, without scheme, port or path: $HOMESTEAD_HOST" >&2
    exit 1
    ;;
esac

for name in HOMESTEAD_PLC HOMESTEAD_TYPEAHEAD HOMESTEAD_SLINGSHOT HOMESTEAD_CONSTELLATION HOMESTEAD_APPVIEW HOMESTEAD_LABEL_RELAY HOMESTEAD_DNS; do
  eval "address=\${$name:-}"

  case "$address" in
    "") continue ;;
  esac

  case "${address#https://}" in
    "$address" | "" | *[!A-Za-z0-9.:/_~-]*)
      echo "$name must be an https address without a query: $address" >&2
      exit 1
      ;;
  esac
done

for name in HOMESTEAD_RELAYS HOMESTEAD_SIGNUP_SERVERS; do
  eval "servers=\${$name:-}"

  case "$servers" in
    *[!A-Za-z0-9.:/_~,\ -]*)
      echo "$name must be a comma-separated list of server names: $servers" >&2
      exit 1
      ;;
  esac
done

case "${HOMESTEAD_PASSWORD_ENTRY:-}" in
  "" | server | homestead) ;;
  *)
    echo "HOMESTEAD_PASSWORD_ENTRY must be server or homestead: $HOMESTEAD_PASSWORD_ENTRY" >&2
    exit 1
    ;;
esac

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
