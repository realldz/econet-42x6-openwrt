#!/usr/bin/env bash
#
# Configure and build OpenWrt for the Econet vG vGP-42X6V1 (Airoha EN7523).
#
#   ./scripts/build-firmware.sh /path/to/openwrt [options]
#
# Options:
#   --initramfs        also emit *-initramfs-kernel.bin        (default)
#   --no-initramfs     do not
#   --debug-kmods      install kmod-pciedbg + kmod-ringwatch into the image
#   --no-packages      do not seed scripts/packages.append into .config
#   --with-pon         apply the stage 2 xPON patches (NOT functional yet)
#   --mt76-debug       also apply the diagnostic mt76 patch (never ship this)
#   --imagebuilder     additionally produce the self-contained Image Builder
#   --no-apply         skip apply-overlay.sh (assume the overlay is already in)
#   -j N, --jobs N     build parallelism (default: number of CPUs)
#   -h, --help         this text
#
# Run this on Linux (or inside the Docker/WSL environment described in
# docs/building.md).  OpenWrt cannot be built on Windows itself.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=pin.env
. "$HERE/pin.env"

INITRAMFS=1
DEBUG_KMODS=0
WITH_PON=0
WITH_PACKAGES=1
MT76_DEBUG=0
IMAGEBUILDER=0
DO_APPLY=1
JOBS=$(nproc 2>/dev/null || echo 4)
OWRT_ARG=""

while [ $# -gt 0 ]; do
	case "$1" in
		--initramfs)    INITRAMFS=1 ;;
		--no-initramfs) INITRAMFS=0 ;;
		--debug-kmods)  DEBUG_KMODS=1 ;;
		--no-packages)  WITH_PACKAGES=0 ;;
		--with-pon)     WITH_PON=1 ;;
		--mt76-debug)   MT76_DEBUG=1 ;;
		--imagebuilder) IMAGEBUILDER=1 ;;
		--no-apply)     DO_APPLY=0 ;;
		-j|--jobs)      JOBS="${2:?--jobs needs a number}"; shift ;;
		-h|--help)      sed -n '2,24p' "$0"; exit 0 ;;
		-*)             echo "!! unknown option: $1" >&2; exit 2 ;;
		*)              OWRT_ARG="$1" ;;
	esac
	shift
done

if [ -z "$OWRT_ARG" ]; then
	echo "usage: $0 <openwrt-tree> [options]   (see --help)" >&2
	exit 2
fi
OWRT=$(cd "$OWRT_ARG" && pwd)

# ---------------------------------------------------------------------------
# (1) Board support into the tree
# ---------------------------------------------------------------------------
if [ "$DO_APPLY" = "1" ]; then
	PON_FLAG=""
	[ "$WITH_PON" = "1" ] && PON_FLAG="--with-pon"
	MT76_DBG_FLAG=""
	[ "$MT76_DEBUG" = "1" ] && MT76_DBG_FLAG="--with-mt76-debug"
	# shellcheck disable=SC2086
	"$HERE/apply-overlay.sh" "$OWRT" $PON_FLAG $MT76_DBG_FLAG
	echo
else
	echo "==> --no-apply: assuming board support is already in $OWRT"
fi

# ---------------------------------------------------------------------------
# (2) Seed .config
#
# set_cfg() replaces an existing assignment, un-comments an existing
# "# CONFIG_X is not set" line, or appends.  Appending blindly would leave
# duplicate keys behind, and in that case the outcome depends on whichever line
# kconfig reads last.
# ---------------------------------------------------------------------------
CFG="$OWRT/.config"
touch "$CFG"

# Every symbol this script seeds is recorded, so that after `make defconfig`
# the list can be re-checked: defconfig drops a symbol whose dependencies are
# not available, and a missing wpad or luci is easy to mistake for a broken
# driver later.  See docs/building.md.
SEEDED=$(mktemp)
trap 'rm -f "$SEEDED"' EXIT

set_cfg() {
	local key="$1" val="$2"
	if grep -q "^${key}=" "$CFG"; then
		sed -i "s|^${key}=.*|${key}=${val}|" "$CFG"
	elif grep -q "^# ${key} is not set" "$CFG"; then
		sed -i "s|^# ${key} is not set|${key}=${val}|" "$CFG"
	else
		printf '%s=%s\n' "$key" "$val" >> "$CFG"
	fi
	printf '%s=%s\n' "$key" "$val" >> "$SEEDED"
	echo "    ${key}=${val}"
}

echo "==> Seeding $CFG"
set_cfg "CONFIG_TARGET_${TARGET}" "y"
set_cfg "CONFIG_TARGET_${TARGET}_${SUBTARGET}" "y"
set_cfg "CONFIG_TARGET_${TARGET}_${SUBTARGET}_DEVICE_${DEVICE_PROFILE}" "y"
set_cfg "CONFIG_TARGET_ROOTFS_SQUASHFS" "y"

if [ "$INITRAMFS" = "1" ]; then
	# Produces *-initramfs-kernel.bin, which is what the UART/YMODEM RAM-boot
	# procedure in docs/booting.md loads.  See "M1" in docs/status.md.
	# Caveat: with this on, the sysupgrade image can inherit a kernel with the
	# initramfs embedded in it (MEASURED 14.4 MB instead of 9.4 MB).  The
	# post-build check below warns about it; build with --no-initramfs when you
	# only want the persistent image.
	set_cfg "CONFIG_TARGET_ROOTFS_INITRAMFS" "y"
fi

if [ "$DEBUG_KMODS" = "1" ]; then
	# Diagnostic only.  kmod-ringwatch reads MT7916 WFDMA registers; it guards
	# its BAR0 access behind PCI_COMMAND.MEMORY because reading BAR0 while
	# Memory Space is off hangs the SoC irrecoverably.  See docs/pcie-root-cause.md.
	set_cfg "CONFIG_PACKAGE_kmod-pciedbg" "y"
	set_cfg "CONFIG_PACKAGE_kmod-ringwatch" "y"
fi

if [ "$IMAGEBUILDER" = "1" ]; then
	set_cfg "CONFIG_IB" "y"
	# Mandatory here: the airoha target is FEATURES:=source-only, so there are
	# no official package repositories for airoha/en7523 to fetch from.  Without
	# standalone the resulting Image Builder cannot resolve even kmod-mt7915e.
	set_cfg "CONFIG_IB_STANDALONE" "y"
fi

# ---------------------------------------------------------------------------
# (2b) Kernel-level .config symbols this board needs
#
# devtmpfs: OpenWrt deliberately does not use it, but MTD registers its devices
# during kernel init -- before procd exists -- so the uevent is lost and no
# /dev/mtd* node is ever created.  Without devtmpfs the kernel can have
# CONFIG_MTD_BLOCK=y and still expose nothing to flash from, which makes
# sysupgrade impossible.  See docs/sysupgrade.md.
# ---------------------------------------------------------------------------
set_cfg "CONFIG_KERNEL_DEVTMPFS" "y"
set_cfg "CONFIG_KERNEL_DEVTMPFS_MOUNT" "y"

# ---------------------------------------------------------------------------
# (2c) Packages
#
# The target is source-only, so anything the image needs must be selected at
# build time.  See scripts/packages.append.
# ---------------------------------------------------------------------------
if [ "$WITH_PACKAGES" = "1" ]; then
	PKGS_FILE="$HERE/packages.append"
	if [ ! -f "$PKGS_FILE" ]; then
		echo "!! $PKGS_FILE is missing" >&2
		exit 1
	fi
	echo "==> Seeding packages from packages.append"
	while IFS= read -r line; do
		case "$line" in
			CONFIG_*=*) ;;
			*) continue ;;
		esac
		set_cfg "${line%%=*}" "${line#*=}"
	done < "$PKGS_FILE"
fi

# ---------------------------------------------------------------------------
# (3) Build
# ---------------------------------------------------------------------------
echo
echo "==> make defconfig"
( cd "$OWRT" && make defconfig )

echo
echo "==> Verifying the seeded symbols survived defconfig"
MISSING=0
while IFS= read -r want; do
	[ -n "$want" ] || continue
	if ! grep -qx "$want" "$CFG"; then
		echo "    MISSING  $want" >&2
		MISSING=$((MISSING + 1))
	fi
done < "$SEEDED"
if [ "$MISSING" -ne 0 ]; then
	cat >&2 <<'EOF'

!! Seeded symbol(s) did not survive make defconfig.

   defconfig drops a symbol whose dependencies are not available in this tree,
   and the usual reason is a feed that is not enabled or a package name that no
   longer exists.  Building anyway produces an image that is silently missing
   files (no AP daemon, no web UI), which is much harder to diagnose than a
   failure here.  Fix the symbol, or pass --no-packages if you really want the
   bare image.
EOF
	exit 1
fi
echo "    all $(grep -c . "$SEEDED") symbol(s) present"

echo
echo "==> make -j$JOBS"
( cd "$OWRT" && make -j"$JOBS" )

# ---------------------------------------------------------------------------
# (4) Report
# ---------------------------------------------------------------------------
echo
echo "==> Artifacts in $TARGET_BIN"
BIN="$OWRT/$TARGET_BIN"
if [ -d "$BIN" ]; then
	ls -l "$BIN"/*.bin 2>/dev/null || echo "    (no .bin files?)"
	if [ "$IMAGEBUILDER" = "1" ]; then
		ls -l "$BIN"/openwrt-imagebuilder-*.tar.zst 2>/dev/null \
			|| echo "    (no Image Builder tarball found -- check CONFIG_IB)"
	fi
else
	echo "!! $BIN does not exist -- the build did not produce target output" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# (4b) Sanity-check the sysupgrade image
#
# The persistent image must carry the PLAIN kernel.  When the same tree also
# builds an initramfs image (--initramfs, on by default), the kernel can end up
# with the initramfs cpio embedded in it, and the sysupgrade image inherits that:
# MEASURED 14,418,209 B with the squashfs at 0x880000, and a second one at
# 12,058,913 B with the squashfs at 0x760000, instead of 9,437,473 B with the
# squashfs at 0x3A0000.  The two kernel Images of that build had the same md5,
# which is what identifies it.
#
# What the check measures: `mtdsplit_fit` derives the kernel partition as
# round_up(FIT totalsize, erase block) and then finds the rootfs by scanning for
# a filesystem magic *after* the FIT, so the squashfs offset is exactly
# round_up(totalsize) -- 0x3A0000 for a clean build here.  An offset far past
# that means the FIT itself grew, i.e. the kernel carries the initramfs.
# Why it matters: the image is much larger than it needs to be, and such a
# kernel boots its own embedded rootfs rather than the flash rootfs, so nothing
# persists across a reboot [not verified on this board, docs/sysupgrade.md].
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
	echo
	echo "==> Checking the sysupgrade image(s)"
	for img in "$BIN"/*-sysupgrade.bin; do
		[ -e "$img" ] || continue
		python3 - "$img" <<'PY'
import os, struct, sys

SQUASHFS_MAGIC = b"hsqs"
COMPRESSIONS = {1, 2, 3, 4, 5, 6}   # gzip, lzma, lzo, xz, lz4, zstd


def plausible_superblock(data, off):
	"""True when a squashfs v4 superblock starts at `off`.

	Checking the magic alone is not enough: the kernel Image is uncompressed,
	so a stray 'hsqs' in it would be reported as the rootfs offset and hide an
	inflated kernel.
	"""
	size = len(data)
	if off < 0 or off + 96 > size or data[off:off + 4] != SQUASHFS_MAGIC:
		return False
	block_size, = struct.unpack_from("<I", data, off + 12)
	compression, = struct.unpack_from("<H", data, off + 20)
	block_log, = struct.unpack_from("<H", data, off + 22)
	major, = struct.unpack_from("<H", data, off + 28)
	bytes_used, = struct.unpack_from("<Q", data, off + 40)
	if major != 4 or compression not in COMPRESSIONS:
		return False
	if block_size < 4096 or block_size > (1 << 20) or block_size & (block_size - 1):
		return False
	if block_log != block_size.bit_length() - 1:
		return False
	return bytes_used <= size - off


def find_rootfs(data):
	offs = []
	i = data.find(SQUASHFS_MAGIC)
	while i >= 0:
		if plausible_superblock(data, i):
			offs.append(i)
		i = data.find(SQUASHFS_MAGIC, i + 1)
	return offs


path = sys.argv[1]
data = open(path, "rb").read()
size = len(data)
offs = find_rootfs(data)

print(f"    {os.path.basename(path)}: {size} bytes", end="")
if not offs:
	print(" -- no squashfs superblock found, is this really a sysupgrade image?")
elif offs[0] > 0x600000:
	print(f", squashfs at 0x{offs[0]:x}  <-- WARNING: kernel looks like it has "
	      "the initramfs embedded")
	print("       the FIT grew, so this image is far larger than it needs to be "
	      "-- rebuild without")
	print("       --initramfs for a lean persistent image (see docs/sysupgrade.md)")
else:
	print(f", squashfs at 0x{offs[0]:x}  ok", end="")
	if len(offs) > 1:
		print(f"  ({len(offs)} candidate offsets, using the first)")
	else:
		print()
PY
	done
fi

cat <<EOF

==> Which artifact is which

  *-initramfs-kernel.bin   RAM-boot over UART/YMODEM, nothing is written to
                           flash.  This is the safe way to try a build.
  *-sysupgrade.bin         the persistent image; belongs in slot B
                           (mtd3, "tclinux_slave").

==> Verify before flashing

  python3 $REPO/tools/verify_build.py <image>

It checks that the FIT load/entry address is 0x80208000.  Get this wrong and the
kernel deadloops in head.S before it can print anything, leaving the UART
completely silent with no diagnostic.  See docs/booting.md.
EOF
