//
//  HideFriends.h
//  抖音「隐藏好友」独立插件 —— 公共头文件
//
//  作者: yZFAIU
//  设计原则：与 huami1314/DYYY 完全隔离，互不冲突：
//    - 包名   : com.yzfaiu.hidefriends（DYYY 为 com.huami.dyyy）
//    - 存储键 : YZFAIU_HF_* 前缀（DYYY 为 DYYY*）
//    - 入口   : 三指长按窗口（DYYY 用双指长按内容区），且不向抖音设置页注入入口
//    - 类/方法: HF 前缀，独立命名空间
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 注：本插件【完全不依赖 Substrate/CydiaSubstrate】。
// 所有方法 hook 均通过 Objective-C runtime 原生接口（method_setImplementation）实现，
// 因此在「越狱 + Substrate」与「TrollFools / diylib 注入（无 Substrate）」两种场景
// 下都能正常加载运行，不会出现 MSHookMessageEx 符号缺失导致的加载崩溃。

#pragma mark - 存储键（与 DYYY 完全隔离）
static NSString *const HFKeyPassword      = @"YZFAIU_HF_PASSWORD";       // 密码（本地存储，仅本机）
static NSString *const HFKeySetupDone     = @"YZFAIU_HF_SETUP_DONE";     // 是否已完成首次设密
static NSString *const HFKeyNeedsRestart  = @"YZFAIU_HF_NEEDS_RESTART";  // 设密后待重启标记
static NSString *const HFKeyHideEnabled   = @"YZFAIU_HF_HIDE_ENABLED";   // 隐藏好友开关
static NSString *const HFKeyPluginHidden  = @"YZFAIU_HF_PLUGIN_HIDDEN";  // 是否隐藏插件自身
static NSString *const HFKeyHiddenUIDs    = @"YZFAIU_HF_HIDDEN_UIDS";    // 需隐藏的好友 UID 数组

#pragma mark - 管理器接口
@interface HideFriendsManager : NSObject
+ (instancetype)shared;

- (BOOL)isSetupDone;
- (void)completeSetupWithPassword:(NSString *)pwd;   // 首次设密：写密码+置 needsRestart
- (BOOL)verifyPassword:(NSString *)pwd;              // 校验密码
- (void)setPassword:(NSString *)pwd;                 // 修改密码

- (BOOL)needsRestart;
- (void)markRestarted;                               // 启动后清除 needsRestart，使入口可见

- (BOOL)hideEnabled;
- (void)setHideEnabled:(BOOL)v;
- (BOOL)pluginHidden;
- (void)setPluginHidden:(BOOL)v;

- (NSSet<NSString *> *)hiddenUIDs;
- (void)addHiddenUID:(NSString *)uid;
- (void)removeHiddenUID:(NSString *)uid;
- (BOOL)shouldHideUID:(NSString *)uid;

@property (nonatomic, assign) BOOL temporarilyRevealed;  // 搜索栏输密码后的本会话临时显示
@end

#pragma mark - 工具函数（在 HideFriendsManager.m 实现）
NSString *HFSHA256(NSString *s);
NSString *HFUidOfModel(id model);     // 从用户/会话模型提取 uid
id       HFFilterArray(id obj);        // 按隐藏名单过滤 NSArray（隐藏开关/临时显示决定）
BOOL     HFCanShowEntry(void);         // 入口是否可见：已设密 && 已重启 && 插件未隐身
void     HFShowToast(NSString *msg);
UIViewController *HFTopViewController(void);
