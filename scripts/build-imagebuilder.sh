#!/usr/bin/env bash
#
# Produce a self-contained OpenWrt Image Builder for the vGP-42X6V1.
#
#   ./scripts/build-imagebuilder.sh /path/to/openwrt [options]
#
# This is a thin wrapper around build-firmware.sh that also sets CONFIG_IB and
# CONFIG_IB_STANDALONE.  All other options are forwarded, e.g. -j 8.
#
# Why this exists
# ---------------
# OpenWrt's upstream Image Builder cannot build a working image for this board,
# because it only ships a precompiled kernel and lets you choose packages and a
# profile -- it cannot apply kernel patches.  Two of this board's fixes are
# kernel patches:
#
#   * arch/arm TEXT_OFFSET   (without it the kernel is mute on the UART)
#   * drivers/pci/quirks.c   (without it the MT7916 can never DMA)
#
# So the firmware must be built from source once, and the resulting Image Builder
# is what users then drive with `make image PROFILE=... PACKAGES=...`.  The
# tarball carries the already-patched prebuilt kernel plus every package,
# including the airoha-specific kernel modules, which is why it is large.
#
# Output:
#   <tree>/bin/targets/airoha/en7523/openwrt-imagebuilder-airoha-en7523.<os>-<arch>.tar.zst
#   copied to ./dist/ unless --out is given.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=pin.env
. "$HERE/pin.env"

OUT="$REPO/dist"
ARGS=()
OWRT_ARG=""

while [ $# -gt 0 ]; do
	case "$1" in
		--out) OUT="${2:?--out needs a directory}"; shift ;;
		-j|--jobs) ARGS+=("-j" "${2:?--jobs needs a number}"); shift ;;
		-h|--help) sed -n '2,25p' "$0"; exit 0 ;;
		-*) ARGS+=("$1") ;;
		*) if [ -z "$OWRT_ARG" ]; then OWRT_ARG="$1"; else ARGS+=("$1"); fi ;;
	esac
	shift
done

if [ -z "$OWRT_ARG" ]; then
	echo "usage: $0 <openwrt-tree> [options]   (see --help)" >&2
	exit 2
fi
OWRT=$(cd "$OWRT_ARG" && pwd)

"$HERE/build-firmware.sh" "$OWRT" --imagebuilder "${ARGS[@]+"${ARGS[@]}"}"

BIN="$OWRT/$TARGET_BIN"
shopt -s nullglob
TARBALLS=("$BIN"/openwrt-imagebuilder-*.tar.zst)
if [ ${#TARBALLS[@]} -eq 0 ]; then
	echo "!! no Image Builder tarball in $BIN" >&2
	exit 1
fi

mkdir -p "$OUT"
for t in "${TARBALLS[@]}"; do
	cp -v "$t" "$OUT/"
	sha256sum "$OUT/$(basename "$t")" >> "$OUT/SHA256SUMS"
done

cat <<EOF

==> Image Builder in $OUT

Ship the tarball (plus SHA256SUMS) as a release asset.  Users then run:

    tar --zstd -xf openwrt-imagebuilder-*.tar.zst
    cd openwrt-imagebuilder-*/
    make image PROFILE=$DEVICE_PROFILE PACKAGES="luci"

See imagebuilder/README.md and docs/image-builder.md.
EOF
