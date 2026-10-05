#!/usr/bin/env bash
# Apply the PON part (xPON + optical frontend) for vGP-42X6V1 to an OpenWrt tree.
# Run on Linux/WSL/Docker (bash + git). Run AFTER scripts/apply-overlay.sh.
#
#   ./apply-pon.sh /path/to/openwrt /path/to/airoha_kernel-clone
#
# The second argument (or $AIROHA_KERNEL_SRC) must point at a clone of the
# community tree, which is where the xPON sources come from:
#
#   git clone -b airoha_en7523_all --depth 1 \
#       https://github.com/Sirherobrine23/airoha_kernel.git
#
# The script deliberately does NOT drop the patches into target/linux/airoha/patches-6.18 for
# OpenWrt to apply by itself: our patches target the kernel tree AFTER OpenWrt has applied its
# ~180 patches, so they must be checked/applied with `git apply --3way` on the prepared kernel
# tree before building.
set -euo pipefail

OWRT=${1:?usage: apply-pon.sh <openwrt-tree> <airoha_kernel-clone>}
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${2:-"${AIROHA_KERNEL_SRC:-}"}
FILES="$OWRT/target/linux/airoha/files"
STAGE="$OWRT/target/linux/airoha/pon-patches"

[ -d "$OWRT/target/linux/airoha" ] || { echo "!! not an OpenWrt tree with the airoha target: $OWRT"; exit 1; }
if [ -z "$SRC" ]; then
  echo "!! no airoha_kernel clone given."
  echo "   Pass it as argument 2 or set AIROHA_KERNEL_SRC. To get one:"
  echo "     git clone -b airoha_en7523_all --depth 1 \\"
  echo "         https://github.com/Sirherobrine23/airoha_kernel.git"
  exit 1
fi
[ -d "$SRC" ] || { echo "!! source clone not found: $SRC"; exit 1; }

show() { git -C "$SRC" show "HEAD:$1"; }

echo "==> 1. copy NEW source files into target/linux/airoha/files/ (kernel source overlay)"
NEW_FILES=(
  net/xpon/Kconfig net/xpon/Makefile net/xpon/core.c net/xpon/genl.c net/xpon/internal.h
  net/xpon/leds.c net/xpon/sysfs.c
  net/xpon/oam/Makefile net/xpon/oam/core.c net/xpon/oam/internal.h net/xpon/oam/sysfs.c net/xpon/oam/wire.c
  net/xpon/omci/Kconfig net/xpon/omci/Makefile net/xpon/omci/agent.c net/xpon/omci/core.c
  net/xpon/omci/identity.c net/xpon/omci/internal.h net/xpon/omci/me.c net/xpon/omci/me.h
  net/xpon/omci/profiles.c net/xpon/omci/sysfs.c net/xpon/omci/wire.c net/xpon/omci/wire.h
  include/net/xpon.h include/net/xpon/oam.h include/net/xpon/omci.h include/uapi/linux/xpon.h
  include/linux/optical_frontend.h include/linux/phy/phy-airoha-xpon.h
  drivers/net/optical/Kconfig drivers/net/optical/Makefile drivers/net/optical/core.c
  drivers/net/optical/hwmon.c
  drivers/net/optical/airoha/Kconfig drivers/net/optical/airoha/Makefile
  drivers/net/optical/airoha/airoha_lddla.h drivers/net/optical/airoha/airoha_lddla_core.c
  drivers/net/optical/airoha/en7570.h drivers/net/optical/airoha/en7570_adcloop.c
  drivers/net/optical/airoha/en7570_ddmi.c drivers/net/optical/airoha/en7570_main.c
  drivers/net/optical/airoha/en7570_regs.h drivers/net/optical/airoha/en7570_txrx.c
  drivers/net/optical/airoha/en7571.h drivers/net/optical/airoha/en7571_adcloop.c
  drivers/net/optical/airoha/en7571_ddmi.c drivers/net/optical/airoha/en7571_main.c
  drivers/net/optical/airoha/en7571_regs.h drivers/net/optical/airoha/en7571_txrx.c
  drivers/net/optical/airoha/en7572.h drivers/net/optical/airoha/en7572_ddmi.c
  drivers/net/optical/airoha/en7572_loop.c drivers/net/optical/airoha/en7572_main.c
  drivers/net/optical/airoha/en7572_regs.h
  drivers/net/optical/semtech/Kconfig drivers/net/optical/semtech/Makefile
  drivers/net/optical/semtech/gn25l95.c
  drivers/phy/airoha/phy-airoha-xpon.c
  drivers/net/pcs/airoha/pcs-en7523.c
  drivers/net/ethernet/airoha/airoha_xpon.c drivers/net/ethernet/airoha/airoha_xpon.h
  drivers/net/ethernet/airoha/airoha_ploam.c drivers/net/ethernet/airoha/airoha_ploam.h
  drivers/net/ethernet/airoha/airoha_gpon_omci.c drivers/net/ethernet/airoha/airoha_gpon_omci.h
)
for f in "${NEW_FILES[@]}"; do
	mkdir -p "$FILES/$(dirname "$f")"
	show "$f" > "$FILES/$f"
done
echo "    ${#NEW_FILES[@]} files copied"

echo "==> 2. copy hook patches into $STAGE (do NOT let OpenWrt apply them by itself)"
mkdir -p "$STAGE"
cp -v "$HERE"/patches/*.patch "$STAGE"/ | sed 's/^/    /'

cat <<EOF

==> 3. NEXT STEPS (manual, in order)

  # (a) prepare the kernel tree (the files/ overlay is applied at this step)
  cd $OWRT
  make defconfig
  make target/linux/prepare V=s

  # (b) apply the 6 hook patches to the prepared kernel tree
  KDIR=\$(ls -d build_dir/target-*/linux-airoha*/linux-6.*)
  for p in $STAGE/*.patch; do
      git -C "\$KDIR" apply --3way --whitespace=nowarn "\$p" || echo "MANUAL FIX: \$p"
  done

  # (c) add the 2 hooks that cannot be patched (the files only exist after OpenWrt's patches):
  #     \$KDIR/drivers/net/pcs/airoha/Kconfig  -> symbol PCS_AIROHA_EN7523
  #     \$KDIR/drivers/net/pcs/airoha/Makefile -> obj-\$(CONFIG_PCS_AIROHA_EN7523) += pcs-en7523.o
  #     \$KDIR/drivers/phy/airoha/Kconfig      -> symbol PHY_AIROHA_XPON
  #     \$KDIR/drivers/phy/airoha/Makefile     -> obj-\$(CONFIG_PHY_AIROHA_XPON) += phy-airoha-xpon.o
  #     \$KDIR/drivers/net/pcs/Kconfig|Makefile: only add if there is no airoha/ hook yet

  # (d) BIGGEST TASK: port the 14 xPON hooks into airoha_eth.c (see pon/README.md section 3)

  # (e) pinctrl: add the "pon" function/group to pinctrl-en7523.c
  #     (or make pinctrl-0 optional in phy-airoha-xpon.c)

  # (f) build
  make -j"\$(nproc)" V=s
EOF
