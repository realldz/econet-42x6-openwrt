#!/usr/bin/env bash
#
# Apply this repository's board support onto an OpenWrt source tree.
#
#   ./scripts/apply-overlay.sh /path/to/openwrt [--with-pon]
#
# The tree must be checked out at the revision recorded in scripts/pin.env.
# Patch files are applied with `git apply`, so a drifted tree fails loudly
# instead of quietly producing a broken image.
#
# What it does:
#   1. applies openwrt/patches/*.patch   (edits to existing upstream files)
#   2. copies  openwrt/overlay/.         (new files: board DTS, kernel patches,
#                                         mt76 package patches, base-files
#                                         overlay, diagnostic kernel modules)
#   3. optionally copies openwrt/dbg/... (--with-mt76-debug, one diagnostic
#                                         mt76 patch that must NOT ship)
#   4. optionally runs openwrt/pon/apply-pon.sh   (--with-pon, stage 2)
#
# It is idempotent: re-running it on an already-patched tree succeeds.
#
# Because step 2 drops patches into package/kernel/mt76/patches/, run
#   make package/kernel/mt76/clean
# whenever those patches change, or the build will reuse the previous mt76
# build directory and silently ignore the new patch.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=pin.env
. "$HERE/pin.env"

WITH_PON=0
WITH_MT76_DEBUG=0
OWRT_ARG=""
for arg in "$@"; do
	case "$arg" in
		--with-pon) WITH_PON=1 ;;
		--with-mt76-debug) WITH_MT76_DEBUG=1 ;;
		-h|--help) sed -n '2,25p' "$0"; exit 0 ;;
		-*) echo "!! unknown option: $arg" >&2; exit 2 ;;
		*) OWRT_ARG="$arg" ;;
	esac
done

if [ -z "$OWRT_ARG" ]; then
	echo "usage: $0 <openwrt-tree> [--with-pon] [--with-mt76-debug]" >&2
	exit 2
fi
if [ ! -d "$OWRT_ARG" ]; then
	echo "!! not a directory: $OWRT_ARG" >&2
	exit 1
fi
OWRT=$(cd "$OWRT_ARG" && pwd)

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if [ ! -d "$OWRT/target/linux/$TARGET" ]; then
	echo "!! $OWRT/target/linux/$TARGET does not exist." >&2
	echo "   Is this an OpenWrt tree?  Fetch it with:" >&2
	echo "     git clone $OPENWRT_REPO $OWRT" >&2
	echo "     git -C $OWRT checkout $OPENWRT_COMMIT" >&2
	exit 1
fi

if git -C "$OWRT" rev-parse --git-dir >/dev/null 2>&1; then
	HEAD_COMMIT=$(git -C "$OWRT" rev-parse HEAD)
	if [ "$HEAD_COMMIT" != "$OPENWRT_COMMIT" ]; then
		echo "!! OpenWrt tree is at $HEAD_COMMIT" >&2
		echo "   but scripts/pin.env expects $OPENWRT_COMMIT ($OPENWRT_COMMIT_DATE)." >&2
		echo "   The patch series has exact context lines and will most likely fail." >&2
		echo "   Check out the pinned revision, or regenerate the series first." >&2
		exit 1
	fi
	echo "==> OpenWrt tree at pinned revision ${OPENWRT_COMMIT:0:12} (${OPENWRT_COMMIT_DATE})"
else
	echo "==> WARNING: $OWRT is not a git tree; cannot verify the revision."
	echo "    Patch context is only guaranteed for $OPENWRT_COMMIT."
fi

# ---------------------------------------------------------------------------
# (1) Patches against existing upstream files
# ---------------------------------------------------------------------------
echo
echo "==> openwrt/patches -> $OWRT"
shopt -s nullglob
PATCHES=("$REPO"/openwrt/patches/*.patch)
if [ ${#PATCHES[@]} -eq 0 ]; then
	echo "!! no patch files found in $REPO/openwrt/patches" >&2
	exit 1
fi
for p in "${PATCHES[@]}"; do
	name=$(basename "$p")
	if git -C "$OWRT" apply --check "$p" 2>/dev/null; then
		git -C "$OWRT" apply "$p"
		echo "    applied       $name"
	elif git -C "$OWRT" apply --reverse --check "$p" 2>/dev/null; then
		echo "    already there $name"
	else
		echo "!! cannot apply $name" >&2
		echo "   Neither a clean apply nor an already-applied state was detected." >&2
		echo "   Regenerate the series against this tree (docs/building.md)." >&2
		exit 1
	fi
done

# ---------------------------------------------------------------------------
# (2) New files
# ---------------------------------------------------------------------------
echo
echo "==> openwrt/overlay -> $OWRT"
if [ ! -d "$REPO/openwrt/overlay" ]; then
	echo "!! $REPO/openwrt/overlay is missing" >&2
	exit 1
fi
cp -a "$REPO/openwrt/overlay/." "$OWRT/"
echo "    board DTS      target/linux/$TARGET/dts/$DEVICE_TREE.dts"
echo "    kernel patches target/linux/$TARGET/patches-$KERNEL_SERIES/"
echo "    base-files     target/linux/$TARGET/base-files/  (sysupgrade platform.sh)"
echo "    board.d        target/linux/$TARGET/$SUBTARGET/base-files/etc/board.d/02_network"
echo "    mt76 patches   package/kernel/mt76/patches/  (run: make package/kernel/mt76/clean)"
echo "    debug modules  package/kernel/{pciedbg,ringwatch}/  (built, not installed by default)"

# ---------------------------------------------------------------------------
# (2b) Optional diagnostic mt76 patch.  Kept out of overlay/ on purpose: it
#      prints the WFDMA descriptor base of every ring and must never end up in
#      a shipped image.
# ---------------------------------------------------------------------------
if [ "$WITH_MT76_DEBUG" = "1" ]; then
	echo
	echo "==> diagnostic mt76 patch (--with-mt76-debug)"
	mkdir -p "$OWRT/package/kernel/mt76/patches"
	cp -a "$REPO/openwrt/dbg/package/kernel/mt76/patches/." "$OWRT/package/kernel/mt76/patches/"
	ls -1 "$REPO/openwrt/dbg/package/kernel/mt76/patches/"
fi

# ---------------------------------------------------------------------------
# (3) Optional stage 2 (xPON / optical).  NOT functional yet -- see
#     docs/pon-port.md and openwrt/pon/README.md.
# ---------------------------------------------------------------------------
if [ "$WITH_PON" = "1" ]; then
	echo
	echo "==> stage 2 PON patches (--with-pon)"
	bash "$REPO/openwrt/pon/apply-pon.sh" "$OWRT"
fi

cat <<EOF

==> Board support applied.

Next: configure and build.

    ./scripts/build-firmware.sh $OWRT --initramfs
    ./scripts/build-imagebuilder.sh $OWRT        # to get an Image Builder

Things that are easy to get wrong:

  * The FIT load address must equal the kernel's physical _text (0x80208000).
    That needs BOTH the TEXT_OFFSET kernel patch and the loadaddr change applied
    above.  If it is wrong the kernel deadloops in head.S before it can print
    anything, and the UART stays completely silent.  See docs/booting.md.

  * The mt76 patches under package/kernel/mt76/patches/ only take effect after
        make package/kernel/mt76/clean
    otherwise the previous mt76 build directory is reused unchanged.

  * /dev/mtd* only exists if the kernel is built with devtmpfs.  That is an
    OpenWrt .config symbol, not a target kernel symbol, and build-firmware.sh
    seeds it.  Without it sysupgrade cannot write flash.  See docs/sysupgrade.md.

  * kmod-pciedbg and kmod-ringwatch are diagnostic modules.  They are built but
    deliberately not part of DEVICE_PACKAGES.  Add them only when debugging:
      --debug-kmods on build-firmware.sh, or PACKAGES="kmod-pciedbg" with the
      Image Builder.
EOF
