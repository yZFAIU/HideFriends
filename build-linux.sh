#!/usr/bin/env bash
#
# build-linux.sh — 在 Linux 上构建 HideFriends 的一键脚本
#
# 前置要求：
#   1. Theos 已安装（本工程在 /opt/theos 实测通过；可用其他路径，用 THEOS 环境变量指定）
#   2. Theos 依赖已装：build-essential fakeroot rsync perl git libxml2 xz-utils
#   3. iOS 工具链已放好：$THEOS/toolchain/linux/iphone/（含 clang、ldid）
#   4. iOS SDK 已放好：$THEOS/sdks/iPhoneOS*.sdk
#
# 用法：
#   ./build-linux.sh                 # 默认（rootful）打包
#   ./build-linux.sh SCHEME=rootless # rootless 打包
#   ./build-linux.sh SCHEME=roothide # roothide 打包
#
set -e

export THEOS="${THEOS:-/opt/theos}"
export PATH="$THEOS/bin:$PATH"

cd "$(dirname "$0")"

# 规避并行 make 下 clang modules 的 build_session 竞态
mkdir -p .theos
touch .theos/build_session

echo "==> 使用 Theos: $THEOS"
make package "$@"
echo "==> 构建完成，产物见 packages/"
