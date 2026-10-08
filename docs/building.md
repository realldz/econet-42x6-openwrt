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
git clone https://github.com/openwrt/openwrt.git openwrt
git -C openwrt checkout 9b95be917b2804cf877ca05c078175b37a3a95bf
```

A shallow clone is not enough if you intend to regenerate the patch series,
because `make-patches.py export` reads files straight out of git:

```bash
git clone --filter=blob:none https://github.com/openwrt/openwrt.git openwrt
git -C openwrt checkout 9b95be917b2804cf877ca05c078175b37a3a95bf
```

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
4. optionally applies the stage 2 PON material with `--with-pon`.

It refuses to run if the tree is not at the pinned revision, and it is
idempotent: running it twice is safe. Re-running after a partial failure works
because each patch is checked with `--reverse --check` to see whether it is
already applied.

**After changing anything under `package/kernel/mt76/patches/`, clean that
package.** Package patches are applied in the *prepare* step, so an incremental
build reuses the previous build directory and silently ignores a new or edited
patch:

```bash
make package/kernel/mt76/clean && make package/kernel/mt76/compile
```

The same applies when you re-run `apply-overlay.sh` after editing an LED patch.

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

## 4. Packages: there is nothing to install from

`airoha/en7523` is `FEATURES:=source-only`, so there are no official package
repositories for it. Everything the image needs -- including `kmod-mt7915e` and
its firmware blobs -- has to be baked in at build time, and the Image Builder has
to be produced with `CONFIG_IB_STANDALONE=y` (the build script does this) so that
the packages it can resolve are the ones inside the tarball.

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
| `--debug-kmods` | install `kmod-pciedbg` and `kmod-ringwatch` into the image |
| `--no-packages` | do not seed `scripts/packages.append` into `.config` |
| `--with-pon` | also apply the stage 2 PON patches (not functional yet) |
| `--mt76-debug` | also apply the diagnostic mt76 ring patch (never ship it) |
| `--imagebuilder` | also produce the Image Builder tarball |
| `--no-apply` | skip step 2, if the overlay is already in the tree |
| `-j N` | build parallelism |

The script verifies after `make defconfig` that every symbol it seeded is still in
`.config`, and refuses to build if one was dropped -- `defconfig` discards a symbol
whose dependencies are missing, which is how an image ends up with no AP daemon
and no web UI while the build reports success.

### The initramfs flag also inflates the persistent image

With `CONFIG_TARGET_ROOTFS_INITRAMFS=y` (the default), the kernel can end up with
the initramfs cpio embedded in it, and `*-sysupgrade.bin` inherits that kernel:
**MEASURED 14,418,209 B with the squashfs at `0x880000`**, against 9,437,473 B with
the squashfs at `0x3A0000` for a clean build. The large image still boots, so the
mistake is silent -- and since this target sets no `IMAGE_SIZE`, an image that
outgrows slot B is truncated at flash time rather than refused at build time.
`build-firmware.sh` therefore prints the squashfs offset of every sysupgrade image
and warns when it looks like an initramfs kernel. Build with `--no-initramfs` when
you only want the persistent image, and check with
[sysupgrade.md](sysupgrade.md), "verify a build before flashing it".

The whole image also has to stay inside slot B, **`0x2800000` (41,943,040 bytes)**,
and nothing enforces that at build time yet: the device profile sets no
`IMAGE_SIZE`, so an image that outgrows the slot is truncated at flash time instead
of being refused. Current images are 9,437,473 bytes, so there is plenty of room --
but a package set that doubles it would fail quietly. Setting
`IMAGE_SIZE := 0x2800000` fixes that and needs one build to confirm.

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
CONFIG_TARGET_ROOTFS_INITRAMFS=y
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
