# PON (xPON + optical frontend) for vGP-42X6V1 - port plan

Source: the community tree **`Sirherobrine23/airoha_kernel` @ `airoha_en7523_all`** (kernel 6.18.44).
This is a *mainline-style rewrite*, not vendor code. Get a clone of it first:

```bash
git clone -b airoha_en7523_all --depth 1 \
    https://github.com/Sirherobrine23/airoha_kernel.git
```

`apply-pon.sh` copies files out of that clone, so it needs the path to it.

## 1. Survey results for the OpenWrt tree (main `4fed8d3`, target `airoha`)

| Component | Present in OpenWrt? | Notes |
|---|---|---|
| `net/xpon/**` (including the in-kernel OMCI agent) | no | must be added |
| `drivers/net/optical/**` (framework + EN7570/71/72 + airoha_lddla) | no | must be added (together with the hooks in `drivers/net/{Kconfig,Makefile}`) |
| `drivers/net/ethernet/airoha/airoha_xpon.c` + `airoha_ploam.*` + `airoha_gpon_omci.*` | no | must be added |
| `drivers/phy/airoha/phy-airoha-xpon.c` | no (but the **directory already exists**) | OpenWrt patch `220-06` already created `drivers/phy/airoha/` |
| `drivers/net/pcs/airoha/{pcs-airoha-common.c,pcs-airoha.h}` | yes | OpenWrt patches `310-09`/`604-01` create the same names => only `pcs-en7523.c` needs to be added |
| `include/dt-bindings/reset/airoha,en7523-reset.h` (has `EN7523_XPON_PHY_RST=0`, `EN7523_XPON_MAC_RST=41`) | yes | already defined by OpenWrt patch `600-11` - **no reset patch needed** |
| `drivers/pinctrl/airoha/pinctrl-en7523.c` | yes (but **different from the community version**) | OpenWrt uses the pinctrl v7.3 series (`202-20...202-28`); the `pon` function may not be there yet |
| PON node in `dts/en7523.dtsi` | no | add it through a board overlay (see `../dts/en7523-vgp42x6v1-pon.dtsi`) |
| `airoha_eth.c` has xPON hooks | no | **this is the largest part** - see section 3 |

## 2. New files to copy (handled automatically by the `apply-pon.sh` script)

```
net/xpon/**                                   -> target/linux/airoha/files/net/xpon/
include/net/xpon.h, include/net/xpon/{oam,omci}.h
include/uapi/linux/xpon.h
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

OpenWrt already supports the `target/linux/<target>/files/` mechanism = **kernel source file overlay**
(so no "create file" patch is needed).

## 3. Part that must be ported by hand: xPON hooks in `airoha_eth.c` - WARNING

`airoha_xpon.c` calls **14 APIs** that the OpenWrt tree *does not have*:

```
airoha_eth_register_xpon()            airoha_eth_unregister_xpon()
airoha_eth_register_xpon_oam()        airoha_eth_unregister_xpon_oam()
airoha_eth_set_xpon_mode()            airoha_eth_set_xpon_datapath()
airoha_eth_set_xpon_tcont_channel()   airoha_eth_get_xpon_netdev()
airoha_eth_xpon_add_service()         airoha_eth_xpon_del_service()
airoha_eth_xpon_flush_services()      airoha_eth_xpon_has_gem_service()
airoha_eth_xpon_update_link()         airoha_eth_xpon_dump_oam_rx_state()
```

Get them from the community tree:

```bash
SRC=/path/to/airoha_kernel
git -C "$SRC" show HEAD:drivers/net/ethernet/airoha/airoha_eth.c \
  | grep -n 'xpon' > /tmp/airoha_eth_xpon_hits.txt
```

Two options:

| # | Approach | Pros | Cons |
|---|---|---|---|
| **A** | Keep OpenWrt's `airoha_eth.c` and port **only** the xPON hooks (manual patch) | keeps OpenWrt's ~60 v7.x patches | laborious, conflict-prone; you must understand the GDM2/PPE datapath |
| **B** | Replace it with the community tree's `airoha_eth.c` (+ Kconfig/Makefile) | fast, already proven to work with xpon | loses some of OpenWrt's v7.x patches; Kconfig is rewritten (adds `NET_AIROHA_SOC_WED`, `NET_AIROHA_WHNAT`, drops the `NET_DSA` dependency) |

Recommendation: **A** for the upstream-friendly branch, **B** for a fast bring-up on the lab bench.

## 4. Pinctrl / DT binding - divergences that need a decision

- The community tree uses node `system-controller@1fbf0200` (`syscon`,`simple-mfd`) -> a child
  `pinctrl`, with group
  `pon_pinctrl: pon { mux { function = "pon"; groups = "pon"; } }`.
- OpenWrt `dts/en7523.dtsi` **has no** pinctrl node (only `gpio0`/`gpio1` of the `airoha,en7523-gpio`
  kind), but it **does have** the `pinctrl-en7523.c` driver (from the v7.3 series) => one of the two is
  needed:
  - **(a)** add a syscon+pinctrl node for EN7523 (like the community tree) and add the `pon`
    function/group to `pinctrl-en7523.c`, or
  - **(b)** modify `phy-airoha-xpon.c` so that `pinctrl-0` is *optional* (`devm_pinctrl_get()` NULL => skip)
    and configure the PON pins some other way (bootloader/SCU).
- Laser/DDMI: on the real stock unit, DDMI goes through the **internal I2C of the PON PHY block**
  (`/proc/pon_phy/debug` -> `phy_i2c_div_clock`), **not** through `/dev/i2c-*` => we must determine which
  bus `airoha,en7571` sits on before finalizing the DTS (see `../dts/en7523-vgp42x6v1-pon.dtsi`).

## 5. Apply order

**CORRECTION (measured during a real build on 2026-10-03):** OpenWrt copies `target/linux/<target>/files/`
into `$(LINUX_DIR)` **BEFORE** it applies the patches. That means:
- OK - **new files** may be overlaid (no patch touches them): `net/xpon/**`, `drivers/net/optical/**`,
  `include/linux/soc/airoha/*`, `drivers/phy/airoha/phy-airoha-xpon.c`,
  `drivers/net/pcs/airoha/pcs-en7523.c`, `airoha_xpon.*`, `airoha_ploam.*`, `airoha_gpon_omci.*`.
- NOT OK - files that OpenWrt also patches **cannot** be overlaid (`airoha_eth.c/.h`, `airoha_ppe.c`, the
  `Kconfig`/`Makefile` of `drivers/net/ethernet/airoha`, `drivers/net/pcs/airoha`, `drivers/phy/airoha`) -
  the patch will fail
  (already seen: `096-v6.19-net-airoha-...` Hunk #1 FAILED on `airoha_eth.c`).
- To replace the whole driver cluster (option B): you must **disable 73/147 patches** of the target
  (64 `drivers/net/ethernet/airoha` + 4 `drivers/net/pcs/airoha` + 4 `drivers/phy/airoha` +
  1 `include/linux/soc/airoha`), and only then overlay. Details: `temp/_logs/openwrt_build_20261003.txt`.

```bash
cd projects/econet-42x6/openwrt
./apply-to-openwrt.sh /path/to/openwrt --with-pon
```

`apply-pon.sh` will: copy 66 new files into `target/linux/airoha/files/`, **stage** 6 hook patches into
`target/linux/airoha/pon-patches/` (deliberately **not** left inside `patches-6.18/` - because our patches
target the kernel tree **after** OpenWrt has applied its ~180 patches), then print a checklist of the
manual work.

How to apply the patches (manual, after `make target/linux/prepare V=s`):

```bash
KDIR=$(ls -d build_dir/target-*/linux-airoha*/linux-6.*)
for p in target/linux/airoha/pon-patches/*.patch; do
    git -C "$KDIR" apply --3way --whitespace=nowarn "$p" || echo "MANUAL FIX: $p"
done
```

## 6. Verification status

| Item | Status |
|---|---|
| Enumerate files/dependencies from the community tree | yes - accurate down to each file name (66 new files) |
| 6 minimal hook patches (net x2, drivers/net x2, airoha Kconfig/Makefile x2) | yes - **`git apply --check` OK on vanilla Linux v6.18** |
| "Whole-file" diff of the community tree | no - **rejected**: the community tree is not vanilla 6.18 (it adds `ETHERNET_PACKET_MANGLE`, `FWNODE_PCS`, `PCS_MTK_USXGMII`, `RFKILL_FULL`, and rewrites the airoha Kconfig) => kept in `reference/` as evidence |
| `drivers/net/pcs/airoha` + reset bindings | yes - OpenWrt already has them => only `pcs-en7523.c` + the symbol need to be added (manual) |
| `airoha_eth.c` hooks (14 APIs), `pon` pinmux | no - not ported yet; needs a prepared kernel tree + a Linux build host |
| Apply the patches to the already-patched OpenWrt kernel tree | no - not run yet (needs `make target/linux/prepare`) |
