# SPDX-License-Identifier: GPL-2.0
include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=ringwatch
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define KernelPackage/ringwatch
  SUBMENU:=Other modules
  TITLE:=MT7916 WFDMA ring-table watcher (42X6 bring-up)
  FILES:=$(PKG_BUILD_DIR)/ringwatch.ko
  KCONFIG:=
endef

define KernelPackage/ringwatch/description
  Poll bang ring WFDMA cua MT7916 tu phia host moi 50 ms va in ra moi thay doi
  (base/cnt/cidx/didx + GLO_CFG) kem so tick. Dung de biet driver mt76 co ghi
  duoc desc_base vao chip that khong, va sau do co bi reset khong.
  KHONG autoload.
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

$(eval $(call KernelPackage,ringwatch))
