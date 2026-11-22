#!/bin/sh
set -eu

dist="$1"

for name in homestead.js homestead.css; do
  hash=$(sha256sum "$dist/$name" | cut -c1-16)
  hashed="${name%.*}.$hash.${name##*.}"

  grep -q "\"/$name\"" "$dist/index.html"
  mv "$dist/$name" "$dist/$hashed"
  sed -i "s|\"/$name\"|\"/$hashed\"|" "$dist/index.html"
done
