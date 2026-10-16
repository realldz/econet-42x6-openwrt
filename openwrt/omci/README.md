# OMCI userspace: `omci-agent` + `luci-app-omci`

Control plane for the in-kernel OMCI stack (`net/xpon/omci/`, enabled by
`openwrt/pon/buildroot-patches/0007-*`, applied only with `--with-pon`). Two packages, applied to the tree by
[`apply-omci.sh`](apply-omci.sh) -- `scripts/apply-overlay.sh` calls it, so a
normal build already includes this. The script also synchronises the UAPI
header; read [the v13 vs v14 story](#uapi-must-match-the-kernel-v13-vs-v14)
before touching anything here.

## Provenance

Both packages are a verbatim copy of the community
[`Sirherobrine23/openwrt`](https://github.com/Sirherobrine23/openwrt) tree,
`main` @ `1b46c9c8` (2026-10-08, head of
[openwrt#20104](https://github.com/openwrt/openwrt/pull/20104)):
`package/utils/airoha/omci-agent/**` and
`package/utils/airoha/luci-app-omci/**`. This is a mainline-style rewrite,
not vendor code. Both carry `SPDX-License-Identifier: GPL-2.0-only`
(`PKG_LICENSE:=GPL-2.0-only`), same as this repository.

Local changes versus that copy are limited to comment wording (English) --
no behaviour change. The vendored UAPI header inside `omci-agent`
(`src/include/linux/omci.h`) is overwritten by `apply-omci.sh` on every
copy; see below.

## Contents

* `packages/omci-agent/` -- `omci.so`, a native C ucode binding that speaks
  Generic Netlink directly to the kernel (`OMCI_GENL_NAME "omci"`); an rpcd
  backend (`omci.agent`, runs inside rpcd, no helper process); an
  `omcictl` ubus CLI; and `/etc/config/omci` defaults. **Not a kmod** -- it
  builds without any kernel patch.
* `packages/luci-app-omci/` -- LuCI pages under Network -> OMCI (Status,
  Configuration: General + Profiles, MIB: Inventory, GPON, Bridge/UNI,
  Multicast, Other). Pure JS over rpcd/ubus.
* `uapi/linux/omci.h` -- the ONE canonical UAPI copy in this repository
  (`OMCI_GENL_VERSION 14`).
* `apply-omci.sh` -- copies the two packages into the tree (modes
  normalised to 755/644), overwrites the vendored header with the canonical
  one, and hard-fails on mismatch (below).

## UAPI must match the kernel (v13 vs v14)

Measured on hardware (2026-10-11): the fork's vendored header is version
**13** while the kernel this target builds is version **14** (the header
arrives via the xPON source overlay as
`target/linux/airoha/files/include/uapi/linux/omci.h`, and
`net/xpon/omci/core.c` reports `.version = OMCI_GENL_VERSION`). The symptom
was `ubus call omci.agent family` -> `compatible: false` (kernel 14 /
client 13), with every other method failing `Unknown error` -- LuCI looked
installed but could do nothing.

The v13 -> v14 delta is +26/-1 lines: the version define, `OMCI_ATTR_ONU_TYPE`
appended at the END of `enum omci_attr` (no attribute number moves), plus
`enum omci_onu_type` and `OMCI_CONFIG_SOURCE_SYSFS`. The ABI is compatible;
only the version handshake was wrong.

The durable fix: `apply-omci.sh` pins the canonical copy here, overwrites
the vendored one on every copy, and exits 1 if the prepared kernel tree
(`build_dir/.../linux-*/include/uapi/linux/omci.h`) differs -- so a
mismatched pair can never be built again. When the kernel bumps the version
(v15 ...): copy the kernel header over `uapi/linux/omci.h`, review the
delta, commit it, then rebuild BOTH sides.

Two operational notes from the same bring-up:

* The packages must be *selected* (`CONFIG_PACKAGE_omci-agent=y`,
  `CONFIG_PACKAGE_luci-app-omci=y` in `scripts/packages.append`, then
  `make defconfig`); otherwise `make package/.../compile` exits 0 having
  compiled nothing.
* `cp -a` from a Windows mount yields mode 0777 on every file, and that mode
  travels into the `.apk`; rpcd SILENTLY SKIPS a world-writable ucode
  script, killing the whole page while the build reports success.
  `apply-omci.sh` normalises modes and gates on them for exactly this
  reason.

## Identity and redaction

`/etc/config/omci` ships with EMPTY identity (`serial`, `vendor_id`,
`hardware_version`, `software_version_*`, `equipment_id`, `password` are all
`''`). Fill them in on the device through LuCI or `omcictl`; per-unit
serials, MACs and passwords are never committed to this repository. The
kernel-side serial comes from the `gpon-serial-number` nvmem cell (see the
`bob` partition in the board DTS), not from this file.
