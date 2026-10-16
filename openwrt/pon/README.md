# PON (xPON + optical frontend) for vGP-42X6V1 -- route A

Source: the community tree
[`Sirherobrine23/airoha_kernel`](https://github.com/Sirherobrine23/airoha_kernel),
branch `airoha_en7523_all` (kernel 6.18.44). This is a *mainline-style
rewrite*, not vendor code. The vendor firmware's own `xpon.ko` is not a
shortcut: it targets kernel 4.4.115, so its ABI does not match 6.18.

**Route A in one paragraph:** the xPON stack is ported into OpenWrt as a
normal kernel patch series that OpenWrt applies by itself during the build
(`930-55`..`930-60` hook the new subsystems in, `940-01`..`940-06` port the
Ethernet/PCS glue, `950-xx` carry the EN7523 bring-up fixes), selected by
`openwrt/pon/buildroot-patches/0007-*`, applied only with `--with-pon`, and described by the board device tree
(`en7523-vgp42x6v1.dts` + `en7523-vgp42x6v1-pon.dtsi`). There is no separate
clone to fetch and no hand-applied hook step anymore. What still does not
work is the link itself: the driver probes on hardware but GPON stays
pre-O5 (downstream unresolved) -- see [docs/pon-port.md](../../docs/pon-port.md).

## 1. Where everything lives

| Piece | Location | Applied/selected by |
|---|---|---|
| xPON Kconfig/Makefile hooks (`net/`, `drivers/net/ethernet/airoha/`, `drivers/phy/airoha/`) | `../overlay/target/linux/airoha/patches-6.18/930-55`..`930-59` | OpenWrt, during the build |
| `MODULE_LICENSE` for `net/xpon/oam` | `patches-6.18/930-60` | `--with-pon` (needs the community sources) |
| Ethernet/PCS port (`airoha_eth` hooks, NPU shim, PCS API, `airoha_wed.h` forward decl.) | `.../patches-6.18/940-01`..`940-06` + `overlay/drivers/net/ethernet/airoha/airoha_wed.h` (via `apply-pon.sh`) | OpenWrt + `scripts/apply-overlay.sh` |
| EN7523 bring-up guards (SCU clock-domain reset, undecoded-register guards, stop-before-PLOAM, disable-path breadcrumbs, LOS-from-ready) | `patches-6.18/950-01`..`950-08` | `--with-pon` (needs the community sources) |
| pinctrl + reset-pulse prerequisites | `.../patches-6.18/202-29`, `202-30` | OpenWrt, during the build |
| Symbol selection + kmod packages | `buildroot-patches/0007-target-airoha-enable-xpon.patch` (and `0006` for the optical frontend) | `scripts/apply-overlay.sh --with-pon` |
| Board device tree (GDM2, `xpon`, `xpon_phy`, `pon_pcs`, `scu_reg`, `bob` + `gpon_serial` cell) | `../overlay/target/linux/airoha/dts/en7523-vgp42x6v1{,-pon}.dtsi` | `scripts/apply-overlay.sh` |
| Kernel `.config` symbols (6× `=m`, written by `0006` and `0007`) | `buildroot-patches/` | nothing sets them without `--with-pon`; `scripts/build-firmware.sh` refuses a build that asks for them without it |
| OMCI userspace (`omci-agent`, `luci-app-omci`, canonical UAPI) | `../omci/` | `../omci/apply-omci.sh` (called by `scripts/apply-overlay.sh`) |

`0006` and `0007` are **buildroot** patches -- they write the six symbols into
`target/linux/airoha/en7523/config-6.18` and declare the kmod packages -- so they are
not part of the kernel patch series and they used not to be here: they were steps 6
and 7 of the *default* series, which meant an M2 build asked the kernel for `net/xpon/`
and `drivers/net/optical/` and died 18 seconds into `target/linux/compile`, after 44
minutes of toolchain work. An M2 image is defined by having no optical and no xPON
code at all, so they now live in `buildroot-patches/` and `--with-pon` is what applies
them. See [docs/ci.md](../../docs/ci.md), trap 10.

`apply-pon.sh` today stages exactly one file -- the `airoha_wed.h` stub that
cannot live in `patches-6.18` (it is a *new* file, and the route-A baseline
of `airoha_eth.c` includes it while this kernel has no `mtk_wed_private.h`).
Run it through `scripts/apply-overlay.sh`; it needs no arguments beyond the
OpenWrt tree.

### Why nine patches need `--with-pon`

`930-60` and `950-01`..`950-08` modify files that **this repository does not
carry**: `net/xpon/**`, `airoha_xpon.[ch]`, `phy-airoha-xpon.c` and
`airoha_gpon_omci.c`. Those come from the community `airoha_en7523_all` branch and
were present in the author's local tree, not in the public one. Applied to a clean
tree they do not fail usefully either:

```
can't find file to patch at input line 4
No file to patch.  Skipping patch.
1 out of 1 hunk ignored
Patch failed!  Please fix .../950-01-...patch!
```

which stops `make target/linux/prepare` about twenty seconds in. Both jobs of CI
run 38616337395 died on exactly that after 47 and 81 minutes of toolchain work, and
that is why the default series is now `930-55`..`930-59` + `940-01`..`940-06`, with
the xPON ones in `patches-6.18/`. Without the community sources, `--with-pon` does
not make them apply -- it only decides where the build stops, which is the honest
behaviour for material this repository cannot ship.

## 2. Apply-order rule that bit us

OpenWrt copies `target/linux/<target>/files/` into the kernel tree BEFORE
applying `patches-6.18`. Consequence: files a patch *creates* must not also
be overlaid (the build dies with "already exists"). `pcs-en7523.c` is the
example -- patch `930-46` creates it, so it is deliberately absent from any
overlay list.

## 3. Retired first-generation material

`reference/010`..`033` were the first-generation hook patches (hand-applied
to a prepared kernel tree). `930-55`..`930-58` (plus `930-53`/`930-54` for
optical) supersede them with the same hunks; nothing applies the old ones
anymore. `reference/ref-*` are third-party comparison patches, kept for
evidence, never applied.

## 4. What this gives, and does not give

It builds the full xPON stack (7 modules in the rootfs, autoloaded) and the
driver probes on hardware: `/sys/class/xpon` exists, `luci` OMCI pages and
`omci.agent` answer (identity empty until provisioned). It does **not** give
a working PON link: GPON reaches O1->O2 but downstream never resolves (MAC
IRQ 39/40 quiet, OMCI counters zero). Ordered evidence, register figures
and the next read-only probe are in
[docs/pon-port.md](../../docs/pon-port.md) sections 15+.

**Hazards.** Never drive **GPIO 16** (the laser TX-disable line) without
knowing the polarity, and never make it unavailable: an optical transmitter
that fires on a live PON when it should not is a physical hazard to the
operator's eyes and to the upstream network. Bring-up stays dark (fibre
unplugged) until the link is understood. The laser BOB calibration and the
GPON serial are per-unit data and must never be copied between devices or
committed here. Never write slot A, the factory block or the trailing raw
region of the SPI-NAND -- see
[docs/hardware.md](../../docs/hardware.md).
