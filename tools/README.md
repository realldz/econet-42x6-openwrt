# tools/

Host-side helpers for driving an Econet / vG vGP-42X6V1 (Airoha EN7523) board over its
UART while bringing up OpenWrt. Everything here talks to the board through the U-Boot
and Linux console; nothing here touches a flash chip directly.

## Install

```
python -m pip install -r tools/requirements.txt
```

Python 3, standard library plus `pyserial` only. Run the scripts from the repository
root, for example `python tools/ub_uart.py peek --sec 5`.

## What each tool does

| Tool | Purpose |
|---|---|
| `tools/ub_uart.py` | Drive the UART console: boot U-Boot to a Linux shell without rebooting the board, then send commands or a command list and log the whole session. |
| `tools/ub_push.py` | Push one file from the PC into SPI-NAND through U-Boot - YMODEM (`loady`) into RAM, then `flash erase` + `flash write`. |
| `tools/ub_paste.py` | Paste one small file into the running target's tmpfs over the console with `printf` octal escapes, for targets that have no /dev/mtd*, /dev/mem, /proc/kcore, base64, uudecode or xxd. |
| `tools/ub_cc.py` | Escape a stuck U-Boot secondary prompt (`PS2 '> '`) with repeated Ctrl-C, or reboot a live Linux through SysRq. |
| `tools/verify_build.py` | Verify that a built image's FIT load/entry address matches the kernel `_text` link address (it must be `0x80208000`), print the unpacked Image size, and count the debug breadcrumbs inside it (see below). |
| `tools/dts_vs_image.py` | Offline: check that a `.dts` in this repository is the one that was compiled into an image. Parses the DTB out of the FIT without `dtc` and compares every node and property the `.dts` declares, cell by cell, so a board file that drifted from the build is caught instead of believed. |
| `tools/mt7916_eeprom_mac.py` | Write your unit's MAC into the MT7916 default eeprom blob, so the driver stops using a random address every boot. Inspect-only with `--show`. |

## Serial port and baud rate

`ub_uart.py`, `ub_push.py`, `ub_paste.py` and `ub_cc.py` all take `--port` (default
`COM23`) and `--baud` (default `115200`), so no part of them is tied to one host.
Console logs are written to `tools/logs/`, created on demand.

Getting past the vendor U-Boot login needs credentials, and these are read from the
environment rather than baked into the source. The username is `admin`; the password is
the shared vendor default for this platform family, recorded in
[`docs/booting.md`](../docs/booting.md) -- with the caveat that the unit as shipped may
instead carry an operator-set password, in which case the default will not work. Without
them the `UserName:` prompt is not answered and the tool reports that it cannot get into
U-Boot:

```
export UB_USER=admin
export UB_PASSWORD=<see docs/booting.md>
```

`verify_build.py` has no command-line parser: pass the image as its single argument,
`python3 tools/verify_build.py <image>` (this is what the top-level README documents).
It prints three things worth reading: the `MATCH?` verdict for the load address, the
`Image unpacked:` size (13,158,560 plain against 25,741,472 with an initramfs), and the
`breadcrumbs:` count of `AIROHA-TRACE` strings in the decompressed kernel. Only that
last one can see the breadcrumbs, because the kernel Image is lzma-compressed inside
the FIT; anything above zero means the image is instrumented.
`dts_vs_image.py` takes the image, the board `.dts` and the `.dtsi` files it includes,
and needs no OpenWrt tree of its own beyond those files.

## ub_uart.py sub-commands

The script implements exactly four actions, `python tools/ub_uart.py <action> [options]`:

| Sub-command | What it does |
|---|---|
| `boot-shell` | Waits for the U-Boot prompt, sets `bootargs` with `rdinit=/bin/sh` for slot B, `flash read`s the FIT from slot B (`0x28C0000`, length `FIT_LEN`) to `0x88000000`, checks that `iminfo` reports load `0x80208000`, then `bootm`s it, waits for the shell and mounts proc/sys/debugfs. No kernel modules are loaded. |
| `send` | Sends commands to the shell that is already running: lines from `--file` (blank lines and `#` comments skipped) and/or one `--cmd`, each bracketed by `@@Bn@@` / `@@En@@` markers and followed by a read of `--wait-per-cmd` seconds. |
| `init` | Run from the `rdinit=/bin/sh` shell: removes the `/etc/modules.d` WiFi autoload entries, then `exec /sbin/init` to bring up the full OpenWrt userspace. |
| `peek` | Read-only: drains the console for `--sec` seconds. |

Other options: `--wait` (seconds to wait for the U-Boot prompt, default 600; `--wait-per-cmd`
overrides the same destination for `send`), `--watch` (seconds to watch for
`Run /init as init process` or `Kernel panic` after `bootm`), `--no-enter` (do not send a
leading carriage return before the first `send` command).

## ub_push.py: which mtd number is slot B

`--mtd` defaults to `3`, and that is slot B (`tclinux_slave`) **only under this
repository's OpenWrt 7-partition device tree**, where `mtd3` is slot B and `mtd4` is
`data`. The **vendor** firmware's 11-entry `/proc/mtd` numbers slot B as `mtd7`, and
`mtd3` there is slot A's rootfs - so the same default points at the wrong partition and
would damage the stock firmware. Run `cat /proc/mtd` on the target and pass `--mtd`
explicitly unless you know you are running this repository's kernel. The default is
deliberately left at `3` and is not auto-detected.

## ub_paste.py: the constraints it works around

The running initramfs of an early build had no /dev/mtd*, no /dev/mem (no
CONFIG_DEVMEM), no /proc/kcore, and its busybox has no base64/uudecode/xxd, so the
console is the only transport. (The missing /dev/mtd* was later explained: it is
devtmpfs, not MTD_BLOCK -- see [`docs/sysupgrade.md`](../docs/sysupgrade.md).) The limits
below were found empirically:

* **Line length.** The target busybox is built with
  `CONFIG_FEATURE_EDITING_MAX_LEN=512` (not 1024). A longer input line is cut off, which
  loses the trailing `>> /tmp/<file>` redirection, makes `printf` print to the console
  instead of the file, and leaves the shell stuck at the PS2 `> ` prompt swallowing every
  command that follows. The script therefore emits **~100 bytes per line** (~430
  characters once the octal escapes are added).
* **XON/XOFF.** Flow control is enabled on the console, so **XOFF (0x13) must be
  honoured**. When the tty RX buffer fills up the kernel sends XOFF and logs
  `ttyS ttyS0: N input overrun(s)` in dmesg; ignoring it drops a byte in the middle of a
  line, which shifts the quoting and wedges the shell in PS2. The script pauses on 0x13
  and only resumes on XON (0x11).
* **Working parameters: ~100 bytes per line and ~64-byte chunks**, paced at `--rate`
  bytes/second (default 2500). Sending larger chunks or ignoring the pacing produces
  input overruns.

After the transfer the script runs `md5sum` on the target itself and compares the result
with the md5 of the local file, so a silent byte loss is caught rather than assumed away.

## Safety

* **Writing SPI-NAND is destructive.** A wrong offset, length or load address overwrites
  live data, and nothing in this directory can undo it.
* **Never write** vendor slot A (`tclinux`), `data`, `config`, `reservearea`, or the
  trailing raw region `0x6900000-0x8000000`, which holds the factory block (GPON identity
  plus laser calibration) and the bad-block table.
* **Prefer the RAM-boot path when trying a new build** (`ub_uart.py boot-shell`, or an
  initramfs image): it writes nothing to flash, so a wrong image costs a reboot instead of
  a brick.
* `ub_push.py` writes only into the empty part of slot B (`tclinux_slave`, `mtd3` under
  the OpenWrt partition scheme - see the mtd numbering caveat above), and the read-back
  `dd if=/dev/mtd3 ...` only works once a kernel that exposes /dev/mtd* is running, which
  on this board needs devtmpfs in the kernel config - see
  [`docs/sysupgrade.md`](../docs/sysupgrade.md). Note also that `dd` must never be used to
  *write* firmware to this NAND: an unerased page keeps the bitwise AND of the old and new
  content plus broken ECC, while `dd` still reports success.
* **A PCIe MMIO hang can only be cleared by a power cycle.** Reading a device BAR while
  `PCI_COMMAND.MEMORY` is 0 hangs the whole SoC: no oops, no watchdog message, no
  soft-lockup warning, and the console dies with it. No tool here recovers the board from
  that state - pull power. Background: [`docs/pcie-root-cause.md`](../docs/pcie-root-cause.md).
* Console-paste limits, the boot chain and the recovery procedures are documented in
  [`docs/booting.md`](../docs/booting.md).

## Logs

Each tool writes a raw console log to `tools/logs/<tool>_<timestamp>.log` (the file name is
also printed as `[con] ...` at start-up), which is what `ub_paste.py` greps for the
target's `md5sum` output.
