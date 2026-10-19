#!/usr/bin/env python3
"""Check that the kernel modules a package archive promises are really selected.

Why this exists: target airoha/en7523 is FEATURES:=source-only, so OpenWrt
publishes no kmods/ directory of its own for it, and the archive on gh-pages can
only hold what this build produced.  A build produces the modules the *image*
asked for -- MEASURED, 46 of them in v0.1.0-m2, and kmod-wireguard is not among
them, because nothing in the M2 package list needs it.  A user then runs

    apk add --allow-untrusted kmod-wireguard

and gets a 404 from a repository that is working exactly as built, which reads
like a broken mirror rather than a module nobody selected.

--kmods in scripts/build-firmware.sh is what selects more of them.  This tool
reads the result out of .config, which costs a second, so a mistake here fails in
CI in about a minute instead of in a release build over an hour in.

How a selected kmod reaches the kernel (verified against OpenWrt
9b95be917b2804cf877ca05c078175b37a3a95bf, the revision this repository pins):

  * `config/Config-build.in:42` declares CONFIG_ALL_KMODS, and the generated
    package Kconfig gives every non-hidden kmod
    `default m if ALL||ALL_NONSHARED||ALL_KMODS`
    (scripts/package-metadata.pl:371-383).  So ALL_KMODS selects modules as `=m`:
    built and packaged, NOT installed into the image.  `=y` would install them,
    and the persistent image has 0x3A0000 of mtd4 to fit in.
  * The module's kernel symbol does NOT have to be listed in
    target/linux/airoha/en7523/config-6.18.  scripts/package-metadata.pl:83-85
    writes the selected packages' Kernel-Config symbols into
    <build_dir>/target-*/linux-*/linux-*/.config.override, and
    include/kernel-defaults.mk:123-124 merges that over the target config --
    including over an explicit `# CONFIG_WIREGUARD is not set` in the generic
    config, which scripts/kconfig.pl:76-78 lets the override replace.
  * That merge happens in `make target/linux/compile`, NOT in
    target/linux/prepare: prepare only untars and patches the kernel.  So
    --require-override can only be checked once the kernel stage has run, and a
    tree that has only been through prepare has no kernel .config at all.
  * There is no `make allmodconfig` at this revision.  `--kmods all` seeds
    CONFIG_ALL_KMODS=y and runs the same `make defconfig` as everything else.

What this tool cannot see: whether the module *compiles*.  Selection is what
decides whether the kernel build produces the .ko package at all; the compile
itself needs a real build.

Usage:
    tools/check_kmods.py <OpenWrt tree> --require-package kmod-wireguard
    tools/check_kmods.py <OpenWrt tree> --require-package kmod-wireguard \\
        --require-all-kmods --min-kmods 100
    tools/check_kmods.py <OpenWrt tree> --require-override CONFIG_WIREGUARD
Exit status: 0 every requirement held, 1 one did not, 2 usage error.
"""

import argparse
import pathlib
import re
import sys

PKG_RE = re.compile(r'^(CONFIG_PACKAGE_(?P<pkg>[A-Za-z0-9_+.-]+))=(?P<val>[ym])$')
NOTSET_RE = re.compile(r'^# (CONFIG_PACKAGE_[A-Za-z0-9_+.-]+) is not set$')
SYM_RE = re.compile(r'^(?P<sym>CONFIG_[A-Za-z0-9_]+)=(?P<val>[ym])$')


def read_config(path: pathlib.Path) -> dict[str, str]:
    """`CONFIG_X=y`, `CONFIG_X=m` and `# CONFIG_X is not set` (as 'n')."""
    out: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return out
    for line in text.splitlines():
        m = PKG_RE.match(line) or SYM_RE.match(line)
        if m:
            out[m.group(1)] = m.group("val")
            continue
        m = NOTSET_RE.match(line)
        if m:
            out[m.group(1)] = "n"
    return out


def find_kernel_configs(owrt: pathlib.Path) -> list[tuple[str, pathlib.Path, dict[str, str]]]:
    """The kernel's own config files, which `make target/linux/compile` writes.

    .config.override is the one that matters: it is where package-metadata.pl puts
    the kernel symbols of the selected kmod packages.  .config is what the kernel
    was finally configured with, after the override was merged over the target
    config.  Neither exists until the kernel stage has configured itself, so an
    empty list here means "nothing to check yet", not "the symbol is missing"."""
    found: list[tuple[str, pathlib.Path, dict[str, str]]] = []
    for pat in ("build_dir/target-*/linux-*/linux-*/.config.override",
                "build_dir/target-*/linux-*/linux-*/.config"):
        for p in sorted(owrt.glob(pat)):
            if p.is_file():
                found.append((p.relative_to(owrt).as_posix(), p, read_config(p)))
    return found


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("owrt", help="OpenWrt tree that has been through make defconfig")
    ap.add_argument("--require-package", action="append", default=[], metavar="NAME",
                    help="package that must be selected (=y or =m), repeatable")
    ap.add_argument("--require-built", action="append", default=[], metavar="NAME",
                    help="package that must be selected as =m (built, not installed "
                         "into the image), repeatable")
    ap.add_argument("--require-override", action="append", default=[], metavar="SYM",
                    help="kernel symbol that must be =m or =y in the kernel's "
                         ".config.override or .config under build_dir, which needs "
                         "`make target/linux/compile` to have run, repeatable")
    ap.add_argument("--require-all-kmods", action="store_true",
                    help="CONFIG_ALL_KMODS must be =y, which is what --kmods all seeds")
    ap.add_argument("--min-kmods", type=int, default=0, metavar="N",
                    help="fail unless at least N kmod-* packages are selected")
    args = ap.parse_args()

    owrt = pathlib.Path(args.owrt).resolve()
    if not owrt.is_dir():
        print(f"!! {owrt} is not a directory", file=sys.stderr)
        return 2
    cfg_path = owrt / ".config"
    if not cfg_path.is_file():
        print(f"!! {cfg_path} does not exist -- run scripts/build-firmware.sh, or at "
              f"least `make defconfig`, first", file=sys.stderr)
        return 2
    cfg = read_config(cfg_path)

    installed = sorted(p for p, v in cfg.items() if p.startswith("CONFIG_PACKAGE_kmod-") and v == "y")
    built = sorted(p for p, v in cfg.items() if p.startswith("CONFIG_PACKAGE_kmod-") and v == "m")
    all_kmods = cfg.get("CONFIG_ALL_KMODS", "n")

    print(f"== {cfg_path.relative_to(owrt).as_posix()}")
    print(f"   CONFIG_ALL_KMODS={all_kmods}")
    print(f"   {len(installed)} kmod package(s) =y (these are in the image), "
          f"{len(built)} =m (built and published, not in the image)")

    kcfgs = find_kernel_configs(owrt)
    if kcfgs:
        print(f"   kernel config(s) found: {', '.join(n for n, _, _ in kcfgs)}")
    elif args.require_override:
        print("   no kernel .config.override or .config under build_dir yet")

    failures = 0

    if args.require_all_kmods:
        if all_kmods == "y":
            print("ok   CONFIG_ALL_KMODS=y survived defconfig")
        else:
            failures += 1
            print("FAIL CONFIG_ALL_KMODS is not =y, so only the image's own modules"
                  " were selected")
            print("     That is what --kmods all seeds.  A kmod package selects as"
                  " =m by default (see the docstring), so the archive would hold")
            print("     the 46-odd modules the image needs and nothing else.")

    for name in args.require_package:
        val = cfg.get(f"CONFIG_PACKAGE_{name}")
        if val in ("y", "m"):
            where = "in the image" if val == "y" else "built and published, not in the image"
            print(f"ok   {name}: selected (={val}, {where})")
        else:
            failures += 1
            print(f"FAIL {name}: not selected in .config"
                  + ("" if val != "n"
                     else f" (written there as '# CONFIG_PACKAGE_{name} is not set')"))
            print("     Select it with --kmods in scripts/build-firmware.sh, or add the")
            print("     line to the package list the build seeds.  A package that is not")
            print("     selected is not built, so its .apk cannot be in the archive.")

    for name in args.require_built:
        val = cfg.get(f"CONFIG_PACKAGE_{name}")
        if val == "m":
            print(f"ok   {name}: selected (=m, built and published, not in the image)")
        elif val == "y":
            failures += 1
            print(f"FAIL {name}: selected =y, which installs it into the image as well.")
            print("     The persistent image has 0x3A0000 of mtd4 to fit in; modules")
            print("     the user installs later belong in the archive only, as =m.")
        else:
            failures += 1
            print(f"FAIL {name}: not selected in .config")

    for sym in args.require_override:
        hit = next(((n, c[sym]) for n, _, c in kcfgs if c.get(sym) in ("m", "y")), None)
        if hit:
            where, val = hit
            print(f"ok   {sym}={val} in {where}")
        elif not kcfgs:
            print(f"!! {sym}: no kernel config to look in yet", file=sys.stderr)
            print("   This reads build_dir/.../linux-*/.config.override, which "
                  "Kernel/Configure writes", file=sys.stderr)
            print("   during `make target/linux/compile` -- not during prepare.  Run "
                  "the kernel stage first.", file=sys.stderr)
            return 2
        else:
            failures += 1
            print(f"FAIL {sym}: absent from every kernel config above.  A selected kmod")
            print("     package should have put it in .config.override; if the package")
            print("     is selected and the symbol is still missing, its KCONFIG line")
            print("     and the kernel version disagree.  It is deliberately NOT")
            print("     required in target/linux/airoha/en7523/config-6.18.")

    if args.min_kmods:
        got = len(installed) + len(built)
        if got >= args.min_kmods:
            print(f"ok   {got} kmod package(s) selected, at least {args.min_kmods} expected")
        else:
            failures += 1
            print(f"FAIL only {got} kmod package(s) selected, at least "
                  f"{args.min_kmods} expected.  --kmods all selects every module this")
            print("     target's kernel config can build; if that number collapsed, the")
            print("     flag did not reach make defconfig.")

    print()
    if failures:
        print(f"!! {failures} requirement(s) not met.  See docs/packages.md.")
        return 1
    print(f"ok: every requirement met ({len(installed) + len(built)} kmod packages selected)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
