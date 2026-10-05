# econet-42x6-openwrt

OpenWrt board support for the **Econet / vG vGP-42X6V1** GPON ONU
(Airoha **EN7523** / EN7529CT SoC, 2x Cortex-A53 running AArch32).

This is a work-in-progress port, not a finished product. **Wi-Fi works on real
hardware. Ethernet and GPON do not work yet.** Read [Status](#status) before you
assume anything, and read [Two things that will bite you](#two-things-that-will-bite-you)
before you build.

---

## What this repository gives you

* A **board device tree** and **image profile** for the vGP-42X6V1
  (`econet_vgp-42x6v1`) for OpenWrt's `airoha` / `en7523` target.
* **Two kernel patches** that are both mandatory and neither obvious:
  * `arch/arm` `TEXT_OFFSET` -- without it the kernel deadloops in `head.S`
    before it can print a single character, so the UART is completely silent.
  * a PCI fixup for the EN7523 root complex -- without it the MT7916 Wi-Fi can
    never DMA, and the failure looks like a firmware timeout, not a PCI bug.
* The **mt76 packaging fix** that makes the `mt7916_eeprom.bin` firmware
  available; without it Wi-Fi probe dies after 60 s with `-110`.
* Two **diagnostic kernel modules** (`kmod-pciedbg`, `kmod-ringwatch`) built but
  not installed by default.
* **Tooling** for driving the device over its UART: boot to a shell, YMODEM an
  image into flash, paste a file into tmpfs, and verify a built image before
  you flash it.
* A way to produce a **self-contained Image Builder**, so that once the kernel
  is built, images can be composed with the normal OpenWrt workflow.

Everything that mutates the OpenWrt tree lives under [`openwrt/`](openwrt/).
[`docs/`](docs/) explains the hardware, the bugs, and the build.

---

## Hardware at a glance

| | |
|---|---|
| Device | Econet / vG **vGP-42X6V1**, a GPON ONU |
| SoC | Airoha / Econet **EN7523** (also seen as EN7529CT) |
| CPU | 2x Cortex-A53, **AArch32** (`armv7l`) |
| DRAM | 512 MiB at `0x80000000`; ATF/TCBoot hold `0x80000000..0x80200000` |
| Flash | SPI-NAND **Winbond W25N01K**, 128 MiB, 2048-byte pages, 128 KiB blocks |
| Wi-Fi | MediaTek **MT7916** on PCIe (2.4 + 5 GHz), functions `14c3:7906` / `14c3:790a` |
| Ethernet | 4x GbE switch -- **no driver for this SoC variant yet** |
| Optical | GPON BOSA + EN7571 laser driver -- **not brought up yet** |
| Console | UART at 115200n8 |

Full detail, including the exact SPI-NAND partition map and which regions must
never be written: [`docs/hardware.md`](docs/hardware.md).

---

## Status

| Milestone | State | Notes |
|---|---|---|
| **M1** boot to userspace on real hardware | **done** | console, 512 MiB, 7 MTD partitions, both PCIe ports enumerate |
| **M2** bring-up outside PON | **partial** | Wi-Fi works; NAND persistence, sysupgrade and Ethernet do not |
| **M3** optical / PON PHY | not started | sources located, nothing built |
| **M4** GPON O5 + OMCI | not started | -- |

Proven working, on the board, from a clean boot:

* the console reaches a shell and `procd` runs;
* both EN7523 root ports come up with `PCI_COMMAND=0x0146` with **no** manual
  register writes;
* the MT7916 loads firmware (`HW/SW Version: 0x8a108a10`) and a `wlan0`
  interface appears at 20 dBm.

Not working yet, and the reason why:

* **Ethernet.** The mainline `airoha_eth` driver supports only `en7581`/`an7583`.
  Nothing drives the EN7523 frame engine. This is the single biggest gap: a
  router without a LAN port is not a router.
* **NAND persistence / sysupgrade.** The stock `en7523` kernel config enables
  neither `MTD_BLOCK` nor `MTD_CHAR`, so the initramfs has no `/dev/mtd*`, and
  the target has no `base-files/lib/upgrade/platform.sh`. This repository adds
  the kernel options; the userspace upgrade path is still to be written.
* **Automated boot.** Vendor U-Boot (2014.04-rc1, `ECNT>` prompt) cannot parse
  OpenWrt's FIT image -- it fails with `Parse main image fail` -- so booting
  OpenWrt is a manual `bootm` after a `flash read`. See [docs/booting.md](docs/booting.md).
* **Real calibration.** The board's EFuse is blank, so Wi-Fi falls back to the
  default eeprom blob; the per-unit calibration lives in the `factory`
  partition and is not read yet. Consequence: a random MAC address.
* **GPON.** Untouched beyond locating the sources.

Prioritised remaining work with concrete acceptance criteria:
[`docs/roadmap.md`](docs/roadmap.md).

---

## Build with the Image Builder (recommended)

OpenWrt's **upstream** Image Builder cannot build a working image for this board,
because it ships only a precompiled kernel and lets you pick packages and a
profile -- it cannot apply kernel patches, and this board needs two of them.

So the workflow is: build from source **once** to produce the project's own
Image Builder, then use that for every image you actually want.

```bash
tar --zstd -xf openwrt-imagebuilder-airoha-en7523.*.tar.zst
cd openwrt-imagebuilder-airoha-en7523.*
make image PROFILE=econet_vgp-42x6v1 PACKAGES="luci luci-ssl"
```

Or let the helper do it, with a curated package list and a first-boot overlay:

```bash
./imagebuilder/build-image.sh /path/to/openwrt-imagebuilder-*.tar.zst --all-packages
```

The tarball carries the already-patched prebuilt kernel **and every package**,
including the airoha-specific kernel modules. That is deliberate:
`airoha/en7523` is `FEATURES:=source-only`, so there are no official package
repositories to fall back on. The price is a large tarball.

Details: [`docs/image-builder.md`](docs/image-builder.md).

---

## Build from source

On Linux, WSL or Docker (OpenWrt cannot be built on Windows itself):

```bash
git clone https://github.com/openwrt/openwrt.git openwrt
git -C openwrt checkout 9b95be917b2804cf877ca05c078175b37a3a95bf

./scripts/build-firmware.sh openwrt --initramfs
```

The pinned revision lives in [`scripts/pin.env`](scripts/pin.env). The script
verifies the tree is at that revision, refuses to continue otherwise, applies
the patches, seeds `.config`, and builds.

Artifacts land in `bin/targets/airoha/en7523/`:

| Artifact | Use |
|---|---|
| `*-initramfs-kernel.bin` | RAM boot over UART/YMODEM. Writes nothing to flash. |
| `*-sysupgrade.bin` | The persistent image; belongs in slot B (`mtd3`, `tclinux_slave`). |

To also produce the Image Builder:

```bash
./scripts/build-imagebuilder.sh openwrt -j8
```

Full build documentation, including how to bump the pinned revision:
[`docs/building.md`](docs/building.md).

---

## Two things that will bite you

**1. The load address must equal the kernel's `_text`, or the UART is silent.**

`textofs-$(CONFIG_ARCH_AIROHA) := 0x00208000` and
`loadaddr-$(CONFIG_TARGET_airoha_en7523) := 0x80208000` must agree, so that the
FIT load address equals `PHYS_OFFSET 0x80000000 + TEXT_OFFSET 0x208000`. Get it
wrong and the kernel deadloops in `head.S` *before* `parse_early_param()`, so
you get no output at all -- no panic, no oops, nothing. Always verify a build
before flashing:

```bash
python3 tools/verify_build.py <image>
```

**2. Reading an MMIO BAR with Memory Space disabled hangs the SoC permanently.**

The EN7523 root complex has no completion timeout. Reading a device BAR while
`PCI_COMMAND.MEMORY` is 0 causes a master abort, `readl()` spins forever,
softirqs stop, the console dies, and there is no oops, no watchdog message and
no soft-lockup warning. Only a power cycle recovers. `kmod-ringwatch` therefore
checks `PCI_COMMAND` before every BAR0 read. If you write your own debug code,
do the same.

Background: [`docs/pcie-root-cause.md`](docs/pcie-root-cause.md).

---

## Flashing safety

* **Never write** vendor slot A (`tclinux`), `data`, `config`, `reservearea`, or
  the trailing raw region `0x6900000-0x8000000`, which holds the factory block
  (GPON identity + laser calibration) and the bad-block table.
* **Never** write a chip image that was modified with an external programmer;
  the NAND ECC will be stale.
* Write flash only from a running Linux, or from U-Boot's `flash write`.
* Prefer the RAM-boot path when you are trying a new build.

---

## Repository layout

```
openwrt/
  patches/          applied with `git apply` to existing upstream files
  overlay/          copied verbatim into the OpenWrt tree
    target/linux/airoha/dts/          board device tree (+ stage 2 PON overlay)
    target/linux/airoha/patches-6.18/ the two mandatory kernel patches
    package/kernel/{pciedbg,ringwatch}/  diagnostic kernel modules
  pon/              stage 2 xPON material, NOT applied by default
scripts/            pin.env, apply-overlay.sh, build-firmware.sh, build-imagebuilder.sh
imagebuilder/       build-image.sh + package list + first-boot overlay
tools/              UART / YMODEM / console-paste / image-verify helpers
docs/               hardware, bugs, build and roadmap documentation
```

---

## Documentation

| Document | Contents |
|---|---|
| [`docs/hardware.md`](docs/hardware.md) | SoC, memory map, SPI-NAND, partition table, PCIe, UART, optical |
| [`docs/pcie-root-cause.md`](docs/pcie-root-cause.md) | Why Wi-Fi could not work, how it was proven, and the fix |
| [`docs/wifi.md`](docs/wifi.md) | MT7916 bring-up: module load order, the eeprom packaging gap |
| [`docs/booting.md`](docs/booting.md) | Boot chain, RAM boot, file transfer, console-paste limits, recovery |
| [`docs/building.md`](docs/building.md) | Pinned revision, applying the overlay, building, verifying |
| [`docs/image-builder.md`](docs/image-builder.md) | Producing and using the project's Image Builder |
| [`docs/status.md`](docs/status.md) | Milestones, what is proven, what is not |
| [`docs/roadmap.md`](docs/roadmap.md) | Prioritised remaining work with acceptance criteria |
| [`docs/reverse-engineering.md`](docs/reverse-engineering.md) | How the vendor firmware was analysed |

---

## Related work

* [`Sirherobrine23/airoha_kernel`](https://github.com/Sirherobrine23/airoha_kernel),
  branch `airoha_en7523_all` -- a community kernel tree that already carries
  EN7523 Ethernet and xPON hooks. This is the most promising starting point for
  closing the Ethernet and PON gaps; see [`docs/roadmap.md`](docs/roadmap.md).

## License

GPL-2.0-only, matching OpenWrt and the Linux kernel. See [LICENSE](LICENSE).

The device tree files are dual-licensed `(GPL-2.0-only OR BSD-2-Clause)`, as is
conventional for device trees, and carry an SPDX header saying so.
