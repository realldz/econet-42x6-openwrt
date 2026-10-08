#!/usr/bin/env python3
"""Write a unit MAC address into the MT7916 default eeprom blob.

Why this is needed
------------------
The MT7916 on the vGP-42X6V1 has a blank EFuse, so mt7915_eeprom_load() reads
zero free blocks, fails, and the driver falls back to the default blob that the
mt76 firmware package installs at

    /lib/firmware/mediatek/mt7916_eeprom.bin

That upstream blob carries a zero MAC, so is_valid_ether_addr() fails and the
driver logs

    mt7915e 0001:01:00.0: Invalid MAC address, using random address 02:...

which means a different MAC on every boot.  Writing the unit's real MAC into
the blob (and dropping it into <openwrt>/files/ or the Image Builder's files/)
fixes that without touching the driver.

Offsets, from mt7915/eeprom.h in the mt76 source tree:

    MT_EE_MAC_ADDR   0x004   2.4 GHz interface
    MT_EE_MAC_ADDR2  0x00a   5 GHz interface

Usage
-----
    # inspect what the blob currently holds
    python3 tools/mt7916_eeprom_mac.py --show mt7916_eeprom.bin

    # write a base MAC (5 GHz gets base+1 unless --second is given)
    python3 tools/mt7916_eeprom_mac.py mt7916_eeprom.bin A4:2B:B0:11:22:30 \\
        -o mt7916_eeprom.bin.local

    # install it for a source build / an Image Builder run
    install -D -m 0644 mt7916_eeprom.bin.local \\
        /path/to/openwrt/files/lib/firmware/mediatek/mt7916_eeprom.bin

Take the MAC from your own unit -- it sits in the vendor factory data (the
"factory" region of the flash and the vendor configuration partition).  Do not
copy a MAC from a different board: a duplicate MAC breaks the local network, and
a MAC from outside your own allocation is not yours to use.

The chip has a MAC filter and the driver derives the per-band addresses from
this blob, so both offsets are written from the base address unless you say
otherwise with --second.
"""

import argparse
import pathlib
import sys

MT_EE_MAC_ADDR = 0x004
MT_EE_MAC_ADDR2 = 0x00A


def parse_mac(text):
    parts = text.replace("-", ":").split(":")
    if len(parts) != 6:
        raise argparse.ArgumentTypeError(f"not a MAC address: {text}")
    try:
        octets = [int(p, 16) for p in parts]
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a MAC address: {text}")
    if any(o < 0 or o > 255 for o in octets):
        raise argparse.ArgumentTypeError(f"octet out of range: {text}")
    return octets


def format_mac(octets):
    return ":".join(f"{o:02x}" for o in octets)


def bump(octets, delta=1):
    value = 0
    for o in octets:
        value = (value << 8) | o
    value = (value + delta) & 0xFFFFFFFFFFFF
    return [(value >> (8 * (5 - i))) & 0xFF for i in range(6)]


def read_at(data, offset):
    return list(data[offset:offset + 6])


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Write a unit MAC into the MT7916 default eeprom blob.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Usage")[-1].strip(),
    )
    parser.add_argument("blob", type=pathlib.Path,
                        help="input eeprom blob (do not edit the installed copy)")
    parser.add_argument("mac", nargs="?", type=parse_mac,
                        help="base MAC to write, e.g. A4:2B:B0:11:22:30")
    parser.add_argument("--second", type=parse_mac, default=None,
                        help="explicit MAC for the 5 GHz interface")
    parser.add_argument("--show", action="store_true",
                        help="only print the MACs currently in the blob")
    parser.add_argument("-o", "--out", type=pathlib.Path, default=None,
                        help="write the result here instead of in place")
    args = parser.parse_args(argv)

    if not args.blob.is_file():
        print(f"!! no such file: {args.blob}", file=sys.stderr)
        return 1

    data = bytearray(args.blob.read_bytes())
    if len(data) < MT_EE_MAC_ADDR2 + 6:
        print(f"!! {args.blob} is too small to be an eeprom blob "
              f"({len(data)} bytes)", file=sys.stderr)
        return 1

    first = read_at(data, MT_EE_MAC_ADDR)
    second = read_at(data, MT_EE_MAC_ADDR2)
    print(f"current  2.4 GHz @0x{MT_EE_MAC_ADDR:03x}: {format_mac(first)}")
    print(f"current  5 GHz   @0x{MT_EE_MAC_ADDR2:03x}: {format_mac(second)}")

    if args.show or args.mac is None:
        if not args.show:
            print("\n(no MAC given; nothing written -- pass a MAC to write one)")
        return 0

    mac = args.mac
    if mac[0] & 0x01:
        print("!! that is a multicast address; refusing", file=sys.stderr)
        return 1
    if not any(mac):
        print("!! all-zero MAC; refusing", file=sys.stderr)
        return 1

    second_mac = args.second if args.second is not None else bump(mac)

    data[MT_EE_MAC_ADDR:MT_EE_MAC_ADDR + 6] = bytes(mac)
    data[MT_EE_MAC_ADDR2:MT_EE_MAC_ADDR2 + 6] = bytes(second_mac)

    out = args.out or args.blob
    if out == args.blob:
        backup = args.blob.with_suffix(args.blob.suffix + ".orig")
        if not backup.exists():
            backup.write_bytes(bytes(args.blob.read_bytes()))
            print(f"kept a copy of the input at {backup}")
    out.write_bytes(bytes(data))

    check = bytearray(out.read_bytes())
    if read_at(check, MT_EE_MAC_ADDR) != mac or \
       read_at(check, MT_EE_MAC_ADDR2) != second_mac:
        print("!! read-back does not match what was written", file=sys.stderr)
        return 1

    print(f"wrote    2.4 GHz @0x{MT_EE_MAC_ADDR:03x}: {format_mac(mac)}")
    print(f"wrote    5 GHz   @0x{MT_EE_MAC_ADDR2:03x}: {format_mac(second_mac)}")
    print(f"result   {out}")
    print()
    print("Install it so the driver finds it instead of the upstream blob:")
    print("  install -D -m 0644 <result> "
          "<openwrt>/files/lib/firmware/mediatek/mt7916_eeprom.bin")
    return 0


if __name__ == "__main__":
    sys.exit(main())
