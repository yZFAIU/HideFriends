//
//  HFDiscovery.h
//  HideFriends
//
//  v1.0.6 运行时自适应引擎
//  启动后后台扫描抖音已加载的全部 ObjC 类，自动发现：
//  - 用户模型类：具备 shortID/uniqueID/secUid/uid 等 ID 字段的类
//  - 作品模型类：具备 author 字段的类
//  - 用户 ID/昵称字段名集合
//  让插件不依赖硬编码类名/字段名，类结构变化也能自动适配。
//

#import <Foundation/Foundation.h>

@interface HFDiscovery : NSObject

/// 后台扫描一次（幂等；%ctor 后调用）。完成后通过日志与诊断报告输出发现结果
+ (void)scanAndLog;

/// 判断类是否属于已发现的「用户模型类」（纯 runtime 比较，安全）
+ (BOOL)isDetectedUserClass:(Class)cls;

/// 判断类是否属于已发现的「作品模型类」（有 author 字段）
+ (BOOL)isDetectedAwemeClass:(Class)cls;

/// 已发现的用户 ID 字段名（如 shortID / uniqueID / secUid…，供匹配读取）
+ (NSArray<NSString *> *)detectedIDFields;

/// 已发现的用户昵称字段名（如 nickname / name…）
+ (NSArray<NSString *> *)detectedNameFields;

/// 已发现的 cell 用户/作品相关属性名（动态白名单 key，v1.0.7）
+ (NSArray<NSString *> *)detectedCellUserKeys;

/// 已发现的用户模型类名列表（诊断报告用）
+ (NSArray<NSString *> *)detectedUserClassNames;

/// v1.1.2：扫描已加载类中匹配关键词的 UIView 子类（自动发现可 hook 的隐藏目标）
/// 关键词：Friend/Recommend/Message/SideBar/Banner/Relation/Follow/Contact/Invite
+ (NSArray<NSString *> *)keywordViewClasses;

/// 是否已完成扫描（诊断报告用）
+ (BOOL)isScanFinished;

@end
