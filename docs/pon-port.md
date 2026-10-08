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

**Nothing has been probed.** No `en7571` driver has ever been loaded on this board, no hwmon
attribute has been read, and no bias current or temperature has been obtained under OpenWrt. What
*is* known is that the DDMI path works on the vendor firmware: `/proc/pon_phy/DDMI_check_8472`
returns plausible values (supply voltage 32622, temperature 12214, Tx bias and Tx power near zero
because the laser was off), and it goes through the **PON PHY block's internal I2C master**, not
through `/dev/i2c-*` (the device has no i2c-dev nodes). So the open question is whether the BOSA
sits on that internal bus or on the SoC's `i2c0` (base `0x1fbf8000`; the EN7571 is at address
`0x70` in the public notes for the same EN7523 + MT7916 + EN7571 combination). The device tree
cannot be finalised until that is settled, and the polarity of the GPIO 16 TX-disable line has to
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
| [`Sirherobrine23/airoha_kernel`](https://github.com/Sirherobrine23/airoha_kernel), branch `airoha_en7523_all` | EN7523, EN7528, EN751221, EN7580 | Actively pushed (head `44641f1d`, 2026-10-08; ~33 commits newer than the `3c44110a` snapshot this document was measured against) | The source this port already uses: `net/xpon` with the in-kernel OMCI agent, `drivers/net/optical` (EN7570/71/72/73), `phy-airoha-xpon.c`. The author's own caveat, on the forum: "everything is still proof of concept at en7523". |
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
  lines). The vendor firmware's internal path through the PON PHY block stays the fallback.
* **How wide the API gap is** (section 5). Re-measured today: the community `airoha_eth.h` is 4,988
  lines against 801 here, `airoha_eth.c` is 10,871 against 4,700, and the header exports **20**
  `airoha_eth_*xpon*()` entry points, not 17. The surface is still growing, which is the argument for
  doing the shim once, keeping it small, and measuring it again before the next attempt.

### 12.2 What to read first

1. Sections 5 and 6 of this document -- the exact missing API list.
2. The community `airoha_en7523_all` tree: `net/xpon/**` and `drivers/net/optical/**`.
3. `target/linux/airoha/en7523/config-6.18` from the fork branch -- the Kconfig block, which this
   repository already carries commented out with `# M1: tat PON` next to it.
4. `px3321-en7523-notes`: `docs/gpon-next-steps.md` and `docs/optical-bob.md`, for the EN7523-specific
   optics checks and the BOB calibration location.
5. PR #24577's `econet-omcid` and `luci-app-econet-xpon`, read for shape rather than copied, and
   Cris7015's `notes/` for what an EN757x bring-up actually looks like day by day.
