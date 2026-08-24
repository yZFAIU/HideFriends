//
//  HFReporter.m
//  HideFriends
//
//  本地维护模块（纯离线）
//  两个定时器：
//  1) 维护定时器（30s）：补装注册表 hook——AWEUserModel 等类晚加载也能补上
//  2) 扫描定时器（60s）：主动扫描隐藏可见 cell——willDisplayCell 之外的兜底
//  均不上传服务器、不采集诊断、不做网络请求。
//

#import "HFReporter.h"
#import "HFConstants.h"
#import "HFBlacklist.h"

// ---------------- 参数 ----------------
#define HF_HEARTBEAT_INTERVAL   30.0   // 维护间隔（秒）
#define HF_SCAN_INTERVAL        60.0   // 主动扫描隐藏间隔（秒）

static BOOL gStarted = NO;

@implementation HFReporter

#pragma mark - 生命周期

+ (void)start {
    if (gStarted) return;
    gStarted = YES;

    // 维护定时器（后台）：每 30s 补装注册表 hook（幂等，已 hook 类会跳过）
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTimer *t = [NSTimer timerWithTimeInterval:HF_HEARTBEAT_INTERVAL
                                             target:self
                                           selector:@selector(maintainTick)
                                           userInfo:nil
                                            repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:t forMode:NSDefaultRunLoopMode];
        [[NSRunLoop currentRunLoop] run];
    });

    // 扫描定时器（主线程）：每 60s 主动扫描隐藏可见 cell（滚动停止才触发，不卡顿）
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *scanTimer = [NSTimer timerWithTimeInterval:HF_SCAN_INTERVAL
                                                     target:self
                                                   selector:@selector(scanTick)
                                                   userInfo:nil
                                                    repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:scanTimer forMode:NSDefaultRunLoopMode];
    });

    NSLog(@"[HideFriends] HFReporter started (offline local maintenance)");
}

#pragma mark - 定时回调

/// 维护：补装注册表 hook（类晚加载也能补上）
+ (void)maintainTick {
    @try {
        [HFBlacklist setupUserRegistry];
    } @catch (NSException *e) {}
}

/// 主动扫描隐藏可见 cell（willDisplayCell 的兜底）
+ (void)scanTick {
    @try {
        [HFBlacklist scanAndHideVisibleCells];
    } @catch (NSException *e) {}
}

@end
