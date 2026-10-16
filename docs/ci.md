# CI/CD

Everything the project publishes is built on GitHub. No release asset is uploaded
by hand, and none of the checks below need an OpenWrt tree to run except the build
itself.

## What runs, and when

| Workflow | Trigger | Wall clock |
|---|---|---|
| [`lint.yml`](../.github/workflows/lint.yml) | every push, every pull request, manual | ~25 s |
| [`kernel-patches.yml`](../.github/workflows/kernel-patches.yml) | every push, every pull request, manual | ~3 min |
| [`build.yml`](../.github/workflows/build.yml) | `workflow_call` from `release.yml`, or manual: one variant, one kind of image | 2-2.5 h |
| [`release.yml`](../.github/workflows/release.yml) | a `v*` tag, or manual with the inputs below | resolve 5 s, then two builds in parallel, then release + `gh-pages` |

`build.yml` has no `push` trigger on purpose: it produces the artifacts, and
`release.yml` decides what they mean and whether they are published.

The runners are pinned to `ubuntu-24.04` rather than `ubuntu-latest`. GitHub
announced on 2026-10-14 that the `ubuntu-latest` label starts moving to Ubuntu 26
on 2026-10-19; a build here takes two and a half hours, and a host distribution
that silently changes the compiler or the autotools underneath it produces a
failure nobody would connect to the runner. The label change is then a deliberate
commit, not a surprise in the middle of a release.

## Why a release is two builds, not one

An image whose kernel carries the initramfs embedded cannot be the persistent
image, because of how the split works: `mtdsplit_fit` derives the kernel partition
as `round_up(FIT totalsize, erase block)` and then finds the rootfs after the FIT.
This board's kernel partition (`mtd4`) is `0x3A0000` = 3801088 bytes. Measured on
such a build: the squashfs landed at `0x760000` and the image was 12,058,913 bytes
instead of 9,437,473 with the squashfs at `0x3A0000` -- an image `sysupgrade`
cannot split correctly.

`--initramfs` changes the kernel, so one build cannot yield both kinds. `release.yml`
therefore runs `build.yml` twice, in parallel, on separate runners: one for
`initramfs`, one for `sysupgrade`. The wall-clock cost is one build.

The Image Builder belongs to the *sysupgrade* job for the same reason: the tarball
bundles the kernel that was just built, so a tarball from the initramfs tree would
hand every image it produces an initramfs-embedded kernel.

## The gates, in the order they run

| Gate | What it catches |
|---|---|
| `tools/check_workflows.py` | Invalid YAML, a `run:` block that does not parse, and an expression that uses a context GitHub does not allow there. The last one is why this exists: `env:` at job level cannot use `runner`, and GitHub cancels the *entire file* for it -- no job, no line number, just "This run likely failed because of a workflow file issue". |
| `tools/check_patches.py` | A hunk header that disagrees with its body. `git apply` reads exactly as many body lines as the header promised and exits 0 for the remainder, so an under-counting header drops the tail of a hunk silently: that is how `CONFIG_I2C_MT7621=y` once went missing from an image while every check stayed green. |
| `tools/check_patches_apply.py` | The series not applying to a clean tree at the pinned revision -- well-formed and applicable are different properties. It fetches every file the series touches from `raw.githubusercontent.com` at `OPENWRT_COMMIT`, applies the patches in the order `apply-overlay.sh` uses, and stops at the first refusal. About ten seconds, against hours for a build. If the network is unavailable it prints `SKIPPED` and exits 0: that is not a patch problem, but it is never silent. |
| `tools/test_check_patches_apply.sh` | The gate above failing to fail. It plants a patch whose context does not exist and one shaped like the patch that broke this pipeline, and asserts both are refused by name. |
| `tools/test_publish_packages.sh` | The package publisher's failure paths and both source layouts. 42 checks, no OpenWrt tree. It covers the case a real tree found and no fixture had: one kernel published under several version strings (`6.18.54`, `6.18.54.7.2`, `6.18.54.2026.09.01~be5ce791`), which an earlier publisher refused as "more than one kernel". |
| `tools/test_build_firmware.sh` | `set_cfg`/`set_cfg_off`, the option parser, including `-jN`, the failure report itself, and `check_target_kernel_config`. |
| `tools/check_kernel_sources.py` | A `source` line in the prepared kernel's Kconfig that points at a path the tree does not have. It resolves every `source` in the prepared kernel, skips the kernel's own `$(SRCARCH)` lines, and fails naming the file and the line: 1888 Kconfig files, about one second. `kernel-patches.yml` runs it in a step named "Every Kconfig source in the prepared kernel resolves", immediately after `target/linux/prepare`. The config-symbol check above cannot see this class -- it inspects the contents of `config-6.18`, and a dangling `source` line is not a symbol. |
| `tools/test_check_kernel_sources.sh` | The checker above failing to fail: 11 checks, including a planted dangling source that must be named by file and line, the kernel's own `$(SRCARCH)` line that must be left alone, and an OpenWrt tree with no prepared kernel, which is a usage error rather than a pass. `lint.yml` runs it. |
| `kernel-patches.yml` | The kernel patch series not applying, and a target kernel config that asks for modules this repository does not carry. This is the one gate that needs an OpenWrt tree and the one no check in this repository can replace: the series is applied *inside* the kernel build, against kernel sources, so `check_patches_apply.py` is blind to it by construction -- which is how nine patches that modified files the repository does not carry reached a release build. The job clones the tree, applies the overlay, and runs `BUILD_TARGET=target/linux/prepare`, which reaches the patches in about twenty seconds instead of forty minutes. Since the M2 fix it also runs the config check above, which is what would have caught the six xPON/optical symbols that made an M2 build ask for `net/xpon/`: 59 seconds on run 38931301958, against 44 minutes and an 18-second failure with no log. It then runs the Kconfig source check above on the prepared tree, in about a second, which is what the config check could not see (trap 11). It does not compile the kernel, so it cannot catch a compile error. |
| `tools/verify_build.py` | Run after the build: the FIT load and entry addresses must match where the kernel is linked, and the image must carry no debug breadcrumbs. |
| `tools/verify_image.py` | Run after the build on the persistent image: a squashfs superblock must exist and start inside the kernel partition. This is the gate that keeps an unsplittable image out of a release. |

The lint workflow also runs `bash -n` over every shell file, `py_compile` over
every Python file, `shellcheck` (advisory), a CRLF scan and an advisory non-ASCII
report. CRLF is worth its own line: a patch file converted to CRLF stops matching
every LF context in the tree it is applied to.

## The package repository

Kernel modules cannot come from OpenWrt for this board: `airoha/en7523` is
`FEATURES:=source-only`, which is how OpenWrt's builders decide not to publish a
package feed for a target, and a module loads only into the exact kernel it was
built against. Userspace packages are unaffected and install from the generic
`arm_cortex-a7` feeds.

`scripts/publish-packages.sh` assembles a repository per release tag:

```
<tag>/kmods/<kernel>/packages.adb + *.apk
<tag>/packages/<arch>/<feed>/...            only with --with-feeds
<tag>/metadata.json  <tag>/install.md
releases.json  index.html  .nojekyll
```

and `release.yml` pushes it to the `gh-pages` branch, which is also what GitHub
Pages serves. Two properties are deliberate:

* **Keyed by tag.** A module from one release is refused by the kernel of another
  ("Invalid module format"), which is the tag in the URL doing its job.
* **Published whole.** The index beside a package directory lists every file in it,
  so copying a subset would publish an index pointing at packages that are not
  there. The source directory itself is *discovered* -- `kmods/<kernel>/` in a
  builder's tree, `packages/` in a plain local build of this target -- and a tree
  with more than one *kernel* under it is refused.
* **One kernel, several version strings, is normal.** A real build of this board
  writes 53 modules named `6.18.54`, 2 named `6.18.54.7.2` (mac80211/cfg80211, which
  append their own backports version) and 5 named `6.18.54.2026.09.01~be5ce791`
  (mt76), all inside the same minute. The kernel is what those names share, it comes
  from the `kernel-*` package in the same directory, and apk tells modules apart by
  their dependency on `kernel (=<version>)` rather than by file name. The publisher
  used to require one name for the whole directory, which no real tree satisfies --
  the refusal below is about the kernel, not about that.

The packages are unsigned; installing them needs `apk add --allow-untrusted`. That
is a deliberate trade: signing means keeping a private key in CI secrets for an
artifact that anybody can rebuild from `scripts/pin.env`. See
[packages.md](packages.md) for the install commands, the raw-host fallback if Pages
is disabled, and how to prove the repository on a board.

## Releasing

```powershell
gh workflow run release.yml --ref main `
  -f tag=v0.1.0-m2 -f variant=m2 -f feeds=false `
  -f publish_release=true -f publish_pages=true
```

| Input | Meaning |
|---|---|
| `tag` | the release tag, created if it does not exist. The tag is what somebody clones to rebuild the images, so it is pinned to the commit the run built. |
| `variant` | `m2` (4x GbE, Wi-Fi 6, LuCI, apk) or `full` (adds the optical frontend and xPON/OMCI). `m2` is what leaves this machine; `full` needs the per-unit BOB calibration blob, see [hardware.md](hardware.md). |
| `feeds` | publish the userspace feeds to `gh-pages` as well. Off by default: the modules are a few megabytes, the full userspace set hundreds. This does not affect what goes into the image -- the build always installs the feeds. |
| `publish_release` | create or update the GitHub Release (both builds must have succeeded). |
| `publish_pages` | push the package repository to `gh-pages`. |

A tag push (`git push origin v0.1.0-m2`) runs the same thing with the defaults, so
the tag and the release always agree.

Then check what the run actually published, rather than that it went green:

```sh
python3 tools/verify_publish.py v0.1.0-m2
```

It reads the release and its assets, the `gh-pages` branch and the live Pages URLs a
board would fetch, and exits non-zero on any missing piece. On `v0.1.0-m2` (run
`38939207748`) that is 19 checks: the four release assets, the sysupgrade image at
9,437,480 B, the Image Builder at 47,340,172 B, `releases.json` listing the tag,
`install.md` naming the kmod directory, and 46 `kmod-*.apk` beside
`kernel-6.18.54~ba6507fb3e4420e857c74d5e042e6c5e-r1.apk` on the branch.

The last of those is the check that matters and the one that is easy to get wrong:
an apk index on main is the binary ADB format (it begins `ADBd`), not text with
`P: name` lines. The first version of this tool parsed it as text and reported zero
kernel modules for a repository holding 46 of them, so the count now comes from the
branch listing and from `metadata.json`.

## What has gone wrong here

Each of these cost a run before it was fixed, and each has a check above that now
catches it locally:

1. `git clone <openwrt> openwrt` inside the checkout: this repository has an
   `openwrt/` directory, so the clone always failed. The tree is fetched outside
   the workspace instead.
2. No step ran `./scripts/feeds update/install`. A freshly cloned tree has no
   `feeds/`, so `make defconfig` dropped `CONFIG_PACKAGE_luci` without a word and
   the image shipped with no web UI.
3. The Image Builder was built by the initramfs job, giving every image it produced
   an initramfs-embedded kernel.
4. `--no-initramfs` unset the symbol instead of writing `# ... is not set`, so a
   stale `=y` survived `make defconfig`.
5. The Image Builder tarball was collected from `dist/`, where only
   `build-imagebuilder.sh` copies it.
6. `runner` in a job-level `env:` (see the gate table above).
7. The workflow and the documentation both passed `-j4`, and the script accepted
   only `-j 4`. Both sides were wrong in the same direction, which is why neither
   caught it.
8. Patch 0006 was refused by `git apply` although every context line it searched
   for was present in the tree, byte for byte. Its hunk inserted at the end of a
   context block that, in a clean tree, is the middle of another block: a position
   from the tree the patch was written in. `tools/check_patches_apply.py` exists
   because of this one.
9. Nine patches of the kernel series modified files this repository does not carry
   -- `net/xpon/**`, `airoha_xpon.[ch]`, `phy-airoha-xpon.c`, `airoha_gpon_omci.c`
   -- which live in the community `airoha_en7523_all` branch and were in the
   author's local tree. Nothing failed at the overlay step; the failure came
   twenty seconds into `make target/linux/prepare`, as

   ```
   can't find file to patch at input line 4
   No file to patch.  Skipping patch.
   1 out of 1 hunk ignored
   Patch failed!  Please fix .../950-01-...patch!
   ```

   and it cost three runs, because the reason was in `logs/` rather than the
   terminal (see the next section) and because the local gate covers
   `openwrt/patches/`, which is applied to upstream files, and not the kernel
   series. Those nine patches now live in `openwrt/pon/patches-6.18/` -- which
   holds sixteen in all, see trap 11 -- and need `--with-pon`.

10. An M2 build asked the kernel to build the xPON and optical modules. The package
    list was right -- `packages-m2.append` seeds fifteen packages and no `kmod-xpon`
    -- and the *kernel* config was not: `0006` and `0007` were steps 6 and 7 of the
    default series, and they write six symbols into
    `target/linux/airoha/en7523/config-6.18`:

    ```
    CONFIG_XPON=m
    CONFIG_XPON_OMCI=m
    CONFIG_XPON_OAM=m
    CONFIG_PHY_AIROHA_XPON=m
    CONFIG_AIROHA_XPON_V1=m
    CONFIG_OPTICAL_FRONTEND=m
    ```

    so every build, M2 included, needed `net/xpon/` and `drivers/net/optical/`,
    which only exist in the community branch. `make target/linux/compile` died on
    run 38635021287 after **18 seconds** -- 21:30:50.71 to 21:31:08.74, following 44
    minutes of toolchain work -- and the runner's log held no reason at all: 18
    seconds is too short to compile anything, which is what points at the kernel's
    own configure step. Both patches are buildroot patches (they edit `config-6.18`
    and declare the kmod packages) and now live in
    `openwrt/pon/buildroot-patches/`, applied only with `--with-pon`.
    `build-firmware.sh` refuses to start when a build without `--with-pon` asks for
    any of those six symbols, naming them, so the failure costs seconds instead of
    three quarters of an hour. The lesson is the same shape as 9: "no PON in this
    image" is a claim about the *kernel config*, and a correct package list does not
    make it true.

11. The default series made kconfig `source` two directories this repository does not
    carry. Trap 10's fix removed the six symbols and the next run died the same way:
    about twenty seconds into the kernel's configure step, after the toolchain was
    built, with no reason in the log (run 38931458568, 38 minutes in). What had
    changed was two lines in the kernel's own Kconfig:

    ```
    net/Kconfig:90:              source "net/xpon/Kconfig"
    drivers/net/Kconfig:29:      source "drivers/net/optical/Kconfig"
    ```

    `930-55` adds the first and `930-53` the second, and `net/xpon/` and
    `drivers/net/optical/` exist only in the community `airoha_en7523_all` branch, so
    kconfig stopped at the first of them -- which is what twenty seconds of a kernel
    stage means. Trap 10's check cannot see this class: it inspects the contents of
    `config-6.18`, and a dangling `source` line is not a config symbol. Seven patches
    therefore moved to the xPON set -- `930-53`..`930-59`, applied only with
    `--with-pon` -- which leaves the default series at 22 patches, every one of them
    touching a file that exists upstream, and takes the xPON symbols out of the
    default tree, so an M2 build cannot select them even by accident. The gate that
    fails on this input in about a second, naming the file and the line, is
    `tools/check_kernel_sources.py`, run by `kernel-patches.yml` right after
    `target/linux/prepare` (see the gate table above).

## When a build fails

An OpenWrt parallel build writes each sub-build's output to `logs/` instead of the
terminal, so the top level reports a directory and nothing else:

```
make[3] -C target/linux compile
    ERROR: target/linux failed to build.
make -r world: build failed. Please re-run make with -j1 V=s ...
```

That line is true and useless, and it was the only thing three runs had to show
for 47 to 81 minutes of work each. Three things now make the reason reach the log:
`scripts/build-firmware.sh` keeps the make output, reads the failing directory out
of that line, and prints the last 80 lines of the matching file in `logs/`; because
OpenWrt writes `logs/` only when `CONFIG_BUILD_LOG=y` -- a prompt that is
`bool "..." if DEVEL`, so a release image cannot set it -- it also re-runs that one
directory with `make -C <dir> compile V=s` under `timeout 900` and prints the last
80 lines of that; and the build job uploads `logs/` and `.config` as an artifact
when it fails. The function that does the printing is `report_build_failure`, and
`tools/test_build_firmware.sh` checks it against a fake tree; `BUILD_LOG_RERUN=0` in
the environment turns the re-run off, which is what that test does.

## Limits

* The kernel patch series in `openwrt/overlay/` is **not** covered by
  `check_patches_apply.py`, which can only check the patches applied to upstream
  files. `kernel-patches.yml` closes that gap with a real OpenWrt tree and
  `make target/linux/prepare`, at about three minutes -- and, since the Kconfig
  check was added, it also resolves every `source` path the prepared tree points at,
  which is where trap 11 was found. Trap 9 above is what the gap in that gate cost:
  three runs of 47 to 81 minutes each.
* `scripts/pin.env` pins OpenWrt, not the feeds. They float with their branch
  heads, which is why the build prints every feed revision it installed.
* A build is 2-2.5 hours on a GitHub runner. The gates above are cheap on purpose:
  they run in seconds and cover the mistakes that would otherwise be found at the
  end of that build.
