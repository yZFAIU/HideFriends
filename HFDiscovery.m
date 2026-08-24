//
//  HFDiscovery.m
//  HideFriends
//
//  实现：objc_copyClassList 扫描 → 关键词过滤 → class_copyIvarList 检查字段名
//  （全部使用纯 runtime C API，不触发任何 KVC，安全且快速，后台线程执行）
//

#import "HFDiscovery.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSMutableArray<Class> *gUserClasses = nil;
static NSMutableArray<Class> *gAwemeClasses = nil;
static NSMutableArray<NSString *> *gIDFields = nil;
static NSMutableArray<NSString *> *gNameFields = nil;
static NSMutableArray<NSString *> *gCellUserKeys = nil;  // cell 上的用户/作品相关属性名
static BOOL gScanFinished = NO;
static dispatch_once_t gScanOnce = 0;

@implementation HFDiscovery

#pragma mark - 字段名归一化（去掉 _ 前缀，转小写）

static NSString *hf_ivarKey(const char *name) {
    if (!name) return @"";
    NSString *s = @(name);
    while ([s hasPrefix:@"_"]) {
        s = [s substringFromIndex:1];
    }
    return s.lowercaseString;
}

static BOOL hf_isIDField(NSString *key) {
    if (key.length == 0) return NO;
    // ID 类字段（精确匹配，去除过宽的 "id" 与 hasPrefix）：
    // 原实现把裸 "id" 和 "shortid*"/"uniqueid*" 等前缀都算作 ID 字段，
    // 导致几乎所有带 id 的模型类都被误判为「用户类」（实测 447 个里大量是
    // Request/Model 误报），进而让注册表 hook 了 410 个无关类。这里收紧为
    // 精确匹配核心 ID 字段。
    if ([key isEqualToString:@"shortid"]) return YES;
    if ([key isEqualToString:@"uniqueid"]) return YES;
    if ([key isEqualToString:@"secuid"]) return YES;
    if ([key isEqualToString:@"uid"]) return YES;
    if ([key isEqualToString:@"douyinid"]) return YES;
    if ([key isEqualToString:@"userid"]) return YES;
    if ([key isEqualToString:@"user_id"]) return YES;
    return NO;
}

static BOOL hf_isNameField(NSString *key) {
    if (key.length == 0) return NO;
    if ([key isEqualToString:@"nickname"]) return YES;
    if ([key isEqualToString:@"name"]) return YES;
    if ([key hasPrefix:@"nickname"] || [key hasPrefix:@"nick_name"]) return YES;
    return NO;
}

#pragma mark - 扫描

+ (void)scanAndLog {
    dispatch_once(&gScanOnce, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self scanSync];
        });
    });
}

+ (void)scanSync {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);

    NSMutableArray<Class> *userClasses = [NSMutableArray array];
    NSMutableArray<Class> *awemeClasses = [NSMutableArray array];
    NSMutableSet<NSString *> *idFieldSet = [NSMutableSet set];
    NSMutableSet<NSString *> *nameFieldSet = [NSMutableSet set];

    for (unsigned i = 0; i < classCount; i++) {
        Class cls = classes[i];
        if (!cls) continue;
        NSString *clsName = NSStringFromClass(cls);
        if (clsName.length == 0) continue;

        // 关键词过滤：只看可能与用户/作品相关的类
        BOOL interesting = NO;
        NSArray *keywords = @[ @"User", @"Aweme", @"Profile", @"Relation", @"Author", @"Creator" ];
        for (NSString *kw in keywords) {
            if ([clsName containsString:kw]) {
                interesting = YES;
                break;
            }
        }
        if (!interesting) continue;

        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(cls, &ivarCount);

        BOOL hasIDField = NO;
        BOOL hasNameField = NO;
        BOOL hasAuthorField = NO;

        for (unsigned j = 0; j < ivarCount; j++) {
            NSString *key = hf_ivarKey(ivar_getName(ivars[j]));
            if (hf_isIDField(key)) {
                hasIDField = YES;
                [idFieldSet addObject:key];
            } else if (hf_isNameField(key)) {
                hasNameField = YES;
                [nameFieldSet addObject:key];
            } else if ([key isEqualToString:@"author"]) {
                hasAuthorField = YES;
            }
        }
        free(ivars);

        if (hasIDField) {
            [userClasses addObject:cls];
        } else if (hasNameField) {
            // 有昵称但无 ID 字段的，也当作用户类候选
            [userClasses addObject:cls];
        } else if (hasAuthorField) {
            [awemeClasses addObject:cls];
        }
    }
    free(classes);

    // 第二遍：扫描 cell 类（类名含 Cell/Item/Feed/Profile）的属性名，
    // 收集「用户/作品相关」属性名 → 动态扩充白名单 key（v1.0.7）
    NSMutableSet<NSString *> *cellKeySet = [NSMutableSet set];
    {
        unsigned int classCount2 = 0;
        Class *classes2 = objc_copyClassList(&classCount2);
        NSArray *cellKeywords = @[ @"Cell", @"Item", @"Feed", @"Profile" ];
        NSArray *userKeyKeywords = @[ @"user", @"author", @"aweme", @"poster", @"owner",
                                      @"creator", @"friend", @"relation", @"target", @"profile" ];
        for (unsigned i = 0; i < classCount2; i++) {
            Class cls = classes2[i];
            if (!cls) continue;
            NSString *clsName = NSStringFromClass(cls);
            if (clsName.length == 0) continue;
            BOOL isCell = NO;
            for (NSString *kw in cellKeywords) {
                if ([clsName containsString:kw]) {
                    isCell = YES;
                    break;
                }
            }
            if (!isCell) continue;
            unsigned int propCount = 0;
            objc_property_t *props = class_copyPropertyList(cls, &propCount);
            for (unsigned j = 0; j < propCount; j++) {
                const char *pn = property_getName(props[j]);
                if (!pn) continue;
                NSString *key = hf_ivarKey(pn);
                if (key.length == 0) continue;
                for (NSString *kw in userKeyKeywords) {
                    if ([key containsString:kw]) {
                        [cellKeySet addObject:key];
                        break;
                    }
                }
            }
            free(props);
        }
        free(classes2);
    }

    // 存入全局（后台线程写，读取在 willDisplayCell 主线程——用锁保护）
    @synchronized (self) {
        gUserClasses = [userClasses copy];
        gAwemeClasses = [awemeClasses copy];
        NSArray *allIDFields = @[ @"shortID", @"uniqueID", @"secUid", @"uid", @"douyinId", @"userId" ];
        NSMutableArray *idFields = [NSMutableArray array];
        for (NSString *d in allIDFields) {
            [idFields addObject:d];
        }
        for (NSString *d in idFieldSet) {
            if (![idFields containsObject:d]) {
                [idFields addObject:d];
            }
        }
        gIDFields = [idFields copy];

        NSMutableArray *nameFields = [NSMutableArray arrayWithObjects:@"nickname", @"name", nil];
        for (NSString *d in nameFieldSet) {
            if (![nameFields containsObject:d]) {
                [nameFields addObject:d];
            }
        }
        gNameFields = [nameFields copy];

        // cell 用户 key：默认白名单 ∪ 扫描发现
        NSMutableArray *cellKeys = [NSMutableArray arrayWithObjects:
            @"user", @"author", @"aweme", @"awemeModel", @"model", @"item", @"data",
            @"userModel", @"targetUser", @"poster", @"owner",
            // v1.3.42：ListKit 载体的用户模型藏在 awelistkit_cellModel / ieseclistkit_preCellModel，
            // 加入第一层候选，关注/粉丝/互关列表 cell 无需深搜也能稳定找到用户对象。
            @"awelistkit_cellModel", @"ieseclistkit_preCellModel", nil];
        for (NSString *k in cellKeySet) {
            if (![cellKeys containsObject:k]) {
                [cellKeys addObject:k];
            }
        }
        gCellUserKeys = [cellKeys copy];

        gScanFinished = YES;
    }

    NSLog(@"[HideFriends] 自适应扫描完成：用户类 %lu 个，作品类 %lu 个，cell用户key %lu 个",
          (unsigned long)userClasses.count, (unsigned long)awemeClasses.count,
          (unsigned long)gCellUserKeys.count);
    NSLog(@"[HideFriends] 用户ID字段: %@", [gIDFields componentsJoinedByString:@","]);
    NSLog(@"[HideFriends] 用户类示例: %@", [self sampleClassNames:userClasses max:10]);
    NSLog(@"[HideFriends] cell用户key: %@",
          [[gCellUserKeys subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)20, gCellUserKeys.count))]
           componentsJoinedByString:@","]);
}

+ (NSString *)sampleClassNames:(NSArray<Class> *)classes max:(NSInteger)max {
    NSMutableArray *names = [NSMutableArray array];
    for (NSInteger i = 0; i < MIN((NSInteger)classes.count, max); i++) {
        [names addObject:NSStringFromClass(classes[i])];
    }
    return [names componentsJoinedByString:@", "];
}

#pragma mark - 查询

+ (BOOL)isDetectedUserClass:(Class)cls {
    if (!cls) return NO;
    // v1.2.0：视图类（UIView 子类，如 cell）绝不视为用户模型——防止关注/粉丝列表
    // cell 被误判为用户对象导致真正的用户模型被跳过
    Class uiv = [UIView class];
    Class c = cls;
    while (c && c != [NSObject class]) {
        if (c == uiv) return NO;
        c = class_getSuperclass(c);
    }
    // v1.2.5：作品模型类（有 author 字段）优先视为 aweme，不当作用户对象——
    // 防止 AWEAwemeModel 同时命中用户类清单时被直接返回，导致其 author 被跳过
    if ([self isDetectedAwemeClass:cls]) return NO;
    @synchronized (self) {
        return [gUserClasses containsObject:cls];
    }
}

+ (BOOL)isDetectedAwemeClass:(Class)cls {
    if (!cls) return NO;
    @synchronized (self) {
        return [gAwemeClasses containsObject:cls];
    }
}

+ (NSArray<NSString *> *)detectedIDFields {
    @synchronized (self) {
        return [gIDFields copy];
    }
}

+ (NSArray<NSString *> *)detectedNameFields {
    @synchronized (self) {
        return [gNameFields copy];
    }
}

+ (NSArray<NSString *> *)detectedCellUserKeys {
    @synchronized (self) {
        return [gCellUserKeys copy];
    }
}

+ (NSArray<NSString *> *)detectedUserClassNames {
    @synchronized (self) {
        NSMutableArray *names = [NSMutableArray array];
        for (Class c in gUserClasses) {
            [names addObject:NSStringFromClass(c)];
        }
        return [names copy];
    }
}

+ (BOOL)isScanFinished {
    @synchronized (self) {
        return gScanFinished;
    }
}

#pragma mark - 关键词视图类（v1.1.2 自动发现可 hook 目标）

/// 纯 C 遍历继承链判断是否为 UIView 子类（不向类发消息，NSProxy 安全）
static BOOL hf_clsIsUIViewSubclass(Class c) {
    Class uiviewClass = [UIView class];
    while (c && c != [NSObject class]) {
        if (c == uiviewClass) return YES;
        c = class_getSuperclass(c);
    }
    return NO;
}

+ (NSArray<NSString *> *)keywordViewClasses {
    NSArray *keywords = @[@"Friend", @"Recommend", @"Message", @"SideBar",
                          @"Banner", @"Relation", @"Follow", @"Contact", @"Invite"];
    unsigned int clsCount = 0;
    Class *classes = objc_copyClassList(&clsCount);
    NSMutableArray *found = [NSMutableArray array];
    for (unsigned i = 0; i < clsCount; i++) {
        Class c = classes[i];
        if (!c) continue;
        NSString *n = NSStringFromClass(c);
        if (n.length == 0 || n.length > 110) continue;
        BOOL match = NO;
        for (NSString *kw in keywords) {
            if ([n containsString:kw]) { match = YES; break; }
        }
        if (!match) continue;
        // 只保留 UIView 子类（纯 C 判断，不触发消息转发）
        if (!hf_clsIsUIViewSubclass(c)) continue;
        [found addObject:n];
        if (found.count >= 80) break;
    }
    free(classes);
    return [found copy];
}

@end
