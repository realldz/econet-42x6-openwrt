#!/usr/bin/env bash
#
# Build a flashable image for the vGP-42X6V1 using this project's Image Builder.
#
#   ./imagebuilder/build-image.sh openwrt-imagebuilder-airoha-en7523.*.tar.zst [options]
#   IB_DIR=/path/to/already-extracted-imagebuilder ./imagebuilder/build-image.sh
#
# Options:
#   -p, --profile NAME      device profile (default: econet_vgp-42x6v1)
#   -P, --packages "a b c"  extra packages to install into the image
#       --all-packages      use imagebuilder/packages.txt as the package list
#       --debug-kmods       add kmod-pciedbg + kmod-ringwatch
#   -o, --out DIR           collect images here (default: ./dist)
#       --keep              keep the extracted Image Builder directory
#   -h, --help              this text
#
# Requires: tar (with zstd), make, and the Image Builder tarball.
#
# Reminder: this Image Builder is the project's own build, not the upstream one.
# It exists because the board needs kernel patches that upstream's Image Builder
# cannot apply.  See docs/image-builder.md.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

PROFILE="econet_vgp-42x6v1"
EXTRA_PKGS=""
USE_LIST=0
DEBUG_KMODS=0
OUT="$PWD/dist"
KEEP=0
TARBALL=""
IB_DIR="${IB_DIR:-}"
WORK=""

while [ $# -gt 0 ]; do
	case "$1" in
		-p|--profile)     PROFILE="${2:?--profile needs a value}"; shift ;;
		-P|--packages)    EXTRA_PKGS="${2:?--packages needs a value}"; shift ;;
		--all-packages)   USE_LIST=1 ;;
		--debug-kmods)    DEBUG_KMODS=1 ;;
		-o|--out)         OUT="${2:?--out needs a directory}"; shift ;;
		--keep)           KEEP=1 ;;
		-h|--help)        sed -n '2,22p' "$0"; exit 0 ;;
		-*)               echo "!! unknown option: $1" >&2; exit 2 ;;
		*)                TARBALL="$1" ;;
	esac
	shift
done

# ---------------------------------------------------------------------------
# Locate the Image Builder
# ---------------------------------------------------------------------------
if [ -z "$IB_DIR" ]; then
	if [ -z "$TARBALL" ]; then
		echo "usage: $0 <imagebuilder.tar.zst> [options]   (see --help)" >&2
		echo "   or: IB_DIR=<extracted-imagebuilder> $0 [options]" >&2
		exit 2
	fi
	if [ ! -f "$TARBALL" ]; then
		echo "!! no such file: $TARBALL" >&2
		exit 1
	fi
	WORK=$(mktemp -d)
	echo "==> extracting $TARBALL"
	tar --zstd -xf "$TARBALL" -C "$WORK"
	IB_DIR=$(find "$WORK" -maxdepth 1 -mindepth 1 -type d | head -n1)
	if [ -z "$IB_DIR" ] || [ ! -f "$IB_DIR/Makefile" ]; then
		echo "!! could not find the Image Builder root inside $TARBALL" >&2
		exit 1
	fi
fi
IB_DIR=$(cd "$IB_DIR" && pwd)
echo "==> Image Builder: $IB_DIR"

# ---------------------------------------------------------------------------
# Package list
# ---------------------------------------------------------------------------
PKGS=""
if [ "$USE_LIST" = "1" ]; then
	if [ ! -f "$HERE/packages.txt" ]; then
		echo "!! $HERE/packages.txt is missing" >&2
		exit 1
	fi
	# strip comments and blank lines, join with spaces
	PKGS=$(sed -e 's/#.*//' -e 's/[[:space:]]\+/ /g' "$HERE/packages.txt" \
		| tr '\n' ' ' | tr -s ' ')
fi
if [ "$DEBUG_KMODS" = "1" ]; then
	PKGS="$PKGS kmod-pciedbg kmod-ringwatch"
fi
if [ -n "$EXTRA_PKGS" ]; then
	PKGS="$PKGS $EXTRA_PKGS"
fi
PKGS=$(echo "$PKGS" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')

FILES_DIR="$HERE/files"
if [ ! -d "$FILES_DIR" ]; then
	echo "!! $FILES_DIR is missing (needed so FILES= resolves)" >&2
	exit 1
fi

echo "==> profile : $PROFILE"
echo "==> packages: ${PKGS:-<none beyond the device defaults>}"
echo "==> overlay : $FILES_DIR"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
( cd "$IB_DIR" && make image \
	PROFILE="$PROFILE" \
	PACKAGES="$PKGS" \
	FILES="$FILES_DIR" )

# ---------------------------------------------------------------------------
# Collect
# ---------------------------------------------------------------------------
BIN=$(find "$IB_DIR/bin/targets" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | head -n1)
if [ -z "$BIN" ]; then
	echo "!! no bin/targets output found under $IB_DIR" >&2
	exit 1
fi

mkdir -p "$OUT"
echo
echo "==> images"
found=0
for f in "$BIN"/*.bin "$BIN"/*.itb; do
	[ -f "$f" ] || continue
	cp -v "$f" "$OUT/"
	sha256sum "$OUT/$(basename "$f")" >> "$OUT/SHA256SUMS"
	found=1
done
if [ "$found" = "0" ]; then
	echo "!! build produced no image files in $BIN" >&2
	exit 1
fi

cat <<EOF

==> Images collected in $OUT

Flash the *-sysupgrade.bin to slot B (mtd3, "tclinux_slave"); use the
*-initramfs-kernel.bin for a non-destructive RAM boot over UART.  See
docs/booting.md -- in particular the TEXT_OFFSET/load-address contract, and the
rule that slot A and the trailing raw region must never be written.
EOF

if [ "$KEEP" = "0" ] && [ -n "$WORK" ]; then
	rm -rf "$WORK"
fi
