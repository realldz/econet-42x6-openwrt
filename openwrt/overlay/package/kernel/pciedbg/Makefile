# SPDX-License-Identifier: GPL-2.0
include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=pciedbg
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define KernelPackage/pciedbg
  SUBMENU:=Other modules
  TITLE:=EN7523 PCIe register debug helper (/proc/pciedbg)
  FILES:=$(PKG_BUILD_DIR)/pciedbg.ko
  KCONFIG:=
endef

define KernelPackage/pciedbg/description
  Cho phep doc/ghi thanh ghi PCIe vat ly tu userspace qua /proc/pciedbg,
  dung cho bring-up EN7523 (42X6). KHONG autoload.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(MAKE) -C "$(LINUX_DIR)" \
		$(KERNEL_MAKE_FLAGS) \
		M="$(PKG_BUILD_DIR)" \
		modules
endef

$(eval $(call KernelPackage,pciedbg))
