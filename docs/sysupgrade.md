# Sysupgrade and persistent install on the Econet vGP-42X6V1 (Airoha EN7523)

**Board:** Econet / vG vGP-42X6V1 GPON ONU -- Airoha EN7523 (reported as `EN7529CT`), AArch32,
128 MiB SPI-NAND (Winbond W25N01K; block size 128 KiB, page size 2048, OOB 96).

**Status:** `sysupgrade` writes slot B, reboots by itself and comes back on the new image with the
overlay -- and therefore the network, wireless and firewall configuration -- intact. Sections 1-5, 7
and 8 are **proven on hardware**; section 6 is deliberately **not** enabled. This is the detail behind
the "Reboot keeps config" row of [status.md](status.md); the boot chain is in [booting.md](booting.md),
image contents in [building.md](building.md).

---

## 1. Where the image goes

The board has two vendor slots. Slot A (`tclinux`) keeps the stock image; OpenWrt is installed into
slot B, `tclinux_slave`, which the vendor dual-image logic selects with the `bootflag` byte
([booting.md](booting.md) section 1.3). The board device tree
([`en7523-vgp42x6v1.dts`](../openwrt/overlay/target/linux/airoha/dts/en7523-vgp42x6v1.dts)) declares
seven fixed partitions; `/proc/mtd` on a running OpenWrt reports ten, because `mtdsplit_fit` derives
three more from slot B at boot:

| mtd | label | flash offset | size | note |
|---|---|---|---|---|
| 0 | `bootloader` | `0x0000000` | `0x80000` | read-only; U-Boot environment in its tail (`0x7C000`) |
| 1 | `romfile` | `0x0080000` | `0x40000` | read-only |
| 2 | `tclinux` | `0x00C0000` | `0x2800000` (40 MiB) | slot A, stock firmware -- never write |
| **3** | **`tclinux_slave`** | **`0x28C0000`** | **`0x2800000`** (40 MiB) | **slot B -- the only flash target**, declared `denx,fit` |
| 4 | `kernel` `*` | `0x0` in slot B | `0x3A0000` (3,801,088 B) | derived: the FIT region, rounded up to the erase-block size |
| 5 | `rootfs` `*` | `0x3A0000` in slot B | `0x2460000` | derived: the squashfs, **mounted as `/`** |
| 6 | `rootfs_data` `*` | after the squashfs | `0x2040000` | derived: a `squashfs-split` child of mtd5; unused here |
| 7 | `data` | `0x50C0000` | `0x1400000` (20 MiB) | UBI volume, holds `/overlay` |
| 8 | `config` | `0x64C0000` | `0x200000` | read-only -- never write |
| 9 | `reservearea` | `0x66C0000` | `0x240000` | read-only -- never write |

`*` mtd4-mtd6 exist only after the split, and their offsets are relative to slot B. The kernel states
the result itself, so this is measured rather than inferred:

```text
N fit-fw partitions found on MTD device tclinux_slave
mtd: setting mtd5 (rootfs) as root device
VFS: Mounted root (squashfs filesystem) readonly on device 31:5.
```

`root=/dev/mtdblock5` follows from that table. After the last partition comes a raw region,
`0x6900000`-`0x8000000` (23 MiB), which is **not** an MTD partition at all -- section 5.

Two things make an install persistent, and neither is `rootfs_data`. The squashfs is mounted read-only
out of slot B, and `/overlay` is a **UBIFS volume on the `data` partition (mtd7)**, outside slot B,
which the kernel auto-attaches (`UBI: auto-attach mtd7`) before `mount_root` switches to it. So an
upgrade loses nothing: `sysupgrade` overwrites mtd3, while mtd7 -- holding `/etc/config` and the
dropbear host keys -- is untouched. The overlay is deliberately not on `rootfs_data` (mtd6), which
lives *inside* slot B and is discarded on every upgrade.

## 2. `platform.sh`: what `sysupgrade` needs

`sysupgrade` sources `/lib/upgrade/platform.sh` and calls `platform_do_upgrade()`. The stock `airoha`
target ships **no** `base-files/lib/upgrade/platform.sh`, so an unmodified build has nothing to call.
This repository adds one --
[`openwrt/overlay/target/linux/airoha/base-files/lib/upgrade/platform.sh`](../openwrt/overlay/target/linux/airoha/base-files/lib/upgrade/platform.sh)
-- copied verbatim into the tree by [`scripts/apply-overlay.sh`](../scripts/apply-overlay.sh), so it
lands as `target/linux/airoha/base-files/lib/upgrade/platform.sh` and is installed into the image
rootfs (verified with `unsquashfs`, which finds `/lib/upgrade/platform.sh` in the built image).
Abbreviated to the essential part:

```sh
platform_do_upgrade() {
	case "$(board_name)" in
	econet,vgp-42x6v1) PART_NAME="tclinux_slave" ;;
	*) return 1 ;;
	esac
	default_do_upgrade "$1"
}
```

`platform_check_image()` accepts the same board string, and the shipped script also implements the
`-n` clean-install path (section 7). **Why that is enough:** the `mtd` tool works on **whole
partitions** -- `mtd erase <part>` erases all of it, `mtd write <file>|- <part>` writes from offset 0,
there is no offset or length argument, and the derived partitions must never be targeted.
`default_do_upgrade()` therefore only needs a partition name: it runs `get_image | mtd write - <part>`
and reboots, printing `Writing from <stdin> to tclinux_slave ...  [ ][e][w][e][w][e][w]`.

Measured on hardware with a hand-written payload: `mtd erase` of the whole 40 MiB partition takes
1.02 s (both ends then read back `0xff`), `mtd write` of a 7,733,248-byte payload takes 2.90 s and
reads back byte-identical, and `mtd verify` on the same pair reports `Success`. End to end,
`sysupgrade <image>` has been run on this board: it erased and wrote slot B, rebooted by itself and
came back on the image it had just written, with the overlay unchanged.

## 3. Why `/dev/mtd*` did not exist

Symptom: `/proc/mtd` lists the partitions (`mtd0: 00080000 00020000 "bootloader"`) but there are no
device nodes -- `ls /dev/mtd*` says *No such file or directory*. The older explanation, "the stock
`en7523` config sets neither `MTD_BLOCK` nor `MTD_CHAR`", is wrong on both counts.

**(a) `CONFIG_MTD_CHAR` does not exist in kernel 6.18.** There is no `config MTD_CHAR` in
`drivers/mtd/Kconfig`, and `mtdchar.o` is linked straight into `mtd-y`
(`drivers/mtd/Makefile:8: mtd-y := mtdcore.o mtdsuper.o mtdconcat.o mtdpart.o mtdchar.o`). The char
nodes `/dev/mtdN` are always built when `CONFIG_MTD=y`; the `CONFIG_MTD_CHAR=y` line in
[`0003-target-airoha-en7523-enable-board-kernel-options.patch`](../openwrt/patches/0003-target-airoha-en7523-enable-board-kernel-options.patch)
is a **dead symbol** that kconfig drops.

**(b) The real cause is that OpenWrt does not use devtmpfs.** OpenWrt creates nodes from **uevents**
handled by `procd`, and devtmpfs is off by design (`target/linux/generic/config-6.18` has
`# CONFIG_DEVTMPFS is not set`; OpenWrt's switch is `CONFIG_KERNEL_DEVTMPFS`, default `n`). MTD
registers its devices during **kernel init, before procd exists**, so that uevent is lost and nobody
creates the nodes; the `mtd` tool does not `mknod` either, it just opens `/dev/mtdN`
(`package/system/mtd/src/mtd.c`). Hence `CONFIG_MTD_BLOCK=y` alone changes nothing: the block device
exists inside the kernel, but with no `/dev/mtdblockN` node every `mtd` and `dd` call still fails with
*No such file or directory*.

The working combination is two independent pieces, in two different files: the target kernel config
(`target/linux/airoha/en7523/config-6.18`) needs `CONFIG_MTD_BLOCK=y`, which provides
`/dev/mtdblockN`; the OpenWrt `.config` -- **not** the target config -- needs
`CONFIG_KERNEL_DEVTMPFS=y` plus `CONFIG_KERNEL_DEVTMPFS_MOUNT=y`, which make the kernel populate
`/dev` itself, so that **both** `/dev/mtdN` and `/dev/mtdblockN` appear. The patch above already adds
`CONFIG_MTD_BLOCK=y`; the devtmpfs half is an OpenWrt symbol, so it belongs in `.config` (seeded by
[`scripts/build-firmware.sh`](../scripts/build-firmware.sh) or set in `menuconfig`) and without it the
`MTD_BLOCK` half is inert. With both, the nodes appear with no `mknod` and no `mtd*.ko`.

## 4. Writing to NAND: the two traps

**Trap 1 -- writing without erasing.** NAND can only clear bits (`1 -> 0`). Writing over a page that
was not erased stores the bitwise **AND of the old and the new content** and corrupts the ECC, while
`dd` still reports success -- measured: `64+0 records out`, and the read-back is completely wrong. So
never `dd` a firmware image into `/dev/mtdN`; use `mtd write` (it erases first) or `sysupgrade`.

**Trap 2 -- addressing the wrong partition.** The numbering is not `mtdN -> minor N`:

```c
/* drivers/mtd/mtdcore.c */
#define MTD_DEVT(index) MKDEV(MTD_CHAR_MAJOR, (index)*2)
/* drivers/mtd/mtdchar.c */
int devnum = minor >> 1;                           /* read-only node == minor & 1 */
```

So `/dev/mtdN` is the char device `90:(N*2)`, `/dev/mtdNro` is `90:(N*2+1)` with writes refused, and
`/dev/mtdblockN` is the block device `31:N`. This really happened during bring-up: a node was created
as `mknod /dev/mtd3 c 90 3`. Minor 3 means `devnum = 3 >> 1 = 1`, so that node was in fact **mtd1
(`romfile`) in read-only mode**. It opens without error, which is what makes the mistake dangerous:
every `dd if=/dev/mtd3` in that session read the wrong partition (and returned nothing, because `skip`
exceeded romfile's 256 KiB), so **every conclusion drawn from that node was invalid**. The correct node
is `mknod /dev/mtd3 c 90 6`.

## 5. What must never be written

| Region | Extent | Why |
|---|---|---|
| `bootloader` (mtd0) | `0x0000000`-`0x0080000` | stage 1 lives in the first 128 KiB and NAND erases in 128 KiB blocks, so one bad write costs the whole first block; the U-Boot env at `0x7C000` needs a correct CRC32 |
| `tclinux` (mtd2, slot A) | `0x00C0000`-`0x28C0000` | the stock firmware and the only bootable copy of it: if the new image fails, the vendor dual-image logic flips `bootflag` back and boots slot A |
| `data` (mtd7) | `0x50C0000`-`0x64C0000` | holds the live UBI `/overlay`; write it through UBI, never with `mtd write` or `dd` |
| `config` (mtd8) | `0x64C0000`-`0x66C0000` | read-only in the device tree |
| `reservearea` (mtd9) | `0x66C0000`-`0x6900000` | read-only; reads back as `0xff` |
| raw region (no mtd) | `0x6900000`-`0x8000000` | vendor area: the `factory` block at `0x6F00000` (GPON identity and laser BOB calibration, magic `0x12344321`), the `bootflag` byte at `0x6FC0000`, `RAWB` at `0x75E0000`, `BMT` at `0x7FE0000` |

The only sanctioned write target is slot B, `0x28C0000`-`0x50C0000`, and in practice only through
`sysupgrade` or `mtd write` on `tclinux_slave`.

## 6. Bad blocks and the vendor BMT

The vendor bad-block table on this unit, read from a full-chip dump:

```text
0x7FE0000  42 4d 54 01 ff 00 01 ff ff ff ff ff ff ff ff ff
           |BMT|  |  |  |
           sig   ver=1  size=0
```

So `signature` = `"BMT"`, **`version` = 1**, `bad_count` = `0xff`, **`size` = 0 entries**, then a
20-byte header with a checksum and `u16 from/to` pairs. The second copy at `0x7FE2000` is empty, and
`RAWB` (`0x75E0000`) is empty too, so **the table is empty -- this unit has no remapped bad blocks**.
While that holds, logical addresses equal physical ones, which is why writing slot B through the raw
partitions works with no BMT driver. The OpenWrt side, and its trap:

* `CONFIG_MTD_NAND_MTK_BMT` exists but is **inert**: `mtk_bmt_attach()` claims a device only if the
  DTS node carries `mediatek,bmt-v2`, `mediatek,nmbm` or `mediatek,bbt`, and none is declared here;
* the `airoha` target patches in `drivers/mtd/nand/airoha_bmt.c` and an `airoha_bmt_ops`, but the file
  is **not in `drivers/mtd/nand/Makefile`** and nothing references the ops struct: dead code that is
  never compiled;
* **do not add `mediatek,bmt-v2` to the device tree.** `mtk_bmt_v2` requires **version 2**, with a
  different header (4 bytes, entries starting at `+4`) and a `"bmt"` marker in the OOB. Reading the
  vendor's v1 table with the v2 struct yields garbage (`bb_tbl[0] = 0x00ff`, ...); the driver logs
  `BMT Version not match,upgrage preloader and uboot please!` and then **rebuilds the table**, making
  the kernel the owner of the bad-block map. Do not do that without a full 128 MiB chip backup and a
  proven need.

If a board ever does need kernel-managed BMT, the work is: wire `airoha_bmt` into the Makefile and the
dispatch, keep any `mediatek,bmt-remap-range` away from the raw region `0x6900000`-`0x8000000`, and
check from the log that the driver *reads* the existing table instead of rewriting it. **None of that
has been tried** -- see section 9.

## 7. Upgrading without losing state, and verifying the flash

Copy the image to the board and let `sysupgrade` do the work. Do **not** pass `-n`:

```sh
# on the board; /tmp is tmpfs and is wiped by the reboot
sha256sum /tmp/image.bin                 # must equal the host-side hash
sysupgrade -T /tmp/image.bin             # validate only: no write, no reboot
sysupgrade    /tmp/image.bin             # keep the configuration (no -n)
```

`-n` is avoided because it throws away the configuration the board is meant to keep. It is *not* what
decides whether you can log in again, and it is worth being precise about that, because an earlier
revision of this file claimed the overlay holds "the SSH key": **there is no
`/etc/dropbear/authorized_keys` on this board at all** (only the three host keys), and the shipped
image has an **empty root password** (`root:::` in `/etc/shadow`), so dropbear on the LAN accepts the
SSH `none` method without a key or a password -- verified with `ssh -v`, which ends in
`Authenticated to 192.168.1.1 ... using "none"`. Access therefore does not depend on the overlay; the
ways back into a board whose new image does not come up are slot A's untouched vendor image and the
UART console. Here `-n` does *not*
mean "the overlay is erased": `/overlay` is a UBIFS volume on its own partition (mtd7), so the image
write never touches it. What `-n` changes is the configuration the *installed* system starts from, and
the shipped `platform.sh` handles it explicitly -- it detects a clean install through `UPGRADE_BACKUP`
being empty (`SAVE_CONFIG` is not exported into stage 2) and in `platform_pre_upgrade()` deletes the
overlay's `/etc/config` and `/etc/board.json` so that `board_detect` and `board.d/02_network` run
again on the next boot, while leaving `/etc/dropbear` alone. A stale `/etc/board.json` otherwise
survives forever (`/bin/config_generate` only runs `board_detect` when the file is missing) and the
board keeps its old network configuration, as observed once on hardware.

Verify **after** the flash, from the running system:

```sh
cat /proc/mtd                          # 10 entries; mtd3 tclinux_slave, mtd5 rootfs
head -c 4 /dev/mtd3 | hexdump -C       # d0 0d fe ed  = bare FIT at offset 0 of slot B
head -c 4 /dev/mtd2 | hexdump -C       # 48 44 52 32  = "HDR2", slot A untouched
cat /proc/cmdline                      # root=/dev/mtdblock5 rootfstype=squashfs
ls /rom/lib/upgrade/platform.sh        # /rom is the squashfs of the image that is running
ls -l /etc/config/network              # created only in the overlay -> the overlay survived
```

`sysupgrade -T` is worth one caveat: it exits 0 whether or not it likes the image, so read its
*messages*, not its status. A missing or foreign image prints `Image metadata not present`, while a
valid one prints nothing at all.

The board is still reachable at its usual LAN address (`192.168.1.1` unless it was changed), and with
the same credentials, because the shipped image has an empty root password -- nothing about access
lives in the overlay. `/rom` is the read-only squashfs of the *running* image, so anything only the new
image ships proves the flash took effect; `/lib/upgrade/platform.sh` is a convenient one, because an
image built before section 2 does not have it.

**Do not verify with a raw hash comparison -- the obvious check is wrong on this board:**

```sh
head -c 9437473 /dev/mtd3 | sha256sum     # NEVER equals the image's sha256
sha256sum /dev/mtd3                       # 40 MiB partition; different for other reasons too
```

`sysupgrade` does not write the file byte for byte: it hands the upgrade to procd
(`ubus call system sysupgrade { "save_partitions": 1, "add_provisioning": 1 }`), and `mtd write`
writes the content that stream carries, not the file's own trailer. Comparing the 9,437,473-byte image
against mtd3 byte for byte showed **0 differing bytes in the FIT region `0x0`-`0x3A0000`** but
**10,546 differing bytes from `0x8E0000` on**, where the partition still holds part of the *previous*
image; a partition-wide hash can never match, and neither can a truncated one. Verify instead with (1)
`sysupgrade -T` before flashing, (2) the first 512 bytes of mtd3 and of mtd5 (which must match the
image at `0x3A0000`), and (3) the running system, as above.

## 8. Verify a build before flashing it

For this board's layout a sysupgrade image must satisfy:

| Property | Value | Why |
|---|---|---|
| FIT magic at offset 0 | `d0 0d fe ed` | the bootloader and `mtdsplit_fit` expect a FIT header at the start of slot B |
| squashfs superblock | `hsqs` at **`0x3A0000`** (3,801,088) for this package set | that offset *is* the size of the derived `kernel` partition (mtd4), so it moves with the FIT, not with the package set -- see the explanation below for what a much larger value means |
| image size | 9,437,473 bytes (`0x900001`) for the current package set | kernel + squashfs + trailer; another package set changes it, the offset above does not |
| FIT `load` / `entry` | `0x80208000` | anything else deadloops in `head.S` with a silent UART -- check with [`tools/verify_build.py`](../tools/verify_build.py) |
| whole-image size | must stay under slot B, `0x2800000` (41,943,040 bytes) | **nothing enforces this at build time yet**: the device definition sets no `IMAGE_SIZE`, so an oversized image is truncated at flash time rather than refused at build time. Current images are 9,437,473 bytes, well inside; adding `IMAGE_SIZE := 0x2800000` to the device profile in `openwrt/patches/0002-*.patch` is the fix, and it needs one build to confirm before it can be trusted `[not verified]` |

`0x3A0000` comes from `mtdsplit_fit` (`target/linux/generic/files/drivers/mtd/mtdsplit/mtdsplit_fit.c`
at the pinned revision): it reads the FIT's `totalsize` and rounds it **up to the erase-block size**
(128 KiB, `0x20000`) to size the `kernel` partition, then finds the `rootfs` partition by scanning for
a filesystem magic *after* the FIT. One measured image had `totalsize = 0x3831C4`, which rounds up to
`0x3A0000`, so `hsqs` sits exactly there -- the offset is a property of the kernel, and a different
package set does not move it (that changes the image size, not the kernel).

**What a grown FIT does *not* break.** The `kernel` partition is computed from the image, not declared
anywhere, so a bigger FIT does not push the rootfs into the kernel's space: the kernel partition simply
grows, the scan still finds the squashfs after it, and the split still mounts. Do not repeat the stricter
claim that a large offset alone makes the rootfs unmountable -- that was wrong, and the source above is
what settles it.

**What it does mean.** An offset far above 3.6 MiB says the FIT itself grew, and the usual cause is a
kernel with an initramfs embedded in it:

* a build with `CONFIG_TARGET_ROOTFS_INITRAMFS=y` plus `CONFIG_TARGET_INITRAMFS_COMPRESSION_NONE=y`
  embedded an uncompressed initramfs into the kernel `Image` and produced **14,418,209 bytes** with
  `hsqs` at **`0x880000`** (kernel 8.80 MB instead of 3.76 MB -- same lzma, same DTB);
* the same mistake was caught earlier in a **12,058,913-byte** image with `hsqs` at **`0x760000`**, where
  `arch/arm/boot/Image` and `Image-initramfs` had the *same* md5 and the same size -- that equality is
  the fingerprint of this bug, and the build log's kernel-1 `Data Size` (7,678,098 instead of ~3,757,000)
  shows it too.

Such an image must not be flashed, but for the right reason: it is not the persistent image. It is nearly
twice the necessary size, and the kernel it carries boots its own embedded rootfs instead of the flash
rootfs, so nothing would persist across a reboot `[not verified]` -- it was never flashed here; what *was*
measured is the size, the offset and the identical kernel md5s.

Clearing `CONFIG_TARGET_ROOTFS_INITRAMFS` brought the image back to 9,437,473 bytes with `hsqs` at
`0x3A0000`. Note that [`scripts/build-firmware.sh`](../scripts/build-firmware.sh) *adds* that symbol for
`--initramfs` (the default) and never removes it, so a stale `=y` survives a later `--no-initramfs`. The
script now checks every sysupgrade image it produced and prints the offset it found: it validates the
**squashfs superblock** at each `hsqs` it sees and not just the magic, because the kernel `Image` here is
uncompressed and a stray `hsqs` inside it would otherwise mask an inflated kernel.

```sh
python3 tools/verify_build.py <image>    # FIT load/entry against the kernel's _text link
grep -abo hsqs image.bin | head -1       # GNU grep; 3801088 (= 0x3A0000) for a clean build
```

## 9. Proven, and not proven

Proven on hardware (Econet vGP-42X6V1, kernel 6.18.54):

* `/proc/mtd` has 10 entries after the FIT split, `tclinux_slave` is still mtd3, `rootfs` is mtd5, and
  the kernel mounts `device 31:5` as `/`;
* `mtd erase` / `mtd write` / `mtd verify` on the whole `tclinux_slave` partition: 1.02 s erase, 2.90 s
  for a 7,733,248-byte payload, byte-identical read-back, `Success`;
* `sysupgrade` end to end: writes slot B through `platform_do_upgrade`
  (`PART_NAME="tclinux_slave"`), reboots by itself, boots the new image, overlay survives;
* `/dev/mtd*` and `/dev/mtdblockN` appear automatically once devtmpfs is enabled -- no `mknod`, no
  `mtd*.ko`;
* the vendor BMT on this unit is version 1 with `size = 0` -- empty, no remapped blocks.

Not proven, or deliberately not attempted:

* any BMT-owning arrangement: `mediatek,bmt-v2` was **not** added and `airoha_bmt.c` was **not** wired
  into the Makefile, so nothing here validates long-term behaviour once a real bad block appears;
* the `-n` clean-install path of the shipped `platform.sh`: implemented and documented, but the
  recorded end-to-end upgrade runs used the keep-config path;
* writing `config`, `reservearea` or slot A -- the only evidence is that all three are still intact
  after several upgrades;
* the exact trailer bytes a given procd version writes: the numbers in section 7 are one measurement,
  not a specification.

Open work with acceptance criteria is in [roadmap.md](roadmap.md). The boot chain, the U-Boot side and
the partition numbering of the **vendor** firmware (11 entries, where `tclinux_slave` is mtd7 -- do
not mix the two schemes) are in [booting.md](booting.md) section 8.
