//
//  HFConstants.h
//  HideFriends
//
//  常量集中定义：开关 Key、读取宏、通知名
//  遵循 DYYY 工程规范：常量统一在此维护，命名带 HF 前缀
//

#ifndef HFConstants_h
#define HFConstants_h

// ============================================================
// 开关 Key（NSUserDefaults）
// ============================================================

/// 隐藏「好友推荐」卡片/标签/入口（AFD 系列视图）
#define HF_KEY_HIDE_FRIEND_RECOMMEND @"HFHideFriendRecommend"

/// 隐藏「消息/私信」入口、推送横幅、侧边栏（AWEIM 系列视图）
#define HF_KEY_HIDE_MESSAGE_ENTRY @"HFHideMessageEntry"

/// 隐藏「关注/粉丝」列表入口（个人主页 Tab 与侧边栏入口）
#define HF_KEY_HIDE_FRIEND_LIST @"HFHideFriendList"

/// 总开关：一键隐藏所有好友相关内容（打开后等同于以上三项全开）
#define HF_KEY_HIDE_ALL_FRIENDS @"HFHideAllFriends"

/// 启用按抖音号黑名单隐藏（v1.0.2 新增）
#define HF_KEY_BLACKLIST_ENABLED @"HFBlacklistEnabled"

/// 黑名单抖音号列表（NSUserDefaults 存 NSArray<NSString *>）
#define HF_KEY_BLACKLIST_IDS @"HFBlacklistIDs"

// ============================================================
// 开关读取宏（对齐 DYYY 的 DYYYGetBool 用法）
// ============================================================

#define HFGetBool(key) [[NSUserDefaults standardUserDefaults] boolForKey:(key)]
#define HFSetBool(key, val) [[NSUserDefaults standardUserDefaults] setBool:(val) forKey:(key)]

/// 统一判断：单项开关或总开关任一开启即生效
#define HFShouldHide(key) (HFGetBool(HF_KEY_HIDE_ALL_FRIENDS) || HFGetBool(key))

// ============================================================
// 通知名
// ============================================================

/// 设置变更通知（设置页改动开关后广播，Hook 内可监听刷新 UI）
#define HF_SETTINGS_DID_CHANGE_NOTIFICATION @"HFSettingsDidChangeNotification"

/// 黑名单变更通知（添加/删除抖音号后广播，Hook 侧收到后 reload 已加载的列表）
#define HF_BLACKLIST_CHANGED_NOTIFICATION @"HFBlacklistChangedNotification"

#endif
