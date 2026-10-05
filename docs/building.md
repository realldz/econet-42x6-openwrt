# Building

How to get from a clean OpenWrt checkout to a flashable image, and how to keep
the patch series maintainable.

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

This does three things:

1. applies `openwrt/patches/*.patch` with `git apply` -- these are edits to
   **existing** upstream files, so they must be patches rather than file copies,
   otherwise bumping the pin would silently discard upstream changes;
2. copies `openwrt/overlay/.` verbatim into the tree -- these are **new** files
   (the board device tree and the diagnostic kernel modules);
3. optionally applies the stage 2 PON material with `--with-pon`.

It refuses to run if the tree is not at the pinned revision, and it is
idempotent: running it twice is safe. Re-running after a partial failure works
because each patch is checked with `--reverse --check` to see whether it is
already applied.

---

## 3. Build

The convenience script seeds `.config`, runs `make defconfig`, and builds:

```bash
./scripts/build-firmware.sh /path/to/openwrt --initramfs
```

Useful flags:

| Flag | Effect |
|---|---|
| `--initramfs` | also emit `*-initramfs-kernel.bin` (the RAM-boot image); this is the default |
| `--no-initramfs` | skip it |
| `--debug-kmods` | install `kmod-pciedbg` and `kmod-ringwatch` into the image |
| `--with-pon` | also apply the stage 2 PON patches (not functional yet) |
| `--imagebuilder` | also produce the Image Builder tarball |
| `--no-apply` | skip step 2, if the overlay is already in the tree |
| `-j N` | build parallelism |

If you would rather drive the build yourself, the only parts that matter are the
target selection and building:

```bash
cd /path/to/openwrt
cat >> .config <<'EOF'
CONFIG_TARGET_airoha=y
CONFIG_TARGET_airoha_en7523=y
CONFIG_TARGET_airoha_en7523_DEVICE_econet_vgp-42x6v1=y
CONFIG_TARGET_ROOTFS_INITRAMFS=y
EOF
make defconfig
make -j"$(nproc)"
```

**A trap worth knowing.** In OpenWrt, `CONFIG_PACKAGE_foo=m` *builds* a package
but does not install it into the image. Anything you actually want on the device
has to be `=y`. This has already caused one wasted image in this project.

---

## 4. Know what you produced

Artifacts land in `bin/targets/airoha/en7523/`.

| Artifact | What it is for |
|---|---|
| `*-initramfs-kernel.bin` | Loaded into RAM over UART/YMODEM. Writes nothing to flash, so it is the safe way to try a build. |
| `*-sysupgrade.bin` | The persistent image. Belongs in slot B, `mtd3` (`tclinux_slave`). |
| `openwrt-imagebuilder-*.tar.zst` | Only with `--imagebuilder`. See [image-builder.md](image-builder.md). |

Always verify before flashing:

```bash
python3 tools/verify_build.py bin/targets/airoha/en7523/*-initramfs-kernel.bin
```

It checks that the FIT load/entry address is `0x80208000`. Getting that wrong
produces a kernel that deadloops before it can print, so the only symptom is a
completely silent UART. See [booting.md](booting.md).

---

## 5. Bumping the pinned revision

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

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `apply-overlay.sh` refuses: "OpenWrt tree is at ..." | The checkout is not at the pinned revision. Check out the pin, or regenerate the series. |
| A patch neither applies nor reverse-applies | Upstream changed the surrounding lines. Regenerate the series (section 5). |
| `cp: cannot stat ...` from a script | Run the scripts by path, not from another directory. The scripts resolve their own location, but the working directory still has to be somewhere sensible. |
| Scripts fail with `$'\r': command not found` | The checkout got CRLF line endings. `.gitattributes` forces LF, so this only happens if the files were copied outside git. Re-clone, or convert with `dos2unix`. |
| The build succeeds but the UART is silent | Almost always the `TEXT_OFFSET` / `loadaddr` mismatch. Verify the image, then read [booting.md](booting.md). |
| `make defconfig` drops `CONFIG_IB` | It depends on `!EXTERNAL_TOOLCHAIN`. Use the internal toolchain. |
