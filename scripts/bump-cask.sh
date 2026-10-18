#!/bin/bash
# Sets the version and sha256 of a Homebrew cask in place, for the release workflow's tap bump:
#   scripts/bump-cask.sh Casks/corescope.rb 0.6.0 <sha256 of the release zip>
set -euo pipefail
CASK=$1 VERSION=$2 SHA=$3
[[ $VERSION =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "bump-cask: bad version '$VERSION'" >&2; exit 1; }
[[ $SHA =~ ^[0-9a-f]{64}$ ]] || { echo "bump-cask: bad sha256 '$SHA'" >&2; exit 1; }
sed -i.bak -E "s/^(  version )\"[^\"]*\"$/\1\"$VERSION\"/; s/^(  sha256 )\"[^\"]*\"$/\1\"$SHA\"/" "$CASK"
rm "$CASK.bak"
# Both lines must have been there to replace.
grep -qx "  version \"$VERSION\"" "$CASK" && grep -qx "  sha256 \"$SHA\"" "$CASK" \
  || { echo "bump-cask: no version/sha256 line in $CASK" >&2; exit 1; }
