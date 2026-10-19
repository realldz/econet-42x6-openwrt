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
#   --variant m2|full  which package set to seed               (default: full)
#                        m2   Ethernet + Wi-Fi + LuCI + apk only.  This is what a
#                             release meant for someone else's unit should be: it
#                             carries no driver that needs the per-unit laser
#                             (BOB) calibration blob.
#                        full m2 + optical frontend + xPON + OMCI.  Only useful
#                             on a unit whose BOB blob you have extracted from its
#                             own factory partition -- see docs/pon-port.md.
#   --packages FILE    seed FILE instead of the variant's own list
#   --no-packages      do not seed any package list into .config
#   --no-feeds         do not run ./scripts/feeds update/install
#   --kmods SPEC       which kernel modules to build *beyond* the image's own
#                        image  only what the image needs (default).  MEASURED on
#                               v0.1.0-m2: 46 modules in the archive, and
#                               kmod-wireguard is not among them, because nothing
#                               in the M2 list needs it.  `apk add kmod-wireguard`
#                               against that archive 404s, which reads like a
#                               broken repository rather than a module nobody
#                               selected.
#                        all    every module this target's kernel config can
#                               build.  Bigger archive and a longer build.
#                        a,b,c  exactly these packages, selected as =m: built and
#                               published, but not installed into the image.  The
#                               image has 0x3A0000 of mtd4 to fit in, so a module
#                               the user installs later must not be in it.
#   --with-pon         apply the stage 2 xPON patches (NOT functional yet)
#   --mt76-debug       also apply the diagnostic mt76 patch (never ship this)
#   --imagebuilder     additionally produce the self-contained Image Builder
#   --no-apply         skip apply-overlay.sh (assume the overlay is already in)
#   -j N, --jobs N     build parallelism (default: number of CPUs)
#                      -jN and --jobs=N are accepted too, as `make` accepts them
#   -h, --help         this text
#
# Environment:
#   BUILD_TARGET     the make target, default `world`.  Setting it runs one stage
#                    only and skips the artifact report, which is how
#                    .github/workflows/kernel-patches.yml reaches the kernel patch
#                    series in minutes: BUILD_TARGET=target/linux/prepare fails in
#                    twenty seconds when a patch cannot apply, instead of forty
#                    minutes into a build that was going to fail anyway.
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
WITH_FEEDS=1
MT76_DEBUG=0
IMAGEBUILDER=0
DO_APPLY=1
VARIANT=full
KMODS=image
PKGS_FILE=""
JOBS=$(nproc 2>/dev/null || echo 4)
OWRT_ARG=""

while [ $# -gt 0 ]; do
	case "$1" in
		--initramfs)    INITRAMFS=1 ;;
		--no-initramfs) INITRAMFS=0 ;;
		--debug-kmods)  DEBUG_KMODS=1 ;;
		--no-packages)  WITH_PACKAGES=0 ;;
		--no-feeds)     WITH_FEEDS=0 ;;
		--variant)      VARIANT="${2:?--variant needs m2 or full}"; shift ;;
		--packages)     PKGS_FILE="${2:?--packages needs a file}"; shift ;;
		--kmods)        KMODS="${2:?--kmods needs image, all or a package list}"; shift ;;
		--with-pon)     WITH_PON=1 ;;
		--mt76-debug)   MT76_DEBUG=1 ;;
		--imagebuilder) IMAGEBUILDER=1 ;;
		--no-apply)     DO_APPLY=0 ;;
		# Both spellings, because `make -j8` is muscle memory: the examples in
		# this repository's own documentation use -j8, and the workflow passed
		# `-j"$(nproc)"`, which arrives as `-j4`.  Only `-j 4` was accepted, so
		# the build died with "unknown option: -j4" before it built anything.
		-j|--jobs)      JOBS="${2:?--jobs needs a number}"; shift ;;
		-j[0-9]*)       JOBS="${1#-j}" ;;
		--jobs=[0-9]*)  JOBS="${1#--jobs=}" ;;
		-h|--help)      awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
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

case "$VARIANT" in
	m2|full) ;;
	*) echo "!! --variant must be m2 or full, not '$VARIANT'" >&2; exit 2 ;;
esac

# --kmods takes image (the default), all, or a comma-separated package list.  A
# name is taken at face value: the post-defconfig gate below reports any name this
# tree turns out not to have, which is more useful than a list of names this script
# believes are allowed to exist.
case "$KMODS" in
	image|all) ;;
	'') echo "!! --kmods needs image, all or a package list" >&2; exit 2 ;;
	*[!A-Za-z0-9_,+-]*)
		echo "!! --kmods takes image, all, or a comma-separated list of package" >&2
		echo "   names; '$KMODS' is none of those" >&2
		exit 2 ;;
esac

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
# (2) Feeds
#
# A fresh clone of OpenWrt has no feeds/ directory at all, and everything this
# board wants beyond the bare system -- LuCI, the AP daemon, iperf3, i2c-tools --
# lives in one of them.  Left alone, `make defconfig` drops CONFIG_PACKAGE_luci
# without complaining and the image comes out with no web UI at all; the gate
# after defconfig below exists to catch exactly that.  Measured on this board's
# own tree before feeds were installed: feeds/ held only `base`,
# `grep -E '^CONFIG_FEED_' .config` was empty, and feeds/luci did not exist, so
# LuCI could not be enabled at all.
#
# The feeds follow their own branch heads rather than the revision pinned in
# pin.env, so a rebuild months later picks up newer feed packages.  The revisions
# actually used are printed below and belong in any bug report.
# ---------------------------------------------------------------------------
if [ "$WITH_FEEDS" = "1" ]; then
	if [ -d "$OWRT/feeds/luci" ] && [ -d "$OWRT/package/feeds/luci" ]; then
		echo "==> Feeds already installed, leaving them alone"
	else
		echo "==> ./scripts/feeds update -a && ./scripts/feeds install -a"
		( cd "$OWRT" && ./scripts/feeds update -a && ./scripts/feeds install -a )
	fi
	if [ -d "$OWRT/feeds" ]; then
		echo "    feed revisions in use:"
		for f in "$OWRT"/feeds/*/; do
			[ -d "$f/.git" ] || continue
			printf '      %-12s %s\n' "$(basename "$f")" \
				"$(git -C "$f" log -1 --format='%h %ad' --date=short 2>/dev/null || echo '?')"
		done
	fi
	echo
else
	echo "==> --no-feeds: not touching $OWRT/feeds"
	echo
fi

# ---------------------------------------------------------------------------
# (3) Seed .config
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

# Turn a bool off, in the spelling kconfig itself uses.  `CONFIG_FOO=n` is valid
# input but `make defconfig` rewrites it to `# CONFIG_FOO is not set`, so that is
# what has to be written here and what the check further down has to look for --
# seeding `=n` would make the symbol look like it never survived.
set_cfg_off() {
	local key="$1"
	if grep -q "^${key}=" "$CFG"; then
		sed -i "s|^${key}=.*|# ${key} is not set|" "$CFG"
	elif ! grep -q "^# ${key} is not set" "$CFG"; then
		printf '# %s is not set\n' "$key" >> "$CFG"
	fi
	printf '# %s is not set\n' "$key" >> "$SEEDED"
	echo "    # ${key} is not set"
}

# Print why the build failed.  An OpenWrt parallel build writes each sub-build's
# output to logs/ instead of the terminal, so the top-level report names a directory
# and nothing else -- "ERROR: target/linux failed to build" and a suggestion to re-run
# with V=s.  Two CI runs ended on that line with the reason in a file on a runner that
# was about to be destroyed, so the directory is taken from that line and its log is
# printed here; build.yml uploads logs/ as well, for what does not fit.
report_build_failure() { # report_build_failure <captured-make-output> <owrt-tree>
	local log="$1" owrt="$2" failed found f
	failed=$(sed -n 's/^ *ERROR: \(.*\) failed to build.*/\1/p' "$log" | head -1)
	echo
	echo "!! the build failed: the directory that failed is '${failed:-unknown}'"
	if [ ! -d "$owrt/logs" ]; then
		echo "    (there is no $owrt/logs directory to read)"
	else
		found=0
		while IFS= read -r f; do
			found=1
			echo
			echo "--- $f (last 80 lines)"
			tail -n 80 "$f"
		done < <(find "$owrt/logs" -type f -name '*.txt' \
			\( -path "*${failed:-/no-such-directory}*" -o -mmin -20 \) \
			2>/dev/null | head -20)
		[ "$found" -eq 1 ] || echo "    (nothing in $owrt/logs matched)"
	fi
	# The tree does not always leave a log to read: the failure of `target/linux`
	# after the toolchain builds writes nothing to logs/ at all -- the directory does
	# not even exist -- and the only trace left is what make printed.  Print that
	# too, always, because throwing away the one artefact the runner still has is
	# how a failure becomes "a directory failed to build" and nothing else.
	echo
	echo "--- the last 30 lines make printed"
	tail -n 30 "$log"
	# ...and thirty lines of `make[3] -C foo compile` is not a reason.  logs/ would
	# hold one, but it is only written when CONFIG_BUILD_LOG=y, whose prompt is
	# `if DEVEL` -- and CONFIG_DEVEL must not be set for a release image, so seeding
	# CONFIG_BUILD_LOG does not survive make defconfig (the seed gate says so, and
	# that is how this was found).  The reason is still obtainable: re-run the one
	# directory that failed with V=s, which is what a person does by hand.  The
	# kernel's configure step, the case this was written for, fails in twenty
	# seconds, so it is cheap there and bounded everywhere else.
	if [ -n "${failed:-}" ] && [ -d "$owrt/$failed" ] && [ "${BUILD_LOG_RERUN:-1}" = "1" ]; then
		local runner=""
		command -v timeout >/dev/null 2>&1 && runner="timeout 900"
		echo
		echo "--- re-running '$failed' with V=s, because there is no logs/ to read"
		echo "    (CONFIG_BUILD_LOG only has a prompt when CONFIG_DEVEL is set)"
		( cd "$owrt" && $runner make -C "$failed" compile V=s 2>&1 | tail -n 80 ) || true
	fi
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
else
	# Clear it actively rather than merely not setting it.  An earlier --initramfs
	# build leaves `CONFIG_TARGET_ROOTFS_INITRAMFS=y` in .config, defconfig keeps
	# it, and the update-sysupgrade image then carries a kernel with the initramfs
	# embedded in it: MEASURED 12,058,913 B with the squashfs at 0x760000 against
	# 9,437,473 B at 0x3A0000.  Not setting the symbol is how that image was
	# produced, and docs/sysupgrade.md recorded the hole without closing it.
	#
	# CONFIG_TARGET_INITRAMFS_COMPRESSION_NONE does not need clearing with it:
	# that option only decides how an initramfs is compressed once one is being
	# embedded at all, and it is what turned the 12.0 MB case into 14.4 MB.
	set_cfg_off "CONFIG_TARGET_ROOTFS_INITRAMFS"
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
# Do *not* seed CONFIG_BUILD_LOG here.  It looks like the answer -- OpenWrt writes
# each sub-build's output to logs/ when it is set, which is what the log upload and
# report_build_failure() both want -- but its prompt is `bool "..." if DEVEL`, so
# without CONFIG_DEVEL make defconfig drops it, and the post-defconfig gate then
# reports the symbol this script itself wrote.  Measured: that is exactly what
# happened when it was tried.  CONFIG_DEVEL is not acceptable in a release image.
# On failure the script re-runs the failing directory with V=s instead.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# (2c) Packages
#
# The target is source-only, so anything the image needs must be selected at
# build time.  Two lists: scripts/packages.append (variant full) carries the
# optical + xPON + OMCI stack, scripts/packages-m2.append (variant m2, the one
# published as a release asset) stops at Ethernet + Wi-Fi + LuCI + apk.
# ---------------------------------------------------------------------------
if [ "$WITH_PACKAGES" = "1" ]; then
	if [ -z "$PKGS_FILE" ]; then
		case "$VARIANT" in
			m2)   PKGS_FILE="$HERE/packages-m2.append" ;;
			full) PKGS_FILE="$HERE/packages.append" ;;
		esac
	fi
	if [ ! -f "$PKGS_FILE" ]; then
		echo "!! $PKGS_FILE is missing" >&2
		exit 1
	fi
	echo "==> Seeding packages from $(basename "$PKGS_FILE") (variant $VARIANT)"
	while IFS= read -r line; do
		case "$line" in
			CONFIG_*=*) ;;
			*) continue ;;
		esac
		set_cfg "${line%%=*}" "${line#*=}"
	done < "$PKGS_FILE"
fi

# ---------------------------------------------------------------------------
# (2d) Kernel modules the image does not need
#
# The target is source-only, so nothing arrives from an OpenWrt feed later: what
# is not built here cannot be installed on the board, and the archive published
# for a release can only hold what this build produced.  The image's own package
# list decides 46 of them (MEASURED, v0.1.0-m2) and leaves out everything else --
# kmod-wireguard among it, which is why `apk add kmod-wireguard` against that
# archive 404s.  --kmods widens the set.
#
# =m rather than =y: a package selected =y is installed into the image, and the
# persistent image has 0x3A0000 of mtd4 to fit in.  =m builds and publishes the
# package without installing it, which is the whole point of an archive users
# install from later.
# ---------------------------------------------------------------------------
# >>> kmods-seeding (extracted by tools/test_build_firmware.sh)
if [ "$KMODS" = "all" ]; then
	echo "==> Seeding CONFIG_ALL_KMODS=y (every module this kernel config can build)"
	set_cfg "CONFIG_ALL_KMODS" "y"
elif [ "$KMODS" != "image" ]; then
	KMOD_LIST=$(printf '%s' "$KMODS" | tr ',' ' ')
	echo "==> Seeding extra kernel modules as =m: $KMOD_LIST"
	# shellcheck disable=SC2086
	for kmod in $KMOD_LIST; do
		set_cfg "CONFIG_PACKAGE_$kmod" "m"
	done
fi
# <<< kmods-seeding

# ---------------------------------------------------------------------------
# The target kernel config must not ask for modules whose sources this repository
# does not carry.  This is what killed run 38635021287: 0006 and 0007 used to be
# steps 6 and 7 of the default series, so even the M2 build -- the one that is
# supposed to hold no optical and no xPON code at all -- put CONFIG_XPON=m,
# CONFIG_XPON_OMCI=m, CONFIG_XPON_OAM=m, CONFIG_PHY_AIROHA_XPON=m,
# CONFIG_AIROHA_XPON_V1=m and CONFIG_OPTICAL_FRONTEND=m into
# target/linux/airoha/en7523/config-6.18.  The kernel then went looking for
# net/xpon/ and drivers/net/optical/, which exist only in the community
# airoha_en7523_all branch, and `make target/linux/compile` died eighteen seconds
# in -- after forty-four minutes of toolchain work, with the reason in no log on
# the runner.  They live in openwrt/pon/buildroot-patches/ now and only --with-pon
# applies them.  Checking the config here costs nothing and fails while the
# toolchain has not been built yet.
# ---------------------------------------------------------------------------
check_target_kernel_config() { # check_target_kernel_config <config-file> <with-pon>
	local kcfg="$1" with_pon="$2" absent
	[ "$with_pon" = "1" ] && return 0
	[ -f "$kcfg" ] || return 0
	absent=$(grep -E '^CONFIG_(XPON|XPON_OMCI|XPON_OAM|PHY_AIROHA_XPON|AIROHA_XPON_V1|OPTICAL_FRONTEND)=' "$kcfg" || true)
	[ -n "$absent" ] || return 0
	echo "!! the target kernel config asks for modules that are not in this repository:" >&2
	printf '%s\n' "$absent" | sed 's/^/    /' >&2
	cat >&2 <<'EOF'
   net/xpon/** and drivers/net/optical/** come from the community
   airoha_en7523_all branch.  The kernel stage would fail looking for them about
   twenty seconds in, with the reason in no log at all.  Those symbols belong to
   openwrt/pon/buildroot-patches/0006 and 0007, which only --with-pon applies: a
   build without --with-pon must not set any of them.
EOF
	return 1
}

KCFG="$OWRT/target/linux/$TARGET/$SUBTARGET/config-$KERNEL_SERIES"
check_target_kernel_config "$KCFG" "$WITH_PON" || exit 1

# ---------------------------------------------------------------------------
# (4) Build
# ---------------------------------------------------------------------------
echo
echo "==> make defconfig"
( cd "$OWRT" && make defconfig )

echo
echo "==> Verifying the seeded symbols survived defconfig"
MISSING=0
MISSING_OFF=""
while IFS= read -r want; do
	[ -n "$want" ] || continue
	if ! grep -qx "$want" "$CFG"; then
		echo "    MISSING  $want" >&2
		MISSING=$((MISSING + 1))
		# Symbols this script turned *off* are spelled the way kconfig spells
		# them.  If one of those does not come back in that form, the fault is
		# this script's spelling rather than the tree's configuration, and the
		# generic advice below would send the reader the wrong way.
		case "$want" in
			'#'*) MISSING_OFF="$want" ;;
		esac
	fi
done < "$SEEDED"
if [ "$MISSING" -ne 0 ]; then
	if [ -n "$MISSING_OFF" ]; then
		cat >&2 <<EOF

   A symbol this script turned OFF did not come back as '$MISSING_OFF'.
   That spelling is kconfig's own ('CONFIG_FOO=n' is rewritten to '# CONFIG_FOO
   is not set'), so if kconfig wrote something else -- or dropped the symbol
   because it is not visible in this tree -- then set_cfg_off in this script is
   wrong, not your .config.  tools/test_build_firmware.sh covers that spelling.
EOF
	fi
	cat >&2 <<'EOF'

!! Seeded symbol(s) did not survive make defconfig.

   defconfig drops a symbol whose dependencies are not available in this tree,
   and the usual reason is a feed that is not enabled or a package name that no
   longer exists.  Building anyway produces an image that is silently missing
   files (no AP daemon, no web UI), which is much harder to diagnose than a
   failure here.  Fix the symbol, or pass --no-packages if you really want the
   bare image.

   A name passed to --kmods that this tree has no package definition for lands in
   the MISSING list above for the same reason, and --no-packages is not the fix
   for it.  What is not selected is not built, and a module that is not built
   cannot be in the published archive: check the name against
   package/kernel/linux/modules/ in the OpenWrt tree, and see docs/packages.md.
EOF
	# The `full` variant seeds the optical and xPON packages, and those are declared
	# by openwrt/pon/buildroot-patches/0006-0007, which only --with-pon applies.  Say
	# so, rather than leaving the reader to work out why the names vanished.
	if [ "$WITH_PON" != "1" ] && [ "$VARIANT" = "full" ]; then
		echo
		echo "   This is the 'full' variant: it seeds kmod-optical-frontend and the five" >&2
		echo "   xPON kmods, which the default series does not declare.  Add --with-pon," >&2
		echo "   or use --variant m2, whose package set needs neither." >&2
	fi
	exit 1
fi
echo "    all $(grep -c . "$SEEDED") symbol(s) present"

# ---------------------------------------------------------------------------
# A flag that survived is not the same as an effect.  `make defconfig` keeps the
# values the .config it reads already carries -- including
# `# CONFIG_PACKAGE_kmod-wireguard is not set` -- and applies a default only to
# symbols it has not seen.  So a tree that has already been through defconfig
# without --kmods keeps every module off even when CONFIG_ALL_KMODS=y is seeded
# into it: the flag is in .config, the gate above passes, and the archive
# published from that build is lean with nothing to show why.  MEASURED, run
# 39218437654, which did exactly that by running this script twice in one job:
# 45 kmod package(s) =y, 0 =m, kmod-wireguard not set.  Count the effect here
# rather than trusting the flag; KMODS_ALL_MIN is the floor below which an
# all-kmods selection cannot plausibly be real (the stale case leaves 0, the
# image's own set is 46, a real all-kmods config leaves hundreds).
# ---------------------------------------------------------------------------
# >>> kmods-effect (extracted by tools/test_build_firmware.sh)
KMODS_ALL_MIN=${KMODS_ALL_MIN:-100}
if [ "$KMODS" = "all" ]; then
	KMODS_M=$(grep -cE '^CONFIG_PACKAGE_kmod-[A-Za-z0-9_+-]*=m$' "$CFG" || true)
	KMODS_Y=$(grep -cE '^CONFIG_PACKAGE_kmod-[A-Za-z0-9_+-]*=y$' "$CFG" || true)
	echo "    $KMODS_Y kernel module(s) =y (in the image), $KMODS_M =m (built and published)"
	if [ "$KMODS_M" -lt "$KMODS_ALL_MIN" ]; then
		cat >&2 <<EOF

!! --kmods all selected only $KMODS_M kernel module(s) as =m, fewer than the
   $KMODS_ALL_MIN this check treats as a real selection.  CONFIG_ALL_KMODS=y is in
   .config, so --kmods all did what it was asked to; the selection still did not
   happen.  That is what reusing a .config produces: defconfig keeps the
   '# CONFIG_PACKAGE_kmod-... is not set' lines an earlier run wrote, and a default
   is only applied to symbols it has not seen.  The archive built from this tree
   would hold the image's own $KMODS_Y modules and nothing else.

   Start from a fresh configuration and build again:

       rm -f $CFG

   and see docs/packages.md, "Which modules a release publishes".
EOF
		exit 1
	fi
elif [ "$KMODS" != "image" ]; then
	KMODS_BAD=""
	for kmod in $KMOD_LIST; do
		grep -qE "^CONFIG_PACKAGE_$kmod=[my]$" "$CFG" || KMODS_BAD="$KMODS_BAD $kmod"
	done
	if [ -n "$KMODS_BAD" ]; then
		cat >&2 <<EOF

!! --kmods asked for kernel module(s) that are not selected in .config:
      $KMODS_BAD

   A package the tree does not know is reported by the gate above.  A package the
   tree does know and still did not select is the reuse case: defconfig keeps the
   '# CONFIG_PACKAGE_kmod-... is not set' line an earlier run left, so the seed was
   rewritten by the gate and then ignored by this one.  Start from a fresh
   configuration:

       rm -f $CFG
EOF
		exit 1
	fi
fi
# <<< kmods-effect

echo
echo "==> make -j$JOBS"
# An OpenWrt parallel build writes each sub-build's output to logs/ instead of the
# terminal, so a failure inside target/linux prints "ERROR: target/linux failed to
# build" and nothing else: two CI runs ended on that one line, with the reason
# sitting in a file on a runner that was about to be destroyed.  Keep the output,
# name the directory that failed, and print its log, so the reason reaches whoever
# reads the CI log -- build.yml uploads logs/ as well, for what does not fit here.
BUILD_LOG=$(mktemp)
trap 'rm -f "$BUILD_LOG"' EXIT
MAKE_ARGS=(-j"$JOBS")
if [ -n "${BUILD_TARGET:-}" ]; then
	echo "    BUILD_TARGET=$BUILD_TARGET (a partial build: no images are produced)"
	MAKE_ARGS+=("$BUILD_TARGET")
fi
set +e
( cd "$OWRT" && make "${MAKE_ARGS[@]}" ) 2>&1 | tee "$BUILD_LOG"
MAKE_RC=${PIPESTATUS[0]}
set -e
if [ "$MAKE_RC" -ne 0 ]; then
	report_build_failure "$BUILD_LOG" "$OWRT"
	exit 1
fi
rm -f "$BUILD_LOG"

# ---------------------------------------------------------------------------
# (5) Report
# ---------------------------------------------------------------------------
# BUILD_TARGET stops at one stage, so there is nothing in bin/ to report and no
# reason to pretend otherwise: the point of that mode is the failure, if there is
# one, and it did not happen.  kernel-patches.yml uses it to reach the kernel patch
# series in minutes instead of hours.
if [ -n "${BUILD_TARGET:-}" ]; then
	echo
	echo "==> $BUILD_TARGET finished with $MAKE_RC; a partial build, so no artifacts are expected"
	exit 0
fi

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
# (5b) Sanity-check the sysupgrade image
#
# The persistent image must carry the PLAIN kernel.  When the same tree also
# builds an initramfs image (--initramfs, on by default), the kernel can end up
# with the initramfs cpio embedded in it, and the sysupgrade image inherits that:
# MEASURED 14,418,209 B with the squashfs at 0x880000, and a second one at
# 12,058,913 B with the squashfs at 0x760000, instead of 9,437,473 B with the
# squashfs at 0x3A0000.  The two kernel Images of that build had the same md5,
# which is what identifies it.
#
# --no-initramfs now clears CONFIG_TARGET_ROOTFS_INITRAMFS instead of only
# leaving it alone, so an inflated image here is no longer the flag's doing: it
# means the kernel was not actually rebuilt (an incremental build that kept a
# stale arch/arm/boot/Image), or that the tree carries an initramfs of its own
# under target/linux.  Both are worth stopping for.
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
# The gate itself lives in tools/verify_image.py, so the same code runs here
# and in CI.  --warn-only is deliberate: building with --initramfs (on by
# default) legitimately produces an image whose squashfs sits past the kernel
# partition, and that is a development artifact, not a build failure.  CI runs
# the same tool without --warn-only, so such an image is never published.
if command -v python3 >/dev/null 2>&1; then
	echo
	echo "==> Checking the sysupgrade image(s)"
	IMGS=("$BIN"/*-sysupgrade.bin)
	if [ -e "${IMGS[0]}" ]; then
		python3 "$REPO/tools/verify_image.py" --warn-only "${IMGS[@]}"
	else
		echo "    (no sysupgrade image produced)"
	fi
fi

cat <<EOF

==> Which artifact is which

  *-initramfs-kernel.bin   RAM-boot over UART/YMODEM, nothing is written to
                           flash.  This is the safe way to try a build.
  *-sysupgrade.bin         the persistent image; belongs in slot B
                           (mtd3, "tclinux_slave").

==> Verify before flashing

  python3 $REPO/tools/verify_build.py <image>    # FIT load/entry vs _text
  python3 $REPO/tools/verify_image.py <image>    # rootfs fits the kernel partition

verify_build.py checks that the FIT load/entry address is 0x80208000.  Get this
wrong and the kernel deadloops in head.S before it can print anything, leaving
the UART completely silent with no diagnostic.  See docs/booting.md.

verify_image.py is the flash gate for a sysupgrade image: mtdsplit_fit derives
the kernel partition from the FIT totalsize, so an image whose squashfs starts
past mtd4 (0x3A0000) cannot be split correctly by sysupgrade.  CI fails on it; a
local build only warns, because --initramfs is on by default here.  See
docs/sysupgrade.md.
EOF
