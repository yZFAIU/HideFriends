//
//  HFBlacklist.h
//  HideFriends
//
//  按抖音号黑名单精确隐藏的核心工具
//  - 存储：NSUserDefaults NSArray<NSString *>
//  - 匹配：鸭子类型匹配（不依赖 AWEUserModel 类名，对象具备
//          shortID / uniqueID / nickname / secUid 字符串字段即视为用户对象）
//  - 拦截点：UICollectionView / UITableView 的 willDisplayCell 阶段
//  - 性能：v1.0.5 起彻底移除深反射，改为白名单 key 轻量查找，
//          避免 Swift 模型 KVC 重负载导致主线程卡顿（watchdog 杀进程）
//  - 诊断：后台线程执行，完成后回调主线程
//

#import <UIKit/UIKit.h>
#import "AwemeHeaders.h"

@interface HFBlacklist : NSObject

#pragma mark - 存储

/// 获取当前黑名单（去空、去重；返回新数组，外部可修改）
+ (NSArray<NSString *> *)blockedIDs;

/// 添加一个抖音号（已存在则不重复添加；添加后自动启用黑名单开关）
+ (void)addBlockedID:(NSString *)douyinID;

/// 移除一个抖音号
+ (void)removeBlockedID:(NSString *)douyinID;

#pragma mark - 匹配（鸭子类型）

/// 判断一个用户对象是否命中黑名单（不依赖具体类名）
+ (BOOL)isUserObjectBlocked:(id)userObj;

/// 在任意对象中轻量查找「用户对象」（白名单 key，最多两级；不深反射）
+ (id)findUserObjectInObject:(id)obj;

/// 隐藏包含黑名单用户的 cell（设 alpha=0 + 高度压缩）
+ (void)hideCellIfContainsBlockedUser:(UIView *)cell;

/// v1.3.39：匹配并隐藏（单次 findUserObjectInObject，返回命中详情供上报）。
/// 供 willDisplayCell 使用，避免双重反射导致滚动卡顿。
+ (NSDictionary *)matchAndHideCellIfBlocked:(UIView *)cell;

/// v1.3.6 主动扫描隐藏：遍历所有可见列表 cell，命中即隐藏+上报（不依赖 willDisplayCell）
+ (void)scanAndHideVisibleCells;

/// 返回 cell 中命中黑名单的详情（v1.1.0 新增，供上报模块使用）
/// @return @{@"blocked_id":..., @"matched_field":...}，未命中返回 nil
+ (NSDictionary *)blockedMatchInCell:(UIView *)cell;

#pragma mark - v1.3.0 用户注册表（方案D：UID↔抖音号映射）

/// 全局注册一个用户对象（读取其 uid/uniqueID/shortID/nickname 入表）
+ (void)registerUserObject:(id)userObj;

/// 根据 UID 查询抖音号（uniqueID/shortID），查不到返回 nil
+ (NSString *)douyinIDForUid:(NSString *)uid;

/// 根据 UID 查询昵称
+ (NSString *)nicknameForUid:(NSString *)uid;

/// 初始化注册表 hook（安全 swizzle AWEUserModel 的 setter，方法存在才替换）
+ (void)setupUserRegistry;

/// v1.3.2：返回已捕获用户列表（uid/uniqueID/shortID/nickname），供设置页选择
+ (NSArray<NSDictionary *> *)knownUsers;

/// v1.3.47：返回互关好友列表（uid/uniqueID/shortID/nickname），供「添加好友」页选择
+ (NSArray<NSDictionary *> *)mutualFollowUsers;

/// v1.3.47：互关列表 cell 的用户标记为互关好友（willDisplayCell 无条件调用，自包含查找+登记）
+ (void)markMutualFollowCell:(UIView *)cell userObj:(id)userObj;

#pragma mark - 通知与刷新

/// 广播黑名单变更通知（设置页增删后调用，触发已加载列表 reloadData）
+ (void)postBlacklistChangedNotification;

/// 遍历视图层级 reload 所有 collectionView/tableView
+ (void)reloadAllListsInView:(UIView *)view;

#pragma mark - UI 文本匹配（v1.3.11）

/// 黑名单显示名集合（抖音号 + 注册表反查昵称，UI 文本匹配用）
+ (NSArray<NSString *> *)blacklistDisplayNames;

@end
