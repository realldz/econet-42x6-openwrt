#!/usr/bin/env python3
"""Verify a NEW OpenWrt image: FIT load/entry + kernel _text link (they must agree)."""
import lzma
import os
import re
import struct
import sys

# Default image path, relative to the repository root. The tool is normally called as
# `python3 tools/verify_build.py <image>`, which overrides this.
BIN = os.path.join("bin", "targets", "airoha", "en7523",
                   "openwrt-airoha-en7523-econet_vgp-42x6v1-initramfs-kernel.bin")
if len(sys.argv) > 1:
    BIN = sys.argv[1]
buf = open(BIN, "rb").read()
print("file          : %s\nsize          : %d byte" % (os.path.basename(BIN), len(buf)))

magic = struct.unpack(">I", buf[0:4])[0]
print("FIT magic     : 0x%08X  totalsize=%d" %
      (magic, struct.unpack(">I", buf[4:8])[0]))
(off_struct, off_strings, off_rsvmap, ver, lastcomp, bootcpu,
 size_strings, size_struct) = struct.unpack(">8I", buf[8:40])
strings = buf[off_strings:off_strings + size_strings]


def s(o):
    e = strings.find(b"\x00", o)
    return strings[o:e].decode("latin-1") if 0 <= o < len(strings) and e > o else "?%d" % o


load = entry = None
kdata = ksize = None
pos, path, depth = off_struct, [], 0
while pos < off_struct + size_struct:
    tok = struct.unpack(">I", buf[pos:pos + 4])[0]
    pos += 4
    if tok == 1:
        e = buf.find(b"\x00", pos)
        name = buf[pos:e].decode("latin-1")
        pos = (e + 4) & ~3
        if depth == 0:
            name = ""
        path.append(name)
        depth += 1
    elif tok == 2:
        depth -= 1
        if path:
            path.pop()
    elif tok == 3:
        ln, noff = struct.unpack(">II", buf[pos:pos + 8])
        pos += 8
        val = buf[pos:pos + ln]
        pos += (ln + 3) & ~3
        nm = s(noff)
        node = path[-1] if path else ""
        if node.startswith("kernel"):
            if nm == "load":
                load = struct.unpack(">I", val)[0]
            elif nm == "entry":
                entry = struct.unpack(">I", val)[0]
            elif nm == "data-offset":
                kdata = struct.unpack(">I", val)[0]
            elif nm == "data-size":
                ksize = struct.unpack(">I", val)[0]
    elif tok == 4:
        pass
    elif tok == 9:
        break
    else:
        print("!! token 0x%x" % tok)
        break

print("kernel load   : 0x%08X" % (load or 0))
print("kernel entry  : 0x%08X" % (entry or 0))

# if the FIT embeds the data directly (no data-offset) then locate it from the Data
# Start printed by iminfo
if kdata is None:
    # OpenWrt-style FIT: node /images/kernel-1 has a 'data' property holding the
    # lzma data
    kdata, ksize = 0xE4, None
    print("(no data-offset -> using offset 0xE4 as for an inline FIT)")

if ksize is None:
    # LZMA stream length: decompress sequentially
    ksize = len(buf) - kdata
print("kernel data   : offset 0x%X  size %d" % (kdata, ksize))

img = lzma.decompress(buf[kdata:kdata + ksize], format=lzma.FORMAT_ALONE)
print("Image unpacked: %d byte (0x%X)" % (len(img), len(img)))
first = struct.unpack("<I", img[:4])[0]
print("first word    : 0x%08X (%s)" % (first, "bl -> ARM32 Image" if (first >> 24) == 0xEB else "?"))

print("\n--- find the _text link via '.long .' style literal pool ---")
best = None
for cand in (0xC0008000, 0xC0208000, 0xC0200000, 0xC0000000):
    hits = sum(1 for f in range(0, len(img) - 4, 4)
               if struct.unpack("<I", img[f:f + 4])[0] == cand + f)
    print("   _text = 0x%08X : %d matches" % (cand, hits))
    if best is None or hits > best[1]:
        best = (cand, hits)

print("\n--- CONCLUSION ---")
text = best[0]
tofs = text - 0xC0000000                      # TEXT_OFFSET
phys = 0x80000000 + tofs                       # physical _text = PHYS_OFFSET + TEXT_OFFSET
print("   _text link       = 0x%08X  -> TEXT_OFFSET 0x%X -> physical 0x%08X" % (text, tofs, phys))
print("   FIT load/entry   = 0x%08X / 0x%08X" % (load or 0, entry or 0))
ok = (phys == (load or 0)) and (phys == (entry or 0))
print("   MATCH?           %s" % ("YES - the kernel will run" if ok else "NO - it will deadloop!"))
poff = (load or 0) - tofs
print("   PHYS_OFFSET      = load - TEXT_OFFSET = 0x%08X -> 2MiB aligned? %s"
      % (poff, "YES" if poff % 0x200000 == 0 else "NO"))
sys.exit(0 if ok else 1)
