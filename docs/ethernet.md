# Ethernet bring-up: the 4-port GbE switch

The Econet vGP-42X6V1 (Airoha EN7523) has four gigabit Ethernet ports driven by a
switch block inside the SoC -- there is no external switch chip. This document
covers the kernel and device-tree work that makes them usable under OpenWrt: the
adopted patch series, what the board device tree declares, the two kernel options
that are mandatory rather than optional, why the subtarget needs its own
`02_network`, and what was actually proven on hardware.

The short version: **the four ports work.** All four PHYs probe, a port with a
cable comes up at 1 Gbps, `br-lan` holds the four DSA user ports (`lan1`..`lan4`)
instead of the DSA conduit, and a port moved to WAN by ordinary UCI/LuCI
configuration carried DHCP, DNS and HTTP traffic to the internet. Section 7 lists
what is *not* done, including the whole PON/USB serdes path, which is compiled
out. Hardware background is in [hardware.md](hardware.md) section 7; Wi-Fi and
PCIe are [wifi.md](wifi.md) and [pcie-root-cause.md](pcie-root-cause.md).

## Sources

The lab log is a Vietnamese bring-up log kept in the research workspace, outside
this repository. Every "what the patch does" statement comes from the patch text
itself.

| Source | Used for |
|---|---|
| `docs/econet/42X6_openwrt_m4_ethernet.md` (research workspace) | the patch list, the kconfig failure, the frame-engine hang, the first flash, the `board.json` trap, the WAN discovery |
| [../openwrt/overlay/target/linux/airoha/patches-6.18/](../openwrt/overlay/target/linux/airoha/patches-6.18/) | the series |
| [../openwrt/overlay/target/linux/airoha/dts/en7523-vgp42x6v1.dts](../openwrt/overlay/target/linux/airoha/dts/en7523-vgp42x6v1.dts) | the `eth`/`gdm1`/`switch` nodes, port labels, PHY addresses |
| [../openwrt/overlay/target/linux/airoha/base-files/lib/upgrade/platform.sh](../openwrt/overlay/target/linux/airoha/base-files/lib/upgrade/platform.sh) | how `/etc/board.json` interacts with `board.d` |
| the subtarget `config-6.18` and `base-files/etc/board.d/02_network` | kernel options and interface naming; build-tree files (sections 4 and 5), not files in this repository |
| [hardware.md](hardware.md) section 7 | the vendor port map, and which compatibles the upstream driver matches |

## 1. Why stock OpenWrt cannot drive it

The EN7523 Ethernet block is the FE/GDM/QDMA family -- the same family the
`airoha_eth` driver handles, but a different generation. There were two
independent gaps:

| Gap | Evidence |
|---|---|
| No compatible for this SoC | the `airoha` target's `airoha_eth` matches only `airoha,en7581-eth` and `airoha,an7583-eth` |
| The device tree does not describe it | `dts/en7523.dtsi` has only `uart1`, `gpio0`/`gpio1`, `pcie0`/`pcie1`, SPI+NAND, SCU and GIC -- no `ethernet`, `gdm*` or `switch` node |

So this was not a missing module or option: nothing could bind, and nothing
described the hardware. `CONFIG_NET_AIROHA` is already enabled in the subtarget, so
the driver source compiled -- it simply never matched a device.

## 2. The patch series

The community driver was not adopted wholesale. EN7523 support was taken as a
**numbered patch series** in
[`openwrt/overlay/target/linux/airoha/patches-6.18/`](../openwrt/overlay/target/linux/airoha/patches-6.18/),
so the deviation from the pinned upstream revision stays explicit. The series came
from the community kernel tree `airoha_kernel`, branch `airoha_en7523_all`
(section 8).

| Patch | What it does |
|---|---|
| [930-42](../openwrt/overlay/target/linux/airoha/patches-6.18/930-42-airoha_en7523_all-airoha_en7523_eth-allocate-GDM-ports-before-QDMA-hw-.patch) | Allocate the GDM ports **before** bringing up the QDMA hardware. GDM allocation reads the port MAC, which a late-registering nvmem provider may answer with `-EPROBE_DEFER`; on that defer the old error path ran `airoha_hw_cleanup()` -> `page_pool_destroy()` while RX DMA was already live, which busy-waits for pages that are never returned, live-locks against the RX softirq and hangs the CPU, so the deferred probe is never retried. Adds an `error_ports_free` label for the pre-hardware unwind. |
| [930-43](../openwrt/overlay/target/linux/airoha/patches-6.18/930-43-airoha_en7523_all-net-dsa-mt7530-Add-EN7523-support.patch) | DSA `mt7530`: EN7523 support -- new `airoha,en7523-switch` compatible and `ID_EN7523`, the mirror-register macros extended to it, the CPU port map (`MT7531_CFC`) applied for it, Special Tag enabled for RX frames, PMCR setup for port 6 (`RXCRC_EN`, IFG, MAC mode, backoff, backpressure), `MT7530_DBGGCR`/`MT7530_CKGCR` writes, and the indirect c22/c45 PHY accessors in the chip table. |
| [930-44](../openwrt/overlay/target/linux/airoha/patches-6.18/930-44-airoha_en7523_all-net-dsa-mt7530-Enable-LED-controller-for-EN7523.patch) | Configure the MediaTek GPHY LED registers (MMD VEND2 `0x24`-`0x27`) on PHY 9..12 after the PHY reset, which the bootloader's LED configuration does not survive: LED0 on when the link is up, LED0 blinking on TX/RX at all speeds. Writes through the indirect switch path because these PHYs sit behind the switch, restores SCU `GPIO_2ND_I2C_MODE` (`0x0210`) to `0x2a8` after the switch reset as a safety net, and logs the four registers back for PHY 9. |
| [930-45](../openwrt/overlay/target/linux/airoha/patches-6.18/930-45-airoha_en7523_all-net-airoha-Add-EN7523-SoC-support.patch) | **The main body**: EN7523 SoC support for the frame engine -- `.compatible = "airoha,en7523-eth"` with a new `en7523_soc_data` (`rx_ring 16`, `tx_ring 8`, `num_ppe 1`, `ppe_sram_entries 512`, `ppe_dram_entries 16 * 1024`, `irq_banks 2`, three XSI resets), Special Tag in the CDM VLAN control, PSE buffer and share-threshold setup, per-SoC CRSN queue-select masks, and the PPE/debugfs/register definitions. 3055 lines, 5 files. |
| [930-46](../openwrt/overlay/target/linux/airoha/patches-6.18/930-46-airoha_en7523_all-en7523-introduce-pcs.patch) | Introduce the EN7523 PCS: a new binding (`airoha,en7523-pcs.yaml`), a new `drivers/net/pcs/airoha/pcs-en7523.c` (652 lines), and the Kconfig/Makefile entries for SGMII/HSGMII. |
| [930-47](../openwrt/overlay/target/linux/airoha/patches-6.18/930-47-airoha_en7523_all-net-pcs-airoha-en7523-init-PON-serdes-SGMII-2500Base.patch) | PON serdes analog PMA init for SGMII/2500Base-X. The PON PCS has `phya = INVALID`, so mainline never initialises the analog PMA, while the attached PHY wants an SGMII (1.25G) serdes at 1G and 2500Base-X (3.125G) at 2.5G; without the PMA bring-up the serdes link never establishes and the XSI-AE MAC stays in local fault. Pulses the serdes + XSI-MAC clock-domain reset, then programs SSR3/WAN_CONF and the rate-specific PMA registers (the reset clears them, so they must be written after it), saving and restoring the MAC global config across the reset. |
| [930-48](../openwrt/overlay/target/linux/airoha/patches-6.18/930-48-airoha_en7523_all-net-airoha-restrict-supported-interfaces-for-SGMII-p.patch) | Restrict `supported_interfaces` for SGMII ports: advertise 2500BASEX/10GBASER/USXGMII only when the port is not SGMII or 1000BASEX. Otherwise a PHY attached in SGMII mode sees 2500BASEX in its host interfaces, forces its serdes to 2500Base-X rate-match, and never links against an SGMII PCS. |
| [930-49](../openwrt/overlay/target/linux/airoha/patches-6.18/930-49-airoha_en7523_all-net-pcs-airoha-en7523-init-USB-PCIe-XSI-serdes.patch) | Init the USB/PCIe0/PCIe1 XSI serdes: write the rate-adapt/AN/PCS-control values and pulse the per-port clock-domain reset through SCU `RST_CFG` (PCIe0 `0x12000`, PCIe1 `0x24000`, USB `0x48000`), saving and restoring the MAC global config. These serdes have a real `phya`, so no analog PMA poke is needed; what mainline omits is the reset pulse and those values. |
| [930-50](../openwrt/overlay/target/linux/airoha/patches-6.18/930-50-airoha_en7523_all-net-airoha-en7523-support-the-GDM3-USB-serdes-port.patch) | Wire up the GDM3 USB serdes port: grow the per-port device array from 2 to 3, map the USB source port at `nbq == 6` (it was `nbq == 1`) in `get_sport()`/`get_vip_port()`, and map it to device index 2 in the RX source-port lookup. |
| [930-51](../openwrt/overlay/target/linux/airoha/patches-6.18/930-51-airoha_en7523_all-net-pcs-airoha-en7523-fix-PON-1000Base-X-rate-setup.patch) | PON 1000Base-X rate fix: run the SGMII-rate PON PMA sequence for `PHY_INTERFACE_MODE_1000BASEX` too (some SFP/copper modules resolve as 1000Base-X while the host serdes still runs at 1.25G), and keep the PON PCS `link_up()` path active with in-band negotiation so the resolved speed reaches the rate-adapt state. This is the case where the module reports 1G/full but the XSI/GDM2 RX counters stay at zero. |

Two things to know before editing the series. **930-45 is 3055 lines and was re-cut
locally** with `diff -Naur` between snapshots (hence its `sN/` path prefixes);
930-43 was re-cut the same way, and a hand-regenerated patch is where a shifted hunk
or missing file is most likely -- blame 930-45 first for a strange runtime symptom.
And **the OpenWrt kernel patch stamp is keyed on the file list, not the contents**:
adding or removing one file in `patches-6.18/` invalidates the stamp and forces a
full kernel re-prepare even if a single line changed, so keep the file list stable
across an edit-build loop and keep backups out of the patch glob.

### 2.1 The prerequisite that is not an Ethernet patch: 610

[610-42x6-clk-en7523-fix-uninitialized-val-in-reset-update.patch](../openwrt/overlay/target/linux/airoha/patches-6.18/610-42x6-clk-en7523-fix-uninitialized-val-in-reset-update.patch)
is one line long and is the reason the first Ethernet images never booted. OpenWrt's
own downstream patch `609-02` (dedicated PCIe PERSTOUT reset) rewrites
`en7523_reset_update()` to build the value in a local and `|=` into it, without
initialising it:

```c
	u32 val;                    /* never initialised */
	if (addr == REG_NP_SCU_PCIC)              /* PCIC reset logic is inverted */
		val |= assert ? 0 : BIT(id % RST_NR_PER_BANK);
	else
		val |= assert ? BIT(id % RST_NR_PER_BANK) : 0;
	regmap_update_bits(rst_data->map, addr, BIT(id % RST_NR_PER_BANK), val);
```

The mask is a single bit, so the value written *is* that bit: the `assert` branch
always writes 1, and the `deassert` branch writes whatever the stack slot held --
usually a value with the frame-engine bit set. Linux therefore believed it had
released the frame engine while bit 21 of SCU `RST_CTRL1` (`0x1fb00834`) was still
asserted. The first MMIO read into the FE (`0x1fb50500`, `REG_GDM_FWD_CFG(1)`) then
hung the CPU permanently: the AXI slave never answers and there is no bus timeout.
The symptom was a boot that stopped dead inside the first iteration of
`airoha_fe_maccr_init()`, with a console that simply went quiet.

The fix is `u32 val = 0;`, which restores the pre-`609-02` semantics exactly because
the mask is one bit. It affects every non-PCIC reset line, not only Ethernet, and it
is an OpenWrt-tree bug rather than a mainline one. Confirmed on hardware: with the
patch, the same board boots to userspace and `airoha_driver_init` returns 0.

## 3. Device tree

Three nodes were added to
[en7523-vgp42x6v1.dts](../openwrt/overlay/target/linux/airoha/dts/en7523-vgp42x6v1.dts):
`eth` at line 74, `gdm1` inside it at line 111, and `switch` at line 137.

| Node | Address | Notes |
|---|---|---|
| `eth` | `0x1fb50000` | `airoha,en7523-eth`; windows `fe` `0x1fb50000`+`0x2600`, `qdma0` `0x1fb54000`+`0x2000`, `qdma1` `0x1fb56000`+`0x2000`, `gdmp` `0x1fbf9000`+`0x1000`; seven resets (`fe`, `pdma`, `qdma`, `hsi0-mac`, `hsi1-mac`, `hsi-mac`, `gdmp`); ten GIC interrupts; two `memory-region`s for the QDMA rings |
| `gdm1` | `reg = <1>` | `airoha,eth-mac`, `phy-mode = "internal"` -- the MAC port facing the internal switch -- plus a `fixed-link` at 10000 and a `mac-address` |
| `switch` | `0x1fb58000` + `0x8000` | `airoha,en7523-switch`, one `GSW` reset, an interrupt controller on `GIC_SPI 31`, ports 1-4 as `lan1`..`lan4`, and port 6 as the CPU port pointed at `gdm1` by `ethernet = <&gdm1>` |

What matters for interface names and debugging:

* **The port labels are what create `lan1`..`lan4`.** A DSA user port's netdev name
  comes from the port node's `label` property (`port->name <-
  of_get_property(dn, "label")`), which is why `port@1`..`port@4` carry
  `label = "lan1"` .. `label = "lan4"` (lines 154-184).
* **`gdm1` is the DSA conduit and its netdev is `eth0`** -- not a LAN port. The four
  user ports are what belongs in `br-lan`, which is the whole of section 5.
* **`phy-mode = "internal"` is the only mode `gdm1` supports here**, because it is
  wired to the on-chip switch rather than to a PHY or serdes. Port 6 is declared as a
  `fixed-link` at 10 Gbps, which is why the conduit's link state reads `10Gbps/Full`.
* **The four switch PHYs are at MDIO addresses 9, 10, 11 and 12** (nodes
  `ethernet-phy@9`..`@c`, lines 204-222), one per front-panel port.
* **`mac-address` on `gdm1` is not cosmetic.** The driver calls
  `of_get_ethdev_address()`; with no such property and no nvmem cell it falls back to
  `eth_hw_addr_random()` and the board gets a new address every boot (the vendor
  U-Boot `ethaddr` is not passed to Linux). With it, `eth0` and all four user ports
  share the intended address and `addr_assign_type` is 0. The value is redacted here
  (see [docs/README.md](README.md)); the upstreamable form is an nvmem cell reading
  the U-Boot environment partition.

One caveat, seen from the bootloader prompt rather than Linux: the two QDMA windows
read back the same value (`0x106`), so the second window is not a separate register
block. The driver still probes and both NAPI instances are created; nothing in the
log ties that overlap to a failure.

Every node and value above can be checked against a real image rather than taken on
trust: [`tools/dts_vs_image.py`](../tools/dts_vs_image.py) pulls the DTB out of a
`*-sysupgrade.bin` without `dtc` and compares it with
[`en7523-vgp42x6v1.dts`](../openwrt/overlay/target/linux/airoha/dts/en7523-vgp42x6v1.dts),
cell by cell. On the recorded image it reports all 129 declared properties present,
the two `/delete-node/` directives honoured (no `gpio@1fbf0200`, no `gpio@1fbf0270`),
and exactly one difference -- `mac-address`, which is redacted here.

## 4. Kernel options

The Ethernet options live in the subtarget's `config-6.18`:

```text
CONFIG_NET_DSA=y
CONFIG_NET_DSA_TAG_MTK=y
CONFIG_NET_DSA_MT7530=y
# CONFIG_NET_DSA_MT7530_MDIO is not set
CONFIG_NET_DSA_MT7530_MMIO=y
CONFIG_MEDIATEK_GE_SOC_PHY=y
# CONFIG_PCS_AIROHA_EN7523 is not set
```

The two `is not set` lines are mandatory, and not for tidiness. OpenWrt
**regenerates** `$(LINUX_DIR)/.config` from the generic and subtarget fragments on
every Configure, so answering `oldconfig` interactively is never remembered -- the
value must be in the fragment. And the series adds brand-new Kconfig symbols:
`NET_DSA_MT7530` implies `NET_DSA_MT7530_MDIO`, and `PCS_AIROHA_EN7523` is introduced
by 930-46. A symbol that exists in the sources but not in the fragment is `(NEW)`,
so kconfig asks `[Y/n/m/?]` on a machine with no terminal and `syncconfig` dies with
`scripts/kconfig/Makefile:85: syncconfig Error 1`; the only visible output is
`ERROR: target/linux failed to build.`, which is why **you should build with `V=s`
when a config error is suspected.** This board uses the MMIO variant, so the MDIO
variant must be off; the PCS code is deliberately off at this stage (section 7).

The role of `CONFIG_MEDIATEK_GE_SOC_PHY` is **not** established by an isolated test
in the sources: it was enabled with the block, and the switch PHYs bind to the
generic PHY driver in the boot log. Treat that line as "enabled with the block", not
as "proven necessary".

## 5. Why the subtarget needs its own `02_network`

OpenWrt picks the default LAN device from `/etc/board.d/*`. This subtarget shipped
no `board.d` directory, so only the generic
`package/base-files/files/etc/board.d/99-default_network` ran, and it sets
`network.lan.device = 'eth0'` -- which on this board is the DSA conduit, not a LAN
port. The observed consequences, in order:

| Step | Result |
|---|---|
| `br-lan` is built from `eth0` | the four DSA user ports stay outside the bridge |
| `ip link set lan4 master br-lan` | `RTNETLINK answers: Invalid argument` -- DSA refuses to enslave a user port while the switch's conduit is already in that bridge |
| a PC plugged into a port | no DHCP lease, and the port is in no firewall zone, so input is rejected: `ping` answers `Destination port unreachable`, TCP 22 reports `TcpTestSucceeded : False` |

The fix is a subtarget board.d script naming the four user ports as LAN:

```sh
. /lib/functions/uci-defaults.sh
case "$(board_name)" in
econet,vgp-42x6v1)
	board_config_update
	ucidef_set_interface_lan "lan1 lan2 lan3 lan4"
	board_config_flush
	;;
esac
exit 0
```

After that, `config_generate` writes `/etc/board.json` with
`"ports": ["lan1","lan2","lan3","lan4"]` and `/etc/config/network` with a `br-lan`
device whose `ports` list is exactly those four; `eth0` stays out of it.

A second trap makes this look like it did not work: `board.d` only runs when
`/etc/board.json` is missing (`[ -s $CFG ] || /bin/board_detect || exit 1` in
`bin/config_generate`), and `/etc/board.json` is not part of the image -- it is
generated at first boot and lives in the overlay, which a sysupgrade into
`tclinux_slave` does not touch. A freshly flashed image was therefore observed still
using the *old* `board.json` and the *old* conduit-only bridge, never consulting the
new `02_network`. The fix used here is on the upgrade path:
[`platform.sh`](../openwrt/overlay/target/linux/airoha/base-files/lib/upgrade/platform.sh)
deletes `/etc/board.json` and the overlay copy of `/etc/config` in
`platform_pre_upgrade()` when the user asked for a clean install, so the next boot
regenerates both from `board.d`. Its header documents the mechanism, including why
`SAVE_CONFIG` cannot be used to detect that decision.

## 6. What is proven on hardware

The board is a vGP-42X6V1 running the built image from SPI-NAND. Every log line
below is from the acceptance sessions recorded in the research workspace log.

### 6.1 Four PHYs, and a link at 1 Gbps

```console
[    7.48] mt7530-mmio 1fb58000.switch: EN7523: PHY LED readback: 0x24=0xc007 0x25=0x3f 0x26=0xc000 0x27=0x0
[    7.51] eth0: Link is Up - 10Gbps/Full - flow control rx/tx
[    7.51] PHY [mt7530-0:09] ... [mt7530-0:0a] ... [mt7530-0:0b] ... [mt7530-0:0c] driver [Generic PHY] (irq=POLL)
[    7.58] DSA: tree 0 setup
[   21.19] mt7530-mmio 1fb58000.switch lan4: Link is Up - 1Gbps/Full - flow control rx/tx
[   21.23] br-lan: port 4(lan4) entered forwarding state
```

All four PHYs register (`09`..`0c`, one per port; that PHY line is four log lines
compressed into one). A cable in port 4 gives a 1 Gbps full-duplex link and the
bridge port goes to forwarding. `eth0`, the conduit, shows the device tree's 10 Gbps
`fixed-link` rather than a real copper speed.

### 6.2 DSA user ports and the bridge

```console
2: eth0            <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1504 state UP      <- conduit, on its own
3: lan1@eth0       ... master br-lan state LOWERLAYERDOWN
4: lan2@eth0       ... master br-lan state LOWERLAYERDOWN
5: lan3@eth0       ... master br-lan state LOWERLAYERDOWN
6: lan4@eth0       <BROADCAST,MULTICAST,UP,LOWER_UP> master br-lan state UP <- cable, 1 Gbps
7: br-lan          <BROADCAST,MULTICAST,UP,LOWER_UP> ... 192.168.1.1/24
```

The `lanN@eth0` names show both halves of the design: the netdev names come from the
device-tree port labels, and the `@eth0` suffix shows they are DSA user ports hanging
off the conduit. `br-lan` holds the four of them and not `eth0`. From a PC on the
LAN, `ping` to 192.168.1.1 succeeded 3/3 with TTL 64 and TCP 22 succeeded with the
firewall enabled -- over a port that needed no configuration at all.

### 6.3 Interrupts and counters

```console
 33:       4807          0    GICv3  69 Level     airoha_eth.0      <- frame engine
 34:          0          0    GICv3  87 Level     airoha_eth.1      <- GDM2 (PON, unused)
 35:          0          0    GICv3  70 Level     airoha_eth.4      <- GDM3 (USB, unused)
 37:          0          0    GICv3  63 Level     mt7530
```

The frame engine is really taking interrupts, so the datapath is not idle-polled. The
switch interrupt stays at 0 because the PHYs are polled (`irq=POLL` above) -- the
current design, not a fault. `airoha_eth.1` and `airoha_eth.4`, the PON and USB GDMs,
stay at 0 because nothing uses them yet. Counters from the same session, after
roughly twelve minutes with a cable in port 4 only:

```console
  lan4:  329902 B / 2758 pkt RX   255727 B / 1163 pkt TX   (the port with the cable)
  eth0:  319150 B / 2762 pkt RX   252723 B / 1179 pkt TX   (conduit)
  lan1 / lan2 / lan3:  0 / 0       (nothing plugged in -> no packets)
```

That `lan1`..`lan3` are exactly zero while `lan4` carries traffic is the evidence
that these are genuinely separate ports with separate PHYs, not one interface
presented four times.

### 6.4 Reaching the internet through a port moved to WAN

The four-port LAN layout is the default (section 7). A user who wants an Ethernet WAN
takes a port out of `br-lan` and creates a `wan` interface on it. That is ordinary
UCI/LuCI configuration, it was done, and it works:

```console
ip -4 a   : lan1@eth0  inet <upstream lease>/24  UP,LOWER_UP mtu 1500
ip route  : default via <upstream gateway> dev lan1
            192.168.1.0/24 dev br-lan
ping <upstream gateway> : 2/2 packets, 0.45 ms
ping 1.1.1.1            : 2/2 packets, 25.5 ms
wget -q -O /tmp/dl.html http://downloads.openwrt.org/   -> rc=0
firewall  : zone wan { input REJECT; output ACCEPT; forward DROP; masq 1; mtu_fix 1 }
```

Attribution is part of the evidence, because "`lan1` is not in `br-lan`" looks like a
switch-driver bug and is not one: `/etc/config/network` contains
`config interface 'wan' { option proto 'dhcp'; option device 'lan1' }` and its mtime
matches the session; `logread` shows a LuCI login first, then
`netifd: Interface 'wan' is enabled`, then `udhcpc` obtaining the lease; and
`/root/.ash_history` is empty, so nobody typed it over SSH. **The switch and all four
PHYs are healthy; which port is WAN is configuration, not a driver property.** That
configuration lives in `/etc/config/network`, so a clean install (`sysupgrade -n`)
wipes it and the interface has to be created again.

### 6.5 A stable hardware address

With `mac-address` on `gdm1`, `eth0` reports `addr_assign_type = 0` (not random),
`lan1`..`lan4` and `br-lan` all carry that same address, and the IPv6 link-local
address derived from it is EUI-64-correct. The `generated random MAC address` warning
the driver prints when the property is absent does not appear. This also survived a
wipe-and-reinstall, so it is the image, not left-over state.

## 7. What is not done

| Item | State |
|---|---|
| Default port layout | **Four LAN ports, deliberately.** `02_network` declares `lan1`..`lan4` as LAN and there is no default WAN port. A default WAN on one port was considered and rejected: if nothing on the other end answers DHCP that port is silent, and a user plugging into it would lose the web UI path |
| Per-port LED control | **Not bound in the kernel.** The four RJ45 LEDs are driven by the switch's own PHY LED engine, configured by 930-44; there is no LED-class device per port, so no trigger, brightness or label can be set |
| VLANs | **Not configured or tested.** No bridge-VLAN, no per-port split, no VLAN filtering work in the sources. The only VLAN IDs in the log are the ISP's PON service VLANs, which belong to the PON milestone |
| PON and USB serdes | **Compiled out, therefore unverified.** `CONFIG_PCS_AIROHA_EN7523` is not set, so 930-46..930-51 have never been built or run, and GDM2/GDM3 show zero interrupts. Any bug in those six patches is still waiting |
| Throughput | **Measured once, by hand, and it is not good `[hardware]`.** End-to-end throughput peaks at **200-400 Mbit/s** in the owner's acceptance runs. `iperf3` is in the image but no run is recorded, and neither the direction, the client nor the tool of those runs was written down, so treat it as an acceptance figure rather than a benchmark `[not verified]`. It is well below both the 1 Gbps the PHYs negotiate and the 864.8 Mbit/s rate the radio reports, so there is room to gain -- but improving it is not a priority yet; see [roadmap.md](roadmap.md) section 7 |
| Port coverage | **Two of four ports were physically exercised**: port 4 in the first acceptance, port 1 later as the WAN uplink. `lan2` and `lan3` probed their PHYs but never had a cable, so their 1 Gbps link is inferred from the identical PHY setup rather than measured |
| Frame-engine details | The QDMA window overlap in section 3 is unexplained. `.ppe_stats_entries = 0` for this SoC, so PPE statistics cannot be used to diagnose the datapath |
| Other | Jumbo frames, hardware offload, link bonding and EEE are untested. `eth0` reports MTU 1504, which is what the conduit was observed using |

## 8. Provenance and licence

The EN7523 Ethernet support was not written from scratch. It comes from the community
kernel tree **`Sirherobrine23/airoha_kernel`, branch `airoha_en7523_all`** -- the same
tree that is the source of the xPON material in
[`openwrt/pon/`](../openwrt/pon/README.md). The git-format patches keep their original
authorship (`From:`/`Signed-off-by:` name Benjamin Larsson and Matheus Sampaio
Queiroga, addresses anonymised to `noreply@localhost`) and their original position in
the series: 930-42..930-51 carry `[PATCH 042/131]` .. `[PATCH 051/131]`, so they are
ten patches out of 131. 930-44 is authored as `EN7523 port <noreply@localhost>` with
an all-zero commit id, unlike the rest.

What changed locally: 930-43 and 930-45 were re-cut with `diff -Naur` against local
snapshots to adapt them to the pinned OpenWrt revision (hence the `sN/` prefixes; they
apply with `-p1`), and
[610](../openwrt/overlay/target/linux/airoha/patches-6.18/610-42x6-clk-en7523-fix-uninitialized-val-in-reset-update.patch)
is this project's own one-line fix for the OpenWrt-tree reset bug of section 2.1,
placed after `609-02` instead of editing it so the upstream file stays recognisable.

Licensing: the kernel driver patches are GPL-2.0-only, like the kernel and OpenWrt,
and this repository is GPL-2.0-only too (see [../LICENSE](../LICENSE)). The community
tree is a fork of a vendor-derived driver set, so it is a fine source for a local port
and for learning, but before sending any of it upstream the provenance of each file
should be confirmed with the silicon vendor or the ODM.
