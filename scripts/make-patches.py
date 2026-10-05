#!/usr/bin/env python3
"""Export pristine upstream files and (re)generate this repo's OpenWrt patches.

The patch series in openwrt/patches/ has exact context lines, so it is only
guaranteed to apply to the pinned revision in scripts/pin.env.  This script is
how the series is produced and how it is refreshed when the pin is bumped.

Usage
-----
    # 1. export the pristine originals from a checkout at the pinned revision
    ./scripts/make-patches.py export /path/to/openwrt /tmp/pristine

    # 2. regenerate openwrt/patches/*.patch from those originals
    ./scripts/make-patches.py generate /tmp/pristine

Both steps are idempotent.  After step 2, verify the result by applying the
series to a pristine tree:

    ./scripts/apply-overlay.sh /path/to/openwrt

Python 3 standard library only.
"""

from __future__ import annotations

import argparse
import difflib
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
PATCH_OUT = REPO / "openwrt" / "patches"

# ---------------------------------------------------------------------------
# The files the series touches.  These are the very files the original board
# bring-up modified; anything not listed here belongs in openwrt/overlay/.
# ---------------------------------------------------------------------------
SOURCES = {
    "image-makefile": "target/linux/airoha/image/Makefile",
    "en7523-mk": "target/linux/airoha/image/en7523.mk",
    "en7523-config": "target/linux/airoha/en7523/config-6.18",
    "mt76-makefile": "package/kernel/mt76/Makefile",
}

# ---------------------------------------------------------------------------
# The transformations.  Keep these in sync with docs/building.md.
# ---------------------------------------------------------------------------
LOADADDR_OLD = "loadaddr-$(CONFIG_TARGET_airoha_en7523) := 0x80200000"
LOADADDR_NEW = "loadaddr-$(CONFIG_TARGET_airoha_en7523) := 0x80208000"

EN7523_MK_APPEND = """
# ---------------------------------------------------------------------------
# Econet / vG vGP-42X6V1 -- GPON ONU on Airoha EN7523 (EN7529CT)
#
# Stage 1 board support: UART console, SPI-NAND partition map, PCIe Wi-Fi.
# xPON / optical nodes are intentionally absent -- see openwrt/pon/.
#
# Device/Default already builds a FIT kernel suitable for UART/YMODEM RAM-boot,
# but its load address must match the kernel's physical _text (0x80208000).
# That needs BOTH of:
#   * patches-6.18/100-ARM-airoha-set-TEXT_OFFSET-2MiB.patch   (textofs)
#   * openwrt/patches/0001-...                                 (loadaddr)
#
# Enable CONFIG_TARGET_ROOTFS_INITRAMFS=y to also get *-initramfs-kernel.bin.
# ---------------------------------------------------------------------------
define Device/econet_vgp-42x6v1
  DEVICE_VENDOR := Econet
  DEVICE_MODEL := vGP-42X6V1
  DEVICE_DTS := en7523-vgp42x6v1
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7915-firmware kmod-mt7916-firmware
endef
TARGET_DEVICES += econet_vgp-42x6v1
"""

EN7523_CONFIG_APPEND = """
# ---------------------------------------------------------------------------
# Econet / vG vGP-42X6V1 (EN7523) -- board kernel options
#
# JFFS2             writable filesystem for the "data" overlay partition
# MTD_CMDLINE_PARTS keep cmdline partition parsing available
# SQUASHFS_XZ       xz-compressed read-only rootfs
#
# MTD_BLOCK / MTD_CHAR are NOT set by the stock en7523 config, which leaves the
# initramfs without /dev/mtd*; that blocks flashing from Linux and the
# sysupgrade path.  See docs/roadmap.md.
# ---------------------------------------------------------------------------
CONFIG_JFFS2_FS=y
CONFIG_JFFS2_FS_DEBUG=0
CONFIG_MTD_CMDLINE_PARTS=y
CONFIG_SQUASHFS_XZ=y
CONFIG_MTD_BLOCK=y
CONFIG_MTD_CHAR=y
"""

MT76_INSERTS = [
    (
        "$(PKG_BUILD_DIR)/firmware/mt7915_rom_patch.bin \\",
        [
            "$(PKG_BUILD_DIR)/firmware/mt7915_eeprom.bin \\",
            "$(PKG_BUILD_DIR)/firmware/mt7915_eeprom_dbdc.bin \\",
        ],
    ),
    (
        "$(PKG_BUILD_DIR)/firmware/mt7916_rom_patch.bin \\",
        [
            "$(PKG_BUILD_DIR)/firmware/mt7916_eeprom.bin \\",
        ],
    ),
]


def die(msg: str) -> None:
    print(f"!! {msg}", file=sys.stderr)
    raise SystemExit(1)


# ---------------------------------------------------------------------------
# export
# ---------------------------------------------------------------------------
def cmd_export(tree: str, outdir: str) -> None:
    tree_p = pathlib.Path(tree).resolve()
    if not (tree_p / "target" / "linux" / "airoha").is_dir():
        die(f"{tree_p} does not look like an OpenWrt tree with the airoha target")
    if not (tree_p / ".git").exists():
        die(f"{tree_p} is not a git checkout; cannot read pristine files")

    out = pathlib.Path(outdir)
    out.mkdir(parents=True, exist_ok=True)

    for name, rel in SOURCES.items():
        res = subprocess.run(
            ["git", "-C", str(tree_p), "show", f"HEAD:{rel}"],
            capture_output=True,
            text=True,
        )
        if res.returncode != 0:
            die(f"git show HEAD:{rel} failed: {res.stderr.strip()}")
        # normalise defensively: the patches must be LF only
        text = res.stdout.replace("\r\n", "\n")
        if not text.endswith("\n"):
            text += "\n"
        dest = out / f"{name}.orig"
        dest.write_text(text, encoding="utf-8", newline="\n")
        print(f"  exported {rel:<48} -> {dest.name} ({len(text)} bytes)")

    print(f"\nPristine originals in {out}")


# ---------------------------------------------------------------------------
# generate
# ---------------------------------------------------------------------------
def read_orig(pristine: pathlib.Path, name: str) -> str:
    p = pristine / f"{name}.orig"
    if not p.is_file():
        die(f"missing {p}; run `make-patches.py export` first")
    return p.read_text(encoding="utf-8").replace("\r\n", "\n")


def emit(relpath: str, old: str, new: str, outname: str) -> None:
    if old == new:
        die(f"{outname}: transformation produced no change for {relpath}")
    body = "".join(
        difflib.unified_diff(
            old.splitlines(keepends=True),
            new.splitlines(keepends=True),
            fromfile="a/" + relpath,
            tofile="b/" + relpath,
            n=3,
        )
    )
    text = f"diff --git a/{relpath} b/{relpath}\n{body}"
    PATCH_OUT.mkdir(parents=True, exist_ok=True)
    with open(PATCH_OUT / outname, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    n_add = sum(1 for l in body.splitlines() if l.startswith("+") and not l.startswith("+++"))
    n_del = sum(1 for l in body.splitlines() if l.startswith("-") and not l.startswith("---"))
    print(f"  {outname:<62} +{n_add} -{n_del}")


def cmd_generate(pristine_dir: str) -> None:
    pristine = pathlib.Path(pristine_dir)
    print(f"generating patches into {PATCH_OUT}")

    # 0001 -- FIT load address must equal _text = PHYS_OFFSET + TEXT_OFFSET
    rel = SOURCES["image-makefile"]
    orig = read_orig(pristine, "image-makefile")
    if orig.count(LOADADDR_OLD) != 1:
        die(f"expected exactly one occurrence of the old loadaddr in {rel}; "
            "the pinned revision probably changed -- update this script")
    emit(rel, orig, orig.replace(LOADADDR_OLD, LOADADDR_NEW),
         "0001-target-airoha-image-fix-en7523-FIT-load-address.patch")

    # 0002 -- board device entry
    rel = SOURCES["en7523-mk"]
    orig = read_orig(pristine, "en7523-mk")
    if "econet_vgp-42x6v1" in orig:
        die(f"{rel} already contains the device entry; nothing to do")
    emit(rel, orig, orig + EN7523_MK_APPEND,
         "0002-target-airoha-image-add-econet-vgp42x6v1-device.patch")

    # 0003 -- board kernel options
    rel = SOURCES["en7523-config"]
    orig = read_orig(pristine, "en7523-config")
    if "CONFIG_MTD_BLOCK" in orig:
        die(f"{rel} already sets CONFIG_MTD_BLOCK; update this script")
    emit(rel, orig, orig + EN7523_CONFIG_APPEND,
         "0003-target-airoha-en7523-enable-board-kernel-options.patch")

    # 0004 -- mt76 default eeprom blobs must be installed
    rel = SOURCES["mt76-makefile"]
    lines = read_orig(pristine, "mt76-makefile").splitlines(keepends=True)
    out: list[str] = []
    hits = 0
    for line in lines:
        out.append(line)
        for anchor, extra in MT76_INSERTS:
            if line.strip() == anchor.strip():
                hits += 1
                for e in extra:
                    out.append("\t\t" + e + "\n")
    if hits != len(MT76_INSERTS):
        die(f"{rel}: matched {hits}/{len(MT76_INSERTS)} anchors; "
            "the mt76 package layout probably changed")
    emit(rel, "".join(lines), "".join(out),
         "0004-package-mt76-install-default-eeprom-bins.patch")

    print("\ndone.  Verify with: ./scripts/apply-overlay.sh /path/to/openwrt")


# ---------------------------------------------------------------------------
def main() -> None:
    ap = argparse.ArgumentParser(
        description="Export pristine files and regenerate the OpenWrt patch series.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_exp = sub.add_parser("export", help="export pristine files from a checkout")
    p_exp.add_argument("tree", help="path to the OpenWrt checkout")
    p_exp.add_argument("outdir", help="directory to write *.orig into")

    p_gen = sub.add_parser("generate", help="regenerate openwrt/patches/*.patch")
    p_gen.add_argument("pristine", help="directory holding the *.orig files")

    args = ap.parse_args()
    if args.cmd == "export":
        cmd_export(args.tree, args.outdir)
    else:
        cmd_generate(args.pristine)


if __name__ == "__main__":
    main()
