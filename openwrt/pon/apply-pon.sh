#!/usr/bin/env bash
# Apply the PON part (xPON + optical frontend) for vGP-42X6V1 to an OpenWrt tree.
# Run on Linux/WSL/Docker (bash + git). Run AFTER scripts/apply-overlay.sh.
#
#   ./apply-pon.sh /path/to/openwrt
#
# Route A: most of the xPON material is a kernel patch series
# (openwrt/overlay/target/linux/airoha/patches-6.18/ 930-55..59, 940-01..06,
# enabled by openwrt/pon/buildroot-patches/0007-*, which --with-pon applies).
# build.  This script stages the files that cannot live in patches-6.18:
#
#   openwrt/pon/overlay/drivers/net/ethernet/airoha/airoha_wed.h
#     - included by airoha_eth.c (route-A baseline), absent from this kernel;
#       the WED symbols it declares are only ever used as pointers here, so a
#       forward declaration is enough and no mtk_wed driver is pulled in.
#
# Everything lands in target/linux/airoha/files/ (the kernel source overlay),
# which OpenWrt copies into the kernel tree BEFORE applying patches.  That
# order is why the reverse is forbidden: files that a patch creates must not
# also be overlaid (the build fails with "already exists").
set -euo pipefail

OWRT=${1:?usage: apply-pon.sh <openwrt-tree>}
HERE=$(cd "$(dirname "$0")" && pwd)
FILES="$OWRT/target/linux/airoha/files"

[ -d "$OWRT/target/linux/airoha" ] || { echo "!! not an OpenWrt tree with the airoha target: $OWRT"; exit 1; }

echo "==> route-A overlay files -> $FILES"
n=0
while IFS= read -r f; do
	rel=${f#"$HERE/overlay/"}
	mkdir -p "$FILES/$(dirname "$rel")"
	cp "$f" "$FILES/$rel"
	n=$((n + 1))
done < <(find "$HERE/overlay" -type f | sort)
echo "    $n route-A overlay file(s) copied"

cat <<EOF

==> Route-A kernel patches apply by themselves.
    The 930-55..59 / 940-01..06 series already lives in
    target/linux/airoha/patches-6.18/ (copied by scripts/apply-overlay.sh),
    and openwrt/pon/buildroot-patches/0007-* selects the symbols and declares the kmod
    packages.  No manual hook patching is needed.

    The xPON-only patches -- 930-60 and 950-01..08, which modify net/xpon/**
    and the airoha_xpon / phy-airoha-xpon / airoha_gpon_omci files -- are in
    openwrt/pon/patches-6.18/ and are copied in only by
    `scripts/apply-overlay.sh --with-pon`, because those files belong to the
    community airoha_en7523_all branch and are not in this repository.  See
    openwrt/pon/README.md.

==> NEXT STEPS (in order)

  # (a) configure and prepare the kernel tree
  cd $OWRT
  make defconfig
  make target/linux/prepare V=s

  # (b) build
  make -j"\$(nproc)" V=s
EOF
