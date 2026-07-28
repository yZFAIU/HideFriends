#
#  HideFriends —— 抖音「隐藏好友」独立插件（Substrate-free）
#  作者: yZFAIU
#  构建: Theos。与 DYYY 项目独立，不共享任何文件/键/入口。
#
#  说明：本插件不依赖 Substrate（hook 全部走 ObjC runtime 原生 method_setImplementation），
#        因此产物既可用作越狱 deb（由 Substrate 加载），也可作为 TrollFools 的 diylib 直接注入。
#

TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

# 打包方案（roothide / rootless / 传统）。默认传统 deb。
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

# 源文件均为纯 ObjC（.m），不依赖 Logos/Substrate
HideFriends_FILES = HideFriends.m HideFriendsManager.m HideFriendsSettingViewController.m
HideFriends_CFLAGS = -fobjc-arc -w
HideFriends_FRAMEWORKS = UIKit Foundation
# 不链接 libobjc 之外的额外库；运行时符号由宿主 App 提供
HideFriends_LDFLAGS = -undefined dynamic_lookup

export THEOS_STRICT_LOGOS = 0
export ERROR_ON_WARNINGS = 0

include $(THEOS_MAKE_PATH)/tweak.mk
