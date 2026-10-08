# Documentation

Start with the [project README](../README.md) if you have not read it. These
documents assume you know what the device is and roughly what state the port is
in.

## Read these in order

| Document | Contents | Read it when |
|---|---|---|
| [hardware.md](hardware.md) | SoC, memory map, SPI-NAND, the full partition table, PCIe, UART, optical, safe-to-write rules | you are touching the device at all |
| [status.md](status.md) | Milestones M1-M4, what is proven on hardware, what is not, and how to reproduce the claims | you want to know what actually works |
| [roadmap.md](roadmap.md) | Prioritised remaining work with acceptance tests | you are deciding what to do next |

## Problem write-ups

| Document | Contents |
|---|---|
| [pcie-root-cause.md](pcie-root-cause.md) | The central bug of this project: why the MT7916 could not DMA, how it was proven, and the fix. Includes the hazard that costs you a power cycle, and one retracted dead end. |
| [wifi.md](wifi.md) | MT7916 bring-up: mandatory module load order, why `modprobe` is unusable, and the eeprom packaging gap that made probe fail with `-110`. |
| [ethernet.md](ethernet.md) | Where the four GbE ports come from: the adopted EN7523 patch series, the internal MT7530 switch driven over MMIO, the port map, and the kconfig traps that go with it. |
| [leds.md](leds.md) | Front-panel LEDs and buttons: how the WLAN LEDs are wired, why they used to stay on with the radio off, and the three mt76 patches that make them follow the radio. |

## Not working yet

| Document | Contents |
|---|---|
| [pon-port.md](pon-port.md) | The xPON/optical port: what compiles, what the `airoha_eth.h` API mismatch blocks, and what the optional stage 2 material contains. |

## Procedures

| Document | Contents |
|---|---|
| [booting.md](booting.md) | Boot chain, the `TEXT_OFFSET`/load-address contract, the RAM-boot procedure, how to get a file onto the device, console-paste limits, recovery, flash-write safety |
| [building.md](building.md) | Prerequisites, applying the overlay, the mandatory kernel options, package seeding, building, verifying, bumping the pinned revision |
| [sysupgrade.md](sysupgrade.md) | Persistent install: `MTD_BLOCK` and devtmpfs, `platform.sh`, writing slot B, which regions are safe to write, and what survives an upgrade |
| [image-builder.md](image-builder.md) | Why the upstream Image Builder cannot build this board, and how to produce and use this project's own |

## Background

| Document | Contents |
|---|---|
| [reverse-engineering.md](reverse-engineering.md) | How the vendor firmware was taken apart: image formats, the `romfile`, FIT/DTB recovery, the factory block, disassembly notes |

## Conventions used throughout

* Addresses are physical and hexadecimal, written `0x...`.
* "slot A" is `tclinux`, the stock firmware. "Slot B" is `tclinux_slave`, where
  OpenWrt is written.
* **`mtdN` numbers depend on whose partition table you are looking at, and the
  two schemes differ.** Under the OpenWrt device tree in this repository there
  are 7 partitions, and slot B is **`mtd3`**. Under the *vendor* firmware's
  `/proc/mtd` there are 11 entries, slot B is **`mtd7`**, and `mtd3` is slot A's
  rootfs. Every `mtdN` in these documents refers to the OpenWrt numbering unless
  it says otherwise. This matters most for tools that take an `--mtd` argument:
  writing with the wrong scheme damages the stock firmware rather than leaving it
  alone. See [booting.md](booting.md).
* Where evidence is incomplete, the documents say so explicitly rather than
  filling the gap. If you find such a statement and can resolve it, that is a
  welcome contribution.
* The per-unit GPON serial number is redacted as `<SERIAL>`, because this
  repository is public. Any statement about GPON identity is about the format and
  location of the data, not its value.
