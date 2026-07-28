//
//  HideFriends.m
//  抖音「隐藏好友」独立插件 —— 主逻辑（Substrate-free 实现）
//
//  作者: yZFAIU
//  思路参考: huami1314/DYYY 的「数据模型数组 hook」分层思路；
//           但本插件完全独立，存储键 / 包名 / 入口手势 / 设置面板均与 DYYY 隔离，互不冲突。
//
//  关键设计：所有方法 hook 使用 ObjC runtime 原生 method_setImplementation，
//            不依赖 Substrate。因此同一份产物既可作为越狱 deb（由 Substrate 加载），
//            也可作为 TrollFools 的 diylib 直接注入（无需 Substrate）。
//

#import "HideFriends.h"
#import "HideFriendsSettingViewController.h"
#import <stdlib.h>
#import <objc/runtime.h>

#pragma mark - 前置声明
static void HFPresentSettings(void);
static void HFPresentSetup(void);
static UIViewController *hf_presenterVC(void);

#pragma mark - 列表 / 会话 hook 配置
// 每一项 = @[ 类名, 返回“用户/会话模型数组”的方法名 ]
// ⚠️ 抖音不同版本类名/方法名不同，请用你本机的 AwemeHeaders 核对并替换下面这些候选名。
//    若类或方法不存在，hook 会自动跳过（不会崩溃）。
static NSArray *HFArrayHookConfig(void) {
    return @[
        // 关注 / 粉丝 / 朋友 列表
        @[@"AWEUserRelationListViewController", @"users"],
        @[@"AWEUserRelationListViewController", @"relationUsers"],
        @[@"AWEFriendsViewController",          @"friends"],
        @[@"AWEUserFollowListViewController",  @"follows"],
        @[@"AWEUserFollowListViewController",  @"users"],
        @[@"AWEUserFansListViewController",     @"fans"],
        @[@"AWEUserFansListViewController",     @"users"],
        // 会话 / 消息 列表（隐藏后看不到聊天框、消息、电话）
        @[@"AWEIMConversationListViewController", @"conversations"],
        @[@"AWEIMConversationListViewController", @"conversationList"],
        @[@"IESIMConversationListViewController", @"conversationList"],
        @[@"IESIMConversationListViewController", @"conversations"],
    ];
}

#pragma mark - Substrate-free 原生 swizzle
// 替换实例方法的 IMP，返回原 IMP（等价 MSHookMessageEx 的 getter 语义，但不依赖 Substrate）。
static IMP hf_replaceMethod(Class cls, SEL sel, IMP replacement) {
    if (!cls || !sel || !replacement) return NULL;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    return method_setImplementation(m, replacement);
}

#pragma mark - 原始 IMP 记录
typedef struct { Class cls; SEL sel; IMP orig; } HFHook;
static HFHook hf_hooks[256];
static int    hf_hookCount = 0;

static IMP hf_lookupOrig(id self, SEL _cmd) {
    for (int i = 0; i < hf_hookCount; i++) {
        if (hf_hooks[i].sel == _cmd && [self isKindOfClass:hf_hooks[i].cls]) return hf_hooks[i].orig;
    }
    return NULL;
}

// 数组 getter 替换：调用原 getter 后对结果按隐藏名单过滤
static id hf_getterReplacement(id self, SEL _cmd) {
    IMP o = hf_lookupOrig(self, _cmd);
    if (!o) return nil;
    return HFFilterArray(((id (*)(id, SEL))o)(self, _cmd));
}
// 数组 setter 替换：先把传入数组过滤，再交给原 setter
static void hf_setterReplacement(id self, SEL _cmd, id arg) {
    IMP o = hf_lookupOrig(self, _cmd);
    if (!o) return;
    ((void (*)(id, SEL, id))o)(self, _cmd, HFFilterArray(arg));
}

static void hf_installArrayHooks(void) {
    for (NSArray *e in HFArrayHookConfig()) {
        NSString *clsName = e[0];
        NSString *selName = e[1];
        Class cls = NSClassFromString(clsName);
        if (!cls) continue;
        SEL sel = NSSelectorFromString(selName);
        if (![cls instancesRespondToSelector:sel]) continue;

        // 去重
        BOOL dup = NO;
        for (int i = 0; i < hf_hookCount; i++)
            if (hf_hooks[i].cls == cls && hf_hooks[i].sel == sel) dup = YES;
        if (dup || hf_hookCount >= 256) continue;

        IMP orig = hf_replaceMethod(cls, sel, (IMP)hf_getterReplacement);
        if (!orig) continue;
        hf_hooks[hf_hookCount++] = (HFHook){cls, sel, orig};

        // 同时 hook 对应的 setter（setXxx:），双向过滤
        NSString *setter = [NSString stringWithFormat:@"set%@:", [selName capitalizedString]];
        SEL ssel = NSSelectorFromString(setter);
        if ([cls instancesRespondToSelector:ssel] && hf_hookCount < 256) {
            IMP orig2 = hf_replaceMethod(cls, ssel, (IMP)hf_setterReplacement);
            if (orig2) hf_hooks[hf_hookCount++] = (HFHook){cls, ssel, orig2};
        }
    }
}

#pragma mark - 入口：三指长按窗口（区别于 DYYY 的双指长按，互不冲突）
// 不 swizzle UIWindow，改为监听 UIWindowDidBecomeKeyNotification，对成为 key 的窗口添加手势，
// 避免对系统窗口方法做替换，更稳定、零侵入。
static char kHFEntryKey;
@interface UIWindow (HFEntry)
- (void)hf_addEntryGestureIfNeeded;
- (void)hf_entryGesture:(UILongPressGestureRecognizer *)g;
@end
@implementation UIWindow (HFEntry)
- (void)hf_addEntryGestureIfNeeded {
    if (objc_getAssociatedObject(self, &kHFEntryKey)) return;
    objc_setAssociatedObject(self, &kHFEntryKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UILongPressGestureRecognizer *g =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(hf_entryGesture:)];
    g.numberOfTouchesRequired = 3;     // 三指：与 DYYY 的双指长按区分
    g.minimumPressDuration = 1.2;
    [self addGestureRecognizer:g];
}
- (void)hf_entryGesture:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (HFCanShowEntry()) HFPresentSettings();
}
@end

#pragma mark - 搜索栏输入密码 -> 临时恢复/隐藏好友显示
// 两类搜索控制器都尝试 hook（按版本存在性自动跳过）
static void hf_handleSearchReveal(NSString *text, id searchBar) {
    HideFriendsManager *m = [HideFriendsManager shared];
    if (![m isSetupDone]) return;
    if (text.length > 0 && [m verifyPassword:text]) {
        BOOL next = ![m temporarilyRevealed];
        [m setTemporarilyRevealed:next];
        HFShowToast(next ? @"已恢复好友显示" : @"已恢复隐藏");
        if ([searchBar respondsToSelector:@selector(setText:)]) {
            [searchBar setText:@""];
        }
        // 插件处于隐身态时，输密码同时打开设置，便于管理
        if (next && [m pluginHidden]) HFPresentSettings();
    }
}

// searchBar:textDidChange: 的替换实现（两个类各持一份 orig IMP）
static IMP hf_origAWE = NULL;
static void hf_AWE_searchTextDidChange(id self, SEL _cmd, id searchBar, NSString *text) {
    if (hf_origAWE) ((void (*)(id, SEL, id, id))hf_origAWE)(self, _cmd, searchBar, text);
    hf_handleSearchReveal(text, searchBar);
}
static IMP hf_origAWENew = NULL;
static void hf_AWENew_searchTextDidChange(id self, SEL _cmd, id searchBar, NSString *text) {
    if (hf_origAWENew) ((void (*)(id, SEL, id, id))hf_origAWENew)(self, _cmd, searchBar, text);
    hf_handleSearchReveal(text, searchBar);
}

static void hf_installSearchHooks(void) {
    Class c1 = NSClassFromString(@"AWESearchViewController");
    if (c1) hf_origAWE = hf_replaceMethod(c1, @selector(searchBar:textDidChange:), (IMP)hf_AWE_searchTextDidChange);
    Class c2 = NSClassFromString(@"AWENewSearchViewController");
    if (c2) hf_origAWENew = hf_replaceMethod(c2, @selector(searchBar:textDidChange:), (IMP)hf_AWENew_searchTextDidChange);
}

#pragma mark - 设置页 / 首启设密
void HFPresentSettings(void) {
    UIViewController *p = hf_presenterVC();
    if (!p) return;
    HideFriendsSettingViewController *vc = [[HideFriendsSettingViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [p presentViewController:nav animated:YES completion:nil];
}

static void HFPresentSetup(void) {
    UIViewController *p = hf_presenterVC();
    if (!p) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"设置隐藏好友密码"
                                                              message:@"该密码用于开关隐藏功能，请牢记。"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){ t.secureTextEntry = YES; t.placeholder = @"输入密码"; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){ t.secureTextEntry = YES; t.placeholder = @"再次输入"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *ac){
        NSString *pw1 = a.textFields[0].text ?: @"";
        NSString *pw2 = a.textFields[1].text ?: @"";
        if (pw1.length < 1 || ![pw1 isEqualToString:pw2]) {
            HFShowToast(@"密码无效或不一致");
            // 不置已展示标记，下次 DidBecomeActive 再弹，避免一次失败后卡死
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                          dispatch_get_main_queue(), ^{ HFPresentSetup(); });
            return;
        }
        [[HideFriendsManager shared] completeSetupWithPassword:pw1];
        HFShowToast(@"设置成功，正在重启…");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ exit(0); });   // 重启后入口才可见
    }]];
    [p presentViewController:a animated:YES completion:nil];
}

// 找到当前可用于 present 的顶层 VC（优先 keyWindow.rootViewController，回退到 HFTopViewController）
static UIViewController *hf_presenterVC(void) {
    UIWindow *kw = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { kw = w; break; }
    }
    if (!kw) kw = [UIApplication sharedApplication].keyWindow;
    if (kw && kw.rootViewController) {
        UIViewController *vc = kw.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        return vc;
    }
    return HFTopViewController();
}

#pragma mark - 入口构造（不依赖 Substrate，纯 C 构造函数）
static BOOL hf_setupShown = NO;

__attribute__((constructor)) static void hf_ctor(void) {
    // 1) 入口手势：监听窗口成为 key，给每个窗口添加三指长按
    [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note){
        id win = note.object;
        if ([win isKindOfClass:[UIWindow class]]) [win hf_addEntryGestureIfNeeded];
    }];

    // 2) 等 App 启动完成后再安装 hook，确保抖音各类已加载（兼容 TrollFools / Substrate 注入时机）
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note){
        HideFriendsManager *m = [HideFriendsManager shared];
        [m markRestarted];                 // 启动后清除 needsRestart，使入口可见
        hf_installArrayHooks();
        hf_installSearchHooks();

        // 3) 首次使用：未设密则在 App 进入可交互态后弹窗（带重试，确保 keyWindow 就绪）
        if (![m isSetupDone]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                              object:nil queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note){
                if (hf_setupShown) return;
                if (!hf_presenterVC()) return;   // 还没就绪，等下次 active
                hf_setupShown = YES;
                HFPresentSetup();
            }];
        }
    }];
}
