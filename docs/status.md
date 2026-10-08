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
| **M3** | Optical | `en7571` probes, hwmon exposes bias/temperature, `tx_enabled=1` | not started |
| **M4** | GPON O5 + OMCI | `GPON netdev link ready: O5=1 OMCI=1`, OLT accepts the ONU, OMCI MIB replies | not started |

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
Detail: [leds.md](leds.md).

### Network identity

The MT7916 EFuse on this unit is blank, so the driver falls back to the default
`mt7916_eeprom.bin` blob. That blob carries a zero MAC out of the box, which makes
the driver invent a new address on every boot; writing your own unit's address into
the blob (`tools/mt7916_eeprom_mac.py`) gives the interfaces a stable identity
`[hardware]`. This is not per-unit calibration: the real per-unit data (MAC, GPON
identity, laser BOB) sits in the vendor factory block in the trailing raw region
and is **not** read yet. See [wifi.md](wifi.md) and [hardware.md](hardware.md).

## M3 / M4 -- not started

Nothing optical has run, but the port is no longer unmapped `[not verified]`:

* the community xPON and optical sources were compiled object by object against
  this kernel (6.18.54): **32 of 34 objects build clean**, including all of
  `net/xpon/**` (14/14) and `drivers/net/optical/**` (15/15);
* the two that fail (`airoha_xpon.o`, `airoha_gpon_omci.o`) fail only because of a
  header API mismatch in `airoha_eth.h` -- the community Ethernet driver and the
  OpenWrt one have diverged, and 17 `airoha_eth_*` hooks plus a set of types and
  macros are missing;
* one real API drift was found and fixed on the way: the pcs-provider API changed
  between 6.18.44 and 6.18.54, so `pcs-en7523.c` needs
  `devm_fwnode_pcs_add_provider()` instead of `fwnode_pcs_add_provider()`.

The stage 2 device tree overlay
[`en7523-vgp42x6v1-pon.dtsi`](../openwrt/overlay/target/linux/airoha/dts/en7523-vgp42x6v1-pon.dtsi)
records the register windows, interrupts and reset bits recovered from the stock
device tree. It is not included by the board device tree and would not compile
today, because the bindings it references do not exist yet. Status and next steps:
[pon-port.md](pon-port.md).

## Still broken or open

* **PON and optical (M3, M4).** Nothing has been run on hardware.
  `[not verified]`
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
* **Package upgrades.** The target has no official package repository
  (`FEATURES:=source-only`), so every `kmod-*` must be baked into the image. New
  userspace packages install fine from the generic feeds, but `apk upgrade` must not
  be run: 12 installed packages are behind, one a `zlib` major-version change that
  can take the whole userland (and SSH) down.
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
