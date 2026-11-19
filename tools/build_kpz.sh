#!/usr/bin/env bash
# Build the Koha plugin package: dist/pigeon-post-v<version>.kpz
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(perl -ne 'print $1 if /our \$VERSION = .([0-9.]+)./' Koha/Plugin/Pro/Koha/PigeonPost.pm)
[ -n "$version" ] || { echo "could not read VERSION" >&2; exit 1; }
mkdir -p dist
out="dist/pigeon-post-v${version}.kpz"
rm -f "$out"
zip -qr -X "$out" Koha -x '*/.DS_Store' '*~'
echo "built $out ($(du -h "$out" | cut -f1))"
unzip -l "$out" | tail -n +4 | head -n -2 | awk '{print "  " $4}'
