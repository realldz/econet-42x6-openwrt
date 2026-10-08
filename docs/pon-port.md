# PON port: xPON, optical frontend and OMCI (milestones M3 and M4)

**State: the material is collected and it compiles; it is not functional and none of it has ever
been run on the device.** There is no PON link, no optical frontend probe and no OMCI session.

This is the analysis behind the material in [`openwrt/pon/`](../openwrt/pon/README.md): where it
comes from, what a compile harness can and cannot prove, the exact blocker, and the ordered work
left. The practical "how to apply it" instructions stay in that directory's README. Milestones and
acceptance tests are defined in [status.md](status.md); the work list is in
[roadmap.md](roadmap.md). This document supersedes one number in `roadmap.md` section 5: "port the
14 `airoha_eth_*xpon*()` APIs" is measured as **17 functions plus a backend behind them**
(section 6).

## 1. What is being ported, and where it comes from

The source is the community tree
[`Sirherobrine23/airoha_kernel`](https://github.com/Sirherobrine23/airoha_kernel), branch
`airoha_en7523_all`, kernel **6.18.44**. It is a mainline-style rewrite of the vendor PON stack,
not vendor code, which is why it is usable at all.

| Part | Size | What it is |
|---|---|---|
| `net/xpon/**` | ~11k lines | xPON core, including an in-kernel OMCI agent (`net/xpon/omci/agent.c`) |
| `drivers/net/optical/**` | ~10k lines | optical frontend framework + `hwmon`, `airoha_lddla`, EN7570/71/72, semtech GN25L95 |
| `drivers/phy/airoha/phy-airoha-xpon.c` | 44 KB | xPON PMA/SerDes, TX_DISABLE/VCC GPIO handling |
| `drivers/net/pcs/airoha/pcs-en7523.c` | ~650 lines | EN7523 PCS, including the PON serdes |
| `airoha_xpon.c`, `airoha_ploam.*`, `airoha_gpon_omci.*` | 130 KB + | the MAC / PLOAM / OMCI glue into `airoha_eth` |

That is roughly **25k lines of new kernel code**. The vendor firmware's own `xpon.ko` is not a
shortcut: it is built for kernel 4.4.115, so its ABI does not match 6.18 (vermagic, `struct
net_device`/`sk_buff` layout, gone symbols), and it is not standalone anyway.

## 2. The compile harness, and what it proves

Work of this size is usually blocked by an unbounded pile of API drift. To make that finite, every
object was compiled **individually** (no link step) against a prepared **Linux 6.18.54** tree --
the version this target pins:

```bash
make -C "$KDIR" ARCH=arm CROSS_COMPILE=<toolchain>- drivers/net/optical/core.o
```

One object at a time because the xPON hooks still missing from `airoha_eth` would fail at *link*
time, and a link failure hides the compile-time drift behind it. Compiling objects also leaves
OpenWrt's build state untouched; `bc` must be installed, or all 34 objects fail with `Error 127` on
`include/generated/timeconst.h`. The harness scripts live in the research workspace, not here.

**What this proves:** the drivers compile against this kernel. **What it does not prove:** that
anything links, loads, probes or works. No object was linked into a module, no module was loaded,
and no PON or optical hardware was exercised.

## 3. Result: 32 of 34 objects compile clean

| Group | Objects | Result |
|---|---|---|
| `net/xpon/**` (including the OMCI agent) | 14 | **14/14 clean** |
| `drivers/net/optical/**` (EN7570/71/72 + semtech) | 15 | **15/15 clean** |
| `drivers/phy/airoha/phy-airoha-xpon.c` | 1 | clean |
| `drivers/net/pcs/airoha/pcs-en7523.c` | 1 | clean, **after the API fix in section 4** |
| `drivers/net/ethernet/airoha/airoha_ploam.c` | 1 | clean |
| `drivers/net/ethernet/airoha/airoha_xpon.c` | 1 | **fails** |
| `drivers/net/ethernet/airoha/airoha_gpon_omci.c` | 1 | **fails** |

The two failures are not spread out: both fail only because of `airoha_eth.h`.

## 4. The one API drift that was found and fixed

### 4.1 The PCS provider API changed between 6.18.44 and 6.18.54

The community code targets 6.18.44 (`int fwnode_pcs_add_provider(...)`,
`fwnode_pcs_del_provider(fwnode)`, and `phylink_release_pcs()`). The 6.18.54 tree
(`include/linux/pcs/pcs-provider.h`) has:

```c
struct fwnode_pcs_provider *
fwnode_pcs_add_provider(struct fwnode_handle *fwnode, ..., void *data);
void fwnode_pcs_del_provider(struct fwnode_pcs_provider *pp);
struct fwnode_pcs_provider *
devm_fwnode_pcs_add_provider(struct device *dev, struct fwnode_handle *fwnode, ...);
/* phylink_release_pcs() no longer exists */
```

The correct model is already in the tree, in `drivers/net/pcs/airoha/pcs-airoha-common.c`:
`devm_fwnode_pcs_add_provider()` plus an `IS_ERR()`/`dev_err_probe()` check, and **no `remove`
function at all** -- the device-managed helper owns the lifetime. `pcs-en7523.c` was moved onto
that pattern and then compiles clean; it is the same family of change as the phylink drift seen
with the community ethernet driver (section 5).

### 4.2 A file that was missing from the apply script

`include/net/xpon/omci.h` does `#include <uapi/linux/omci.h>`, but `include/uapi/linux/omci.h` was
missing from the `NEW_FILES` list of [apply-pon.sh](../openwrt/pon/apply-pon.sh). Without it, **8
objects** failed with `fatal error: uapi/linux/omci.h: No such file or directory`. The file exists
in the community tree (392 lines); it was only missing from the list, and it is **now included**
(the copy set went from 66 files to 67). The measurement above stands as the reason it was added.

## 5. The blocker: `airoha_eth.h` is a different API generation

The in-tree header is **744 lines**; the community one is **4805 lines**, and it is **not a
superset** -- it describes a different driver. Two experiments settled this.

**Experiment A -- swap only the header.** It fixes the two xPON objects and breaks the two that
were fine: `airoha_xpon.o` and `airoha_gpon_omci.o` go from FAIL to OK, while `airoha_eth.o` and
`airoha_ppe.o` go from OK to FAIL (`airoha_ploam.o` and `airoha_npu.o` pass either way):

```
include/linux/compiler.h:197: static assertion failed: "must be array"
airoha_ppe.c:45: 'airoha_is_7583' implicit declaration; 'struct airoha_ppe' has no member 'eth'
```

**The header cannot simply be replaced.**

**Experiment B -- adopt the whole community ethernet cluster** (all 25 files of
`drivers/net/ethernet/airoha`): `airoha_ploam.o`, `airoha_xpon.o`, `airoha_gpon_omci.o` and
`airoha_ppe_debugfs.o` compile; `airoha_eth.o`, `airoha_npu.o`, `airoha_ppe.o`, `airoha_wed.o`,
`airoha_wed_debugfs.o` and `airoha_whnat.o` fail with 3-4+ errors each. Those errors show real
kernel drift outside PON, and that the community tree is not self-contained either:

```
airoha_eth.c:8847: passing argument 3 of 'fwnode_phylink_pcs_parse' makes integer from pointer
airoha_eth.c:8903: 'struct phylink_config' has no member named 'num_available_pcs'
```

It also edits `include/linux/soc/mediatek/mtk_wed.h` (`airoha_wed.c`: `mtk_wed_soc_data` has
incomplete type), and `airoha_ppe_dev_check_skb_reason` / `airoha_ppe_dev_setup_tc` are declared
nowhere. Adopting it means adopting a dependency chain, not a driver.

**Why that direction was rejected.** Every `patches-6.18` patch touching `airoha_eth.c`/`.h` was
dry-run against a copy of the community files: **1 applied, 50 were refused** (48 touch the `.c`,
25 the `.h`), including the whole v6.19/v7.0-v7.4 backport series. The two files diverge in
*opposite* directions -- this tree is at mainline v7.2/v7.3, the community one is a 2024/v6.x base
plus gen-1 and EN7523 and xPON -- so taking it over would lose multi-netdev-per-GDM-port,
`get_link_ksettings`, GRO, HW QoS and the MTU rework, and regress the other boards in the target
(`en7581-evb`, `nokia-xg-040g`, `q1000k`, `w1700k`). The xPON part is about 12 % of that diff: of
the **+6019** added lines in the community `airoha_eth.c`, only about **740** are xPON.

## 6. Sizing the job correctly: 17 hooks, and the backend behind them

The material in [`openwrt/pon/`](../openwrt/pon/README.md) describes "14 missing APIs". That came
from `airoha_xpon.c` alone; `airoha_gpon_omci.c` needs three more
(`airoha_eth_xpon_control_start()`, `airoha_eth_xpon_control_stop()`, `airoha_eth_xmit_xpon_oam()`),
so the number is **17**, plus 8 types/enums and 8 macros. Compiling the two files with the target's
exact kbuild flags gives **107** errors for `airoha_xpon.c` and **6** for `airoha_gpon_omci.c`, and
every one is a missing declaration -- none is an incompatibility in the ported code itself.

The job is smaller than "rewrite a driver" and bigger than the hook list. Smaller: the 17 entry
points are three-line dispatchers, all going through `eth->soc->xpon_ops` (173 lines); the three
ported `.c` files never dereference the driver's structures (grepping every `->field` access over
them returns only `dev->of_node` twice and `dev->fwnode` once); and of 497 identifiers referenced
but absent from this driver, only **55** come from `airoha_eth.h`, while 302 come from the ported
`airoha_xpon.h`. Bigger: the work is the **backend**. Wiring `airoha_en7523_soc_data.xpon_ops`
means 17 callbacks plus 6 helpers plus `gdm_xpon_start/stop` -- about 970 lines in the community
tree, of which ~700 are needed here, and closing the transitive dependency costs 56 more functions
(~1422 lines). `xmit_oam` is the one entangled path (it goes through `__airoha_dev_xmit`, 209
lines).

**The deeper problem was the datapath underneath.** `airoha_eth_get_xpon_netdev()` finds its
target by scanning `init_net` for a netdev whose `get_xpon_ops()` succeeds, so it needs a **GDM2
netdev created by `airoha_eth`**. Measured on the pristine driver: `'7523'` occurred **0 times**
in `airoha_eth.c`/`.h`/`airoha_ppe.c`/`airoha_npu.c`, `of_airoha_match` listed only
`airoha,en7581-eth` and `airoha,an7583-eth`, and `en7523.dtsi` had no ethernet node -- so "just add
17 hooks" was not achievable, and the plan carried a 200-600 line unknown for "EN7523 SoC data + a
gen-2 datapath", because `airoha_ppe.c` had no FoE/PPE configuration for this SoC.

**That unknown is now resolved.** The EN7523 ethernet support from the same community branch is in
this repository's overlay
(`openwrt/overlay/target/linux/airoha/patches-6.18/930-42..930-51-airoha_en7523_all-*`: GDM ports,
DSA MT7530, `airoha,en7523-eth`, EN7523 PCS and PON serdes). Re-measured against a prepared tree:
`grep -c 7523 airoha_eth.c` is **70** (the SoC is in the driver, with `en7523_soc_data` at
`airoha_eth.c:4763` and `of_airoha_match` matching `airoha,en7523-eth`), while `grep -c xpon` is
still **0 / 0** in `airoha_eth.c`/`.h`, `struct airoha_eth_soc_data` still has **no** `xpon_ops`
field (`airoha_eth.h:640-656`), and `CONFIG_AIROHA_XPON_V1` still does not exist in any Kconfig
(section 7). What is left is the xPON glue: roughly **700-1300 lines**, previously estimated at
1100-1900.

## 7. What `apply-pon.sh` and the six hook patches do today

`apply-pon.sh` does three things, and none of them produces a working PON link:

1. it copies **67 files** out of the community clone into `target/linux/airoha/files/`, which
   OpenWrt overlays onto the kernel source (`include/uapi/linux/omci.h` is now in the list,
   section 4.2);
2. it **stages** the six hook patches into `target/linux/airoha/pon-patches/`, deliberately *not*
   into `patches-6.18/`, because they target the kernel tree *after* OpenWrt has applied its own
   patches and must be applied by hand with `git apply --3way`;
3. it prints a manual checklist: `make target/linux/prepare`, apply the six patches, add the
   symbols that cannot be patched (`PCS_AIROHA_EN7523`, `PHY_AIROHA_XPON` and the
   `drivers/net/pcs` / `drivers/phy/airoha` Kconfig and Makefile hooks that only exist after
   OpenWrt's own patches), then port the xPON hooks, resolve pinctrl and build.

| Patch | File | Effect |
|---|---|---|
| `010-net-Kconfig-xpon.patch` | `net/Kconfig` | `source "net/xpon/Kconfig"` |
| `011-net-Makefile-xpon.patch` | `net/Makefile` | build `net/xpon/` |
| `020-drivers-net-Kconfig-optical.patch` | `drivers/net/Kconfig` | `source "drivers/net/optical/Kconfig"` |
| `021-drivers-net-Makefile-optical.patch` | `drivers/net/Makefile` | build `drivers/net/optical/` |
| `032-airoha-Kconfig-xpon-minimal.patch` | `drivers/net/ethernet/airoha/Kconfig` | `config AIROHA_XPON_V1` |
| `033-airoha-Makefile-xpon-minimal.patch` | `drivers/net/ethernet/airoha/Makefile` | link `airoha-xpon.o` from `airoha_xpon.o` + `airoha_ploam.o` + `airoha_gpon_omci.o` |

The first four were checked with `git apply --check` against a vanilla Linux v6.18 tree and pass.
**`032` does not apply to the prepared tree**: it leaves a `Kconfig.rej`, so
`CONFIG_AIROHA_XPON_V1` **does not exist in any Kconfig today** and the driver cannot be selected.
The measured correct context is a hunk at `@@ -31,6 +31,23 @@` ending at the `endif` for
`NET_VENDOR_AIROHA`; the patch has to be rewritten against the real file.

[`reference/`](../openwrt/pon/reference/README.md) holds the community variants of these hooks for
comparison, which is also the evidence for rejecting the "replace the whole cluster" route: it
contains the community's full `airoha` Kconfig rewrite (adds `NET_AIROHA_SOC_WED` and
`NET_AIROHA_WHNAT`, drops a `NET_DSA` dependency) and its Makefile, alongside the `ref-` copies of
the net/optical hooks and the two PCS hooks for `pcs-en7523.c`.

**Bottom line: applying everything in `openwrt/pon/` does not give a working PON link -- it does
not even build the xPON objects yet, because the `airoha_eth.h` shim of section 10 does not exist
and `CONFIG_AIROHA_XPON_V1` cannot be selected.**

## 8. The stage 2 device tree overlay

[`en7523-vgp42x6v1-pon.dtsi`](../openwrt/overlay/target/linux/airoha/dts/en7523-vgp42x6v1-pon.dtsi)
records what was recovered from the stock device tree and from live hardware, for the day the
drivers exist:

* `xpon` / `xmac@1fb60000` -- the MAC window plus a `tx-off` register, interrupts 42 (MAC) and 34
  (dying-gasp, which the community tree does not declare), reset `EN7523_XPON_MAC_RST` (bit 41),
  and the GDM2 phandle the ethernet driver has to provide;
* `xpon_phy@1faf0000` -- the SerDes/PMA block with two extra register windows the stock tree
  implies, interrupt 43 (also missing from the community tree), reset `EN7523_XPON_PHY_RST`
  (bit 0);
* `pon_pcs` -- the PCS windows and interrupt 66 (again missing from the community tree);
* `tx-disable-gpios` -- GPIO 16, with the polarity explicitly unconfirmed;
* the GPON identity properties as **placeholders**: the real values are per unit and live in the
  factory block of the SPI-NAND, and the intended design is to read them at runtime. The serial is
  redacted in this repository as `<SERIAL>`.

It is **not included by the board device tree**, and it would not compile today, because the
bindings and drivers it references (`airoha,en7523-xpon`, `airoha,en7523-xpon-phy`,
`airoha,en7523-pcs`, the `pon` pinmux group) do not exist in this tree yet. Its open questions, all
unresolved: whether the `pon` pinmux function has to be added to `pinctrl-en7523.c` or made
optional in the PHY driver, and which I2C bus carries the laser (section 9).

## 9. The optical path (M3)

The board carries an Airoha/Econet LDDLA **EN7571** laser driver and BOSA (laser plus APD). The
identification comes from two independent places: the factory block holds the per-unit BOB
calibration blob, whose magic identifies the GPON profile and laser variant 1 (= EN7571 in the
public `airoha_lddla.h`), and the stock OMCI library contains the literal string `EN7571`.

Three layers from the community tree have to land: `drivers/net/optical/core.c` with
`include/linux/optical_frontend.h` (the frontend registration model);
`drivers/net/optical/airoha/en7571_*.c` (main, txrx, adcloop, ddmi, regs -- probe, the APD bias and
temperature control loops, and DDMI, with `compatible = "airoha,en7571"` and calibration from
`firmware-name`, default `airoha/en7571_bob.bin`); and `drivers/net/optical/hwmon.c`, which would
expose the DDMI values as hwmon attributes -- **temperature, supply voltage, Tx bias current, Tx/Rx
optical power**. That last layer is the measurable part of M3.

**Nothing has been probed on the optical side yet.** No `en7571` driver has been loaded on this board, no
hwmon attribute has been read, and no bias current or temperature has been obtained under OpenWrt. What
*is* known is that the DDMI path works on the vendor firmware: `/proc/pon_phy/DDMI_check_8472`
returns plausible values (supply voltage 32622, temperature 12214, Tx bias and Tx power near zero
because the laser was off), and on that firmware it goes through the **PON PHY block's internal I2C
master** rather than through `/dev/i2c-*` (the stock device has no i2c-dev nodes). That made it an open
question whether the BOSA sits on that internal bus or on the SoC's `i2c0` (base `0x1fbf8000`; the EN7571
is at address `0x70` in the public notes for the same EN7523 + MT7916 + EN7571 combination) -- and it is
now answered in favour of `i2c0`: see section 13. The polarity of the GPIO 16 TX-disable line still has to
be tried both ways -- see section 11. As of 2026-10-08 there is an answer to prefer: the community
drivers and the one public EN7523 write-up both put the EN7571 on the SoC `i2c0` as an ordinary I2C
child, and neither uses the PHY-internal master. Section 12 records the sources, and what enabling
that bus costs on this image.

## 10. Next step: four ordered jobs, each with an acceptance test

The order matters: the header shim is the only thing that unblocks the rest of the code, the
optical frontend is the cheapest thing to make observable, and OMCI is last. The acceptance tests
are deliberately the same shape as the ones in [status.md](status.md) -- a command whose output is
either right or wrong, on the device.

| # | Job | Acceptance test (falsifiable) | State |
|---|---|---|---|
| 1 | **`airoha_eth.h` / API shim.** Add the xPON types, the `airoha_eth_xpon_ops` table, the 17 dispatchers and the state fields *without* replacing the header (section 5): missing declarations go in the header, dispatchers and the EN7523 backend in `airoha_eth.c`. | `airoha_xpon.o` and `airoha_gpon_omci.o` compile with **0 errors** (currently 107 and 6), *and* `airoha_eth.o` and `airoha_ppe.o` still compile with 0 errors. Every error is a missing declaration, so this is a counting exercise, not a judgement call. | not started |
| 2 | **Optical frontend: `en7571` + hwmon.** Land `drivers/net/optical/**` and its hooks (patches 020/021), resolve which I2C bus the BOSA is on, provide the BOB calibration blob, and expose DDMI. | `en7571` probes, hwmon exposes bias/temperature, `tx_enabled=1`. Falsified if the driver does not probe, or the hwmon attributes are absent or constant. | not started |
| 3 | **PON PCS/MAC.** Land `phy-airoha-xpon.c` + `pcs-en7523.c` + the net/xpon core (patches 010/011, 032/033 and the by-hand Kconfig/Makefile hooks), wire the EN7523 backend vtable and `gdm_xpon_start/stop`, add the device tree nodes. | `pon_pcs` probes, the xPON GDM2 netdev exists, and `/proc/xpon/ponInfo` no longer reports `Mode: Error`, with LOS following the fibre. Falsified by no netdev, or by `Mode: Error` persisting. | not started |
| 4 | **OMCI.** Enable the in-kernel OMCI agent and give it the identity read from the factory partition. | `GPON netdev link ready: O5=1 OMCI=1`; the OLT accepts the ONU; OMCI MIB get/set round-trips. | not started |

Two booking rules: **do not enable the PON MAC or the laser before job 2's `tx_enabled` and
TX-disable behaviour is understood** (section 11), and record whether each result came from a
compile, a probe, or a link with an OLT -- three different levels of proof.

## 11. Hazards

* **The laser TX-disable line (GPIO 16) must never be driven blindly, and must never become
  unavailable.** An optical transmitter on a live PON that fires when it should not is a physical
  hazard: to the operator's eyes and to the upstream network (it is somebody else's fibre, shared
  with other customers). The polarity is unconfirmed, so the first experiments belong on a
  disconnected fibre, and the TX-disable path must stay available and working -- it is the only way
  to stop the laser.
* **Never write slot A, the factory block, or the trailing raw region of the SPI-NAND.** The
  factory block holds the per-unit GPON identity (serial, equipment ID) and the laser BOB
  calibration; the raw tail also holds the boot flag. Writing them destroys data that cannot be
  regenerated. The full rules are in [hardware.md](hardware.md).
* **Do not copy a BOB calibration blob from another unit.** It is this laser's bias/APC table.
* **Keep the redaction.** The GPON serial, the MAC addresses and the ISP identity are per-unit data
  and are not reproduced in this repository; use the placeholders described in
  [docs/README.md](README.md).

## 12. Prior art: who has already built this (checked 2026-10-08)

Section 10 does not change because of this section, but its *cost* does. Four independent projects
cover most of the pieces, one of them is aimed at this SoC, and one covers this board. What no
public source has is a GPON O5 state with OMCI on an **EN7523**: the two end-to-end successes are on
sibling MIPS parts.

| Project | Hardware | State (2026-10-08) | What it is worth here |
|---|---|---|---|
| [`Sirherobrine23/airoha_kernel`](https://github.com/Sirherobrine23/airoha_kernel), branch `airoha_en7523_all` | EN7523, EN7528, EN751221, EN7580 | Actively pushed (head `44641f1d`, 2026-10-08; 32 commits newer than the `3c44110a` snapshot this document was measured against) | The source this port already uses: `net/xpon` with the in-kernel OMCI agent, `drivers/net/optical` (EN7570/71/72/73), `phy-airoha-xpon.c`. The author's own caveat, on the forum: "everything is still proof of concept at en7523". |
| [`Sirherobrine23/openwrt`](https://github.com/Sirherobrine23/openwrt), branch `airoha_en7523` (`1b46c9c8`), posted as [openwrt PR #20104](https://github.com/openwrt/openwrt/pull/20104) | `airoha` target, EN7523 subtarget | Open, **draft**, 162 commits / 613 files, updated 2026-10-08 | An OpenWrt tree that already sets `CONFIG_XPON`, `CONFIG_XPON_OAM`, `CONFIG_XPON_OMCI` and `CONFIG_AIROHA_XPON_V1` for `en7523`, with ~66 board DTS. This is the Kconfig block and the DTS set to diff against. PR body: "very unstable for prodution, but working for testing". |
| [openwrt PR #24577](https://github.com/openwrt/openwrt/pull/24577) (AKoo7) | EN7528 (MIPS), JCOW407 / DASAN H660GM-A | Open, 182 files, active 2026-10-08; claims **O5, full OMCI, PPPoE and LAN NAT on live fibre** | A second, independent end-to-end implementation with the same EN7571 front-end, plus a userspace `econet-omcid` and a LuCI status app. **Licence red flag:** one of the ported files carries an EcoNet header that reads "confidential and proprietary ... strictly prohibited", so that code is not usable as GPL -- read it for shape only. |
| [`Cris7015/xr500v-openwrt`](https://github.com/Cris7015/xr500v-openwrt) | EN7526G / EN751221 (MIPS) | Release `v2026.10.07`: "O5, OMCI and PPPoE", tested end to end on a live line | The deepest public EN757x optics lab log (about 60 dated notes), and the idea of taking the ONU serial from the U-Boot environment (`gpon-serial-number`) instead of a partition. |
| [`coolsnowwolf/lede`](https://github.com/coolsnowwolf/lede) commit `f7fd86e` | vendor kmods for EN7570/71/81, AN7583 | Package `package/kernel/airoha-pon`; one variant declares `DEPENDS+=@TARGET_airoha_en7523` | Vendor GPON drivers packaged for OpenWrt, with this target's name already in the dependency. Large amount of vendor code, no EN7523 runtime evidence, licence to be checked before any use. |
| [`gilsonolegario/px3321-en7523-notes`](https://github.com/gilsonolegario/px3321-en7523-notes) | EN7523 + MT7916 + EN7571 (Zyxel PX3321-T1) | Docs only, last push 2026-09-02 | The only EN7523-specific xPON write-up: `en7571@70` on `i2c0`, the 400-byte BOB blob at `reservearea+0x140000`, `&xpon { gpon-serial-number = <&gponsn>; }`, and `/proc/xpon/ponInfo` field triage. Its own result: the MAC probes and the GTC/GEM counters tick, O1/O2 are reachable, "O3+ requires OLT + identity", "OMCI stack: not yet". |

**No EN7523 has reached O5 in public.** The working reports are EN751221 and EN7528, both MIPS, and
the "same-family EN7523 report" that PR #24577 alludes to is not public either. So everything this
repository can borrow stops at "the pieces work on the sibling silicon" -- which is a much better
place to start than a blank file, but it is not a finished port to copy.

**Upstream moved on the day of this check.** John Crispin posted
`[RFC net-next 00/12] net: add the PON subsystem`
([lore](https://lore.kernel.org/netdev/20261008143249.3439762-1-john@phrozen.org/)) on 2026-10-08: a
`net/pon` subsystem (not `net/xpon`), XGS-PON first, whose first driver is the AN7581 PON MAC and
which depends on the still-unmerged Airoha PCS series, with a userspace
[`pon-tool`](https://github.com/blogic/pon-tool) that its author says "reaches O5, passes traffic and
recovers from fiber pulls against a production OLT". Mainline today has no `net/xpon`, no
`drivers/net/optical` and no `pcs-airoha`. Two consequences for this port: keep the datapath behind
an ordinary netdev, and do not invent a private `/proc` interface, because the ABI that is going to
exist is `net/pon` plus `pon-tool`.

### 12.1 The two open questions this answered

* **Where the laser sits** (section 9). Both the community drivers and the one public EN7523 port put
  the EN7571 on the **SoC `i2c0`** (`0x1fbf8000`) at address `0x70`, as an ordinary I2C child:
  `&i2c0 { en7571: lddla@70 { compatible = "airoha,en7571"; reg = <0x70>; }; };`. That bus does not
  exist in this image: the running device tree has no `i2c` node at all, the kernel is built with
  `CONFIG_I2C=m` and `CONFIG_I2C_CHARDEV=m` only, `CONFIG_I2C_MT7621` is unset, and there is no
  `/sys/class/i2c-adapter/` on the board. The community tree adds the compatible to
  `drivers/i2c/busses/i2c-mt7621.c` (an `airoha_caps` struct and one match entry, about fifteen
  lines). Stronger evidence than the Zyxel write-up: **three EN7523 boards** in the fork's own tree
  (`askey_rtf8225vw`, `mitrastar_gpt_2742gx4x5v6`, `tplink_xx230v_v1`) all wire the same child on
  `&i2c0`, and all three feed the laser its calibration data through an **nvmem cell** instead of a
  raw flash offset -- `en7571: lddla@70 { compatible = "airoha,en7571"; reg = <0x70>;
  nvmem-cells = <&en7571_bob>; }` with `en7571_bob` carved out of the calibration area (`0xc0000`,
  `0x140000`, `0x1c0400` depending on the board). That is the shape to copy for the BOB blob.
  Verified against the raw DTS on 2026-10-08: on the Askey board the cell is
  `en7571_bob@1c0400 { reg = <0x1c0400 0xff>; }` inside the `art` UBI volume, the frontend is wired
  into the MAC with `optical-frontends = <&en7571>` plus `optical-frontend-names = "pon"`, GDM2 is
  claimed with `airoha,xpon-managed` and `openwrt,netdev-name = "pon0"` while its `pcs-handle` is
  deleted, and the GPON serial number comes from the bootloader environment (`gponsn: asp_gpon_sn`
  in the `ubootenv2` volume) rather than from a flash offset -- worth checking in this board's own
  bootloader environment when the MAC work starts. The vendor firmware's internal path through the
  PON PHY block stays the fallback.
* **How wide the API gap is** (section 5). Re-measured today: the community `airoha_eth.h` is 4,988
  lines against 801 here and `airoha_eth.c` is 10,871 against 4,700. The header now carries **20**
  names matching `airoha_eth_*xpon*()`; the 17 counted in section 5 are the `EXPORT_SYMBOL_GPL`
  dispatchers, and the previous header already had 18 of the 20 names, so only two functions are
  genuinely new (`xpon_retire_all`, `xpon_retire_channel` -- retiring a service). The surface is
  still growing, which is the argument for doing the shim once, keeping it small, and measuring it
  again before the next attempt.

### 12.2 What to read first

1. Sections 5 and 6 of this document -- the exact missing API list.
2. The community `airoha_en7523_all` tree: `net/xpon/**` and `drivers/net/optical/**`.
3. `target/linux/airoha/en7523/config-6.18` from the fork branch -- the Kconfig block, which this
   repository already carries commented out with `# M1: tat PON` next to it.
4. `px3321-en7523-notes`: `docs/gpon-next-steps.md` and `docs/optical-bob.md`, for the EN7523-specific
   optics checks and the BOB calibration location.
5. PR #24577's `econet-omcid` and `luci-app-econet-xpon`, read for shape rather than copied, and
   Cris7015's `notes/` for what an EN757x bring-up actually looks like day by day.
---

## 13. M3, step 1: turning on I2C0 to settle where the laser sits (2026-10-08)

Section 12.1 settled this question on paper; this section is the first half of settling it on hardware. The
step is deliberately the cheapest of the four remaining PON jobs: the controller needs a fifteen-line
driver variant and one device-tree node, the probe is read-only, and the answer does not need an OLT.

### 13.1 What changed

| Where | Change |
|---|---|
| `openwrt/overlay/target/linux/airoha/patches-6.18/930-52-airoha_en7523_all-i2c-mt7621-add-EN7523-SoC-support.patch` | Adopts the community `drivers/i2c/busses/i2c-mt7621.c` wholesale: it adds `struct mtk_i2c_caps` (`max_clk_div` 0xfff, atomic polling, no CFG2 register), an `airoha_caps` instance and **one** match entry `{ .compatible = "airoha,en7523-i2c", .data = &airoha_caps }`. 203 lines / 5.7 kB; the community file is 372 lines against 342 here (12 clean hunks). It applies on top of the target's own `885-i2c-mt7621-optional-reset.patch`, which touches the same file. |
| `openwrt/overlay/target/linux/airoha/dts/en7523-vgp42x6v1.dts` | Two nodes in the root block: `i2cclock: i2cclock@0` (fixed 20 MHz clock) and `i2c0: i2c0@1fbf8000` (`airoha,en7523-i2c`, `reg = <0x1fbf8000 0x100>`, `clocks = <&i2cclock>`, `clock-frequency = <100000>`, one address cell, `status = "okay"`). No pinctrl: the I2C pads keep the SoC defaults. |
| `openwrt/patches/0003-*.patch` | `CONFIG_I2C_MT7621=y`. Kconfig then clamps it to `=m`, because the target sets `CONFIG_I2C=m` -- see 13.2.3. |
| `openwrt/patches/0005-*.patch` (new) | Declares `KernelPackage/i2c-mt7621` in `target/linux/airoha/modules.mk`, so the module can actually reach the rootfs. |
| `scripts/packages.append` | `CONFIG_PACKAGE_i2c-tools=y` (for `i2cdetect`) and `CONFIG_PACKAGE_kmod-i2c-mt7621=y`. |

A useful side effect: the label `i2c0` did not exist anywhere before, so `en7523-vgp42x6v1-pon.dtsi` --
which already carries `xpon`, `xpon_phy`, `pon_pcs` and an `&i2c0 { en7571@70 { ... }; }` child -- could not
be included at all. The device tree now has the label, so enabling PON later will not have to touch the I2C
part again.

### 13.2 Three build-system traps this step walked into

**1. A whole-file guard silently dropped a new config symbol.** The kernel-config step used to test for one
symbol (`JFFS2_FS=y`) and then skip the entire append file, so a symbol added later was never applied --
the build stays green and the image is simply missing the feature. It now applies the append file symbol by
symbol and reports how many lines it added. This is the failure mode to remember: *check the payload, not
the exit code*.

**2. The stale-patch warning cried wolf.** It compared every file in `patches-6.18/` against this
repository's patch set, which flagged every patch OpenWrt itself ships (hundreds of lines). It now lists
only files that the tree's own git does not track *and* this repository does not ship -- i.e. real
hand-applied leftovers. A warning that fires on everything gets ignored, which is how a trace patch once
rode along into 21 consecutive images.

**3. A kernel symbol set to `=m` does not automatically become a kmod package.** This is the expensive one:

1. `CONFIG_I2C=m` in the target forces `CONFIG_I2C_MT7621` down to `=m` (a tristate child cannot be `=y`
   while its parent is `=m`), whatever the config file asks for.
2. OpenWrt only creates a `kmod-*` package for symbols declared explicitly in
   `package/kernel/linux/modules/*.mk` or in a target's `modules.mk`. `i2c-mt7621` is in neither, so
   nothing installed `i2c-mt7621.ko` into the rootfs.
3. Evidence: the package index listed `kmod-pwm-airoha` (declared in the airoha target's `modules.mk`) but
   not `kmod-i2c-mt7621`, and an otherwise successful image build contained only `i2c-core.ko` and
   `i2c-dev.ko`. `openwrt/patches/0005-*.patch` fixes this; selecting `kmod-i2c-mt7621` is then enough.

Worth recording for later: `kmod-i2c-core` ships **both** `i2c-core.ko` and `i2c-dev.ko` (see
`I2C_CORE_MODULES` in `package/kernel/linux/modules/i2c.mk`), and it is already selected, so `/dev/i2c-N`
exists as soon as the controller is bound -- no extra package needed.

**4. The build environment has no network access.** Any new package source has to be fetched outside and
placed in `dl/` by hand; otherwise the build fails at download with a message that looks like a source
error. (`i2c-tools` 4.4 was fetched from kernel.org this way; its sha256 matches the feed's `PKG_HASH`.)
Two further facts about this tree's build: the default target is `world`, which compiles the whole feed
(including a host Python with profile-guided optimisation, tens of minutes) even though almost none of it
is installed, and the image is assembled from a rootfs cache, so a newly selected package only enters the
image through a full `make` -- `make package/install` plus `make target/install` completes in seconds and
quietly omits it.

### 13.3 Verification so far, and what comes next

Static checks before any flash: the patched kernel sources contain `airoha_caps` and the
`airoha,en7523-i2c` match; the kernel `.config` has `CONFIG_I2C_MT7621=m`; `i2c-mt7621.o`, `i2c-mt7621.ko`
and `vmlinux` are all built; and the OpenWrt `.config` selects `kmod-i2c-mt7621`, `i2c-tools`, `libi2c` and
`kmod-i2c-core`. The image is then checked by unpacking its squashfs payload and confirming that
`i2c-mt7621.ko` and `usr/sbin/i2cdetect` are really there.

On the board the sequence is read-only: `dmesg | grep -i i2c`, `/sys/class/i2c-adapter/`, `i2cdetect -l`,
then **`i2cdetect -y -r 0`**. The `-r` matters: the default quick-write probe writes an address byte, while
`-r` only reads, and this bus may carry the laser driver. `i2cset` against `0x70` is never acceptable.
If `0x70` answers, the community wiring is right for this board too and job 2 of the port (the optical
frontend) follows `px3321-en7523-notes` and the fork's three EN7523 boards directly; if the bus is silent,
the vendor firmware's internal path through the PON PHY block is the only one left and the EN7571 driver
work has to start from the vendor binary instead. Directly relevant to that caution: the community PON
nodes declare `tx-disable-gpios = <&pinctrl 16 GPIO_ACTIVE_HIGH>`, which is the same GPIO 16 this project
already treats as untouchable.

### 13.4 Result (2026-10-08)

The bus is up and the answer matches the community: **the BOSA/EN7571 is on the SoC's I2C0 at address
`0x70`.**

| Measurement | Value |
|---|---|
| `dmesg` | `i2c_dev: i2c /dev entries driver`, `i2c-mt7621 1fbf8000.i2c0: clock 100 kHz` |
| adapter | `i2cdetect -l` lists `i2c-0  i2c  1fbf8000.i2c0  I2C adapter`; `/sys/bus/i2c/devices/i2c-0` exists |
| running device tree | `/proc/device-tree/i2c0@1fbf8000`: `compatible=airoha,en7523-i2c status=okay`, plus `i2cclock@0` |
| modules | `i2c_mt7621 12288 0`, `i2c_core 40960 3 i2c_mt7621,hwmon,i2c_dev` |
| **bus scan** | `i2cdetect -y -r 0` prints `70` in row `70:` |
| single read | `i2cget -y 0 0x70` returns `0x10` |

So the optical frontend work follows the community shape directly (`compatible = "airoha,en7571"`, BOB
through an `nvmem-cell`, `optical-frontends = <&en7571>` on the xPON node, `airoha,xpon-managed` on GDM2),
and the vendor firmware's internal path through the PON PHY block is not needed for DDMI -- it stays only
as a fallback. Two things are worth carrying forward:

* On this board `/sys/class/i2c-adapter/` does **not** exist even though the adapter is registered and
  `i2cdetect` works. Check `/sys/bus/i2c/devices/` or `i2cdetect -l` before concluding a bus is missing.
* `sha256sum` over the whole `mtd3` partition never equals the sha256 of the built image, and that is
  normal: OpenWrt appends a metadata block to the *file* (JSON with `metadata_version` and
  `supported_devices`, then an `FWx0` magic plus CRC) and `sysupgrade` does not write it to flash. Verify by
  comparing the FIT region (sized by the header's `totalsize`) and the squashfs region instead. Here the FIT
  matched byte for byte and the rootfs matched in every 1 MB chunk; only the final chunk, which holds the
  metadata, differed.

Post-flash health, for the record: kernel 6.18.54, WiFi AP up on the MT7916 with the same `mt7915e.ko` and
eeprom hashes as the previous image, overlay preserved, vendor slot A untouched (`1.2.00.241216`),
AIROHA-TRACE count 0, and no new warnings in `dmesg`.

### 13.5 Reading the DDMI registers read-only (2026-10-08): why the manual part stops here

With approval, the diagnostic address range `0x00..0x7F` was read one register at a time. Each read is a
register-address write followed by a data read; no data byte was ever written, and nothing at or above
`0x80` (where the control and calibration registers of such devices live) was touched. The range is mostly
zero with a handful of populated registers:

```
00: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
10: 00 ff 0f 00 00 00 00 00 00 00 00 00 00 00 00 00
20: 00 ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00
30: 00 02 3f 00 00 00 00 00 00 00 00 00 00 00 00 00
40: 96 02 b8 00 00 00 00 00 00 00 00 00 00 00 00 00
50: (all zero)
60: 00 00 5a 00 00 00 00 00 00 00 00 00 00 00 00 00
70: 00 00 b4 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Two conclusions:

* The device is real and answers properly: it is not a stuck bus returning `0xff`, and the populated
  registers (`0x11=ff`, `0x12=0f`, `0x21=ff`, `0x31=02`, `0x32=3f`, `0x40=96`, `0x42=b8`, `0x62=5a`,
  `0x72=b4`) are a useful fingerprint to compare against the community `en7571` / `airoha_lddla` driver.
* The layout is **not** an SFF-8472 diagnostic page: temperature, supply voltage and bias all read back as
  zero across `0x60..0x7F`, and none of the values the vendor firmware reported for this unit (supply
  voltage 32622, temperature 12214) appear anywhere in the range.

The most likely explanation is that the EN7571 needs its BOB calibration loaded -- and possibly a page
selected through a control register -- before the diagnostic area means anything. Loading the BOB is a write,
and it must be done by a driver using this unit's own calibration blob, not by a manual poke. That is a
deliberate stopping point for the read-only investigation: the next step is the `en7571` driver and its
hwmon exposure, which is where those writes belong.

## 14. M3 step 2: bringing up the `en7571` optical frontend driver (2026-10-09)

Read-only probing is over: the frontend driver is the component that owns the BOSA from here on, and its
bring-up path writes to the part. This section records what the port needs and the traps found while wiring it
into the build.

### 14.1 The driver is independent of the xPON MAC, so it can come first

`drivers/net/optical/` (framework) plus `drivers/net/optical/airoha/` (`airoha_lddla` = core + `en7571_*`)
build and register without any of the xPON stack: `lddla_frontend_register()` only needs the
`optical_frontend` framework.

* `OPTICAL_FRONTEND` (tristate) and, via the `OPTICAL_FRONTEND_HWMON` bool, the hwmon class exposure.
* `AIROHA_LDDLA_PHY` (tristate, `depends on I2C`, `select FW_LOADER`, `select PHY_COMMON_PROPS`,
  `select OPTICAL_FRONTEND`) with per-chip booleans `EN7570_PHY` / `EN7571_PHY` / `EN7572_PHY` / `GN25L95_PHY`.
* `PHY_COMMON_PROPS` already exists in 6.18.54 (`drivers/phy/Kconfig:8`), so no Kconfig fix is needed.

`probe()` reads `firmware-name` (default `airoha/en7571_bob.bin`), then runs `en7571_detect()` ->
`lddla_bob_load()` -> `en7571_init()` -> `lddla_frontend_register()` -> a 1 Hz `tick_work`. Anything that fails
before the frontend registration means "no DDMI", and `en7571_detect()` is the gate: it reads
`EN7571_FT_ADC_CLK_CLR` and `EN7571_DUMMY` and requires `id1 == 0x03` and `id2 >= 0x03`. Both registers live
above `0x7F`, i.e. outside the range that was probed by hand, so a mismatch would only show up in `dmesg` as
`EN7571 silicon not found`.

### 14.2 The BOB blob matches the format the driver parses

`lddla_bob_load()` tries an nvmem cell named `calibration` first and falls back to the firmware file. The
comment on the function states the magic lives at byte `0x94` of the image and identifies both the chip family
and the 32-bit word endianness of the source. This unit's blob -- extracted from the factory block at absolute
`0x6F00000 + 0x497`, which is *outside* the `reservearea` partition -- is 400 B and has `01 07 05 07` at
`0x94`. So the file is used as-is, no re-packing, and no nvmem cell is declared. A missing BOB is non-fatal in
the driver (it leaves an erased mirror) but a malformed or wrong-chip one is rejected.

The blob is per-unit calibration data and is not published; it is installed into the image at
`/lib/firmware/airoha/en7571_bob.bin`. `*.bin` is in `.gitignore`, so it cannot reach this repository by
accident -- which is also why the exact bytes are not quoted here.

### 14.3 Build traps hit while adding it

1. **Two `drivers/net` hooks are needed.** `drivers/net/optical/**` is a new directory, so the framework is
   invisible to the build until `drivers/net/Kconfig` sources it and `drivers/net/Makefile` descends into it,
   even though `target/linux/<target>/files/` already contains the source (that overlay is copied *before*
   patches are applied, which is why the files exist but nothing gets built). Handled by `930-53` (Kconfig) and
   `930-54` (Makefile), one hunk each against upstream context.
2. **`=m` kernel symbols need an explicit kmod package.** `CONFIG_I2C=m` in the target clamps
   `AIROHA_LDDLA_PHY` to `=m`, and a bare `=m` symbol only produces a `.ko` inside the kernel tree -- no
   package installs it into the rootfs. Both packages are declared in `target/linux/airoha/modules.mk`
   (`kmod-optical-frontend`, `kmod-airoha-lddla`) and selected in `.config`. Without them the image still
   builds "successfully" and ships without the driver.
3. **An idempotence guard can silently swallow new packages.** The project's apply script appended
   `modules.mk` only `if grep -q KernelPackage/i2c-mt7621` -- a condition that was already true from the
   previous image, so the two new package blocks were never written and `make defconfig` then dropped the two
   `CONFIG_PACKAGE_kmod-*` lines (surfacing as `PACKAGES_FAIL`, with the feed's pre-existing
   `luci-app-weechat` / `squeezelite` recursion errors as decoys in the same output). The fix is to restore the
   file from git and append the whole list again, so the step is idempotent *and* always current.

### 14.4 Laser safety during bring-up

The driver does not merely read: `en7571_init()` loads TX calibration data and a TX shutdown level, and the
1 Hz tick runs an APC/compensation loop that writes bias values. The board's TX-disable line is GPIO16 in the
stock LED map (`LED_PHY_TX_POWER_DISABLE`), and Linux does not claim it -- `/sys/kernel/debug/gpio` lists only
gpio-0 (reset), gpio-1/6/10/27 (LEDs) and gpio-7 (WPS). Nothing in this DTS can therefore guarantee a dark
laser; that rests on the BOSA's own power-up state and on the TX gate a PON MAC would drive, which this image
does not have yet. Bring-up is done with the fibre unplugged and the port dark.

### 14.5 Verified on hardware with img25 (2026-10-08) -- first DDMI that means something

**Image:** `42X6_openwrt_6.18.54_img25_en7571_sysupgrade.bin` (9,437,473 B, md5 `a60bb3ecfc8ffaf42a1a045a9d2cc5ee`, sha256 `4bc52f9691179f75b52eb50357f7325d00fa74771c3efd82c9b1feeadf708926`). `SQFS_OFFSET = 3801088 = 0x3A0000` (FIT-SPLIT OK), 1214 squashfs entries. Offline `verify_img_sqfs.sh` already reported the payload before flashing: `optical_frontend.ko` (16,216 B), `airoha_lddla.ko` (40,660 B), `lib/firmware/airoha/en7571_bob.bin` 400 B md5 `61f90dec6a394f914bc6b56b7101e372` (per-unit blob, not in git), autoload entries `airoha-lddla` + `optical-frontend`, and no `airoha_xpon.ko` -- by design M3 step 2 is decoupled from xPON.

Board was flashed over HTTP (`python -m http.server` on the PC, `uclient-fetch` on the board, sha256 checked) into `mtd3` (`tclinux_slave`) with overlay kept (no `-n`). Reboot in ~15 s (`Connection failed`/`rc=246` is normal). Slot A vendor `1.2.00.241216` untouched, overlay intact (`/dev/ubi0_0` + `overlayfs`, 12 files in `/etc/config`), WiFi `phy0-ap0` ESSID "OpenWrt", LEDs `blue:power=1`/`blue:inet=0`/`green:pon=0`/`red:los=0`, `AIROHA-TRACE` 0, load ~0.3, `dmesg` only the two known harmless lines.

**Driver probe -- first try, success:**

```
[14.998071] en7571 0-0070: loaded 400-byte little-endian BOB from airoha/en7571_bob.bin: magic 0x07050701, chip-id 0x01, profile 0x07
[15.223361] en7571 0-0070: EN7571 TxSD calibrated: offset=196 tiaflt=203 tiasd=180 pav_d=183 threshold=0x046
[15.248782] en7571 0-0070: EN7571 initialised: GPON, rev 2, KT1, DDMI1
```

* `en7571_detect()` passed, so `id1 == 0x03`, `id2 >= 0x03` -- the two ID registers live above `0x7F`, hence invisible to the earlier hand probe, and no "EN7571 silicon not found". Chip is EN7571 rev 2.
* 400 B little-endian BOB, magic `0x07050701` at byte `0x94` (the format `lddla_bob_import()` checks), chip-id `0x01`.
* `TxSD calibrated` and `initialised: GPON, rev 2, KT1, DDMI1` -- APC/KT loop running, DDMI on.

**Frontend + hwmon:**

* `/sys/class/optical_frontend/frontend0` -- `present=1`, `ready=1`, `model=EN7571-LDDLA`, `vendor=Airoha`, `type=lddla`, `capabilities=0x47f`, `alarms=0x15` (the "min" alarms for bias/tx/rx while the laser is off).
* `/sys/class/hwmon/hwmon0` (`name=en7571`): `temp1_input 41292 -> 42170` (41.3 C -> 42.2 C after 20 s, rising, so the BOSA is really being read), `in0_input 3263` mV (3.263 V, matches the 32622 the stock firmware reported for this unit within 0.4 mV at 0.1 mV units), `curr1_input 0`, `power1_input 0`, `power2_input 0` with `curr1_min_alarm`/`power*_min_alarm = 1` -- correct with the laser off and no fibre. Thresholds `temp1_max 85000`/`min -5000`, `in0 2900-3700 mV` look sane.
* `i2cdetect` now shows `70: UU` and `i2cget 0x70` returns `Resource busy` -- correctly claimed by the driver.
* `GPIO16` (TX-disable) is still unclaimed -- `/sys/kernel/debug/gpio` lists only gpio-0/1/6/7/10/27 -- so the dark state rests on the BOSA power-up and the PON MAC burst gate (not yet present). Fibre stays unplugged.

The SFF-8472-shaped `0x60..0x7F` window that read all zero by hand now means something after init+BOB: temperature and voltage are readable and match the stock numbers. M3 step 2 is done; next is the xPON MAC/PCS/OMCI (M3 steps 3-4, `airoha_eth` + `pon_pcs` + `xpon`/`xpon_phy`).
