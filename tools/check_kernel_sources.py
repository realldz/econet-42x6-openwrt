#!/usr/bin/env python3
"""Check that every Kconfig source path in a prepared kernel tree resolves.

Why this exists: `make target/linux/compile` dies about twenty seconds into the
kernel's configure step when a Kconfig file sources a path that is not there, and
the failure is invisible from the workflow log unless CONFIG_BUILD_LOG is set --
twenty seconds is far too short to compile anything, which is the only clue.

Two patches reached a release build that did exactly this:

    openwrt/.../930-55-net-Kconfig-xpon.patch    -> source "net/xpon/Kconfig"
    openwrt/.../930-53-...-Kconfig-optical.patch -> source "drivers/net/optical/Kconfig"

Both pointed at sources that only exist in the community airoha_en7523_all branch.
The config-symbol check in build-firmware.sh cannot see this class: it inspects the
*contents* of config-6.18, and a dangling `source` line is not a config symbol.  This
tool looks at what kconfig itself resolves, so it fails on the same input kconfig
fails on, in about a second, with the file and the line.

Usage:
    tools/check_kernel_sources.py <prepared kernel tree>
    tools/check_kernel_sources.py --owrt <OpenWrt tree>     # finds build_dir itself
    tools/check_kernel_sources.py <OpenWrt tree> --owrt
Exit status: 0 clean, 1 dangling path found, 2 usage error.
"""

import argparse
import pathlib
import re
import sys

SOURCE_RE = re.compile(r'^\s*source\s+"?([^"\s]+)"?\s*$')
OBJ_DIR_RE = re.compile(r'^\s*obj-\S+\s*\+=\s*([A-Za-z0-9_./-]+/)\s*$')


def find_kernel_tree(owrt: pathlib.Path) -> pathlib.Path | None:
    """The extracted kernel under build_dir, which exists after target/linux/prepare."""
    cands = sorted(owrt.glob("build_dir/target-*/linux-*/linux-*"))
    cands = [c for c in cands if (c / "Kconfig").is_file()]
    return cands[0] if cands else None


def resolve(path: str, kconfig_dir: pathlib.Path, root: pathlib.Path) -> pathlib.Path | None:
    """Kconfig resolves a path with a slash against the tree root, and a bare name
    against the directory of the file that sourced it.  Accept either.

    A path holding a make or kconfig variable is not checked: the kernel writes
    `source "arch/$(SRCARCH)/Kconfig"` and `source "$(srctree)/..."` on purpose, and
    expanding them here would mean reimplementing kconfig.  Those lines are correct
    in every tree, including the ones that fail this check for a real reason."""
    if "$" in path:
        return kconfig_dir  # untestable by design; treated as present
    if path.startswith("/"):
        p = pathlib.Path(path)
        return p if p.exists() else None
    for cand in (root / path, kconfig_dir / path):
        if cand.exists():
            return cand
    return None


def check(tree: pathlib.Path) -> tuple[int, int]:
    """Returns (number of dangling source paths, number of dangling obj dirs)."""
    root = tree
    bad_source = 0
    bad_obj = 0

    kconfigs = sorted(
        p for p in root.rglob("*")
        if p.is_file() and (p.name == "Kconfig" or p.name.startswith("Kconfig."))
    )
    for kc in kconfigs:
        try:
            text = kc.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for n, line in enumerate(text.splitlines(), 1):
            m = SOURCE_RE.match(line)
            if m and resolve(m.group(1), kc.parent, root) is None:
                print(f"!! {kc.relative_to(root).as_posix()}:{n}: source \"{m.group(1)}\" does not exist")
                bad_source += 1
                if bad_source >= 25:
                    print("!! (stopping after 25 -- fix these first)")
                    return bad_source, bad_obj

    # obj-$(...) += dir/ over a directory that is not there is a make error, but
    # kbuild only trips over it when the symbol is set, so report it separately.
    for mk in sorted(root.rglob("Makefile")):
        try:
            text = mk.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for n, line in enumerate(text.splitlines(), 1):
            m = OBJ_DIR_RE.match(line)
            if m and not (mk.parent / m.group(1)).is_dir():
                print(f"   {mk.relative_to(root).as_posix()}:{n}: {line.strip()}"
                      f"  -> {m.group(1)} is not a directory")
                bad_obj += 1
                if bad_obj >= 25:
                    return bad_source, bad_obj

    return bad_source, bad_obj


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("tree", nargs="?", help="prepared kernel tree, or an OpenWrt tree with --owrt")
    ap.add_argument("--owrt", action="store_true",
                    help="treat the argument as an OpenWrt tree and find build_dir/target-*/linux-* yourself")
    ap.add_argument("--quiet-obj", action="store_true",
                    help="do not report obj- directories (only Kconfig sources decide the exit status)")
    args = ap.parse_args()

    if not args.tree:
        ap.print_usage(sys.stderr)
        print("!! give a kernel tree, or an OpenWrt tree with --owrt", file=sys.stderr)
        return 2

    p = pathlib.Path(args.tree).resolve()
    if not p.is_dir():
        print(f"!! {p} is not a directory", file=sys.stderr)
        return 2
    if args.owrt:
        found = find_kernel_tree(p)
        if found is None:
            print(f"!! no build_dir/target-*/linux-*/* under {p} -- run "
                  f"BUILD_TARGET=target/linux/prepare first", file=sys.stderr)
            return 2
        p = found

    print(f"== Kconfig sources under {p}")
    bad_source, bad_obj = check(p)
    kc = sum(1 for q in p.rglob("Kconfig*") if q.is_file())
    if bad_source:
        print()
        print(f"!! {bad_source} Kconfig path(s) do not exist.  kconfig stops at the first")
        print("   one, about twenty seconds into the kernel's configure step.  A path")
        print("   under net/xpon/ or drivers/net/optical/ belongs to the community")
        print("   airoha_en7523_all branch, which this repository does not carry: the")
        print("   patch that adds it belongs in openwrt/pon/patches-6.18/ and needs")
        print("   --with-pon.  See docs/ci.md, trap 11.")
        return 1
    if args.quiet_obj:
        print(f"ok: {kc} Kconfig file(s), every source path resolves")
        return 0
    if bad_obj:
        print(f"ok: {kc} Kconfig file(s), every source path resolves -- but "
              f"{bad_obj} obj- directory/directories above do not exist")
        return 0
    print(f"ok: {kc} Kconfig file(s), every source path resolves, every obj- directory exists")
    return 0


if __name__ == "__main__":
    sys.exit(main())
