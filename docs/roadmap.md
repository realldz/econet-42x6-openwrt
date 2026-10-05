# Roadmap

Remaining work, ordered by what unblocks the most. Each item states a concrete
acceptance test, so "done" is not a matter of opinion.

The short version of the current state is in [status.md](status.md).

---

## Read this first: reference implementations already in the OpenWrt tree

Before writing anything for the items below, look at `target/linux/econet/`. It is
an existing OpenWrt target for **the same vendor's earlier MIPS family**
(EN751221 / EN751627 / EN7528), and it already solves several problems this board
has:

| Path in the OpenWrt tree | Why it matters here |
|---|---|
| `base-files/sbin/en75_chboot` | A boot-flag switcher for the vendor's A/B scheme. It shows the flag is a small **ASCII byte pattern** (`0x30` = `'0'`, `0x31` = `'1'`) at a per-board partition and offset, with a table mapping each board to its location. This is very likely what the lone `'1'` byte at `0x6FC0000` on this board is. See item 4. |
| `base-files/lib/upgrade/platform.sh` | A working sysupgrade implementation for this vendor family, including slot handling. Use it as the template for item 1 rather than starting from scratch. |
| `files/drivers/mtd/nand/en75_bmt.c`, `patches-6.18/901-nand-enable-en75-bbt.patch`, `902-snand-mtk-bmt-support.patch` | A second BMT implementation for the same NAND lineage. Compare it with the `airoha` target's `900-airoha-bmt-support.patch` before trusting either with this unit's bad-block table. |
| `base-files/lib/functions/econet.sh`, `base-files/lib/preinit/09_mount_factory_data` | How the same vendor's firmware locates and mounts its factory/data partition. Directly relevant to item 3. |
| `etc/hotplug.d/ieee80211/10_fix_wifi_mac` | A reference for deriving a stable Wi-Fi MAC from stored per-unit data. Also item 3. |
| `etc/board.d/01_leds`, `02_network` | Per-board LED and network defaults, if item 6 ever needs them. |
| `package/kernel/econet-eth` | An out-of-tree Ethernet driver, but `DEPENDS:=@TARGET_econet` and written for the MIPS EN751221. Treat it as a structural reference for how this vendor's Ethernet is organised, **not** as something reusable for EN7523. |

Note also that `econet`, like `airoha`, is `FEATURES:=source-only`, so anything
learned there carries no expectation of official binary support.

---

## 1. NAND persistence and sysupgrade

**Why first.** Until this works, OpenWrt on this board is a demo: every reboot
loses everything, and starting the system means repeating a manual procedure over
a serial console. Nothing else becomes pleasant until this is fixed.

**Steps**

1. Build and boot with the kernel options this repository already adds
   (`CONFIG_MTD_BLOCK`, `CONFIG_MTD_CHAR` in
   `openwrt/patches/0003-...`) and confirm `/dev/mtd0` .. `/dev/mtd6` and
   `/dev/mtdblock0` .. `6` appear. This is the first thing to check, because it
   has not been verified on hardware yet.
2. Establish that the `mtd` userspace tool can read and erase a partition on this
   NAND without corrupting the bad-block table. Test on a scratch partition
   before touching slot B.
3. Write `target/linux/airoha/base-files/lib/upgrade/platform.sh` providing
   `platform_check_image()` and `platform_do_upgrade()`, targeting slot B
   (`tclinux_slave`, `mtd3`) and leaving slot A untouched.
4. Add the flash layout to the device profile: set `IMAGE_SIZE` for slot B so
   `check-size` rejects an oversized image instead of writing a truncated one,
   and make `SUPPORTED_DEVICES` cover the board so `sysupgrade` refuses a
   mismatched image.
5. Deliver an overlay on the `data` partition (JFFS2), so configuration survives
   a reflash, not just a reboot.

### Bad-block handling is a smaller problem than it first looks

The bad-block table is not something that has to be written from scratch. The
OpenWrt tree **already contains an Airoha BMT driver**:

* `target/linux/airoha/patches-6.18/900-airoha-bmt-support.patch` adds
  `drivers/mtd/nand/airoha_bmt.c`, implementing the Airoha BMT format
  (`MAX_BMT_SIZE` 250 entries, a signed table header, checksum);
* `901-snand-mtk-bmt-support.patch` wires it into the SPI-NAND core;
* it is **enabled for `an7581` and `an7583`** via `CONFIG_MTD_NAND_MTK_BMT=y`,
  but the `en7523` config does not set it.

So the remaining work on this axis is roughly a one-line config change plus
verification, rather than a driver port.

It is deliberately **not** enabled by default in this repository, because it is a
one-way decision. The vendor's bad-block mapping lives in the trailing raw region
(`RAWB` at `0x75E0000`, the `BMT` marker at `0x7FE0000`), and the vendor's own
boot log shows it initialising that pool (`bmt pool size: 81`,
`BMT & BBT Init Success`). Handing those blocks to the kernel's BMT driver means
the kernel becomes the owner of that mapping. Whether the driver correctly adopts
an existing vendor table, rather than deciding it is invalid and rebuilding it,
has not been verified on this unit -- and if it rebuilds, the mapping is gone.
Confirm that before enabling it, and take a full readback of the trailing region
first.

**Acceptance test:** from a running image, `sysupgrade -n <image>` reboots into
the new image on slot B, `/etc/config` persists across the upgrade, and slot A is
byte-identical to what it was before.

**Risk: high.** This is the item most likely to brick a unit if it is done
carelessly. The bad-block table at `0x7FE0000` is outside every partition and
must not be disturbed; see [hardware.md](hardware.md).

---

## 2. Ethernet and the 4x GbE switch

**Why it matters.** A router without a LAN port is not a router. This is the
largest remaining piece of real engineering.

**The most promising lead.** The community tree
[`Sirherobrine23/airoha_kernel`](https://github.com/Sirherobrine23/airoha_kernel),
branch `airoha_en7523_all`, carries an EN7523-capable `airoha_eth.c` together
with xPON support. That is a far better starting point than writing a driver from
scratch, and it is the same tree the PON material in
[`openwrt/pon/`](../openwrt/pon/README.md) came from.

**Steps**

1. Diff that tree's `drivers/net/ethernet/airoha/` against OpenWrt's, and work out
   which parts are EN7523-specific (the GDM2 instance, the switch, the PPE
   entries) rather than generic refactoring.
2. Decide between the two strategies already analysed in
   [`openwrt/pon/README.md`](../openwrt/pon/README.md) section 3: port only the
   hooks into OpenWrt's driver, or replace the driver wholesale for a bench
   bring-up.
3. Add the missing device tree nodes for the frame engine, the GDM instances and
   the switch.
4. Bring up one port, then the switch, then verify throughput and that the CPU
   port is not a bottleneck.

**Acceptance test:** a link comes up on a physical port, the port gets an address
over DHCP or a static config, and a bidirectional throughput test completes at a
plausible rate.

**Risk: high.** Driver work with no reference manual.

---

## 3. Per-unit calibration and a stable MAC address

**Why it matters.** Today the MAC address is random and there is no RF
calibration, so the device changes identity on every boot.

**Steps**

1. Decode the layout of the `factory` partition at `0x6F00000`, which holds the
   per-unit Wi-Fi calibration in addition to the GPON identity and laser BOB.
2. Express that in the device tree as an nvmem cell or `mediatek,mtd-eeprom`
   reference, so `mt7915_eeprom_load()` finds real data instead of failing over
   to the default blob.
3. Derive the base MAC address from the same region.

**Acceptance test:** the MAC address is identical across reboots and matches the
value stored in the factory partition, and the Wi-Fi driver no longer reports
that it fell back to the default eeprom bin.

---

## 4. Booting OpenWrt without a serial console

**Why it matters.** Right now every boot needs a human with a terminal.

**Steps**

1. Settle the boot flag first, because it is the cheapest possible win. The
   earlier notes were unsure whether the lone byte at `0x6FC0000` (value `'1'`)
   is a boot flag, and if so what its encoding is. The `econet` target's
   `en75_chboot` answers the encoding question for this vendor family: it is a
   small ASCII byte pattern, `0x30` = `'0'` and `0x31` = `'1'`, at a
   board-specific partition and offset. So `0x6FC0000` reading `'1'` is
   consistent with "slot B selected". Confirm that on this unit by reading the
   byte, switching it to `'0'`, and observing which slot U-Boot takes. Add a
   `econet,vgp-42x6v1` case to a port of `en75_chboot`.
2. Determine whether vendor U-Boot can be configured to accept the OpenWrt FIT,
   or whether it needs its `bootcmd` adjusted. It already fails with
   `Parse main image fail`, so the FIT is being discovered but not understood.
   That failure is separate from the boot flag.
3. Alternatively establish the exact `bootcmd`/`bootargs` combination that boots
   slot B unattended and persist it in the environment.
4. Preserve the ability to get back to a U-Boot prompt, so an unattended boot
   cannot lock the unit out permanently.

**Acceptance test:** power-cycle the device with nothing attached to the UART and
it reaches userspace on its own, while interrupting early still yields a U-Boot
prompt.

---

## 5. Optical and PON (milestones M3 and M4)

**Why it is last.** It is the largest body of work, it needs hardware that the
other items do not (a fibre and an OLT), and it is independent of a usable
router. Everything needed to start is already collected in
[`openwrt/pon/`](../openwrt/pon/README.md).

**Steps toward M3**

1. Apply the six hook patches and copy the community tree's xPON and optical
   sources into the kernel overlay.
2. Port the 14 `airoha_eth_*xpon*()` APIs into `airoha_eth.c`. This is the bulk
   of the work and cannot be automated, because the surrounding datapath differs.
3. Resolve the device tree questions the stage 2 overlay lists as open: the
   `pon` pinctrl group, and whether the `xpon_phy` node needs the additional
   register windows.
4. Resolve where the laser actually sits: DDMI evidence points at the PON PHY
   block's internal I2C rather than the SoC's `i2c0`. Confirm GPIO 16 polarity.

**Acceptance test for M3:** `en7571` probes successfully, hwmon exposes bias
current and temperature, and `tx_enabled` reads 1.

**Acceptance test for M4:** the kernel reports the link in O5 with OMCI up, the
OLT accepts the ONU using the identity from the factory partition, and OMCI MIB
get/set round-trips.

---

## 6. Polish

Smaller items, in rough order of usefulness:

* **LEDs and buttons.** Add device tree nodes once the GPIO assignments are
  confirmed. The laser enable GPIO is known (GPIO 16) but its polarity is not;
  board LEDs were not established with confidence, so they are not described.
* **Thermal and watchdog.** The SoC has a thermal block that the target config
  currently leaves disabled.
* **Image size limits.** Set `IMAGE_SIZE` so an oversized image is rejected at
  build time rather than being truncated at flash time.
* **A reproducible release.** Wire the GitHub Actions workflow to publish both
  the firmware images and the Image Builder tarball on a tag, with checksums.

---

## Explicitly rejected for now

* **Sending patches upstream to `openwrt/openwrt`.** Not a goal for this
  project. The repository is therefore structured as a self-contained overlay
  with its own Image Builder, rather than as a fork aiming at merge. If that
  changes, the patch series in `openwrt/patches/` is already in the right shape
  to be submitted.
