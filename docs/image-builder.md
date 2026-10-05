# The Image Builder

You asked for images to be buildable with OpenWrt's Image Builder. This document
explains why the **upstream** one cannot do it for this board, and how this
project provides one that can.

---

## Why the upstream Image Builder cannot build this board

OpenWrt's Image Builder is a stripped-down buildroot that contains:

* a **precompiled kernel** and kernel modules,
* a `profiles.json` describing the devices the target knows about,
* a package repository,
* the image assembly tooling.

Its whole design is that you never compile the kernel. `make image` picks a
profile, installs packages, and assembles an image.

This board needs two **kernel patches**:

| Patch | What happens without it |
|---|---|
| `arch/arm` `TEXT_OFFSET` | the kernel deadloops in `head.S` before it can print; the UART is completely silent |
| the EN7523 root complex PCI fixup | the MT7916 can never DMA, and Wi-Fi times out with a misleading firmware error |

An Image Builder cannot apply either of those, and it cannot add a device profile
either, because profiles are compiled in. So no upstream Image Builder will ever
produce a working vGP-42X6V1 image until those changes land in
`openwrt/openwrt` itself -- which, for this project, is explicitly **not** a goal
(see [roadmap.md](roadmap.md), "Explicitly rejected for now").

## What this project does instead

Build the firmware from source **once**, with `CONFIG_IB=y`, and OpenWrt will
emit an Image Builder built from that same tree. Crucially, the tarball is
assembled from the **already-compiled kernel**:

```
cp $(KERNEL_BUILD_DIR)/* $(IB_KDIR)/          # the patched, built kernel
```

It also deletes the source patches from the copy it ships:

```
rm -rf $(PKG_BUILD_DIR)/target/linux/*/patches{,-*}
```

So the fixes are baked into the binary the Image Builder carries, rather than
being reapplied -- which is exactly what you want. Our device profile travels
too, in `profiles.json`.

Producer side:

```bash
./scripts/build-imagebuilder.sh /path/to/openwrt -j8
# -> copy of dist/openwrt-imagebuilder-airoha-en7523.*.tar.zst
```

The tarball name follows OpenWrt's own scheme:

```
openwrt-imagebuilder-airoha-en7523.Linux-x86_64.tar.zst
```

(`CONFIG_VERSION_FILENAMES` inserts the version number, so a snapshot build may
also produce `openwrt-imagebuilder-SNAPSHOT-airoha-en7523.*`. Always glob.)

---

## `CONFIG_IB_STANDALONE` is mandatory here

The Image Builder has two modes:

* **standalone** (`CONFIG_IB_STANDALONE=y`, the default for a non-buildbot
  build): the tarball carries **every** built package in its own `packages/`
  directory, and needs no network;
* **non-standalone**: the tarball carries only the toolchain, base-files, libc
  and kernel packages, and fetches everything else from
  `downloads.openwrt.org`.

Non-standalone would be much smaller, but it does not work for this board. The
`en7523` subtarget declares `FEATURES+=source-only`, and there are no official
package repositories for `airoha/en7523`. Kernel modules in particular are
published per target, so even `kmod-mt7915e` would be unresolvable.

Consequence: **the tarball is large**, because it contains the whole package
set. That is the price of a self-contained Image Builder, and it is why
`build-imagebuilder.sh` copies it to `dist/` with a `SHA256SUMS` entry rather
than asking you to commit it.

---

## Using it

```bash
tar --zstd -xf openwrt-imagebuilder-airoha-en7523.*.tar.zst
cd openwrt-imagebuilder-airoha-en7523.*

make image PROFILE=econet_vgp-42x6v1 PACKAGES="luci luci-ssl"
```

Or use the helper, which adds a curated package list and the first-boot overlay:

```bash
./imagebuilder/build-image.sh /path/to/openwrt-imagebuilder-*.tar.zst --all-packages
./imagebuilder/build-image.sh /path/to/openwrt-imagebuilder-*.tar.zst --debug-kmods
./imagebuilder/build-image.sh /path/to/openwrt-imagebuilder-*.tar.zst -P "luci luci-ssl htop"
```

| Option | Effect |
|---|---|
| `-p, --profile NAME` | device profile, default `econet_vgp-42x6v1` |
| `-P, --packages "a b c"` | extra packages |
| `--all-packages` | use [`imagebuilder/packages.txt`](../imagebuilder/packages.txt) |
| `--debug-kmods` | add `kmod-pciedbg` and `kmod-ringwatch` |
| `-o, --out DIR` | where to collect images, default `./dist` |
| `--keep` | keep the extracted Image Builder directory |

Images come out in `bin/targets/airoha/en7523/` inside the extracted tree, and
the helper copies them plus a `SHA256SUMS` into `--out`.

### The `files/` overlay

`imagebuilder/files/` is copied into the image root. Right now it contains one
first-boot script that sets the hostname and nothing else, deliberately:

* there is no Ethernet driver yet, so a static network config would be fiction;
* the Wi-Fi PHY numbering is not stable across boots (the logs show `phy#0` on
  one boot and `phy2`/`phy3` on another), so a static `/etc/config/wireless`
  would break.

Generate the wireless config at runtime instead:

```sh
wifi config
vi /etc/config/wireless
wifi up
```

### What an Image Builder cannot do

It cannot add a package that was not built, and it cannot change the kernel. If
you need either, go back to `build-firmware.sh` and rebuild from source.

---

## Always verify the output

```bash
python3 tools/verify_build.py dist/*-initramfs-kernel.bin
```

Confirms the FIT load/entry address is `0x80208000`. This check is not optional:
the failure mode of getting it wrong is a completely silent UART with no
diagnostic, which is expensive to debug. See [booting.md](booting.md).

---

## Publishing

`.github/workflows/build.yml` builds the firmware and the Image Builder and
attaches both to a GitHub release when a tag is pushed. When publishing, attach:

* the `*-initramfs-kernel.bin` and `*-sysupgrade.bin` images,
* the `openwrt-imagebuilder-airoha-en7523.*.tar.zst`,
* `SHA256SUMS` covering all of them.

Do not commit images or the tarball into git. They are build outputs.
