#!/usr/bin/env bash
# Exercise tools/check_kernel_sources.py against fake kernel trees.
#
# Why this is worth a test: the tool exists because two patch series sources reached a
# release build --
#
#     net/Kconfig:90:             source "net/xpon/Kconfig"
#     drivers/net/Kconfig:29:     source "drivers/net/optical/Kconfig"
#
# -- where the sourced file only exists in the community airoha_en7523_all branch.
# kconfig stops on the first one about twenty seconds into the kernel's configure
# step, which is far too short to compile anything and is the only clue the workflow
# log holds.  A checker that misses a dangling path is worse than none, and one that
# reports the kernel's own `$(SRCARCH)` lines is noise that hides the real hit, so
# both halves are checked here.
#
# Usage: tools/test_check_kernel_sources.sh      (needs python3)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "!! no $PY (set PYTHON=...)"; exit 1; }
TOOL=tools/check_kernel_sources.py

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fails=0

# run <tree> [extra args...] -> sets out and rc
run() {
	local tree="$1"; shift
	out=$("$PY" "$TOOL" "$tree" "$@" 2>&1); rc=$?
}

echo "== a clean tree"
K="$WORK/clean"; mkdir -p "$K/net/9p" "$K/drivers/net/optical"
printf 'source "net/9p/Kconfig"\nsource "Kconfig.debug"\n' > "$K/net/Kconfig"
printf 'config NINE_P\n\tbool "x"\n' > "$K/net/9p/Kconfig"
printf 'config DBG\n\tbool "x"\n' > "$K/net/Kconfig.debug"
printf 'obj-y += optical/\n' > "$K/drivers/net/Makefile"
printf 'config OPT\n\tbool "x"\n' > "$K/drivers/net/optical/Kconfig"
run "$K"
if [ "$rc" -eq 0 ]; then
	echo "  ok   a tree whose sources all resolve passes"
else
	echo "  FAIL a clean tree was rejected:"; sed 's/^/       /' <<<"$out"; fails=$((fails + 1))
fi

echo "== the tree that broke the build: net/xpon and drivers/net/optical are absent"
K="$WORK/dangling"; mkdir -p "$K/net" "$K/drivers/net" "$K/arch/arm"
printf 'source "arch/$(SRCARCH)/Kconfig"\nsource "net/xpon/Kconfig"\n' > "$K/net/Kconfig"
printf 'source "drivers/net/optical/Kconfig"\n' > "$K/drivers/net/Kconfig"
printf 'obj-y += optical/\n' > "$K/drivers/net/Makefile"
printf 'config X\n\tbool "x"\n' > "$K/arch/arm/Kconfig"
run "$K"
if [ "$rc" -ne 0 ]; then
	echo "  ok   a dangling source fails the check"
else
	echo "  FAIL a dangling source was accepted"; fails=$((fails + 1))
fi
case "$out" in
	*'net/Kconfig:2: source "net/xpon/Kconfig" does not exist'*)
		echo "  ok   the file, the line and the path are named" ;;
	*)	echo "  FAIL the dangling net/xpon source was not named:"; sed 's/^/       /' <<<"$out"; fails=$((fails + 1)) ;;
esac
case "$out" in
	*'drivers/net/optical/Kconfig'*)
		echo "  ok   so is the optical one" ;;
	*)	echo "  FAIL the dangling optical source was not named"; fails=$((fails + 1)) ;;
esac
case "$out" in
	*'$(SRCARCH)'*)
		echo "  FAIL the kernel's own \$(SRCARCH) line was reported as dangling"; fails=$((fails + 1)) ;;
	*)	echo "  ok   the kernel's \$(SRCARCH) line is left alone" ;;
esac
case "$out" in
	*'buildroot-patches/0006'*|*'--with-pon'*)
		echo "  ok   and it says which flag the patch needs" ;;
	*)	echo "  FAIL it does not say where such a patch belongs"; fails=$((fails + 1)) ;;
esac

echo "== an obj- directory that is not there (reported, but not fatal on its own)"
K="$WORK/objdir"; mkdir -p "$K/net"
printf 'config X\n\tbool "x"\n' > "$K/net/Kconfig"
printf 'obj-y += gone/\n' > "$K/net/Makefile"
run "$K"
if [ "$rc" -eq 0 ]; then
	echo "  ok   a missing obj- directory alone does not fail the check"
else
	echo "  FAIL a missing obj- directory alone failed the check"; fails=$((fails + 1))
fi
case "$out" in
	*'gone/ is not a directory'*)
		echo "  ok   but it is reported" ;;
	*)	echo "  FAIL the missing obj- directory was not reported"; fails=$((fails + 1)) ;;
esac
out=$("$PY" "$TOOL" "$K" --quiet-obj 2>&1) \
	&& echo "  ok   --quiet-obj keeps it out of the report" \
	|| { echo "  FAIL --quiet-obj failed the run"; fails=$((fails + 1)); }

echo "== an OpenWrt tree with --owrt finds build_dir itself"
K="$WORK/owrt"; mkdir -p "$K/build_dir/target-arm_cortex-a7_musl_eabi/linux-airoha_en7523/linux-6.18.54/net"
printf 'source "net/missing/Kconfig"\n' > "$K/build_dir/target-arm_cortex-a7_musl_eabi/linux-airoha_en7523/linux-6.18.54/net/Kconfig"
run "$K" --owrt
if [ "$rc" -ne 0 ]; then
	echo "  ok   the kernel tree under build_dir is found and checked"
else
	echo "  FAIL --owrt did not find the kernel tree"; fails=$((fails + 1))
fi

echo "== an OpenWrt tree with no prepared kernel"
K="$WORK/empty"; mkdir -p "$K"
run "$K" --owrt
if [ "$rc" -eq 2 ]; then
	echo "  ok   a tree without build_dir/.../linux-* is a usage error, not a pass"
else
	echo "  FAIL a tree with no kernel tree returned $rc"; fails=$((fails + 1))
fi

echo
if [ "$fails" -ne 0 ]; then
	echo "$fails check(s) FAILED"
	exit 1
fi
echo "ok: check_kernel_sources names dangling Kconfig sources and ignores the rest"
