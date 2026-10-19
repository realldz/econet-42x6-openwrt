#!/usr/bin/env bash
# Exercise set_cfg() / set_cfg_off() from build-firmware.sh against a fake .config,
# and report_build_failure() against a fake build tree.
#
# Why this is worth a test: these two helpers decide what lands in .config before
# `make defconfig`, and the SEEDED file they write is what the post-defconfig gate
# greps for.  The two halves have to agree on spelling, and kconfig rewrites
# `CONFIG_FOO=n` as `# CONFIG_FOO is not set` -- so seeding an off symbol as `=n`
# would make the gate report a symbol it had just written itself, and the build
# would abort with a message that makes no sense.
#
# The specific hole this covers is the one in docs/sysupgrade.md: --no-initramfs
# used to leave a stale `=y` behind, and the sysupgrade image built that way was
# 12,058,913 B with the squashfs at 0x760000 instead of 9,437,473 B at 0x3A0000.
#
# It also covers the two ways that check can be fooled: a selection that never
# took effect because defconfig kept an older .config, and an exclusion that
# did not hold -- which is how kmod-ipt-rtpengine reaches a telephony daemon's
# package directory and kills a release build there (run 39219693393).
#
# It also covers the check that a --kmods selection took effect, which is a
# different question from whether the flag survived: `make defconfig` keeps the
# values the .config it reads already has, so a second run over a tree that was
# configured without --kmods leaves CONFIG_ALL_KMODS=y in place and every module
# still off.  MEASURED, run 39218437654: 45 kmod package(s) =y, 0 =m.
#
# Usage: tools/test_build_firmware.sh      (no dependencies beyond bash/sed/grep)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The helpers are pulled out of the script rather than copied, so this cannot
# drift into testing a stale duplicate of them.
sed -n '/^set_cfg() {/,/^}/p;/^set_cfg_off() {/,/^}/p;/^report_build_failure() {/,/^}/p;/^check_target_kernel_config() {/,/^}/p' \
	scripts/build-firmware.sh > "$WORK/helpers.sh"
# The selection-effect check is top-level code rather than a function, so it is
# extracted on its own and run in a subshell with the variables it reads.
sed -n '/^# >>> kmods-effect/,/^# <<< kmods-effect$/p' scripts/build-firmware.sh > "$WORK/kmods-effect.sh"
if [ ! -s "$WORK/kmods-effect.sh" ]; then
	echo "!! could not extract the --kmods selection check from scripts/build-firmware.sh"
	exit 1
fi
if [ ! -s "$WORK/helpers.sh" ]; then
	echo "!! could not extract set_cfg/set_cfg_off/report_build_failure/check_target_kernel_config from scripts/build-firmware.sh"
	exit 1
fi
# shellcheck disable=SC1090,SC1091
. "$WORK/helpers.sh"

fails=0
check() { # check <label> <exact-line> <file>
	if grep -qx "$2" "$3"; then
		echo "  ok   $1"
	else
		echo "  FAIL $1: expected the line '$2'"
		sed 's/^/       /' "$3"
		fails=$((fails + 1))
	fi
}
check_absent() { # check_absent <label> <exact-line> <file>
	if grep -qx "$2" "$3"; then
		echo "  FAIL $1: '$2' is still present"
		fails=$((fails + 1))
	else
		echo "  ok   $1"
	fi
}

echo "== a symbol that is currently =y, turned off (the stale-=y case)"
CFG=$(mktemp); SEEDED=$(mktemp)
printf 'CONFIG_TARGET_ROOTFS_INITRAMFS=y\nCONFIG_KERNEL_DEVTMPFS=y\n' > "$CFG"
set_cfg_off "CONFIG_TARGET_ROOTFS_INITRAMFS" >/dev/null
check_absent "the =y line is gone" "CONFIG_TARGET_ROOTFS_INITRAMFS=y" "$CFG"
check "written the way kconfig writes it" "# CONFIG_TARGET_ROOTFS_INITRAMFS is not set" "$CFG"
check "and seeded in that same form" "# CONFIG_TARGET_ROOTFS_INITRAMFS is not set" "$SEEDED"
check "nothing else was touched" "CONFIG_KERNEL_DEVTMPFS=y" "$CFG"

echo "== a symbol that is absent from .config"
CFG=$(mktemp); SEEDED=$(mktemp)
: > "$CFG"
set_cfg_off "CONFIG_TARGET_ROOTFS_INITRAMFS" >/dev/null
check "appended when missing" "# CONFIG_TARGET_ROOTFS_INITRAMFS is not set" "$CFG"

echo "== a symbol that is already off, applied twice"
CFG=$(mktemp); SEEDED=$(mktemp)
printf '# CONFIG_TARGET_ROOTFS_INITRAMFS is not set\n' > "$CFG"
set_cfg_off "CONFIG_TARGET_ROOTFS_INITRAMFS" >/dev/null
set_cfg_off "CONFIG_TARGET_ROOTFS_INITRAMFS" >/dev/null
count=$(grep -c 'CONFIG_TARGET_ROOTFS_INITRAMFS' "$CFG")
if [ "$count" = "1" ]; then
	echo "  ok   still exactly one line (idempotent)"
else
	echo "  FAIL duplicated: $count lines"; fails=$((fails + 1))
fi

echo "== set_cfg wins over an off line"
CFG=$(mktemp); SEEDED=$(mktemp)
printf '# CONFIG_TARGET_ROOTFS_INITRAMFS is not set\n' > "$CFG"
set_cfg "CONFIG_TARGET_ROOTFS_INITRAMFS" "y" >/dev/null
check "the off line became =y" "CONFIG_TARGET_ROOTFS_INITRAMFS=y" "$CFG"
check "and seeded as =y" "CONFIG_TARGET_ROOTFS_INITRAMFS=y" "$SEEDED"

echo "== set_cfg replaces rather than appends"
CFG=$(mktemp); SEEDED=$(mktemp)
printf 'CONFIG_TARGET_ROOTFS_INITRAMFS=n\n' > "$CFG"
set_cfg "CONFIG_TARGET_ROOTFS_INITRAMFS" "y" >/dev/null
count=$(grep -c 'CONFIG_TARGET_ROOTFS_INITRAMFS' "$CFG")
if [ "$count" = "1" ]; then
	echo "  ok   exactly one line"
else
	echo "  FAIL duplicated: $count lines"; fails=$((fails + 1))
fi

echo
echo "== the flags the documentation and CI actually pass"
# The whole option loop, extracted the same way, so a spelling that stops being
# accepted fails here instead of 20 seconds into a 2-3 hour CI run.  It has: the
# workflow passed -j"$(nproc)" (which arrives as -j4) while the parser only took
# `-j 4`, and the build died with "unknown option: -j4" -- yet the repository's own
# examples showed -j8 the whole time.
{
	sed -n '/^INITRAMFS=1$/,/^done$/p' scripts/build-firmware.sh
	echo 'printf "%s|%s|%s|%s|%s|%s\n" "$JOBS" "$VARIANT" "$INITRAMFS" "$WITH_FEEDS" "$OWRT_ARG" "$KMODS"'
} > "$WORK/parser.sh"
if [ ! -s "$WORK/parser.sh" ]; then
	echo "FAIL could not extract the option parser"; fails=$((fails + 1))
else
	NCPU=$(nproc 2>/dev/null || echo 4)
	expect_parse() { # expect_parse <label> <expected> <args...>
		label=$1; expected=$2; shift 2
		got=$(bash "$WORK/parser.sh" "$@" 2>/dev/null)
		if [ "$got" = "$expected" ]; then
			echo "  ok   $label"
		else
			echo "  FAIL $label: got '$got', expected '$expected'"
			fails=$((fails + 1))
		fi
	}
	expect_parse "-j4"            "4|full|1|1||image"    -j4
	expect_parse "-j 4"           "4|full|1|1||image"    -j 4
	expect_parse "--jobs 4"       "4|full|1|1||image"    --jobs 4
	expect_parse "--jobs=4"       "4|full|1|1||image"    --jobs=4
	expect_parse "--no-feeds"     "$NCPU|full|1|0||image" --no-feeds
	expect_parse "tree + -j8 + --variant m2 + --no-initramfs" \
		"8|m2|0|1|/tree|image" /tree -j8 --variant m2 --no-initramfs
	expect_parse "--kmods all" "$NCPU|full|1|1||all" --kmods all
	expect_parse "--kmods a,b" "$NCPU|full|1|1||kmod-wireguard,kmod-udptunnel4" \
		--kmods kmod-wireguard,kmod-udptunnel4
	if bash "$WORK/parser.sh" -jbogus >/dev/null 2>&1; then
		echo "  FAIL -jbogus was accepted as a job count"
		fails=$((fails + 1))
	else
		echo "  ok   -jbogus is refused"
	fi
fi

echo "== --kmods seeds the modules, and as =m rather than =y"
# =y installs the module into the image, and the persistent image has 0x3A0000 of
# mtd4 to fit in -- so a module meant for the published archive must be =m.  The
# seeding block is extracted rather than copied, so this cannot drift into testing
# a stale duplicate of it.
sed -n '/^# >>> kmods-seeding/,/^# <<< kmods-seeding$/p' scripts/build-firmware.sh > "$WORK/kmods.sh"
if [ ! -s "$WORK/kmods.sh" ]; then
	echo "  FAIL could not extract the --kmods seeding block"; fails=$((fails + 1))
else
	CFG=$(mktemp); SEEDED=$(mktemp)
	KMODS="kmod-wireguard,kmod-udptunnel4"
	# shellcheck disable=SC1090,SC1091
	. "$WORK/kmods.sh" >/dev/null
	check "the named module is seeded as =m" "CONFIG_PACKAGE_kmod-wireguard=m" "$CFG"
	check "and so is the second one" "CONFIG_PACKAGE_kmod-udptunnel4=m" "$CFG"
	check_absent "nothing is seeded =y" "CONFIG_PACKAGE_kmod-wireguard=y" "$CFG"
	check "and both reach the post-defconfig gate" "CONFIG_PACKAGE_kmod-wireguard=m" "$SEEDED"

	CFG=$(mktemp); SEEDED=$(mktemp)
	KMODS="all"
	. "$WORK/kmods.sh" >/dev/null
	check "--kmods all seeds CONFIG_ALL_KMODS" "CONFIG_ALL_KMODS=y" "$CFG"
	# Run 39219693393: CONFIG_ALL_KMODS reaches kernel modules that live inside
	# feed package directories, and one of those directories builds more than its
	# module -- package/feeds/telephony/rtpengine also builds telephony daemons this
	# board has no use for, and the build died there.  The default exclusion stays
	# out of $SEEDED on purpose: --no-feeds means the package does not exist, and
	# that is an exclusion that holds rather than a symbol that failed to survive.
	check "the module that dragged that directory in is turned off" \
		"# CONFIG_PACKAGE_kmod-ipt-rtpengine is not set" "$CFG"
	check_absent "and it is not held to the post-defconfig gate" \
		"# CONFIG_PACKAGE_kmod-ipt-rtpengine is not set" "$SEEDED"

	# The default applies only when the option was *not given*.  The first version
	# initialised KMODS_EXCLUDE="" and used ${KMODS_EXCLUDE-DEFAULT}, which cannot
	# tell "not given" from "given empty": the variable looked set, the default never
	# applied, and kmod-ipt-rtpengine was never turned off -- in the commit written to
	# turn it off (gate run 39230757790, whose log has no 'minus' line).  The three
	# states are therefore tested against the script's own initial values.
	run_seed() { # run_seed <exclude> <given> <cfg>
		KMODS="all" KMODS_EXCLUDE="$1" KMODS_EXCLUDE_GIVEN="$2" CFG="$3" SEEDED=$(mktemp)
		# Sourced in this shell, not in a subshell: the block calls set_cfg() and
		# set_cfg_off(), which come from helpers.sh above.
		# shellcheck disable=SC1090,SC1091
		. "$WORK/kmods.sh" >/dev/null
	}
	if grep -qx 'KMODS_EXCLUDE=""' scripts/build-firmware.sh \
		&& grep -qx 'KMODS_EXCLUDE_GIVEN=0' scripts/build-firmware.sh; then
		echo "  ok   the header starts at 'no exclusions given'"
	else
		echo "  FAIL the header no longer initialises the exclusion state as expected"
		fails=$((fails + 1))
	fi
	CFG=$(mktemp)
	run_seed "" 0 "$CFG"
	check "not given: the measured default is turned off" \
		"# CONFIG_PACKAGE_kmod-ipt-rtpengine is not set" "$CFG"

	CFG=$(mktemp)
	run_seed "kmod-v4l2loopback,kmod-jool" 1 "$CFG"
	check "given: the first name is used" "# CONFIG_PACKAGE_kmod-v4l2loopback is not set" "$CFG"
	check "given: and the second" "# CONFIG_PACKAGE_kmod-jool is not set" "$CFG"
	check_absent "given: it replaces the default rather than adding to it" \
		"# CONFIG_PACKAGE_kmod-ipt-rtpengine is not set" "$CFG"

	CFG=$(mktemp)
	run_seed "" 1 "$CFG"
	if grep -q 'is not set' "$CFG"; then
		echo "  FAIL 'given empty' still turned something off"
		fails=$((fails + 1))
	else
		echo "  ok   given empty: nothing is excluded, which is how the failure was measured"
	fi

	CFG=$(mktemp); SEEDED=$(mktemp)
	KMODS="image"
	. "$WORK/kmods.sh" >/dev/null
	if [ -s "$CFG" ]; then
		echo "  FAIL --kmods image seeded something"; fails=$((fails + 1))
	else
		echo "  ok   --kmods image seeds nothing extra"
	fi
fi

echo "== reporting why a build failed"
# The build's own output is useless here: with -j, OpenWrt keeps each sub-build's
# output in logs/ and the top level prints one line naming the directory that
# failed.  Two CI runs spent their whole 47 and 81 minutes to produce exactly that
# line, so this is the part that has to work.
FAKE="$WORK/owrt"
mkdir -p "$FAKE/logs/target/linux"
printf 'make[4]: Entering directory /kernel\nsome_wrong_thing.c:41:3: error: it did not compile\nmake[4]: *** [Makefile:9: all] Error 2\n' \
	> "$FAKE/logs/target/linux/compile.txt"
printf 'make[3] -C target/linux compile\n    ERROR: target/linux failed to build.\n' \
	> "$WORK/make-output.txt"
out=$(report_build_failure "$WORK/make-output.txt" "$FAKE" 2>&1)
case "$out" in
	*"directory that failed is 'target/linux'"*)
		echo "  ok   the failing directory is named" ;;
	*)	echo "  FAIL the failing directory is not named: $out"; fails=$((fails + 1)) ;;
esac
case "$out" in
	*"some_wrong_thing.c:41:3: error: it did not compile"*)
		echo "  ok   its log is printed, which is where the reason is" ;;
	*)	echo "  FAIL the log of the failing directory was not printed"; fails=$((fails + 1)) ;;
esac
case "$out" in
	*"logs/target/linux/compile.txt"*)
		echo "  ok   and it says which file that came from" ;;
	*)	echo "  FAIL the log file is not named"; fails=$((fails + 1)) ;;
esac

echo "== reporting when there is nothing to read"
out=$(report_build_failure "$WORK/make-output.txt" "$WORK/no-such-tree" 2>&1)
case "$out" in
	*"logs directory to read"*)
		echo "  ok   a tree without logs/ says so instead of printing nothing" ;;
	*)	echo "  FAIL a tree without logs/ was not reported: $out"; fails=$((fails + 1)) ;;
esac

echo "== reporting when the named directory has no log"
mkdir -p "$FAKE/other/logs"
out=$(report_build_failure "$WORK/make-output.txt" "$FAKE/other" 2>&1)
case "$out" in
	*"nothing in"*)
		echo "  ok   an unmatched logs/ directory says so" ;;
	*)	echo "  FAIL an empty logs/ directory was reported as having content: $out"; fails=$((fails + 1)) ;;
esac

echo "== the failure report re-runs the failing directory, because logs/ is not written"
# logs/ only exists when CONFIG_BUILD_LOG=y, whose prompt is `if DEVEL`, so a release
# build has none -- and then the report would end on thirty lines of
# `make[3] -C foo compile`, which is not a reason.  The re-run is what a person does
# by hand; it must be announced, must be skippable, and must not fail the report.
mkdir -p "$FAKE/target/linux"
out=$(report_build_failure "$WORK/make-output.txt" "$FAKE" 2>&1)
case "$out" in
	*"re-running 'target/linux' with V=s"*)
		echo "  ok   the failing directory is re-run with V=s" ;;
	*)	echo "  FAIL the re-run was not announced: $out"; fails=$((fails + 1)) ;;
esac
out=$(BUILD_LOG_RERUN=0 report_build_failure "$WORK/make-output.txt" "$FAKE" 2>&1)
case "$out" in
	*"re-running"*)
		echo "  FAIL BUILD_LOG_RERUN=0 still re-ran the directory"; fails=$((fails + 1)) ;;
	*)	echo "  ok   BUILD_LOG_RERUN=0 suppresses it" ;;
esac
out=$(report_build_failure "$WORK/make-output.txt" "$WORK/no-such-tree" 2>&1)
case "$out" in
	*"re-running"*)
		echo "  FAIL a tree that has no such directory still tried to re-run it"
		fails=$((fails + 1)) ;;
	*)	echo "  ok   a directory that is not there is not re-run" ;;
esac

echo "== and it re-runs through the top-level Makefile, not inside the directory"
# A feed package path is a symlink into feeds/, and a feed Makefile run on its own
# has no $(INCLUDE_DIR): run 39219693393's re-run died on a fake
# "Makefile:37: /nls.mk: No such file or directory" and printed that as the reason
# the release failed, hiding the real one.  The invocation is checked here because
# nothing else in a build can catch it -- it only happens after something failed.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$MAKE_ARGS"\nexit 1\n' > "$WORK/bin/make"
chmod +x "$WORK/bin/make"
rm -f "$WORK/make-args.txt"
out=$(PATH="$WORK/bin:$PATH" MAKE_ARGS="$WORK/make-args.txt" \
	report_build_failure "$WORK/make-output.txt" "$FAKE" 2>&1)
recorded=$(head -1 "$WORK/make-args.txt" 2>/dev/null)
case "$recorded" in
	*"target/linux/compile V=s"*)
		echo "  ok   the failing directory is compiled through the top level" ;;
	*)	echo "  FAIL the re-run did not use the top-level Makefile: '$recorded'"
		fails=$((fails + 1)) ;;
esac
case "$recorded" in
	*" -C "*)
		echo "  FAIL the re-run still uses make -C, which cannot work for a feed path"
		fails=$((fails + 1)) ;;
	*)	echo "  ok   and it does not chdir into a directory whose Makefile needs the top level" ;;
esac

echo "== the target kernel config, when it asks for modules this repo does not carry"
# Run 38635021287 died eighteen seconds into `target/linux/compile` because
# config-6.18 asked for net/xpon/ and drivers/net/optical/, which only exist in the
# community branch.  The check has to fire on exactly those symbols, pass for a
# clean config, and stay quiet under --with-pon, where the sources are expected.
KCFG="$WORK/config-6.18"
printf 'CONFIG_XPON=m\nCONFIG_KERNEL_DEVTMPFS=y\n' > "$KCFG"
out=$(check_target_kernel_config "$KCFG" 0 2>&1); rc=$?
case "$out" in
	*"modules that are not in this repository"*)
		echo "  ok   a config that asks for xPON is refused" ;;
	*)	echo "  FAIL an xPON symbol in the kernel config was accepted: $out"; fails=$((fails + 1)) ;;
esac
[ "$rc" -ne 0 ] && echo "  ok   and it reports failure" || { echo "  FAIL it did not fail"; fails=$((fails + 1)); }
case "$out" in
	*"CONFIG_XPON=m"*)
		echo "  ok   the symbol is named" ;;
	*)	echo "  FAIL the offending symbol is not named"; fails=$((fails + 1)) ;;
esac
case "$out" in
	*"buildroot-patches/0006 and 0007"*)
		echo "  ok   and it says where those symbols belong" ;;
	*)	echo "  FAIL it does not say where to get them"; fails=$((fails + 1)) ;;
esac

# The same config with --with-pon: the sources are expected to be there, so this
# must pass -- otherwise the flag that exists for that case could not be used.
out=$(check_target_kernel_config "$KCFG" 1 2>&1) \
	&& echo "  ok   --with-pon accepts the same config" \
	|| { echo "  FAIL --with-pon was rejected: $out"; fails=$((fails + 1)); }

# A clean config, and a tree with no config file yet (which is the state before
# 0003 creates it).
printf 'CONFIG_KERNEL_DEVTMPFS=y\n' > "$KCFG"
check_target_kernel_config "$KCFG" 0 \
	&& echo "  ok   a clean kernel config is accepted" \
	|| { echo "  FAIL a clean kernel config was refused"; fails=$((fails + 1)); }
check_target_kernel_config "$WORK/no-such-config" 0 \
	&& echo "  ok   a missing config file is not an error" \
	|| { echo "  FAIL a missing config file was refused"; fails=$((fails + 1)); }

echo "== --kmods all, and whether the selection actually happened"
# Running `make defconfig` over a .config that already exists keeps the values in
# it: every `# CONFIG_PACKAGE_kmod-x is not set` line an earlier run wrote stays,
# a default is applied only to symbols kconfig has not seen, and the flag the
# seeding step wrote is present the whole time.  Run 39218437654 did exactly that
# -- one job, two invocations of the script -- and produced 45 modules =y, 0 =m,
# with CONFIG_ALL_KMODS=y in .config and the post-defconfig gate green.  The
# archive from that tree would have held the image's own modules and nothing else.
run_effect() { # run_effect <kmods> <kmod-list> <cfg> <min> [excluded]
	KMODS="$1" KMOD_LIST="$2" CFG="$3" KMODS_ALL_MIN="$4" KMODS_OFF="${5-}" \
		bash -c '. "$1"' _ "$WORK/kmods-effect.sh" 2>&1
}
STALE="$WORK/stale.config"
{ i=0; while [ $i -lt 45 ]; do printf 'CONFIG_PACKAGE_kmod-fake%s=y\n' "$i"; i=$((i + 1)); done; } > "$STALE"
out=$(run_effect all "" "$STALE" 100); rc=$?
case "$out" in
	*"selected only 0 kernel module(s) as =m"*)
		echo "  ok   an all-kmods selection that selected nothing is refused" ;;
	*)	echo "  FAIL the reuse case was accepted: $out"; fails=$((fails + 1)) ;;
esac
[ "$rc" -ne 0 ] && echo "  ok   and it reports failure" || { echo "  FAIL it did not fail"; fails=$((fails + 1)); }
case "$out" in
	*"rm -f $STALE"*)
		echo "  ok   and it names the fix, with the path" ;;
	*)	echo "  FAIL it does not say what to do: $out"; fails=$((fails + 1)) ;;
esac
case "$out" in
	*"45 kernel module(s) =y"*)
		echo "  ok   the counts are printed, so the number is in the log" ;;
	*)	echo "  FAIL the counts are not printed: $out"; fails=$((fails + 1)) ;;
esac

# A real selection passes, and prints both counts.
REAL="$WORK/all.config"
printf 'CONFIG_ALL_KMODS=y\nCONFIG_PACKAGE_kmod-fake0=y\nCONFIG_PACKAGE_kmod-wireguard=m\nCONFIG_PACKAGE_kmod-udptunnel4=m\n' > "$REAL"
out=$(run_effect all "" "$REAL" 2) \
	&& echo "  ok   a selection of 2 modules passes a floor of 2" \
	|| { echo "  FAIL a real selection was refused: $out"; fails=$((fails + 1)); }
case "$out" in
	*"1 kernel module(s) =y"*"2 =m"*)
		echo "  ok   the =y and =m counts are reported separately" ;;
	*)	echo "  FAIL the split is not reported: $out"; fails=$((fails + 1)) ;;
esac

# An exclusion that did not hold puts the module back, and with it the feed
# package directory: the archive stops being what the release promised and the
# build stops being predictable.  It is refused, and the module is named.
printf 'CONFIG_ALL_KMODS=y\nCONFIG_PACKAGE_kmod-fake0=y\nCONFIG_PACKAGE_kmod-ipt-rtpengine=m\n' \
	> "$WORK/excluded-but-kept.config"
out=$(run_effect all "" "$WORK/excluded-but-kept.config" 1 kmod-ipt-rtpengine); rc=$?
case "$out" in
	*"are selected anyway"*"kmod-ipt-rtpengine"*)
		echo "  ok   an exclusion that did not hold is refused, and the module named" ;;
	*)	echo "  FAIL an exclusion that did not hold was accepted: $out"; fails=$((fails + 1)) ;;
esac
[ "$rc" -ne 0 ] && echo "  ok   and it reports failure" || { echo "  FAIL it did not fail"; fails=$((fails + 1)); }
out=$(run_effect all "" "$REAL" 2 kmod-ipt-rtpengine) \
	&& echo "  ok   the same exclusion against a config without that package passes" \
	|| { echo "  FAIL an exclusion that held was refused: $out"; fails=$((fails + 1)); }

echo "== --kmods with a list, and a package that did not get selected"
# A name the tree knows but that is not selected is the same reuse case, and the
# gate above cannot see it: the seed is in .config, kconfig simply kept the `is
# not set` line that was already there.
out=$(run_effect kmod-wireguard kmod-wireguard "$STALE" 100); rc=$?
case "$out" in
	*"not selected in .config"*"kmod-wireguard"*)
		echo "  ok   a requested module that was not selected is refused" ;;
	*)	echo "  FAIL a module that was not selected was accepted: $out"; fails=$((fails + 1)) ;;
esac
[ "$rc" -ne 0 ] && echo "  ok   and it reports failure" || { echo "  FAIL it did not fail"; fails=$((fails + 1)); }
out=$(run_effect kmod-wireguard kmod-wireguard "$REAL" 100) \
	&& echo "  ok   the same request against a config that has it passes" \
	|| { echo "  FAIL a selected module was refused: $out"; fails=$((fails + 1)); }
# =y counts too: something else in the tree may have turned the module on, and
# that is still a module this build produces and publishes.
printf 'CONFIG_PACKAGE_kmod-wireguard=y\n' > "$WORK/all-y.config"
out=$(run_effect kmod-wireguard kmod-wireguard "$WORK/all-y.config" 100) \
	&& echo "  ok   a module the image itself selects as =y is accepted" \
	|| { echo "  FAIL =y was treated as absent: $out"; fails=$((fails + 1)); }

echo "== and --kmods image checks nothing, because it promises nothing"
# The default must stay quiet: an image-only build is not making a promise about
# the archive, and a floor on it would fail every ordinary build.
out=$(run_effect image "" "$STALE" 100) \
	&& echo "  ok   --kmods image passes over a stale config" \
	|| { echo "  FAIL the default was refused: $out"; fails=$((fails + 1)); }

echo
if [ "$fails" -ne 0 ]; then
	echo "$fails check(s) FAILED"
	exit 1
fi
echo "ok: set_cfg / set_cfg_off, the option parser and the failure report behave as the gate expects"
