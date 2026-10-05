# Root cause: MT7916 Wi-Fi could not work on the Econet vGP-42X6V1 (Airoha EN7523)

Target: Econet vGP-42X6V1 GPON ONU, Airoha EN7523 SoC (2x Cortex-A53 running AArch32),
SPI-NAND, MediaTek MT7916 Wi-Fi behind PCIe, OpenWrt on Linux 6.18.

This document explains one bug: why the MT7916 could never be brought up, and what fixed it.
It is written from the engineering log of the bring-up sessions, and every number, register
name and log line below is taken from that log or from the patch that fixes the bug. Where the
material is inconsistent or a conclusion is uncertain, that is stated explicitly.

The causal chain, in one paragraph:

```
EN7523 root ports expose a bogus BAR 0 (0x0000000c, 64-bit prefetchable, base 0)
  -> the size probe returns an enormous window -> the kernel cannot assign it
  -> pci_enable_resources() returns -EINVAL for both root ports
  -> both root ports keep PCI_COMMAND = 0x0140 (Memory Space = 0, Bus Master = 0)
  -> MT7916 memory reads are never forwarded upstream to DRAM
  -> the MT7916 WFDMA never consumes a single descriptor (cpu_idx advances, dma_idx stays 0)
  -> the first MCU command (0x10, PATCH_SEM_CONTROL) times out
  -> mt7915_mac_reset_work runs on uninitialised state, NULL deref, kernel panic
```

Raw evidence for the log excerpts quoted here (UART captures kept in the bring-up workspace,
outside this repository): `sh_mse_test.out` (session-3 failure chain), `rw_run1.txt` /
`rw_run2.txt` (host-side WFDMA ring polling), `golden_4_pci_cmd_0146_fix.log` (manual
`PCI_COMMAND` experiment), `golden_6_fixed_image_cmd0146_auto.log`,
`golden_7_fixed_image_firmware_ok.log`, `golden_8_fixed_image_wlan0_up.log` (clean boot of the
fixed image).

## 1. Symptom

Nothing about the failure looks like a bus problem at first. The card enumerates, the BARs of
the endpoints are assigned, MSI allocation succeeds, and the register handshake between the
driver and the chip completes. The failure appears only when the driver tries to talk to the
MCU, and the first MCU command of the whole flow is the one that dies.

Clean log, driver loaded by hand on a running system (raw UART capture from the session-3
status log, kept in the bring-up workspace as `sh_mse_test.out`, backing log
`ub_send_20261005_211623.log`):

```
[  651.910435] pci 0000:00:00.0: BAR 0 [mem size 0x00000000 64bit pref disabled]: not assigned; can't enable device
[  651.920704] pci 0000:00:00.0: Error enabling bridge (-22), continuing
[  651.927205] mt7915e_hif 0000:01:00.0: enabling device (0140 -> 0142)
[  651.933934] pci 0001:00:01.0: BAR 0 [mem size 0x00000000 64bit pref disabled]: not assigned; can't enable device
[  651.944181] pci 0001:00:01.0: Error enabling bridge (-22), continuing
[  651.950715] mt7915e 0001:01:00.0: enabling device (0140 -> 0142)
[  657.115318] mt7915e 0001:01:00.0: Retry message 00000010 (seq 1)
[  662.155293] mt7915e 0001:01:00.0: Message 00000010 (seq 1) timeout
[  662.161512] mt7915e 0001:01:00.0: Could not release semaphore
[  662.167307] mt7915e 0001:01:00.0: Failed to get patch semaphore
```

Then the panic, from a raw capture that also had an instrumented module loaded
(`rw_run2.txt`):

```
[  257.195322] mt7915e 0001:01:00.0: Message 00000010 (seq 1) timeout
[  257.201526] mt7915e 0001:01:00.0: Could not release semaphore
[  257.207347] mt7915e 0001:01:00.0: Failed to get patch semaphore
[  257.228916] Internal error: Oops: 817 [#1] SMP ARM
[  257.262993] Workqueue: mt76 mt7915_mac_reset_work [mt7915e]
[  257.512055]  mt76_txq_schedule_all [mt76] from mt7915_mac_reset_work+0xab8/0xd3c [mt7915e]
[  257.520374]  mt7915_mac_reset_work [mt7915e] from process_one_work+0x1a4/0x34c
[  257.581579] Kernel panic - not syncing: Fatal exception in interrupt
```

Facts that made the failure look impossible:

| Observation | Value / evidence |
|---|---|
| Enumeration | MT7916 HIF `14c3:790a` on `0000:01:00.0`, MT7916 WF `14c3:7906` on `0001:01:00.0`; endpoint BARs assigned (`0000:01:00.0` BAR0 `0x20000000-0x200fffff`, BAR2 `0x20100000-0x20107fff`, BAR4 `0x20108000-0x20108fff`) |
| MSI | Allocated successfully: `29: ... dummy ... mt7915e-hif`, `33: ... MTK-PCI-MSI-0001:01:00.0 ... mt7915e` |
| Endpoint enable | `enabling device (0140 -> 0142)`: the endpoint's own Memory Space Enable does get set |
| Register handshake | The driver never prints `Timeout for driver own` nor `Firmware did not enter download state`, so `DRV_OWN` was accepted and the MCU did enter download state |
| First MCU command | `0x10 = MCU_CMD_PATCH_SEM_CONTROL` (`mt76_connac_mcu.h:1374`), sent from `mt7915_load_firmware()` -> `mt76_connac_mcu_patch_sem_ctrl(false)` |
| Timing | Retry after about 5 s, timeout after about 10.2 s, then `mt7915_mac_reset_work` and panic |
| Firmware files | Missing `mt7916_eeprom.bin` was a real but separate defect (see section 7.2); it cannot explain this timeout, because firmware is loaded only after the patch semaphore is acquired |

The `mt7915_mac_reset_work` NULL dereference in `mt76_txq_schedule_pending` is a secondary
bug in mt76 (scheduling on a device state that was never initialised). It is a consequence of
the timeout, not the cause.

## 2. Hazard: an MMIO read with Memory Space disabled hangs the whole SoC until power cycle

> **WARNING -- this mistake costs a power cycle and produces no diagnostic output at all.**
>
> If `PCI_COMMAND.Memory Space Enable` is 0 for a device and you issue a `readl()` against one
> of its memory BARs, the EN7523 root complex turns the access into a master abort. The EN7523
> root complex has **no completion timeout**. `readl()` therefore spins forever, the CPU never
> returns from the access, and because the read is usually done from a softirq (a timer
> callback) the softirqs are blocked: the tty flip buffer is never processed, so the console
> goes permanently silent.
>
> Observed behaviour: **no oops, no panic, no soft-lockup report (the detector is not enabled
> in the image), no watchdog message (there is no watchdog driver), Ctrl-C does nothing,
> pulsing DTR/RTS does nothing, waiting 90 s changes nothing.** Only removing and re-applying
> power recovers the board.
>
> **Mandatory rule:** read `PCI_COMMAND` through config space first (that path is always safe),
> and touch a BAR only when `PCI_COMMAND.MEMORY = 1`.

This trap was hit twice: once while probing an endpoint BAR by hand, and once by an
instrumented module whose timer callback called `readl()` on BAR0 in its very first tick,
before the `mt7915e` driver had been loaded and had enabled the endpoint's Memory Space:

```
[ 1268.346432] ringwatch: loading out-of-tree module taints kernel.
[ 1268.352688] RINGW: <module start line, Vietnamese in the original capture; abbreviated here>
rc=0
~ #                               <- last prompt ever seen; absolute silence afterwards
```

Two related facts are worth recording because they pin down exactly which operations are
dangerous:

* `ioremap()` only builds page tables and does not touch the device, so it is safe even when
  `MemEn = 0`; only the actual `readl()`/`writel()` is dangerous. This is why the fixed version
  of the instrumentation module moved `ioremap()` into its `module_init` and keeps only
  `readl()` behind a `PCI_COMMAND.MEMORY` check.
* Calling `ioremap()` from softirq context is itself a bug on this kernel: `__get_vm_area_node()`
  has `BUG_ON(in_interrupt())`, and on ARM `BUG()` is `udf`, which produced
  `Oops - undefined instruction` with `PC is at __get_vm_area_node+0x120/0x124`.

## 3. Root cause

The EN7523 PCI host driver is matched through the fallback compatible string
`mediatek,mt7622-pcie`, so it runs the MT7622 "v2" bring-up path. Everything about the link
works: the port comes up, the link trains, enumeration runs, the bridge memory windows are
programmed, and the endpoint BARs are assigned correctly.

What is wrong is the **root complex's own BAR 0**. The two root ports are PCI devices in their
own right (`14c3:0810` at `0000:00:00.0`, `14c3:0811` at `0001:00:01.0`), and their config
space reports a garbage BAR 0. Measured dumps:

```
0000:00:00.0:  c3 14 10 08 | 40 01 10 00 | 03 00 04 06 | 10 00 01 00
               14c3:0810    Cmd=0x0140     class 060400   hdr type 01 (bridge)
10: 0c 00 00 00   -> BAR0 = 0x0000000c  (MEM, 64-bit, PREFETCHABLE, base 0)
18: 00 01 01 40   -> bus 0/1/1
20: 00 20 10 20   -> Mem Base/Limit = 0x2000/0x2010  => 0x20000000..0x201fffff

0001:00:01.0:  c3 14 11 08 | 40 01 10 00 | ... | BAR0 = 0x0000000c
20: 00 22 10 22   -> Mem Base/Limit = 0x2200/0x2210  => 0x22000000..0x221fffff
```

Decoding `0x0000000c` as the low dword of a memory BAR: bit 0 = 0 (memory space), bits 2:1 =
`10` (64-bit BAR), bit 3 = 1 (prefetchable), bits 31:4 = 0 (base address 0). So the hardware
default really is "64-bit prefetchable memory BAR at base 0", which is not a window this
device has.

The size probe then reports an enormous window, and the kernel refuses it:

```
[    0.992817] pci 0000:00:00.0: BAR 0: can't handle BAR larger than 4GB (size 0x200000000)
[    1.001719] pci 0000:00:00.0: BAR 0 [mem size 0x00000000 64bit pref disabled]
...
[    1.365253] pci 0001:00:01.0: BAR 0: can't handle BAR larger than 4GB (size 0x200000000)
[    1.374162] pci 0001:00:01.0: BAR 0 [mem size 0x00000000 64bit pref disabled]
```

Note on the number: the raw log line measures **`size 0x200000000`, i.e. 2^33 = 8 GiB**; the
"4GB" in that message is the kernel's BAR size limit, not the measured size. Our own patch
comment says "size-probes as 4 GiB", which is loose wording; the log line is authoritative.

Consequence, for both root ports:

```
pci 0000:00:00.0: BAR 0 ... not assigned; can't enable device
pci 0000:00:00.0: Error enabling bridge (-22), continuing
```

`pci_enable_resources()` returns `-EINVAL`, and because it bails out on the unassignable
resource, the root port's `PCI_COMMAND` is never updated. It stays at the reset value:

```
PCI_COMMAND = 0x0140
   bit 6 (0x0040) = Parity Error Response : 1
   bit 8 (0x0100) = SERR# Enable          : 1
   bit 2 (0x0004) = Bus Master            : 0
   bit 1 (0x0002) = Memory Space          : 0
```

`PCI_COMMAND.MEMORY` is the bit that enables the port's memory-space decoding and
`PCI_COMMAND.MASTER` is the bit that lets it master transactions; with both clear on the root
port, memory requests issued by the MT7916 behind it are never forwarded upstream to DRAM.

Honesty note: in the decisive experiment and in the quirk, Memory Space and Bus Master were
always set **together** (writing `0x0146`, i.e. `0x0140 | MEMORY | MASTER`). The logs
therefore prove that the root port's `PCI_COMMAND` was the gate; they do not separate the two
bits' individual contributions.

## 4. How it was proven

### 4.1 The host side is entirely correct

An instrumented `mt76` (debug patch `999-42x6-debug-ring-base.patch`, which prints every queue
right after `Q_WRITE(q, desc_base, q->desc_dma)` in `mt76_dma_sync_idx()`) showed that the ring
registers are written and read back bit-for-bit identical, with `cnt` matching the real ring
size:

```
[  597.385890] 42X6 ring hw_idx=18 ndesc=2048 desc_dma=0x83410000 rb: base=83410000 cnt=00000800 cidx=00000000 didx=00000000
[  597.411626] 42X6 ring hw_idx=17 ndesc=256  desc_dma=0x82f2a000 rb: base=82f2a000 cnt=00000100 cidx=00000000 didx=00000000
[  597.442763] 42X6 ring hw_idx=16 ndesc=128  desc_dma=0x82f28000 rb: base=82f28000 cnt=00000080 cidx=00000000 didx=00000000
[  597.480126] 42X6 ring hw_idx=4  ndesc=1536 desc_dma=0x82bb0000 rb: base=82bb0000 cnt=00000600 cidx=00000000 didx=00000000
```

Every `desc_dma` is `0x82xxxxxx`, i.e. DRAM at `0x80000000 + offset`, nicely aligned. So
`dma_alloc_coherent()` is working, the target's `dma-ranges` handling is fine, and MMIO writes
do land in the chip. This eliminated the DMA API and the "register writes do not reach the
chip" hypotheses.

### 4.2 The DMA engine consumes nothing

The decisive measurement came from a host-side polling module (`ringwatch`, 20 ms tick) that
reads the MT7916 WFDMA ring table over BAR0 and prints only changes. Raw capture (`rw_run2.txt`),
queue 17 = `MT7915_TXQ_MCU_WM`:

```
[  246.669730] RINGW t=652 w0 GLO_CFG=1010b850 tx_en=0 rx_en=0
[  247.065327] RINGW t=653 w0 GLO_CFG=1030b855 tx_en=1 rx_en=1
[  247.078274] RINGW t=653 w0 q17 base=8306e000 cnt=00000100 cidx=0    didx=0
[  247.106923] RINGW t=653 w1 GLO_CFG=1030b875 tx_en=1 rx_en=1
[  247.135325] RINGW t=654 w0 GLO_CFG=1030b857 tx_en=1 rx_en=1
[  247.141106] RINGW t=654 w0 q17 base=8306e000 cnt=00000100 cidx=1    didx=0
[  252.155326] mt7915e 0001:01:00.0: Retry message 00000010 (seq 1)
[  252.185521] RINGW t=822 w0 q17 base=8306e000 cnt=00000100 cidx=2    didx=0
[  257.195322] mt7915e 0001:01:00.0: Message 00000010 (seq 1) timeout
```

Reading this:

* `GLO_CFG` goes `0x1010b850` (`tx_en=0, rx_en=0`) -> `0x1030b855`
  (`TX_DMA_EN = BIT(0)`, `RX_DMA_EN = BIT(2)`), so `mt7915_dma_start()` did run and WFDMA is
  enabled. One tick later the value is `0x1030b857`: bit 1, i.e. **`TX_DMA_BUSY` is asserted**.
* The ring base and count are correct and stable.
* `cidx` (host producer) advances 0 -> 1 -> 2, following exactly the MCU command and its
  retry.
* `didx` (DMA consumer) stays **0** forever.

So the DMA engine accepted the configuration, reported busy, and consumed zero descriptors.

The ring register layout is

```
q->regs = BAR0 + MT_Q_BASE(q) + 0x300 + q_id * MT_RING_SIZE(0x10)
MT7916: MT_WFDMA0_BASE = mt7916_reg[WFDMA0_ADDR] = 0xd4000
q_id: MT7915_TXQ_FWDL = 16, MT7915_TXQ_MCU_WM = 17, MT7915_TXQ_MCU_WA = 20,
      MT7916_RXQ_MCU_WM = 0
```

### 4.3 Register-level reason: `cpu_idx` is the host producer, `dma_idx` is the DMA consumer

In `struct mt76_queue_regs` the four fields at `+0x00`, `+0x04`, `+0x08`, `+0x0c` are the
descriptor base, the descriptor count, `cpu_idx` and `dma_idx`:

| Index | Offset | Written by | Meaning | Observed |
|---|---|---|---|---|
| `cpu_idx` | `+0x08` | the **host**, in `mt76_dma_kick_queue()`: `Q_WRITE(q, cpu_idx, q->head)` | driver's produce index | 0 -> 1 -> 2 |
| `dma_idx` | `+0x0c` | the **DMA engine**; the host only reads it via `mt76_dma_read_dma_idx()` | descriptors consumed by the DMA | 0, always |

`mt7915_mcu_send_message()` -> `mt76_tx_queue_skb_raw(dev, mdev->q_mcu[qid], skb, 0)` puts the
MCU command into a WFDMA ring in host DRAM and expects the chip to DMA-read it. With `dma_idx`
stuck at 0 while `cpu_idx` advances and `TX_DMA_BUSY` is asserted, the conclusion is exact:
**the DMA engine never read one single descriptor out of host DRAM.**

### 4.4 The smoking gun: `PCI_COMMAND = 0x0140` on all four devices

```
0000:00:00.0 CMD=0140     <- root port 0 : IO=0 MEMORY=0 BUS MASTER=0
0001:00:01.0 CMD=0140     <- root port 1 : IO=0 MEMORY=0 BUS MASTER=0
0000:01:00.0 CMD=0140     <- MT7916 HIF
0001:01:00.0 CMD=0140     <- MT7916 WF
```

### 4.5 The decisive experiment

Forcing `0x0146` (`0x0140 | MEMORY | MASTER`) into all four devices and then loading the
driver made the very first MCU command succeed:

```
0000:00:00.0 CMD=0146
0001:00:01.0 CMD=0146
0000:01:00.0 CMD=0146
0001:01:00.0 CMD=0146

[  757.206447] mt7915e 0001:01:00.0: HW/SW Version: 0x8a108a10, Build Time: 20240823172725a
[  757.223895] mt7915e 0001:01:00.0: WM Firmware Version: ____000000, Build Time: 20240823172741
[  757.262719] mt7915e 0001:01:00.0: WA Firmware Version: DEV_000000, Build Time: 20240823172837
```

No retry, no timeout, no panic. Two notes on this capture: in the raw
`golden_4_pci_cmd_0146_fix.log` the WF endpoint reads `0142` rather than `0146` at the check,
because a previous driver load had already set its Memory Space Enable; what matters is that
both root ports read `0146`. And the earlier `not assigned; can't enable device` /
`Error enabling bridge (-22)` messages are still present in the same capture, because the bits
were forced *after* enumeration had already failed to claim the resources. That is exactly why
this had to become a kernel fixup that runs *before* resource claiming, rather than a userspace
workaround.

### 4.6 Measurement trap worth knowing

`dd of=/sys/.../config` **must** carry `seek=<offset>`, otherwise it writes at offset 0 (the
read-only vendor ID) and fails silently. The correct form used here:

```
printf '\x46\x01' | dd of=/sys/bus/pci/devices/<dev>/config bs=1 seek=4 count=2 conv=notrunc
```

## 5. The fix

A PCI fixup in `drivers/pci/quirks.c`, delivered by this repository as
`openwrt/overlay/target/linux/airoha/patches-6.18/110-PCI-quirk-airoha-EN7523-root-complex.patch`.
The added code, verbatim from the patch file:

```c
/*
 * Airoha EN7523 / Econet 42X6 PCIe root complex
 *
 * The RC reports a bogus BAR 0: it reads 0x0000000c (64-bit prefetchable) and
 * size-probes as 4 GiB.  pci_enable_resources() therefore fails with -EINVAL
 * on both root ports, which leaves their PCI_COMMAND Memory Space Enable and
 * Bus Master Enable bits clear.
 *
 * With bus mastering disabled on the root port, memory requests issued by an
 * endpoint behind it (here a MediaTek MT7916) are never forwarded upstream to
 * DRAM.  The endpoint WFDMA happily accepts the ring configuration, sets
 * TX_DMA_EN/RX_DMA_EN and asserts TX_DMA_BUSY, but never fetches a single
 * descriptor: cpu_idx advances while dma_idx stays 0.  Every MCU command then
 * times out ("Message 00000010 (seq 1) timeout") and the device is unusable.
 *
 * Drop the bogus BARs so resource claiming succeeds, and enable memory
 * decoding plus bus mastering explicitly.
 */
static void quirk_airoha_en7523_rc(struct pci_dev *dev)
{
	u16 cmd;
	int i;

	/* Only devices sitting directly on a root bus, i.e. the RC itself. */
	if (dev->bus->self)
		return;

	for (i = 0; i < 2; i++) {
		dev->resource[i].flags = 0;
		dev->resource[i].start = 0;
		dev->resource[i].end = 0;
	}

	pci_read_config_word(dev, PCI_COMMAND, &cmd);
	cmd |= PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER;
	pci_write_config_word(dev, PCI_COMMAND, cmd);
}
DECLARE_PCI_FIXUP_HEADER(PCI_VENDOR_ID_MEDIATEK, 0x0810, quirk_airoha_en7523_rc);
DECLARE_PCI_FIXUP_HEADER(PCI_VENDOR_ID_MEDIATEK, 0x0811, quirk_airoha_en7523_rc);
```

(The comment inside the patch says "size-probes as 4 GiB"; the log line measures
`size 0x200000000`, i.e. 8 GiB. See section 3.)

Four properties of the fix matter:

* **Vendor and device match.** `PCI_VENDOR_ID_MEDIATEK` with device IDs `0x0810` and `0x0811`,
  which is exactly what the two EN7523 root ports report (`14c3:0810`, `14c3:0811`).
* **The `dev->bus->self` guard.** A `NULL` parent bus means the device sits directly on a root
  bus, i.e. it *is* the root complex. This confines the quirk to the root ports and keeps it
  from touching any other MediaTek device with the same IDs behind a bridge.
* **Resource release.** `resource[0]` and `resource[1]` -- the first two resource slots, which
  is where the 64-bit BAR 0 lives -- are zeroed: flags, start and end. A cleared resource slot
  is ignored by the claiming path, so nothing unassignable is left for
  `pci_enable_resources()` to fail on, and bridge setup proceeds.
* **Fixup stage.** `DECLARE_PCI_FIXUP_HEADER` runs early, during device setup and before
  resource assignment/claiming, so the corrected state is what enumeration and the PCI bridge
  layer see. Doing this later (from userspace, after `pci_enable_resources()` had already
  failed) leaves `pcieport` unbound, which is exactly what the manual experiment showed.

The quirk was confirmed present in the built kernel tree at
`build_dir/.../linux-6.18.54/drivers/pci/quirks.c` lines 6404 / 6423 / 6424.

## 6. Why a quirk in `drivers/pci/quirks.c` and not `drivers/pci/controller/pcie-mediatek.c`

The tradeoff, stated plainly:

* The garbage BAR 0 lives in the **emulated config space of the root complex, seen as a PCI
  device**. It is therefore only reachable from the PCI enumeration path, where a
  `struct pci_dev` exists and `dev->resource[]` can be corrected before claiming.
* `mtk_pcie_probe()` operates on a **platform device** with the `port0`/`port1` register
  regions. It never looks at the PCI `dev->resource[]` of the root port device, so fixing it
  there would mean reaching across subsystems.
* The real upstream defect is in the v2 bring-up path: mainline `pcie-mediatek.c` programs
  `PCIE_BAR0_SETUP` (offset `0x10`) **only in the v1 path** (`mtk_pcie_setup_irq()`,
  `PCIE_BAR_MAP_MAX | PCIE_BAR_ENABLE`). The **v2** ops used for `mt7622`/`mt7623` -- and
  therefore for EN7523 through the fallback compatible -- never program BAR 0 at all, so the
  hardware default (`0x0000000c`) survives into enumeration.
* Given that, a quirk is the least invasive correction: it is a small, self-contained, clearly
  commented hunk in a file whose entire purpose is to work around broken PCI hardware, it does
  not risk regressing the working v1 path, and it is trivially revertible if the proper fix
  lands elsewhere. The alternative -- programming `PCIE_BAR0_SETUP` in the v2 path -- is the
  better long-term shape (and the more likely thing upstream would accept), but it changes
  bring-up for every v2 SoC and requires its own validation. It was deliberately not done
  first.

## 7. Verification on real hardware

### 7.1 Clean boot of the fixed image, zero manual PCI writes

Both patches were built into a new image and flashed to slot B, then booted. No PCI register
was touched by hand. Evidence: `golden_6_fixed_image_cmd0146_auto.log`,
`golden_7_fixed_image_firmware_ok.log`, `golden_8_fixed_image_wlan0_up.log`.

```
0000:00:00.0 CMD=0146      <- root port 0: Memory + Bus Master, set by the quirk
0001:00:01.0 CMD=0146      <- root port 1: Memory + Bus Master, set by the quirk
0000:01:00.0 CMD=0140      <- MT7916 HIF (driver not loaded yet)
0001:01:00.0 CMD=0140      <- MT7916 WF  (driver not loaded yet)
```

The bridges now bind. Instead of `Error enabling bridge (-22)`, both root ports report PME
routing (the first line is from the clean-boot capture, the second from the session-5 summary
of the same boot):

```
[    1.170476] pcieport 0000:00:00.0: PME: Signaling with IRQ 29
[    1.542922] pcieport 0001:00:01.0: PME: Signaling with IRQ 31
```

The firmware download succeeds, with no retry and no timeout:

```
[  320.312392] mt7915e_hif 0000:01:00.0: enabling device (0140 -> 0142)
[  320.319181] mt7915e 0001:01:00.0: enabling device (0140 -> 0142)
[  320.425845] mt7915e 0001:01:00.0: HW/SW Version: 0x8a108a10, Build Time: 20240823172725a
[  320.443455] mt7915e 0001:01:00.0: WM Firmware Version: ____000000, Build Time: 20240823172741
[  320.478391] mt7915e 0001:01:00.0: WA Firmware Version: DEV_000000, Build Time: 20240823172837
```

And a usable interface:

```
~ # iw phy phy0 interface add wlan0 type managed ; echo add=$?
add=0
~ # ip link set wlan0 up ; echo up=$?
up=0
~ # iw dev
phy#0
	Interface wlan0
		ifindex 2
		addr <random address, redacted>
		type managed
		txpower 20.00 dBm
```

Both PHYs register (2.4 GHz + 5 GHz, 2T2R each). On the manual-fix run they appeared as
`phy2`/`phy3` (`registering led 'mt76-phy2'`, `registering led 'mt76-phy3'`); on the clean fixed
boot they appear as `phy0`/`phy1`. That difference is only PHY numbering.

### 7.2 A second, independent blocker on the way to `wlan0`

Passing the PCIe gate is necessary but was not sufficient. The OpenWrt `mt76` package installed
only `mt7916_rom_patch.bin`, `mt7916_wa.bin` and `mt7916_wm.bin`; `mt7916_eeprom.bin` was
missing. Because this board has an empty efuse (`mt7915_eeprom_load()` -> `-EINVAL`, "efuse
info isn't enough"), the driver falls back to the default eeprom file, did not find it, waited
on the sysfs fallback (no helper in the initramfs) and failed after 60 s:

```
[  311.536080] mt7915e 0001:01:00.0: eeprom load fail, use default bin
[  311.542449] mt7915e 0001:01:00.0: Direct firmware load for mediatek/mt7916_eeprom.bin failed with error -2
[  311.552148] mt7915e 0001:01:00.0: Falling back to sysfs fallback for: mediatek/mt7916_eeprom.bin
[  371.755824] mt7915e 0001:01:00.0: probe with driver mt7915e failed with error -110
```

This is a packaging defect in `package/kernel/mt76/Makefile` (the firmware install blocks only
`cp` three files each), fixed as a second patch that adds the `*_eeprom.bin` files. It is
documented here only so that the root-cause story is complete and not overclaimed: the PCIe
fix is what makes the MCU reachable at all, and the eeprom file is a separate, later failure
mode with a completely different signature (`-110` after 60 s, not a 5 s MCU timeout).

Caveat: with the default eeprom bin the board gets a driver-generated random MAC address and
no per-unit calibration data. That is a known limitation of using the default bin and is out
of scope for this document.

## 8. Retraction: the "WFDMA ring table is all defaults" dead end

**Earlier conclusion (session 3):** the MT7916's WFDMA ring table read back as all-defaults
(base 0, count `0x200` for every ring, `cidx` 0, `didx` 0, and `MT_WFDMA0_GLO_CFG = 0x1010b850`
with `TX_DMA_EN`/`RX_DMA_EN` clear), which was taken as the cause: "the chip has no valid
descriptor base pointing into DRAM, therefore it cannot read the MCU command".

```
Ring        address      +00 BASE   +04 CNT    +08 CIDX   +0c DIDX
FWDL        0x220d4400   0          0x200      0          0
WM (MCU)    0x220d4410   0          0x200      0          0
WA (MCU)    0x220d4440   0          0x200      0          0
RX-MCU      0x220d4500   0          0x200      0          0
```

**That conclusion is RETRACTED. It was post-reset aftermath, not a cause.** The reasoning:

* `0x200` is the hardware default count for every ring, while the driver's real ring sizes are
  `MT7915_TX_RING_SIZE = 2048 (0x800)`, `MT7915_TX_MCU_RING_SIZE = 256 (0x100)`,
  `MT7915_TX_FWDL_RING_SIZE = 128 (0x80)`, `MT7915_RX_RING_SIZE = 1536 (0x600)`,
  `MT7915_RX_MCU_RING_SIZE = 512 (0x200)`. So the reading was self-consistent with "somebody
  reset WFDMA back to defaults", not with "the driver never wrote it".
* The instrumented `mt76` proved the writes are in fact correct at the moment the driver makes
  them: `desc_dma = 0x82xxxxxx`, readback bit-identical, `cnt` matching `ndesc` (section 4.1).
* Reading `mt76` source closed the other half: `mt7915_dma_init()` ends with
  `mt7915_dma_enable(dev, false)` -> `mt7915_dma_prefetch()` + `BUSY_ENA` + poll `HIF_MISC` +
  `mt7915_dma_start()`, and `mt7915_dma_start()` does
  `mt76_set(MT_WFDMA0_GLO_CFG, TX_DMA_EN | RX_DMA_EN | OMIT_TX_INFO | OMIT_RX_INFO_PFET2)`.
  DMA is enabled **before** firmware download. So the observed `GLO_CFG` with both enable bits
  clear was also aftermath.
* The aftermath is produced by the failure path itself: after the MCU timeout,
  `mt7915_mac_reset_work` / `mt7915_dma_reset` runs and resets WFDMA to defaults, and it panics
  about 370 ms later, so a register dump taken afterwards describes the reset, not the bug.

Do not repeat this dead end. Two things made it expensive and both are avoidable:

1. **Post-mortem register state lies.** Reading chip registers after the panic/reboot gives you
   a state that the error path has already rewritten. You need the **time ordering**: the
   instrumentation module that polls and prints changes showed `cidx` advancing while `didx`
   stayed at 0, i.e. "DMA is on but consumes nothing", which is a different and correct story
   from "the ring was never programmed".
2. **Racing to read the ring right after `insmod` does not work either.** It was attempted and
   failed: the panic happens about 370 ms after the timeout but before `insmod` returns, so the
   read loop never runs. Let the driver report its own state instead (the debug patch), or poll
   from a separate module.

### Two further conclusions that also had to be walked back

* **"The root port `PCI_COMMAND` is a read-only mirror, therefore it is not the culprit."**
  In session 3, a userspace `dd seek=4` write of `0x0147` to `0000:00:00.0` read back
  `0x0140`, and a direct write of `0x0604000f` to the root port register block at `0x1fa91104`
  read back `0x06040003`, so the bits were declared unwritable and the root port
  was excluded. That was wrong: `quirk_airoha_en7523_rc()` writes the same two bits through
  `pci_write_config_word()` and a clean boot shows `CMD=0146` on both root ports. **The bits are
  settable -- the earlier manual write path was not equivalent to the kernel's.** We did not
  isolate why that particular userspace write did not land at the time; what is certain is the
  clean-boot result.
* **"Fixing `pcieport` will not fix Wi-Fi."** Session 3 said the quirk was "correct but not the
  decisive move". It was the decisive move.

## 9. Lessons

1. **When everything visible from the host looks correct, suspect the state nobody logs.** Here
   it was `PCI_COMMAND.Bus Master`/`Memory Space` of the *root port*. Two layers hid it:
   `pci_enable_resources()` failed but only printed `Error enabling bridge (-22), continuing`,
   and `pcieport` never bound, so there was no AER and no log at all about blocked requests --
   the failure destroyed the very observability that would have shown it.
2. **`dma_idx` vs `cpu_idx` is the measurement that separates "DMA is not enabled" from "DMA is
   enabled but cannot read DRAM".** `GLO_CFG.tx_en`/`rx_en` is not enough: in this failure
   `TX_DMA_BUSY` was even asserted while zero descriptors were consumed.
3. **Time ordering matters more than snapshots.** A register dump after a reset-triggering
   timeout describes the reset. Poll and print changes, or have the driver report its own
   writes at the moment it makes them.
4. **Never touch a BAR before confirming `PCI_COMMAND.MEMORY` through config space.** On this
   SoC that mistake costs a power cycle and yields no kernel message whatsoever.
5. **`ioremap()` is safe at any time** (it only builds page tables, even with `MemEn = 0`);
   only the actual MMIO access needs the guard. But **never call `ioremap()` from softirq
   context** -- `BUG_ON(in_interrupt())` in `__get_vm_area_node()` turns into an
   "undefined instruction" oops on ARM.
6. **A userspace config-space write that does not stick is not proof that a bit is hardwired.**
   The kernel writing the same bit during enumeration is a different path; check that path
   before ruling a register out.
7. **Root port BARs can be garbage, and ignoring `Error enabling bridge (-22), continuing` is
   expensive.** It silently costs AER, PME and hotplug, and it leaves the port's Memory Space
   and Bus Master disabled -- which is enough to break every endpoint behind it.
8. **Fix it at the earliest point that sees the problem, and no later.** A `HEADER` fixup runs
   before resource claiming, so the corrected BAR state is what enumeration evaluates. A
   userspace write after enumeration has already failed cannot repair `pcieport` binding.
9. **The right level matters.** The malformed BAR comes from the root complex's own config
   space, so the PCI enumeration path is the level that can fix it; the platform bring-up
   driver never sees it. But the actual upstream defect is that the v2 bring-up path never
   programs `PCIE_BAR0_SETUP`, and that is where a permanent fix belongs.
