# MT7916 Wi-Fi bring-up

The Econet vGP-42X6V1 (Airoha EN7523) carries a single MediaTek MT7916 802.11ax
radio on PCIe. This document is about the driver side of that radio: what the
kernel has to load, in which order, what files it needs on disk, and what a
successful bring-up prints. The PCIe host controller side is a separate story
and is not repeated here -- see [pcie-root-cause.md](pcie-root-cause.md), and
[hardware.md](hardware.md) section 5 for the bus topology.

The short version: the radio is a stock mainline `mt7915e`/`mt76` device and
needs no vendor driver, but on a clean OpenWrt build it did not come up for two
independent reasons. One was the PCI root complex (fixed by a quirk, documented
in [pcie-root-cause.md](pcie-root-cause.md)). The other was a packaging gap in
the OpenWrt `mt76` package, which is the subject of section 4 below.

## Sources

Everything below is traceable to these files. They are in the development
workspace, not in this repository.

| Source | Used for |
|---|---|
| `temp/42X6/golden_1_firmware_download_ok.log` | firmware download succeeds, eeprom request fails |
| `temp/42X6/golden_2_eeprom_missing_-110.log` | the `-110` failure, module list, `/lib/firmware/mediatek/` contents |
| `temp/42X6/golden_3_wifi_wlan0_up.log` | `phy2`/`phy3` boot, `wlan0` up at 20 dBm |
| `temp/42X6/golden_4_pci_cmd_0146_fix.log` | `PCI_COMMAND` on all four devices, probe succeeds |
| `temp/42X6/golden_5_probe_ok_phy2_phy3.log` | `iw phy phy2 info`, PHY index `phy2` |
| `temp/42X6/golden_6_fixed_image_cmd0146_auto.log` | fixed image: `0x0146` set by the quirk, 9 firmware files present |
| `temp/42X6/golden_7_fixed_image_firmware_ok.log` | clean-image success, PHY index `phy0` |
| `temp/42X6/golden_8_fixed_image_wlan0_up.log` | clean-image `wlan0` up at 20 dBm, PHY index `phy0` |
| `temp/42X6/sh_fix2.txt`, `temp/42X6/sh_fix3.txt` | the exact `insmod` order that works |
| `temp/42X6/sh_axiw80.out`, `temp/42X6/sh_bme_test.out`, `temp/42X6/send_b3_clean.log` | `Unknown symbol` messages per module |
| `docs/econet/42X6_openwrt_m1_status.md` | sections 10, 13, 14 and 15: PCIe diagnosis, module order, eeprom root cause |
| `openwrt/patches/0004-package-mt76-install-default-eeprom-bins.patch` | the packaging fix, quoted verbatim in section 4 |

## 1. What is on the PCIe bus

The EN7523 has two PCIe root complex ports. Both train a link, and both links
end at the *same* physical MT7916, which presents itself as two PCIe functions.

| Device | Role | Address | BARs |
|---|---|---|---|
| `14c3:0810` | root complex, port 0 | `0000:00:00.0`, register base `0x1fa91000` | -- |
| `14c3:0811` | root complex, port 1 | `0001:00:01.0`, register base `0x1fa92000` | -- |
| `14c3:790a` | MT7916 function **HIF** | `0000:01:00.0` behind the port 0 bridge | BAR0 `0x20000000` (1 MiB), BAR2 `0x20100000` (32 KiB), BAR4 `0x20108000` (4 KiB) |
| `14c3:7906` | MT7916 function **WF** | `0001:01:00.0` behind the port 1 bridge | BAR0 `0x22000000` (1 MiB), BAR2 `0x22100000` (32 KiB), BAR4 `0x22108000` (4 KiB) |

The WF function (`14c3:7906`, BAR0 `0x22000000`) is the one the `mt7915e`
driver binds and drives. The HIF function (`14c3:790a`, BAR0 `0x20000000`) is
picked up as the HIF2 companion. Both BAR0 windows are decoded by the same
silicon: a value written through one window is readable through the other, which
is how the pairing was proven. The MT7916 WFDMA ring tables live at
`BAR0 + 0xd4000`, with the second WFDMA block at `BAR0 + 0xd8000`; both offsets
sit comfortably inside the 1 MiB aperture.

Two things about the module tables are worth knowing before debugging:

- `mt7915_pci_device_table` matches both `0x7915` and `0x7906`, and the latter is
  what this board has. So the WF function is handled by `mt7915e`.
- `mt7915_hif_device_table` matches `0x7916` and `0x790a`, and `0x790a` is the
  HIF2 stub.

### Both firmware packages are required

The `mt76` package in OpenWrt ships **two** separate firmware packages, and this
board needs **both**:

| Package | Files installed into `/lib/firmware/mediatek/` |
|---|---|
| `kmod-mt7915-firmware` | `mt7915_wa.bin`, `mt7915_wm.bin`, `mt7915_rom_patch.bin` |
| `kmod-mt7916-firmware` | `mt7916_wa.bin`, `mt7916_wm.bin`, `mt7916_rom_patch.bin` |

This is easy to get wrong because the *driver* package is a single one
(`kmod-mt7915e`) that covers both chips, so it looks like one firmware package
should be enough. It is not. An early build declared only `kmod-mt7916-firmware`
in `DEVICE_PACKAGES`, and the MT7915 blobs were then missing from the image
entirely; the fix was to add `kmod-mt7915-firmware` as well.

In other words: the device is an MT7916, but do not read that as "only the
MT7916 firmware is needed". Install both packages.

## 2. Kernel module load order

The load order is mandatory and is not obvious from the file names. It is:

```
compat -> i2c-core -> hwmon -> cfg80211 -> mac80211 -> mt76 -> mt76-connac-lib -> mt7915e
```

Which is, verbatim, these commands:

```sh
insmod /lib/modules/6.18.54/compat.ko; echo rc=$?
insmod /lib/modules/6.18.54/i2c-core.ko; echo rc=$?
insmod /lib/modules/6.18.54/hwmon.ko; echo rc=$?
insmod /lib/modules/6.18.54/cfg80211.ko; echo rc=$?
insmod /lib/modules/6.18.54/mac80211.ko; echo rc=$?
insmod /lib/modules/6.18.54/mt76.ko; echo rc=$?
insmod /lib/modules/6.18.54/mt76-connac-lib.ko; echo rc=$?
insmod /lib/modules/6.18.54/mt7915e.ko; echo rc=$?
```

After a successful run, `Modules linked in:` in a kernel report lists them in
exactly this order:

```
Modules linked in: mt7915e(O+) hwmon i2c_core mt76_connac_lib(O) mt76(O) mac80211(O) cfg80211(O) compat(O) slhc crc_ccitt
```

### Gotcha 1: without `compat.ko`, everything after it fails

`compat.ko` is the backports shim. It provides `backport_dependency_symbol`,
which every backported module in the chain references. Load `cfg80211.ko`
without `compat.ko` first and you get:

```
[  660.762211] cfg80211: Unknown symbol backport_dependency_symbol (err -2)
failed to insert /lib/modules/6.18.54/cfg80211.ko
[  669.222543] mac80211: Unknown symbol ieee80211_ie_split_ric (err -2)
[  669.228908] mac80211: Unknown symbol backport_dependency_symbol (err -2)
```

The same run then fails further down the chain, each module reporting the
symbols its predecessor should have provided:

```
[  489.832154] mac80211: Unknown symbol ieee80211_ie_split_ric (err -2)
[  489.838514] mac80211: Unknown symbol backport_dependency_symbol (err -2)
...
[  497.587679] mt76: Unknown symbol ieee80211_sta_register_airtime (err -2)
...
[  506.210451] mt76_connac_lib: Unknown symbol mt76_tx_status_unlock (err -2)
...
[  514.835346] mt7915e: Unknown symbol mt76_connac_mcu_restart (err -2)
```

The two easy-to-miss edges inside the chain are `i2c-core` before `hwmon`, and
`hwmon` before `mt7915e`:

```
[  654.223291] hwmon: Unknown symbol i2c_verify_client (err -2)
[  675.850652] mt7915e: Unknown symbol devm_hwmon_device_register_with_groups (err -2)
```

`mt7915e` pulls in `hwmon` (the driver registers a temperature hwmon device) and
`hwmon` itself needs `i2c-core`. `mt7915e` will not load without `hwmon`, even
though nothing about Wi-Fi suggests that.

### Gotcha 2: `/sbin/insmod` is `kmodloader`

On OpenWrt, `/sbin/insmod`, `/sbin/rmmod`, `/sbin/modprobe` and `/sbin/lsmod`
are provided by the `kmodloader` utility rather than by a busybox `insmod`. The
boot log shows `kmodloader` doing the module loading in this image:

```
[    2.289136] kmodloader: loading kernel modules from /etc/modules-boot.d/*
[    2.307807] kmodloader: done loading kernel modules from /etc/modules-boot.d/*
[   10.833272] kmodloader: loading kernel modules from /etc/modules.d/*
```

`kmodloader` parses module dependencies out of the module metadata rather than
out of a module name, so the semantics differ from a busybox `insmod`: it will
resolve and load dependencies for you, but only if you hand it a path it can
read the metadata from. When driving the chain by hand it is safest to just pass
absolute paths, one module per invocation, in the order listed above.

See section 8 for how thin the direct evidence for the symlink claim is.

## 3. Why `modprobe` does not work here

`modprobe` needs a dependency map. OpenWrt does not ship one: there is no
`/lib/modules/<version>/modules.dep` in the image. Without that file `modprobe`
cannot work out what to load before what, so it cannot resolve the `compat` ->
`cfg80211` -> `mac80211` -> `mt76` -> `mt7916` chain at all, and a bare
`modprobe mt7915e` has nothing to recurse into.

The practical consequence is that the entire chain has to be `insmod`ed by hand,
in order, with the `kmodloader` semantics described above. There are two workable
ways to do it:

1. `kmodloader` with explicit paths -- one path per invocation, in the order in
   section 2. `kmodloader` reads each module's own dependency metadata, so it
   will pull in what that one module needs; the order still has to be right for
   the modules it does not know about.
2. Plain `insmod` in the order in section 2, with an absolute path for every
   module and no reliance on recursion.

The `insmod` form is what the working logs show and is the form quoted above.

Note that a normal OpenWrt boot does not need any of this: `kmodloader` loads
`/etc/modules-boot.d/*` and then `/etc/modules.d/*` at boot, and in a correct
image `mt7915e` is loaded that way. Manual loading is for diagnosis and for
`rdinit=/bin/sh` sessions, where `procd` and `kmodloader` never run.

## 4. The eeprom packaging gap -- the actual bug

Once the PCIe side was fixed, the firmware downloaded and the driver still died.
The failure is a missing file, and the chain that leads to it is worth following
exactly, because the missing file is not mentioned anywhere in the success path.

### The chain

1. `mt7915_eeprom_load()` looks for an EEPROM described by the device tree. This
   board's device tree describes none, so it takes the next branch and calls
   `mt7915_mcu_get_eeprom_free_block()` to ask the firmware how much EFuse is
   left.

2. This board's EFuse is **blank**. A blank EFuse means `free_block_num >= 29`,
   and `mt7915_eeprom_load()` returns `-EINVAL` on that condition, with a comment
   to the effect that the efuse information is not enough.

3. `mt7915_eeprom_init()` sees the `-EINVAL` and falls back, printing:

   ```
   eeprom load fail, use default bin
   ```

   It then calls `mt7915_eeprom_load_default()`, which calls
   `request_firmware("mediatek/mt7916_eeprom.bin")` and marks the device as using
   a flash-mode EEPROM (`dev->flash_mode = true`).

4. The OpenWrt `mt76` package installed the `wa`, `wm` and `rom_patch` blobs for
   both mt7915 and mt7916 -- but **not** the `*_eeprom*.bin` files, even though
   they were present in the package build directory. So `request_firmware()`
   returned `-ENOENT`:

   ```
   [  311.536080] mt7915e 0001:01:00.0: eeprom load fail, use default bin
   [  311.542449] mt7915e 0001:01:00.0: Direct firmware load for mediatek/mt7916_eeprom.bin failed with error -2
   [  311.552148] mt7915e 0001:01:00.0: Falling back to sysfs fallback for: mediatek/mt7916_eeprom.bin
   ```

5. With no userspace firmware helper in the initramfs, the sysfs fallback waits.
   The probe gave up 60 seconds later:

   ```
   [  371.755824] mt7915e 0001:01:00.0: probe with driver mt7915e failed with error -110
   ```

   `-110` is `ETIMEDOUT`. Note the timestamps: the fallback started at 311.5 s
   and the probe failed at 371.8 s, which is the 60-second wait.

6. The consequence on the user-visible side is that there was **no Wi-Fi
   interface at all**. The module was loaded, and `/proc/modules` listed it, but
   there was no PHY and no netdev:

   ```
   ~ # ls /sys/class/ieee80211/ 2>&1
   ~ # iw dev 2>&1
   ~ # ip link 2>&1 | head -20
   1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN qlen 1000
       link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
   ```

   Only `lo`. The same run shows what the image *did* contain:

   ```
   ~ # ls /lib/firmware/mediatek/ 2>&1 | head -20
   mt7916_rom_patch.bin
   mt7916_wa.bin
   mt7916_wm.bin
   ```

   Exactly three files: the MT7916 blobs, no MT7915 blobs and no eeprom blobs.

### The fix

The `install` blocks in `package/kernel/mt76/Makefile` copied only the three
blobs per chip. The fix adds the eeprom files. This is the relevant part of
[0004-package-mt76-install-default-eeprom-bins.patch](../openwrt/patches/0004-package-mt76-install-default-eeprom-bins.patch),
copied verbatim:

```diff
diff --git a/package/kernel/mt76/Makefile b/package/kernel/mt76/Makefile
--- a/package/kernel/mt76/Makefile
+++ b/package/kernel/mt76/Makefile
@@ -612,6 +612,8 @@
 		$(PKG_BUILD_DIR)/firmware/mt7915_wa.bin \
 		$(PKG_BUILD_DIR)/firmware/mt7915_wm.bin \
 		$(PKG_BUILD_DIR)/firmware/mt7915_rom_patch.bin \
+		$(PKG_BUILD_DIR)/firmware/mt7915_eeprom.bin \
+		$(PKG_BUILD_DIR)/firmware/mt7915_eeprom_dbdc.bin \
 		$(1)/lib/firmware/mediatek
 endef
 
@@ -621,6 +623,7 @@
 		$(PKG_BUILD_DIR)/firmware/mt7916_wa.bin \
 		$(PKG_BUILD_DIR)/firmware/mt7916_wm.bin \
 		$(PKG_BUILD_DIR)/firmware/mt7916_rom_patch.bin \
+		$(PKG_BUILD_DIR)/firmware/mt7916_eeprom.bin \
 		$(1)/lib/firmware/mediatek
 endef
 
```

After the fix, `/lib/firmware/mediatek/` in a clean image contains nine files:

```
mt7915_eeprom.bin  mt7915_eeprom_dbdc.bin  mt7915_rom_patch.bin
mt7915_wa.bin      mt7915_wm.bin           mt7916_eeprom.bin
mt7916_rom_patch.bin  mt7916_wa.bin        mt7916_wm.bin
```

### A consequence that still stands: no per-unit calibration

The default blob is a **generic template**. It is not this unit's calibration
data, and it is not supposed to be. Two visible consequences:

- There is no per-unit MAC address in it, so the driver invents one. The logs
  show:

  ```
  [  757.434455] mt7915e 0001:01:00.0: Invalid MAC address, using random address 02:00:00:00:00:00
  ```

  (The address in that line is redacted here -- the log carries a
  driver-generated random address, not a manufacturer address.)

- There is no per-unit RF calibration, so the radio runs uncalibrated.

The real calibration for this board lives in the `factory` partition. Reading it
and pointing mt76 at it (via an nvmem / `mediatek,mtd-eeprom` reference in the
device tree) is still an open item; see section 8. The default blob is a
workaround that makes the driver probe, not a correct end state.

## 5. What a working bring-up looks like

Two boots are shown, because the two images differ. Both are from a clean image
with the PCI quirk applied, so `0x0146` is set by the kernel and no manual PCI
write was performed.

### The intermediate boot (eeprom blob copied in by hand)

`golden_4_pci_cmd_0146_fix.log` shows the two root ports at `0x0146`, with the
MT7916 function the driver has claimed enabled at `0x0142`:

```
0000:00:00.0 CMD=0000000 0146
0001:00:01.0 CMD=0000000 0146
0000:01:00.0 CMD=0000000 0146
0001:01:00.0 CMD=0000000 0142
```

And the probe succeeding:

```
[  757.206447] mt7915e 0001:01:00.0: HW/SW Version: 0x8a108a10, Build Time: 20240823172725a
[  757.223895] mt7915e 0001:01:00.0: WM Firmware Version: ____000000, Build Time: 20240823172741
[  757.262719] mt7915e 0001:01:00.0: WA Firmware Version: DEV_000000, Build Time: 20240823172837
[  757.428020] mt7915e 0001:01:00.0: eeprom load fail, use default bin
[  757.434455] mt7915e 0001:01:00.0: Invalid MAC address, using random address 02:00:00:00:00:00
[  757.443235] mt7915e 0001:01:00.0: registering led 'mt76-phy2'
[  757.477160] mt7915e 0001:01:00.0: registering led 'mt76-phy3'
insmod=0
```

`insmod=0` is the key line: the probe returned success. Note that
`eeprom load fail, use default bin` is **expected** and is not an error on this
board, because the EFuse really is blank. What must not appear is the
`Direct firmware load ... failed` line after it.

The PHYs appear, and `wlan0` can then be created:

```
~ # ls /sys/class/ieee80211/
phy2  phy3
~ # iw phy phy2 interface add wlan0 type managed 2>&1; echo add=$?
add=0
~ # ip link set wlan0 up 2>&1; echo up=$?
up=0
~ # iw dev 2>&1
phy#2
	Interface wlan0
		ifindex 2
		wdev 0x200000001
		addr 02:00:00:00:00:00
		type managed
		txpower 20.00 dBm
```

(The `addr` field is redacted here for the same reason as above.)

### The final, clean-image boot

`golden_6`, `golden_7` and `golden_8` are from the rebuilt image containing both
fixes. On a clean boot, with no manual PCI writes:

```
0000:00:00.0 CMD=0146
0001:00:01.0 CMD=0146
0000:01:00.0 CMD=0140
0001:01:00.0 CMD=0140
```

The two root ports are at `0x0146` (Memory Space | Bus Master) because of the
quirk; the two MT7916 functions are still at `0x0140` because `mt7915e` has not
been loaded yet at that point. `pcieport` now binds:

```
[    1.170476] pcieport 0000:00:00.0: PME: Signaling with IRQ 29
[    1.542922] pcieport 0001:00:01.0: PME: Signaling with IRQ 31
```

Loading the driver:

```
~ # insmod /lib/modules/6.18.54/mt7915e.ko; echo rc=True
[  320.312392] mt7915e_hif 0000:01:00.0: enabling device (0140 -> 0142)
[  320.319181] mt7915e 0001:01:00.0: enabling device (0140 -> 0142)
[  320.425845] mt7915e 0001:01:00.0: HW/SW Version: 0x8a108a10, Build Time: 20240823172725a
[  320.443455] mt7915e 0001:01:00.0: WM Firmware Version: ____000000, Build Time: 20240823172741
[  320.478391] mt7915e 0001:01:00.0: WA Firmware Version: DEV_000000, Build Time: 20240823172837
[  320.643528] mt7915e 0001:01:00.0: eeprom load fail, use default bin
[  320.649995] mt7915e 0001:01:00.0: Invalid MAC address, using random address 02:00:00:00:00:00
[  320.658798] mt7915e 0001:01:00.0: registering led 'mt76-phy0'
[  320.717094] mt7915e 0001:01:00.0: registering led 'mt76-phy1'
rc=True
```

And the interface:

```
~ # ls /sys/class/ieee80211/
phy0  phy1
~ # P=$(ls /sys/class/ieee80211/ | head -1); echo PHY=$P; iw phy $P interface add wlan0 type managed; echo add=$?
PHY=phy0
add=0
~ # ip link set wlan0 up; echo up=$?
up=0
~ # iw dev
phy#0
	Interface wlan0
		ifindex 2
		wdev 0x1
		addr 02:00:00:00:00:00
		type managed
		txpower 20.00 dBm
		multicast TXQ:
			qsz-byt	qsz-pkt	flows	drops	marks	overlmt	hashcol	tx-bytes	tx-packets
			0	0	0	0	0	0	0	0		0
```

Two PHYs are registered, one per band (2.4 GHz and 5 GHz), 2T2R each, and a
managed interface comes up at 20.00 dBm.

One thing that is *not* a bug: mac80211 does not create a netdev by itself. Until
`iw phy <phy> interface add wlan0 type managed` is run, `ip link` shows only
`lo`, and `iw dev` prints nothing. That is normal behaviour for this driver, not
a sign of a failed probe.

### Success checklist for the dmesg lines

| Line | Meaning |
|---|---|
| `HW/SW Version: 0x8a108a10, Build Time: 20240823172725a` | ROM/hardware handshake done, firmware transfer started |
| `WM Firmware Version: ____000000, Build Time: 20240823172741` | WM firmware running |
| `WA Firmware Version: DEV_000000, Build Time: 20240823172837` | WA firmware running |
| `eeprom load fail, use default bin` | expected on this board (blank EFuse); the default blob is used |
| `registering led 'mt76-phy0'` / `'mt76-phy1'` | the two PHYs registered |
| no `Direct firmware load ... failed` | the eeprom blob is present |
| no `probe with driver mt7915e failed` | the probe returned success |

## 6. PHY numbering is not stable

The `phyN` names are not stable across boots. The same board, same kernel, same
driver, has been observed with two different sets of indices:

| Boot | `/sys/class/ieee80211/` | `iw dev` heading | LED names |
|---|---|---|---|
| intermediate image | `phy2` `phy3` | `phy#2` | `mt76-phy2`, `mt76-phy3` |
| final image | `phy0` `phy1` | `phy#0` | `mt76-phy0`, `mt76-phy1` |

This means a static `/etc/config/wireless` that names `phy0` (or any other fixed
index) is fragile: it may be correct on one boot and wrong on the next. The
final-image log even works around this by discovering the name at runtime:

```
~ # P=$(ls /sys/class/ieee80211/ | head -1); echo PHY=$P; iw phy $P interface add wlan0 type managed; echo add=$?
PHY=phy0
```

The recommendation is therefore to **generate the wireless configuration at
runtime** rather than hardcoding PHY names in a committed config file: enumerate
the PHYs from `/sys/class/ieee80211/` (or, more robustly, resolve each one to its
underlying PCI device under `/sys/class/ieee80211/phyN/device`) and build the
radio sections from what is actually present. Note that the `| head -1` form in
the log above is itself only a discovery shortcut, not a reliable ordering; it
happened to pick `phy0` on that boot.

Which index a given band gets is not documented by the sources either. The logs
show `phy2`/`phy3` and `phy0`/`phy1` but do not record which of the pair is
2.4 GHz and which is 5 GHz, so any band-to-PHY assumption should be checked on
hardware rather than read off an index.

## 7. If Wi-Fi does not come up

Work through these in order. Each maps to one of the sections above.

1. **Module load order.** `compat` -> `i2c-core` -> `hwmon` -> `cfg80211` ->
   `mac80211` -> `mt76` -> `mt76-connac-lib` -> `mt7915e`. A load failure with
   `Unknown symbol` almost always means the previous module in this list was not
   loaded. `backport_dependency_symbol` specifically means `compat.ko` is
   missing. `i2c_verify_client` means `i2c-core.ko` is missing;
   `devm_hwmon_device_register_with_groups` means `hwmon.ko` is missing.
   Remember that `/sbin/insmod` is `kmodloader` (section 2).

2. **Both firmware packages.** `kmod-mt7915-firmware` **and**
   `kmod-mt7916-firmware` must both be in `DEVICE_PACKAGES`. Having only one is
   the classic mistake here (section 1).

3. **The eeprom blobs are present.** Check `/lib/firmware/mediatek/` for
   `mt7916_eeprom.bin`, and for `mt7915_eeprom.bin` and
   `mt7915_eeprom_dbdc.bin`. A clean image has nine files there. If the file the
   driver asks for is missing you will see
   `Direct firmware load for mediatek/mt7916_eeprom.bin failed with error -2`
   followed by `probe with driver mt7915e failed with error -110` about 60
   seconds later (section 4).

4. **`PCI_COMMAND = 0x0146` on both root ports.** Both `14c3:0810` at
   `0000:00:00.0` and `14c3:0811` at `0001:00:01.0` need Memory Space plus Bus
   Master.

   ```sh
   for d in 0000:00:00.0 0001:00:01.0 0000:01:00.0 0001:01:00.0; do
       printf "%s CMD=" $d
       dd if=/sys/bus/pci/devices/$d/config bs=1 skip=4 count=2 2>/dev/null | hexdump
   done
   ```

   If the root ports read `0x0140` rather than `0x0146`, the PCI quirk is not
   active and the MT7916 cannot DMA into host memory at all -- the MCU commands
   will time out and `mt7915e` will panic on the way down. That is the whole
   subject of [pcie-root-cause.md](pcie-root-cause.md); do not diagnose it here.

   Also check that `pcieport` bound and that `Error enabling bridge (-22)` is
   gone from `dmesg`.

5. **Only after 1-4 are clean**, treat "no interface" as the mac80211 behaviour
   described in section 5: `ip link` shows only `lo` until
   `iw phy <phy> interface add wlan0 type managed` is run.

## 8. Where the evidence is thin or open

These are stated plainly rather than glossed over.

- **The `dev->flash_mode = true` assignment is not in a captured log.** The
  workspace notes establish the `free_block_num >= 29` -> `-EINVAL` test and the
  `request_firmware("mediatek/mt7916_eeprom.bin")` call in `mt7915/eeprom.c`, and
  the logs capture the resulting `-ENOENT`/`-110` behaviour. The `flash_mode`
  flag itself comes from the driver source path, not from a log line in these
  sources.

- **The `/sbin/insmod` is `kmodloader` claim is indirectly supported here.** The
  workspace notes contain a probe command that listed `/sbin/modprobe`,
  `/sbin/insmod` and `/bin/insmod`, but the recorded result of that probe is not
  preserved in the notes. What *is* directly evidenced in this workspace is that
  `kmodloader` is the utility loading modules in this OpenWrt image
  (`kmodloader: loading kernel modules from /etc/modules.d/*`). Treat the
  symlink detail as OpenWrt behaviour rather than as a measurement from this
  board.

- **The absence of `modules.dep` is asserted, not shown.** The notes record a
  command to list `/lib/modules/6.18.54/modules.dep` but the output of that
  command is not preserved either. The practical behaviour -- `modprobe` cannot
  resolve the chain and it has to be `insmod`ed in order -- is well evidenced by
  the working `insmod` sequences; the specific reason (no dependency file) is
  the standard OpenWrt explanation and is not proven by a captured listing here.

- **Which PHY is which band is not recorded.** The logs establish that the
  driver registers two PHYs and that their indices vary, but not the mapping
  from `phyN` to 2.4 GHz or 5 GHz for either boot.

- **The real calibration path is not resolved.** The `factory` partition has
  been located, but no run in these sources reads calibration from it or feeds
  it to mt76. Until that happens, the MAC address is random and the radio is
  uncalibrated. This is an open item, not a solved one.

- **Data-path behaviour is untested.** The evidence stops at the interface being
  up at 20.00 dBm. Nothing in these sources shows a scan, an association, or a
  packet actually crossing the radio, so "works" here means "probe succeeds and
  the interface comes up", not "passes traffic".
