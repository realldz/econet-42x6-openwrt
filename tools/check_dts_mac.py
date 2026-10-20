#!/usr/bin/env python3
"""Check that every MAC address of this board is read out of its own flash.

The board keeps exactly one address, in the U-Boot environment inside the
bootloader area of the SPI-NAND (offset 0x7C000, one 16 KiB sector: a 4-byte
little-endian CRC32, then NUL-separated `name=value` text).  The board DTS
declares that window as an MTD partition with
`compatible = "nvmem-cells", "fixed-layout"`, so the nvmem device mtdcore
registers FOR THE PARTITION ITSELF (mtd_nvmem_add()) parses its declared child
at partition-registration time -- there is no second nvmem provider, no layout
driver, and nothing to race against.  The child is a `mac-base` cell with the
17-byte ASCII address; the kernel's generic fixup
(nvmem_mac_base_ascii_read()) converts it and applies the index each consumer
passes, so airoha_eth, the DSA switch ports and mt76 all read the one stored
address.

Why NOT `compatible = "u-boot,env"` (the first attempt, verified broken on
hardware): mtdcore registers an nvmem device for EVERY MTD partition, so two
nvmem devices ended up sharing this partition's of_node -- mtd11's own nvmem,
registered first at partition creation, and the u-boot,env platform driver's
nvmem, registered later.  of_nvmem_cell_get() takes the FIRST nvmem that
matches the cell's parent node (drivers/nvmem/core.c, __nvmem_device_get(),
bus_find_device()), so every consumer resolved mtd11's cell-less nvmem and got
-ENOENT silently: random MACs on eth0 AND wifi, at boot and at 15.8 s alike.

Failures here are quiet and expensive.  A stale cell offset reads the wrong
flash bytes and gives a wrong -- not random -- address; a missing
`#nvmem-cell-cells` makes the lookup fail with random addresses; a duplicated
index puts the same address on two interfaces; a partition inserted before
this one shifts every later MTD index and breaks `root=/dev/mtdblock5`, which
the vendor U-Boot passes on the kernel command line.

Checks:

  1. exactly one partition carries both `nvmem-cells` and `fixed-layout`, its
     `reg` is the window the CRC lives in (0x7C000 + 0x4000, not one erase
     block), it is read-only, and it is the LAST partition of the table;
  2. it has `#address-cells = <1>` / `#size-cells = <1>` (the children's `reg`
     is read against them) and a child node named `ethaddr@19b` carrying
     `reg = <0x19B 0x11>` (where `ethaddr=` sits in the environment, 17 =
     3*ETH_ALEN-1 bytes of ASCII address), `compatible = "mac-base"` and
     `#nvmem-cell-cells = <1>`;
  3. the DTS contains no `mac-address` property any more: nothing may bake a
     per-unit value into the image;
  4. GDM1, lan1..lan4 and the two Wi-Fi bands each ask the `ethaddr` cell for a
     DISTINCT index, and the indices are the documented ones;
  5. the 5 GHz band is a child of the PCI node with `reg = <1>` -- mt76 looks up
     the MAC per band, by `reg`, among the children of the device node.

With `--dump FILE` it also redoes the arithmetic on a real image: FILE is the
raw `mtd0` (`dd if=/dev/mtd0 of=mtd0.bin`), a full-chip dump, or a bare 16 KiB
environment file.  It verifies the CRC32 the environment carries, checks that
the cell offset declared in the DTS is where `ethaddr=` actually sits in THIS
dump, and prints the address every consumer would end up with.

Usage:  tools/check_dts_mac.py [--repo-root DIR] [--dump FILE]
"""

import argparse
import os
import re
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dts_vs_image import dts_value, parse_dts, strip_comments  # noqa: E402

ENV_OFFSET = 0x7C000
ENV_SIZE = 0x4000
CELL_OFFSET = 0x19F          # where the value of `ethaddr=` starts in the window
CELL_LEN = 0x11              # 17 = 3 * ETH_ALEN - 1: the ASCII "xx:xx:..." form
CELL_NODE = "ethaddr@%x" % CELL_OFFSET

DTS_REL = "openwrt/overlay/target/linux/airoha/dts/en7523-vgp42x6v1.dts"

# label -> (index, what it is).  The index is the offset nvmem_mac_base_ascii_read
# adds to the stored address (`eth_addr_add`).
CONSUMERS = [
    ("gdm1", 0, "the CPU port (eth0, and the address on the label)"),
    ("gsw_port1", 1, "lan1"),
    ("gsw_port2", 2, "lan2"),
    ("gsw_port3", 3, "lan3"),
    ("gsw_port4", 4, "lan4"),
]
# band index -> cell index
BANDS = [(0, 6, "2.4 GHz"), (1, 7, "5 GHz")]

def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()

def raw_node(text, header_re):
    """The source text of the first node whose header matches, comments removed."""
    text = strip_comments(text)
    m = re.search(header_re, text)
    if not m:
        return None
    start = text.index("{", m.end() - 1)
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
    return None

def cells(value):
    """The integer list of a `<a b c>` property, or None when it is not one.

    Accepts either the raw source text of the property or the canonical form
    `dts_value()` returns for it, because silently returning None for a string
    argument is exactly the mistake this helper exists to catch.
    """
    if isinstance(value, str):
        value = dts_value(value)
    if not value or value[0] != "cells":
        return None
    out = []
    for kind, *rest in value[1]:
        if kind != "int":
            return None
        out.append(rest[0])
    return out

def eth_addr_add(mac, index):
    """The kernel's eth_addr_add(): add the index to the 6-byte address."""
    mac = bytearray(mac)
    for i in range(5, -1, -1):
        index += mac[i]
        mac[i] = index & 0xFF
        index >>= 8
        if not index:
            break
    return bytes(mac)

def fmt(mac):
    return ":".join("%02x" % b for b in mac)

def check_dts(root, bad):
    dts_path = os.path.join(root, DTS_REL)
    if not os.path.exists(dts_path):
        bad.append("%s: missing" % DTS_REL)
        return None

    labels, nodes, directives = {}, {}, []
    parse_dts(dts_path, labels, nodes, directives)

    def parent(path):
        return path.rsplit("/", 1)[0]

    def children(path):
        want = path + "/"
        return [p for p in nodes if p.startswith(want) and "/" not in p[len(want):]]

    # -- 1. the environment partition ------------------------------------------
    tables = [p for p in nodes
              if p.endswith("/partitions") and any(c.startswith(p + "/partition@")
                                                   for c in nodes)]
    if len(tables) != 1:
        bad.append("expected exactly one partition table, found %d" % len(tables))
        return None
    table = tables[0]
    parts = [c for c in children(table) if c.rsplit("/", 1)[1].startswith("partition@")]

    def compat(p):
        c = nodes[p].get("compatible") or ""
        got = dts_value(c)
        if got and got[0] in ("strings", "str"):
            return list(got[1])
        return [s.strip('"') for s in c.split(",") if s.strip('"')]

    env = [p for p in parts
           if "nvmem-cells" in compat(p) and "fixed-layout" in compat(p)]
    if not env:
        bad.append('no partition carries compatible = "nvmem-cells", "fixed-layout" '
                   "in %s; the mtdcore nvmem only parses declared cells for such a "
                   "partition, and every other shape (including the old "
                   "\"u-boot,env\") loses the nvmem-of_node lookup to mtdcore's own "
                   "cell-less nvmem and comes up with random MACs" % table)
        return None
    if len(env) > 1:
        bad.append('more than one partition claims "nvmem-cells" + "fixed-layout": %s'
                   % ", ".join(sorted(env)))
        return None
    env = env[0]
    leftover = [p for p in parts if "u-boot,env" in compat(p)]
    if leftover:
        bad.append('%s still carries "u-boot,env": the platform driver would register '
                   "a second nvmem on the same of_node, the exact ambiguity this "
                   "shape exists to remove" % ", ".join(sorted(leftover)))

    reg = cells(nodes[env].get("reg"))
    if reg != [ENV_OFFSET, ENV_SIZE]:
        bad.append("%s: reg is %s, expected <0x%X 0x%X> -- the window is the sector "
                   "the U-Boot environment lives in; anything else would read the "
                   "wrong bytes" %
                   (env, "<%s>" % " ".join("0x%X" % r for r in reg) if reg else "missing",
                    ENV_OFFSET, ENV_SIZE))
    if "read-only" not in nodes[env]:
        bad.append("%s: not marked read-only; it is U-Boot's, not ours" % env)
    if parts[-1] != env:
        bad.append("%s is not the last partition (it is followed by %s): an MTD index "
                   "is the position in the table, and U-Boot boots with "
                   "root=/dev/mtdblock5, so inserting a partition before this one "
                   "shifts every index after it" %
                   (env, ", ".join(p.rsplit("/", 1)[1] for p in parts[parts.index(env) + 1:])))

    # -- 2. the cell node ------------------------------------------------------
    # `#nvmem-cell-cells` cannot be seen through parse_dts(): it drops every line
    # that starts with `#` (that is how it skips `#include`/`#define`), and a
    # property beginning with `#` looks exactly like one.  Search the source of
    # this one partition for it instead.
    body = raw_node(read(dts_path), r"partition@7[cC]000\s*\{")
    have_addr_cells = body is not None and \
        re.search(r"#address-cells\s*=\s*<1>\s*;", body) is not None and \
        re.search(r"#size-cells\s*=\s*<1>\s*;", body) is not None
    if not have_addr_cells:
        bad.append("%s: missing `#address-cells = <1>` / `#size-cells = <1>`; the "
                   "nvmem core reads the child's `reg` (offset, then length) against "
                   "them" % env)
    have_cells = body is not None and \
        re.search(r"#nvmem-cell-cells\s*=\s*<1>\s*;", body) is not None
    if not have_cells:
        bad.append("%s: no `#nvmem-cell-cells = <1>` in the partition (found %s); "
                   "without it a consumer cannot pass an index and "
                   "of_nvmem_cell_get() fails" %
                   ("%s/%s" % (env, CELL_NODE),
                    "no such property" if body is not None else "no partition body"))

    cell = "%s/%s" % (env, CELL_NODE)
    if cell not in nodes:
        got = ", ".join(c.rsplit("/", 1)[1] for c in children(env)) or "none"
        bad.append("no child node named `%s` under %s (found: %s).  The name must be "
                   "the mac-base cell of this environment; its @%x is the offset in "
                   "the window and has to match the cell's own `reg`"
                   % (CELL_NODE, env, got, CELL_OFFSET))
    else:
        creg = cells(nodes[cell].get("reg"))
        if creg != [CELL_OFFSET, CELL_LEN]:
            bad.append("%s: reg is %s, expected <0x%X 0x%X> -- the offset is where "
                       "`ethaddr=` starts in the 16 KiB environment window "
                       "(MEASURED on the flash dump), and 0x11 is the 17-byte ASCII "
                       "form nvmem_mac_base_ascii_read() converts"
                       % (cell,
                          "<%s>" % " ".join("0x%X" % r for r in creg) if creg else "missing",
                          CELL_OFFSET, CELL_LEN))
        name_off = cell.rsplit("@", 1)[-1]
        if name_off != "%x" % CELL_OFFSET:
            bad.append("%s: the unit address in the node name does not match the "
                       "offset in its `reg` (0x%X)" % (cell, CELL_OFFSET))
        ccompat = compat(cell)
        if "mac-base" not in ccompat:
            bad.append("%s: no `compatible = \"mac-base\"`; without it the kernel "
                       "hands consumers the raw 17 ASCII bytes instead of a 6-byte "
                       "address" % cell)

    # -- 3. no baked-in address ------------------------------------------------
    baked = sorted(p for p, props in nodes.items() if "mac-address" in props)
    if baked:
        bad.append("%s: still carries a `mac-address` property; the point of the "
                   "nvmem cell is that no per-unit value ships in the image" %
                   ", ".join(baked))

    # -- 4/5. the consumers ----------------------------------------------------
    seen = {}
    for label, index, what in CONSUMERS:
        path = labels.get(label)
        if path is None or path not in nodes:
            bad.append("%s: node not found in %s" % (label, DTS_REL))
            continue
        names = dts_value(nodes[path].get("nvmem-cell-names"))
        want = ("str", ("mac-address",))
        if names != want:
            bad.append("%s (%s): nvmem-cell-names is %r, expected \"mac-address\"" %
                       (label, what, nodes[path].get("nvmem-cell-names")))
        got = dts_value(nodes[path].get("nvmem-cells"))
        if not got or got[0] != "cells" or len(got[1]) != 2 or got[1][0][0] != "phandle":
            bad.append("%s (%s): nvmem-cells is %r, expected <&ethaddr %d>" %
                       (label, what, nodes[path].get("nvmem-cells"), index))
            continue
        if got[1][0][1] != "ethaddr":
            bad.append("%s (%s): points at &%s, not &ethaddr" %
                       (label, what, got[1][0][1]))
            continue
        # Record what was actually asked for, not what was expected: a wrong and a
        # duplicated index are different mistakes, and the caller needs to see both.
        actual = got[1][1]
        if actual != ("int", index):
            bad.append("%s (%s): asks for index %s, expected %d" %
                       (label, what, actual[1] if actual[0] == "int" else actual, index))
            if actual[0] != "int":
                continue
        seen.setdefault(actual[1], []).append("%s (%s)" % (label, what))

    wifi = [p for p in nodes if re.search(r"/wifi(@[0-9a-fA-F,]+)?$", p)]
    for path in wifi:
        for band, index, what in BANDS:
            bp = "%s/band@%d" % (path, band)
            if bp not in nodes:
                bad.append("%s: no band@%d child (mt76 reads the MAC of band %d from "
                           "a child of the device node whose `reg` is %d)"
                           % (path, band, band, band))
                continue
            if cells(nodes[bp].get("reg")) != [band]:
                bad.append("%s: reg is %s, expected <0x%X>" %
                           (bp, nodes[bp].get("reg"), band))
            got = dts_value(nodes[bp].get("nvmem-cells"))
            if not got or got[0] != "cells" or len(got[1]) != 2 or \
                    got[1][0][0] != "phandle" or got[1][0][1] != "ethaddr":
                bad.append("%s (%s): nvmem-cells is %r, expected <&ethaddr %d>" %
                           (bp, what, nodes[bp].get("nvmem-cells"), index))
                continue
            actual = got[1][1]
            if actual != ("int", index):
                bad.append("%s (%s): asks for index %s, expected %d" %
                           (bp, what, actual[1] if actual[0] == "int" else actual, index))
                if actual[0] != "int":
                    continue
            seen.setdefault(actual[1], []).append("band@%d (%s)" % (band, what))
    if not wifi:
        bad.append("no Wi-Fi device node under a PCIe node: mt76_eeprom_override() "
                   "reads dev->dev->of_node, which only exists if the DTS gives the "
                   "device a child node whose `reg` matches its devfn")

    for index, users in sorted(seen.items()):
        if len(users) > 1:
            bad.append("index %d is used twice: %s" % (index, ", ".join(users)))
    return labels

def check_dump(path, bad, out):
    data = read_bytes(path)
    if len(data) == ENV_SIZE:
        win = data                       # a bare 16 KiB environment file
        prefix = "environment window"
    elif len(data) >= ENV_OFFSET + ENV_SIZE:
        win = data[ENV_OFFSET:ENV_OFFSET + ENV_SIZE]
        prefix = "at 0x%X" % ENV_OFFSET
    else:
        bad.append("%s: %d bytes, too short to hold 0x%X+0x%X (or a bare 0x%X-byte "
                   "window)" % (path, len(data), ENV_OFFSET, ENV_SIZE, ENV_SIZE))
        return
    stored = struct.unpack("<I", win[:4])[0]
    calc = zlib.crc32(win[4:])
    if stored != calc:
        bad.append("%s: CRC32 in the window is 0x%08X, computed 0x%08X over the "
                   "remaining 0x%X bytes %s; %s is not the sector the environment "
                   "lives in" % (path, stored, calc, ENV_SIZE - 4, prefix, path))
        return
    env = {}
    for item in win[4:].split(b"\x00"):
        if b"=" in item:
            k, _, v = item.partition(b"=")
            if k and k not in env:
                env[k.decode("latin1")] = v.decode("latin1")
    out.append("dump %s (window %s): CRC32 0x%08X ok, %d variables %s" %
               (path, prefix, stored, len(env), ", ".join(sorted(env)[:6])))
    raw = env.get("ethaddr")
    if not raw:
        bad.append("%s: no ethaddr variable in the environment (found: %s)" %
                   (path, ", ".join(sorted(env)) or "nothing"))
        return
    # The value of `ethaddr=` is at 4 (CRC) + (position of the `ethaddr=` key) +
    # len("ethaddr=").  That position is what the DTS cell's `reg` declares; a
    # different one means the variable set moved and the cell offset is stale.
    key_at = win.find(b"ethaddr=")
    value_at = key_at + len(b"ethaddr=")   # find() already skips the CRC prefix
    tail = win[value_at:value_at + CELL_LEN]
    if value_at != CELL_OFFSET or len(raw) != CELL_LEN or tail != raw.encode():
        bad.append("%s: the DTS cell expects the ethaddr value at 0x%X (0x%X bytes), "
                   "but this dump has it at 0x%X (%d bytes: %r) -- the environment "
                   "layout moved; update the cell `reg` in the DTS, then re-verify"
                   % (path, CELL_OFFSET, CELL_LEN, value_at, len(raw), raw))
    else:
        out.append("  cell reg <0x%X 0x%X> matches the dump (ethaddr value at 0x%X)"
                   % (CELL_OFFSET, CELL_LEN, value_at))
    try:
        base = bytes(int(b, 16) for b in raw.split(":"))
    except ValueError:
        bad.append("%s: ethaddr=%r is not a MAC address" % (path, raw))
        return
    if len(base) != 6 or base[0] & 1 or not any(base):
        bad.append("%s: ethaddr=%s is not a usable unicast address" % (path, raw))
    out.append("  ethaddr = %s (%s)" % (raw, "valid" if len(base) == 6 else "bad"))
    for label, index, what in CONSUMERS:
        out.append("  %-9s (%-46s) = %s" % (label, what, fmt(eth_addr_add(base, index))))
    for band, index, what in BANDS:
        out.append("  %-9s (%-46s) = %s" % ("band@%d" % band, what,
                                            fmt(eth_addr_add(base, index))))

def read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo-root", default=os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))),
        help="the repository to check (default: the one this script lives in)")
    ap.add_argument("--dump", help="raw mtd0, full-chip dump, or bare 16 KiB "
                   "environment file to verify")
    args = ap.parse_args()

    bad, out = [], []
    check_dts(args.repo_root, bad)
    if args.dump:
        check_dump(args.dump, bad, out)

    for line in out:
        print(line)
    if bad:
        print("")
        for line in bad:
            print("FAIL %s" % line)
        print("")
        print("%d problem(s): the image would come up with random or wrong "
              "addresses, or not at all" % len(bad))
        return 1
    print("ok: every MAC is read from flash at 0x%X (mac-base cell at 0x%X), one "
          "cell per consumer, and no per-unit value is in the tree"
          % (ENV_OFFSET, CELL_OFFSET))
    return 0

if __name__ == "__main__":
    sys.exit(main())
