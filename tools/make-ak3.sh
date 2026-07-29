#!/usr/bin/env bash
# Build the recovery-flashable AnyKernel3 zip.
#
#   tools/make-ak3.sh <Image.gz> [out.zip] [path/to/AnyKernel3]
#
# AnyKernel3 itself is NOT vendored -- it ships ~2 MB of prebuilt binaries
# (magiskboot, busybox) that have no business in git history. It is cloned at
# package time, or you can pass a local checkout as the third argument.
set -euo pipefail
cd "$(dirname "$0")/.."

KERNEL="${1:?usage: tools/make-ak3.sh <Image.gz> [out.zip] [AnyKernel3 dir]}"
[ -s "$KERNEL" ] || { echo "not found: $KERNEL" >&2; exit 1; }
KERNEL="$(cd "$(dirname "$KERNEL")" && pwd)/$(basename "$KERNEL")"

VER=$(grep '^version=' module/module.prop | cut -d= -f2)
OUT="${2:-dist/antigravity-docker-kernel-${VER}-AnyKernel3.zip}"
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
AK3SRC="${3:-}"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

if [ -n "$AK3SRC" ]; then
    cp -R "$AK3SRC/." "$STAGE/"
else
    echo "cloning AnyKernel3..."
    git clone -q --depth 1 https://github.com/osm0sis/AnyKernel3 "$STAGE/ak3"
    cp -R "$STAGE/ak3/." "$STAGE/"
    rm -rf "$STAGE/ak3"
fi
rm -rf "$STAGE/.git" "$STAGE/README.md"

# our config replaces the template's, and the kernel goes in the zip root
cp anykernel/anykernel.sh "$STAGE/anykernel.sh"
cp "$KERNEL" "$STAGE/Image.gz"

[ -f "$STAGE/tools/ak3-core.sh" ] || { echo "AnyKernel3 is incomplete: tools/ak3-core.sh missing" >&2; exit 1; }

# macOS on exFAT sprays AppleDouble sidecars; they must not reach the zip.
find "$STAGE" -name '._*' -delete 2>/dev/null || true
find "$STAGE" -name '.DS_Store' -delete 2>/dev/null || true

rm -f "$OUT"
( cd "$STAGE" && zip -qr9 "$OUT" . -x '._*' -x '*/._*' -x '.DS_Store' )
echo "built: $OUT  ($(du -h "$OUT" | cut -f1))"
shasum -a 256 "$OUT"
