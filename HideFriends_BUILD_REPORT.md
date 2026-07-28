# HideFriends 项目问题检查 + 编译打包报告

**作者**：yZFAIU　|　**目标**：抖音（Aweme）「隐藏好友」独立插件
**交付时间**：2026-07-29　|　**构建环境**：Linux 沙箱（clang 18.1.3 + iPhoneOS14.5 SDK + ld.lld + dpkg-deb）

---

## 一、检查出的项目问题

| # | 问题 | 严重度 | 后果 | 修复方式 |
|---|------|--------|------|----------|
| 1 | `HideFriends.h` 导入 `<substrate.h>`，`HideFriends.xm` 使用 `MSHookMessageEx` 与 Logos `%hook/%orig` | **致命** | 经 TrollFools / diylib 注入（无 Substrate）时 `MSHookMessageEx` 符号未定义 → dylib 加载即崩溃；与你"要 diylib"的需求直接冲突 | 改为 **Substrate-free**：所有 hook 走 ObjC runtime 原生 `method_setImplementation`，并将 `.xm` 转为纯 `.m` |
| 2 | `HideFriendsSettingViewController.m` 第 147 行 `t.secureTextExtension = YES` | **致命（编译错误）** | 属性名错误，`secureTextExtension` 不存在 → **原项目根本无法编译通过** | 改为正确的 `secureTextEntry` |
| 3 | hook 安装在构造函数（`%ctor`）中，早于抖音各类加载 | 中 | TrollFools 注入时机过早时 `NSClassFromString` 可能返回 nil，列表/会话 hook 全部失效 | 安装推迟到 `UIApplicationDidFinishLaunchingNotification` |
| 4 | 首启设密弹窗在 `DidFinishLaunching` 后固定 `0.6s` 弹出，未确认 keyWindow 就绪 | 中 | 部分版本 keyWindow 未就绪 → 弹窗不显示 → 无法完成首次设密 | 改为 `UIApplicationDidBecomeActiveNotification` 并带「未就绪则重试」 |
| 5 | README 声称"沙箱（Linux）无法编译 iOS tweak" | 误 | 实际沙箱具备 theos + SDK + clang + lld + dpkg，本应就地编译 | 删除误述，补充 Linux/macOS 构建命令与成品说明 |

---

## 二、关键修复说明（Substrate-free 设计）

原项目用 Logos `%hook` + `MSHookMessageEx`，这在越狱（有 Substrate）下没问题，但 **diylib 注入场景没有 Substrate**，未定义符号会导致 dyld 加载失败。

修复后：
- 移除 `<substrate.h>` 依赖，所有方法替换使用 `method_setImplementation`（ObjC runtime 原生，iOS 始终可用）；
- 入口手势不再 swizzle `UIWindow`，改为监听 `UIWindowDidBecomeKeyNotification` 给窗口加三指长按，零侵入、更稳；
- 搜索栏密码恢复改为对 `AWESearchViewController` / `AWENewSearchViewController` 的 `searchBar:textDidChange:` 做原生 swizzle；
- **同一份产物**在「越狱 + Substrate 加载」与「TrollFools / TrollStore 直接注入（无 Substrate）」两种场景都能运行。

> ⚠️ 抖音各版本私有类名/方法名差异较大。hook 点已做成配置式 `HFArrayHookConfig` 且自动跳过不存在的类/方法；
> 若某列表未生效，按目标版本的 AwemeHeaders 核对并替换候选名后重新编译即可，其余逻辑与版本无关。

---

## 三、编译验证

- ✅ 三个源文件（arm64 + arm64e）均编译通过；
- ✅ 链接产物 `strings` 扫描**无任何 `substrate` / `MSHook` 字符串引用**（即无 Substrate 符号依赖）；
- ✅ `file` 确认 fat dylib 为 `Mach-O universal binary with 2 architectures: arm64 + arm64e`；
- ✅ `.deb` 内 dylib 同为有效 fat Mach-O，无 Substrate 引用。

---

## 四、交付物（均在 `/workspace`）

| 文件 | 用途 |
|------|------|
| **`HideFriends.dylib`** | 通用 fat dylib（arm64+arm64e），已剥离 `LC_BUILD_VERSION` → **TrollFools 注入用** |
| **`HideFriends.with_buildversion.dylib`** | 同上但保留 `LC_BUILD_VERSION` → **TrollStore 安装用** |
| **`com.yzfaiu.hidefriends_1.0.0_iphoneos-arm.deb`** | 越狱包，内含 `HideFriends.dylib` + `HideFriends.plist`（过滤 Aweme / Aweme.lite） |
| **`HideFriends-src/`** | 修复后的完整可重建源码（含更新后的 README 与 Makefile、`.github` CI） |

---

## 五、使用方式

- **越狱**：`dpkg -i com.yzfaiu.hidefriends_1.0.0_iphoneos-arm.deb`
- **TrollFools**：直接注入 `HideFriends.dylib`
- **TrollStore**：安装 `HideFriends.with_buildversion.dylib`

首启打开抖音 → 强制设密码 → 保存后自动重启 → 三指长按（或搜索栏输密码）进入设置 → 开「隐藏好友」、添加好友 UID。
