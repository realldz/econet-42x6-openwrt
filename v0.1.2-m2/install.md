# Packages for v0.1.2-m2

Built from OpenWrt `9b95be917b2804cf877ca05c078175b37a3a95bf` (main snapshot, kernel 6.18.54), kernel `6.18.54`,
taken from `bin/targets/airoha/en7523/packages` on the build tree.

That directory is published whole: it holds the kernel modules for this kernel
(83 of them) and the rest of this target's packages, and `packages.adb`
lists all of them.  OpenWrt itself publishes no feed for this board -- the target
is `source-only` -- which is why the modules have to come from here.

**The URL contains the release tag on purpose.**  A kernel module only loads into
the kernel it was built against, so these packages belong to the images published
in the `v0.1.2-m2` release, and to no other release.

On the board:

```sh
# 1. Point apk at this release's repository.
echo 'https://realldz.github.io/econet-42x6-openwrt/v0.1.2-m2/kmods/6.18.54' > /etc/apk/repositories.d/42x6-kmods.list

# 2. The packages are not signed, so apk must be told to accept them.
apk update --allow-untrusted
apk add --allow-untrusted <package>

# 3. Check what is available.
apk search --allow-untrusted
```

If GitHub Pages is not serving this branch, the same tree is reachable from the
raw host, which apk handles just as well:

```sh
echo 'https://raw.githubusercontent.com/realldz/econet-42x6-openwrt/gh-pages/v0.1.2-m2/kmods/6.18.54' > /etc/apk/repositories.d/42x6-kmods.list
```

The signed-off alternative is to run it once per boot from a console instead of
editing the repository list:

```sh
apk add --allow-untrusted --repository 'https://realldz.github.io/econet-42x6-openwrt/v0.1.2-m2/kmods/6.18.54' <package>
```

## Two things that will waste your afternoon

* **`apk upgrade` is not safe on this board.**  Several packages in the OpenWrt
  snapshot are built against a different zlib ABI than the image carries.  Install
  one package at a time and reboot afterwards if anything looks wrong.
* **A module that refuses to load with `invalid module format` is from the wrong
  release.**  Check `uname -r` against the kernel listed above before assuming
  the module is broken.
