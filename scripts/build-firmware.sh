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
#   --with-pon         apply the stage 2 xPON patches (NOT functional yet)
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
IMAGEBUILDER=0
DO_APPLY=1
JOBS=$(nproc 2>/dev/null || echo 4)
OWRT_ARG=""

while [ $# -gt 0 ]; do
	case "$1" in
		--initramfs)    INITRAMFS=1 ;;
		--no-initramfs) INITRAMFS=0 ;;
		--debug-kmods)  DEBUG_KMODS=1 ;;
		--with-pon)     WITH_PON=1 ;;
		--imagebuilder) IMAGEBUILDER=1 ;;
		--no-apply)     DO_APPLY=0 ;;
		-j|--jobs)      JOBS="${2:?--jobs needs a number}"; shift ;;
		-h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
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
	# shellcheck disable=SC2086
	"$HERE/apply-overlay.sh" "$OWRT" $PON_FLAG
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

set_cfg() {
	local key="$1" val="$2"
	if grep -q "^${key}=" "$CFG"; then
		sed -i "s|^${key}=.*|${key}=${val}|" "$CFG"
	elif grep -q "^# ${key} is not set" "$CFG"; then
		sed -i "s|^# ${key} is not set|${key}=${val}|" "$CFG"
	else
		printf '%s=%s\n' "$key" "$val" >> "$CFG"
	fi
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
# (3) Build
# ---------------------------------------------------------------------------
echo
echo "==> make defconfig"
( cd "$OWRT" && make defconfig )

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
