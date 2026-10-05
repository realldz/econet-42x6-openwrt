# Booting OpenWrt on the Econet vGP-42X6V1 (Airoha EN7523)

**Board:** Econet / vG vGP-42X6V1 GPON ONU -- Airoha EN7523 (reported as `EN7529CT`),
512 MiB DRAM, 128 MiB SPI-NAND (Winbond W25N01K, `mfr_id=0xEF`, `dev_id=0xAE 0x21`,
`Flash Size=0x8000000`).

**Unit data:** the GPON serial is written `<SERIAL>` throughout this document. The real MAC
address, the GPON/PLOAM password and the vendor web/console passwords are deliberately not
reproduced -- this is a public repository. The vendor default U-Boot password `vht380` is the
only credential printed here, and it is a shared vendor default, not unit-specific data.

**Scope:** how the board gets from power-on to a Linux prompt; the load-address contract that
decides whether the OpenWrt kernel runs at all; and the three transports that can put a file on
the device. Booting is *manual* today -- section 1.4 explains why.

**Status (verified on real hardware):** the OpenWrt 6.18.54 initramfs image boots to userspace
with a serial console, NAND and PCIe, and the Wi-Fi fix image brings `wlan0` up. The vendor
U-Boot autoboot still cannot start OpenWrt, so every OpenWrt boot is a hand-typed
`flash read` / `iminfo` / `bootm` sequence.

---

## 1. The boot chain

### 1.1 What sits where in DRAM

Stage 1 (`tcboot` / `bldr`, flat ARM code in the first 128 KiB of flash) runs first and hands
over to the vendor U-Boot, whose LZMA-compressed image sits at flash `0x24800`; the bootloader
leaves ARM Trusted Firmware at the bottom of DRAM. The board device tree encodes that
reservation and starts Linux above it:

```
/memreserve/ 0x80000000 0x200000;
linux,usable-memory-range = <0x80200000 0x1fe00000>;
```

| Address | What lives there |
|---|---|
| `0x80000000` | start of DRAM |
| `0x80000000`-`0x80200000` | **reserved: TCBoot / ATF, 2 MiB.** Nothing may be loaded here |
| `0x80200000` | first address Linux may use (`linux,usable-memory-range`) |
| `0x80208000` | kernel physical `_text` = FIT `load` = FIT `entry` (see section 2) |
| `0x81800000` | vendor U-Boot `loadaddr` -- do **not** stage a FIT here (see section 4, step 7) |
| `0x88000000` | RAM staging address used by the tools for `flash read` and `loady` |
| `0x81E00000` | link base of the decompressed vendor U-Boot |
| `0x9EE03000` | where the vendor U-Boot relocated itself (`Now running in RAM - U-Boot at:`) |

U-Boot reports `DRAM: 496 MiB`; Linux reports `MemTotal: 480136 kB`; the board DTS declares
512 MiB. The ATF is not optional: the successful boot log contains
`psci: PSCIv1.1 detected in firmware.` / `Using standard PSCI v0.2 function IDs`. Anything that
overwrites `0x80000000`-`0x80200000` breaks PSCI (see section 2.3).

### 1.2 The vendor U-Boot

```
U-Boot 2014.04-rc1 (Feb 10 2025 - 08:16:37)
DRAM:  496 MiB
EN7529CT
Now running in RAM - U-Boot at: 9ee03000
spi_nand_probe: mfr_id=0xef, dev_id=0xae 0x21
Detected SPI NAND Flash :  _SPI_NAND_DEVICE_ID_W25N01K, Flash Size=0x8000000
bmt pool size: 81
BMT & BBT Init Success
Net:   ecnt_eth        Uip activated
Hit enter to stop autoboot:  0
UserName:
```

* Prompt: **`ECNT>`** (reachable only after logging in).
* The binary is LZMA-compressed in flash at **`0x24800`**; it decompresses to 265,072 bytes and
  links at **`0x81E00000`**. `grep`ing the raw dump for `UserName` finds nothing -- decompress
  first.
* Login is asked as `UserName:` then `Password:` (the password is **not echoed**, and the
  hex SHA-256 of what you typed is printed). The user name is compared over its first
  16 bytes with env `username`; the password is compared as a lower-case hex SHA-256 against
  env `password`. The environment block is 16 KiB at flash `0x7C000` (CRC32 little-endian at
  `+0`, `key=value\0` data from `+4`).
* On the unit as shipped, the env `password` was the hash of an operator-set plaintext that was
  never recovered (24k config tokens plus a 38.4 million candidate brute force all failed). The
  practical way in is therefore to rewrite the env (or the whole chip) with a known password --
  the images used by this project write `admin` / **`vht380`** (shared vendor default), and the
  UART tools log in with those values.
* If the env CRC32 is wrong, U-Boot falls back to its compiled-in `admin` / `telecomadmin`
  defaults. Because the comparison is `strcmp(hex_sha256(typed), env_password)` and the compiled
  default is *plaintext*, **a corrupt env makes the U-Boot console permanently unreachable**
  while autoboot still runs. Never write the env with a hand-computed CRC.

Commands present in this build: `flash init|erase [addr] [len]|read [src] [len] *[dst]|
write [dst] [len] *[src]`, `bootflag read|swap`, `iminfo`, `md`, `mw`, `loady` / `loadx` /
`loadb`, `bootm` (including `bootm start|loados|fdt|cmdline|prep|go`), `setenv` / `printenv` /
`saveenv`, `setenv baudrate <n>`. Note that `flash imgread` / `flash imgwrite` exist in the
banner but print the usage text and fail -- the stock `bootcmd` (`flash imgread 2048;bootm`)
does not work.

### 1.3 Two boot slots

| Slot | Partition label | Flash offset | Size | Contents |
|---|---|---|---|---|
| A | `tclinux` | `0xC0000` | 40 MiB | vendor firmware: `HDR2` header at `0xC0000`, FIT at `0xC0100` |
| B | `tclinux_slave` | `0x28C0000` | 40 MiB | where OpenWrt is written (bare FIT at offset 0) |

Slot selection is a single byte, `bootflag`, at flash `0x6FC0000` (`0` = A, `1` = B), readable
and togglable from U-Boot with `bootflag read` / `bootflag swap`. After a failed boot the
dual-image logic flips the flag itself and prints
`write 1 to boot_flag_addr:0x6fc0000`.

The observed autoboot sequence, every time the board resets:

```
bootflag==0 --> booting from Main Image
get fdt data error:0x00000000
Parse main image fail.
flash  (in usage)          <-- 'flash imgread 2048' from bootcmd fails
bootm flag=0, states=70f
## Loading kernel from FIT Image at 81800000 ...
Bad FIT kernel image format!        <-- image was not loaded / was truncated
ERROR: can't get kernel image!
write 1 to boot_flag_addr:0x6fc0000     <-- switch to the second image
bootflag==1 --> booting from second image
Parse second image fail.            <-- slot B is a bare FIT, not an HDR2 image
bootm ... Wrong Image Format ...
ECNT>
```

### 1.4 Why autoboot cannot boot OpenWrt

The vendor autoboot does not parse a generic FIT. It expects **its own dual-image layout**: an
`HDR2` wrapper whose `+0x08` word carries the total size, followed by a FIT with a valid
`/configurations` node.

* The vendor FIT in slot A has **no `/configurations` node** (`iminfo` on it reports
  `Bad FIT image format!`), so the main-image path itself is broken -- which is why the vendor
  firmware can no longer be booted from U-Boot either.
* OpenWrt ships a **bare FIT** (`d00dfeed` at offset 0, totalsize `0x6F0F5C` or `0x7407C8`, no
  `HDR2` wrapper), so the second-image parser reports `Parse second image fail.`
* Either way U-Boot gives up, returns to `ECNT>`, and the operator has to load and boot the FIT
  by hand. **That is why booting OpenWrt is currently a manual procedure.** Making it automatic
  requires changing the env / `bootcmd` logic or producing a vendor-format (HDR2) image; that
  work is still open.

> **Uncertainty (flagged).** The notes are explicit that `Parse main image fail.` was already
> present *before* anything was written to slot B, and they leave its cause open: it is either
> the HDR2/FIT parser of the vendor dual-image code, or the `bootflag` byte encoding (the raw
> dump holds ASCII `'1'`, while U-Boot writes binary `0`/`1`). The flag location is also
> disputed between `0x6FC0000` (what U-Boot prints) and `reservearea + 0x200000` = `0x68C0000`
> (older notes). Treat the paragraph above as accurate for slot B and *probable* for slot A.

---

## 2. The `TEXT_OFFSET` / load-address contract

This is the single most important thing to get right. Get it wrong and the kernel produces
**no output at all** -- no log, no panic, no error, nothing.

### 2.1 The three numbers that must agree

```
arch/arm/Makefile                                  textofs-$(CONFIG_ARCH_AIROHA) := 0x00208000
target/linux/airoha/image/Makefile                 loadaddr-$(CONFIG_TARGET_airoha_en7523) := 0x80208000
en7523-vgp42x6v1.dts                               /memreserve/ 0x80000000 0x200000;
                                                   linux,usable-memory-range = <0x80200000 0x1fe00000>;
```

The arithmetic they encode:

```
PAGE_OFFSET   = 0xC0000000
_text link    = PAGE_OFFSET + TEXT_OFFSET = 0xC0208000
PHYS_OFFSET   = FIT load - TEXT_OFFSET    = 0x80208000 - 0x208000 = 0x80000000
_text physical= PHYS_OFFSET + TEXT_OFFSET = 0x80000000 + 0x208000 = 0x80208000
```

So the FIT load address, the FIT entry address and the kernel's physical `_text` must all be
**`0x80208000`**. Two independent files state this, and they only work when both are patched
together:

* `openwrt/patches/0001-target-airoha-image-fix-en7523-FIT-load-address.patch` changes
  `loadaddr-$(CONFIG_TARGET_airoha_en7523)` from `0x80200000` to `0x80208000`.
* `openwrt/overlay/target/linux/airoha/patches-6.18/100-ARM-airoha-set-TEXT_OFFSET-2MiB.patch`
  adds `textofs-$(CONFIG_ARCH_AIROHA) := 0x00208000` (its header comment records the exact
  failure arithmetic and states that ATF + TCBoot occupy the first 2 MiB,
  `0x80000000`-`0x80200000`).

The configuration also matches the device tree by design: the kernel lands at `0x80208000`,
inside the usable range that starts at `0x80200000`, leaving the first 32 KiB of usable DRAM
for the ARM vectors and page tables.

### 2.2 Why exactly these values

Two constraints in `arch/arm` pin the value down:

1. `arch/arm/kernel/head.S` computes `r8 = runtime(_text) - TEXT_OFFSET`.
   `arch/arm/kernel/phys2virt.S` then requires `PHYS_OFFSET` (that is, `r8 - PAGE_OFFSET`) to be
   **2 MiB aligned**:

   ```
   subs  r3, r8, #PAGE_OFFSET      @ r8 = runtime(_text) - TEXT_OFFSET
   mov   r0, r3, lsr #21
   teq   r3, r0, lsl #21           @ must be 2 MiB aligned
   bne   0f
   0:  mov   r0, r0                @ deadloop on error
       b     0b
   ```

   With the shipped combination (`loadaddr = 0x80200000`, default `TEXT_OFFSET = 0x8000`) the
   expression becomes `0x80200000 - 0x8000 = 0x801F8000`, which is **not** 2 MiB aligned, and
   the loop above is taken.

2. `head.S` also carries
   `#error KERNEL_RAM_VADDR must start at 0xXXXX8000`, so `TEXT_OFFSET` must end in `0x8000`.
   `0x00200000` is therefore not a legal value -- `0x00208000` is.

### 2.3 The observed failure when the contract is broken

The deadloop in `head.S` runs **before `parse_early_param()`**. Consequences, as observed:

* The UART stays **completely silent -- not one character**, from the moment U-Boot prints
  `Starting kernel ...`. There is no panic, no oops, no "Uncompressing" line, nothing.
* The board is later reset by its watchdog after roughly 350 s. To a human it looks like a dead
  board, and it is easy to misattribute to hardware.

Contrast this with the *other* classic failure -- loading the kernel too low, at `0x80008000`
(the old link address `0xC0008000` minus `PAGE_OFFSET`), which overwrites ATF:

| Symptom | Cause |
|---|---|
| **Total silence**, not one character | `TEXT_OFFSET` / `PHYS_OFFSET` violation (deadloop before `parse_early_param()`) |
| A few log lines, then a hang at `psci: probing for conduit method from DT.` | kernel load address collided with ATF at `0x80000000`-`0x80200000` |

Use that difference diagnostically: early output proves `parse_early_param()` ran, so the
`TEXT_OFFSET` arithmetic was fine.

### 2.4 Verify before you load

Always check the FIT before `bootm`:

```
iminfo 0x88000000
```

`iminfo` must report `Load Address: 0x80208000` and `Entry Point: 0x80208000`, and the
`totalsize` field must equal the length you read/wrote. Anything else -- stop and rebuild.

The build can also be verified offline without booting (the notes' `verify_build.py` does the
literal-pool scan for the linked `_text`):

```
_text link       = 0xC0208000  -> TEXT_OFFSET 0x208000 -> physical 0x80208000
FIT load/entry   = 0x80208000 / 0x80208000
MATCH?             YES -- the kernel will run
PHYS_OFFSET      = load - TEXT_OFFSET = 0x80000000 -> 2MiB aligned? YES
```

If you must boot an image built with the wrong `TEXT_OFFSET` (for example to read one kernel
log without a rebuild), stage the FIT in RAM and patch **only** the FIT's `load` and `entry`
properties before `bootm`. The device tree stores these big-endian, so the words are written
byte-swapped:

```
mw.l 0x886EFE14 0x00800080
mw.l 0x886EFE24 0x00800080
bootm 0x88000000
```

Two hard rules from that procedure: the two offsets are specific to a FIT staged at
`0x88000000` for the recorded build (do not reuse them blindly), and **never patch the DTB** --
doing so breaks the `fdt-1` `crc32` hash, U-Boot then uses a wrong `ft_addr`, and the boot dies
with `ERROR: image is not a fdt` / `FDT creation failed! hanging...`.

---

## 3. Serial console access

### 3.1 Port and settings

| Item | Value |
|---|---|
| Adapter | USB-SERIAL CH341, enumerated as **COM23** on the development machine |
| Line settings | **115200 8N1**, 3 wires (TX, RX, GND), no hardware flow control |
| Linux side | `ttyS0` at MMIO `0x1fbf0000` (irq 32, 16550), `console=ttyS0,115200n8` |
| Software flow control | **IXON/XOFF is enabled** on the Linux console -- see section 6 |
| Python | `pyserial`; `--port` defaults to `COM23` in `ub_uart.py`, `ub_push.py`, `ub_paste.py` (`ub_pulse.py` has it hard-coded) |

Do **not** enable RTS/CTS. Pulsing DTR/RTS does not reset this board (section 7.4).

### 3.2 Which credentials belong to which prompt

| Prompt you see | What is running | Credentials |
|---|---|---|
| `UserName:` / `Password:` | vendor U-Boot (appears **before** `Starting kernel`) | `admin` / **`vht380`** (shared vendor default; password not echoed) |
| `login:` | vendor Linux getty on `ttyS0` (appears **after** the kernel booted) | `admin` plus the stock console password recorded in the vendor romfile -- not reproduced here |
| telnet `:23` / SSH `:62222` | vendor Linux, if the vendor backdoor service was enabled | credentials from the vendor romfile -- not reproduced here |
| no prompt at all, straight to `~ #` | OpenWrt with `rdinit=/bin/sh` | root shell, **no login** |
| `Please press Enter to activate this console.` | OpenWrt full procd boot | root shell, **no password on the initramfs** |

Do not confuse the two `admin` prompts: the U-Boot one takes `vht380` (or whatever the env
holds), the Linux getty one does not.

### 3.3 How to get a shell

1. **Enter U-Boot.** Power-cycle or reset, then send a carriage return during the 3-second
   `Hit enter to stop autoboot` window. If you miss it, wait: autoboot fails on its own and
   leaves you at `ECNT>` anyway.
2. **Log in** at `UserName:` with `admin` / `vht380`.
3. **For a quick OpenWrt root shell**, run the recorded tool:

   ```
   python temp\42X6\ub_uart.py boot-shell
   ```

   It grabs the U-Boot prompt, logs in, sets `bootargs` (with `rdinit=/bin/sh`), does the
   `flash read` + `iminfo` + `bootm` sequence, mounts `/proc`, `/sys` and `/sys/kernel/debug`,
   and waits until the shell answers `echo @@RDY@@`.
4. **For a full OpenWrt boot** (procd, ubus, the real console banner), run the `init` action
   from that same shell; it first deletes the `mt7915e` / `mt76*` autoload entries under
   `/etc/modules.d/` (which prevents the Wi-Fi driver panic) and then `exec /sbin/init`:

   ```
   python temp\42X6\ub_uart.py init
   ```

   Alternatively boot without `rdinit=/bin/sh` and press Enter at
   `Please press Enter to activate this console.` Note that with the pre-quirk image the kernel
   panics about 10 s after the console appears (see the panic text in the notes); the
   PCIe-quirk image boots cleanly and brings `wlan0` up.
5. **Keep talking to the running shell.** The serial link is not held exclusively, so every
   later `send` invocation talks to the shell that is still alive -- no reboot needed:

   ```
   python temp\42X6\ub_uart.py send --cmd "ls /proc/mtd"
   python temp\42X6\ub_uart.py send --file temp\42X6\cmds_x.txt
   ```

6. **Vendor Linux only:** telnet `23` / SSH `62222` could be turned on by a web POST that sets
   `statevalue=1`; that applies to the stock firmware, not to OpenWrt.

---

## 4. RAM-boot procedure (milestone M1)

The image used for this milestone is a `*-initramfs-kernel.bin` (a bare FIT, kernel + initramfs
in one; it needs no rootfs partition). Once it is in slot B it never has to be transferred
again -- only read back and booted.

### 4.1 Key addresses used below

| Name | Value | Meaning |
|---|---|---|
| `SLOT_B` | `0x28C0000` | slot B (`tclinux_slave`) start |
| `LOAD_ADDR` | `0x88000000` | RAM staging address for the FIT |
| `FIT_LEN` | length in bytes of **your** image | e.g. `0x6F0F5C` = 7,278,428 B, `0x7407C8` = 7,604,168 B |
| `_text` / `load` / `entry` | `0x80208000` | must be reported by `iminfo` |

`FIT_LEN` is a per-image constant, not a hardware constant: the tools' fixed value must be
updated whenever a new image is written (`ub_uart.py` carries `FIT_LEN = 0x7407C8` for the
Wi-Fi-fix image). See the flagged conflict in section 9.

### 4.2 The complete sequence

1. Connect the 3-wire UART, open COM23 at **115200 8N1**, and make sure XON/XOFF is enabled in
   your terminal program (section 6).
2. Power-cycle the board and press Enter to stop autoboot; wait for `ECNT>`.
3. Log in: `admin` / `vht380` (the vendor default; not echoed).
4. Set the kernel command line. The quoted form is **mandatory** -- without quotes the vendor
   `setenv` accepts only one value token, prints its usage text and silently sets nothing:

   ```
   setenv bootargs "console=ttyS0,115200n8 earlycon=uart8250,mmio32,0x1fbf0000 ignore_loglevel loglevel=8"
   printenv bootargs
   ```

   The stock env contains **no** `bootargs` variable at all (`printenv bootargs` ->
   `## Error: "bootargs" not defined`), and the vendor U-Boot then writes an empty
   `/chosen/bootargs` into the device tree, so the kernel would receive an empty command line.
   You must set it before every `bootm`. The recorded tool also sets `console` as a precaution
   (the `uboot_m1c.py` step in the notes) and verifies with `printenv` before booting:

   ```
   setenv console "ttyS0,115200n8 earlycon=uart8250,mmio32,0x1fbf0000"
   ```

   Variants in use:

   | Variant | String | Used by |
   |---|---|---|
   | Base | `console=ttyS0,115200n8 earlycon=uart8250,mmio32,0x1fbf0000 ignore_loglevel loglevel=8` | `ub_uart.py` (`BOOTARGS_BASE`) |
   | Direct shell | the base string plus `rdinit=/bin/sh` | `ub_uart.py boot-shell` |
   | Auto-reboot on panic | the base string plus `panic=5` | `uboot_m1c.py` |
   | Minimal legacy | `console=ttyS0,115200n8 earlycon` | `uboot_ymodem.py`, and the `chosen/bootargs` in the board DTS |

   `0x1fbf0000` is the real `ttyS0` MMIO base, so `earlycon` works before the driver binds.
   Beware `panic=5`: it makes any panic reboot the board 5 s later, which cuts the log short.
5. Read the image from slot B into RAM (skip this step only if you have just uploaded it with
   `loady`, in which case it is already at `0x88000000`):

   ```
   flash read 0x28C0000 0x7407C8 0x88000000
   ```

   Substitute the exact length of the image that was written to slot B. A too-small length
   truncates the FIT; the mismatch shows up immediately as a wrong `totalsize` in `iminfo`.
   Reading is harmless -- it touches no flash state.
6. Verify the header **before** booting:

   ```
   iminfo 0x88000000
   md.b 0x88000000 0x10
   ```

   Expected: `iminfo` reports `totalsize` equal to the length you used,
   `Load Address: 0x80208000`, `Entry Point: 0x80208000`, and crc32/sha1 hashes `OK`;
   `md.b` shows the FIT magic bytes `d0 0d fe ed` followed by the totalsize in big-endian
   (`5c 0f 6f 00` for a `0x6F0F5C` image, `c8 07 74 00` for a `0x7407C8` one). Note that `md`
   (word display, no `.b`) prints that same magic as `edfe0dd0`, because of word order.
   If load/entry are not `0x80208000`, **stop** -- see section 2.
7. Boot:

   ```
   bootm 0x88000000
   ```

   Watch for `Uncompressing Kernel Image ... OK` and then
   `Run /init as init process`. With `rdinit=/bin/sh` you land in a root shell; the tool then
   mounts `/proc`, `/sys` and `/sys/kernel/debug` for you.

   **Do not** stage the FIT at the vendor `loadaddr` `0x81800000`: the kernel decompresses to
   `0x80208000`, the uncompressed `Image` is 24,692,192 bytes, and the tail of it therefore
   overwrites the FIT at `0x81800000`. U-Boot aborts with
   `ERROR: new format image overwritten - must RESET the board to recover`. That is exactly why
   the working staging address is `0x88000000`.

8. One-shot alternative. The whole of steps 2-7 is implemented by:

   ```
   python temp\42X6\ub_uart.py boot-shell
   ```

   Useful flags: `--port` (default `COM23`), `--wait` (seconds to wait for the U-Boot prompt,
   default 600), `--watch` (seconds to watch the boot, default 120). `--wait` and
   `--wait-per-cmd` write the same argparse destination, so the later occurrence wins.

### 4.3 If the image is not in flash yet

Upload it with YMODEM straight into RAM, then verify and boot identically:

```
loady 0x88000000
iminfo 0x88000000
bootm 0x88000000
```

`loady` expects a YMODEM transfer (XMODEM-1K blocks plus a block-0 header carrying the file
name and size). Throughput at 115200 is about **0.6 MB/min**, so a 7.3-7.6 MB image takes
**11-13 minutes**, verified at 10.8 minutes / 7108 blocks. `uboot_ymodem.py` and
`uboot_m1c.py --no-flash` drive it from the PC. Do not use TFTP (section 5.3).

To make it permanent in the same run, `uboot_m1c.py` follows the upload with
`flash erase` / `flash write` into slot B:

```
flash erase 0x28C0000 0x760000
flash write 0x28C0000 0x7407C8 0x88000000
flash read  0x28C0000 0x10 0x87000000
md.b 0x87000000 0x10
```

The erase length is rounded up to a whole number of 128 KiB NAND blocks (`0x7407C8` -> 59
blocks -> `0x760000`). The read-back must show the FIT magic bytes `d0 0d fe ed`.

---

## 5. Getting the image onto the device

### 5.1 The constraints that shape every method

Everything below is measured on the running OpenWrt initramfs, and together these constraints
eliminate almost every conventional transfer path.

| Route | Available? | Why |
|---|---|---|
| `/dev/mtdN`, `/dev/mtdblockN` | **no** | `/proc/mtd` lists the partitions, but the kernel was built without `CONFIG_MTD_CHAR` / `CONFIG_MTD_BLOCK` and ships no `mtd*.ko` |
| `/dev/mem` | **no** | `CONFIG_DEVMEM` is off, so you cannot read RAM that U-Boot `loady` left behind |
| `/proc/kcore` | **no** | `CONFIG_PROC_KCORE` is off |
| network (eth / Wi-Fi / PON) | **no** | no driver runs in this image (Wi-Fi only after the PCIe quirk image; Ethernet has no EN7523 driver at all) |
| `base64`, `uudecode`, `xxd`, `od` | **no** | busybox has none of them; only `hexdump` exists, and it is read-only |
| shell `printf` builtin | **yes** | the only usable route into the running system |
| U-Boot `loady` (YMODEM) over UART | **yes** | slow but reliable; the only route for a whole image |
| U-Boot `flash erase` / `flash write` | **yes** | the only way to persist something from U-Boot |
| U-Boot TFTP | **effectively no** | see 5.3 |

Two more consequences worth stating plainly:

* `sysupgrade` **cannot work** on an image built without `CONFIG_MTD_BLOCK` -- this is a real
  defect of the current image, not just a debugging inconvenience. The fix list is
  `CONFIG_MTD_BLOCK`, `CONFIG_MTD_CHAR`, `CONFIG_MTD_CMDLINE_PARTS`, plus the busybox `base64`
  applet (and `CONFIG_DEVMEM` / `CONFIG_PROC_KCORE` if you want them for diagnostics).
* Because no MTD block device exists, a file pushed into flash with `ub_push.py` cannot be read
  back from that same running Linux. `ub_push.py` is for staging data that a later boot or
  another image will consume -- not for handing a file to the live initramfs.

### 5.2 The three transports

**Transport 1 -- YMODEM into RAM, then `bootm`.** Use it to try a fresh image without touching
flash at all, which is the safest way to test a new build.

```
loady 0x88000000          # PC sends the file via YMODEM
iminfo 0x88000000         # must show Load/Entry 0x80208000
bootm 0x88000000
```

Tool: `uboot_ymodem.py`, or `uboot_m1c.py --no-flash`. Cost: 11-13 minutes per attempt. Applies
to a whole bootable image.

**Transport 2 -- YMODEM into RAM, then `flash erase` + `flash write`.** Use it to make an image
persistent (that is how the OpenWrt image got into slot B) or to park a small file at a spare
offset.

```
loady 0x88000000
flash erase 0x38C0000 0x20000          # one 128 KiB NAND block (ERASE = 0x20000 in ub_push.py);
                                       # the tool rounds the length up to whole blocks
flash write 0x38C0000 <LEN> 0x88000000 # <LEN> = the size of the file you sent
md.b 0x88000000 0x40                   # read back from RAM
```

Tools: `uboot_m1c.py` (writes slot B) and `ub_push.py` (writes a file into the scratch offset).
The scratch area the tools stage into is **`0x38C0000`** -- 16 MiB into slot B
(`ub_push.py --dst` default), which is beyond the ~7.4 MB the OpenWrt FIT occupies, so it does
not clobber the image. `--addr` defaults to `0x88000000`. Read the staged bytes back from Linux
with the `dd` line the tool prints (`bs=512 skip=32768`, i.e. 16 MiB into the slot) -- **but note
the warning about its `--mtd` default in section 9.2 (item 5)** before you trust the device
number.
Applies to whole images (slot B) and to small files (scratch offset, if a future MTD-capable
image will consume them).

**Transport 3 -- console paste via `printf` octal escapes.** The only way to put a regular file
into the *running* Linux. Use it for small things: a `.ko` module, a firmware blob, a script.

```
python temp\42X6\ub_paste.py --file temp\42X6\ringwatch.ko --rate 2500
```

It emits one shell line per 100 input bytes:

```
rm -f /tmp/ringwatch.ko
printf '\173\105\114\106...' >> /tmp/ringwatch.ko
...
md5sum /tmp/ringwatch.ko
```

Every byte becomes three octal digits, so an escape can never merge with a following digit.
Verified: `ringwatch.ko` (6,628 B) arrived with a matching md5. Cost: roughly 2.5-3 KB/s, so
100 KB takes about 2.5 minutes -- still far cheaper than rebuilding and re-uploading a 7 MB
image. The gotchas that make or break this method are section 6.

**Historical path (vendor firmware only).** While the *stock* Linux still booted, the image
reached slot B over the network: dropbear on port 62222 has no SFTP server, so the file went
across as base64 over `ssh` (7.28 MB in 2.8 s), or with `scp -O`, and was then written with
`/userfs/bin/mtd unlock|erase|writeflash ... tclinux_slave` followed by a read-back diff. This
route needs the vendor firmware running with telnet/SSH enabled; it is not available to OpenWrt
until there is a network driver.

### 5.3 Why TFTP is not used

The vendor U-Boot does have `Net: ecnt_eth`, but the `ecnt_eth` / QDMA path **wedges after
about 50-60 KB in every session** (`TX DSCP_INFO ... incorrect`), regardless of `blksize` or
delays. TFTP was therefore abandoned, and the earlier plan of
`tftpboot 0x81800000 <file>` + `bootm` is doubly wrong: besides the wedge, `0x81800000` is
where the decompressed kernel would overwrite the FIT (section 4, step 7). The working address
is `0x88000000` and the working protocol is YMODEM over the console.

---

## 6. Console-paste gotchas

Two traps cost real debugging time. Both end the same way: the shell falls into the secondary
`> ` (PS2) prompt and **swallows every following command**.

### 6.1 Line length: `CONFIG_FEATURE_EDITING_MAX_LEN = 512`

OpenWrt's busybox ash is built with `CONFIG_FEATURE_EDITING_MAX_LEN=512` (512, not 1024). Any
line longer than that is **truncated**, and the truncation drops the tail -- typically the
`>> /tmp/x.ko` redirection. The `printf` output then goes to the console instead of the file,
the unmatched quote leaves the shell waiting for more input, and everything you send afterwards
is consumed as part of that unfinished string.

Working parameters:

| Parameter | Value | Why |
|---|---|---|
| bytes per line | **100** (`BYTES_PER_LINE`) | 100 bytes -> `printf '` (8) + 400 escape characters + `' >> /tmp/x.ko` (22) = about **430 characters**, safely under 512 |
| escape format | `\ooo`, always **three** octal digits | 3 digits per byte means a following digit can never be read as part of the escape |
| bytes per serial chunk | **64** (`CHUNK`) | small enough that an XOFF can still be seen in time |
| send rate | **2500 B/s** (`--rate`) | well below the 115200 bps theoretical ~11520 B/s, so the tty receive buffer does not fill |

### 6.2 XON/XOFF: ignoring XOFF overruns the FIFO

The console has `IXON` enabled. When the tty receive buffer approaches full the kernel sends
**XOFF (0x13)**, and if you keep pushing bytes the FIFO overruns -- the kernel says so itself:

```
[  146.385334] random: crng init done
[  146.389486] ttyS ttyS0: 1 input overrun(s)
```

A byte lost in the middle of a quoted string shifts the quoting, which produces exactly the
stuck-`> ` state described above. This -- not the 512-character limit -- caused the first two
failed paste attempts (those lines were 430 characters long, i.e. legal).

Rules that work:

* **Pause on 0x13, resume only on 0x11 (XON).** `ub_paste.py` tracks both bytes in everything it
  reads and refuses to write while paused.
* Send in 64-byte chunks so the pause can be noticed quickly.
* Scan the log for `input overrun` and warn; `ub_paste.py` does this automatically.

### 6.3 Procedure and verification

1. Send **3x Ctrl-C (0x03)** before the first line. This escapes the PS2 `> ` prompt if a
   previous attempt was truncated. `ub_paste.py` does this itself; `ub_cc.py` does it on demand.
2. Paste the generated `printf` lines (`--dst` defaults to `/tmp/<basename>`).
3. Let the script run `md5sum <dst>` and compare it with the local file's md5. If the md5 does
   **not** appear in the log, treat the transfer as failed -- do not "try the module anyway".
4. Failure recovery: 3x Ctrl-C, then start again.

**Faster alternative, not implemented.** The notes record a possible ~4x speed-up: drop the
octal escaping entirely, put the line discipline in raw mode
(`stty -icanon -echo -isig -icrnl min 0 time 2`, keeping `ixon`) and pipe the binary straight
into `dd of=/tmp/x`, using a 200 ms silence as EOF. This removes the line-length limit and sends
only the real bytes, but it loses echo (harder to diagnose) and needs `stty sane` afterwards.
It has **not** been tested; do not document it as a working method until it is.

---

## 7. Recovery

### 7.1 PCIe MMIO hang: power-cycle only

Reading a BAR of a PCIe function whose `PCI_COMMAND.MEMORY` bit is still 0 produces a master
abort, and **the EN7523 has no PCIe completion timeout**: `readl()` spins forever. Because the
offending access happened in a timer softirq, softirqs stop, the tty flip buffer is never
processed, and the console goes **completely dead**:

* no oops, no panic, no soft-lockup message, no watchdog reset, no automatic reboot;
* Ctrl-C does nothing, waiting 90 s changes nothing;
* **pulsing DTR/RTS does nothing** (tested, see 7.4).

**The only way out is to remove and restore power.** Prevention: before touching any BAR, read
`PCI_COMMAND` through config space (always safe) and require `MEMORY = 1` before a single MMIO
read.

### 7.2 A live Linux

On a Linux that still answers, `echo b > /proc/sysrq-trigger` forces an immediate reboot.

> **Uncertainty (flagged).** The source notes only record that the **vendor** firmware has no
> `/proc/sysrq-trigger` and that its `reboot` (shell and web) is a no-op -- there, power-cycling
> is the only reboot. Whether the OpenWrt image has `CONFIG_MAGIC_SYSRQ` enabled was not
> verified in the notes. Test it before relying on it.
>
> A related built-in: with `panic=5` in `bootargs`, any kernel panic reboots the board by itself
> after 5 seconds (back to `ECNT>`, since autoboot cannot start OpenWrt).

### 7.3 A board sitting at `ECNT>`

Nothing is wrong with the hardware. `Parse main image fail.` / `Parse second image fail.` plus
the prompt simply mean both slots failed the vendor parser. Either boot manually (section 4) or,
if slot B was overwritten, restore it:

```
flash read  0xC0000 0x2800000 0x88000000     # whole slot A (vendor image), 40 MB
iminfo 0x88000000                            # optional check
flash erase 0x28C0000 0x2800000
flash write 0x28C0000 0x2800000 0x88000000   # slot B becomes a copy of slot A
```

Slot A's FIT is itself unparseable in this state, so this restores the *dual-image* invariant
rather than the ability to boot the vendor firmware. To get the vendor firmware back, restore
slot B from the original dump (`0x28C0000`-`0x50C0000`) or reflash the chip (7.5).

### 7.4 DTR/RTS pulsing does not reset this board

`ub_pulse.py` tried five patterns -- RTS low 200 ms, DTR low 200 ms, both low 500 ms, DTR low
2 s, both low 2 s -- and read the UART for 6 s after each. The board never came back. **Do not
budget on a serial-port reset**; walk to the power socket.

### 7.5 Bricked bootloader (no LEDs)

A dead board with no LED activity at all is usually a damaged bootloader, not an env problem --
an invalid env still boots fine via the compiled defaults. Recovery is an external programmer
(CH341A) writing the original full-chip dump. See section 8 for the two hard rules: use an
**unmodified** image, and remember that NAND erases in 128 KiB blocks, so a wrong write to
`mtd0` costs the whole first block (`0x00000`-`0x1FFFF`, which holds TCBoot stage 1). The
minimal recovery file is the first **128 KiB** of `mtd0` (`0x00000`-`0x1FFFF`) from the original
dump; writing the whole 128 MiB works too and is just slower.

---

## 8. Flash-write safety

### 8.1 Partition table

Both numbering schemes are in use in the notes, and `mtdN` means different things in each.
Always check `cat /proc/mtd` on the running system first.

| Vendor `/proc/mtd` (11 entries) | Label | Offset | Size | OpenWrt DTS (7 entries) | Write? |
|---|---|---|---|---|---|
| mtd0 | `bootloader` | `0x0000000` | `0x80000` | mtd0 | env only, with a correct CRC32 (section 1.2) |
| mtd1 | `romfile` | `0x0080000` | `0x40000` | mtd1 | no |
| mtd2 | `kernel` (slot A) | `0x00C0000` | `0x286C76` | -- (inside mtd2 `tclinux`) | no |
| mtd3 | `rootfs` (slot A) | `0x034EC76` | `0x1620000` | -- (inside mtd2 `tclinux`) | no |
| mtd4 | `tclinux` (slot A) | `0x00C0000` | `0x2800000` | mtd2 | **never** |
| mtd5 | `kernel_slave` | inside slot B | `0x286C76` | -- (inside mtd3) | via slot B only |
| mtd6 | `rootfs_slave` | inside slot B | `0x1620000` | -- (inside mtd3) | via slot B only |
| **mtd7** | **`tclinux_slave`** (slot B) | **`0x28C0000`** | `0x2800000` | **mtd3** | **yes -- the only slot this project writes** |
| mtd8 | `data` | `0x50C0000` | `0x1400000` | mtd4 | not in the recorded procedures |
| mtd9 | `config` | `0x64C0000` | `0x200000` | mtd5 | **never** |
| mtd10 | `reservearea` | `0x66C0000` | `0x240000` | mtd6 | **never** |
| -- | *not an mtd partition* | `0x6900000`-`0x8000000` | 23 MiB | undeclared | **never** (raw vendor area) |

Inside the trailing raw region:

| Offset | Marker |
|---|---|
| `0x6F00000` | `factory` block -- GPON identity, laser BOB calibration, magic `0x12344321` |
| `0x6FC0000` | `bootflag` byte (`0` = slot A, `1` = slot B) |
| `0x75E0000` | `RAWB` |
| `0x7FE0000` | `BMT` -- bad-block table (last two blocks) |

### 8.2 Rules

1. **Never write slot A** (`tclinux`, `0xC0000`-`0x28C0000`). It is the vendor fallback and it is
   the only copy of the stock image in a bootable position.
2. **Never write `data`, `config`, `reservearea`,** and never the raw region
   `0x6900000`-`0x8000000` (factory identity/calibration, `RAWB`, and the BMT bad-block table).
   Losing the BMT loses the NAND.
   *(Note: the board DTS currently declares `data` as writable, because it is the intended future
   overlay partition, while the flash-map notes mark it as not-to-be-written. Nothing in the
   recorded procedures writes it. Treat it as off-limits until the overlay design is settled.)*
3. **The only region this project writes is slot B** (`tclinux_slave`, `0x28C0000`), plus the
   staging offset `0x38C0000` *inside* slot B. Note that anything staged at `0x38C0000` is
   destroyed by the next full slot-B write.
4. **Never write a chip image that was modified outside the running system.** A CH341A-class
   programmer writes main pages only and leaves the NAND ECC/spare bytes as they were; the
   resulting pages fail ECC on read (`Using Flash ECC`) and the board does not boot. Measured
   directly: a modified dump does not boot, the original does. Write flash only
   (a) from running Linux through `/userfs/bin/mtd`, or (b) from U-Boot with
   `flash erase` + `flash write`, which compute ECC in the controller.
5. **Never use `dd`/`nandwrite` directly on `/dev/mtd0`** from the vendor Linux -- that bypasses
   the vendor BMT. Use `/userfs/bin/mtd writeflash` / `readflash`.

### 8.3 The vendor `mtd` tool is decimal-only

`/userfs/bin/mtd` parses `<n>` and `<offset>` with `atoi()` (the binary imports no
`strtoul`/`strtol`), so **hexadecimal offsets are read as 0**. This has already bricked a unit:
`... 16384 0x7C000 bootloader` became "write 16384 bytes at offset 0", erased the whole first
128 KiB block of `mtd0` (TCBoot stage 1) and left a board with no LEDs at all.

| Hex | Decimal you must type |
|---|---|
| `0x7C000` (U-Boot env) | **507904** |
| `0x80000` (mtd0 size) | **524288** |
| `0x60000` | 393216 |
| whole partition | **0** |

The safe, proven form is a whole-partition write at offset `0`:

```
/userfs/bin/mtd unlock bootloader
/userfs/bin/mtd erase  bootloader
/userfs/bin/mtd writeflash /tmp/bl.bin 524288 0 bootloader

/userfs/bin/mtd readflash  /tmp/bl_chk.bin 524288 0 bootloader
openssl dgst -sha256 /tmp/bl_chk.bin      # must equal the local file's sha256
sync
```

**Always read back and compare SHA-256 before `reboot`.** If you write only the 16 KiB env, use
the decimal value `507904`, never `0x7C000`, and still read back.

### 8.4 U-Boot-side writes

```
flash erase <addr> <len>        # len is rounded up to a 128 KiB NAND block
flash write <dst> <len> <src>
flash read  <src> <len> <dst>
```

`flash erase` clears whole 128 KiB blocks, so a slot-B update for a 7,604,168-byte image becomes
`flash erase 0x28C0000 0x760000` (59 blocks). Read back at least the first 16 bytes
(`flash read 0x28C0000 0x10 0x87000000` + `md.b 0x87000000 0x10`) and expect `d0 0d fe ed`.

---

## 9. Sources, and where the notes are ambiguous

### 9.1 Sources

Engineering notes (Vietnamese) in the development workspace:

| Document | Used for |
|---|---|
| `docs/econet/42X6_uboot_console.md` | U-Boot banner, env layout, login logic, credential map, decimal-only `mtd` trap |
| `docs/econet/42X6_openwrt_m1_status.md` | `TEXT_OFFSET` proof, autoboot failure log, RAM-boot recipe, transfer constraints, paste gotchas, hazards |
| `docs/econet/42X6_openwrt_build_prep.md` | build artifacts, `tftpboot` plan that was superseded, `CONFIG_TARGET_ROOTFS_INITRAMFS` |
| `docs/econet/42X6_<SERIAL>.md` | live `/proc/mtd` partition table, flash map, serial/identity facts |

Tooling (`temp/42X6/`), whose flags are quoted as implemented:

| Tool | Actions / flags as implemented | Notes |
|---|---|---|
| `ub_uart.py` | `boot-shell` / `send` / `init` / `peek`; `--port` (COM23), `--wait` (600), `--watch` (120), `--file`, `--cmd`, `--wait-per-cmd` (5, same destination as `--wait`), `--no-enter`, `--sec` (3). Constants: `SLOT_B=0x28C0000`, `FIT_LEN=0x7407C8`, `LOAD_ADDR=0x88000000` | `send` skips blank lines and `#` comments and brackets each command with `echo @@B<n>@@` / `echo @@E<n>@@` markers |
| `ub_push.py` | `--file` (required), `--port` (COM23), `--addr` (0x88000000), `--dst` (0x38C0000), `--mtd` (3), `--wait` (600) | waits for `ECNT>`, logs in, `loady <addr>`, YMODEM, `flash erase`, `flash write`, `md.b`, then prints the Linux `dd` line |
| `ub_paste.py` | `--file` (required), `--dst` (default `/tmp/<basename>`), `--port` (COM23), `--rate` (2500), `--tail-wait` (6.0). Constants: `BYTES_PER_LINE=100`, `CHUNK=64` | sends 3x Ctrl-C first; finishes with `md5sum` + `ls -la` and checks the md5 in its own log |
| `ub_pulse.py` | no flags; `COM23` hard-coded | the DTR/RTS reset attempt that failed |

Repo artifacts referenced above: `openwrt/patches/0001-target-airoha-image-fix-en7523-FIT-load-address.patch`,
`openwrt/overlay/target/linux/airoha/patches-6.18/100-ARM-airoha-set-TEXT_OFFSET-2MiB.patch`,
`openwrt/overlay/target/linux/airoha/dts/en7523-vgp42x6v1.dts`.

### 9.2 Ambiguities flagged in the text

1. **`Parse main image fail.` cause (section 1.4).** The notes prove it predates the slot-B write
   but do not settle whether the cause is the HDR2/FIT parser or the `bootflag` byte encoding
   (ASCII `'1'` in the dump vs binary `0`/`1` written by U-Boot). The flag's location is also
   disputed: `0x6FC0000` (what U-Boot prints) vs `0x68C0000` (`reservearea + 0x200000`, older
   notes).
2. **Extent of the ATF reservation (section 1.1).** The DTS reserves 2 MiB
   (`0x80000000`-`0x80200000`) and the `TEXT_OFFSET` patch header says ATF + TCBoot occupy the
   first 2 MiB, while one note places "ATF" at `0x80000000`-`0x80040000`. All sources agree that
   nothing may be loaded below `0x80200000`.
3. **`FIT_LEN` constants conflict.** `ub_uart.py` comments `0x6F0F5C` as "the original vendor
   FIT", but the notes record `0x6F0F5C` = 7,278,428 B as the **OpenWrt** `tofs208000` image size,
   and the vendor FIT in slot A is `0x187E453` = 25,681,491 B. Take the length from the image you
   actually wrote (and from `iminfo`'s `totalsize`), never from a memorised constant.
4. **`ub_push.py` docstring vs its parser.** The docstring advertises
   `--dst 0x38C0000 --mtd 3 --mtd-off 0x1000000`, but `--mtd-off` is **not defined** by the
   argument parser (the MTD offset is derived from `--dst`); passing it will error out.
5. **`--mtd` numbering.** `ub_push.py` defaults to `--mtd 3`, which is correct for the **OpenWrt
   7-partition DTS** (where `tclinux_slave` is mtd3, and `data` is mtd4) but wrong for the
   **vendor 11-partition `/proc/mtd`** table (where slot B is mtd7 and mtd3 is slot A's rootfs).
   The `dd ... skip=32768` line the tool prints matches the 16 MiB offset inside slot B, so the
   intended device is `tclinux_slave`; override `--mtd 7` when reading from the vendor firmware.
6. **`mknod` for MTD devices is unverified.** One session recommends creating
   `mknod /dev/mtd3 c 90 3` and `mknod /dev/mtdblock3 b 31 3` in the `rdinit=/bin/sh` shell and
   reports that `dd` on the char device returns 0 bytes when `skip>0` (so `/dev/mtdblockN` must be
   used); a later session states the initramfs kernel has neither `CONFIG_MTD_CHAR` nor
   `CONFIG_MTD_BLOCK` and no `mtd*.ko`, so `/dev/mtd*` cannot work at all. The two observations
   cannot both be true of the same image. Until `CONFIG_MTD_BLOCK`/`CONFIG_MTD_CHAR` are enabled,
   assume no MTD device nodes are usable (section 5.1).
7. **`echo b > /proc/sysrq-trigger` is not verified on OpenWrt** (section 7.2). The notes only
   establish that the vendor firmware lacks `/proc/sysrq-trigger` and that its `reboot` is a
   no-op.
8. **`admin` / `vht380`** is documented here as the shared vendor default. Strictly, the unit as
   shipped carried an operator-set SHA-256 hash in its env; `vht380` is the plaintext this project
   writes into the env (or the whole chip image) to make the U-Boot console reachable.

### 9.3 Deliberately omitted

The GPON serial (shown as `<SERIAL>`), the MAC address, the GPON/PLOAM password, the U-Boot env
`password` hash, and all vendor web/console/telnet/SSH passwords except the shared vendor default
`vht380`.
