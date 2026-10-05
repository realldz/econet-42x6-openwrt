# Vendor firmware analysis

This document is a methodology write-up: how the stock Econet vGP-42X6V1
firmware image was taken apart, what formats were encountered, how each one was
decoded, and what the exercise did and did not buy the OpenWrt port. It is about
technique and findings, not about a build recipe.

The board is an Airoha EN7523 GPON ONU with 128 MiB of SPI-NAND. The analysis
starts from a full 128 MiB chip dump and, later, an encrypted OTA image.

## Sources

Engineering notes and tooling in the development workspace. Everything below is
traceable to one of these.

| Source | Used for |
|---|---|
| `docs/econet/42X6_<SERIAL>.md` | device identification, live partition table, factory block, BOB, SSH-side facts |
| `docs/econet/42X6_romfile_cfg.md` | `romfile` format, HDR3, the A/B layout and boot flag, OTA image format |
| `docs/econet/42X6_pon_source_inventory.md` | public source inventory, HDR2 comparison with a sibling board, boot-flag candidate |
| `docs/econet/42X6_openwrt_build_prep.md` | board DTS inputs, build results, the calibration question |
| `docs/econet/42X6_uboot_console.md` | U-Boot location, env block layout and CRC, login logic, the decimal-only `mtd` trap |
| `docs/econet/42X6_openwrt_m1_status.md` | sections 12-15: vendor kernel symbol recovery, PCIe disassembly, the movw/movt decoding bug |
| `temp/42X6/decrypt_fw42x6.py` | OTA image decryption |
| `temp/42X6/romfile_tool.py` | `romfile` decrypt / XML / build round-trip |
| `temp/42X6/parse_hdr2.py` | HDR2 section boundaries and CRC candidates |
| `temp/42X6/slota_hdr2.py` | HDR2 + FIT magic walk over slot A |
| `temp/42X6/vendor_fit.py` | FIT token parser for the vendor kernel |
| `temp/42X6/dtb_show.py` | DTB token parser (used on the OpenWrt-built FIT) |
| `temp/42X6/bob_extract.py` | factory block and laser BOB extraction |
| `temp/42X6/mtd_parse_audit.py` | ELF/dynsym/PLT analysis of the vendor `mtd` tool |
| `temp/42X6/ub_extract.py` | LZMA decompression of the two U-Boot blobs |

Serial numbers, MAC addresses, GPON/PLOAM credentials and the U-Boot password
hash are deliberately not reproduced here; the unit serial appears as
`<SERIAL>`. The literal key material for the two encrypted containers is not
reproduced either -- its location in the vendor binaries is recorded instead.

## 1. The image formats encountered

Four nested containers had to be dealt with, in this order.

| Layer | Magic / marker | What it is |
|---|---|---|
| OTA update image | 260-byte outer header, then ASCII `Salted__` | encrypted firmware update file |
| `tclinux` container | ASCII `HDR2` | the payload that owns the `tclinux` / `tclinux_slave` partitions |
| FIT / DTB | `0xd00dfeed` | flattened image tree and device tree, inline in the container |
| `romfile` config | gzip stream containing `HDR3` | the configuration database, a separate partition; the `Salted__` wrapper is an extra layer used only for download/restore files |

### 1.1 The OTA image

The ISP-pushed update file starts with a 260-byte outer header (the first four
bytes are `00 01 00 00`, followed by a 256-byte RSA blob) and then an OpenSSL
salted payload beginning with `Salted__` at offset `0x104`.

`decrypt_fw42x6.py` handles it as follows: scan the file for `Salted__`, take the
8-byte salt at `+8`, derive key and IV with `EVP_BytesToKey` over the hardcoded
password using SHA-256, decrypt the remainder with AES-256-CBC, and strip the
PKCS#7 padding. The password is hardcoded in the vendor rootfs
(`libvtfw.so`, file offset `0x3ABC`); the literal value is not reproduced here.

The result is 25,789,251 bytes, and that plaintext is not merely *like* the
`tclinux` partition -- it **is** its contents: the first 512 bytes match the
start of `mtd4` (`tclinux`) byte-for-byte and the MD5s agree. That equivalence is
what made the OTA file usable as an offline stand-in for the flash partition, and
it is why `parse_hdr2.py` can operate on the decrypted file rather than on a
slice of the chip dump.

### 1.2 The `tclinux` container and its `HDR2` header

`tclinux` (slot A) is 40 MiB at `0xC0000`; `tclinux_slave` (slot B) is 40 MiB at
`0x28C0000`. Each is an `HDR2`-wrapped FIT image.

The header, as read by `parse_hdr2.py` and `slota_hdr2.py`:

| Offset | Width | Meaning |
|---|---|---|
| `0x00` | 4 bytes | magic `HDR2` |
| `0x08` | u32 LE | total size |
| `0x0C` | u32 LE | CRC field (custom; see section 7) |
| `0x10` | u32 LE | version |
| `0x50` | u32 LE | kernel size |
| `0x54` | u32 LE | rootfs size |
| `0x100` | -- | FIT begins, magic `0xd00dfeed` |

`parse_hdr2.py` walks the container like this: read the header fields, locate the
squashfs superblock by searching for `hsqs`, compute where it *should* start from
the header (`0x100` plus the kernel size), and read `bytes_used` out of the
squashfs superblock at `+0x28`. It then tries to match the header CRC field
against CRC-32 over a set of candidate ranges (payload from `0x200`, from `0x100`,
the kernel range, the rootfs range). The notes record that field as a custom CRC
that was not broken, so the candidate CRC ranges are a search, not a verification
step that succeeded.

`slota_hdr2.py` walks the whole 40 MiB slot for every `0xd00dfeed` occurrence and
prints each one's `totalsize`. It also checks the first bytes of slot B, which is
how the bare-FIT-versus-HDR2 difference between the two slots became visible.

For the V1.3.02 image the inline layout was: kernel 2,640,546 bytes, then the
squashfs at `0x286D70` with a 23,138,963-byte region. Note that the squashfs
offset inside slot B moved between firmware revisions (`0x2B46804` in V1.2.00
versus `0x2B46D70` in V1.3.02, a shift of `+0x56C`) -- an example of why offsets
read out of one dump should not be assumed valid for another.

A related detail worth knowing: the vendor `/proc/mtd` exposes both the
aggregate labels and their sub-ranges. `kernel` / `rootfs` (`mtd2` / `mtd3`) and
`kernel_slave` / `rootfs_slave` (`mtd5` / `mtd6`) are *views* into `tclinux`
(`mtd4`) and `tclinux_slave` (`mtd7`). The vendor tool refuses the four sub-range
labels, which is how the nesting was confirmed.

### 1.3 The FIT and the DTB inside it

`vendor_fit.py` is a hand-written FIT parser, written because there was no `dtc`
available on the analysis host. It reads the eight header words at `+8`
(`off_struct`, `off_strings`, `off_rsvmap`, version, last compatible, boot CPU,
size of the strings block, size of the struct block), slices out the strings
block, and then walks the struct block by FDT token number:

| Token | Meaning | Handling |
|---|---|---|
| `1` | `FDT_BEGIN_NODE` | read the NUL-terminated name, align the cursor to 4 bytes, print the path |
| `2` | `FDT_END_NODE` | pop the path |
| `3` | `FDT_PROP` | read length and name offset, slice the value, print selected properties |
| `4` | `FDT_NOP` | skip |
| `9` | `FDT_END` | stop |

The property formatter decides between a string, a big-endian cell array, and a
hex dump, which is what makes `/memory` and `reg` properties readable without
`dtc`. `dtb_show.py` is the same idea specialised for a DTB that is *not* inside
a FIT-conformant container (`dtb_show.py` locates the DTB in an OpenWrt image at
a fixed offset and length: `0x6EFEF8`, 4886 bytes), and it additionally dumps the
memory reserve map from `off_rsvmap`.

What the vendor DTB revealed is covered in section 3.

### 1.4 The `romfile` partition

A separate 256 KiB partition at `0x080000`, label `romfile`. Its own format is
covered in section 2.

### 1.5 Slot B

`tclinux_slave` at `0x28C0000`, 40 MiB. In the stock V1.3.02 image slot B holds a
complete second copy of the `HDR2` + FIT + squashfs layout with a different
build, which is the vendor's A/B upgrade mechanism. `slota_hdr2.py` checks
`0x28C0000` and reports its FIT magic and `totalsize` directly, and that is how
the "slot B is a bare FIT when OpenWrt is written there, not an HDR2 image"
difference showed up.

## 2. The `romfile`

### What it is

`romfile` is the vendor's persistent configuration database. It is a flat dump of
the `tcapi` tree: every node becomes an XML element and every attribute becomes an
XML attribute, wrapped in `<ROMFILE>`. It is what makes the ONT's identity, the
WAN/PPP/VLAN provisioning and the service toggles survive a reboot.

### How it is encoded

The on-flash blob is not XML. There are three layers:

```
romfile.cfg  (web-download backup, 262,208 B)
  [0..7]     "Salted__"
  [8..15]    8-byte random salt
  [16..]     AES-256-CBC ciphertext
             plaintext = 32-byte ASCII MD5 hex
                       + payload
             payload   = gzip(tar("ctromfile.cfg"))
             ctromfile.cfg = "HDR3" 0x100-byte header + XML
```

| Component | Detail |
|---|---|
| Cipher | `openssl aes-256-cbc -k <passwd>`; the same password is used for encrypt (`boa`) and decrypt (`libcfg_clisvc.so`) |
| KDF | `EVP_BytesToKey` with **SHA-256**, salted, PKCS#7. The firmware was built against OpenSSL 3.x, where `enc` switched its default KDF digest from MD5 to SHA-256 -- decrypting with MD5 produces wrong plaintext. This was confirmed empirically, not assumed. |
| Padding | the plaintext is padded with `0xFF` to exactly 262,144 bytes *before* the MD5 is taken, so the stored MD5 covers the padding too. In the observed backup the real gzip stream is 12,725 bytes and 249,419 bytes of `0xFF` follow it. A freshly built file without that padding risks being rejected by the parser. |
| Integrity | `openssl dgst -md5` over the payload; the device verifies the same value on restore |
| Salt | random on every save, so two backups of the same configuration legitimately differ |

The `HDR3` header inside `ctromfile.cfg`:

| Offset | Type | Meaning |
|---|---|---|
| `0x00` | char[4] | magic `HDR3` |
| `0x04` | u32 LE | `0x100` -- offset of the XML |
| `0x08` | u32 LE | total file size |
| `0x0C` | u32 LE | CRC-32/JAMCRC of the XML, i.e. `zlib.crc32(xml) ^ 0xFFFFFFFF` |
| `0x58` | u32 LE | XML size |

### How it was decoded and re-encoded

`romfile_tool.py` implements both directions:

```
romfile_tool.py decrypt <romfile.cfg> <out/ctromfile.cfg>   # verify MD5, gunzip, untar
romfile_tool.py xml     <romfile.cfg> <out.xml>             # stop at the XML
romfile_tool.py build   <in.xml> <out_romfile.cfg>          # XML -> HDR3 -> tar -> gzip -> pad -> MD5 -> AES
romfile_tool.py encrypt <ctromfile.cfg> <out_romfile.cfg>   # re-wrap an existing blob
```

`build` is deliberately faithful to the device output: GNU tar with a single
`ctromfile.cfg` member, `mtime = 0`, gzip level 9 with `mtime = 0`, the 32-byte
MD5 prefix, the `0xFF` padding to 256 KiB, then the OpenSSL salted envelope. The
round trip was verified byte-identical, and the output was cross-checked against
`openssl` 3.x.

The CRC choice was itself a finding: the header's CRC is CRC-32/JAMCRC
(`zlib.crc32(xml) ^ 0xFFFFFFFF`), not the plain `zlib.crc32`. Using plain
`crc32` fails the header check.

There is also a way around the encryption entirely: an authenticated `GET
/romfile.cfg` on the vendor web UI returns the live configuration as plaintext
XML. That gives a read-back channel for verifying what the device actually holds,
without needing a shell.

### What it revealed

Decoding the live `romfile` (from `0x080000`) yielded the GPON identity, which
until then had only been inferable:

- the GPON serial (redacted as `<SERIAL>`), with the vendor ID and the serial
  suffix in the expected places;
- the PLOAM password field **empty** -- this unit authenticates by serial, not by
  password;
- the LOID and LOID password empty;
- the equipment ID and software version identifiers;
- the WAN model: PPPoE over a VLAN-tagged PVC by default, with the bridge /
  route split and the OMCI-managed entries that the vendor firmware rebuilds on
  boot.

The same identity fields were cross-checked against the live `tcapi show GPON`
output over SSH, which agreed. That cross-check matters: it is the difference
between "the config file says so" and "the running device says so".

## 3. The FIT / DTB extraction

The stock device tree was recovered from the FIT inside slot A with
`vendor_fit.py` and kept as a clean dump. Recovering it was the single highest-
value step in the whole exercise, because the vendor DTB is the only place the
vendor's own register layout is written down.

What it revealed:

| Area | What the vendor DTB said |
|---|---|
| PCIe node | `compatible = "ecnt,pcie-en7523"`, **six** register windows: `0x1fa91000`, `0x1fa92000`, `0x1fa90000` (the shared subsystem block), and `0x1a100000`, `0x1a148000`, `0x1a14a000` |
| PCIe `ranges` | 256 MB (`0x10000000`) |
| PCIe lanes | `num-lanes = <1>` on both ports |
| PCIe PHY | a `pcie_phy@1fa93700` node with two windows of `0x568` each (`0x1fa93700`, `0x1fa95700`) |
| Optical | an xPON MAC, a PON PHY and a PON PCS/SGMII node with their interrupt numbers |
| Memory | a memory node claiming **1 GiB** of DRAM |

Two of those needed correction before they were usable:

1. **The three `0x1a1xxxxx` registers do not exist on EN7523.** Reading them on
   hardware returns `0xdeadbeef`. They are leftovers from another SoC in the same
   vendor family. Reading them is harmless, but they must not be copied into a
   board DTS as if they were real.

2. **The 1 GiB DRAM claim is wrong for this board.** The live system reports
   `MemTotal: 480136 kB` in `/proc/meminfo`, and the vendor U-Boot itself prints
   `DRAM:  496 MiB`. Both are consistent with 512 MB of physical DRAM, not 1 GiB.
   The board DTS was therefore written with 512 MB plus a `usable-memory-range`,
   not with the DTB's value.

The lesson generalises: a static blob is not a measurement. Where the DTB and the
running system disagreed, the running system won.

## 4. The factory block and the laser BOB

### Finding it

The last 23 MB of the chip (`0x6900000`-`0x8000000`) is not covered by any MTD
partition. The vendor reaches it directly through its own driver and through the
bad-block table, so the partition table gives no clue that anything is there. The
factory block was found by looking at that uncovered tail.

The absolute locations are the verified ones:

| Location | Content |
|---|---|
| `0x6F00000` | factory block; magic `0x12344321` at `+0x004` |
| `0x6F00497` | start of the laser BOB blob; its own magic `0x07050701` at blob `+0x94`, i.e. flash `0x6F0052B` |
| `0x6FC0000` | a single ASCII byte `'1'` (see section 6) |
| `0x75E0000` | magic `RAWB` |
| `0x7FE0000` | magic `BMT` (bad-block table, in the last two blocks) |

### What the factory block holds

| Offset | Field |
|---|---|
| `+0x004` | magic `0x12344321` |
| `+0x0AC` | an ASCII field (a board/vendor code; meaning not established) |
| `+0x21C` | model string `ONT.vGP-42X6V1` |
| `+0x23C` | a second ASCII field (a production string; meaning not established) |
| `+0x2BC` | GPON serial (`<SERIAL>`) |
| `+0x497` | the laser BOB blob |
| `+0x74C` | version string `MGP6.1.0` |

This is the per-unit identity: the GPON serial the OLT authenticates against, and
the laser calibration. Both are unit-specific and neither can be copied from
another board.

### The BOB blob

`bob_extract.py` reads the blob at the fixed offset `0x6F00497` and validates it
by decoding the magic at `+0x94`:

- magic `0x07050701` splits into a profile byte `0x07` (GPON) and a variant byte
  `0x01`, which corresponds to the EN7571 laser driver;
- the last non-`0xFF` byte inside a 0x200-byte window is at `+0xE0`, so the real
  payload is 225 bytes, and the remainder of the window is erased flash. The
  public EN7571 driver accepts a BOB payload of 161 to 512 bytes, so 225 is
  comfortably in range;
- the extracted artifact is 400 bytes: the blob plus `0xFF` padding.

**The location was corroborated twice, which is why it is trusted.** The vendor
tool on the running unit can read it directly:

```
/userfs/bin/mtd bob get <file>
```

which prints `read bob magic code is 0x07050701` and returns 256 bytes. Reading
that live dump and the offline extraction byte-for-byte, the first 256 bytes are
identical (sha256 `96d848fdfb9078a79acf59c242a9249b0b247ff2d38194fe05fe19355056f863`).
So the offset, the size and the content are all confirmed by two independent
paths, not by arithmetic alone.

Two operational warnings came out of this:

- `mtd bob get` is **not** read-only. It prints `Unlocking reservearea ...` and
  writes an unlock marker into the raw area before reading. Treat every `mtd`
  command aimed at the raw tail as a write.
- The unit rebooted once during that live reconnaissance, in the same window as
  the `mtd bob get` runs. Causality with the watchdog or the power supply was
  never excluded. The practical rule adopted was to run raw-area `mtd` commands
  only when genuinely necessary, and not back to back.

## 5. Kernel analysis

### Getting symbols at all

The vendor kernel ships stripped, but it is not stripped of everything: the
compressed kernel component decompresses to a 7,143,424-byte image, and
`vmlinux-to-elf` reconstructed an ELF32 ARM from it with a full symbol table --
**39,289 symbols**, link base `0xc0088000`, written out as an 8.6 MB
`vendor_vmlinux.elf`. That single step turned "guess the register sequence" into
"read the function".

The recovered symbol table is a genuine artefact and it is precise. For example:

```
c02faa2c l     F .kernel	00000000 mtk_pcie_startup_port_v2
c02fb3a8 g     F .kernel	00000000 mt7512_pcie_fixup
c06f074c l     F .kernel	00000000 early_tclinux_info
c06f0800 l     F .kernel	00000000 early_onutype
c06f0880 l     F .kernel	00000000 early_bootflag
c06f08c0 l     F .kernel	00000000 early_serdes_sel
c06f0798 l     F .kernel	00000000 early_tclinux_mac
c06f0908 l     F .kernel	00000000 early_hardware_vendor
c06f06dc l     F .kernel	00000000 ecnt_xpon_driver_init
c06f06ec l     F .kernel	00000000 ecnt_pon_phy_driver_init
```

Two things follow from that list. First, the PCIe driver functions can be read by
address. Second, the `early_*` names are hard evidence that the kernel parses the
boot flag, the tclinux metadata, the MAC, the ONU type, the serdes selection and
the hardware-vendor string very early in boot -- which is exactly the state that
would otherwise have to be guessed from U-Boot messages. And `ecnt_xpon_driver_init`
plus `ecnt_pon_phy_driver_init` confirm that the PON MAC and PON PHY are built
into the vendor kernel, not loaded as modules.

### The disassembler was lying

Disassembling the reconstructed ELF with the toolchain `objdump` produced
plausible-looking but **wrong** output. The ELF that `vmlinux-to-elf` emits
declares `e_flags` as **armv3m**, so `objdump` decoded the ARMv7 `movw`/`movt`
instructions as entirely different instructions -- `tst` and `cmp` -- with the
wrong registers and the wrong constants, and every subsequent `ldr`/`str`
displacement was then off.

A concrete, checked example: the encoding `e30306f8`, which is `movw r0, #0x36f8`,
was printed as `tst r3, #248, 12`.

This matters more than a normal tooling annoyance because the mis-decoded output
is *readable*. It produced register writes with plausible but fabricated
constants, and those constants were load-bearing for the PCIe work.

Two ways out, both used:

1. Disassemble with a toolchain that declares the right ISA (an armv7
   cross-toolchain), or
2. Decode the two instructions by hand:
   `imm16 = ((w >> 4) & 0xF000) | (w & 0xFFF)` and `Rd = (w >> 12) & 0xF`.

The durable fix was `vdis.py`, built on capstone with `CS_ARCH_ARM` /
`CS_MODE_ARM`. It does three things beyond a plain disassembler:

- it decodes with the correct architecture, so `movw`/`movt` come out right;
- it recombines a `movw` followed by a `movt` into the full 32-bit constant;
- it resolves `ldr rX, [pc, #imm]` automatically and prints both the constant and
  the **string** at the target address, which is what makes format strings and
  register names visible in a listing.

With that, `mtk_pcie_startup_port_v2` (`0xc02faa2c`) and
`mt7512_pcie_fixup` (`0xc02fb3a8`) were decoded in full. The most useful results
were partly negative, and they are recorded as such: the vendor startup path
never writes the PCIe reset control register at `0x510` (it relies on U-Boot
having initialised the PHY and SGMII), and it does not configure MSI in the
startup path either. Those absences are as informative as the writes -- they show
which parts of the vendor's working state were inherited rather than set up, and
therefore which parts a mainline driver has to do itself.

### Small-binary analysis: the vendor `mtd` tool

`mtd_parse_audit.py` is a separate, smaller analysis of a much smaller ELF:
`userfs/bin/mtd`. It parses the ELF section headers, reads `.dynsym`/`.dynstr`,
maps `.rel.plt` entries to symbol names, and then disassembles `.text` with
capstone looking for `bl` calls into the `atoi`/`sscanf` stubs.

The finding that mattered was in the import list, not the disassembly: the binary
imports `atoi` and `__isoc99_sscanf`, and **neither `strtoul` nor `strtol`**.
Therefore `atoi("0x7C000")` returns `0`, because `atoi` stops at `x`. Any offset
passed to this tool in hexadecimal silently becomes zero. That is documented in
section 6 along with the consequence.

## 6. Boot-time behaviour discovery

### The U-Boot blobs

`mtd0` is not flat code. Most of it is LZMA-compressed, so grepping the dump for
U-Boot strings finds nothing at all -- a first attempt at string-searching the
firmware for `UserName` came up empty for exactly that reason. `ub_extract.py`
decompresses the two candidate regions with `lzma.FORMAT_ALONE`:

| Flash offset | Decompressed size | Content |
|---|---|---|
| `0x21000` | 32,896 bytes | stage-1 loader blob |
| `0x24800` | 265,072 bytes | U-Boot `2014.04-rc1` |

The link base was recovered from the literal pool: the dwords pointing at the
`"UserName: "` and `"Password: "` strings resolve to `0x81E328B1` and
`0x81E328BC`, which places `TEXT_BASE` at `0x81E00000`. That is how a stripped,
compressed bootloader becomes addressable.

### The env block

The U-Boot environment lives at `0x7C000`, 16 KiB:

| Offset | Size | Content |
|---|---|---|
| `0x7C000` | 4 | CRC32, little-endian |
| `0x7C004` | `0x3FFC` | `key=value\0...` environment data |

The CRC definition was determined by brute-force search over candidate ranges and
then confirmed as a self-test: `crc32(flash[0x7C004:0x80000]) ==
u32le(flash[0x7C000:0x7C004])`. Note the range: the CRC covers the entire
remaining 16,380 bytes of the partition including the zero fill, and there is no
separate `flags` byte as a conventional U-Boot `env_t` would have.

From the env, the boot behaviour is directly readable: `bootcmd=flash imgread
2048;bootm`, `bootdelay=3`, `loadaddr=0x81800000`, `ipaddr=192.168.1.1`,
`serverip=192.168.1.126`, `board=en7523_evb`, plus the GPIO and board
identification values. This is where the vendor's boot mechanism stops being a
black box.

### The login check

The login routine itself was recovered by disassembly of the decompressed
U-Boot. Its logic is:

1. read the username with echo, then the password without echo;
2. hash the password with SHA-256 and render it as **lowercase** hex;
3. compare the username with `strncmp(input, getenv("username"), 16)`;
4. compare the hex digest with `strcmp(hex, getenv("password"))`.

Two consequences follow, and both are operationally important:

- The stored `password` env variable is always a SHA-256 hex digest, never
  plaintext. The `setenv` command is wrapped so that it hashes whatever you give
  it and prints a confirmation -- so an operator, not the factory, set this
  password. The plaintext was never recovered: roughly 24,000 candidate tokens
  from every config and romfile in the workspace, plus a brute-force over 38.4
  million candidates, produced no match. It is a human-chosen value, not derivable
  from the firmware.
- A corrupt env CRC makes U-Boot fall back to its compiled-in defaults, and the
  comparison then can never succeed, because the default `password` is stored as
  plaintext while the code compares against a hex digest. So corrupting the env
  does not lock you out of *booting* -- the machine still boots -- but it does
  permanently remove the U-Boot console path unless the env is rewritten with
  both a correct digest and a correct CRC.

### The two boot slots and the boot flag

Slot A versus slot B is a single byte that the bootloader reads before loading
anything. The evidence for it comes from three directions:

1. **The vendor's own U-Boot output**, which narrates the decision:

   ```
   bootflag==0 --> booting from Main Image
   ...
   write 1 to boot_flag_addr:0x6fc0000
   bootflag==1 --> booting from second image
   ```

   So the flag is one byte, `0` selects the main (slot A) image, and the
   dual-image fallback logic flips it itself after a failed boot and prints the
   address it wrote to.

2. **The vendor kernel's early-boot symbols.** `early_bootflag` at `0xc06f0880`,
   alongside `early_tclinux_info`, `early_tclinux_mac`, `early_onutype`,
   `early_serdes_sel` and `early_hardware_vendor`, all clustered around
   `0xc06f07xx`-`0xc06f09xx`. The kernel parses the same flag and the tclinux
   metadata from the boot argument area very early, before most drivers exist.

3. **The vendor userspace tool.** `/usr/bin/sys bootflag read|swap|checksum`
   reads, flips and checksums the flag, and the OTA upgrade path writes the new
   image into the *other* slot and then swaps the flag, rather than writing the
   partition it is currently booted from.

**Where the flag lives is not settled by the sources, and this document will not
pretend otherwise.** Three candidates are in play:

| Candidate | Source |
|---|---|
| `0x6FC0000` | what U-Boot itself prints, and the location of the ASCII byte `'1'` found in the dump |
| `0x68C0000` | `reservearea + 0x200000`, using the live `/proc/mtd` reservearea base of `0x66C0000` |
| `0x6FC0000` again, via `reservearea + 0x200000` | an older note that used a deduced reservearea base of `0x6DC0000` |

The two `+0x200000` derivations only agree with each other because they use
different bases. And the encodings disagree too: the dump holds the ASCII
character `'1'` (`0x31`) at `0x6FC0000`, while U-Boot's messages imply a binary
`0`/`1`, and the live kernel command line reported `bootflag=0`. Which of these
is the authoritative encoding is open.

### The decimal-only trap

Analysis of `userfs/bin/mtd` (section 5) established that it parses its numeric
arguments with `atoi` alone. The consequence was not theoretical: an env write
was issued as

```sh
/userfs/bin/mtd writeflash /tmp/env16k.bin 16384 0x7C000 bootloader
```

`atoi("0x7C000")` returned `0`, so 16,384 bytes were written to offset 0 of
`mtd0`, overwriting the stage-1 loader, and the board came up with no LEDs at
all. Because NAND erases in 128 KiB blocks, the damage was confined to the first
block; the U-Boot LZMA blobs at `0x21000`/`0x24800` and the original env at
`0x7C000` were untouched. Recovery needed only the first 128 KiB, not a full chip
write.

The analysis held up where the command did not: the disassembly correctly
predicted the failure mode before the fix, and the cross-check that every
previously successful flash write in the project had used offset `0` confirmed
the interpretation.

## 7. What this unlocks, and what it does not

### What it unlocked

- **The stock partition map.** Both the vendor 11-partition `/proc/mtd` view and
  the seven physical partitions the OpenWrt board DTS uses: `bootloader`,
  `romfile`, `tclinux`, `tclinux_slave`, `data`, `config`, `reservearea`. The
  write-safety rules for this board rest directly on this, together with the raw
  tail that belongs to no partition.
- **The PCIe register layout.** The vendor DTB gave the register windows and the
  PHY node; the vendor kernel disassembly gave the actual startup sequence and,
  importantly, showed which steps the vendor *did not* perform because U-Boot had
  already done them. That, combined with live measurement, is what produced the
  root-complex quirk.
- **The Wi-Fi parameters.** Two functions of one MT7916, which driver binds which
  function, and that the mainline `mt76` stack is sufficient. It also exposed the
  eeprom question, which turned into the packaging fix described in
  [wifi.md](wifi.md).
- **The optical parameters.** The laser driver identity, the TX-disable GPIO, and
  the factory block's location, which is what the PON device-tree overlay is
  built from.
- **The boot chain.** The FIT load/entry address contract, why the vendor
  autoboot cannot boot a generic OpenWrt FIT, and where the A/B flag lives
  (modulo the ambiguity above). That is the subject of
  [booting.md](booting.md).
- **The configuration plane.** Being able to decode and re-encode `romfile`
  means the vendor configuration can be changed and the GPON identity read
  without shell access, and the plaintext `GET /romfile.cfg` endpoint gives a
  read-back channel for verification.

### What it did not do

- **It did not produce a working Ethernet driver.** The vendor Ethernet path is
  user-space libraries plus kernel modules (`qdma_lan.ko`, `qdma_wan.ko`,
  `libmtkswitch.so`), not a source tree. Reading the vendor binaries gave register
  knowledge but not a driver. Mainline `airoha_eth` matches only `en7581` and
  `an7583`, and the OpenWrt target's `en7523.dtsi` has no ethernet/GDM/switch
  node at all. Nothing in this analysis changed that.
- **It did not produce a working PON driver.** The vendor `xpon` and PON PHY
  code is built into the vendor kernel, and the userspace is a set of `.ko` files
  and libraries. Recovering symbols and disassembling them does not yield a
  driver. Public source for the protocol layers exists independently, but that is
  a separate line of work from this analysis.
- **It did not recover the vendor kernel as compilable source.** The symbol
  recovery yields names, addresses and code, not C, and the addresses are tied to
  one build.
- **It did not resolve the boot-flag location or encoding.** Section 6 states the
  candidates; none is confirmed over the others.
- **It did not recover the U-Boot console password.** It has to be replaced by
  rewriting the env, with all the risk that carries.
- **It did not recover the HDR2 CRC definition**, so images cannot be rebuilt
  from scratch with a verified header on the strength of these sources.

The honest summary is that this analysis recovered *parameters and layout*. It
made the port possible by removing guesswork from the hardware description; it
did not by itself write any driver.

## 8. Methodology lessons

- **A chatty console was the thing that kept the bring-up tractable.** The vendor
  image narrates its own decisions on the UART -- which image it is booting, when
  it flips the boot flag, and to which address. Without that, the A/B mechanism
  would have been inferred rather than observed. The same holds on the kernel
  side: the `early_*` symbol cluster showed that boot state is parsed in the first
  moments of kernel init, which focused attention on the boot argument area
  instead of the driver layer.
- **Do not guess register semantics without a source-level cross-check.** The
  costly example was treating a "WFDMA ring table is all defaults" reading as a
  root cause. It was a *consequence*: the driver had written the ring registers
  correctly, and a later reset had returned them to defaults. A static snapshot
  after the fact could not distinguish cause from effect; only a time-ordered
  measurement could. The retraction is part of the record.
- **A disassembler that is confidently wrong is worse than no disassembler.** The
  `armv3m` `e_flags` made `objdump` render `movw`/`movt` as plausible `tst`/`cmp`
  with fabricated constants. Validate the disassembler against a known encoding,
  or pick one that declares the right ISA, before trusting anything it prints --
  especially constants that will become register writes.
- **Compressed blobs hide their strings.** Grepping the 128 MiB dump for U-Boot
  strings found nothing, because the bootloader is LZMA-compressed. Decompress
  first, then search.
- **Know how your flash tool parses its arguments.** The overnight loss of a
  bootloader came from `atoi` meeting `0x7C000`. Read the import list of the
  binary you are about to trust with a write. And always read back and compare a
  hash before rebooting.
- **Confirm a per-unit blob against a live read, not against arithmetic.** The
  BOB offset was trusted because the same 256 bytes came back from the vendor
  tool on the running unit and from the offline extraction. One source alone
  would have been a plausible guess.
- **Prefer the running system over the static blob when they disagree.** The
  vendor DTB claims 1 GiB of DRAM; `/proc/meminfo` and U-Boot both say 512 MB.
  The DTB also contains three PCIe registers that return `0xdeadbeef`. A dump is
  a claim, not a fact.

## 9. Where the evidence is thin or open

- **The HDR2 CRC.** The notes describe the field at `+0x0C` as a custom CRC that
  was not broken; `parse_hdr2.py` only *tests* candidate CRC ranges. No verified
  definition is recorded here, so `HDR2` images cannot be regenerated with a
  trustworthy header on the basis of these sources.
- **The factory block's offset arithmetic does not reconcile.** The absolute
  locations (`0x6F00000` for the factory block, `0x6F00497` for the BOB) are
  verified twice over. But `bob_extract.py` derives the factory block as
  `reservearea + 0x140000` using a reservearea base of `0x6DC0000`, while the
  live `/proc/mtd` reports reservearea as `0x66C0000` with size `0x240000`. Those
  two do not produce `0x6F00000`. Use the absolute offsets; treat the relative
  arithmetic as unreconciled.
- **The boot flag location and encoding.** `0x6FC0000` (U-Boot's own message, and
  the ASCII `'1'` in the dump) versus `0x68C0000` (`reservearea + 0x200000` from
  the live partition table); binary `0`/`1` versus ASCII `'1'`. Open.
- **The two extra ASCII fields in the factory block** at `+0x0AC` and `+0x23C`
  are readable but their meaning is not established.
- **The vendor kernel version** is recorded in the notes as 4.4.115 by way of the
  recovered ELF; this analysis did not independently verify the version string,
  and `vendor_vmlinux_syms.txt` carries 39,294 lines where the notes cite 39,289
  symbols (the difference is the file's header lines, but the exact count should
  be read from the file rather than from this document).
- **The PLT-to-symbol mapping in `mtd_parse_audit.py` is inferred, not decoded.**
  The script falls back to assigning PLT stubs in relocation order rather than
  decoding each stub, so the exact stub addresses it reports for `atoi`/`sscanf`
  are approximate. The conclusion drawn from it -- that the binary imports `atoi`
  and neither `strtoul` nor `strtol` -- rests on the `.dynsym` import list, which
  is read directly and is solid.
- **The reboot during live BOB reconnaissance is unexplained.** It coincided with
  the `mtd bob get` runs, but the notes explicitly record that a causal link with
  the watchdog or the power supply was never excluded.
