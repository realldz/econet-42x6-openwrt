#!/usr/bin/env python3
"""Gate a built sysupgrade image before it is published or flashed.

Two checks, both of which have already cost this project real time.

1. FIT split geometry.  `mtdsplit_fit` derives the kernel partition as
   `round_up(FIT totalsize, erase block)` and then finds the rootfs by scanning
   for a filesystem magic *after* the FIT -- so the squashfs offset is exactly
   that rounded-up total.  The kernel partition on this board (mtd4) is
   `0x3A0000` = 3801088 bytes.  Measured on a build whose kernel carried the
   initramfs embedded: the squashfs sat at `0x760000` and the image was
   12,058,913 B instead of 9,437,473 B with the squashfs at `0x3A0000`.  Such an
   image cannot be split correctly by sysupgrade.  `scripts/build-firmware.sh`
   prints a warning for this; a warning is not enough for something that is
   about to be written to flash.

2. The rootfs must be a plausible squashfs v4 superblock: magic, a power-of-two
   block size, a known compression id and a `bytes_used` that fits inside the
   image.  The magic alone is not enough -- the kernel Image is uncompressed, so
   a stray `hsqs` in it would be reported as the rootfs offset and hide a real
   problem.

Usage
-----
    tools/verify_image.py <image> [more images...]
    tools/verify_image.py --warn-only <image>      # report, never fail
    tools/verify_image.py --limit 0x3A0000 <image>

An image whose name contains `-sysupgrade` MUST carry a rootfs.  Any other
image (an `-initramfs-kernel.bin`, say) legitimately has none, so it only has to
pass the superblock check when one is found.

Exit status is 0 when every image is safe to flash, 1 otherwise.
"""

import argparse
import os
import struct
import sys

SQUASHFS_MAGIC = b"hsqs"
COMPRESSIONS = {1, 2, 3, 4, 5, 6}  # gzip, lzma, lzo, xz, lz4, zstd
DEFAULT_LIMIT = 0x3A0000            # mtd4 "kernel" partition, from /proc/mtd


def plausible_superblock(data, off):
    """True when a squashfs v4 superblock starts at `off`."""
    size = len(data)
    if off < 0 or off + 96 > size or data[off:off + 4] != SQUASHFS_MAGIC:
        return False
    block_size, = struct.unpack_from("<I", data, off + 12)
    compression, = struct.unpack_from("<H", data, off + 20)
    block_log, = struct.unpack_from("<H", data, off + 22)
    major, = struct.unpack_from("<H", data, off + 28)
    bytes_used, = struct.unpack_from("<Q", data, off + 40)
    if major != 4 or compression not in COMPRESSIONS:
        return False
    if block_size < 4096 or block_size > (1 << 20) or block_size & (block_size - 1):
        return False
    if block_log != block_size.bit_length() - 1:
        return False
    return bytes_used <= size - off


def find_rootfs(data):
    """Every offset in `data` that looks like the start of a squashfs image."""
    offs = []
    i = data.find(SQUASHFS_MAGIC)
    while i >= 0:
        if plausible_superblock(data, i):
            offs.append(i)
        i = data.find(SQUASHFS_MAGIC, i + 1)
    return offs


def check(path, limit):
    """Return (ok, lines) for one image."""
    with open(path, "rb") as fh:
        data = fh.read()
    size = len(data)
    name = os.path.basename(path)
    offs = find_rootfs(data)
    lines = ["%s: %d bytes" % (name, size)]
    ok = True

    if not offs:
        if "-sysupgrade" in name:
            lines.append("    FAIL no squashfs superblock found -- a sysupgrade image "
                         "must carry a rootfs")
            ok = False
        else:
            lines.append("    ok   no rootfs (expected for a non-sysupgrade image)")
        return ok, lines

    off = offs[0]
    if len(offs) > 1:
        lines.append("    note %d candidate superblocks, using the first at 0x%X"
                     % (len(offs), off))

    if off > limit:
        lines.append("    FAIL squashfs at 0x%X > 0x%X (mtd4 'kernel' partition)"
                     % (off, limit))
        lines.append("         the FIT grew: the kernel carries the initramfs, or the")
        lines.append("         module selection made kconfig build modules in.  Check the")
        lines.append("         initramfs kind first, then --kmods / --kmods-exclude.")
        lines.append("         mtdsplit_fit would derive the wrong kernel size. Do not flash.")
        ok = False
    else:
        lines.append("    ok   squashfs at 0x%X <= 0x%X (fits the kernel partition)"
                     % (off, limit))

    return ok, lines


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--limit", default="0x%X" % DEFAULT_LIMIT,
                    help="maximum squashfs offset (default 0x%X = mtd4)" % DEFAULT_LIMIT)
    ap.add_argument("--warn-only", action="store_true",
                    help="always exit 0: report a bad image without failing the caller")
    ap.add_argument("images", nargs="+")
    args = ap.parse_args()

    try:
        limit = int(args.limit, 0)
    except ValueError:
        raise SystemExit("!! --limit must be a number, e.g. 0x3A0000")

    bad = 0
    for path in args.images:
        if not os.path.isfile(path):
            print("!! no such image: %s" % path)
            bad += 1
            continue
        ok, lines = check(path, limit)
        print("\n".join(lines))
        if not ok:
            bad += 1

    if bad and not args.warn_only:
        print("\n%d image(s) FAILED the flash gate -- do not publish or flash them"
              % bad)
        return 1
    if bad:
        print("\n%d image(s) failed the gate (--warn-only: not failing the build)"
              % bad)
    return 0


if __name__ == "__main__":
    sys.exit(main())
