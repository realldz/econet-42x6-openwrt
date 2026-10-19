#!/usr/bin/env bash
# Exercise tools/check_kmods.py against fake OpenWrt trees.
#
# Why this is worth a test: the tool is what tells a release build, in about a
# minute, whether the module archive it is about to publish will hold the modules
# users ask for.  MEASURED: v0.1.0-m2 published 46 kernel modules and no
# kmod-wireguard, because only the image's own dependencies were selected -- a
# failure that looks like a working repository until `apk add` 404s.
#
# Two things this pins down, both of which were wrong in the first draft of the
# tool: a package written into .config as `# CONFIG_PACKAGE_kmod-wireguard is not
# set` must not count as selected, and the kernel symbol must be looked for in
# build_dir/.../linux-*/.config.override -- NOT in
# target/linux/airoha/en7523/config-6.18, which does not list it and must not,
# since scripts/package-metadata.pl writes it into the override at compile time.
# A checker that demanded it in the target config would fail a tree that is
# correct.
#
# Usage: tools/test_check_kmods.sh      (needs python3, or set PYTHON=python)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "!! no $PY (set PYTHON=...)"; exit 1; }
TOOL=tools/check_kmods.py

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fails=0

# run <tree> [extra args...] -> sets out and rc
run() {
	local tree="$1"; shift
	out=$("$PY" "$TOOL" "$tree" "$@" 2>&1); rc=$?
}

KERNEL_REL=build_dir/target-arm_cortex-a7_musl_eabi/linux-airoha_en7523/linux-6.18.54

# mktree <name> -> a tree with a .config, and a target kernel config that says the
# opposite of what a selected module needs, exactly as the real tree does.
mktree() {
	local t="$WORK/$1"
	mkdir -p "$t/target/linux/airoha/en7523"
	printf 'CONFIG_TARGET_airoha=y\n' > "$t/.config"
	printf '# CONFIG_WIREGUARD is not set\n' > "$t/target/linux/airoha/en7523/config-6.18"
	echo "$t"
}

echo "== a kmod selected as =m, with its kernel symbol in the override"
K=$(mktree ok)
cat >> "$K/.config" <<'EOF'
CONFIG_ALL_KMODS=y
CONFIG_PACKAGE_kmod-wireguard=m
CONFIG_PACKAGE_kmod-lib-crc32c=m
CONFIG_PACKAGE_kmod-mt7915e=y
CONFIG_PACKAGE_luci=y
EOF
mkdir -p "$K/$KERNEL_REL"
printf 'CONFIG_WIREGUARD=m\n' > "$K/$KERNEL_REL/.config.override"
run "$K" --require-package kmod-wireguard --require-built kmod-wireguard \
	--require-override CONFIG_WIREGUARD --require-all-kmods
if [ "$rc" -eq 0 ]; then
	echo "  ok   a selected module with its kernel symbol passes"
else
	echo "  FAIL a satisfied tree was rejected:"; sed 's/^/       /' <<<"$out"; fails=$((fails + 1))
fi
case "$out" in
	*'kmod-wireguard: selected (=m, built and published, not in the image)'*)
		echo "  ok   =m is reported as published-but-not-installed" ;;
	*)	echo "  FAIL the =m wording is missing:"; sed 's/^/       /' <<<"$out"; fails=$((fails + 1)) ;;
esac
case "$out" in
	*'1 kmod package(s) =y (these are in the image), 2 =m'*)
		echo "  ok   the =y/=m counts separate the image from the archive" ;;
	*)	echo "  FAIL the counts line is wrong:"; sed 's/^/       /' <<<"$out"; fails=$((fails + 1)) ;;
esac
case "$out" in
	*'ok   CONFIG_WIREGUARD=m in '"$KERNEL_REL"'/.config.override'*)
		echo "  ok   the kernel symbol names the file it was found in" ;;
	*)	echo "  FAIL the override hit was not named:"; sed 's/^/       /' <<<"$out"; fails=$((fails + 1)) ;;
esac
case "$out" in
	*'config-6.18'*)
		echo "  FAIL the target config was read as if it carried the symbol"
		fails=$((fails + 1)) ;;
	*)	echo "  ok   the target config is not where the symbol is looked for" ;;
esac
case "$out" in
	*'CONFIG_PACKAGE_luci'*)
		echo "  FAIL a non-kmod package was counted as a kernel module"; fails=$((fails + 1)) ;;
	*)	echo "  ok   userspace packages are not counted as modules" ;;
esac

echo "== the case that happened: the module was never selected"
K=$(mktree notselected)
printf '# CONFIG_PACKAGE_kmod-wireguard is not set\n' >> "$K/.config"
run "$K" --require-package kmod-wireguard
if [ "$rc" -ne 0 ]; then
	echo "  ok   an unselected module fails the check"
else
	echo "  FAIL an unselected module was accepted"; fails=$((fails + 1))
fi
case "$out" in
	*'FAIL kmod-wireguard: not selected in .config'*)
		echo "  ok   and it says so plainly" ;;
	*)	echo "  FAIL the failure line is missing:"; sed 's/^/       /' <<<"$out"; fails=$((fails + 1)) ;;
esac
case "$out" in
	*'--kmods'*)
		echo "  ok   and it names the flag that selects it" ;;
	*)	echo "  FAIL it does not say how to select the module"; fails=$((fails + 1)) ;;
esac

echo "== a module selected =y would be installed into the image"
K=$(mktree installed)
printf 'CONFIG_PACKAGE_kmod-wireguard=y\n' >> "$K/.config"
run "$K" --require-built kmod-wireguard
if [ "$rc" -ne 0 ]; then
	echo "  ok   =y fails a --require-built check"
else
	echo "  FAIL =y passed a --require-built check"; fails=$((fails + 1))
fi
case "$out" in
	*'0x3A0000'*)
		echo "  ok   and it says why that matters for a release image" ;;
	*)	echo "  FAIL the mtd4 reason is missing:"; sed 's/^/       /' <<<"$out"; fails=$((fails + 1)) ;;
esac

echo "== CONFIG_ALL_KMODS is what a full archive rests on"
K=$(mktree allkmods)
printf 'CONFIG_PACKAGE_kmod-a=m\n' >> "$K/.config"
run "$K" --require-all-kmods
if [ "$rc" -ne 0 ]; then
	echo "  ok   a tree without CONFIG_ALL_KMODS fails that check"
else
	echo "  FAIL a tree without CONFIG_ALL_KMODS was accepted"; fails=$((fails + 1))
fi
case "$out" in
	*'FAIL CONFIG_ALL_KMODS is not =y'*'--kmods all'*|*'--kmods all'*'=m by default'*)
		echo "  ok   and it explains that kmods select as =m, not =y" ;;
	*)	echo "  FAIL the ALL_KMODS failure does not explain itself:"; sed 's/^/       /' <<<"$out"; fails=$((fails + 1)) ;;
esac

echo "== the kernel symbol only in the kernel's own .config"
K=$(mktree prepared)
printf 'CONFIG_PACKAGE_kmod-wireguard=m\n' >> "$K/.config"
mkdir -p "$K/$KERNEL_REL"
printf 'CONFIG_WIREGUARD=m\n' > "$K/$KERNEL_REL/.config"
run "$K" --require-package kmod-wireguard --require-override CONFIG_WIREGUARD
if [ "$rc" -eq 0 ]; then
	echo "  ok   the kernel's .config is read as well as the override"
else
	echo "  FAIL a symbol in build_dir was not found:"; sed 's/^/       /' <<<"$out"; fails=$((fails + 1))
fi
case "$out" in
	*'linux-6.18.54/.config'*)
		echo "  ok   and the path is reported" ;;
	*)	echo "  FAIL the kernel config path was not named"; fails=$((fails + 1)) ;;
esac

echo "== a module whose kernel symbol never reached the kernel"
K=$(mktree nosym)
printf 'CONFIG_PACKAGE_kmod-wireguard=m\n' >> "$K/.config"
mkdir -p "$K/$KERNEL_REL"
printf '# CONFIG_WIREGUARD is not set\n' > "$K/$KERNEL_REL/.config.override"
run "$K" --require-override CONFIG_WIREGUARD
if [ "$rc" -ne 0 ]; then
	echo "  ok   a missing kernel symbol fails, even with the package selected"
else
	echo "  FAIL a missing kernel symbol was accepted"; fails=$((fails + 1))
fi
case "$out" in
	*'target/linux/airoha/en7523/config-6.18'*)
		echo "  ok   and it says the target config is not the place for it" ;;
	*)	echo "  FAIL it does not say where the symbol does not belong:"; sed 's/^/       /' <<<"$out"; fails=$((fails + 1)) ;;
esac
case "$out" in
	*'ok   CONFIG_WIREGUARD='*)
		echo "  FAIL a comment line was read as a set symbol"; fails=$((fails + 1)) ;;
	*)	echo "  ok   '# CONFIG_WIREGUARD is not set' is not a set symbol" ;;
esac

echo "== no kernel config yet, because only prepare has run"
K="$WORK/nocfg"; mkdir -p "$K"
printf 'CONFIG_PACKAGE_kmod-wireguard=m\n' > "$K/.config"
run "$K" --require-override CONFIG_WIREGUARD
if [ "$rc" -eq 2 ]; then
	echo "  ok   it is a usage error, not a pass for lack of evidence"
else
	echo "  FAIL it returned $rc with nothing to check"; fails=$((fails + 1))
fi
case "$out" in
	*'make target/linux/compile'*)
		echo "  ok   and it says which stage writes that file" ;;
	*)	echo "  FAIL it does not name the stage that produces the config:"; sed 's/^/       /' <<<"$out"; fails=$((fails + 1)) ;;
esac

echo "== --min-kmods: how the all-kmods flag is held to a number"
K=$(mktree few)
printf 'CONFIG_PACKAGE_kmod-a=m\nCONFIG_PACKAGE_kmod-b=m\n' >> "$K/.config"
run "$K" --min-kmods 100
if [ "$rc" -ne 0 ]; then
	echo "  ok   2 modules do not satisfy --min-kmods 100"
else
	echo "  FAIL --min-kmods 100 passed with 2 modules"; fails=$((fails + 1))
fi
case "$out" in
	*'--kmods all'*)
		echo "  ok   and the hint names the flag it suspects" ;;
	*)	echo "  FAIL the --kmods all hint is missing:"; sed 's/^/       /' <<<"$out"; fails=$((fails + 1)) ;;
esac
run "$K" --min-kmods 2
if [ "$rc" -eq 0 ]; then
	echo "  ok   --min-kmods 2 passes with 2 modules"
else
	echo "  FAIL --min-kmods 2 rejected 2 modules"; fails=$((fails + 1))
fi

echo "== usage errors are not passes"
K="$WORK/noconfig"; mkdir -p "$K"
run "$K" --require-package kmod-wireguard
if [ "$rc" -eq 2 ]; then
	echo "  ok   a tree with no .config is a usage error"
else
	echo "  FAIL a tree with no .config returned $rc"; fails=$((fails + 1))
fi
run "$WORK/does-not-exist" --require-package kmod-wireguard
if [ "$rc" -eq 2 ]; then
	echo "  ok   a tree that does not exist is a usage error"
else
	echo "  FAIL a missing tree returned $rc"; fails=$((fails + 1))
fi

echo
if [ "$fails" -ne 0 ]; then
	echo "$fails check(s) FAILED"
	exit 1
fi
echo "ok: check_kmods reads .config and the kernel configs, and fails on what is absent"
