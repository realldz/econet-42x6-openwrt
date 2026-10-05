# Status

What is actually proven on hardware, what is not, and how you can tell the
difference. Last verified against a clean boot of the `wifi-fix` build.

The milestone definitions are taken from the original gap analysis, so that a
milestone is only "done" when its stated acceptance test passes.

## Milestones

| | Milestone | Acceptance test | State |
|---|---|---|---|
| **M1** | Boot to userspace over RAM | shell on the console, `/proc/mtd` lists the partitions, 512 MiB reported | **done** |
| **M2** | Bring-up outside PON | SPI-NAND + BMT, 4x GbE switch, PCIe MT7916, LEDs/buttons, `data` overlay. "LAN up, Wi-Fi up, reboot keeps config" | **partial** |
| **M3** | Optical | `en7571` probes, hwmon exposes bias/temperature, `tx_enabled=1` | not started |
| **M4** | GPON O5 + OMCI | `GPON netdev link ready: O5=1 OMCI=1`, OLT accepts the ONU, OMCI MIB replies | not started |

## M1 -- done

Verified from a clean boot, with no manual register writes:

* the console reaches a shell and `procd` runs;
* PSCI v1.1, two CPUs, GICv3;
* SPI-NAND is detected with the expected 7 partitions;
* both PCIe root ports enumerate, and both MT7916 functions are visible.

The milestone was blocked for a long time by a problem that produced no output
at all: the `airoha` target lacked an `arch/arm` `TEXT_OFFSET`, so the kernel
deadlooped in `head.S` before it could print. See
[docs/booting.md](booting.md).

## M2 -- partial

### Done

**PCIe + Wi-Fi.** Both EN7523 root ports now reach `PCI_COMMAND=0x0146` on a
clean boot, with no manual writes. The MT7916 loads its firmware, and a
`wlan0` interface appears at 20 dBm. Two fixes were needed:

1. a PCI fixup for the EN7523 root complex, whose bogus BAR0 stops
   `pci_enable_resources()` from ever enabling Memory Space and Bus Master on
   the bridge -- so the Wi-Fi card's DMA never reached DRAM. Write-up:
   [docs/pcie-root-cause.md](pcie-root-cause.md).
2. the mt76 package was not installing the default `*_eeprom*.bin` blobs, so
   the fallback path that a blank-EFuse board needs could not complete. See
   [docs/wifi.md](wifi.md).

**SPI-NAND reads.** The partition map in the board device tree matches
`/proc/mtd` on real hardware.

### Not done

**NAND persistence and sysupgrade.** Three separate gaps:

* the stock `en7523` kernel config sets neither `CONFIG_MTD_BLOCK` nor
  `CONFIG_MTD_CHAR`, so the initramfs has no `/dev/mtd*` at all. This
  repository adds both in
  `openwrt/patches/0003-target-airoha-en7523-enable-board-kernel-options.patch`,
  but that has **not yet been built and booted**;
* the `airoha` target ships no `base-files/lib/upgrade/platform.sh`, so there is
  no `platform_do_upgrade` for `sysupgrade` to call. Writing that is roadmap
  item 1;
* the bad-block table is **not** a missing driver. An Airoha BMT implementation
  is already in the OpenWrt tree and is enabled for `an7581`/`an7583`; the
  `en7523` subtarget simply does not set `CONFIG_MTD_NAND_MTK_BMT`. Adopting it
  needs verification first, because it would make the kernel the owner of the
  vendor's bad-block mapping. See [roadmap.md](roadmap.md).

Consequence today: every reboot loses all state, and running OpenWrt means
re-doing the manual RAM-boot procedure.

**Ethernet.** The 4x GbE switch is not driven. The mainline `airoha_eth` driver
supports only `en7581`/`an7583`; nothing handles this SoC's frame engine. This is
the biggest single gap. A community tree that does handle it is identified in
[docs/roadmap.md](roadmap.md).

**Automated boot.** Vendor U-Boot (2014.04-rc1, `ECNT>` prompt) cannot parse
OpenWrt's FIT image and fails with `Parse main image fail`, so it falls through
to the prompt. Booting OpenWrt is therefore a manual `flash read` plus `bootm`.

**Per-unit calibration.** Because the EFuse is blank, Wi-Fi uses the default
eeprom blob. There is no per-unit calibration and the MAC address is random. The
real data is in the `factory` partition and is not read yet.

**LEDs, buttons, thermal, watchdog.** Not configured. The board device tree has
no LED or button nodes, because none were established with confidence.
`kmod-gpio-button-hotplug` was in the earlier experimental image but has been
removed from the default package list until the device tree actually describes a
button.

## M3 / M4 -- not started

The xPON and optical drivers are not in OpenWrt. The material for the port is
collected in [`openwrt/pon/`](../openwrt/pon/README.md): the source inventory, the
six minimal hook patches, and an analysis of the 14 `airoha_eth_*xpon*()` APIs
that would have to be ported by hand. None of it has been built or run.

The stage 2 device tree overlay
[`en7523-vgp42x6v1-pon.dtsi`](../openwrt/overlay/target/linux/airoha/dts/en7523-vgp42x6v1-pon.dtsi)
records the register windows, interrupts and reset bits recovered from the stock
device tree. It is not included by the board device tree and would not compile
today, because the bindings it references do not exist yet.

## How to reproduce the "done" claims

From a freshly built image, with no manual writes, these must hold:

```sh
# the two EN7523 root ports, not the endpoints
cat /sys/bus/pci/devices/0000:00:00.0/config | hexdump -C | head -1   # expect 0146 at +4
cat /sys/bus/pci/devices/0001:00:01.0/config | hexdump -C | head -1

dmesg | grep -E 'HW/SW Version|WM Firmware|WA Firmware'
iw dev          # expect a managed interface with a txpower of 20.00 dBm
cat /proc/mtd   # expect 7 partitions
```

If the root ports show `0140` instead of `0146`, the PCI fixup did not apply, and
Wi-Fi will time out no matter what else is right.
