# PON (xPON + optical frontend) for vGP-42X6V1 - port plan

Source: the community tree **`Sirherobrine23/airoha_kernel` @ `airoha_en7523_all`** (kernel 6.18.44).
This is a *mainline-style rewrite*, not vendor code. Get a clone of it first:

```bash
git clone -b airoha_en7523_all --depth 1 \
    https://github.com/Sirherobrine23/airoha_kernel.git
```

`apply-pon.sh` copies files out of that clone, so it needs the path to it.

**Status: the material compiles, it does not run.** Every object here was compiled individually
against the pinned Linux 6.18.54 tree: **32 of 34 are clean** (`net/xpon` 14/14,
`drivers/net/optical` 15/15, the airoha xPON PHY and the EN7523 PCS). The remaining two
(`airoha_xpon.o`, `airoha_gpon_omci.o`) fail **only** because of `airoha_eth.h`. Nothing has been
linked, loaded, probed or run: there is no PON link, no `en7571` probe and no OMCI session. The
full analysis -- the two experiments that isolated the blocker, the corrected size of the job and
the ordered next steps with acceptance tests -- is in
[docs/pon-port.md](../../docs/pon-port.md). Read that before spending time here.

## 1. Survey results for the OpenWrt tree (main `4fed8d3`, target `airoha`)

| Component | Present in OpenWrt? | Notes |
|---|---|---|
| `net/xpon/**` (including the in-kernel OMCI agent) | no | must be added |
| `drivers/net/optical/**` (framework + EN7570/71/72 + airoha_lddla) | no | must be added (together with the hooks in `drivers/net/{Kconfig,Makefile}`) |
| `drivers/net/ethernet/airoha/airoha_xpon.c` + `airoha_ploam.*` + `airoha_gpon_omci.*` | no | must be added |
| `drivers/phy/airoha/phy-airoha-xpon.c` | no (but the **directory already exists**) | OpenWrt patch `220-06` already created `drivers/phy/airoha/` |
| `drivers/net/pcs/airoha/{pcs-airoha-common.c,pcs-airoha.h}` | yes | patches `310-09`/`604-01` create the same names, and this repository's `930-46` adds `pcs-en7523.c` itself |
| `include/dt-bindings/reset/airoha,en7523-reset.h` (has `EN7523_XPON_PHY_RST=0`, `EN7523_XPON_MAC_RST=41`) | yes | already defined by OpenWrt patch `600-11` - **no reset patch needed** |
| `drivers/pinctrl/airoha/pinctrl-en7523.c` | yes (but **different from the community version**) | OpenWrt uses the pinctrl v7.3 series (`202-20...202-28`); the `pon` function may not be there yet |
| PON node in `dts/en7523.dtsi` | no | add it through a board overlay (see `../overlay/target/linux/airoha/dts/en7523-vgp42x6v1-pon.dtsi`) |
| EN7523 ethernet + PCS | yes | `../overlay/target/linux/airoha/patches-6.18/930-42..930-51-airoha_en7523_all-*` adds `airoha,en7523-eth`, the GDM ports and the EN7523 PCS (including PON serdes) |
| xPON hooks in `airoha_eth.c` | no | **this is what is left** - section 3 |

## 2. New files to copy (handled automatically by the `apply-pon.sh` script)

```
net/xpon/**                                   -> target/linux/airoha/files/net/xpon/
include/net/xpon.h, include/net/xpon/{oam,omci}.h
include/uapi/linux/xpon.h                     (and include/uapi/linux/omci.h - see section 5)
include/linux/optical_frontend.h
include/linux/phy/phy-airoha-xpon.h
drivers/net/optical/**                          (core.c, hwmon.c, airoha/**, semtech/gn25l95.c)
drivers/phy/airoha/phy-airoha-xpon.c
drivers/net/pcs/airoha/pcs-en7523.c
drivers/net/ethernet/airoha/airoha_xpon.{c,h}
drivers/net/ethernet/airoha/airoha_ploam.{c,h}
drivers/net/ethernet/airoha/airoha_gpon_omci.{c,h}
Documentation/devicetree/bindings/net/{airoha,en7523-xpon.yaml,omci.yaml,optical-frontend.yaml}
Documentation/devicetree/bindings/phy/airoha,en7523-xpon-phy.yaml
```

OpenWrt already supports the `target/linux/<target>/files/` mechanism = **kernel source file
overlay** (so no "create file" patch is needed).

## 3. The part that must be ported by hand: the xPON hooks in `airoha_eth.c`

`airoha_xpon.c` calls **17** functions that this tree does not have (the widely quoted "14" comes
from `airoha_xpon.c` alone; `airoha_gpon_omci.c` adds three more -
`airoha_eth_xpon_control_start()`, `airoha_eth_xpon_control_stop()`, `airoha_eth_xmit_xpon_oam()`):

```
airoha_eth_register_xpon()            airoha_eth_unregister_xpon()
airoha_eth_register_xpon_oam()        airoha_eth_unregister_xpon_oam()
airoha_eth_set_xpon_mode()            airoha_eth_set_xpon_datapath()
airoha_eth_set_xpon_tcont_channel()   airoha_eth_get_xpon_netdev()
airoha_eth_xpon_add_service()         airoha_eth_xpon_del_service()
airoha_eth_xpon_flush_services()      airoha_eth_xpon_has_gem_service()
airoha_eth_xpon_update_link()         airoha_eth_xpon_dump_oam_rx_state()
```

Two options:

| # | Approach | Pros | Cons |
|---|---|---|---|
| **A** | Keep OpenWrt's `airoha_eth.c` and port **only** the xPON hooks (manual patch) | keeps this target's patches | laborious; you must understand the GDM2/PPE datapath |
| **B** | Replace it with the community tree's `airoha_eth.c` (+ Kconfig/Makefile) | fast, already proven to work with xpon | **rejected by measurement** - see below |

**Option A is the only one left standing**, and the reason is not the hook list. The blocker is
`airoha_eth.h`: the in-tree header is **744 lines**, the community one **4805 lines**, and it is
*not* a superset - dropping it in fixes the two xPON objects and breaks `airoha_eth.c` and
`airoha_ppe.c`. Taking the whole community cluster instead (option B) drags in phylink drift and
`mtk_wed.h`, and every `patches-6.18` patch that touches those two files was dry-run against it:
1 applied, 50 refused. Measurements, error text and the corrected estimate (**~700-1300 lines of
glue, not "14 hooks"**) are in [docs/pon-port.md](../../docs/pon-port.md) sections 5 and 6.

The one thing that makes an incremental patch defensible: the three ported `.c` files never
dereference the driver's structures (only `dev->of_node` and `dev->fwnode`).

## 4. Pinctrl / DT binding - divergences that need a decision

- The community tree uses node `system-controller@1fbf0200` (`syscon`,`simple-mfd`) -> a child
  `pinctrl`, with group `pon_pinctrl: pon { mux { function = "pon"; groups = "pon"; } }`.
- OpenWrt `dts/en7523.dtsi` **has no** pinctrl node (only `gpio0`/`gpio1` of the
  `airoha,en7523-gpio` kind), but it **does have** the `pinctrl-en7523.c` driver (v7.3 series), so
  one of the two is needed:
  - **(a)** add a syscon+pinctrl node for EN7523 (like the community tree) and add the `pon`
    function/group to `pinctrl-en7523.c`, or
  - **(b)** make `pinctrl-0` *optional* in `phy-airoha-xpon.c` (`devm_pinctrl_get()` NULL => skip)
    and configure the PON pins some other way (bootloader/SCU).
- Laser/DDMI: on the real stock unit, DDMI goes through the **internal I2C of the PON PHY block**
  (`/proc/pon_phy/debug` -> `phy_i2c_div_clock`), **not** through `/dev/i2c-*`, so which bus
  `airoha,en7571` sits on has to be determined before the DTS is finalised (see
  `../overlay/target/linux/airoha/dts/en7523-vgp42x6v1-pon.dtsi`).

## 5. Apply order

**CORRECTION (measured during a real build):** OpenWrt copies `target/linux/<target>/files/` into
`$(LINUX_DIR)` **BEFORE** it applies the patches. That means:

- OK - **new files** may be overlaid (no patch touches them): `net/xpon/**`,
  `drivers/net/optical/**`, `include/linux/soc/airoha/*`, `drivers/phy/airoha/phy-airoha-xpon.c`,
  `airoha_xpon.*`, `airoha_ploam.*`, `airoha_gpon_omci.*`.
- NOT OK - files that OpenWrt also patches **cannot** be overlaid (`airoha_eth.c/.h`,
  `airoha_ppe.c`, the `Kconfig`/`Makefile` of `drivers/net/ethernet/airoha`,
  `drivers/net/pcs/airoha`, `drivers/phy/airoha`) - the patch will fail (already seen:
  `096-v6.19-net-airoha-...` Hunk #1 FAILED on `airoha_eth.c`). `pcs-en7523.c` is in this category
  too: this repository's `930-46` patch creates that exact path.

```bash
# from the root of a checkout of this repository
./scripts/apply-overlay.sh /path/to/openwrt --with-pon
# --with-pon runs openwrt/pon/apply-pon.sh (stage 2), which also needs the
# community clone: AIROHA_KERNEL_SRC=/path/to/airoha_kernel
```

`apply-pon.sh` will: copy 66 new files into `target/linux/airoha/files/`, **stage** 6 hook patches
into `target/linux/airoha/pon-patches/` (deliberately **not** inside `patches-6.18/` - because our
patches target the kernel tree **after** OpenWrt has applied its own patches), then print a
checklist of the manual work.

The six are: `010-net-Kconfig-xpon.patch`, `011-net-Makefile-xpon.patch`,
`020-drivers-net-Kconfig-optical.patch`, `021-drivers-net-Makefile-optical.patch`,
`032-airoha-Kconfig-xpon-minimal.patch`, `033-airoha-Makefile-xpon-minimal.patch`. How to apply
them (manual, after `make target/linux/prepare V=s`):

```bash
KDIR=$(ls -d build_dir/target-*/linux-airoha*/linux-6.*)
for p in target/linux/airoha/pon-patches/*.patch; do
    git -C "$KDIR" apply --3way --whitespace=nowarn "$p" || echo "MANUAL FIX: $p"
done
```

One known gap in that flow, still open:

- **`032-airoha-Kconfig-xpon-minimal.patch` does not apply** to the prepared tree - it leaves a
  `Kconfig.rej`, so `CONFIG_AIROHA_XPON_V1` does not exist in any Kconfig and the driver cannot be
  selected. Regenerate it against the prepared `drivers/net/ethernet/airoha/Kconfig` (the context
  lines moved when the EN7523 Ethernet series was applied). The other five hooks are fine
  (`git apply --check` passes against a vanilla v6.18).
- Fixed after the measurement: `include/uapi/linux/omci.h` was missing from `NEW_FILES`.
  `include/net/xpon/omci.h` includes it, so without it 8 objects failed with
  `fatal error: uapi/linux/omci.h: No such file or directory`. The file exists in the community
  tree (392 lines) and is now part of the copy set (67 files).

## 6. What applying this does, and does not, do

It compiles most of the material and it stages the plumbing. It does **not** give a working PON
link, and today it does not even build the xPON objects, because the `airoha_eth.h` API shim does
not exist and `CONFIG_AIROHA_XPON_V1` cannot be selected. The ordered work that fixes that is in
[docs/pon-port.md](../../docs/pon-port.md) section 10.

**Hazards.** Never drive **GPIO 16** (the laser TX-disable line) without knowing the polarity, and
never make it unavailable: an optical transmitter that fires on a live PON when it should not is a
physical hazard to the operator's eyes and to the upstream network. The laser BOB calibration is
per unit and must not be copied from another device. And never write slot A, the factory block or
the trailing raw region of the SPI-NAND - see [docs/hardware.md](../../docs/hardware.md).

## 7. Verification status

| Item | Status |
|---|---|
| Enumerate files/dependencies from the community tree | yes - accurate down to each file name (66 new files) |
| Object-by-object compile against 6.18.54 | **yes - 32/34 clean** (details above and in [docs/pon-port.md](../../docs/pon-port.md)) |
| 6 minimal hook patches (net x2, drivers/net x2, airoha Kconfig/Makefile x2) | 5 of 6 - `git apply --check` OK on vanilla Linux v6.18, but `032` was measured **not** to apply to the prepared tree (`Kconfig.rej`) |
| "Whole-file" diff of the community tree | no - **rejected**: the community tree is not vanilla 6.18 (it adds `ETHERNET_PACKET_MANGLE`, `FWNODE_PCS`, `PCS_MTK_USXGMII`, `RFKILL_FULL`, and rewrites the airoha Kconfig) => kept in `reference/` as evidence |
| `drivers/net/pcs/airoha` + reset bindings | yes by OpenWrt/`930-46`; the community `pcs-en7523.c` needs its PCS-provider API updated for 6.18.54 (done, see docs/pon-port.md section 4) |
| `airoha_eth.c` hooks (17 APIs), `pon` pinmux | no - not ported; this is the remaining work (20 APIs in the community header as of 2026-10-08) |
| Anything linked, loaded, probed or run on the device | **no - nothing at all** |

The laser bus question in section 4 is settled by the community sources and the one public EN7523
port: the `en7571` is an ordinary I2C child at address `0x70` on the SoC `i2c0` (`0x1fbf8000`),
which this image does not have yet (no `i2c` node, `CONFIG_I2C_MT7621` unset); the community patch
is about fifteen lines in `drivers/i2c/busses/i2c-mt7621.c`. Survey of the prior art, including the
EN7528 end-to-end implementation and the upstream `net/pon` RFC of 2026-10-08:
[docs/pon-port.md](../../docs/pon-port.md) section 12.
