#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Sysupgrade support for the Airoha EN7523 family.
#
# Storage model
# -------------
# The bootloader loads a FIT image (kernel, optionally + squashfs rootfs) from the
# "tclinux_slave" partition.  That partition is declared in the board DTS with
#
#	compatible = "denx,fit";
#
# so the kernel's mtdsplit_fit parser (CONFIG_MTD_SPLIT_FIT_FW) splits it at boot
# into "kernel", "rootfs" and - via CONFIG_MTD_SPLIT_SQUASHFS_ROOT - "rootfs_data".
#
# Consequence for the upgrade: the split child partitions are *derived*, they must
# never be written directly.  The whole sysupgrade image is written over the parent
# partition ("tclinux_slave"), exactly like the vendor A/B scheme does for slot B.
#
# Verified on hardware (Econet vGP-42X6V1, EN7523, Winbond W25N01K):
#   mtd erase /dev/mtd3                       -> 1.02 s, partition reads back 0xff
#   mtd write <7.7 MB payload> /dev/mtd3      -> 2.90 s
#   read-back + mtd verify                    -> identical, "Success"
# Note: writing over non-erased NAND pages silently stores (old AND new) and
# corrupts ECC, so the erase step is mandatory.  "mtd write" erases by default;
# never use plain "dd" against /dev/mtdN for firmware.

# ---------------------------------------------------------------------------
# sysupgrade -n  ("do not keep configuration" == clean install)
#
# /overlay is a UBIFS volume on its own MTD partition ("data"), so the image
# write into "tclinux_slave" never touches it: a "clean install" would still
# boot with the previous configuration.  Worse, /bin/config_generate only runs
# /bin/board_detect when /etc/board.json is missing
#	[ -s $CFG ] || /bin/board_detect || exit 1
# so the stale /etc/board.json also stops the board.d scripts from ever running
# again -- observed on hardware: a freshly flashed image kept the old
# conduit-only bridge and ignored the new 02_network.  Do the reset ourselves
# and let the next boot rebuild the config from board.d.
#
# How "-n" is detected, and where the reset runs (both read out of the sources
# that shipped in the image, procd-2026.09.27~675942be + base-files):
#
#   * SAVE_CONFIG is *not* usable here.  It is set in /sbin/sysupgrade's own
#     shell (line 37 default, line 41 for -n), but it is never exported into
#     stage 2 nor forwarded in the ubus payload; $R/lib/upgrade/stage2 only
#     exports IMAGE/COMMAND/INTERACTIVE/VERBOSE/CONFFILES.
#   * The signal that *does* survive is UPGRADE_BACKUP:
#       /sbin/sysupgrade:445   json_add_string backup "$CONF_TAR"   # only if SAVE_CONFIG=1
#       procd sysupgrade.c     if (backup) setenv("UPGRADE_BACKUP", backup, 1);
#       -> non-empty = keep the config, empty/unset = "-n" = clean install.
#   * stage 2 runs in the REAL root, not in a scratch chroot: procd chroots to
#     prefix=/tmp/root before exec'ing /sbin/upgraded, but upgraded.c escapes it
#     immediately ( open("/") ; chroot(".")  <- cwd is still the real "/" ;
#     fchdir(fd) ) and only then execs /lib/upgrade/stage2.  So the hook below
#     sees the live /overlay mounted read-write.
#   * The reset itself deletes the OLD system's files directly in the overlay
#     upperdir (/overlay/upper), not through the merged view, so that the
#     conffiles shipped by the NEW image stay visible (see platform_wipe_config).
#   * platform_pre_upgrade() is the only hook stage 2 calls before
#     switch_to_ramfs (lib/upgrade/stage2:165).  It must not be put into
#     platform_check_image(): that one also runs for "sysupgrade -T", which
#     validates the image and then exits without upgrading anything.
# ---------------------------------------------------------------------------

WIPE_LOG=/root/sysupgrade-wipe.log

# Delete what the OLD system created on top of the read-only rootfs, working
# directly inside the overlay upperdir instead of going through the merged view.
# The difference matters, and it was measured on the image with unsquashfs:
#
#   * the new image ships /etc/config/dhcp, /etc/config/dropbear and
#     /etc/config/firewall inside the squashfs;
#   * "rm -rf /etc/config; mkdir /etc/config" through the merged view leaves an
#     empty upper directory, i.e. it HIDES those three conffiles - dnsmasq,
#     dropbear and the firewall would then start without their defaults, which
#     is a good way to lose the network after the reboot;
#   * removing only the upper copies reproduces a fresh installation exactly,
#     because a fresh installation is "image + empty overlay": the shipped
#     conffiles become visible again, while /etc/board.json (which is NOT part of
#     the image) disappears, so /bin/board_detect regenerates it on the next boot
#     and /etc/board.d/02_network finally runs.
#
# The upper directory is recreated with a plain mkdir (not rmdir+mkdir through
# the merged view) so overlayfs never marks it opaque, and /etc/dropbear is
# deliberately left alone: /etc/dropbear/authorized_keys is the way back in if
# the flashed image does not come up.
platform_wipe_config() {
	local ovl=/overlay/upper

	{
		echo "--- $(date) wipe (sysupgrade -n) ---"
		echo "mounts:"; /bin/mount
		echo "/etc/config before:"; ls -la /etc/config 2>&1
		echo "/etc/board.json before:"; ls -l /etc/board.json 2>&1
		echo "$ovl/etc before:"; ls -la $ovl/etc 2>&1
	} >> $WIPE_LOG 2>&1

	if [ -d "$ovl/etc" ]; then
		rm -rf "$ovl/etc/config" "$ovl/etc/board.json"
		mkdir -p "$ovl/etc/config"
		chmod 0755 "$ovl/etc/config"
		echo "wiped upperdir: $ovl/etc/{config,board.json}" >> $WIPE_LOG
	else
		# No overlay upperdir found: fall back to the merged view. Less
		# exact, but still better than doing nothing.
		rm -rf /etc/config /etc/board.json
		mkdir -p /etc/config
		echo "wiped merged view (no $ovl/etc)" >> $WIPE_LOG
	fi
	sync

	{
		echo "result:"
		echo "/etc/config after (conffiles of the new image must show up):"
		ls -la /etc/config 2>&1
		echo "$ovl/etc after:"; ls -la $ovl/etc 2>&1
		echo "/etc/board.json after:"; ls -l /etc/board.json 2>&1
	} >> $WIPE_LOG 2>&1
}

# Called by /lib/upgrade/stage2 before it switches to the ramfs, i.e. while the
# running system (and its /overlay) is still fully available.
platform_pre_upgrade() {
	[ -n "$UPGRADE_BACKUP" ] && return 0	# user asked to keep the config

	platform_wipe_config

	# Mirror the decision onto the console for a serial capture.
	echo "platform_pre_upgrade: clean install (no UPGRADE_BACKUP), config wiped" \
		> /dev/kmsg 2>/dev/null

	return 0
}

platform_check_image() {
	local board=$(board_name)

	case "$board" in
	econet,vgp-42x6v1)
		return 0
		;;
	esac

	return 1
}

platform_do_upgrade() {
	local board=$(board_name)

	case "$board" in
	econet,vgp-42x6v1)
		# Parent partition holding the FIT; mtdsplit_fit re-derives
		# kernel/rootfs/rootfs_data from it after the next boot.
		PART_NAME="tclinux_slave"
		;;
	*)
		return 1
		;;
	esac

	# The config reset happens in platform_pre_upgrade(), see the header.
	default_do_upgrade "$1"
}
