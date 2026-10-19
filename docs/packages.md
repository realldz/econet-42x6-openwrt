# Prebuilt images and the apk package repository

Two different questions live in this document, and confusing them is the usual
reason somebody spends an afternoon on `invalid module format`:

* **Can I install a userspace package?** Yes, from OpenWrt's own generic
  `arm_cortex-a7` feeds. Measured on the board: a new userspace package
  installs, and the board still boots with SSH reachable.
  The arch string is worth stating because this document said
  `aarch64_cortex-a53` for a while: the `en7523` subtarget declares
  `CPU_TYPE:=cortex-a7` and the target builds 32-bit (`CONFIG_ARCH="arm"`), so the
  configuration seeded here resolves to `CONFIG_TARGET_ARCH_PACKAGES="arm_cortex-a7"`
  -- the kernel build directory is literally `target-arm_cortex-a7_musl_eabi` --
  and the board's own feed list in [wifi.md](wifi.md) section 4 names the same.
  `aarch64_cortex-a53` is a different architecture: apk refuses those packages
  here, the two are not interchangeable.
* **Can I install a kernel module?** Not from OpenWrt. This is the half the
  repository published by this project exists for.

## Why kernel modules are the problem

The `en7523` subtarget declares `FEATURES:=source-only`. OpenWrt's builders use
that to decide not to produce a `kmods/` directory for it, and kernel modules are
published per target *and per kernel build*:

```
bin/targets/<target>/<subtarget>/kmods/<kernel>-<hash>/packages.adb
```

No such directory exists for a target nobody builds images for. Userspace
packages do not have that constraint -- they depend on the CPU/ABI, not on the
kernel -- which is why the generic feeds work here and `kmod-*` does not.

The consequence, before this repository existed: every `kmod-*` an image wanted
had to be baked in at build time. That is still the rule for whatever the image
ships with (`scripts/packages.append`, `scripts/packages-m2.append`); what changes
is that a module can now also be added to a **running** board, as long as it is
built for the kernel that board is running.

## Which modules a release publishes

An archive holds the modules a build *selected*, which is not the same as the
modules that could exist -- and that gap is a trap this project walked into once.
A release built without `--kmods` selects only what the image itself needs:
MEASURED on v0.1.0-m2, 46 kernel modules among the 57 packages in
`bin/targets/airoha/en7523/packages/`, and `kmod-wireguard` is not one of them,
because nothing in the M2 package list needs it. Installing it from that archive is
a 404 -- from a repository that was built exactly as asked, which is what makes it
worth writing down.

`scripts/build-firmware.sh` takes the selection:

| flag | what it selects |
|---|---|
| `--kmods image` | only what the image itself carries (the default) |
| `--kmods all` | every kernel module this kernel config can build, minus `--kmods-exclude` |
| `--kmods a,b,c` | those packages, selected as `=m` |
| `--kmods-exclude a,b` | with `--kmods all`: keep these off (default: `kmod-ipt-rtpengine`) |

`--kmods all` sets `CONFIG_ALL_KMODS=y`, and that is the whole mechanism: every
non-hidden `kmod-*` package then defaults to `=m` (`config/Config-build.in:42`
declares the symbol; `scripts/package-metadata.pl:371-383` gives each generated
package `default m if ALL||ALL_NONSHARED||ALL_KMODS`). For a package symbol `=m`
means "build and package it", not "build it into the kernel" -- so the module is
compiled and published, and it is **not** added to the image. That distinction is
the point: the persistent image has only `0x3A0000` of mtd4 to fit in, and a module
somebody installs later belongs in the archive rather than in the flash image.

MEASURED on a fresh configuration, run `39219228917`: `CONFIG_ALL_KMODS=y` leaves
45 kmod packages `=y` -- the target's own, which is what the image carries -- and
1110 `=m`, every one of them built and published. Under `--variant m2`, whose
package list carries one module the bare target does not, the release run
`39219693393` printed `46 kernel module(s) =y (in the image), 1149 =m (built and
published)`, and that build then failed in a feed package the archive never needed
-- see "Feed kernel modules" below. That is the shape of the archive a release is
meant to serve: the image unchanged, the archive wider by an order of magnitude.

### `--kmods all` does nothing on a tree that is already configured

`make defconfig` keeps the values the `.config` it reads already carries, and
applies a default only to symbols it has not seen. The `.config` an earlier build
wrote is full of them: every module that run did not want is in there as
`# CONFIG_PACKAGE_kmod-x is not set`, which is a value. Seeding
`CONFIG_ALL_KMODS=y` into that file and running `defconfig` again therefore leaves
the flag in place, every module still off, and the archive as narrow as it was.
MEASURED, run `39218437654`, which ran the build script twice in one job: 45 kmod
packages `=y`, **0 `=m`**, `kmod-wireguard` not set -- with the flag visibly
present and the post-defconfig seed gate green, which is what makes this worth a
section of its own.

`scripts/build-firmware.sh` therefore counts the effect after `defconfig` instead
of trusting the flag: `--kmods all` must leave at least `KMODS_ALL_MIN` (100 by
default) modules selected `=m`, and every name passed to `--kmods a,b,c` must come
out `=y` or `=m`. Either check failing stops the build, prints the counts, and
names the fix:

```
rm -f <tree>/.config
```

### Feed kernel modules, and the one that does not build here

`CONFIG_ALL_KMODS=y` does not distinguish where a module is declared, so it also
selects the kernel modules that live inside the *feeds* -- and a feed package
directory is not a module. `feeds/telephony/net/rtpengine` declares
`kmod-ipt-rtpengine` next to telephony daemons this board has no use for, and
selecting the module puts the whole directory into `make world`. Run `39219693393`
died there, fifty minutes into the sysupgrade build:

```
make[3] -C feeds/telephony/net/rtpengine compile
    ERROR: package/feeds/telephony/rtpengine failed to build (build variant: no-transcode).
```

The selection itself was right -- the effect check had printed `46 kernel
module(s) =y (in the image), 1149 =m (built and published)` -- and the reason the
directory failed is still unknown (the report re-ran it the wrong way, trap 14 in
[ci.md](ci.md)). None of that matters for the release: the package is a telephony
daemon, the module is not one a board user asks for, and it was only ever in the
build because a module happened to share its directory.

`--kmods-exclude` names such packages, and `--kmods all` writes them as
`# CONFIG_PACKAGE_<name> is not set` before `make defconfig`. That works for the
same reason the reuse trap above is a trap: kconfig keeps a value the `.config`
already carries, so an exclusion that is written down stays written down. The
default list holds exactly one name, `kmod-ipt-rtpengine`, because that is the one
that has been *measured* to fail here. The list is not a judgement about which
modules a router needs, and not a guess about which feeds are risky: excluding a
module the board could have used is a real loss, so a name is added to it only
after a run failed on it. `--kmods-exclude ""` selects everything `ALL_KMODS`
reaches, which is how that failure was measured -- do not ship it.

The check after `defconfig` refuses a selection that kept an excluded package on,
because the exclusion is written into a file the tree rewrites: if a future
`defconfig` does not keep it, the module comes back, the directory comes back, and
the release fails in a telephony daemon rather than saying why.

Two consequences of that mechanism are worth knowing before touching it:

* The module's kernel symbol does **not** have to be listed in
  `target/linux/airoha/en7523/config-6.18` to make the module build. Selecting the
  package is enough: `scripts/package-metadata.pl:83-85` writes the symbol into
  `<build_dir>/target-*/linux-*/linux-*/.config.override`, and
  `include/kernel-defaults.mk:123-124` merges that over the target config --
  including over an explicit `# CONFIG_WIREGUARD is not set` in
  `target/linux/generic/config-6.18:8241`. Adding the symbol to the target config
  would be a second, redundant copy that can drift.
* That merge happens during `make target/linux/compile`, **not** during
  `target/linux/prepare`, so a tree that has only been through prepare has no
  kernel `.config` at all. `tools/check_kmods.py --require-override` treats that as
  a usage error instead of passing for lack of evidence.

Adding a module to an image is a rebuild of the kernel, not an edit to the
published archive -- a module only loads into the kernel it was built against, so
the whole image has to be rebuilt with it selected:

```sh
./scripts/build-firmware.sh openwrt --variant m2 --kmods kmod-wireguard,kmod-udptunnel4
```

`release.yml` builds its sysupgrade job with `--kmods all` by default (the `kmods`
input takes `all`, `image` or a list) and passes `image` to the initramfs job, which
publishes no archive; the exclusions above apply to both, since the list is the
script's default rather than something a workflow passes. Two checks keep a release from publishing an archive that
404s: `kernel-patches.yml` runs `--kmods all` plus
`tools/check_kmods.py --require-all-kmods --require-package kmod-wireguard
--min-kmods 1000` in about two minutes, and `build.yml` checks after the publisher that
`pages/` really contains the modules the run promised -- before anything is pushed
to `gh-pages`.

## What is published, and where

| | |
|---|---|
| Images, Image Builder, SHA256SUMS | [GitHub Releases](https://github.com/realldz/econet-42x6-openwrt/releases), built and verified by CI |
| Kernel modules | the `gh-pages` branch, one directory per release tag |
| Userspace feeds | the same branch, only when a release was built with feeds enabled |

The branch looks like this:

```
<tag>/kmods/<kernel>-<hash>/packages.adb
<tag>/kmods/<kernel>-<hash>/*.apk
<tag>/packages/<arch>/<feed>/packages.adb      (only with feeds enabled)
<tag>/metadata.json                            which images these belong to
<tag>/install.md                               the commands, with the real path
releases.json                                  every published release
index.html                                     landing page
```

`<tag>` is the release tag, so the URL is versioned on purpose: a kernel module
only loads into the kernel it was built against.

## Installing a module

The exact directory name for a release is written in its release notes and in
`<tag>/install.md` -- do not guess it.

```sh
# Point apk at the repository for the release whose image the board is running.
echo 'https://realldz.github.io/econet-42x6-openwrt/<tag>/kmods/<kernel>' \
  > /etc/apk/repositories.d/42x6-kmods.list

apk update --allow-untrusted
apk search --allow-untrusted
apk add --allow-untrusted <package>
```

`uname -r` reports the kernel release the board runs, and on this image
`/lib/modules/` is `6.18.54`, so `uname -r` is `6.18.54`; the directory name
starts with that and the rest identifies the build. If they do not match, the
module is refused at load time rather than at install time.

### Proving it on the board

Two things can be wrong independently -- the repository may be unreachable, or the
module may not belong to the kernel the board is running -- and they fail
differently, so check them in that order:

```sh
uname -r                                     # must match the directory in the URL
apk list --installed | grep '^kmod-'         # what the image already carries

apk update --allow-untrusted                 # reachability and index, before installing
apk search --allow-untrusted | head

apk add --allow-untrusted kmod-<name>        # something the image does not carry
modprobe <name> && dmesg | tail
```

A module built for a different kernel installs and then refuses to load:

```
insmod: ERROR: could not insert module ...: Invalid module format
```

That is the expected result of pointing a board at the wrong release tag, and it is
the tag in the URL doing its job rather than a broken repository. It is also why
the modules are fetched *per release* instead of from one shared directory.

### If GitHub Pages is not enabled

apk does not need a web server, only a URL that serves the index, so the branch
is usable through the raw host:

```sh
echo 'https://raw.githubusercontent.com/realldz/econet-42x6-openwrt/gh-pages/<tag>/kmods/<kernel>' \
  > /etc/apk/repositories.d/42x6-kmods.list
```

### The packages are not signed

apk checks repository signatures; these are unsigned, which is what
`--allow-untrusted` switches off. The trust is therefore in TLS and in the
hosting, not in a key. That is a deliberate trade: signing would mean keeping a
private key in CI secrets for artifacts that are reproducible from the pinned
revision in [`scripts/pin.env`](../scripts/pin.env). If you would rather not
trust the download, build the module yourself against the same revision.

## What not to do

* **Do not run `apk upgrade`.** Measured: 12 installed packages in the snapshot
  are behind, one of them a `zlib` major-version change, which can break every
  binary linked against the older `zlib` -- including the SSH server you would
  need to repair it. Install one package at a time.
* **Do not point apk at another release's directory.** It resolves and downloads
  happily, then fails at load time with `invalid module format`, which names the
  module and not the mismatch.
* **Do not install a module built for another board**, even one with the same SoC
  and the same kernel version.

## Publishing a repository yourself, or from a fork

It is one script:

```bash
./scripts/publish-packages.sh openwrt --tag v0.2.0 --out pages [--with-feeds]
```

It *discovers* the layout of the finished build tree instead of assuming it. The
modules are looked for in `bin/targets/airoha/en7523/kmods/*/` first (the shape
OpenWrt's own builders publish) and then in `bin/targets/airoha/en7523/packages/`,
which is where a plain local build of this target leaves them: measured on a real
build of this board, that directory held 73 packages, among them
`kmod-xpon-6.18.54-r1.apk`. It refuses a tree with more than one *kernel* under it --
not a directory whose modules carry several version strings, which is what a single
build produces: the same measurement has 53 modules named `6.18.54`, 2 named
`6.18.54.7.2` and 5 named `6.18.54.2026.09.01~be5ce791`, all built together against
`6.18.54`. It also
refuses to write a half-filled release directory, publishes whichever directory it
chose *whole* -- the index beside those packages lists every one of them, so
copying a subset would publish an index pointing at files that are not there -- and
writes `metadata.json`, `install.md`, `releases.json` and `index.html` beside the
packages. `--with-feeds` is off by default because the kernel modules are a few
megabytes and the full userspace set is hundreds: publish what somebody needs.

`tools/test_publish_packages.sh` exercises the failure paths and the generated
layout against a fake build tree -- both layouts, `kmods/<kernel>/` and
`packages/` -- and `lint.yml` runs it on every push.

In CI, `release.yml` calls it in the job that produced the sysupgrade image, only
after that image passed `tools/verify_image.py`, and the `pages` job pushes the
result to `gh-pages`. The branch keeps every past release on purpose: somebody
running an older image still needs the modules built for its kernel.

## Verified, and not

* `[hardware]` Userspace packages install from the generic feeds; `apk add` works;
  `apk upgrade` breaks the userland.
* The image's own kernel modules are the same packages it was built with, so
  publishing them does not change what the image contains.
* **The archive is published and self-consistent, but nothing has been installed
  from it on a board yet.** `v0.1.0-m2` is live, and
  `tools/verify_publish.py` checks the release assets, the `gh-pages` branch and
  the served URLs (19 checks -- see [ci.md](ci.md)). That release published the 46
  modules it had selected, correctly, and no `kmod-wireguard` -- which is the gap
  `--kmods all` closes, and the reason the module list is now part of what a
  release promises rather than a side effect of the package list.
  What remains `[not verified]` on hardware is the install itself: `apk add
  --allow-untrusted <kmod>` against that URL, and the negative case, where a module
  from another tag installs and then refuses to load with `Invalid module format`
  (see above). The procedure in this document is what has to pass.
