# econet-42x6-openwrt

OpenWrt board support for the **Econet / vG vGP-42X6V1** GPON ONU
(Airoha **EN7523** / EN7529CT SoC, 2x Cortex-A53 running AArch32).

This is a work-in-progress port, not a finished product. **Ethernet, Wi-Fi, a
persistent install, the optical frontend and the xPON driver probe work on real
hardware; the GPON link itself does not (O1->O2, downstream open).** Read
[Status](#status) before you assume anything, and read
[Six things that will bite you](#six-things-that-will-bite-you) before you
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
* **Route-A xPON/optical work** (`openwrt/pon/`, `openwrt/omci/`,
  `openwrt/pon/buildroot-patches/0007-*`): the control plane (`omci-agent`,
  `luci-app-omci`) is applied by default, and so is the `940-01`..`940-06`
  Ethernet/PCS port that the board's 4xGbE needs. The kernel side of the xPON stack
  is not: sixteen patches in `openwrt/pon/patches-6.18/` -- the `930-53`..`930-59`
  Kconfig/Makefile hooks and the nine that touch the community xPON sources
  themselves (`930-60`, `950-01`..`950-08`) -- plus the symbol selection and the
  kmod packages (`buildroot-patches/0006`-`0007`) need `--with-pon` **and** the
  `airoha_en7523_all` sources, which this repository does not carry. That is
  deliberate and load-bearing: the default series sets no
  `CONFIG_XPON`, `CONFIG_XPON_OMCI`, `CONFIG_PHY_AIROHA_XPON`, `CONFIG_AIROHA_XPON_V1`
  or `CONFIG_OPTICAL_FRONTEND`, so an M2 image carries no optical and no xPON code at
  all. It used to set all six, and the kernel then tried to build `net/xpon/` and
  `drivers/net/optical/` -- sources that are not here -- and died eighteen seconds
  into `make target/linux/compile`; see [pon-port.md](docs/pon-port.md). Measured
  on the author's own tree, which did carry those sources: 7 modules that self-load,
  the driver probes, GPON reaches O1->O2, downstream unresolved. Unit identity is
  redacted (placeholders in git, real serial from flash, empty password).
* A **helper that writes a unit MAC into the default eeprom blob**
  ([`tools/mt7916_eeprom_mac.py`](tools/mt7916_eeprom_mac.py)), so a second board
  does not come up wearing the first board's address.
* Two **diagnostic kernel modules** (`kmod-pciedbg`, `kmod-ringwatch`), built but
  not installed by default, and **UART tooling** to boot to a shell, YMODEM an
  image into flash, paste a file into tmpfs and verify a built image.
* A way to produce a **self-contained Image Builder**, so later images can be
  composed with the normal OpenWrt workflow.
* **Prebuilt images and a kernel-module repository**, built and verified by CI, so
  trying the board does not start with a 2-3 hour build. See
  [Prebuilt images](#prebuilt-images-and-the-package-repository).

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
| Optical | GPON BOSA + EN7571 laser driver -- **probes on the SoC's I2C0 at `0x70`**, DDMI temperature/voltage read and match stock, BOB loads |
| Console | UART at 115200n8 |

Full detail, including the SPI-NAND partition map and which regions must never be
written: [`docs/hardware.md`](docs/hardware.md).

---

## Status

| Milestone | State | Notes |
|---|---|---|
| **M1** boot to userspace on real hardware | **done** | console, 512 MiB, 7 MTD partitions, both PCIe ports enumerate |
| **M2** bring-up outside PON | **done** | LAN up (4x GbE), Wi-Fi up with a real client, a reboot keeps its configuration |
| **M3** optical / PON PHY | **done** | `en7571` probes, hwmon reads bias/temperature, BOB loads |
| **M4** GPON O5 + OMCI | **in progress** | route-A stack builds (7 modules, autoloaded), xPON probes, OMCI answers (`compatible: true`), FSM runs O1->O2 with fibre; downstream unresolved (MAC IRQs quiet, next: one read-only GTC-counter probe) |

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

* **GPON link.** The xPON stack builds, probes and runs O1->O2 with fibre, but
  downstream never resolves: MAC IRQs stay quiet and OMCI counters read zero.
  Next is one read-only probe (`GPON_DBG_RX_GTC_CNT`). O5 needs a live OLT,
  and no public source has reached it on EN7523. Bring-up stays dark (fibre
  unplugged) until the link is understood; GPIO16 (laser TX-disable) polarity
  is still unconfirmed. See [docs/pon-port.md](docs/pon-port.md) sections
  15-21.
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

## Prebuilt images and the package repository

CI builds both images on GitHub, verifies them, and attaches them to a
[release](https://github.com/realldz/econet-42x6-openwrt/releases) along with the
Image Builder tarball. Nothing has to be built locally to try the board.

| Asset | Use |
|---|---|
| `*-initramfs-kernel.bin` | RAM boot over UART/YMODEM. Writes nothing to flash -- try this one first. |
| `*-squashfs-sysupgrade.bin` | The persistent image; belongs in slot B (`mtd3`, `tclinux_slave`). |
| `openwrt-imagebuilder-*.tar.zst` | Build your own image later without a full source build. |
| `SHA256SUMS` | What each file hashes to. |

The released images are the **M2** variant: the four GbE ports, Wi-Fi 6, LuCI and
`apk`. The optical frontend and the xPON/OMCI stack are deliberately left out,
because they need the per-unit BOB laser calibration blob, which sits in the
factory partition of the individual unit and is not published here -- see
[`docs/hardware.md`](docs/hardware.md). Drivers without that blob only produce a
boot log full of failures nobody can act on. To build the full set for your own
unit, use `--variant full` and read [`docs/pon-port.md`](docs/pon-port.md).

### Installing extra packages

`airoha/en7523` is `FEATURES:=source-only`, so OpenWrt publishes no `kmods/`
directory for it, and **no kernel module for this board can be installed from
downloads.openwrt.org**. (Userspace packages are a different matter: they depend
on the CPU/ABI rather than the kernel, and install normally from the generic
`arm_cortex-a7` feeds.) A kernel module has to come from a repository built
against the exact kernel the board is running, because one built against another
kernel is refused at load time with `invalid module format`. CI publishes such a
repository per release, keyed to the release tag, on the `gh-pages` branch:

```sh
echo 'https://realldz.github.io/econet-42x6-openwrt/<tag>/kmods/<kernel>' \
  > /etc/apk/repositories.d/42x6-kmods.list
apk update --allow-untrusted
apk add --allow-untrusted <package>
```

Which modules that repository holds is a decision made at build time, and one the
board cannot repair afterwards: an archive carries the modules the image was built
with, and a plain M2 build selects 46 of them -- `kmod-wireguard` is not among
them, because nothing in the image needs it.

Releases publish the curated list in
[`scripts/kmods-release.txt`](scripts/kmods-release.txt) (`--kmods release`): 14
names -- WireGuard, BBR, CAKE and IFB for SQM, TUN/TAP, veth, macvlan, VXLAN, GRE,
6in4, the NAT helpers, `nft-arp` -- plus the packages they depend on, so a module
you install months later is there. MEASURED on `v0.1.1-m2`: 83 modules, 96 files in
one directory, 8,540 B of kernel partition left over.

`--kmods all` was the first shape and it does not fit this board: MEASURED, the
FIT reaches 3,986,924 B against a 3,801,088 B mtd4 `kernel` partition, and the
module version carries the md5 of the whole kernel config, so a wider selection
would make the archive uninstallable as well as the image unflashable
([trap 16](docs/ci.md), [packages.md](docs/packages.md)). `--kmods a,b,c` narrows
the archive to a list of your own, and `--kmods-exclude a,b` keeps a package out
of `all` -- the one name excluded by default is `kmod-ipt-rtpengine`, whose feed
directory also builds telephony daemons this board has no use for, and one of them
failed a release build ([trap 13](docs/ci.md)). Selected modules are packaged into
the archive and **not** installed into the image. See
[`docs/packages.md`](docs/packages.md).

The packages are not signed, which is what `--allow-untrusted` is for. The exact
`<tag>` and `<kernel>` for a release are written in its release notes and in
`.../<tag>/install.md`; if GitHub Pages is not serving the branch, the same tree
is reachable at
`https://raw.githubusercontent.com/realldz/econet-42x6-openwrt/gh-pages/<tag>/`.
Full detail, including how to publish a repository yourself:
[`docs/packages.md`](docs/packages.md).

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
`FEATURES:=source-only`, so there is no official feed for its kernel modules to
fall back on. The price is a large tarball. Details:
[`docs/image-builder.md`](docs/image-builder.md).

---

## Build from source

On Linux, WSL or Docker (OpenWrt cannot be built on Windows itself):

```bash
git clone https://github.com/openwrt/openwrt.git ../openwrt
git -C ../openwrt checkout 9b95be917b2804cf877ca05c078175b37a3a95bf

./scripts/build-firmware.sh ../openwrt --variant m2 --initramfs
```

Clone OpenWrt **outside** this repository, not into it: this project has its own
top-level `openwrt/` directory (the board support), so `git clone ... openwrt`
here fails with `destination path 'openwrt' already exists and is not an empty
directory` -- which is how the first CI run of this repository died, before it
built anything. Any path works as long as `build-firmware.sh` is given it.

The pinned revision lives in [`scripts/pin.env`](scripts/pin.env). The script
verifies the tree is at that revision, refuses otherwise, applies the patches,
installs the feeds if they are missing (LuCI and the AP daemon live in feeds, and
a fresh clone has none), seeds `.config`, and builds. Artifacts land in
`bin/targets/airoha/en7523/`:

| Artifact | Use |
|---|---|
| `*-initramfs-kernel.bin` | RAM boot over UART/YMODEM. Writes nothing to flash. |
| `*-sysupgrade.bin` | The persistent image; belongs in slot B (`mtd3`, `tclinux_slave`). |

Two options decide what goes in:

* `--variant m2` (the release shape) carries Ethernet, Wi-Fi, LuCI and `apk`.
  `--variant full` adds the optical frontend and the xPON/OMCI stack, which need
  the per-unit BOB blob; the lists are
  [`scripts/packages-m2.append`](scripts/packages-m2.append) and
  [`scripts/packages.append`](scripts/packages.append).
* `--initramfs` is on by default. Note that it changes the *kernel*, so the
  `*-sysupgrade.bin` of such a build is not usable -- build once with
  `--initramfs` for the RAM-boot image and again with `--no-initramfs` for the
  persistent one. See item 6 in
  [Six things that will bite you](#six-things-that-will-bite-you).

Add `--imagebuilder` to also produce the Image Builder tarball, or run
`./scripts/build-imagebuilder.sh ../openwrt -j8`. Full build documentation,
including the mandatory kernel options, package seeding and how to bump the
pinned revision: [`docs/building.md`](docs/building.md).

---

## Six things that will bite you

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

**6. A build with `--initramfs` produces a `*-sysupgrade.bin` that cannot be used.**

`--initramfs` is on by default, and it does not only add an artifact: it builds a
kernel with the initramfs cpio embedded in it. `mtdsplit_fit` derives the kernel
partition from the FIT size and then looks for the rootfs *after* the FIT, so the
sysupgrade image from that build has its rootfs far outside `mtd4` -- MEASURED
12,058,913 B with the squashfs at `0x760000`, against 9,437,473 B with the
squashfs at `0x3A0000` for a clean build. Build the persistent image with
`--no-initramfs`, and always gate it before flashing:

```bash
python3 tools/verify_image.py <image>
```

CI runs exactly this check on every sysupgrade image it releases, and refuses to
publish one that fails. See [`docs/sysupgrade.md`](docs/sysupgrade.md).

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
  pon/              route-A xPON staging (airoha_wed.h stub) + README;
                    patches-6.18/ holds the sixteen xPON kernel patches
  omci/             omci-agent + luci-app-omci + canonical UAPI + apply-omci.sh
  pon/buildroot-patches/  optical-frontend and xPON symbols + kmod packages
                    (0006-0007); both pon patch sets need `--with-pon`
  optional-configs/ example files you can opt into, e.g. a pinned wireless config
scripts/            pin.env, apply-overlay.sh, build-firmware.sh,
                    packages.append + packages-m2.append, publish-packages.sh
imagebuilder/       build-image.sh + package list + first-boot overlay
tools/              UART / YMODEM / console-paste / image-verify / DTS-vs-image /
                    eeprom-MAC helpers, and the patch-appliance gate
                    (tools/check_patches_apply.py)
.github/workflows/  lint on every push; build.yml (reusable) and release.yml, which
                    builds both images, verifies them, publishes a GitHub Release
                    and updates the package repository on gh-pages
docs/               hardware, Ethernet, LEDs, sysupgrade, PON, packages, CI and
                    build documentation
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
| [`docs/packages.md`](docs/packages.md) | The prebuilt images, and the apk repository published per release |
| [`docs/ci.md`](docs/ci.md) | CI/CD: what runs on GitHub, the gates before anything is published, how to dispatch a release |
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
* The **xPON port is route A and it probes**: the `940-01` hook patch brings
  `airoha_eth` to the community baseline the working Ethernet driver still
  applies against, `940-05` back-ports the five hook-contract deltas, and the
  `950-xx` guards keep every boot alive. What does not work yet is the link,
  not the build. See [`docs/pon-port.md`](docs/pon-port.md) sections 15-21.

## License

GPL-2.0-only, matching OpenWrt and the Linux kernel. See [LICENSE](LICENSE).

The device tree files are dual-licensed `(GPL-2.0-only OR BSD-2-Clause)`, as is
conventional for device trees, and carry an SPDX header saying so.
