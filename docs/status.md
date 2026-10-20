# Status

What is actually proven on hardware, what is not, and how you can tell the
difference. Last verified against a clean boot of the current build, which carries
Ethernet, a persistent install and the board LEDs. Every claim is labelled
`[hardware]` when it was measured on the board, or `[not verified]` when it is
only a build-time or source-level result.

The milestone definitions are taken from the original gap analysis, so that a
milestone is only "done" when its stated acceptance test passes.

## Milestones

| | Milestone | Acceptance test | State |
|---|---|---|---|
| **M1** | Boot to userspace over RAM | shell on the console, `/proc/mtd` lists the partitions, 512 MiB reported | **done** |
| **M2** | Bring-up outside PON | SPI-NAND + BMT, 4x GbE switch, PCIe MT7916, LEDs/buttons, `data` overlay. "LAN up, Wi-Fi up, reboot keeps config" | **done** |
| **M3** | Optical | `en7571` probes, hwmon exposes bias/temperature, `tx_enabled=1` | **done** `[hardware]`: `en7571` probes on `i2c0` at `0x70`, DDMI temperature/voltage read and match stock, BOB loads (see [pon-port.md](pon-port.md) section 14) |
| **M4** | GPON O5 + OMCI | `GPON netdev link ready: O5=1 OMCI=1`, OLT accepts the ONU, OMCI MIB replies | **in progress** `[hardware]`: route-A stack builds clean (7 modules, autoloaded, self-loading), xPON probes on the board, OMCI userspace answers (`compatible: true`); GPON reaches O1->O2 with fibre but downstream never resolves -- MAC IRQs quiet, OMCI counters zero ([pon-port.md](pon-port.md) sections 15-21) |

## Published images and the package repository

The first end-to-end CI release, measured on what it published rather than on what
it was supposed to publish:

| | |
|---|---|
| release | [`v0.1.1-m2`](https://github.com/realldz/econet-42x6-openwrt/releases/tag/v0.1.1-m2), built by [run 39259723152](https://github.com/realldz/econet-42x6-openwrt/actions/runs/39259723152) in 1h11m08s |
| variant | `m2` -- 4x GbE, Wi-Fi 6 (MT7916), LuCI over HTTPS, apk. No optical frontend, no xPON/OMCI |
| sysupgrade | `openwrt-airoha-en7523-econet_vgp-42x6v1-squashfs-sysupgrade.bin`, 9,437,480 B; FIT 3,792,548 B inside a 3,801,088 B mtd4 `kernel` partition (8,540 B spare), squashfs at `0x3A0000` |
| initramfs | `openwrt-airoha-en7523-econet_vgp-42x6v1-initramfs-kernel.bin`, 8,815,628 B |
| Image Builder | `openwrt-imagebuilder-airoha-en7523.Linux-x86_64.tar.zst`, 47,848,220 B |
| kmod repository | `https://realldz.github.io/econet-42x6-openwrt/v0.1.1-m2/kmods/6.18.54` -- 96 files, **83 kernel modules** (the 14 names in `scripts/kmods-release.txt` and their dependencies), `kernel-6.18.54~143bce488b8f95c4cfd2004defd35cd5-r1.apk` among them |

The first release, `v0.1.0-m2` ([run 38939207748](https://github.com/realldz/econet-42x6-openwrt/actions/runs/38939207748),
1h07m45s), published 59 files and 46 modules -- only the ones the image itself
carries, because that is what a plain M2 build selects. `v0.1.1-m2` publishes the
curated list instead, so a module you install later is there, and that is why it
holds 83.

**The two tags' modules are not interchangeable.** The kernel package name carries
the md5 of the whole kernel config (`include/kernel-defaults.mk`), and selecting 83
modules instead of 46 changed it: `v0.1.0-m2` shipped
`kernel-6.18.54~ba6507fb3e4420e857c74d5e042e6c5e-r1.apk`, `v0.1.1-m2` ships
`kernel-6.18.54~143bce488b8f95c4cfd2004defd35cd5-r1.apk`. A module from one tag
will not install on the other, even though the sysupgrade image is the same size to
the byte: flash the image from the same tag first, then add modules from it.

Three kernel version strings appear in that one repository, and that is normal:
`kmod-pppoe-6.18.54-r1.apk`, `kmod-mac80211-6.18.54.7.2-r4.apk` (the mac80211/cfg80211
backports) and `kmod-mt7915e-6.18.54.2026.09.01~be5ce791-r1.apk` (mt76). apk keeps them
apart with `depends: kernel (=<version>)`, not with the file name, so the directory is
the right one for the image as long as the URL carries its tag.

It carries no `kmod-xpon`, no `kmod-xpon-omci` and no `kmod-optical-frontend`: the M2
variant defines itself by not having the optical or xPON code, and the patches that
would declare those modules (and would ask the kernel for `net/xpon/`) are behind
`--with-pon`. Installing from it, on the board:

```sh
echo 'https://realldz.github.io/econet-42x6-openwrt/v0.1.1-m2/kmods/6.18.54' \
  > /etc/apk/repositories.d/42x6-kmods.list
apk update --allow-untrusted
apk add --allow-untrusted <package>
```

`[not verified]` on hardware: nothing in this table has been flashed or installed
from on a board yet. The images are the same shape as the ones that boot (M1/M2 above),
and the repository is keyed to the kernel those images run, but the `apk add` itself
has not been run on the board, and neither has the negative case (a module built for
another kernel tag must fail with `Invalid module format`).

## M1 -- done `[hardware]`

Verified from a clean boot, with no manual register writes:

* the console reaches a shell and `procd` runs;
* PSCI v1.1, two CPUs, GICv3;
* SPI-NAND is detected with the expected partition map (7 partitions in an
  initramfs build; the squashfs build adds `kernel`, `rootfs` and `rootfs_data`
  through `mtdsplit`);
* both PCIe root ports enumerate, and both MT7916 functions are visible.

The milestone was blocked for a long time by a problem that produced no output at
all: the `airoha` target lacked an `arch/arm` `TEXT_OFFSET`, so the kernel
deadlooped in `head.S` before it could print. See [booting.md](booting.md).

## M2 -- done `[hardware]`

The acceptance test is "LAN up, Wi-Fi up, reboot keeps config". All three parts
were demonstrated on the board:

| Part | How it was demonstrated |
|---|---|
| **LAN up** | The 4x GbE internal switch is driven as DSA by `mt7530` in MMIO mode (`mt7530-mmio 1fb58000.switch`), using the community kernel patch series adopted as `930-42` .. `930-51`. The four ports come up as `lan1` .. `lan4` on the `eth0` conduit, and a cable on one port negotiated 1 Gbps/Full. The board routes for real: an uplink on the WAN port gave a default route, DNS and a clean download. Detail: [ethernet.md](ethernet.md). |
| **Wi-Fi up** | Both MT7916 radios come up and carry traffic to a real client over the air. The driver reports 864.8 Mbit/s Tx at HE-MCS 8, 80 MHz, 2 spatial streams -- that is the `station dump` rate estimate, not an `iperf3` result; no `iperf3` peer was set up. The path was host -> cable -> `lan4` -> `br-lan` -> `phy1-ap0` -> client. The AP interfaces are `phy0-ap0` / `phy1-ap0` (not `wlan0`), and both are members of `br-lan`. LuCI runs on `ucode` and serves its login page; `apk` works after the generic feeds are added. Detail: [wifi.md](wifi.md). |
| **Reboot keeps config** | `sysupgrade` runs on the board: it unlocks and writes slot B (`tclinux_slave`, mtd3) block by block, reboots, and the board comes back on the image it just wrote. Slot A is untouched, the overlay survives, and `/etc/config` plus marker files were intact after the upgrade. Detail: [sysupgrade.md](sysupgrade.md). |

**Measured throughput `[hardware]`, not yet good.** End-to-end throughput was measured by the owner during acceptance and peaks at **200-400 Mbit/s**.
That is far below the 864.8 Mbit/s `station dump` rate estimate and below what this hardware should reach (the wired link negotiates 1 Gbps and the
radio reports HE80 2x2), so there is real room to improve. Two honest caveats: the run's direction, client and tool were not recorded, and there is
no `iperf3` baseline yet, so the number is an acceptance figure rather than a benchmark `[not verified]`. Improving it -- offloads, flow control and
the FE/QDMA path -- is deliberately **not** a priority: the board is usable as it is and the work needs a proper `iperf3` setup first. See
[roadmap.md](roadmap.md) section 7.

### Two fixes M2 still depends on

* A PCI fixup for the EN7523 root complex: its bogus BAR0 stops
  `pci_enable_resources()` from enabling Memory Space and Bus Master on the bridge,
  so the Wi-Fi card's DMA never reached DRAM. Both root ports now reach
  `PCI_COMMAND=0x0146` on a clean boot, with no manual writes. Write-up:
  [pcie-root-cause.md](pcie-root-cause.md).
* The mt76 package did not install the default `*_eeprom*.bin` blobs, so the
  fallback path a blank-EFuse board needs could not complete.

### Persistence and sysupgrade

Three things were needed, and all three are in place `[hardware]`: the board
kernel options patch adds `CONFIG_MTD_BLOCK` (plus the OpenWrt `DEVTMPFS`
options -- `CONFIG_MTD_CHAR` is not a real symbol on 6.18 and does nothing),
without which there were no `/dev/mtd*` nodes at all;
`platform.sh` supplies `platform_do_upgrade` with `PART_NAME="tclinux_slave"`,
which is what makes the generic `default_do_upgrade` write slot B; and the overlay
is a UBI volume named `rootfs_data` on the `data` partition (mtd7), deliberately
outside the firmware slot, so an upgrade keeps the configuration. (JFFS2 was not
viable on this SPI-NAND; see [sysupgrade.md](sysupgrade.md).)

### LEDs and buttons `[hardware]`

The board device tree now describes the front-panel LEDs and both keys, and each
one was checked on hardware:

| Node | GPIO | State on the board |
|---|---|---|
| `blue:power` | 27 | lit from boot through `default-state = "on"`; also the `led-boot` / `led-running` / `led-failsafe` / `led-upgrade` alias |
| `green:pon` | 10 | binds, off at boot, driven from sysfs |
| `red:los` | 6 | binds, off at boot, driven from sysfs |
| `blue:inet` | 1 | binds, off at boot, driven from sysfs |
| `reset` (`KEY_RESTART`) | 0 | polled key, 100 ms; the uevent reaches `procd` and a long press factory-resets the board |
| `wps` (`KEY_WPS_BUTTON`) | 7 | polled key; the same event path |

The WLAN 2.4G and 5G LEDs are **not** GPIOs: they hang off a pad-mux register in
the SoC (`MT_LED_GPIO_MUX1`, pads 14 and 15) that the Wi-Fi driver writes. Three
mt76 patches make the driver own that state instead of leaving it on from driver
init: the pad-mux init writes "off", `brightness` maps to the pad of the matching
band, and the radio start/stop path sets and clears it. Semantics on the board:
radio down -> both LEDs off, radio up and idle -> solid, traffic -> blink.
**All three states were confirmed by eye** by the owner on the flashed image
(patch 102), so this is `[hardware]` rather than an intention. Detail:
[leds.md](leds.md).

The **WPS LED stays unresolved and blocked** `[not verified]`: driving all 28
safe pads (plus pad 16 and pad 28) lights nothing, so no LED node is declared for
it. Reasoning and what would close it: [leds.md](leds.md) section 11.

### Network identity

The base MAC is read at boot from the U-Boot environment (an `nvmem-cells` /
`fixed-layout` partition with a `mac-base` cell at 0x19F): eth0, the four switch
ports and both radio bands each consume it with their own index
(base+0 .. base+4, bands base+6/base+7), so no pool of random-originated
addresses reaches the interfaces. On the flashed image
`econet_vgp42x6v1_openwrt_m2_mac_env19f_pci_20261020` (sha256 `169e59f9...`,
2026-10-20) every address was measured on the board in one boot: eth0 f0,
lan1..4 f1..f4, `phy0-ap0` f6, `phy1-ap0` f7, zero "random address" lines in
`dmesg`. Reaching the radio bands needed one more device-tree hop than the
obvious one: the MT7916 sits behind the integrated root port `0001:00:01.0`, so
the DTS needs a `pci@1,0` wrapper before the kernel attaches an of_node to the
endpoint and `mt76_eeprom_override()` can walk the `band@N` children. Full
chain: [pcie-root-cause.md](pcie-root-cause.md) section 10 and
[wifi.md](wifi.md). The MT7916 EFuse is blank and the fallback default
`mt7916_eeprom.bin` blob carries a zero MAC; the DTS cells hide that, and
`tools/mt7916_eeprom_mac.py` remains the fallback for Image Builder images
whose tree does not carry the cell. This is not per-unit
calibration: the real per-unit data (GPON identity, laser BOB) sits in the vendor
factory block in the trailing raw region and is **not** read yet. See
[wifi.md](wifi.md) and [hardware.md](hardware.md).

## M3 / M4 -- M3 done, M4 in progress (xPON probes, O1->O2, downstream open)

M3 closed on hardware (`img25`, 2026-10-08 -- [pon-port.md](pon-port.md)
section 14): `en7571` probes at `0x70`, `EN7571 initialised: GPON, rev 2, KT1,
DDMI1`, `/sys/class/optical_frontend/frontend0` shows `present=1 ready=1`,
hwmon temperature 41-42 C rising and 3.263 V matching stock within 0.4 mV.

M4 (route A, images `img31`..`img61`, 2026-10-11/12) is where the project
stands now:

* the xPON patch series builds clean: 7 modules link with zero modpost
  errors, land in the rootfs with autoload entries, self-load after boot;
* `/sys/class/xpon` exists, the driver probes, `dmesg` shows no call
  trace/panic/WARNING across reboots, LAN is unregressed (1 Gbps, NAT works);
* the DT carries the PON nodes (GDM2 2500base-x, `xpon`/`xpon_phy`/`pon_pcs`,
  `scu_reg`, `bob` + `gpon_serial` cell) with redacted placeholders -- real
  serial comes from flash, password is empty;
* OMCI userspace (`omci-agent` + LuCI) answers with `compatible: true` after
  the v13/v14 handshake fix; identity UCI ships empty;
* first light measured (RX ~-24 dBm); the boot-with-fibre hang is fixed by
  deriving LOS from PHY READY (`950-08`); the FSM runs O1->O2;
* **still open**: downstream never resolves -- MAC IRQs 39/40 quiet, OMCI
  counters zero. Next is one read-only probe (`GPON_DBG_RX_GTC_CNT` at
  `0x1fb64308`) that decides IRQ-routing vs RX-arming.

The compile-harness history behind route A (32 of 34 objects clean, the
`airoha_eth.h` divergence measured at 17 then 20 hooks) is kept in
[pon-port.md](pon-port.md) sections 2-6.

Prior art, surveyed 2026-10-08: a second, independent implementation reaches GPON
O5 with full OMCI and internet on **EN7528** (openwrt PR #24577, licence-encumbered
in part), and a third does the same on **EN751221**; neither is EN7523, and no public
source has reached O5 on this SoC. The survey, the reusable pieces and the upstream
`net/pon` RFC are in [pon-port.md](pon-port.md) section 12.

The PON device tree
[`en7523-vgp42x6v1-pon.dtsi`](../openwrt/overlay/target/linux/airoha/dts/en7523-vgp42x6v1-pon.dtsi)
is included by the board device tree and compiles; it records the register
windows, interrupts and reset bits recovered from the stock device tree, plus
the `scu_reg`, `bob`/`gpon_serial` and `#optical-frontend-cells` details that
each cost a boot to learn. Full story: [pon-port.md](pon-port.md) sections
15-21.

## Still broken or open

* **PON downstream (M4).** Optical is done; xPON probes, O1->O2 reached with
  fibre, but downstream never resolves (MAC IRQs quiet, OMCI counters zero;
  next: one read-only `GPON_DBG_RX_GTC_CNT` probe). `[partially verified]`
* **Real per-unit RF calibration.** Wi-Fi runs on the default blob, so the
  calibration is generic rather than the unit's own. The MAC is stable, but it is
  not read from the factory block. `[not verified]`
* **Automated boot.** Booting still rests on a hand-edited U-Boot environment:
  the vendor U-Boot cannot parse an OpenWrt FIT image (`Parse main image fail`),
  so it boots slot B through a `bootcmd` of `flash read` + `bootm` that this
  repository does not create or restore. Once that environment exists, autoboot
  itself needs no host: a sysupgrade-triggered reboot was measured with 0 bytes
  sent from the host. `[hardware]` for the 0 bytes, `[not verified]` for a
  reproducible boot chain.
* **WPS LED.** Unresolved: the pad the vendor's LED table assigns to WPS is not a
  plain GPIO here (another pin function claims it and it does not respond), so no
  LED node is declared. The WPS *button* works.
* **Watchdog and thermal.** No watchdog is armed -- `/dev/watchdog` does not exist
  and `/sys/class/watchdog` is empty, because the Airoha watchdog driver only
  starts when userspace opens it `[hardware]`. The thermal block is disabled in the
  target config `[not verified]`.
* **Package upgrades.** The target has no official package repository for its
  *kernel modules* (`FEATURES:=source-only` means no `kmods/` directory is
  published for `airoha/en7523`), so every `kmod-*` the image needs is baked into
  it. New userspace packages install fine from the generic feeds, but `apk upgrade`
  must not be run: 12 installed packages are behind, one a `zlib` major-version
  change that can take the whole userland (and SSH) down. Modules that are not
  baked in can be added from the repository CI publishes per release -- see
  [packages.md](packages.md) for the URL, which is keyed to the release tag because
  a module only loads into the kernel it was built against. `[not verified]` on
  hardware: the pipeline is written and tested, **no release has been published
  yet**.
* **Image size limits.** `IMAGE_SIZE` is not set, so an oversized image is
  truncated at flash time rather than rejected at build time. `[not verified]`

## How to reproduce the "done" claims

From a freshly built image, with no manual writes, these must hold.

```sh
# --- M1: boot ---------------------------------------------------------------
head -1 /proc/meminfo        # expect MemTotal around 480 MB (512 MiB minus ATF/NPU)
cat /proc/mtd                # 7 partitions on an initramfs build; 10 on the
                             # squashfs build, mtd3 still tclinux_slave

# --- PCIe and Wi-Fi ---------------------------------------------------------
# the two EN7523 root ports, not the endpoints
cat /sys/bus/pci/devices/0000:00:00.0/config | hexdump -C | head -1   # expect 0146 at +4
cat /sys/bus/pci/devices/0001:00:01.0/config | hexdump -C | head -1

dmesg | grep -E 'HW/SW Version|WM Firmware|WA Firmware'
iw dev                       # radios enabled: phy0-ap0 / phy1-ap0, 20.00 dBm
iwinfo                       # per-radio mode, channel, txpower, current rate

# --- Ethernet (DSA) ---------------------------------------------------------
dmesg | grep -E 'mt7530|lan[1-4]'
ls /sys/class/net            # eth0, lan1..lan4, br-lan, phy0-ap0, phy1-ap0
ls /sys/class/net/br-lan/brif/    # bridge members
cat /sys/class/net/lan4/speed     # 1000 with a gigabit link on that port
ip -4 addr show br-lan            # 192.168.1.1/24
ip route                          # default route, when a WAN uplink is present

# --- sysupgrade -------------------------------------------------------------
sysupgrade -T /tmp/<image>.bin    # image test; writes nothing
sysupgrade /tmp/<image>.bin       # erase and write slot B, then reboot
# after the reboot, with the configuration kept:
mount | grep overlay              # /dev/ubi0_0 on /overlay type ubifs (rw)
dmesg | grep -E 'UBI: auto-attach|UBI: attached mtd7'

# --- LEDs and buttons -------------------------------------------------------
ls /sys/class/leds/          # blue:inet blue:power green:pon red:los mt76-phy0 mt76-phy1
cat /sys/class/leds/blue:power/brightness    # 1, from default-state = "on"
cat /sys/class/leds/mt76-phy0/trigger        # [phy0tpt]
logread -f                   # then press a key: procd runs the matching rc.button script
```

Two warnings while checking the LEDs: read the `trigger` attribute, never write
it (writing it on this kernel crashes the LED core), and do not hold `reset` for
5 s or more unless you want a factory reset.

If the root ports show `0140` instead of `0146`, the PCI fixup did not apply, and
Wi-Fi will time out no matter what else is right. If `sysupgrade` refuses the
image or writes nothing, check that `platform.sh` is present with
`PART_NAME="tclinux_slave"` and that `/dev/mtd*` exists at all.
