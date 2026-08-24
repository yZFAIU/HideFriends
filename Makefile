#
#  HideFriends
#
#  隐藏抖音好友插件（学习 DYYY 架构后自建）
#  基于 Theos / Logos，仅供学习交流
#
#  构建：
#    make package                 # 默认（rootful）打包
#    make package SCHEME=rootless # rootless 打包
#    make package SCHEME=roothide # roothide 打包
#    make package INSTALL=1       # 打包并安装到设备（需 THEOS_DEVICE_IP）
#

TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

# 根据参数选择打包方案
ifeq ($(SCHEME),roothide)
    export THEOS_PACKAGE_SCHEME = roothide
else ifeq ($(SCHEME),rootless)
    export THEOS_PACKAGE_SCHEME = rootless
else
    unexport THEOS_PACKAGE_SCHEME
endif

export DEBUG = 0
INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HideFriends

HideFriends_FILES = HideFriends.xm HFSettingViewController.m HFUtils.m HFBlacklist.m HFBlacklistViewController.m HFUserSelectViewController.m HFDiscovery.m HFReporter.m
HideFriends_CFLAGS = -fobjc-arc -w
HideFriends_LDFLAGS = -undefined dynamic_lookup
HideFriends_LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS_MAKE_PATH)/tweak.mk

# 清理 packages 目录
clean::
	@echo "==> Cleaning packages…"
	@rm -rf .theos packages

# 编译并自动安装（参照 DYYY after-package 逻辑）
after-package::
	@echo "==> Packaging complete."
	@if [ "$(INSTALL)" = "1" ]; then \
        DEB_FILE=$$(ls -t packages/*.deb | head -1); \
        PACKAGE_NAME=$$(basename "$$DEB_FILE" | cut -d'_' -f1); \
        echo "==> Installing $$PACKAGE_NAME to device…"; \
        ssh root@$(THEOS_DEVICE_IP) "rm -rf /tmp/$${PACKAGE_NAME}.deb"; \
        scp "$$DEB_FILE" root@$(THEOS_DEVICE_IP):/tmp/$${PACKAGE_NAME}.deb; \
        ssh root@$(THEOS_DEVICE_IP) "dpkg -i --force-overwrite /tmp/$${PACKAGE_NAME}.deb && rm -f /tmp/$${PACKAGE_NAME}.deb"; \
    fi
