# HideFriends · 抖音「隐藏好友」独立插件

> 作者：**yZFAIU**
> 仅供学习交流，请在 24 小时内自觉删除。
> 思路参考 [huami1314/DYYY](https://github.com/huami1314/DYYY) 的分层架构（数据模型 hook + 中心 Manager + 自定义视图），
> 但本插件**完全独立**，与 DYYY 在包名、存储键、入口手势、设置面板上均隔离，可同时共存、互不冲突。

---

## 一、功能对照需求

| 需求 | 实现位置 | 说明 |
|------|----------|------|
| 首次注入必须设密码，保存后**重启 APP 才可见入口** | `HideFriendsManager` 门禁 + 构造函数（`__attribute__((constructor))`）启动逻辑 | 未设密码时每次启动强制弹窗设密码；保存后置 `NEEDS_RESTART`，下次启动 `markRestarted` 才置 `READY`，入口方可见 |
| 密码 = 触发隐藏好友开关 | 密码哈希存储 + 设置内开关 | 密码是访问/控制隐藏功能的钥匙；搜索栏输入密码可临时恢复显示 |
| ① 隐藏好友开关 | 设置面板 Section 0 第 1 行 | 写入 `YZFAIU_HF_HIDE_ENABLED` |
| ② 是否隐藏插件 | 设置面板 Section 0 第 2 行 | 开启后三指入口失效（stealth），仅搜索密码可恢复/进入设置 |
| ③ 需隐藏的好友 | 设置面板 Section 1 | 按 **UID** 增删，写入 `YZFAIU_HF_HIDDEN_UIDS` |
| ④ 修改密码 | 设置面板 Section 2 | 校验旧密码后改密 |
| 隐藏好友后关注/朋友列表也看不见 | 运行时 hook（关注/粉丝/朋友列表） | 见 `HFArrayHookConfig` |
| 搜索栏输入密码恢复好友显示 | `AWESearchViewController` hook | 命中密码即 `setTemporarilyRevealed:YES` 并清空搜索框 |
| 隐藏后看不到聊天框/消息/电话 | 运行时 hook（会话列表） | 会话被过滤，聊天入口与消息、来电均不可见 |
| 设置入口不与 DYYY 冲突 | 三指长按（DYYY 用双指）+ 搜索密码 | **不**向抖音设置页注入入口 |

---

## 二、项目结构

```
HideFriends/
├── Makefile                       # Theos 构建（独立包名 com.yzfaiu.hidefriends）
├── control                        # Debian 包信息
├── HideFriends.plist              # 注入目标：Aweme / Aweme.lite
├── HideFriends.h                  # 公共头：存储键 + Manager 接口 + 工具函数声明
├── HideFriendsManager.m           # 核心：密码/门禁/开关/隐藏名单/临时显示 + SHA256/uid提取/数组过滤
├── HideFriendsSettingViewController.h/.m  # 深色风格设置面板（四项功能）
├── HideFriends.m                  # 主逻辑：三指入口 + 首启设密 + 搜索密码 + 列表/会话 hook（纯 ObjC，无 Logos/Substrate）
└── README.md
```

---

## 三、构建（diylib / .deb）

> **Substrate-free 设计（重要）**：本插件**不依赖 Substrate / CydiaSubstrate**。所有方法 hook 均通过
> Objective-C runtime 原生 `method_setImplementation` 实现。因此同一份产物既能作为越狱 `.deb`（由 Substrate 加载），
> 也能作为 **TrollFools / TrollStore 的 diylib 直接注入（无需 Substrate）**，不会出现 `MSHookMessageEx`
> 符号缺失导致的加载崩溃。本仓库已附带编译好的成品（见同目录 / 下载区），也支持在 Linux 沙箱或 macOS 重新构建。

### A. 已附带的成品（同目录 / 下载区）
- `HideFriends.dylib` —— 通用 fat（arm64+arm64e），**已剥离 `LC_BUILD_VERSION`**，专供 **TrollFools 注入**；
- `HideFriends.with_buildversion.dylib` —— 同上但保留 `LC_BUILD_VERSION`，供 **TrollStore** 安装；
- `com.yzfaiu.hidefriends_1.0.0_iphoneos-arm.deb` —— 越狱包，内含 `HideFriends.dylib` 与 plist 过滤器。

### B. 在 Linux 沙箱 / CI 手动编译（无需 macOS，已验证）
工具链：clang + iPhoneOS14.5 SDK（`/opt/theos/sdks`）+ `ld.lld` + `dpkg-deb`。

```bash
SDK=/opt/theos/sdks/iPhoneOS14.5.sdk
mkdir -p build/arm64 build/arm64e
# 1) 编译三个 .m（arm64 / arm64e）
for f in HideFriends.m HideFriendsManager.m HideFriendsSettingViewController.m; do
  clang -target arm64-apple-ios14.5  -fobjc-arc -isysroot $SDK -I. -c "$f" -o build/arm64/${f%.m}.o
  clang -target arm64e-apple-ios14.5 -fobjc-arc -isysroot $SDK -I. -c "$f" -o build/arm64e/${f%.m}.o
done
# 2) 链接为 dylib（-undefined dynamic_lookup 让运行时由宿主 App 解析 UIKit 等符号）
clang -target arm64-apple-ios14.5  -fuse-ld=lld -dynamiclib -undefined dynamic_lookup -isysroot $SDK -o HideFriends.arm64.dylib  build/arm64/*.o
clang -target arm64e-apple-ios14.5 -fuse-ld=lld -dynamiclib -undefined dynamic_lookup -isysroot $SDK -o HideFriends.arm64e.dylib build/arm64e/*.o
# 3) 用 mkfat.py 合成 fat（含剥离 / 保留 LC_BUILD_VERSION 两版），再用 dpkg-deb 出包
```

### C. 在 macOS + Theos 编译（传统 / rootless / roothide）
```bash
export THEOS=/opt/theos
make clean && make package            # 传统 deb
make SCHEME=rootless package          # rootless
make SCHEME=roothide  package         # roothide
# 产物：packages/HideFriends_<版本>_iphoneos-arm.deb
```
> 仓库内置 `.github/workflows/build.yml`，推送后到 Actions 运行 `Build` 即出 `packages/*.deb`。

### 安装 / 使用
- 越狱：用 `dpkg -i com.yzfaiu.hidefriends_1.0.0_iphoneos-arm.deb` 安装（含 dylib + plist 过滤器）；
- TrollFools：直接注入 `HideFriends.dylib`；
- TrollStore：安装 `HideFriends.with_buildversion.dylib`。

---

## 四、使用流程

1. 安装插件后打开抖音 → 首次强制要求**设置密码**（连续输入两次）。
2. 保存后插件**自动重启抖音**。
3. 重启后入口生效：
   - **三指长按**屏幕任意处（区别于 DYYY 的双指长按）→ 打开设置（前提是“是否隐藏插件”为关）。
   - 或：在**搜索栏输入密码** → 立即恢复隐藏好友显示（若插件已隐藏，则同时打开设置）。
4. 设置内：
   - 打开「隐藏好友开关」；
   - 在「需隐藏的好友」中添加目标好友 **UID**；
   - 隐藏插件：开启后三指入口关闭，仅搜索密码可恢复；
   - 修改密码：需先输旧密码。

> 忘记密码且已开启“隐藏插件”时：用 `ssh root@设备` 执行
> `defaults delete com.ss.iphone.ugc.Aweme YZFAIU_HF_PASSWORD` 等键，或重装插件即可重置。

---

## 五、?? 必须按抖音版本核对的 Hook 点

抖音各版本的私有类名/方法名差异较大。本插件用**配置式 runtime hook**（`HideFriends.m` 中的 `HFArrayHookConfig`），自动跳过不存在的类/方法。请按你的 **AwemeHeaders** 核对并替换下表中的候选名：

```objc
static NSArray *HFArrayHookConfig(void) {
    return @[
        // 关注 / 粉丝 / 朋友 列表（取好友 UID 的数组 / setter）
        @[@"AWEUserRelationListViewController", @"users"],
        @[@"AWEUserFollowListViewController",  @"follows"],
        @[@"AWEFansListViewController",         @"fans"],
        @[@"AWEFriendsViewController",          @"friends"],
        // 聊天 / 会话 列表（隐藏后看不到聊天框、消息、电话）
        @[@"AWEIMConversationListViewController", @"conversationList"],
        @[@"IESIMConversationListViewController", @"conversationList"],
        ...
    ];
}
```

核对要点：
- 列表 VC 中**返回模型数组**的 getter（如 `users` / `userList` / `friends` / `conversationList` / `relations`）及其对应 setter；
- 模型对象里取 UID 的字段（`HFUidOfModel` 已内置 `uid/userID/userId/sec_uid/conversationID/peerUser...`，可按需补充）；
- 搜索控制器类名：`AWESearchViewController` 或 `AWENewSearchViewController`，以及其 `searchBar:textDidChange:` 方法签名。

若某列表未生效，多半是类名/方法名不符，把正确的填进 `HFArrayHookConfig` 重新编译即可；其余逻辑（密码门禁、设置、搜索恢复、入口手势）与版本无关，无需改动。

---

## 六、设计要点（与 DYYY 隔离）

- **存储键前缀** `YZFAIU_HF_*`，绝不触碰 DYYY 的 `DYYY*` 键；
- **入口手势**为三指长按（DYYY 为双指长按），且本插件**不向抖音设置页注入入口**；
- **包名** `com.yzfaiu.hidefriends`，独立 bundle，可与原 DYYY 并存；
- **Substrate-free**：hook 全部走 ObjC runtime 原生接口，越狱与 TrollFools 注入两种场景通用；
- 密码仅以 **SHA256** 存储，不落明文；本插件**不上传任何数据**，仅做本地显示过滤。

---

## 七、本次修复记录（相对原始上传版本）

- 移除对 `<substrate.h>` 与 `MSHookMessageEx` / Logos `%hook`/`%orig` 的依赖，改为 `method_setImplementation` 原生 hook，解决 diylib 注入时因 Substrate 符号缺失导致的加载崩溃；
- 修复 `HideFriendsSettingViewController.m` 中 `secureTextExtension`（不存在属性）的编译错误，应为 `secureTextEntry`；
- hook 安装由构造函数推迟到 `UIApplicationDidFinishLaunchingNotification`，确保抖音各类已加载（兼容 TrollFools 注入时机）；
- 首启设密弹窗由固定 0.6s 改为 `UIApplicationDidBecomeActiveNotification` 且带「未就绪则重试」，避免 keyWindow 未就绪导致弹窗不显示；
- 更新本文档：删除“沙箱无法编译”的误述，补充 Linux/macOS 构建命令与成品说明。
