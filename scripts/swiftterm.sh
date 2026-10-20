#!/bin/bash
# Prints the folder holding the pinned SwiftTerm (MIT) built as a static library and Swift module
# for each architecture in $ARCHS (default: this Mac's), building it into build/vendor the first
# time. It backs the integrated terminal in projects (Settings › Editor and terminal, off by
# default). The macOS sources only: no iOS views, no Metal shader bundle (Metal stays off).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=1.20.0
SHA256=36b39a2a4a63afc02099879e00a2b10f7d891c2b8b967db8af6ff45f81cf90f1
ARCHS=${ARCHS:-$(uname -m)}
# Bump PATCHED when the patch below changes, so cached builds are redone.
PATCHED=1
DIR="$PWD/build/vendor/SwiftTerm-$VERSION-p$PATCHED"
SRC="$DIR/src"
if [ ! -f "$SRC/LICENSE" ]; then
  mkdir -p build/vendor
  archive="build/vendor/SwiftTerm-$VERSION.tar.gz"
  curl -fsSL --retry 3 -o "$archive" "https://github.com/migueldeicaza/SwiftTerm/archive/refs/tags/v$VERSION.tar.gz"
  echo "$SHA256  $archive" | shasum -a 256 -c - >&2
  rm -rf "$SRC.tmp" && mkdir -p "$SRC.tmp"
  tar -xzf "$archive" -C "$SRC.tmp" --strip-components 1 "SwiftTerm-$VERSION/Sources/SwiftTerm" "SwiftTerm-$VERSION/LICENSE"
  # Stands in for SwiftPM's build-info plugin (used for the XTVERSION reply).
  cat > "$SRC.tmp/Sources/SwiftTerm/SwiftTermBuildInfo.swift" <<SWIFT
public enum SwiftTermBuildInfo {
    public static let branch: String? = nil
    public static let tag: String? = "v$VERSION"
    public static let commit: String? = nil
    public static let hasUncommittedChanges: Bool? = false
    public static let version: String = "v$VERSION"
}
SWIFT
  # Patch: LocalProcess compacts its backlog of received chunks every 32 chunks, moving the whole
  # backlog each time. Output arrives a few bytes per read (a line at a time), so once the main
  # thread falls behind (up to 4 MB, about a million chunks) that is quadratic and the app hangs
  # for minutes on `yes | head -n 2000000`. Compact only when at least half is consumed.
  lp="$SRC.tmp/Sources/SwiftTerm/LocalProcess.swift"
  sed -i '' 's/if pendingChunkIndex >= pendingChunkFlushThreshold {/if pendingChunkIndex >= pendingChunkFlushThreshold \&\& pendingChunkIndex * 2 >= pendingChunks.count {/' "$lp"
  grep -q 'pendingChunkIndex \* 2 >= pendingChunks.count' "$lp" || { echo "SwiftTerm patch did not apply" >&2; exit 1; }
  rm -rf "$SRC" && mv "$SRC.tmp" "$SRC"
  rm -f "$archive"
fi
for arch in $ARCHS; do
  out="$DIR/$arch"
  [ -f "$out/libSwiftTerm.a" ] && [ -f "$out/SwiftTerm.swiftmodule" ] && continue
  rm -rf "$out.tmp" && mkdir -p "$out.tmp"
  s="$SRC/Sources/SwiftTerm"
  # Library mode with evolution off, -O, whole module: built once, linked statically.
  swiftc -O -wmo -parse-as-library -swift-version 5 -module-name SwiftTerm -target "$arch-apple-macosx14.0" \
    -emit-module -emit-module-path "$out.tmp/SwiftTerm.swiftmodule" -emit-library -static -o "$out.tmp/libSwiftTerm.a" \
    "$s"/*.swift "$s"/Apple/*.swift "$s"/Apple/Metal/*.swift "$s"/Mac/*.swift >&2
  rm -rf "$out" && mv "$out.tmp" "$out"
done
echo "$DIR"
