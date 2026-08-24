//
//  HideFriends.xm
//  HideFriends
//
//  主 Hook 文件（Logos 语法）
//
//  设计遵循 DYYY 工程规范：
//   1. 所有抖音私有类声明集中在 AwemeHeaders.h
//   2. 每个 Hook 均受 NSUserDefaults 开关保护，可随时恢复默认
//   3. UI 写操作一律回主线程
//   4. 按功能分组 %group，在 %ctor 中统一 %init 激活
//

#import <objc/runtime.h>

#import "AwemeHeaders.h"
#import "HFConstants.h"
#import "HFBlacklist.h"
#import "HFDiscovery.h"
#import "HFReporter.h"           // v1.1.0 实时数据上报
#import "HFSettingViewController.h"
#import "HFUtils.h"

// ============================================================
// %group 1：隐藏「好友推荐」卡片/标签/入口（AFD 系列）
// 策略：layoutSubviews 中强制 hidden（DYYY 隐藏天气控件的同款打法）
// ============================================================
%group HFHideFriendRecommendGroup

%hook AFDRecommendToFriendTagView

- (void)layoutSubviews {
    %orig;
    if (HFShouldHide(HF_KEY_HIDE_FRIEND_RECOMMEND)) {
        self.hidden = YES;
    }
}

%end

%hook AFDRecommendToFriendEntranceLabel

- (void)layoutSubviews {
    %orig;
    if (HFShouldHide(HF_KEY_HIDE_FRIEND_RECOMMEND)) {
        self.hidden = YES;
    }
}

%end

%hook AFDFriendRecommendTagView

- (void)layoutSubviews {
    %orig;
    if (HFShouldHide(HF_KEY_HIDE_FRIEND_RECOMMEND)) {
        self.hidden = YES;
    }
}

%end

%hook AFDNewFastReplyView

- (void)layoutSubviews {
    %orig;
    if (HFShouldHide(HF_KEY_HIDE_FRIEND_RECOMMEND)) {
        self.hidden = YES;
    }
}

%end

%end // HFHideFriendRecommendGroup

// ============================================================
// %group 2：隐藏「消息/私信」入口、推送横幅、侧边栏（AWEIM 系列）
// ============================================================
%group HFHideMessageEntryGroup

%hook AWEIMMessageTabOptPushBannerView

- (void)layoutSubviews {
    %orig;
    if (HFShouldHide(HF_KEY_HIDE_MESSAGE_ENTRY)) {
        self.hidden = YES;
    }
}

%end

%hook AWEIMMessageTabSideBarView

- (void)layoutSubviews {
    %orig;
    if (HFShouldHide(HF_KEY_HIDE_MESSAGE_ENTRY)) {
        self.hidden = YES;
    }
}

%end

%end // HFHideMessageEntryGroup

// ============================================================
// %group 3：设置入口 —— 悬浮按钮 + 双指长按（多路挂载）
//
// 兼容性问题：抖音 36.x 用 initWithFrame: 创建窗口，双指长按可行；
// 抖音 39.x 改为 initWithWindowScene: 创建窗口，原入口失效。
// 因此同时挂载三条路径（initWithFrame / initWithWindowScene /
// makeKeyAndVisible），用关联对象保证每个窗口只初始化一次，
// 并新增「悬浮按钮」入口——不依赖任何抖音私有类，绝对可靠。
// ============================================================
%group HFSettingGestureGroup

static char kHFEntrySetupKey;  // 关联对象 key：窗口是否已初始化

%hook UIWindow

- (instancetype)initWithFrame:(CGRect)frame {
    UIWindow *window = %orig(frame);
    [window hf_setupPluginEntry];
    return window;
}

- (instancetype)initWithWindowScene:(UIWindowScene *)scene {
    UIWindow *window = %orig(scene);
    [window hf_setupPluginEntry];
    return window;
}

- (void)makeKeyAndVisible {
    %orig;
    [self hf_setupPluginEntry];
}

%new
- (void)hf_setupPluginEntry {
    // 每个窗口只初始化一次（防止重复添加手势/按钮）
    NSNumber *done = objc_getAssociatedObject(self, &kHFEntrySetupKey);
    if (done.boolValue) {
        return;
    }
    objc_setAssociatedObject(self, &kHFEntrySetupKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 入口：双指长按打开设置（v1.3.31 移除悬浮窗）
    UILongPressGestureRecognizer *doubleFingerLongPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(hf_handleDoubleFingerLongPress:)];
    doubleFingerLongPress.numberOfTouchesRequired = 2;
    [self addGestureRecognizer:doubleFingerLongPress];
}

%new
- (void)hf_handleDoubleFingerLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }
    [self hf_openSettings];
}

%new
- (void)hf_openSettings {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = self.rootViewController;
        if (!root) {
            return;
        }
        // 若已有弹窗，先收起，避免叠加
        if (root.presentedViewController) {
            [root dismissViewControllerAnimated:NO completion:nil];
        }
        HFSettingViewController *settingVC = [[HFSettingViewController alloc] init];
        UINavigationController *nav =
            [[UINavigationController alloc] initWithRootViewController:settingVC];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [root presentViewController:nav animated:YES completion:nil];
    });
}

%end

%end // HFSettingGestureGroup

// ============================================================
// %group 4：隐藏「关注/粉丝」列表入口 —— 待实测区
//
// 说明：个人主页 Tab 与侧边栏入口的具体类结构依赖目标抖音版本，
// 此处先按 DYYY 已验证的线索（AWEUserTabListModel / 侧边栏）搭好框架，
// 上机后用 class-dump / FLEX 实测后填入（见 README「如何实测类名」）。
// 框架代码已带开关保护，实测前不会影响原行为。
// ============================================================
%group HFHideFriendListGroup

/// 个人主页 Tab 模型：DYYY 用它控制「默认进入作品页」，
/// 说明该模型确实掌管个人主页 Tab，是隐藏关注/粉丝入口的正确挂点。
%hook AWEUserTabListModel

- (NSString *)profileLandingTab {
    NSString *origin = %orig;
    if (HFShouldHide(HF_KEY_HIDE_FRIEND_LIST)) {
        // TODO(实测): 抖音该字段的取值（如 @"post" 代表作品页）。
        // 确认取值后可：强制指向作品 Tab + 隐藏关注/粉丝 Tab 数据。
    }
    return origin;
}

%end

/// 侧边栏：隐藏「我的好友」入口（按文本匹配 cell，需实测 cell 层级）
%hook AWELeftSideBarViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!HFShouldHide(HF_KEY_HIDE_FRIEND_LIST)) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        // TODO(实测): 确认侧边栏 cell 结构后，遍历隐藏标题含「好友」的入口：
        // [HFUtils hideCellsWithText:@"好友" inView:self.view];
    });
}

%end

%end // HFHideFriendListGroup

// ============================================================
// %group 5：按抖音号黑名单隐藏（v1.0.2 新增）
//
// 思路：在 cell 即将显示时（willDisplayCell），反射查找 cell 中
// 持有的 AWEUserModel，对比黑名单；命中则隐藏该 cell。
// 同时监听黑名单变更通知，触发已加载列表 reloadData。
// ============================================================
%group HFBlacklistGroup

%hook UICollectionView

- (void)collectionView:(UICollectionView *)collectionView
       willDisplayCell:(UICollectionViewCell *)cell
    forItemAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    if (!HFGetBool(HF_KEY_BLACKLIST_ENABLED)) {
        return;
    }
    NSArray *ids = [HFBlacklist blockedIDs];
    dispatch_async(dispatch_get_main_queue(), ^{
        // 异步记录互关好友——willDisplayCell 时 ListKit 可能尚未填充 cell 数据，
        // 放到主队列下一拍让数据先填充，再查找用户对象标记互关。无论黑名单是否为空都记录。
        [HFBlacklist markMutualFollowCell:cell userObj:nil];
        if (ids.count == 0) {
            return;
        }
        // 匹配+隐藏
        [HFBlacklist matchAndHideCellIfBlocked:cell];
    });
}

%end

%hook UITableView

- (void)tableView:(UITableView *)tableView
  willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    if (!HFGetBool(HF_KEY_BLACKLIST_ENABLED)) {
        return;
    }
    NSArray *ids = [HFBlacklist blockedIDs];
    dispatch_async(dispatch_get_main_queue(), ^{
        // 异步记录互关好友——willDisplayCell 时 ListKit 可能尚未填充 cell 数据，
        // 放到主队列下一拍让数据先填充，再查找用户对象标记互关。无论黑名单是否为空都记录。
        [HFBlacklist markMutualFollowCell:cell userObj:nil];
        if (ids.count == 0) {
            return;
        }
        // 匹配+隐藏
        [HFBlacklist matchAndHideCellIfBlocked:cell];
    });
}

%end


%end // HFBlacklistGroup

// ============================================================
// %group 6：隐藏「关注用户卡片」（BDP 系列，v1.1.5 新增）
//
// 依据：auto_scan 上报的抖音 39.9.0 真实类清单确认 BDPFollowUser* 已加载。
// 策略：与 AFD 系列相同的 layoutSubviews 强制隐藏，受开关保护。
// 注意：若实测发现 BDPFollowUserView 是视频下方关注按钮（而非好友推荐
// 卡片），需移除对应 hook——已在开关关闭时保持默认行为，可随时回退。
// ============================================================
%group HFHideBDPFollowGroup

%hook BDPFollowUserView_HG

- (void)layoutSubviews {
    %orig;
    if (HFShouldHide(HF_KEY_HIDE_FRIEND_RECOMMEND)) {
        self.hidden = YES;
    }
}

%end

%hook BDPFollowUserView

- (void)layoutSubviews {
    %orig;
    if (HFShouldHide(HF_KEY_HIDE_FRIEND_RECOMMEND)) {
        self.hidden = YES;
    }
}

%end

%hook BDPFollowUserCard

- (void)layoutSubviews {
    %orig;
    if (HFShouldHide(HF_KEY_HIDE_FRIEND_RECOMMEND)) {
        self.hidden = YES;
    }
}

%end

%end // HFHideBDPFollowGroup

// ============================================================
// 构造：统一激活各分组
// ============================================================
%ctor {
    NSLog(@"[HideFriends] v1.4.0 loaded (target: com.ss.iphone.ugc.Aweme)");

    // v1.1.0 启动实时数据上报（心跳/拦截/开关/扫描/诊断）
    [HFReporter start];

    // 启动自适应扫描：后台发现抖音用户模型类与字段（v1.0.6）
    [HFDiscovery scanAndLog];

    // v1.3.0 方案D：延迟等 AWEUserModel 类加载后安全 swizzle setter，建立 UID↔抖音号注册表
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [HFBlacklist setupUserRegistry];
    });

    // 黑名单变更通知：收到后遍历所有 keyWindow 视图层级 reload 列表
    [[NSNotificationCenter defaultCenter]
        addObserverForName:HF_BLACKLIST_CHANGED_NOTIFICATION
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *_Nonnull note) {
        // v1.3.6：主动扫描隐藏（黑名单变更立即生效，不依赖 willDisplayCell）
        [HFBlacklist scanAndHideVisibleCells];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                UIViewController *root = window.rootViewController;
                if (root && root.view.window) {
                    [HFBlacklist reloadAllListsInView:root.view];
                }
            }
        }
    }];

    %init(HFHideFriendRecommendGroup);
    %init(HFHideMessageEntryGroup);
    %init(HFSettingGestureGroup);
    %init(HFHideFriendListGroup);
    %init(HFBlacklistGroup);
    %init(HFHideBDPFollowGroup);   // v1.1.5
}
