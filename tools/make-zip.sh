#!/usr/bin/env bash
# Package the module source plus a built kernel into a flashable zip.
#
#   tools/make-zip.sh path/to/Image.gz [output.zip]
#
# Image.gz is NOT committed: it is 18 MB of build output and belongs in a
# release, not in git history.
set -euo pipefail
cd "$(dirname "$0")/.."
KERNEL="${1:?usage: tools/make-zip.sh <Image.gz> [out.zip]}"
[ -s "$KERNEL" ] || { echo "not found: $KERNEL" >&2; exit 1; }

VER=$(grep '^version=' module/module.prop | cut -d= -f2)
OUT="${2:-dist/raphael-docker-kernel-${VER}.zip}"
mkdir -p "$(dirname "$OUT")"
# Resolve to an absolute path: the zip runs from a staging dir, so a relative
# path would land in the wrong place and an absolute one must not be re-prefixed.
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R module/. "$STAGE/"
mkdir -p "$STAGE/kernel"
cp "$KERNEL" "$STAGE/kernel/Image.gz"

# Record the payload hash so the installer can prove the kernel it is about to
# flash is the one that was built, not a truncated or corrupted download. A zip
# that unpacks cleanly can still contain a damaged Image.gz.
shasum -a 256 "$STAGE/kernel/Image.gz" | cut -d' ' -f1 > "$STAGE/kernel/Image.gz.sha256"
echo "  payload sha256: $(cat "$STAGE/kernel/Image.gz.sha256")"

# macOS on exFAT sprays AppleDouble sidecars; they must not reach the zip.
find "$STAGE" -name '._*' -delete 2>/dev/null || true
find "$STAGE" -name '.DS_Store' -delete 2>/dev/null || true

rm -f "$OUT"
( cd "$STAGE" && zip -qr9 "$OUT" . -x '._*' -x '*/._*' -x '.DS_Store' )
echo "built: $OUT  ($(du -h "$OUT" | cut -f1))"
shasum -a 256 "$OUT"
