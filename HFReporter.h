//
//  HFReporter.h
//  HideFriends
//
//  本地维护模块（纯离线）
//  定时补装注册表 hook（类晚加载也能补上）+ 主动扫描隐藏兜底。
//  不再有任何网络上报、云端配置同步、界面诊断采集。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface HFReporter : NSObject

/// 启动本地维护定时器（%ctor 中调用）
+ (void)start;

@end
