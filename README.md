# HideFriends

隐藏抖音（Aweme）好友相关内容的 iOS 越狱插件，**纯离线工具**，不上传任何数据到服务器。

基于 [Theos](https://theos.dev/) / Logos 开发，仅供学习交流。

## 功能

- 黑名单隐藏：按抖音号 / UID / 昵称精确匹配，隐藏黑名单好友的相关内容
- 覆盖场景：
  - 好友推荐（AFD 系列视图）
  - 消息 / 私信入口（AWEIM 系列视图）
  - 关注 / 粉丝 / 互关列表
  - 消息页「限时日常」窗口
  - 聊天会话列表
- 隐藏方式：整行隐藏（内容 + 高度归零），复用滚动不闪出、不误伤
- 「添加好友」页：自动识别互关好友，一键加入黑名单
- 设置页：总开关 / 添加好友 / 关于，统一深色主题

## 架构

| 文件 | 职责 |
| --- | --- |
| `HideFriends.xm` | Logos hook 入口：`willDisplayCell`、双指长按呼出设置页 |
| `HFBlacklist.m/.h` | 核心：黑名单匹配、隐藏、行高归零、用户注册表、互关好友 |
| `HFDiscovery.m/.h` | 运行时自适应类发现（用户类 / ID 字段 / cell key） |
| `HFReporter.m/.h` | 本地维护：定时补装 hook + 主动扫描隐藏兜底（纯离线） |
| `HFSettingViewController.m` | 设置页 |
| `HFBlacklistViewController.m` | 添加好友页 |
| `HFUserSelectViewController.m` | 从互关好友选择页 |
| `HFUtils.m/.h` | 工具函数 |
| `AwemeHeaders.h` | 抖音类前向声明 |

## 编译

### 前置要求

- Linux（实测 Ubuntu 22.04）
- Theos（含 iOS 工具链 + SDK）
- 依赖：`build-essential fakeroot rsync perl git libxml2 xz-utils`

### 打包

```bash
./build-linux.sh                 # rootful
./build-linux.sh SCHEME=rootless # rootless（iOS 15+ 越狱）
./build-linux.sh SCHEME=roothide # roothide
```

产物在 `packages/` 目录，生成 `.deb` 安装包。

## 安装

1. 用 Sileo / 包管理器安装 `packages/*.deb`，或 `dpkg -i` 安装
2. 重启抖音：`killall Aweme`
3. 在抖音任意界面**双指长按**呼出设置页

## 使用

1. 设置页 → 总开关（默认开启）
2. 添加好友 → 从互关好友选择，或手动输入抖音号 / UID
3. 黑名单好友会自动在推荐流、消息、关注 / 粉丝 / 互关列表中被隐藏

## 免责声明

本插件仅供学习、研究 iOS 逆向工程与 Theos 开发使用，请勿用于任何违反抖音用户协议或法律法规的用途。使用本插件产生的一切后果由使用者自行承担。
