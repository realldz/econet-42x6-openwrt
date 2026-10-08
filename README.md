# econet-42x6-openwrt

OpenWrt board support for the **Econet / vG vGP-42X6V1** GPON ONU
(Airoha **EN7523** / EN7529CT SoC, 2x Cortex-A53 running AArch32).

This is a work-in-progress port, not a finished product. **Ethernet, Wi-Fi and a
persistent install work on real hardware; GPON and the optical front end do
not.** Read [Status](#status) before you assume anything, and read
[Five things that will bite you](#five-things-that-will-bite-you) before you
build.

---

## What this repository gives you

* A **board device tree** and **image profile** for the vGP-42X6V1
  (`econet_vgp-42x6v1`), covering the four GbE ports, the front-panel LEDs and
  the two buttons.
* The **adopted EN7523 Ethernet kernel patch series** (`930-42`..`930-51`, taken
  from a community tree), which teaches `airoha_eth` about this SoC and lets DSA
  drive the internal MT7530 switch in MMIO mode.
* **Two kernel patches** that are both mandatory and neither obvious:
  * `arch/arm` `TEXT_OFFSET` -- without it the kernel deadloops in `head.S`
    before it can print a single character, so the UART is silent;
  * a PCI fixup for the EN7523 root complex -- without it the MT7916 Wi-Fi can
    never DMA, and the failure looks like a firmware timeout, not a PCI bug.
* **Three mt76 patches** for the WLAN LEDs. Without them the 2.4/5 GHz LEDs come
  on at driver init and stay on whatever the radio does; with them the LEDs
  follow the radio -- off when it is down, solid when it is up and idle, blinking
  under traffic.
* The **mt76 packaging fix** that ships `mt7916_eeprom.bin`; without it Wi-Fi
  probe dies after 60 s with `-110`.
* A **base-files overlay**: `lib/upgrade/platform.sh`, which gives `sysupgrade`
  a partition to write to, and `etc/board.d/02_network`, which bridges the switch
  ports.
* **Optional stage 2 xPON material** under `openwrt/pon/`: source inventory and
  hook patches. None of it is applied by default and none of it works.
* A **helper that writes a unit MAC into the default eeprom blob**
  ([`tools/mt7916_eeprom_mac.py`](tools/mt7916_eeprom_mac.py)), so a second board
  does not come up wearing the first board's address.
* Two **diagnostic kernel modules** (`kmod-pciedbg`, `kmod-ringwatch`), built but
  not installed by default, and **UART tooling** to boot to a shell, YMODEM an
  image into flash, paste a file into tmpfs and verify a built image.
* A way to produce a **self-contained Image Builder**, so later images can be
  composed with the normal OpenWrt workflow.

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
| Ethernet | 4x GbE through the internal MT7530 switch, driven by DSA in MMIO mode |
| Optical | GPON BOSA + EN7571 laser driver -- **not brought up yet** |
| Console | UART at 115200n8 |

Full detail, including the SPI-NAND partition map and which regions must never be
written: [`docs/hardware.md`](docs/hardware.md).

---

## Status

| Milestone | State | Notes |
|---|---|---|
| **M1** boot to userspace on real hardware | **done** | console, 512 MiB, 7 MTD partitions, both PCIe ports enumerate |
| **M2** bring-up outside PON | **done** | LAN up (4x GbE), Wi-Fi up with a real client, a reboot keeps its configuration |
| **M3** optical / PON PHY | not started | sources located; the xPON/optical stack compiles (32 of 34 objects) but nothing runs |
| **M4** GPON O5 + OMCI | not started | -- |

Proven working, on the board, from a clean boot:

* the console reaches a shell and `procd` runs, and both EN7523 root ports come
  up with `PCI_COMMAND=0x0146` and no manual register writes;
* the MT7916 loads firmware and both radios come up at 20 dBm. The image ships no
  `/etc/config/wireless` on purpose, so the AP interfaces are disabled until you
  enable them; they are then called `phy0-ap0` / `phy1-ap0`, not `wlan0`;
* a real client associates over the air on 5 GHz, gets a DHCP lease, moves
  hundreds of megabytes and answers pings from the wired side with 0 % loss, so
  packets really do cross the air;
* the four GbE ports are driven by the internal switch through DSA, and a cabled
  port negotiated 1 Gbps; a `sysupgrade` image written into slot B survives a
  reboot with its configuration;
* LuCI serves the web UI, `apk` installs packages, and with a WAN port chosen in
  LuCI the board forwards traffic to the internet (NAT).

Not working yet, and the reason why:

* **GPON / optical.** Beyond locating the sources and compiling most of them,
  untouched. The xPON port is blocked on an `airoha_eth.h` API mismatch: the
  community header is not a superset of OpenWrt's, and swapping it in breaks the
  Ethernet driver that now works. See [docs/pon-port.md](docs/pon-port.md).
* **Per-unit calibration.** The EFuse is blank, so Wi-Fi falls back to the
  default eeprom blob. The MAC address is no longer random -- a helper here
  writes a unit address into that blob -- but the real per-unit calibration in
  the `factory` partition is still not read.
* **Thermal sensor and watchdog.** Neither is configured.
* **The WPS LED.** Fitted on the board, but not reachable from any pad we have
  been able to drive.

Prioritised remaining work with acceptance criteria:
[`docs/roadmap.md`](docs/roadmap.md).

---

## Build with the Image Builder (recommended)

OpenWrt's **upstream** Image Builder cannot build a working image for this board:
it ships a precompiled kernel and lets you pick a profile and packages, but it
cannot apply kernel patches, and this board needs a patch series plus a base-files
overlay. So build from source **once** to produce the project's own Image Builder,
then use that for every image you actually want:

```bash
tar --zstd -xf openwrt-imagebuilder-airoha-en7523.*.tar.zst
cd openwrt-imagebuilder-airoha-en7523.*
make image PROFILE=econet_vgp-42x6v1 PACKAGES="luci luci-ssl"
```

`imagebuilder/build-image.sh` wraps this with a curated package list and a
first-boot overlay. The tarball carries the already-patched prebuilt kernel **and
every package**, including the airoha-specific kernel modules: `airoha/en7523` is
`FEATURES:=source-only`, so there are no official package repositories to fall
back on. The price is a large tarball. Details:
[`docs/image-builder.md`](docs/image-builder.md).

---

## Build from source

On Linux, WSL or Docker (OpenWrt cannot be built on Windows itself):

```bash
git clone https://github.com/openwrt/openwrt.git openwrt
git -C openwrt checkout 9b95be917b2804cf877ca05c078175b37a3a95bf

./scripts/build-firmware.sh openwrt --initramfs
```

The pinned revision lives in [`scripts/pin.env`](scripts/pin.env). The script
verifies the tree is at that revision, refuses otherwise, applies the patches,
seeds `.config`, and builds. Artifacts land in `bin/targets/airoha/en7523/`:

| Artifact | Use |
|---|---|
| `*-initramfs-kernel.bin` | RAM boot over UART/YMODEM. Writes nothing to flash. |
| `*-sysupgrade.bin` | The persistent image; belongs in slot B (`mtd3`, `tclinux_slave`). |

Add `--imagebuilder` to also produce the Image Builder tarball, or run
`./scripts/build-imagebuilder.sh openwrt -j8`. Full build documentation,
including the mandatory kernel options, package seeding and how to bump the
pinned revision: [`docs/building.md`](docs/building.md).

---

## Five things that will bite you

**1. The load address must equal the kernel's `_text`, or the UART is silent.**

`textofs-$(CONFIG_ARCH_AIROHA) := 0x00208000` and
`loadaddr-$(CONFIG_TARGET_airoha_en7523) := 0x80208000` must agree, so that the
FIT load address equals `PHYS_OFFSET 0x80000000 + TEXT_OFFSET 0x208000`. Get it
wrong and the kernel deadloops in `head.S` *before* `parse_early_param()`, so you
get no output at all -- no panic, no oops, nothing. Always verify a build before
flashing it with `python3 tools/verify_build.py <image>`.

**2. Reading an MMIO BAR with Memory Space disabled hangs the SoC permanently.**

The EN7523 root complex has no completion timeout. Reading a device BAR while
`PCI_COMMAND.MEMORY` is 0 causes a master abort, `readl()` spins forever, softirqs
stop, the console dies, and there is no oops, no watchdog message and no
soft-lockup warning. Only a power cycle recovers. `kmod-ringwatch` therefore
checks `PCI_COMMAND` before every BAR0 read; if you write your own debug code, do
the same. Background: [`docs/pcie-root-cause.md`](docs/pcie-root-cause.md).

**3. Two `is not set` lines are mandatory, or the build dies in `syncconfig`.**

`CONFIG_NET_DSA_MT7530` *implies* `CONFIG_NET_DSA_MT7530_MDIO`, and the PCS
patches add `CONFIG_PCS_AIROHA_EN7523`. Both are prompted symbols with no default,
so kconfig treats them as brand-new questions and asks them interactively; a
non-interactive kernel build then aborts in `syncconfig` with `Error 1`, minutes
in. This board needs MMIO mode and no PCS, so both are pinned in the target kernel
config:

```
# CONFIG_NET_DSA_MT7530_MDIO is not set
# CONFIG_PCS_AIROHA_EN7523 is not set
```

Other prompted symbols with no default (`CONFIG_LD_DEAD_CODE_DATA_ELIMINATION`,
`CONFIG_AIROHA_THERMAL`, the `PHY_AIROHA_*` USB/PCIe PHYs) are pinned the same way
in the same file. See [`docs/building.md`](docs/building.md).

**4. Never `dd` a firmware image into `/dev/mtdN` on this NAND.**

NAND cells only go from 1 to 0. Write a page that was not erased first and you get
the AND of the old and the new contents, plus ECC damage -- and `dd` still reports
`N records out` and exits 0. That was measured on this board: the write reported
success while the readback was entirely wrong. Use the `mtd` tool (`mtd write`,
which erases first) or `sysupgrade`, which is what `platform.sh` calls. See
[`docs/sysupgrade.md`](docs/sysupgrade.md).

**5. After changing an mt76 patch, clean the mt76 package.**

The WLAN LED patches land in `package/kernel/mt76/patches/`, and OpenWrt applies
package patches in the *prepare* step. An incremental build reuses the previous
build directory and silently ignores the new patch, so the image you test does not
contain your change:

```bash
make package/kernel/mt76/clean && make package/kernel/mt76/compile
```

---

## Flashing safety

* **Never write** vendor slot A (`tclinux`), `data`, `config`, `reservearea`, or
  the trailing raw region `0x6900000-0x8000000`, which holds the factory block
  (GPON identity + laser calibration) and the bad-block table.
* **Never** write a chip image modified with an external programmer, and never
  write a firmware image with `dd`: use the `mtd` tool from a running Linux (it
  erases first), or U-Boot's `flash write`. The NAND ECC is stale otherwise.
* Prefer the RAM-boot path when you are trying a new build.

---

## Repository layout

```
openwrt/
  patches/          applied with `git apply` to existing upstream files
  overlay/          copied verbatim into the OpenWrt tree
    target/linux/airoha/dts/                board device tree (LEDs, buttons)
                                            + stage 2 PON overlay
    target/linux/airoha/patches-6.18/       the EN7523 kernel patches
    target/linux/airoha/base-files/         sysupgrade platform.sh
    target/linux/airoha/en7523/base-files/  board.d/02_network (switch ports)
    package/kernel/mt76/patches/            the three WLAN LED patches
    package/kernel/{pciedbg,ringwatch}/     diagnostic kernel modules
  dbg/              diagnostic patches for --with-mt76-debug, never shipped
  pon/              stage 2 xPON material, NOT applied by default
  optional-configs/ example files you can opt into, e.g. a pinned wireless config
scripts/            pin.env, apply-overlay.sh, build-firmware.sh, packages.append
imagebuilder/       build-image.sh + package list + first-boot overlay
tools/              UART / YMODEM / console-paste / image-verify / DTS-vs-image / eeprom-MAC helpers
docs/               hardware, Ethernet, LEDs, sysupgrade, PON and build documentation
```

---

## Documentation

| Document | Contents |
|---|---|
| [`docs/hardware.md`](docs/hardware.md) | SoC, memory map, SPI-NAND, partition table, PCIe, UART, optical |
| [`docs/pcie-root-cause.md`](docs/pcie-root-cause.md) | Why Wi-Fi could not work, how it was proven, and the fix |
| [`docs/wifi.md`](docs/wifi.md) | MT7916 bring-up: module load order, the eeprom packaging gap |
| [`docs/ethernet.md`](docs/ethernet.md) | The EN7523 Ethernet patch series and the switch in MMIO mode |
| [`docs/leds.md`](docs/leds.md) | LEDs and buttons, and the three mt76 LED patches |
| [`docs/booting.md`](docs/booting.md) | Boot chain, RAM boot, file transfer, console-paste limits, recovery |
| [`docs/building.md`](docs/building.md) | Pinned revision, the overlay, kernel options, package seeding, verifying |
| [`docs/sysupgrade.md`](docs/sysupgrade.md) | Persistent install: `/dev/mtd*`, `platform.sh`, slot B, what survives |
| [`docs/image-builder.md`](docs/image-builder.md) | Producing and using the project's Image Builder |
| [`docs/pon-port.md`](docs/pon-port.md) | Where the xPON/optical port stands, and what blocks it |
| [`docs/status.md`](docs/status.md) | Milestones, what is proven, what is not |
| [`docs/roadmap.md`](docs/roadmap.md) | Prioritised remaining work with acceptance criteria |
| [`docs/reverse-engineering.md`](docs/reverse-engineering.md) | How the vendor firmware was analysed |

---

## Related work

* [`Sirherobrine23/airoha_kernel`](https://github.com/Sirherobrine23/airoha_kernel),
  branch `airoha_en7523_all` -- a community kernel tree that already carries
  EN7523 Ethernet and xPON hooks. Its **Ethernet half was adopted**: the
  `930-42`..`930-51` series is what makes the four GbE ports work today. Its
  **PCS half was left asleep**: `930-46`..`930-51` add the SerDes/PCS layer that
  only optical needs, and they stay disabled
  (`# CONFIG_PCS_AIROHA_EN7523 is not set`).
* The **xPON port itself is still blocked** on an `airoha_eth.h` API mismatch: the
  community header (4805 lines) is not a superset of OpenWrt's (744 lines), so
  swapping it in breaks `airoha_eth.c` and `airoha_ppe.c` -- the working Ethernet
  driver and the new PON stack cannot share it as it stands. A first pass of the
  ported xPON stack compiles **32 of 34 objects** clean against 6.18.54; the two
  failures (`airoha_xpon.o`, `airoha_gpon_omci.o`) are missing API surface rather
  than wrong code. See [`docs/pon-port.md`](docs/pon-port.md).

## License

GPL-2.0-only, matching OpenWrt and the Linux kernel. See [LICENSE](LICENSE).

The device tree files are dual-licensed `(GPL-2.0-only OR BSD-2-Clause)`, as is
conventional for device trees, and carry an SPDX header saying so.
