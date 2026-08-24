//
//  AwemeHeaders.h
//  HideFriends
//
//  抖音私有类声明集中地（遵循 DYYY 工程规范：
//  所有新增的抖音类/方法声明必须写入本文件，禁止散落各处）
//
//  说明：以下类名与方法提取自 DYYY 仓库（已在抖音 36.5.0 验证存在）。
//  部分方法签名可能随抖音版本变化，上机前建议用 class-dump / FLEX
//  在目标版本上实测确认（详见 README「如何实测类名」一节）。
//

#ifndef AwemeHeaders_h
#define AwemeHeaders_h

#import <UIKit/UIKit.h>

// ============================================================
// 好友推荐相关（AFD 系列）
// 作用位置：推荐流/搜索结果中的「你可能认识的人」卡片、标签、入口
// ============================================================

/// 好友推荐标签视图
@interface AFDRecommendToFriendTagView : UIView
@end

/// 好友推荐入口标签
@interface AFDRecommendToFriendEntranceLabel : UIView
@end

/// 好友推荐标签视图（另一种）
@interface AFDFriendRecommendTagView : UIView
@end

/// 快速回复视图（好友分享私信场景）
@interface AFDNewFastReplyView : UIView
@end

// ============================================================
// 消息 / 私信（IM）相关（AWEIM 系列）
// 作用位置：消息 Tab、私信会话列表的横幅与侧边栏
// ============================================================

/// 私信 Tab 推送横幅
@interface AWEIMMessageTabOptPushBannerView : UIView
@end

/// 私信 Tab 侧边栏
@interface AWEIMMessageTabSideBarView : UIView
@end

// ============================================================
// 侧边栏（左滑菜单）
// 作用位置：侧边栏中的「我的好友」等入口
// ============================================================

/// 左侧边栏控制器
@interface AWELeftSideBarViewController : UIViewController
@property(nonatomic, strong) UICollectionView *collectionView;
@end

/// 左侧边栏顶部图标横排视图（含「设置」按钮；可在此旁注入 HF 入口）
@interface AWELeftSideBarTopIconHorizontalView : UIView
@end

// ============================================================
// 关注用户卡片（BDP 系列，v1.1.5 新增）
// 作用位置：推荐流/搜索结果中的「你可能认识的人 / 关注用户」卡片
// 依据：auto_scan 上报的抖音 39.9.0 真实类清单（BDPFollowUser* 已确认加载）
// ============================================================

/// 关注用户卡片（横滑变体 _HG）
@interface BDPFollowUserView_HG : UIView
@end

/// 关注用户视图
@interface BDPFollowUserView : UIView
@end

/// 关注用户卡片
@interface BDPFollowUserCard : UIView
@end

// ============================================================
// 个人主页 Tab（作品/喜欢/关注/粉丝）
// 作用位置：个人主页顶部 Tab 栏
// ============================================================

/// 用户主页 Tab 列表模型
@interface AWEUserTabListModel : NSObject
@property(nonatomic, copy) NSString *profileLandingTab;
@end

// ============================================================
// 数据模型
// ============================================================

/// 用户模型
@interface AWEUserModel : NSObject
@property(nonatomic, copy) NSString *nickname;
@property(nonatomic, copy) NSString *shortID;     // 抖音号（用户可设置）
@property(nonatomic, copy) NSString *uniqueID;    // 数字 UID（系统分配）
@property(nonatomic, copy) NSString *signature;
@property(nonatomic, strong) NSURL *avatarMedium;
@end

/// 视频/图文作品模型（含作者 AWEUserModel）
@interface AWEAwemeModel : NSObject
@property(nonatomic, strong) AWEUserModel *author;
@property(nonatomic, strong) id video;
@property(nonatomic, copy) NSString *desc;
@end

// ============================================================
// UIWindow 插件入口 Category（HideFriends 自扩展方法声明）
// 实现位于 HideFriends.xm 的 %group HFSettingGestureGroup 中
// ============================================================

@interface UIWindow (HideFriendsEntry)

/// 初始化插件入口（悬浮按钮 + 双指长按），每个窗口只执行一次
- (void)hf_setupPluginEntry;

/// 打开设置页
- (void)hf_openSettings;

/// 双指长按手势处理
- (void)hf_handleDoubleFingerLongPress:(UILongPressGestureRecognizer *)gesture;

/// 悬浮按钮拖拽处理
- (void)hf_dragFloatingButton:(UIPanGestureRecognizer *)pan;

@end

#endif
