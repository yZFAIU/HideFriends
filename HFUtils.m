//
//  HFUtils.m
//  HideFriends
//
//  工具方法实现
//

#import "HFUtils.h"

@implementation HFUtils

#pragma mark - 控制器查找

+ (UIViewController *)topViewController {
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:UIWindowScene.class]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow) {
                        keyWindow = window;
                        break;
                    }
                }
                if (keyWindow) {
                    break;
                }
            }
        }
    }
    if (!keyWindow) {
        keyWindow = UIApplication.sharedApplication.keyWindow;
    }

    UIViewController *top = keyWindow.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    if ([top isKindOfClass:UINavigationController.class]) {
        top = [(UINavigationController *)top topViewController];
    }
    return top;
}

#pragma mark - 按文本隐藏视图

+ (void)hideViewsContainingText:(NSString *)keyword inView:(UIView *)view {
    if (!view || keyword.length == 0) {
        return;
    }

    // 若自身是文本类视图且包含关键字，则隐藏
    NSString *labelText = nil;
    if ([view isKindOfClass:UILabel.class]) {
        labelText = ((UILabel *)view).text;
    } else if ([view isKindOfClass:UIButton.class]) {
        labelText = ((UIButton *)view).currentTitle;
    }
    if (labelText.length > 0 && [labelText containsString:keyword]) {
        view.hidden = YES;
        return;
    }

    // 递归子视图
    for (UIView *subview in view.subviews) {
        [self hideViewsContainingText:keyword inView:subview];
    }
}

@end
