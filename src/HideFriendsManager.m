//
//  HideFriendsManager.m
//  状态管理 + 工具函数实现
//
//  作者: yZFAIU
//

#import "HideFriends.h"
#import <CommonCrypto/CommonDigest.h>

@implementation HideFriendsManager

+ (instancetype)shared {
    static id i = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ i = [[self alloc] init]; });
    return i;
}

- (NSUserDefaults *)df { return [NSUserDefaults standardUserDefaults]; }

#pragma mark - 设置 / 门禁
- (BOOL)isSetupDone { return [[self df] boolForKey:HFKeySetupDone]; }

- (void)completeSetupWithPassword:(NSString *)pwd {
    [[self df] setObject:(HFSHA256(pwd) ?: @"") forKey:HFKeyPassword];   // 仅存 SHA256，不落明文
    [[self df] setBool:YES forKey:HFKeySetupDone];
    [[self df] setBool:YES forKey:HFKeyNeedsRestart];   // 标记：重启后入口才可见
    [[self df] synchronize];
}

- (void)setPassword:(NSString *)pwd {
    [[self df] setObject:(HFSHA256(pwd) ?: @"") forKey:HFKeyPassword];
    [[self df] synchronize];
}

- (BOOL)verifyPassword:(NSString *)pwd {
    NSString *s = [[self df] stringForKey:HFKeyPassword];
    NSString *h = HFSHA256(pwd);
    return (s.length > 0 && h.length > 0 && [s isEqualToString:h]);
}

- (BOOL)needsRestart { return [[self df] boolForKey:HFKeyNeedsRestart]; }

- (void)markRestarted {
    if ([self needsRestart]) {
        [[self df] setBool:NO forKey:HFKeyNeedsRestart];
        [[self df] synchronize];
    }
}

#pragma mark - 开关
- (BOOL)hideEnabled { return [[self df] boolForKey:HFKeyHideEnabled]; }
- (void)setHideEnabled:(BOOL)v { [[self df] setBool:v forKey:HFKeyHideEnabled]; [[self df] synchronize]; }

- (BOOL)pluginHidden { return [[self df] boolForKey:HFKeyPluginHidden]; }
- (void)setPluginHidden:(BOOL)v { [[self df] setBool:v forKey:HFKeyPluginHidden]; [[self df] synchronize]; }

#pragma mark - 隐藏名单
- (NSSet<NSString *> *)hiddenUIDs {
    NSArray *a = [[self df] arrayForKey:HFKeyHiddenUIDs];
    return a ? [NSSet setWithArray:a] : [NSSet set];
}
- (void)addHiddenUID:(NSString *)uid {
    if (uid.length == 0) return;
    NSMutableArray *a = [[[self df] arrayForKey:HFKeyHiddenUIDs] mutableCopy] ?: [NSMutableArray new];
    if (![a containsObject:uid]) [a addObject:uid];
    [[self df] setObject:a forKey:HFKeyHiddenUIDs];
    [[self df] synchronize];
}
- (void)removeHiddenUID:(NSString *)uid {
    NSMutableArray *a = [[[self df] arrayForKey:HFKeyHiddenUIDs] mutableCopy] ?: [NSMutableArray new];
    [a removeObject:uid];
    [[self df] setObject:a forKey:HFKeyHiddenUIDs];
    [[self df] synchronize];
}
- (BOOL)shouldHideUID:(NSString *)uid {
    if (uid.length == 0) return NO;
    return [self.hiddenUIDs containsObject:uid];
}

@end

#pragma mark - 工具函数

NSString *HFSHA256(NSString *s) {
    if (!s) return nil;
    const char *c = [s UTF8String];
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256((const void *)c, (CC_LONG)strlen(c), d);
    NSMutableString *o = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [o appendFormat:@"%02x", d[i]];
    return o;
}

// 从用户/会话模型提取 uid（兼容多种常见字段名与嵌套结构）
NSString *HFUidOfModel(id model) {
    if (!model) return nil;
    NSArray *keys = @[@"uid", @"sec_uid", @"userID", @"userId", @"uniqueID",
                      @"conversationID", @"conversationId", @"peerUserID", @"peerUserId"];
    for (NSString *k in keys) {
        SEL sel = NSSelectorFromString(k);
        if ([model respondsToSelector:sel]) {
            id v = [model valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [v length]) return v;
            if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
        }
    }
    NSArray *nested = @[@"peerUser", @"user", @"owner", @"contact", @"model", @"coreInfo", @"targetUser"];
    for (NSString *k in nested) {
        SEL sel = NSSelectorFromString(k);
        if ([model respondsToSelector:sel]) {
            id v = [model valueForKey:k];
            if (v) {
                NSString *u = HFUidOfModel(v);
                if (u) return u;
            }
        }
    }
    return nil;
}

// 过滤数组：隐藏开关关闭 或 本会话临时显示时原样返回
id HFFilterArray(id obj) {
    if (![obj isKindOfClass:[NSArray class]]) return obj;
    HideFriendsManager *m = [HideFriendsManager shared];
    if (![m hideEnabled]) return obj;
    if (m.temporarilyRevealed) return obj;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:[obj count]];
    for (id model in (NSArray *)obj) {
        NSString *uid = HFUidOfModel(model);
        if (uid && [m shouldHideUID:uid]) continue;   // 命中隐藏名单 -> 丢弃
        [out addObject:model];
    }
    return out;
}

BOOL HFCanShowEntry(void) {
    HideFriendsManager *m = [HideFriendsManager shared];
    return [m isSetupDone] && ![m needsRestart] && ![m pluginHidden];
}

void HFShowToast(NSString *msg) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w || msg.length == 0) return;
    UILabel *l = [[UILabel alloc] init];
    l.text = msg;
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont systemFontOfSize:14];
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    l.layer.cornerRadius = 8;
    l.clipsToBounds = YES;
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 0;
    CGSize s = [l sizeThatFits:CGSizeMake(280, 80)];
    CGFloat ww = MIN(s.width + 30, 300);
    l.frame = CGRectMake((w.bounds.size.width - ww) / 2, w.bounds.size.height - 130, ww, MAX(s.height + 20, 36));
    [w addSubview:l];
    l.alpha = 0;
    [UIView animateWithDuration:0.25 animations:^{ l.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)1.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ l.alpha = 0; } completion:^(BOOL d) { [l removeFromSuperview]; }];
    });
}

UIViewController *HFTopViewController(void) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}
