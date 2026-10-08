# Roadmap

Remaining work, ordered by what unblocks the most. Each item states a concrete
acceptance test, so "done" is not a matter of opinion. The short version of the
current state is in [status.md](status.md).

## What moved off this list

| Item | What closed it | Write-up |
|---|---|---|
| Ethernet and the 4x GbE switch | the community series adopted as `930-42` .. `930-51`, plus `mt7530` DSA in MMIO mode; a real 1 Gbps link and a working NAT uplink | [ethernet.md](ethernet.md) |
| NAND persistence and sysupgrade | `platform.sh` with `PART_NAME="tclinux_slave"`, plus `CONFIG_MTD_BLOCK` / `_CHAR` and the `DEVTMPFS` options | [sysupgrade.md](sysupgrade.md) |
| Board LEDs and buttons | four LED nodes and two polled keys in the board device tree, each checked on hardware | [leds.md](leds.md) |
| Wi-Fi and the web UI | a real client over the air (HE-MCS 8, 80 MHz, 2SS), LuCI on `ucode`, `apk` against the generic feeds | [wifi.md](wifi.md) |

Two decisions from those items still teach something:

* **The bad-block table is still owned by the vendor.** An Airoha BMT driver exists
  in the OpenWrt tree (`900-airoha-bmt-support.patch`,
  `901-snand-mtk-bmt-support.patch`), enabled for `an7581`/`an7583` but not
  `en7523`. Enabling it is a one-way decision, because the vendor's mapping is in
  the trailing raw region (`RAWB` at `0x75E0000`, `BMT` at `0x7FE0000`) and the
  driver may rebuild it rather than adopt it. Read it back first.
* **The overlay is deliberately not `rootfs_data` in slot B.** `mtdsplit` creates a
  partition of that name inside slot B, which every upgrade wipes; the working setup
  uses a UBI volume named `rootfs_data` on the separate `data` partition (mtd7).
  Keep that, or upgrades lose `/etc/config`.

## Read this first: reference implementations already in the OpenWrt tree

`target/linux/econet/` is an existing OpenWrt target for **the same vendor's
earlier MIPS family** (EN751221 / EN751627 / EN7528), and it already solves several
problems this board has:

| Path in the OpenWrt tree | Why it matters here |
|---|---|
| `base-files/sbin/en75_chboot` | A boot-flag switcher for the vendor A/B scheme: the flag is an ASCII byte (`0x30` = `'0'`, `0x31` = `'1'`) at a per-board offset. Very likely what the lone `'1'` at `0x6FC0000` is. Item 3. |
| `files/drivers/mtd/nand/en75_bmt.c`, `901-...`, `902-snand-mtk-bmt-support.patch` | A second BMT implementation for the same NAND lineage. Compare it before trusting either with this unit's table. |
| `base-files/lib/functions/econet.sh`, `09_mount_factory_data` | How the same vendor's firmware locates and mounts its factory and data partitions. Item 2. |
| `etc/hotplug.d/ieee80211/10_fix_wifi_mac` | Deriving a stable Wi-Fi MAC from stored per-unit data. Item 2. |
| `base-files/lib/upgrade/platform.sh` | The template the board's sysupgrade was written from: `default_do_upgrade` plus a `PART_NAME` covers this vendor's slots. |
| `package/kernel/econet-eth` | An out-of-tree driver for the MIPS EN751221: a structural reference, not reusable for EN7523. |

`econet`, like `airoha`, is `FEATURES:=source-only`, so nothing learned there
implies official binary support.

For EN7523 the tree that matters is the community
[`Sirherobrine23/airoha_kernel`](https://github.com/Sirherobrine23/airoha_kernel),
branch `airoha_en7523_all`: the Ethernet series was adopted from it as `930-42` ..
`930-51`, and the xPON and optical sources in
[`openwrt/pon/`](../openwrt/pon/README.md) come from the same tree.

## 1. The xPON and optical port (M3, then M4)

**Why first.** This is the only item that makes the board what it is; everything
else on this page refines a router that already works.

**Where the work stands** (measured in a compile harness, not estimated). Compiling
the community sources object by object against this kernel (6.18.54) gives **32 of
34 objects clean**: `net/xpon/**` 14/14 (including the in-kernel OMCI agent),
`drivers/net/optical/**` 15/15, `phy-airoha-xpon.c` and `pcs-en7523.c`. The two
failures (`airoha_xpon.o`, `airoha_gpon_omci.o`) fail **only** on `airoha_eth.h`:
the community and OpenWrt `airoha_eth` drivers have diverged, and 17
`airoha_eth_*xpon*()` hooks plus a set of types/enums and macros are missing.
Neither shortcut works -- the community header is not a superset (it breaks
`airoha_eth.c` and `airoha_ppe.c`), and that driver wholesale compiles only 4 of its
10 objects. One real API drift is already fixed: pcs-provider changed between 6.18.44
and 6.18.54, so `pcs-en7523.c` needs `devm_fwnode_pcs_add_provider()`.

**Steps**

1. Turn the per-object harness into a **link** harness: a shim header providing the
   missing 17 hooks, types and macros with stub bodies, so the whole stack links
   while the datapath hooks stay unimplemented. That separates "does it link" from
   "does it work", the question the last attempt could not answer.
2. Implement the hooks in `airoha_eth.c`: GEM port to netdev queue mapping, the OAM
   transmit path, and the xPON control start/stop entry points.
3. Bring up the optical side: the `en7571` laser driver and its hwmon exposure
   first, then `phy-airoha-xpon.c` and the PON PHY.
4. Close the device tree questions the stage 2 overlay lists as open: the `pon`
   pinctrl group, whether the `xpon_phy` node needs more register windows, and where
   the laser actually sits (DDMI points at the PON PHY block's internal I2C, not the
   SoC's `i2c0`). Confirm the GPIO 16 laser-disable polarity.
5. Only then M4: the O5 state machine and the OMCI agent's MIB round-trip, using the
   identity from the factory partition.

**Acceptance test.** M3: `en7571` probes, hwmon exposes bias current and
temperature, and `tx_enabled` reads 1. M4: the kernel reports O5 with OMCI up, the
OLT accepts the ONU using the identity from the factory partition, and OMCI MIB
get/set round-trips.

**Risk: high.** Driver work with no reference manual, on hardware that needs a fibre
and an OLT to test properly.

## 2. Per-unit calibration and identity from the factory block

**Why it matters.** Wi-Fi runs on the default eeprom blob: the MAC is stable, but the
RF calibration is generic, and the driver still reports a fallback to the default bin.

**Steps**

1. Decode the vendor factory block at `0x6F00000`, which holds the per-unit Wi-Fi
   calibration in addition to the GPON identity and laser BOB data. Nothing in it
   may be written.
2. Express it in the device tree -- an nvmem cell or a `mediatek,mtd-eeprom`
   reference -- so the driver reads real data instead of falling back.
3. Derive the base MAC from the same region, so a replacement unit gets its own
   address with no per-unit edit.

**Acceptance test:** the driver no longer reports a fallback to the default eeprom
bin, the MAC matches the value stored in the factory block, and both stay identical
across reboots.

**Risk: medium.** Read-only in every path, but the layout has to be confirmed
against vendor firmware before anything points the driver at it.

## 3. Automated, reproducible boot

**Why it matters.** Booting rests on a hand-edited U-Boot environment: the vendor
U-Boot cannot parse an OpenWrt FIT image (`Parse main image fail`), so the working
setup boots slot B through a saved `bootcmd` of `flash read` + `bootm` with a
hard-coded length. This repository neither creates nor restores that environment.

**Steps**

1. Settle the boot flag. `en75_chboot` shows the flag is an ASCII byte at a
   per-board offset, so the lone `'1'` at `0x6FC0000` is consistent with "slot B
   selected"; confirm it by switching the byte and observing which slot U-Boot takes,
   and add an `econet,vgp-42x6v1` case to a port of that tool. Two things must not be
   assumed: the exact location (`0x6FC0000` is what U-Boot prints; a live
   `/proc/mtd`-derived reading says `0x68C0000`) and the polarity (a `'1'` byte at
   rest next to a cmdline reporting `bootflag=0`).
2. Determine whether this U-Boot can be taught the OpenWrt FIT (its dual-image path
   rejects it for a missing `/configurations` node), or whether a `bootcmd` is the
   permanent answer.
3. Make the result reproducible: the environment and the boot flag must come from
   the repository or an installer, not from being typed per unit. The current
   `bootcmd` embeds the image length, so it also needs updating on every upgrade.
4. Keep a way back to a U-Boot prompt, so an unattended boot cannot lock the unit
   out.

**Acceptance test:** power-cycle the board with nothing attached to the UART and it
reaches userspace on its own, from an install performed by the repository's tooling.

**Risk: medium.** The board is recoverable over the UART, but only with a working
console.

## 4. The WPS LED

**Why it matters.** Every other front-panel light is described and works; this is the
last unexplained indicator, and the vendor's LED table claims it exists.

**Steps**

1. The candidate pad (the one the vendor's `7523duled`-style table assigns to WPS) is
   claimed by another pin function and produced no LED response when driven as a
   GPIO. Re-test with the function muxed away, and measure the pad rather than
   inferring from the table.
2. If the pad turns out to be a serial-to-parallel output rather than a GPIO, decide
   whether it is worth driving at all.

**Acceptance test:** either the LED lights from a device tree node and survives a
reboot, or the pad is proven unreachable and the item is closed as "no LED".

**Status: blocked, on purpose `[not verified]`.** The 28 safe pads were each driven
low, plus pad 16 and pad 28, and the button was held for 5 s; nothing lit it. Only
two ways out remain: identify that pad's other function and re-test with it muxed
away, or close the item as "no LED". Nothing further is planned. Detail:
[leds.md](leds.md) section 11.

**Risk: low.** Cosmetic, and the WPS button works regardless.

## 5. Watchdog and thermal

**Why it matters.** Nothing recovers a hung system today, and the thermal block of the
SoC is not monitored.

**Steps**

1. Decide what should own the watchdog. The Airoha watchdog driver does not arm in
   `probe()`; it starts only when userspace opens `/dev/watchdog`, which nothing
   does today. If it is armed, verify the timeout and the reset path on hardware, and
   make sure the bootloader does not fight it.
2. Enable the thermal sensor and confirm it tracks the die before wiring it to any
   policy.

**Acceptance test:** a deliberate hang resets the board within the configured
timeout, and the thermal zone reports a plausible temperature.

**Risk: medium.** A watchdog that fires during boot is a bricking machine; prove it
before enabling it by default.

## 6. Packaging: bake every kmod, and respect the ABI

**Why it matters.** The `airoha/en7523` target is `source-only`, so it has no official
package repository: anything not in the image has to be built into the next one.

**Steps**

1. Document the rule that `kmod-*` must be baked in: a module built against a
   different kernel build will not load.
2. Keep the `apk` hazard visible. The generic feeds work for *new* userspace
   packages, but `apk upgrade` must not be run on a snapshot image: 12 installed
   packages are behind, and one is a `zlib` major-version bump, which can break every
   binary linked against the older `zlib` -- including the SSH server needed to fix it.
3. Add a build-time note or check so a release image never depends on a package the
   target cannot fetch.

**Acceptance test:** a fresh install reaches the LuCI package manager, installs a new
userspace package from the generic feeds, and still boots and serves SSH afterwards,
with `apk upgrade` documented as forbidden.

**Risk: low**, as long as the rule is followed.

## 7. Throughput: find where the 200-400 Mbit/s goes (low priority)

**Why it matters.** The board works, but it is not fast: acceptance runs peak at
**200-400 Mbit/s** `[hardware]`, against 1 Gbps negotiated on the wire and a radio
that reports HE80 2x2. Something in the datapath -- not the link -- is the limit.
This is explicitly **not** a priority; it is written down so the number stops being
a mystery.

**Steps**

1. Build a reproducible harness first, because the existing figure does not say how
   it was obtained `[not verified]`: `iperf3` both directions, wired-to-wired and
   wired-to-wireless, with the client, version and negotiated link recorded.
2. Attribute the loss: wired-only against wireless-only separates the Ethernet
   datapath from the radio, and CPU load during the run says whether the target is
   CPU-bound or queue-bound.
3. Then look at the known unknowns from [ethernet.md](ethernet.md) section 7: the
   unexplained QDMA window overlap, `.ppe_stats_entries = 0` (so PPE statistics
   cannot help), `eth0` MTU 1504, hardware offload and flow control untested, and a
   single queue per port.
4. Only after that, consider offloads or queue changes.

**Acceptance test:** the harness reports a number that is reproducible across
reboots, the wired number is far above the 200-400 Mbit/s band (no radio in the
path), and the wireless number is explained rather than guessed.

**Risk: low** (measurement), but a number without a baseline is worse than no
number -- do not tune anything before the harness exists.

## Smaller items

Set `IMAGE_SIZE := 0x2800000` (slot B) in the device profile so an oversized image is
rejected at build time rather than truncated at flash time `[not verified]` -- the value
is known, the build that proves the check fires is not done. See
[sysupgrade.md](sysupgrade.md) section 8.

Publish the firmware images plus the Image Builder tarball on a tag, with checksums --
and re-check the two per-unit items listed in
[imagebuilder/README.md](../imagebuilder/README.md) ("Before you publish an image")
before any image is handed out.

## Explicitly rejected for now

* **Sending patches upstream to `openwrt/openwrt`.** Not a goal for this project. The
  repository is therefore a self-contained overlay with its own Image Builder, rather
  than a fork aiming at merge. If that changes, the patch series in `openwrt/patches/`
  is already in the right shape to be submitted.
