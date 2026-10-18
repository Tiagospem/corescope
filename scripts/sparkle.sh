#!/bin/bash
# Prints the folder of the pinned Sparkle release (framework + sign_update), downloading and
# checking it into build/vendor the first time. Sparkle installs updates in the app; see
# CONTRIBUTING.md › Releases for the signing key.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=2.10.0
SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
DIR="$PWD/build/vendor/Sparkle-$VERSION"
if [ ! -x "$DIR/bin/generate_keys" ]; then
  mkdir -p build/vendor
  archive="build/vendor/Sparkle-$VERSION.tar.xz"
  curl -fsSL --retry 3 -o "$archive" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
  echo "$SHA256  $archive" | shasum -a 256 -c - >&2
  rm -rf "$DIR.tmp" && mkdir -p "$DIR.tmp"
  tar -xJf "$archive" -C "$DIR.tmp" Sparkle.framework bin/sign_update bin/generate_keys LICENSE
  rm -rf "$DIR" && mv "$DIR.tmp" "$DIR"
  rm -f "$archive"
fi
echo "$DIR"
