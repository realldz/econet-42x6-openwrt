# Building

How to get from a clean OpenWrt checkout to a flashable image, and how to keep
the patch series maintainable.

The short version: build from source **once**, with the pinned kernel options and
the package set below, use it to produce this project's own Image Builder, and
compose every later image with that. The traps that waste an evening are all in
sections 3 and 4.

---

## What you need

* Linux, WSL2, or a Linux container. **OpenWrt cannot be built on Windows
  directly** -- the build needs a case-sensitive filesystem and a GNU userspace.
* Roughly 30 GB of free disk for a first build, and a lot of patience: a cold
  `airoha/en7523` build downloads and compiles a toolchain, a kernel and the
  package set. On 8 cores this was ~17 minutes for a rebuild with the toolchain
  already present, considerably longer from scratch.
* `git`, `make`, `gcc`, `g++`, `ncurses` headers, `zlib` headers, `python3`,
  and the rest of OpenWrt's host prerequisites. Use OpenWrt's own list rather
  than guessing: <https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem>.

This project does not pin a particular build host. What was used during
development was a `debian:stable-slim` container with the workspace bind-mounted,
which is a convenient way to keep the host clean:

```bash
docker run -d --name owrt -v "$PWD:/w" debian:stable-slim sleep infinity
docker exec owrt bash -c 'apt-get update && apt-get install -y \
    build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
    gettext git libncurses-dev libssl-dev python3 rsync unzip zlib1g-dev \
    file wget ca-certificates'
```

If you build as `root` inside such a container, export
`FORCE_UNSAFE_CONFIGURE=1`: the bundled `tar` refuses to configure itself when it
thinks it is running as root, and the build stops in the tools stage.

---

## 1. Get OpenWrt at the pinned revision

The patch series has exact context lines, so it only applies to one revision.
That revision is recorded in [`scripts/pin.env`](../scripts/pin.env).

```bash
git clone https://github.com/openwrt/openwrt.git ../openwrt
git -C ../openwrt checkout 9b95be917b2804cf877ca05c078175b37a3a95bf
```

Keep the tree outside this repository. The destination directory cannot be called
`openwrt` *inside* the checkout, because this project already has a top-level
`openwrt/` directory holding the board support, and cloning into it fails with
`destination path 'openwrt' already exists and is not an empty directory`. The
name of the destination does not matter to any of the scripts -- they all take
the tree as an argument -- so put it wherever you keep sources.

A shallow clone is not enough if you intend to regenerate the patch series,
because `make-patches.py export` reads files straight out of git:

```bash
git clone --filter=blob:none https://github.com/openwrt/openwrt.git ../openwrt
git -C ../openwrt checkout 9b95be917b2804cf877ca05c078175b37a3a95bf
```

`git -C ../openwrt rev-parse HEAD` has to print the pinned revision:
`apply-overlay.sh` refuses to touch a tree at any other revision -- and
`build-firmware.sh` runs it, so a source build refuses too -- because a series with
exact context lines would either fail to apply or, worse, apply in the wrong place.

---

## 2. Apply the board support

```bash
./scripts/apply-overlay.sh /path/to/openwrt
```

This does four things:

1. applies `openwrt/patches/*.patch` with `git apply` -- these are edits to
   **existing** upstream files, so they must be patches rather than file copies,
   otherwise bumping the pin would silently discard upstream changes;
2. copies `openwrt/overlay/.` verbatim into the tree -- these are **new** files:
   the board device tree, the EN7523 kernel patch series
   (`target/linux/airoha/patches-6.18/`), the base-files overlay
   (`platform.sh` for `sysupgrade`, `en7523/base-files/etc/board.d/02_network`
   for the switch ports), the mt76 WLAN LED patches
   (`package/kernel/mt76/patches/`) and the diagnostic kernel modules;
3. optionally copies `openwrt/dbg/` with `--with-mt76-debug` -- one diagnostic
   mt76 patch that prints ring base addresses and must never ship;
4. with `--with-pon`, adds the sixteen xPON patches from
   `openwrt/pon/patches-6.18/` to the kernel series **and** applies
   `openwrt/pon/buildroot-patches/0006` and `0007`. Nine of the sixteen patch
   `net/xpon/**`, `airoha_xpon.[ch]`, `phy-airoha-xpon.c` and `airoha_gpon_omci.c`,
   which come from the community `airoha_en7523_all` branch and are **not** in this
   repository, so the flag is only useful in a tree that has them; without them the
   kernel stage stops at the first of the nine (`can't find file to patch`). The
   other seven are the `930-53`..`930-59` hooks: they edit upstream `Kconfig` and
   `Makefile` files, but `930-53` and `930-55` add `source
   "drivers/net/optical/Kconfig"` and `source "net/xpon/Kconfig"`, directories that
   exist only in that branch, so kconfig stops there twenty seconds into the
   kernel's configure step. 0006 and 0007 are what switch the kernel symbols on and
   declare the kmod packages, and between them the sixteen kernel patches and those
   two buildroot patches are the reason the default series sets no `CONFIG_XPON`,
   `CONFIG_XPON_OMCI`, `CONFIG_XPON_OAM`, `CONFIG_PHY_AIROHA_XPON`,
   `CONFIG_AIROHA_XPON_V1` or `CONFIG_OPTICAL_FRONTEND` at all: an M2 image carries
   no optical and no xPON code, and `build-firmware.sh` refuses to start if any of
   those six symbols is set without the flag. The default series is 22 patches --
   `100`, `110`, `202-29`, `202-30`, `610-42x6`, `930-42`..`930-52` and
   `940-01`..`940-06` -- and every one of them touches a file that exists upstream,
   which is what a release image is built from.

It refuses to run if the tree is not at the pinned revision, and each patch is
checked with `--reverse --check` before it is applied, so a run that failed halfway
can be resumed. It is **not** idempotent in general, and the earlier claim here that
it was cost two debugging sessions: once a later patch has changed the same region
as an earlier one -- 0003, 0005 and 0007 all write into `config-6.18` and
`modules.mk` -- the earlier patch can be neither applied nor reverse-applied, and
the script stops with

```
!! cannot apply 0003-target-airoha-en7523-enable-board-kernel-options.patch
   Neither a clean apply nor an already-applied state was detected.
```

That is not a drifted patch: it is an already-applied one whose context a later
patch has since rewritten. Start from a clean tree, or restore one with
`git checkout -- . && git clean -fd -- target package` in the OpenWrt tree.

**After changing anything under `package/kernel/mt76/patches/`, clean that
package.** Package patches are applied in the *prepare* step, so an incremental
build reuses the previous build directory and silently ignores a new or edited
patch:

```bash
make package/kernel/mt76/clean && make package/kernel/mt76/compile
```

The same applies when you re-run `apply-overlay.sh` after editing an LED patch.

**A patch that is already in the tree is never removed.** Step 2 only adds and
overwrites files, so a patch applied by hand into
`target/linux/airoha/patches-6.18/` stays there and is re-applied by every later
build. `apply-overlay.sh` therefore ends by listing any patch in that directory
that this repo does not ship, and the list is worth reading: a leftover trace
patch is exactly how 21 consecutive images came to print 122 lines of
`AIROHA-TRACE` on every boot while the source tree looked clean. Removing it
changes the kernel and nothing else -- the squashfs region of that rebuild was
byte-identical to the previous image, and the unpacked Image size stayed at
13,158,560 bytes.

---

## 3. Kernel options: what is mandatory, and where it lives

Three mandatory groups, spread over two different config files. Mixing them up is
the usual reason a build finishes and then boots an image with no `/dev/mtd*`.

| Config file | Symbols | Why |
|---|---|---|
| `target/linux/airoha/en7523/config-6.18` (the target kernel config, added by `openwrt/patches/0003-*.patch`) | `CONFIG_MTD_BLOCK=y`, `CONFIG_MTD_CMDLINE_PARTS=y`, `CONFIG_SQUASHFS_XZ=y`, `CONFIG_JFFS2_FS=y` | `mtdblockN` is what the read-only squashfs root (`mtd5`) is mounted from, and `CONFIG_MTD_SPLIT_*` + `CONFIG_MTD_CMDLINE_PARTS` are what let the kernel split the FIT into `kernel`/`rootfs`/`rootfs_data`. The writable overlay is a UBIFS volume on the `data` partition (`mtd7`), not JFFS2 -- see [sysupgrade.md](sysupgrade.md) |
| the same file | `CONFIG_NET_DSA=y`, `CONFIG_NET_DSA_TAG_MTK=y`, `CONFIG_NET_DSA_MT7530=y`, `CONFIG_NET_DSA_MT7530_MMIO=y`, `CONFIG_MEDIATEK_GE_SOC_PHY=y` | the four GbE ports hang off an internal MT7530 switch, and this board has no MDIO bus, so it is driven in MMIO mode. See [ethernet.md](ethernet.md) |
| the OpenWrt `.config` (seeded by [`scripts/build-firmware.sh`](../scripts/build-firmware.sh)) | `CONFIG_KERNEL_DEVTMPFS=y` and `CONFIG_KERNEL_DEVTMPFS_MOUNT=y` | populates `/dev` at boot. Without it, neither `/dev/mtdN` nor `/dev/mtdblockN` appears, no matter what the kernel config says |

### `CONFIG_MTD_CHAR` is a dead symbol on 6.18

There is no `config MTD_CHAR` in `drivers/mtd/Kconfig` any more: `mtdchar.o` is
part of `mtd-y`, so the char devices follow `CONFIG_MTD` unconditionally. Writing
`CONFIG_MTD_CHAR=y` therefore does nothing at all -- kconfig drops the line
silently and the resolved `.config` has no `MTD_CHAR` in it. The real reason a
default image has no `/dev/mtd*` is that OpenWrt leaves devtmpfs off. Both parts
of the fix are needed: `MTD_BLOCK` in the target kernel config **and** devtmpfs in
`.config`. More: [sysupgrade.md](sysupgrade.md).

### Prompted symbols with no default must be answered

The kernel's `syncconfig` step asks about any symbol that has a prompt and no
default value. In a non-interactive build there is nobody to answer, so it stops
with `Error 1` before it has compiled anything. Pin a value for each of them:

```
# CONFIG_NET_DSA_MT7530_MDIO is not set
# CONFIG_PCS_AIROHA_EN7523 is not set
# CONFIG_LD_DEAD_CODE_DATA_ELIMINATION is not set
# CONFIG_AIROHA_THERMAL is not set
# CONFIG_PHY_AIROHA_AN7583_PCIE is not set
# CONFIG_PHY_AIROHA_USB is not set
# CONFIG_PHY_AIROHA_AN7583_USB is not set
```

Two of these are worth understanding rather than copying:

* `CONFIG_NET_DSA_MT7530` *implies* `CONFIG_NET_DSA_MT7530_MDIO`, so enabling the
  switch creates a new question that would otherwise be asked interactively.
* `CONFIG_PCS_AIROHA_EN7523` is added by the EN7523 PCS patches. This board only
  uses the internal GDM1 port, whose `phy-mode` is `internal`, and the driver
  looks up no PCS phandle, so the PCS layer stays off -- which is also what keeps
  the optical stack out of a working router image.

---

## 4. Packages: kernel modules have to be baked in

`airoha/en7523` is `FEATURES:=source-only`, so OpenWrt publishes no `kmods/`
directory for it. Everything the image needs in the way of kernel modules --
including `kmod-mt7915e` and its firmware blobs -- has to be selected at build
time. That is also why the Image Builder has to be produced with
`CONFIG_IB_STANDALONE=y` (the build script does this): the packages it can resolve
are the ones inside the tarball, `kmod-*` included.

Userspace packages are a different case. They depend on the CPU/ABI rather than
on the kernel, so the generic `arm_cortex-a7` feeds serve this board
normally, and a kernel module can also be added after the fact from the
per-release repository described in [`packages.md`](packages.md) -- as long as it
was built for the kernel the board is running.

Two consequences:

* **`CONFIG_PACKAGE_foo=m` is not enough.** In OpenWrt, `=m` *builds* a package
  but does not install it into the image. Anything you actually want on the
  device has to be `=y`. This has already cost this project one wasted image.
* **A base set is needed before the board is a router at all.** The Wi-Fi driver
  and firmware are not enough for an AP: with no `wpad` flavour selected there is
  no `/usr/sbin/hostapd`, `/etc/init.d/wpad` starts "successfully" and does
  nothing, and no AP interface ever appears. The set used here is listed in
  [`imagebuilder/packages.txt`](../imagebuilder/packages.txt):

  | Purpose | Symbols |
  |---|---|
  | AP | `wpad-mbedtls`, `hostapd-utils`, `iw`, `iwinfo`, `wireless-regdb` |
  | web UI | `luci`, `luci-ssl`, `uhttpd`, `uhttpd-mod-ubus` |
  | package manager | `apk-mbedtls` (OpenWrt main uses apk, not opkg) |
  | throughput testing | `iperf3` |

  `wpad-mbedtls` is the full build (hostapd + wpa_supplicant, WPA3/SAE,
  802.11k/v/r, mesh) rather than `wpad-basic-mbedtls`; it costs a few hundred KB
  of squashfs and buys the ability to test STA and mesh modes later.

After `make defconfig`, read the result back for the lines you care about.
Defconfig silently drops a symbol whose dependencies are not met, so a line you
seeded can be a line you do not get.

---

## 5. Build

The convenience script seeds `.config`, runs `make defconfig`, and builds:

```bash
./scripts/build-firmware.sh /path/to/openwrt --initramfs
```

Useful flags:

| Flag | Effect |
|---|---|
| `--initramfs` | also emit `*-initramfs-kernel.bin` (the RAM-boot image); this is the default |
| `--no-initramfs` | skip it -- use this when you only want the persistent image, see the warning below |
| `--variant m2` | seed `scripts/packages-m2.append`: Ethernet, Wi-Fi, LuCI and apk, with no optical/xPON/OMCI -- and, since the `930-53`..`930-59` hooks and `0006`/`0007` left the default series, no `CONFIG_XPON*` or `CONFIG_OPTICAL_FRONTEND` symbol either, so the kernel is not asked for sources that are not here. This is the shape of a release image. |
| `--variant full` | seed `scripts/packages.append`: the same plus the optical frontend and the xPON/OMCI stack, which need the per-unit BOB blob -- and, because those kmod packages are declared by `0006`/`0007`, `--with-pon` as well; without it the seed dies at the post-defconfig gate. This is the default. |
| `--packages FILE` | seed `FILE` instead of either list |
| `--debug-kmods` | install `kmod-pciedbg` and `kmod-ringwatch` into the image |
| `--kmods SPEC` | how many kernel modules to build and publish: `image` (default) is only what the image carries, `all` sets `CONFIG_ALL_KMODS=y` and selects every module this kernel config can build, and a comma-separated list selects those packages. Either way the modules are selected as `=m`, so they are packaged and published but **not** installed into the image. A plain M2 build selects 46 modules and no `kmod-wireguard`; a fresh `--kmods all` configuration selects 1110 (MEASURED, run `39219228917`). On a tree that an earlier build already configured the flag has **no effect**, because `defconfig` keeps the values the `.config` it reads carries -- the script counts the selection after `defconfig` and stops with `rm -f <tree>/.config` rather than building a narrow archive. See [packages.md](packages.md). |
| `--no-packages` | seed no package list at all into `.config` |
| `--no-feeds` | do not run `./scripts/feeds update -a` / `install -a` first |
| `--with-pon` | also add the sixteen kernel patches from `openwrt/pon/patches-6.18/` (the `930-53`..`930-60` hooks and `950-01`..`950-08`) and `0006`/`0007` from `openwrt/pon/buildroot-patches/`, all of which need the community xPON sources as well (not in this repository); without it no `CONFIG_XPON*` or `CONFIG_OPTICAL_FRONTEND` symbol is set at all |
| `--mt76-debug` | also apply the diagnostic mt76 ring patch (never ship it) |
| `--imagebuilder` | also produce the Image Builder tarball |
| `--no-apply` | skip step 2, if the overlay is already in the tree |
| `-j N` | build parallelism; `-jN` and `--jobs=N` work too, as with `make` |

### Feeds are fetched for you, and they float

A fresh clone of OpenWrt has no `feeds/` directory at all, and everything this
board wants beyond the bare system -- LuCI, the AP daemon, `iperf3`, `i2c-tools`
-- comes from one. Before feeds are installed, `make defconfig` drops
`CONFIG_PACKAGE_luci` without a word and the image is built with no web UI; on
this board's own tree the state was measurably worse than that: `feeds/` held
only `base`, `grep -E '^CONFIG_FEED_' .config` was empty, and `feeds/luci` did
not exist, so LuCI could not be enabled at all `[hardware]`.

The script therefore runs `./scripts/feeds update -a` and `./scripts/feeds
install -a` when `feeds/luci` is missing, and prints the revision each feed
resolved to. **Those revisions are not pinned by `scripts/pin.env`** -- the feeds
follow their own branch heads, so a rebuild months later gets newer feed packages
against the same kernel and the same patches. When the luci feed was last checked
it sat 3 days ahead of the pinned tree (`0257cc05`, 2026-10-05, against
`9b95be9`, 2026-10-02), which was judged acceptable; a rebuild that behaves
differently from the one described here should start by comparing those lines.
Pass `--no-feeds` only when you have installed feeds yourself and mean to keep
them.

The script verifies after `make defconfig` that every symbol it seeded is still in
`.config`, and refuses to build if one was dropped -- `defconfig` discards a symbol
whose dependencies are missing, which is how an image ends up with no AP daemon
and no web UI while the build reports success.

### The initramfs flag also inflates the persistent image

With `CONFIG_TARGET_ROOTFS_INITRAMFS=y` (the default), the kernel can end up with
the initramfs cpio embedded in it, and `*-sysupgrade.bin` inherits that kernel:
**MEASURED 14,418,209 B with the squashfs at `0x880000`**, against 9,437,473 B with
the squashfs at `0x3A0000` for a clean build (a second instance of the same bug was
12,058,913 B at `0x760000`, with `Image` and `Image-initramfs` sharing an md5).
The build succeeds either way, which is what makes the mistake silent: an inflated
kernel means a larger derived kernel partition, so the split still mounts -- the
damage is a needlessly huge image whose kernel boots its own embedded rootfs rather
than the flash rootfs, so nothing would persist `[not verified]`.

Three things now stand between you and that image:

* `--no-initramfs` does not merely omit the symbol, it writes
  `# CONFIG_TARGET_ROOTFS_INITRAMFS is not set`, and the check after `make
  defconfig` verifies it stayed that way. Omitting it was not enough: a `=y` left
  behind by an earlier build survives `defconfig`, and that is how the 12 MB image
  above was produced.
* `build-imagebuilder.sh` always appends `--no-initramfs` last, so the kernel the
  Image Builder bundles is the plain one -- every image it produces would otherwise
  inherit an embedded initramfs.
* [`tools/verify_image.py`](../tools/verify_image.py) validates the squashfs
  superblock of every sysupgrade image and reports an offset that shows an inflated
  kernel. `build-firmware.sh` calls it in warn-only mode (a `--initramfs` build
  legitimately produces one) and CI calls it as a hard gate, so such an image is
  never published.

Build with `--no-initramfs` when you only want the persistent image, and check with
[sysupgrade.md](sysupgrade.md), "verify a build before flashing it".

The whole image also has to stay inside slot B, **`0x2800000` (41,943,040 bytes)**,
and nothing enforces that at build time: the device profile sets no `IMAGE_SIZE`, so
an image that outgrows the slot is truncated at flash time instead of being refused.
Current images are 9,437,473 bytes, so there is plenty of room -- but a package set
that quadruples it would fail quietly. Setting `IMAGE_SIZE := 0x2800000` fixes that
and needs one build to confirm `[not verified]`.

**Then stop building from source.** The Image Builder produced here carries the
already-patched kernel and the whole package set, which is what you want for
every image after the first; it is the recommended path for day-to-day work. See
[image-builder.md](image-builder.md).

If you would rather drive the build yourself, the parts that matter are the
target selection, the devtmpfs options from section 3, and the packages from
section 4:

```bash
cd /path/to/openwrt
cat >> .config <<'EOF'
CONFIG_TARGET_airoha=y
CONFIG_TARGET_airoha_en7523=y
CONFIG_TARGET_airoha_en7523_DEVICE_econet_vgp-42x6v1=y
# deliberately not here: CONFIG_TARGET_ROOTFS_INITRAMFS=y is what --initramfs
# adds, and it is what inflates the persistent image -- see above
CONFIG_KERNEL_DEVTMPFS=y
CONFIG_KERNEL_DEVTMPFS_MOUNT=y
CONFIG_PACKAGE_wpad-mbedtls=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-ssl=y
EOF
make defconfig
make -j"$(nproc)"
```

---

## 6. Know what you produced

Artifacts land in `bin/targets/airoha/en7523/`.

| Artifact | What it is for |
|---|---|
| `*-initramfs-kernel.bin` | Loaded into RAM over UART/YMODEM. Writes nothing to flash, so it is the safe way to try a build. |
| `*-sysupgrade.bin` | The persistent image. Belongs in slot B, `mtd3` (`tclinux_slave`), and is written by `sysupgrade` -- never with `dd`. See [sysupgrade.md](sysupgrade.md). |
| `openwrt-imagebuilder-*.tar.zst` | Only with `--imagebuilder`. See [image-builder.md](image-builder.md). |

Always verify before flashing:

```bash
python3 tools/verify_build.py bin/targets/airoha/en7523/*-initramfs-kernel.bin
```

It checks that the FIT load/entry address is `0x80208000`. Getting that wrong
produces a kernel that deadloops before it can print, so the only symptom is a
completely silent UART. See [booting.md](booting.md).

It also prints `Image unpacked:`, which is the other half of the check: a plain
kernel unpacks to 13,158,560 bytes, and a kernel carrying an initramfs unpacks to
25,741,472. The second number means the build mixed the two kernel variants, the
persistent image is nearly twice the necessary size, and the image must not be
flashed -- see [sysupgrade.md](sysupgrade.md).

The same run counts `AIROHA-TRACE` breadcrumbs inside the unpacked kernel, and that
count is the only cheap way to see them. They live in the lzma-compressed Image, so
`grep` over the image file reports a clean build while the kernel goes on narrating
every boot: the archived builds from the tracing session onward all carry 103 of
them and print 122 lines, and a string scan over the files said zero. A count above
zero means an instrumented `airoha_eth.c` went into the build; rebuild without it
before shipping.

To confirm that the device tree in this repository is the one that was actually
compiled into an image:

```bash
python3 tools/dts_vs_image.py bin/targets/airoha/en7523/*-sysupgrade.bin \
    openwrt/overlay/target/linux/airoha/dts/en7523-vgp42x6v1.dts \
    <openwrt>/target/linux/airoha/dts/en7523.dtsi
```

It parses the DTB out of the FIT without `dtc` and compares every node and
property the `.dts` declares, cell by cell (macro-valued cells such as
`GPIO_ACTIVE_LOW` are wildcards because the binding headers are not available to
it). The `.dtsi` argument is only needed to resolve `&label` to a node path; it
comes from the OpenWrt tree, so pass the same revision you built against.
Expected output on an unmodified pair: every node and property present, and
exactly one difference, `mac-address`, because this repository ships a
placeholder instead of the per-unit address. Anything else -- a missing node, a
missing property, a different GPIO number, a phandle pointing at the wrong
label -- means the `.dts` and the image have drifted apart.

---

## 7. Bumping the pinned revision

When you move to a newer OpenWrt:

```bash
cd /path/to/openwrt
git fetch && git checkout <new-revision>
cd -
./scripts/make-patches.py export /path/to/openwrt /tmp/pristine
./scripts/make-patches.py generate /tmp/pristine
```

Then update `OPENWRT_COMMIT`, `OPENWRT_COMMIT_DATE` and `OPENWRT_DESCRIBE` in
`scripts/pin.env`, and re-run `apply-overlay.sh` against a clean tree to confirm
the series still applies.

To check that without a build tree at all:

```bash
tools/check_patches_apply.py
```

It fetches every file the series touches at the pinned revision from
`raw.githubusercontent.com`, replays `git apply` in the same order
`apply-overlay.sh` uses, and stops at the first patch git refuses. The lint
workflow runs it on every push, which is worth the ~10 seconds: a series can pass
`tools/check_patches.py` (well-formed hunks, correct counts) and still not apply,
because a patch written in a tree that had already drifted carries that tree's line
numbers and block positions, not only its text. Patch 0006 was exactly that -- its
context lines were present in a clean tree and `git apply` refused it anyway -- and
the first CI run paid for it by failing 20 seconds in, with no detail in the log
because the build script suppresses git's stderr.

Patches 0001-0004 are generated by `scripts/make-patches.py generate`; 0005, 0006
and 0007 are written by hand, so when you edit one of those, check it before
pushing -- with the tool above for 0005, which is in `openwrt/patches/`, and with a
`--with-pon` run against a scratch tree for 0006 and 0007, which now live in
`openwrt/pon/buildroot-patches/` and are outside what that check replays.

To regenerate one of those three, do not edit the patch file: edit the tree. Copy
the pin, apply the series up to the patch *before* the one you are changing, make
the change there, and let `git diff` write the hunk:

```bash
git clone --depth 1 --branch <pin> https://github.com/openwrt/openwrt.git /tmp/pin
cd /tmp/pin && git checkout -b work
for p in /path/to/repo/openwrt/patches/000{1..5}-*.patch; do git apply "$p"; done
git add -A && git commit -qm "patches 0001-0005"
$EDITOR target/linux/airoha/en7523/config-6.18
git diff -- target/linux/airoha/en7523/config-6.18 target/linux/airoha/modules.mk
```

That order matters more than it looks. A hunk written by hand carries the line
numbers and block positions of the tree it was written in, and those can stop
matching without a single character of the patch being wrong: patch 0006 inserted
its lines at the end of a context block that, in a clean tree, is the *middle* of
the I2C comment block from 0003, and `git apply` refused it -- as did GNU `patch
-F0` -- while every context line it searched for was present, byte for byte, in the
file. A diff taken in the tree it has to apply to cannot have that problem, and
`tools/check_patches_apply.py` will say so either way.

`make-patches.py generate` fails loudly rather than producing a broken patch: it
asserts that each anchor string it edits occurs exactly the expected number of
times. If upstream renamed the firmware lines in the mt76 package, or already
fixed the load address, you get an error telling you which assumption broke --
which is what you want, instead of a patch that applies with fuzz and quietly
does the wrong thing.

The adopted EN7523 series (`930-42`..`930-51`) is the part most likely to need
attention on a bump: `930-45` alone is ~3000 lines of `airoha_eth.c`/`airoha_ppe.c`
changes, and it was regenerated with `diff -Naur` for this tree rather than taken
verbatim from the community branch.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `apply-overlay.sh` refuses: "OpenWrt tree is at ..." | The checkout is not at the pinned revision. Check out the pin, or regenerate the series. |
| A patch neither applies nor reverse-applies | Upstream changed the surrounding lines. Regenerate the series (section 7). |
| `syncconfig` fails with `Error 1` | A prompted kernel symbol has no default and the config does not name a value. Add the `# CONFIG_... is not set` lines from section 3. |
| The image boots but there is no `/dev/mtd*` | `CONFIG_KERNEL_DEVTMPFS` (and `_MOUNT`) missing from `.config`, or `CONFIG_MTD_BLOCK` missing from the target kernel config. Both are required; see section 3. |
| A change to an mt76 patch has no effect | The patch is applied in the prepare step. Run `make package/kernel/mt76/clean` and rebuild (section 2). |
| Wi-Fi driver and firmware are in the image, but no AP interface appears | No `wpad` flavour selected, so nothing calls `nl80211`. See section 4. |
| `cp: cannot stat ...` from a script | Run the scripts by path, not from another directory. The scripts resolve their own location, but the working directory still has to be somewhere sensible. |
| Scripts fail with `$'\r': command not found` | The checkout got CRLF line endings. `.gitattributes` forces LF, so this only happens if the files were copied outside git. Re-clone, or convert with `dos2unix`. |
| The build succeeds but the UART is silent | Almost always the `TEXT_OFFSET` / `loadaddr` mismatch. Verify the image, then read [booting.md](booting.md). |
| `make defconfig` drops `CONFIG_IB` | It depends on `!EXTERNAL_TOOLCHAIN`. Use the internal toolchain. |
| The tools stage fails while configuring `tar` | Building as root in a container: export `FORCE_UNSAFE_CONFIGURE=1`. |
