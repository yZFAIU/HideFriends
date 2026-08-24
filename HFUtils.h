//
//  HFUtils.h
//  HideFriends
//
//  无状态工具层（对齐 DYYYUtils 职责：窗口查找、通用 UI 能力）
//

#import <UIKit/UIKit.h>

@interface HFUtils : NSObject

/// 获取当前顶层可见的控制器（用于弹出设置页等）
+ (UIViewController *)topViewController;

/// 递归遍历视图，隐藏文本中包含关键字的所有子视图（用于按文本隐藏入口）
/// @param keyword 匹配关键字（如「好友」）
/// @param view    遍历起点视图
+ (void)hideViewsContainingText:(NSString *)keyword inView:(UIView *)view;

@end
