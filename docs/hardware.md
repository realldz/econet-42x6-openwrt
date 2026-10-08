# Hardware reference -- Econet vG vGP-42X6V1 (Airoha EN7523) GPON ONU

Reference for the board support in this repository. Values are taken from the engineering notes
under `docs/econet/` in the analysis workspace (per-unit inventory, feasibility study, U-Boot console
notes, PON gap analysis, live captures over SSH) and cross-checked against the board device tree
`openwrt/overlay/target/linux/airoha/dts/en7523-vgp42x6v1.dts`. Where a value was measured on the
running unit it is marked "(live)".

The unit serial, the unit MAC address and the PLOAM registration password are intentionally not
reproduced in this public document. The serial appears below as `<SERIAL>`.

## 1. Device identification

| Property | Value |
|---|---|
| Vendor | ECONET Technologies Corp. (Airoha / MediaTek) |
| Hardware vendor (OEM) | HS |
| Model | vG vGP-42X6V1 |
| Model strings from the factory block | `ONT.vGP-42X6V1` (model), `vGP-42X6V1` (EquipmentId), `VGP42X6M001` (Version), `MGP6.1.0` (vendor firmware/board version) |
| Product | xPON ONU -- a GPON optical network unit (the build also carries EPON dual-image support) |
| SoC | Airoha/Econet `EN7523`; the U-Boot banner prints `EN7529CT` for the same part |
| CPU | 2x Arm Cortex-A53, running in AArch32 (armv7l / ARMv7) |
| DRAM | 512 MB, physical base `0x80000000` |
| Board name (U-Boot env) | `en7523_evb` |
| GPON identity | VendorId `VTGR`; unit serial `<SERIAL>` (redacted); PLOAM registration password field is empty (registration is by serial) |
| MAC address | Unit `ethaddr` is redacted; use `02:00:00:00:00:00` as a placeholder |
| Flash | SPI-NAND 128 MB (1 Gbit) with a vendor bad-block table (BMT) |
| Wi-Fi | Single MediaTek MT7916 card on PCIe (see section 5) |
| Ethernet | 4x GbE switch integrated inside the EN7523 (see section 7) |
| VoIP | Not populated on this unit (`TCSUPPORT_VOIP` is commented out in the vendor build config) |
| Front-panel LEDs | Blue power = GPIO27, green pon = GPIO10, red los/alm = GPIO6, blue inet/int = GPIO1 -- all measured, see section 9 |
| Buttons | Reset = GPIO0 (`KEY_RESTART`), WPS = GPIO7 (`KEY_WPS_BUTTON`, polled) -- see section 9 |

Evidence for the CPU mode: vendor build config has `TCSUPPORT_CPU_EN7523=y`,
`TCSUPPORT_CPU_ARMV8=y` and `# TCSUPPORT_CPU_ARMV8_64 is not set`; the U-Boot env reports
`cpu=armv7`, `arch=arm`; the kernel boot log reports `smp: Brought up 1 node, 2 CPUs`.

## 2. Memory map and reserved regions

| Region | Address / size | Notes |
|---|---|---|
| DRAM | `0x80000000`, 512 MB (`0x20000000`) | Device tree `memory@80000000`. The stock vendor device tree claims 1 GiB (`0x40000000`) -- that value is wrong, do not copy it |
| ATF / TCBoot reservation | `0x80000000..0x80200000`, 2 MiB | Encoded as `/memreserve/ 0x80000000 0x200000` in the board DTS. Boot-log evidence places ATF at the bottom of DRAM (measured `0x80000000..0x80040000`), and TCBoot/U-Boot relocates itself higher in RAM (`U-Boot at: 0x9ee03000`) |
| Usable memory range | `0x80200000`, `0x1fe00000` (510 MiB) | Device tree `linux,usable-memory-range` |
| Measured RAM | `MemTotal 480136 kB` (live) | U-Boot reports `DRAM: 496 MiB`; the M1 boot log reports `Memory: 452416K/522240K available`. The difference from 512 MB is held by ATF and NPU/other carve-outs |
| QDMA DMA buffers | `0x87000000` + 32 MiB (`qdma0-buf`), `0x89000000` + 16 MiB (`qdma1-buf`) | Added by the board device tree with `no-map`; the frame engine's ring buffers (section 7). `en7523.dtsi` already reserves five NPU regions starting at `0x84000000`, so the board DTS extends that node rather than declaring a second `reserved-memory` node |

The two DMA windows are the only further carve-outs established since; they belong to the Ethernet
block described in section 7.

**Consequence for the OpenWrt `_text`:** the ARM32 kernel of the `airoha` target must be linked so
that its physical `_text` lands inside the usable range and is 2 MiB aligned -- with
`TEXT_OFFSET = 0x00208000` this gives `_text` link `0xC0208000` and physical `0x80208000`, and the
FIT `load`/`entry` addresses must match that value. If the load address is wrong the kernel dead
loops in `head.S` before `parse_early_param()`, the UART stays completely silent and the watchdog
resets the board after roughly 350 s. The full boot chain, the A/B slot selection and the recovery
paths are in [booting.md](booting.md); they are not repeated here.

## 3. SPI-NAND

| Property | Value |
|---|---|
| Chip model | Winbond `W25N01K` (ASCII name reported by the bootloader; manufacturer ID `0xEF`, device ID `0xAE 0x21`) |
| Total size | `0x8000000` = 128 MiB = 1 Gbit = 134,217,728 bytes |
| Page size (main area) | 2048 bytes |
| OOB / spare size | 96 bytes |
| Erase block size | 128 KiB |
| Bad-block table | Marker `BMT` at `0x7FE0000`, at the end of the chip; the notes describe the table as occupying the last two erase blocks |
| Vendor boot messages | `Detected SPI NAND Flash : _SPI_NAND_DEVICE_ID_W25N01K, Flash Size=0x8000000`, `bmt pool size: 81`, `BMT & BBT Init Success` |
| Linux boot message | `spi-nand spi0.0: Winbond SPI NAND was found.` -- `128 MiB, block size: 128 KiB, page size: 2048, OOB size: 96` |

Early dump-only analysis guessed a GigaDevice `GD5F1GM7UE` because the bootloader's chip-ID table
lists several compatible parts; the on-hardware U-Boot probe and the Linux SPI-NAND driver both
identify `W25N01K`, which is the settled answer.

**"Using Flash ECC" note.** The NAND is used with on-die/flash ECC and a spare area of 96 bytes per
page. A raw programmer (CH341A) writes only the main pages and leaves the existing ECC/spare bytes
untouched, so a modified image written with a programmer fails ECC on the altered pages and the
board does not boot (the stock image written the same way boots fine). Flash modifications must
therefore be made from a running operating system through its MTD/BMT layer, or with an image whose
ECC bytes are regenerated.

## 4. Flash / partition map

The 11 rows marked `mtd0`..`mtd10` are exactly what the stock vendor kernel reports in
`/proc/mtd` (live). The OpenWrt board DTS declares only the 7 top-level partitions
(`bootloader`, `romfile`, `tclinux`, `tclinux_slave`, `data`, `config`, `reservearea`) and
deliberately leaves the trailing raw region undeclared.

| Offset | Size | Linux mtd | Label | Notes |
|---|---|---|---|---|
| `0x0000000` | `0x80000` (512 KiB) | mtd0 | `bootloader` | Read-only. TCBoot stage-1 (flat ARM code in `0x00000..0x1FFFF`), LZMA-compressed U-Boot 2014.04-rc1 (unpacks from `0x24800` to 265,072 B, link base `0x81E00000`), and the 16 KiB U-Boot env block at `0x7C000` (CRC32 at +0, env data at +4, hex SHA-256 password at +0x1CC). **NEVER WRITE** -- corrupting it produces a board with no LED activity |
| `0x0080000` | `0x40000` (256 KiB) | mtd1 | `romfile` | Read-only. Live gzip `ctromfile.cfg` (72,704 bytes uncompressed): the vendor configuration store. **NEVER WRITE** |
| `0x00C0000` | `0x286C76` (2,649,462 B) | mtd2 | `kernel` | Sub-partition inside `tclinux` (slot A, the currently booted kernel image). Part of slot A -- **NEVER WRITE** |
| `0x034EC76` | `0x1620000` (22 MiB) | mtd3 | `rootfs` | Sub-partition inside `tclinux`; Squashfs mounted as `root=/dev/mtdblock3`. **NEVER WRITE** |
| `0x00C0000` | `0x2800000` (40 MiB) | mtd4 | `tclinux` | Read-only. Parent partition of mtd2 + mtd3 (slot A, stock firmware). **NEVER WRITE** |
| inside `tclinux_slave` | `0x286C76` | mtd5 | `kernel_slave` | Slot B kernel sub-partition |
| inside `tclinux_slave` | `0x1620000` | mtd6 | `rootfs_slave` | Slot B rootfs sub-partition |
| `0x28C0000` | `0x2800000` (40 MiB) | mtd7 | `tclinux_slave` | Slot B. **Writable** -- this is the slot the OpenWrt image is written to |
| `0x50C0000` | `0x1400000` (20 MiB) | mtd8 | `data` | JFFS2. Writable in the board DTS and intended as the OpenWrt overlay, but on the stock firmware it holds live system data (mounted `/data`) -- do not write it while stock is running |
| `0x64C0000` | `0x200000` (2 MiB) | mtd9 | `config` | Read-only. JFFS2; on stock it is mounted for `/usr/config/WLan/MAP`. **NEVER WRITE** |
| `0x66C0000` | `0x240000` (2.25 MiB) | mtd10 | `reservearea` | Read-only. Reads back as all `0xFF` (empty). **NEVER WRITE** |
| `0x6900000` | `0x1700000` (23 MiB) | -- (no mtd) | raw vendor tail | Belongs to no mtd partition; the vendor firmware reaches it directly through the driver/BMT. Contains everything in the rows below. **NEVER WRITE ANY OF IT** |
| `0x6E40000` | approx. 11.8 KiB (gzip) | -- | romfile copy | Second copy of the gzip `romfile`; decompresses byte-identically to mtd1. It is not a recovery OS. **NEVER WRITE** |
| `0x6F00000` | factory block | -- | factory / per-unit data | Magic `0x12344321` at +0x004. Holds the GPON identity (model, equipment ID, GPON serial) and the BOB laser calibration blob at +0x497. See section 8. **NEVER WRITE** |
| `0x6FC0000` | 1 byte | -- | boot-flag byte | Read as ASCII `1`. Unresolved: the U-Boot notes describe this byte as the A/B boot flag (0 = slot A, 1 = slot B) and report U-Boot toggling it after a failed boot, but the live kernel command line reports `bootflag=0` while this byte reads `1`, so the encoding is not fully reconciled. U-Boot exposes `bootflag read` and `bootflag swap`. **NEVER WRITE** |
| `0x75E0000` | marker | -- | `RAWB` | Raw-block magic marker. Purpose not established beyond the marker. **NEVER WRITE** |
| `0x7FE0000` | to end of chip (`0x20000`, 128 KiB) | -- | `BMT` | Vendor bad-block table marker at the end of the chip; the notes describe the table as the last two erase blocks. Vendor code accesses it through the BMT driver. **NEVER WRITE** |

Arithmetic note on the slot A sub-partitions: the live capture reports `kernel` at `0x00C0000`
with size `0x286C76` and `rootfs` at `0x034EC76`, which implies an `0x8000` gap between the two
(`0x00C0000 + 0x286C76 = 0x346C76`). The offset/size pairs are reproduced verbatim from the live
`/proc/mtd` capture; the gap is presumably padding or a transcription artifact in the source note.

### The vendor / factory region

The trailing raw region is not an mtd partition and is never written (section 10). It is the vendor's
own storage, and it is where this unit's per-unit data lives:

| Offset | Contents |
|---|---|
| `0x6E40000` | second copy of the gzip `romfile`, byte-identical to mtd1 when decompressed |
| `0x6F00000` | factory block, magic `0x12344321` at +0x004: model string at +0x21C, GPON serial at +0x2BC, laser BOB calibration at +0x497 |
| `0x6FC0000` | one byte, ASCII `1` (A/B boot-flag candidate, not fully reconciled) |
| `0x75E0000` | `RAWB` marker |
| `0x7FE0000` | `BMT`, the vendor bad-block table |

What that data is:

* **GPON identity** -- model, equipment ID and the ONU serial, plus the PLOAM registration password
  field (empty on this unit, which registers by serial);
* **laser calibration** -- the BOB blob for the EN7571 laser driver, which the vendor reads with
  `mtd bob get` (section 8). Treat that command as a write: it unlocks the raw area first;
* **the base MAC address** -- not in the EFuse (blank) and not in the factory block: it is in the
  vendor configuration that sits gzipped inside the `romfile` partition (mtd1), from which the stock
  firmware materialises `/etc/mac.conf`. The same value is what U-Boot reports as `ethaddr`.

OpenWrt does **not** read any of it yet: the board device tree declares no nvmem cell and no
`nvmem-layout`, so Wi-Fi takes its MAC from a patched default blob ([wifi.md](wifi.md) section 4) and
the PON identity is unused. The intended way to consume the region is a read-only `fixed-partition`
covering the factory block plus nvmem cells for the serial, the BOB blob and the base MAC -- laid out
so that the `BMT` at the end of the chip is never touched.

## 5. PCIe

| Item | Value |
|---|---|
| Root complex, port 0 | `14c3:0810` at `0000:00:00.0`, class `0x060400`, header type 01 (bridge), register base `0x1fa91000` |
| Root complex, port 1 | `14c3:0811` at `0001:00:01.0`, class `0x060400`, header type 01 (bridge), register base `0x1fa92000` |
| RC memory windows | port 0: `0x20000000..0x21ffffff` (bus `0000:01`); port 1: `0x22000000..0x23ffffff` (bus `0001:01`) |
| RC Command register | Both root ports read `Command = 0x0140` (Memory Space Enable = 0, Bus Master Enable = 0) and the value is a read-only mirror: writes are swallowed. This is not the Wi-Fi root cause -- see the link below. With the quirk applied they read `0x0146` on a clean boot |
| Wi-Fi card | One MediaTek MT7916 (802.11ax), exposed as two PCIe functions |
| Function 1 -- HIF | `14c3:790a` on pcie0, endpoint `0000:01:00.0`. BAR0 `0x20000000` (measured aperture `0x20000000..0x200fffff`, 1 MiB), BAR2 `0x20100000` (32 KiB), BAR4 `0x20108000` (4 KiB) |
| Function 2 -- WF | `14c3:7906` on pcie1, endpoint `0001:01:00.0`. BAR0 `0x22000000` (measured aperture `0x22000000..0x220fffff`, 1 MiB), BAR2 `0x22100000` (32 KiB), BAR4 `0x22108000` (4 KiB) |
| Endpoint class / MSI | Class `0x028000`; MSI capability `0x018a` with 32 vectors and per-vector masking |
| Link | Link Status `0x1011`: trained as Gen1 x1 (the parts are Gen2 capable) |

Which function is which matters: `14c3:7906` (the WF function, BAR0 `0x22000000`) is the one the
mainline `mt7915e` driver binds and drives, while `14c3:790a` (HIF, BAR0 `0x20000000`) is handled as
the HIF2 companion. Both BAR0 windows map into the same silicon -- a value written through the WF
window is observable through the HIF window and vice versa -- and the MT7916 WFDMA ring tables live
at `BAR0 + 0xd4000` (and the second block at `BAR0 + 0xd8000`). Anyone debugging Wi-Fi must know
which window a register address belongs to, otherwise every read is off by one aperture. The
measured BAR0 aperture is 1 MiB per function; a 16 MB aperture for the WF BAR0 is not established by
the available evidence.

The root cause of the original Wi-Fi failure (root-complex BAR0 size-probe garbage,
`pcieport` failing with `-E22`, and the MT7916 WFDMA never consuming descriptors until a PCI quirk
enables Memory Space plus Bus Master on the root ports) is analysed in
[pcie-root-cause.md](pcie-root-cause.md).

## 6. UART

| Item | Value |
|---|---|
| Console | `ttyS0`, 8250/16550-compatible |
| Physical base address | `0x1fbf0000` (`1fbf0000.serial: ttyS0 at MMIO 0x1fbf0000 (irq = 32, base_baud = 115200) is a 16550`) |
| Interrupt | Linux IRQ 32; the live `/proc/interrupts` capture shows `ttyS0` on GICv3 SPI 50 |
| Line settings | `115200n8` (115200 baud, 8 data bits, no parity, 1 stop bit) |
| Kernel console | `console=ttyS0,115200n8 earlycon`; device tree `stdout-path = "serial0:115200n8"` |
| U-Boot baud rate | `baudrate=115200` in the U-Boot env |
| Adapter used on the bench | CH341A USB-to-serial, enumerated as COM23 |
| Header / pins | Not established by the available evidence beyond "a 3-pin UART (TX/RX/GND) has to be soldered"; no connector reference designator or pin order is documented |

The console carries two different shells: the U-Boot prompt (username compared for 16 bytes plus a
SHA-256 password check against the env variable) appears before `Starting kernel`, and after the
kernel boots the same port becomes a Linux getty (`getty -L ttyS0 115200 vt100`, `askfirst`), so
nothing is printed until a key is pressed. Flash access and the U-Boot recovery paths are covered in
[booting.md](booting.md).

## 7. Ethernet / switch

| Item | Value |
|---|---|
| Ports | 4x Gigabit Ethernet |
| Switch | Integrated in the EN7523 -- no external switch chip (`# TCSUPPORT_MT7530_EXTERNAL is not set` in the vendor build config); the vendor stack is switch-IP comparable to MT7530 (`libmtkswitch.so` in user space, `qdma_lan.ko` / `qdma_wan.ko` in the kernel) |
| Hardware block name | `frame_engine@1fb50000` -- the FE/GDM/QDMA family, the same family as the upstream `airoha_eth` driver but a different generation |
| Frame engine (FE) node | `ethernet@1fb50000` (`airoha,en7523-eth`): `fe` `0x1fb50000`+`0x2600`, `qdma0` `0x1fb54000`+`0x2000`, `qdma1` `0x1fb56000`+`0x2000`, `gdmp` `0x1fbf9000`+`0x1000`; ten GIC SPIs (`37, 55, 56, 57, 38, 58, 59, 60, 49, 64`); resets `FE`, `FE_PDMA`, `FE_QDMA`, `DUAL_HSI0_MAC`, `DUAL_HSI1_MAC`, `HSI_MAC`, `GDMP` |
| GDM ports | Three internal MACs. **GDM1** (`ethernet@1`, child of the FE) is `phy-mode = "internal"` and faces the internal switch -- it is the one that carries the four LAN ports. **GDM2** faces the PON MAC (SGMII / 2500Base-X; needs the PON PCS, not enabled). **GDM3** faces the USB serdes (not enabled) |
| Internal switch (GSW) | `switch@1fb58000` (`0x1fb58000`+`0x8000`), `compatible = "airoha,en7523-switch"`, `GIC_SPI 31`, reset `GSW`; four user ports `lan1`-`lan4` with internal PHYs at MDIO addresses 9-12, plus CPU port 6 wired to GDM1 over a declared 10 Gbit/s fixed link |
| DMA buffers | `qdma0-buf` at `0x87000000` (32 MiB) and `qdma1-buf` at `0x89000000` (16 MiB), `no-map`, used as the frame engine's ring buffers -- see section 2 |
| Port map | The switch exposes 5 ports; physical port 4 is the uplink used as etherWAN (netdev `nas10`), ports 1-3 are LAN (`eth0.1`/`eth0.2`/`eth0.3`). In board terms: LAN1-3 are LAN, LAN4 can be the Ethernet WAN |
| Ethernet WAN | Supported by the vendor firmware (`TCSUPPORT_WAN_ETHER=y`, `serdes_sel=0` in the U-Boot env) |

**Driver status.** Mainline 6.18.54, and the OpenWrt `airoha` target's `patches-6.18`, carry no EN7523
Ethernet support: the target's `airoha_eth` driver matches only `airoha,en7581-eth` and
`airoha,an7583-eth`, and the target device tree `dts/en7523.dtsi` has no ethernet/GDM/switch node at
all -- only `uart1`, `gpio0`/`gpio1`, `pcie0`/`pcie1`, SPI+NAND, SCU and GIC. The board support
therefore adds a ten-patch series (`930-42`..`930-51`) that gives `airoha_eth` the EN7523 SoC data
plus the FE/QDMA/GDMP and GDM nodes, and describes the internal switch -- which the existing MT7530
DSA driver drives in MMIO mode (`CONFIG_NET_DSA_MT7530_MMIO`), with its LED controller enabled for
EN7523 (`930-44`). It also adds the PON PCS and the USB-serdes side of `930-49`..`930-51`, which are
present but not enabled on this board.

With that series the four ports come up. Measured: `br-lan` contained `lan2`, `lan3`, `lan4` and both
AP interfaces, with `lan1` moved out of the bridge to serve as the Ethernet WAN, and a client behind
a cable reached the board and, through the Wi-Fi AP, the air
([wifi.md](wifi.md) section 10). Switch throughput has **not** been benchmarked.

## 8. Optical / PON hardware

| Item | Value |
|---|---|
| PON type | GPON ONU (the same build carries EPON dual-image support) |
| BOSA / laser driver | Airoha/Econet LDDLA `EN7571` |
| Driver identity on this unit | The BOB blob in the factory block carries magic `0x07050701` = profile GPON (`0x07`) + laser variant `0x01`, and variant `0x01` is EN7571 in the public `airoha_lddla.h`. The stock OMCI adapter library also contains the literal string `EN7571` |
| Public driver | `compatible = "airoha,en7571"` in `drivers/net/optical/en7571*`, with `firmware-name` defaulting to `airoha/en7571_bob.bin`, accepting a BOB payload of 161 to 512 bytes |
| BOB calibration location | Factory block at `0x6F00000` + `0x497`, i.e. flash offset `0x6F00497`; the magic `0x07050701` sits at blob + 0x94 (flash `0x6F0052B`) |
| BOB calibration size | 225-byte payload; the remainder of the read window is `0xFF`. The extracted artifact is 400 bytes (`0x6F00497` + 400, `0xFF` padded); a live read with the vendor tool returns 256 bytes, and the first 256 bytes match the offline artifact byte for byte (the digest is not published here: it fingerprints one unit's laser calibration) |
| PON blocks in the vendor device tree | xPON MAC `xpon@1fb64000` (IRQs 42 and 34 reported), PON PHY `pon_phy@1faf0000` (IRQ 43), PON PCS/SGMII `pon_hsgmii@1fa65000` (IRQ 66). The public EN7523 rewrite places the MAC at `0x1fb60000` and the PCS at `0x1fa08000`; the two sets of base addresses are not reconciled in the notes |
| Vendor read tool | `/userfs/bin/mtd bob get <file>` prints `read bob magic code is 0x07050701` and returns 256 bytes. Treat it as a write operation: it prints `Unlocking reservearea ...` and writes an unlock marker into the raw area before reading |

The BOB blob is the per-unit laser bias/APC calibration. Do not copy it from another unit, and do not
overwrite it.

**Settled on hardware, 2026-10-08 -- the laser DDMI is reachable on the SoC's own I2C0.** The two candidate
topologies were:

- The BOSA sits on the PON PHY block's internal I2C master. Supporting evidence: the stock firmware
  exposes no `/dev/i2c-*` device at all, and `/proc/pon_phy/debug` reports
  `phy_i2c_div_clock: 0x60`, with `/proc/pon_phy/DDMI_check_8472` returning plausible values
  (Supply Voltage 32622, Temperature 12214) and Tx bias/Tx power near zero because the laser is off.
- The BOSA sits on the SoC `i2c0` (base `0x1fbf8000`), as documented for the Zyxel PX3321-T1, which
  is the same EN7523 + MT7916 + EN7571 combination and which places the EN7571 at I2C address `0x70`.

The second one is what the hardware does: with an image that enables `i2c0` and the `i2c-mt7621` driver
(`img24`), `i2cdetect -y -r 0` reports a device at **`0x70`** and a single read byte returns `0x10`. The
stock firmware simply does not enable or expose that bus, which is why the first reading looked like the
only option. Consequences: the optical frontend is declared as an `i2c0` child
(`compatible = "airoha,en7571"`), not as a PHY consumer, and the BOB blob belongs in an `nvmem-cell`.
See [pon-port.md](pon-port.md) section 13. Still unconfirmed: whether a fiber-present PON MAC changes
anything, and the GPIO 16 laser-disable polarity. Live PON state at capture time (stock firmware):
`/proc/xpon/ponInfo` reported `Mode: Error` with the PON MAC not enabled (the unit was running in
etherWAN mode), `/proc/pon_phy/info` reported `PHY Status: unplug`, and LOS = 1.

## 9. GPIO / LEDs / buttons

**Pin controller.** The board no longer uses the legacy `gpio0`/`gpio1` bank nodes: the device tree
deletes both and declares one pin controller in their place.

| Item | Value |
|---|---|
| Node | `system-controller@1fbf0200` (`syscon`, `simple-mfd`), window `0x1fbf0200` + `0xc0` |
| Child | `pinctrl`, `compatible = "airoha,en7523-pinctrl"` |
| Required phandle | `airoha,chip-scu = <&scu>` -- without it the probe returns `-ENODEV` and there is no gpiochip at all |
| Interrupt | `GIC_SPI 26` |
| Lines | 30, `GPIO0..GPIO29`; `gpio-ranges = <&en7523_pinctrl 0 12 30>` maps line N to internal pin N+12, so `<&en7523_pinctrl N>` is the old `<&gpio0 N>` |
| Why the old banks go | they decode the same window (`0x1fbf0200`-`0x1fbf02bf`), so the pinctrl driver and the legacy banks cannot coexist |
| IOMUX | the pinctrl probe zeroes five SCU IOMUX registers (`0x1fbf0210`, `0214`, `0218`, `0220`, `0224`) -- on EN7523 a zero means "GPIO". A pad that stays mute is usually held by `REG_GPIO_FLASH_MODE_CFG` (`0x1fbf0234` / `0x1fbf0268`), which is **not** cleared |

**Measured front-panel map.** The vendor LED table (`userfs/7523duled.conf`) does not match this
board, so the map below comes from measurement: drive one pad to 0 with every other pad at 1, then
read the pad data register back to confirm the level actually changed.

| Function | Pad | Notes |
|---|---|---|
| Power LED (blue) | GPIO27 | `default-state = "on"` is required: bit 27 of the pad data register reads 0 at power-on, so the LED is already lit before any driver runs |
| PON LED (green) | GPIO10 | |
| LOS LED (red) | GPIO6 | The silkscreen calls it ALM; the pad is the LOS/ALM LED. (An earlier revision drove pad 6 as the 2.4 GHz LED: wrong.) |
| Internet LED (blue) | GPIO1 | Silkscreen: INET |
| Reset button | GPIO0 | `KEY_RESTART`. Quick press reboots, holding it ~5 s factory-resets. Verified on hardware: `pressed`/`released` are logged |
| WPS button | GPIO7 | `KEY_WPS_BUTTON`, polled (`gpio-keys-polled`, 100 ms) |
| LAN1-LAN4 LEDs | pads 22-25 | **Not** GPIO-controllable: the pads are muxed to the internal switch's LED engine (`SCU 0x1fa20210`, LAN0..3_LED0_MODE = 1). They work; Linux cannot drive them |
| WLAN 2.4/5 GHz LEDs | -- | Driven by the MT7916 through its pad mux (`MT_LED_GPIO_MUX1`, `0x70005054`; pad 14 = 2.4 GHz, pad 15 = 5 GHz) -- see [wifi.md](wifi.md) section 12 |
| WPS LED | unknown | **Not reachable.** No pad responded while the button was held (28 safe pads tried). The remaining candidates are pad 16 (laser TX-disable) and pad 28 (PCIe reset0), both hazardous to drive. Open item |

Pads that were tested and have **no** LED at all: 2, 3, 4, 5, 8, 9, 11, 12-21, 26. Pads 28 and 29
also read as having no LED, but they are the PCIe resets, so they were not driven as part of the LED
search. In particular pad 11 (which the vendor table calls PWR) and pads 3 and 26 (vendor: LOS, WPS)
are mute; an earlier revision of the board support drove pad 11 as the power LED, which is why the
power LED could not be controlled at the time.

The vendor U-Boot env agrees with the measurement where its values decode as hex pad numbers:
`internet_gpio = 01` is pad 1 (INET), `dsl_gpio = 0a` is pad 10 (the PON LED), and the
`multi_upgrade_gpio` list `0b0a03010604051b1a` contains `1b` = pad 27 (power) and `1a` = pad 26. It is
also a reminder that the vendor table is only a hint: `power_gpio = 1515` does not decode as a single
pad and is left unexplained.

The two buttons sit on pads the pinctrl can see. The device tree nevertheless keeps
`gpio-keys-polled` (100 ms) even though the pinctrl node provides an interrupt controller, because
the move away from the legacy banks was made one variable at a time; interrupt-driven `gpio-keys` is
a listed follow-up. The often-quoted reason for polling -- that only GPIO0..GPIO15 are
interrupt-capable here -- is **not re-verified** in the sources behind this document.

**Laser enable / TX disable.** The vendor `userfs/led.conf` line `42 16 1 0 1` maps
`LED_PHY_TX_POWER_DISABLE` to **GPIO 16**, mode 1 (ONOFF). Two caveats:

- The polarity is **not confirmed**. Both polarities have to be tried on hardware before the value
  is trusted (`tx-disable-gpios = <&en7523_pinctrl 16 ...>` with the active level tested either way).
- The number 16 comes from the vendor GPIO framework, which numbers lines 0-63. With the pinctrl in
  place the same pad is line 16 and GPIO 16 is inside the 30-line range, but no node drives it yet,
  and the pad must stay untouched until the laser driver owns it (see the hazards in section 10).

## 10. Safe-to-write rules

1. **Only `tclinux_slave` (slot B, `0x28C0000`, 40 MB) is a sanctioned write target.** It is where
   the OpenWrt image goes, and it is the only partition the board DTS leaves writable.
2. **`data` (`0x50C0000`, 20 MB, JFFS2)** is writable in the board DTS and is intended as the OpenWrt
   overlay. On the stock firmware it holds live system data; do not write it while stock is running.
3. **Never write anything else:** `bootloader` (mtd0), `romfile` (mtd1), `tclinux` / slot A plus its
   `kernel` and `rootfs` sub-partitions (mtd2, mtd3, mtd4), `config` (mtd9) and `reservearea` (mtd10).
4. **Never write the raw tail `0x6900000..0x8000000`**, including the factory block at `0x6F00000`
   (GPON identity + per-unit laser BOB calibration), the byte at `0x6FC0000`, the `RAWB` marker at
   `0x75E0000` and the `BMT` bad-block table at `0x7FE0000`. None of it belongs to an mtd partition
   and the vendor reaches it directly.
5. **Do not flash a modified image with a raw programmer.** CH341A-style writes leave the NAND
   ECC/spare bytes stale and the board will not boot. Write from the running operating system
   through the MTD layer, or regenerate the ECC bytes.
6. **Never write blindly without BMT-aware tooling.** Writing raw blocks can corrupt the bad-block
   mapping; the vendor `mtd` tool goes through the BMT, raw `dd`/`nandwrite` to `/dev/mtd0` does not.
7. **The vendor `mtd` tool parses sizes and offsets with `atoi`, so it accepts decimal only.**
   `0x7C000` is read as `0` (this has already destroyed a bootloader once). Use `507904` for the
   U-Boot env, `524288` for the whole mtd0 image, or `0` to write a whole partition.
8. **Always read back and compare a hash before rebooting** after any flash write, and treat
   `mtd bob get` and any `mtd` command aimed at the raw area as a write, not a read.
9. **Keep a full 128 MB dump and a CH341A programmer on hand** before any operation, and keep U-Boot
   console access available: the stock autoboot path for slot A is broken when its FIT image is
   damaged, and a re-flash is then the only way back.

### Hazards: pads and register windows that must not be touched

The flash rules above are one class of hazard. The others are the pads and the PCIe window:

| Hazard | Why |
|---|---|
| Pad 16 (`PHY_TX_POWER_DISABLE`) | The PON laser's TX-disable line (vendor `led.conf` line `42 16 1 0 1`, independently confirmed). Driving it disables the optical transmitter -- or, with the polarity reversed, may enable it. Leave it to the laser driver |
| Pad 29 (`pcie_reset1`) and pad 28 (`pcie_reset0`) | PCIe resets. Pulling either low resets the link: the MT7916 disappears and Wi-Fi is gone until the next power cycle. The vendor LED table lists pad 29 as the Internet LED, which is wrong on this board |
| Reading a PCI BAR while `PCI_COMMAND.MEMORY` is 0 | Hangs the whole SoC until the power is cycled -- no watchdog recovery. Analysed in [pcie-root-cause.md](pcie-root-cause.md) section 2 |
| Pads 22-25 | Muxed to the internal switch's LED engine; driving them as GPIO achieves nothing |
| Flash | Slot B only; see items 1-4 above |
