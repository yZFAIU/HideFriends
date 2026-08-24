//
//  HFBlacklist.m
//  HideFriends
//
//  v1.0.5：性能重构
//  - 移除 class_copyPropertyList 深反射（Swift 模型 KVC 重负载 → watchdog 杀进程）
//  - 改为白名单 key 轻量查找（每 cell ≤ 12 次快速 KVC）
//  - 诊断改后台线程执行
//

#import "HFBlacklist.h"
#import "HFConstants.h"
#import "HFDiscovery.h"
#import "HFReporter.h"   // v1.1.6 黑名单变更同步云端
#import <objc/runtime.h>

#pragma mark - 内部工具函数

/// v1.3.0 用户注册表（方案D：UID↔抖音号映射）——声明提前，供全文件各方法使用
static NSMutableDictionary *gUserRegistry = nil;          // uid -> {uniqueID, shortID, nickname}
static NSLock *gRegistryLock = nil;
static NSMutableSet<Class> *gRegistryHookedClasses = nil;    // v1.3.3 已 hook 的类（诊断/幂等用；v1.3.52 改 Set：containsObject O(1)）
static NSString *const HF_REGISTRY_CACHE = @"HFUserRegistryCache";  // v1.3.34 注册表持久化
static NSString *const HF_MUTUAL_FOLLOW_CACHE = @"HFMutualFollowCache";  // v1.3.59 互关好友持久化
static NSTimeInterval gLastPersistTs = 0;                            // v1.3.39 注册表持久化节流
static NSTimeInterval gMutualFollowPersistTs = 0;                    // v1.3.59 互关好友持久化节流
static NSMutableDictionary *gMutualFollowUsers = nil;                // v1.3.56 互关好友集合：key=抖音号/uid, value={uniqueID,nickname,uid}
static NSLock *gMutualFollowLock = nil;
static NSArray<NSString *> *gBlacklistDisplayNamesCache = nil;       // v1.3.52 黑名单显示名缓存（避免每次 cell 都遍历整个注册表反查昵称）

/// 前向声明（hf_looksLikeAwemeObject 定义在后，hf_looksLikeUserObject 需调用）
static BOOL hf_looksLikeAwemeObject(id obj);

/// 判断对象是否为 NSProxy（或子类）实例。
/// 只用 runtime C 函数遍历继承链，绝不向代理对象发 ObjC 消息。
static BOOL hf_isProxy(id obj) {
    if (!obj) return NO;
    Class c = object_getClass(obj);
    Class proxyCls = [NSProxy class];
    while (c && c != [NSObject class]) {
        if (c == proxyCls) return YES;
        c = class_getSuperclass(c);
    }
    return NO;
}

/// 安全读取字符串属性（KVC + 类型检查；NSProxy 直接返回 nil）
/// v1.3.53 性能：先用 runtime 判断 getter 是否存在，避免 valueForKey 对不存在的 key
/// 抛 NSUnknownKeyException——异常抛出+栈展开是匹配热路径（每个 cell 多次调用）的主要开销。
static NSString *hf_stringProperty(id obj, NSString *name) {
    if (!obj || hf_isProxy(obj)) {
        return nil;
    }
    SEL sel = sel_registerName(name.UTF8String);
    if (!sel || !class_respondsToSelector(object_getClass(obj), sel)) {
        return nil;   // getter 不存在，直接返回，不触发 KVC 异常
    }
    @try {
        id v = [obj valueForKey:name];
        if (!v || hf_isProxy(v)) {
            return nil;
        }
        if ([v isKindOfClass:[NSString class]]) {
            return (NSString *)v;
        }
        if ([v respondsToSelector:@selector(stringValue)]) {
            return [v stringValue];
        }
    } @catch (NSException *e) {
    }
    return nil;
}

/// 纯 C 判断类继承链（不向类发消息，NSProxy 安全）
static BOOL hf_clsIsKindOf(Class c, Class target) {
    while (c && c != [NSObject class]) {
        if (c == target) return YES;
        c = class_getSuperclass(c);
    }
    return NO;
}

/// 鸭子类型判定：对象是否「长得像」抖音用户模型（≤7 次轻量 KVC）
/// v1.2.0：UIView 子类（cell 等）绝不视为用户模型——修复关注列表 cell 被误判的 bug
/// v1.3.3：有 author 字段的对象（作品模型 aweme）绝不视为用户——修复 AWEAwemeModel 被当用户返回、抖音号读不到的 bug
static BOOL hf_looksLikeUserObject(id obj) {
    if (!obj || hf_isProxy(obj)) {
        return NO;
    }
    if (hf_clsIsKindOf(object_getClass(obj), [UIView class])) {
        return NO;
    }
    // v1.3.3：作品模型（有 author 属性）不是用户——用户模型不会有 author
    if (hf_looksLikeAwemeObject(obj)) {
        return NO;
    }
    if (hf_stringProperty(obj, @"shortID").length > 0) return YES;
    if (hf_stringProperty(obj, @"uniqueID").length > 0) return YES;
    if (hf_stringProperty(obj, @"secUid").length > 0) return YES;
    if (hf_stringProperty(obj, @"uid").length > 0) return YES;
    if (hf_stringProperty(obj, @"douyinId").length > 0) return YES;
    if (hf_stringProperty(obj, @"userId").length > 0) return YES;
    if (hf_stringProperty(obj, @"userID").length > 0) return YES;   // v1.2.2
    if (hf_stringProperty(obj, @"nickname").length > 0) return YES;
    return NO;
}

/// 对象是否「长得像」作品模型（aweme）：有 author 字段即视为
static BOOL hf_looksLikeAwemeObject(id obj) {
    if (!obj || hf_isProxy(obj)) {
        return NO;
    }
    // v1.3.53：先判断 author getter 是否存在，避免 KVC 异常
    SEL authorSel = sel_registerName("author");
    if (!class_respondsToSelector(object_getClass(obj), authorSel)) return NO;
    @try {
        id author = [obj valueForKey:@"author"];
        if (author && !hf_isProxy(author)) {
            return YES;
        }
    } @catch (NSException *e) {
    }
    return NO;
}

/// v1.1.7 安全 KVC（代理保护 + 异常兜底）
/// v1.3.53 性能：同 hf_stringProperty，先判断 getter 存在，避免 KVC 异常开销
static id hf_safeKV(id obj, NSString *key) {
    if (!obj || hf_isProxy(obj)) return nil;
    SEL sel = sel_registerName(key.UTF8String);
    if (!sel || !class_respondsToSelector(object_getClass(obj), sel)) return nil;
    @try {
        id v = [obj valueForKey:key];
        if (!v || hf_isProxy(v)) return nil;
        return v;
    } @catch (NSException *e) {
        return nil;
    }
}

/// v1.3.17：从 conversationID 字符串解析对方 UID（"0:1:对方UID:内部ID" → parts[2]）
static NSString *hf_uidFromConversationIDString(NSString *cid) {
    if (cid.length == 0) return nil;
    NSArray *parts = [cid componentsSeparatedByString:@":"];
    for (NSInteger pi = (NSInteger)parts.count - 2; pi >= 0; pi--) {
        NSString *cand = parts[pi];
        if (cand.length < 8 || cand.length > 25) continue;
        NSCharacterSet *nonDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        if ([cand rangeOfCharacterFromSet:nonDigit].location == NSNotFound) {
            return cand;   // 从后往前找第一个纯数字长串（对方 UID 特征）
        }
    }
    return nil;
}

/// v1.3.17：安全读取对象的 conversationID（多种 key 命名兼容）
static NSString *hf_conversationIDOf(id obj) {
    if (!obj || hf_isProxy(obj)) return nil;
    NSString *cid = hf_stringProperty(obj, @"conversationID");
    if (cid.length == 0) cid = hf_stringProperty(obj, @"conversationId");
    if (cid.length == 0) cid = hf_stringProperty(obj, @"conversation_id");
    return cid;
}

/// v1.3.9 深度找 UID：cell 直接字段取不到时，穿透 cellViewModel/viewModel →
/// conversation/user/toUser/chatTarget/friendUser 等容器取 uid/userID/userId 字符串。
/// 覆盖消息列表（cell.cellViewModel = AWEIMChatCellViewModel）等 ViewModel 模式的 cell。
/// v1.3.17：① 容器 key 追加 chat（实测 AWEIMChatCellViewModel.chat = AWEIMOfficialChatModel，
///   对方会话数据藏在这里）；② 对 vm/会话容器本身也做 conversationID 解析。
/// 安全：全程 hf_safeKV，最多 ~20 次 KVC，异常兜底。
static NSString *hf_findUidDeep(id obj) {
    if (!obj || hf_isProxy(obj)) return nil;
    NSString *u = nil;
    // v1.3.14：会话 ID 解析——AWEIMMessageConversation.conversationID 格式
    // "0:1:对方UID:会话内部ID"（实测：0:1:72320954569:2957056977667067），parts[2] 即对方 UID
    u = hf_uidFromConversationIDString(hf_conversationIDOf(obj));
    if (u.length > 0) return u;
    // v1.3.14：直播客服会话直接持有对方 UID 字段
    NSString *spUid = hf_stringProperty(obj, @"liveCustomServiceSpUid");
    if (spUid.length > 0) return spUid;
    NSArray *vmKeys = @[ @"cellViewModel", @"viewModel", @"cellModel", @"model", @"itemModel" ];
    for (NSString *k in vmKeys) {
        id vm = hf_safeKV(obj, k);
        if (!vm || vm == obj) continue;
        // v1.3.17：vm 自身的 conversationID（会话模型常见）
        u = hf_uidFromConversationIDString(hf_conversationIDOf(vm));
        if (u.length > 0) return u;
        u = hf_stringProperty(vm, @"userID");
        if (u.length == 0) u = hf_stringProperty(vm, @"userId");
        if (u.length == 0) u = hf_stringProperty(vm, @"uid");
        if (u.length > 0) return u;
        // 二层容器：conversation / chat / user / toUser / chatTarget / friendUser / userModel
        // v1.3.17：chat 实测持有对方会话数据（AWEIMChatCellViewModel.chat = AWEIMOfficialChatModel）
        NSArray *innerKeys = @[ @"conversation", @"chat", @"user", @"toUser", @"chatTarget",
                                @"friendUser", @"userModel", @"targetUser", @"fromUser" ];
        for (NSString *ik in innerKeys) {
            id inner = hf_safeKV(vm, ik);
            if (!inner || inner == vm) continue;
            // v1.3.17：会话容器自身也可能带 conversationID
            u = hf_uidFromConversationIDString(hf_conversationIDOf(inner));
            if (u.length > 0) return u;
            u = hf_stringProperty(inner, @"userID");
            if (u.length == 0) u = hf_stringProperty(inner, @"userId");
            if (u.length == 0) u = hf_stringProperty(inner, @"uid");
            if (u.length > 0) return u;
        }
    }
    // 再直接查一层用户容器（cell 无 vm 时）
    NSArray *directKeys = @[ @"conversation", @"chat", @"user", @"toUser", @"chatTarget",
                             @"friendUser", @"userModel", @"targetUser" ];
    for (NSString *k in directKeys) {
        id inner = hf_safeKV(obj, k);
        if (!inner || inner == obj) continue;
        u = hf_uidFromConversationIDString(hf_conversationIDOf(inner));
        if (u.length > 0) return u;
        u = hf_stringProperty(inner, @"userID");
        if (u.length == 0) u = hf_stringProperty(inner, @"userId");
        if (u.length == 0) u = hf_stringProperty(inner, @"uid");
        if (u.length > 0) return u;
    }
    // v1.3.11：全属性扫描兜底——不猜 key，遍历对象全部属性，
    // 纯数字 8~25 位字符串（UID 特征）直接返回；用户模型/数组内的用户取 uid。
    {
        unsigned int count = 0;
        objc_property_t *props = class_copyPropertyList(object_getClass(obj), &count);
        for (unsigned i = 0; i < count && u.length == 0; i++) {
            const char *pn = property_getName(props[i]);
            if (!pn) continue;
            NSString *name = [NSString stringWithUTF8String:pn];
            if ([name isEqualToString:@"uid"] || [name isEqualToString:@"userId"] ||
                [name isEqualToString:@"userID"]) continue;   // 已查过
            id v = hf_safeKV(obj, name);
            if (!v || hf_isProxy(v)) continue;
            if ([v isKindOfClass:[NSString class]]) {
                NSString *s = (NSString *)v;
                if (s.length >= 8 && s.length <= 25) {
                    NSCharacterSet *nonDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
                    if ([s rangeOfCharacterFromSet:nonDigit].location == NSNotFound) {
                        u = s;   // 纯数字长串 → 候选 UID
                        break;
                    }
                }
            } else if (hf_looksLikeUserObject(v)) {
                u = hf_stringProperty(v, @"uid");
                if (u.length == 0) u = hf_stringProperty(v, @"userID");
            } else if ([v isKindOfClass:[NSArray class]]) {
                for (id item in (NSArray *)v) {
                    if (!item || hf_isProxy(item)) continue;
                    if (hf_looksLikeUserObject(item)) {
                        u = hf_stringProperty(item, @"uid");
                        if (u.length == 0) u = hf_stringProperty(item, @"userID");
                        break;
                    }
                }
            }
        }
        free(props);
    }
    return u;
}

/// v1.3.16 全属性 dump：遍历对象类+父类链的全部属性，输出「属性名 = 值摘要」。
/// v1.2.3 深度查找节流：每 100ms 最多深扫 20 个 cell（防主线程卡顿被 watchdog 杀）
static int gDeepScanCount = 0;
static CFAbsoluteTime gDeepScanWindowStart = 0;
static BOOL hf_deepScanThrottled(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gDeepScanWindowStart > 0.1) {
        gDeepScanWindowStart = now;
        gDeepScanCount = 0;
    }
    gDeepScanCount++;
    return gDeepScanCount > 20;
}

/// v1.2.4 深度 BFS：穿透任意属性链/数组找用户对象（覆盖抖音 ListKit 全系列 cell）
/// - 深度 ≤ 2 + 节流（100ms/20 次）防 watchdog 崩溃
/// - 固定 key 含 ListKit 载体：awelistkit_cellModel / ieseclistkit_preCellModel
/// - 通用属性扫描：遍历对象属性，数组/用户模型/作品模型(author) 自动深入
static id hf_deepFindUser(id obj, int depth) {
    if (!obj || hf_isProxy(obj) || depth > 2) return nil;
    if (hf_deepScanThrottled()) return nil;
    NSArray *keys = @[ @"viewController", @"viewModel", @"cellViewModel",
                       @"aweme", @"awemeModel", @"model", @"data", @"item",
                       @"author", @"user", @"userModel", @"userID",
                       @"conversation", @"chatTarget",
                       @"chat", @"peerUser", @"toUser", @"friendUser",
                       @"awelistkit_cellModel", @"ieseclistkit_preCellModel" ];
    for (NSString *k in keys) {
        id v = hf_safeKV(obj, k);
        if (!v) continue;
        if ([HFDiscovery isDetectedUserClass:object_getClass(v)] ||
            hf_looksLikeUserObject(v)) {
            return v;
        }
        if (hf_looksLikeAwemeObject(v) || [HFDiscovery isDetectedAwemeClass:object_getClass(v)]) {
            id author = hf_safeKV(v, @"author");
            if (author && hf_looksLikeUserObject(author)) {
                return author;
            }
        }
        id found = hf_deepFindUser(v, depth + 1);
        if (found) return found;
    }
    // v1.2.3 通用属性扫描：不再猜 key，遍历对象属性找用户模型/数组
    if (depth <= 1) {
        unsigned int count = 0;
        objc_property_t *props = class_copyPropertyList(object_getClass(obj), &count);
        NSInteger scanned = 0;
        for (unsigned i = 0; i < count && scanned < 15; i++) {
            const char *pn = property_getName(props[i]);
            if (!pn) continue;
            NSString *name = [NSString stringWithUTF8String:pn];
            if ([keys containsObject:name]) continue;  // 已查过
            scanned++;
            id v = hf_safeKV(obj, name);
            if (!v) continue;
            if ([v isKindOfClass:[NSArray class]]) {
                for (id item in (NSArray *)v) {
                    if (!item || hf_isProxy(item)) continue;
                    if ([HFDiscovery isDetectedUserClass:object_getClass(item)] ||
                        hf_looksLikeUserObject(item)) {
                        return item;
                    }
                    // v1.2.4：数组元素是作品模型 → 取 author
                    if (hf_looksLikeAwemeObject(item) ||
                        [HFDiscovery isDetectedAwemeClass:object_getClass(item)]) {
                        id author = hf_safeKV(item, @"author");
                        if (author && hf_looksLikeUserObject(author)) {
                            return author;
                        }
                    }
                    id found = hf_deepFindUser(item, depth + 1);
                    if (found) return found;
                }
            } else if ([HFDiscovery isDetectedUserClass:object_getClass(v)] ||
                       hf_looksLikeUserObject(v)) {
                return v;
            } else if (hf_looksLikeAwemeObject(v) ||
                       [HFDiscovery isDetectedAwemeClass:object_getClass(v)]) {
                // v1.2.4：属性值是作品模型 → 取 author（ListKit awelistkit_cellModel 场景）
                id author = hf_safeKV(v, @"author");
                if (author && hf_looksLikeUserObject(author)) {
                    return author;
                }
            }
        }
        free(props);
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            if (!item || hf_isProxy(item)) continue;
            id found = hf_deepFindUser(item, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}

@implementation HFBlacklist

#pragma mark - 存储

+ (NSArray<NSString *> *)blockedIDs {
    NSArray *raw = [[NSUserDefaults standardUserDefaults] arrayForKey:HF_KEY_BLACKLIST_IDS];
    if (![raw isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSMutableArray *clean = [NSMutableArray arrayWithCapacity:raw.count];
    NSMutableSet *seen = [NSMutableSet set];
    for (id v in raw) {
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
            NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (s.length > 0 && ![seen containsObject:s.lowercaseString]) {
                [clean addObject:s];
                [seen addObject:s.lowercaseString];
            }
        }
    }
    return [clean copy];
}

+ (void)saveBlockedIDs:(NSArray<NSString *> *)ids {
    [[NSUserDefaults standardUserDefaults] setObject:(ids ?: @[]) forKey:HF_KEY_BLACKLIST_IDS];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (void)addBlockedID:(NSString *)douyinID {
    NSString *trimmed = [douyinID stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return;
    }
    NSMutableArray *list = [[self blockedIDs] mutableCopy];
    for (NSString *existing in list) {
        if ([existing.lowercaseString isEqualToString:trimmed.lowercaseString]) {
            return;
        }
    }
    [list addObject:trimmed];
    [self saveBlockedIDs:list];
    // 黑名单变了，清显示名缓存（避免下次匹配用到旧的昵称集合）
    [self bumpChatCacheVersion];
    // 自动启用黑名单开关
    HFSetBool(HF_KEY_BLACKLIST_ENABLED, YES);
}

+ (void)removeBlockedID:(NSString *)douyinID {
    NSMutableArray *list = [[self blockedIDs] mutableCopy];
    NSInteger idx = -1;
    for (NSInteger i = 0; i < (NSInteger)list.count; i++) {
        if ([list[i] isEqualToString:douyinID]) {
            idx = i;
            break;
        }
    }
    if (idx >= 0) {
        [list removeObjectAtIndex:idx];
        [self saveBlockedIDs:list];
        // 黑名单变了，清显示名缓存
        [self bumpChatCacheVersion];
    }
}

#pragma mark - 匹配（鸭子类型 + 自适应类判断）

+ (BOOL)isUserObjectBlocked:(id)userObj {
    NSArray *ids = [self blockedIDs];
    if (ids.count == 0 || !userObj) {
        return NO;
    }
    // 读取用户标识：默认字段 + 自适应扫描发现的字段（合并去重）
    NSMutableArray *fields = [NSMutableArray arrayWithObjects:
        @"shortID", @"uniqueID", @"secUid", @"uid", @"douyinId", @"userId", @"userID", @"nickname", nil];
    for (NSString *f in [HFDiscovery detectedIDFields]) {
        if (![fields containsObject:f]) [fields addObject:f];
    }
    for (NSString *f in [HFDiscovery detectedNameFields]) {
        if (![fields containsObject:f]) [fields addObject:f];
    }

    NSMutableArray *idValues = [NSMutableArray array];
    NSString *nickname = nil;
    for (NSString *field in fields) {
        NSString *v = hf_stringProperty(userObj, field);
        if (v.length == 0) continue;
        if ([field isEqualToString:@"nickname"] || [field isEqualToString:@"name"]) {
            if (!nickname) nickname = v;
        } else {
            [idValues addObject:v];
        }
    }

    for (NSString *bid in ids) {
        if (bid.length == 0) continue;
        NSString *lowerBid = bid.lowercaseString;
        for (NSString *field in idValues) {
            if (field.length > 0 &&
                ([field isEqualToString:bid] ||
                 [field.lowercaseString isEqualToString:lowerBid])) {
                return YES;
            }
        }
        if (nickname.length > 0 && [nickname containsString:bid]) {
            return YES;
        }
    }
    // v1.3.1：ViewModel 包装穿透——userObj 读不到抖音号时，从其内部找 user 模型再比对
    NSArray *innerKeys = @[ @"user", @"userModel", @"targetUser", @"aweme", @"awemeModel" ];
    for (NSString *k in innerKeys) {
        id inner = hf_safeKV(userObj, k);
        if (!inner || inner == userObj) continue;
        if (hf_looksLikeAwemeObject(inner) || [HFDiscovery isDetectedAwemeClass:object_getClass(inner)]) {
            id author = hf_safeKV(inner, @"author");
            if (author && author != userObj) inner = author;
        }
        if (!inner || hf_isProxy(inner)) continue;
        for (NSString *bid in ids) {
            if (bid.length == 0) continue;
            NSString *lowerBid = bid.lowercaseString;
            NSArray *innerFields = @[ @"shortID", @"uniqueID", @"secUid", @"uid",
                                      @"douyinId", @"userId", @"userID", @"nickname" ];
            for (NSString *f in innerFields) {
                NSString *v = hf_stringProperty(inner, f);
                if (v.length == 0) continue;
                if ([v isEqualToString:bid] || [v.lowercaseString isEqualToString:lowerBid] ||
                    ([f isEqualToString:@"nickname"] && [v containsString:bid])) {
                    return YES;
                }
            }
        }
        break;  // 只穿透一层
    }
    // v1.3.1：注册表匹配——userObj 的 uid → 查表 → 抖音号/昵称比对
    {
        NSString *u = hf_stringProperty(userObj, @"uid");
        if (u.length == 0) u = hf_stringProperty(userObj, @"userId");
        if (u.length == 0) u = hf_stringProperty(userObj, @"userID");
        if (u.length > 0) {
            NSString *dyId = [self douyinIDForUid:u];
            if (dyId.length > 0) {
                for (NSString *bid in ids) {
                    if (bid.length > 0 &&
                        ([dyId isEqualToString:bid] || [dyId.lowercaseString isEqualToString:bid.lowercaseString])) {
                        return YES;
                    }
                }
            }
            NSString *nick = [self nicknameForUid:u];
            if (nick.length > 0) {
                for (NSString *bid in ids) {
                    if (bid.length > 0 && [nick containsString:bid]) {
                        return YES;
                    }
                }
            }
        }
    }
    // v1.3.9：会话/ViewModel 深度匹配——AWEIMMessageConversation 等模型自身无用户字段，
    // 深度取内部 UID（toUser/user/conversation…）→ 查注册表 → 抖音号/昵称比对
    {
        NSString *deepUid = hf_findUidDeep(userObj);
        if (deepUid.length > 0) {
            NSString *dyId = [self douyinIDForUid:deepUid];
            if (dyId.length > 0) {
                for (NSString *bid in ids) {
                    if (bid.length > 0 &&
                        ([dyId isEqualToString:bid] || [dyId.lowercaseString isEqualToString:bid.lowercaseString])) {
                        return YES;
                    }
                }
            }
            NSString *nick = [self nicknameForUid:deepUid];
            if (nick.length > 0) {
                for (NSString *bid in ids) {
                    if (bid.length > 0 && [nick containsString:bid]) {
                        return YES;
                    }
                }
            }
        }
    }
    return NO;
}

#pragma mark - 轻量查找（动态白名单 key + 自适应类判断）

+ (id)findUserObjectInObject:(id)obj {
    if (!obj || hf_isProxy(obj)) {
        return nil;
    }
    // 自身就是用户对象（自适应类判断优先，纯 C 比较零成本）
    if ([HFDiscovery isDetectedUserClass:object_getClass(obj)]) {
        // v1.2.5：作品模型已被 isDetectedUserClass 排除；此处兜底：若仍有 author，取 author
        id author = hf_safeKV(obj, @"author");
        if (author && hf_looksLikeUserObject(author)) {
            return author;
        }
        return obj;
    }
    if (hf_looksLikeUserObject(obj)) {
        // v1.2.5：若同时是作品模型（有 author），取 author（真用户）
        if (hf_looksLikeAwemeObject(obj)) {
            id author = hf_safeKV(obj, @"author");
            if (author && hf_looksLikeUserObject(author)) {
                return author;
            }
        }
        return obj;
    }
    // 一级 key：自适应扫描发现的 cell 用户 key（含默认白名单）
    NSArray *userKeys = [HFDiscovery detectedCellUserKeys];
    // v1.3.75：awemeKeys 提前声明（currentContext 穿透里也要用）
    NSArray *awemeKeys = @[ @"aweme", @"awemeModel", @"model", @"item", @"data" ];
    for (NSString *key in userKeys) {
        id v = hf_safeKV(obj, key);   // v1.3.53：hf_safeKV 内部已做 getter 预判断，不抛异常
        if (!v || hf_isProxy(v)) continue;
        if ([HFDiscovery isDetectedUserClass:object_getClass(v)] ||
            hf_looksLikeUserObject(v)) {
            return v;
        }
    }
    // v1.3.42：ListKit 载体 key 兜底（扫描完成前 detectedCellUserKeys 可能为空；
    // 关注/粉丝/互关列表的用户模型藏在 awelistkit_cellModel / ieseclistkit_preCellModel）
    // v1.3.75/78：新增 currentContext + awelistkit_cellContext——消息页"限时日常"窗口
    // AWEIMSkylightCommonCell 的用户对象藏在 currentContext.cellViewModel 里，需多层穿透。
    for (NSString *key in @[ @"awelistkit_cellModel", @"ieseclistkit_preCellModel", @"currentContext", @"awelistkit_cellContext" ]) {
        id v = hf_safeKV(obj, key);
        if (!v || hf_isProxy(v)) continue;
        if ([HFDiscovery isDetectedUserClass:object_getClass(v)] ||
            hf_looksLikeUserObject(v)) {
            return v;
        }
        // 穿透一层：context 内部再用 user/author 等 key 找用户对象
        for (NSString *innerKey in userKeys) {
            id inner = hf_safeKV(v, innerKey);
            if (!inner || hf_isProxy(inner)) continue;
            if ([HFDiscovery isDetectedUserClass:object_getClass(inner)] ||
                hf_looksLikeUserObject(inner)) {
                return inner;
            }
        }
        // v1.3.78：穿透 cellViewModel（限时日常 context 的用户模型藏在这里）
        id cvm = hf_safeKV(v, @"cellViewModel");
        if (cvm && !hf_isProxy(cvm)) {
            if ([HFDiscovery isDetectedUserClass:object_getClass(cvm)] ||
                hf_looksLikeUserObject(cvm)) {
                return cvm;
            }
            // cellViewModel 内部再找 user / peerUser / toUser 等
            for (NSString *ik in @[ @"user", @"peerUser", @"toUser", @"targetUser", @"friendUser", @"otherUser", @"author" ]) {
                id inner = hf_safeKV(cvm, ik);
                if (!inner || hf_isProxy(inner)) continue;
                if ([HFDiscovery isDetectedUserClass:object_getClass(inner)] ||
                    hf_looksLikeUserObject(inner)) {
                    return inner;
                }
            }
            // v1.3.80：限时日常用户模型真正藏在 cellViewModel.model 里
            // （诊断：cvm[model] = AWEIMOnlineContactAvatarViewModel / AWEIMSkylightBizViewModel）
            id model = hf_safeKV(cvm, @"model");
            if (model && !hf_isProxy(model)) {
                if ([HFDiscovery isDetectedUserClass:object_getClass(model)] ||
                    hf_looksLikeUserObject(model)) {
                    return model;
                }
                // model 内部常见容器：user/author/userModel/aweme
                for (NSString *ik in @[ @"user", @"author", @"userModel", @"targetUser", @"peerUser", @"aweme", @"awemeModel" ]) {
                    id inner = hf_safeKV(model, ik);
                    if (!inner || hf_isProxy(inner)) continue;
                    if (hf_looksLikeAwemeObject(inner) || [HFDiscovery isDetectedAwemeClass:object_getClass(inner)]) {
                        id author = hf_safeKV(inner, @"author");
                        if (author && !hf_isProxy(author) &&
                            ([HFDiscovery isDetectedUserClass:object_getClass(author)] ||
                             hf_looksLikeUserObject(author))) {
                            return author;
                        }
                    }
                    if ([HFDiscovery isDetectedUserClass:object_getClass(inner)] ||
                        hf_looksLikeUserObject(inner)) {
                        return inner;
                    }
                }
                // model 自身含 UID 字段（uid/userID/uniqueID/shortID/secUid）→ 视为用户对象返回，
                // 交给 isUserObjectBlocked 读 UID 对比黑名单
                for (NSString *ik in @[ @"uid", @"userID", @"userId", @"uniqueID", @"shortID", @"secUid" ]) {
                    NSString *sv = hf_stringProperty(model, ik);
                    if (sv.length > 0) return model;
                }
            }
        }
        // 再穿透 aweme 容器（context 内部可能是作品模型 → author）
        for (NSString *innerKey in awemeKeys) {
            id inner = hf_safeKV(v, innerKey);
            if (!inner || hf_isProxy(inner)) continue;
            if ([HFDiscovery isDetectedAwemeClass:object_getClass(inner)] ||
                hf_looksLikeAwemeObject(inner)) {
                id author = hf_safeKV(inner, @"author");
                if (author && !hf_isProxy(author) &&
                    ([HFDiscovery isDetectedUserClass:object_getClass(author)] ||
                     hf_looksLikeUserObject(author))) {
                    return author;
                }
            }
        }
    }
    // 二级：作品容器（aweme 等）→ author
    for (NSString *key in awemeKeys) {
        id v = hf_safeKV(obj, key);
        if (!v || hf_isProxy(v)) continue;
        BOOL isAweme = [HFDiscovery isDetectedAwemeClass:object_getClass(v)] ||
                       hf_looksLikeAwemeObject(v);
        if (!isAweme) continue;
        id author = hf_safeKV(v, @"author");
        if (author && !hf_isProxy(author)) {
            if ([HFDiscovery isDetectedUserClass:object_getClass(author)] ||
                hf_looksLikeUserObject(author)) {
                return author;
            }
        }
    }
    // v1.1.5：三级——39.9.0 推荐流 cell 的用户对象挂在 viewController 链上
    // （AWEFeedViewCell 无直接用户属性；经 viewController → aweme → author 可达）
    {
        id vc = hf_safeKV(obj, @"viewController");
        if (vc && !hf_isProxy(vc)) {
            NSArray *vcKeys = @[ @"viewModel", @"aweme", @"awemeModel", @"videoModel", @"model" ];
            for (NSString *k in vcKeys) {
                id v = hf_safeKV(vc, k);
                if (!v || hf_isProxy(v)) continue;
                if ([HFDiscovery isDetectedUserClass:object_getClass(v)] ||
                    hf_looksLikeUserObject(v)) {
                    return v;
                }
                if (hf_looksLikeAwemeObject(v) || [HFDiscovery isDetectedAwemeClass:object_getClass(v)]) {
                    id author = hf_safeKV(v, @"author");
                    if (author && !hf_isProxy(author) &&
                        ([HFDiscovery isDetectedUserClass:object_getClass(author)] ||
                         hf_looksLikeUserObject(author))) {
                        return author;
                    }
                }
            }
        }
    }
    // v1.1.7：终极兜底——深度 BFS（最多 2 层，覆盖搜索/主页/关注列表等一切 cell）
    {
        id found = hf_deepFindUser(obj, 0);
        if (found) return found;
    }
    return nil;
}

#pragma mark - 隐藏 cell

/// v1.3.6 关联对象 key：cell 是否已被隐藏处理过
static char kHFHiddenFlagKey;
/// v1.3.19 关联对象 key：cell 是否命中黑名单（持久隐藏——layoutSubviews 强制重隐藏）
static char kHFBlockedCellKey;
/// v1.3.20 关联对象 key：cell → NSIndexPath（行高钩子用）
static char kHFIndexPathKey;

+ (void)hideCellIfContainsBlockedUser:(UIView *)cell {
    if (!cell) return;
    id userObj = [self findUserObjectInObject:cell];
    BOOL hit = NO;
    if (userObj && [self isUserObjectBlocked:userObj]) {
        hit = YES;
    }
    // v1.2.2：cell 直接字段匹配（关注/粉丝列表 cell 直接持有 userID 等字符串）
    if (!hit && [self cellDirectFieldMatch:cell]) {
        hit = YES;
    }
    // v1.3.4：UI 文本兜底匹配（不猜数据结构——界面上显示了黑名单抖音号/昵称即命中）
    if (!hit && [self cellTextMatchesBlacklist:cell]) {
        hit = YES;
    }
    if (hit) {
        [self hideCellState:cell];
        // v1.3.6 标记已隐藏（v1.3.15 仅用于上报去重，不再跳过隐藏动作）
        objc_setAssociatedObject(cell, &kHFHiddenFlagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

/// v1.3.39：匹配并隐藏——一次 findUserObjectInObject 完成匹配+隐藏，返回命中详情供上报。
/// 用于 willDisplayCell，替代原先「hideCellIfContainsBlockedUser + blockedMatchInCell」
/// 两次反射（每次 cell 显示都多跑一遍深反射，是滚动卡顿来源之一）。
+ (NSDictionary *)matchAndHideCellIfBlocked:(UIView *)cell {
    if (!cell) return nil;
    // v1.3.47 性能：消息列表 chat cell 先走轻量直查（cellViewModel→chat 容器，O(1)），
    // 命中即隐藏返回，不再跑完整 blockedMatchInCell 深反射——消息列表是最高频滚动页。
    NSDictionary *match = [self matchChatInCellQuick:cell];
    if (!match) match = [self blockedMatchInCell:cell];
    if (match) {
        [self hideCellState:cell];
        objc_setAssociatedObject(cell, &kHFHiddenFlagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // v1.3.64：命中后同时标记行 + 触发行高重算——否则只隐藏内容(hidden=YES)但行高
        // 不归零，表现为「空白框」。行高钩子靠 isRowBlocked 判断，必须先 markRowBlocked。
        NSIndexPath *ip = objc_getAssociatedObject(cell, &kHFIndexPathKey);
        UIView *sv = cell.superview;
        if (ip && sv) {
            [self markRowBlocked:ip list:sv];
            if ([sv isKindOfClass:[UITableView class]]) {
                [self scheduleRowHeightReload:(UITableView *)sv indexPath:ip];
            } else if ([sv isKindOfClass:[UICollectionView class]]) {
                // v1.3.67：命中后 invalidateLayout 触发 layout 重算——配合
                // hf_installCollectionLayoutHook（对标记行返回 size=0 + 后续行上移）让
                // 关注/粉丝列表命中 cell 真正整行消失。不用 reloadData（对 ListKit 太重）。
                // v1.3.73：移除 layoutIfNeeded——它强制同步布局，与 ListKit 的异步布局
                // 冲突导致粉丝页「闪屏」。invalidateLayout 标记失效即可，系统下一布局
                // 周期自然重算（异步、无同步抖动）。
                UICollectionView *cv = (UICollectionView *)sv;
                [cv.collectionViewLayout invalidateLayout];
            }
        }
    } else {
        // v1.3.65 修复（误隐藏根因）：未命中时若 cell 之前被命中过（复用场景），
        // 必须恢复显示 + 清标记 + 撤行缓存。否则 ListKit 复用到非目标用户时，
        // 旧 cell 的 hidden=YES + kHFBlockedCellKey 标记残留，layoutSubviews 钩子的
        // enforceHideOnMarkedCell 会把这个无辜用户也强制隐藏。
        if ([objc_getAssociatedObject(cell, &kHFBlockedCellKey) boolValue]) {
            [self restoreCellState:cell];
            NSIndexPath *ip = objc_getAssociatedObject(cell, &kHFIndexPathKey);
            if (ip) [self unmarkRowBlocked:ip list:cell.superview];
        }
    }
    return match;
}

/// v1.3.26：统一隐藏状态——标记 + hidden/alpha/contentView 全部隐藏。
/// 所有隐藏路径（扫描/绑定/布局钩子）统一调用，避免遗漏。
+ (void)hideCellState:(UIView *)cell {
    if (!cell) return;
    objc_setAssociatedObject(cell, &kHFBlockedCellKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cell.alpha = 0.0;
    cell.hidden = YES;
    cell.userInteractionEnabled = NO;
    if ([cell isKindOfClass:[UITableViewCell class]] || [cell isKindOfClass:[UICollectionViewCell class]]) {
        cell.clipsToBounds = YES;
        UIView *content = (UIView *)[cell valueForKey:@"contentView"];
        if (content) {
            content.hidden = YES;
            // v1.3.28：contentView 也打标记——systemLayoutSize 钩子（UIView 基类）识别
            objc_setAssociatedObject(content, &kHFBlockedCellKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

/// v1.3.26：统一恢复状态——清标记 + hidden/alpha/contentView 全部恢复。
/// v1.3.26 修复：恢复路径此前漏了 contentView.hidden=NO（cell 复用给正常会话时内容不显示）。
/// v1.3.67 说明：这里【不撤行缓存】——行缓存（gBlockedRowKeys）是「位置级」标记，供
/// willDisplayCell 做 O(1) 判断（该位置是否目标）。若在此撤掉，快速滑动复用后 willDisplayCell
/// 就无法立即判断目标位置，必须等 0.5s 延迟匹配，出现「快速滑动时目标闪出来」。行缓存的
/// 正确撤除时机在 willDisplayCell 的「复用换位」分支（见 installDelegateHeightHooksForTableView）。
+ (void)restoreCellState:(UIView *)cell {
    if (!cell) return;
    objc_setAssociatedObject(cell, &kHFBlockedCellKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kHFHiddenFlagKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cell.hidden = NO;
    cell.alpha = 1.0;
    cell.userInteractionEnabled = YES;
    if ([cell isKindOfClass:[UITableViewCell class]] || [cell isKindOfClass:[UICollectionViewCell class]]) {
        UIView *content = (UIView *)[cell valueForKey:@"contentView"];
        if (content) {
            content.hidden = NO;
            // v1.3.28：同步清 contentView 标记
            objc_setAssociatedObject(content, &kHFBlockedCellKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

/// v1.3.27：节流触发黑名单行行高重算（reload 单行，10 秒一次）
static char kHFReloadTsKey;
+ (void)scheduleRowHeightReload:(UITableView *)tv indexPath:(NSIndexPath *)ip {
    if (!tv || !ip) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSDictionary *last = objc_getAssociatedObject(tv, &kHFReloadTsKey);
    if (last && (now - [last[ip] doubleValue]) < 10.0) return;
    NSMutableDictionary *d = [last mutableCopy] ?: [NSMutableDictionary dictionary];
    d[ip] = @(now);
    objc_setAssociatedObject(tv, &kHFReloadTsKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        [tv reloadRowsAtIndexPaths:@[ ip ] withRowAnimation:UITableViewRowAnimationNone];
    } @catch (NSException *e) {
    }
}

/// v1.3.19：轻量 chat 匹配——只查 vm 的 chat/conversation 容器（不跑全量 deepFind）
/// v1.3.26：① chat 命中缓存（关联对象挂 chat 对象上，O(1) 直接返回，根治卡死）；
///   ② 优先 peerUser 字段直查（uniqueID/shortID/douyinId/dy 与黑名单直比——已实锤路径）；
///   ③ 全属性扫描降为首次兜底；④ 黑名单版本号失效（增删黑名单后自动重扫）。
static char kHFChatHitKey;              // chat 对象 → @{@"v":版本, @"hit":YES/NO, @"bid":抖音号}
static NSInteger gChatCacheVersion = 0; // 黑名单变更时 +1，缓存失效

+ (NSDictionary *)matchChatInViewModel:(id)vm {
    if (!vm || hf_isProxy(vm)) return nil;
    NSArray *ids = [self blockedIDs];
    if (ids.count == 0) return nil;
    for (NSString *ck in @[ @"chat", @"conversation", @"conversationInfo", @"session" ]) {
        id cv = hf_safeKV(vm, ck);
        if (!cv || cv == vm || hf_isProxy(cv)) continue;
        // 1) 命中缓存（O(1)）
        NSDictionary *cached = objc_getAssociatedObject(cv, &kHFChatHitKey);
        if (cached && [cached[@"v"] integerValue] == gChatCacheVersion) {
            if ([cached[@"hit"] boolValue]) {
                return @{ @"blocked_id": cached[@"bid"] ?: (ids.firstObject ?: @"?"),
                          @"matched_field": @"chat.peerUser(cache)" };
            }
            continue;   // 已确认未命中，跳过
        }
        NSDictionary *m = nil;
        // 2) 优先 peerUser 字段直查（已实锤命中路径，最快）
        id pu = hf_safeKV(cv, @"peerUser");
        if (pu && !hf_isProxy(pu)) {
            // v1.3.38：登记 peerUser，捕获消息列表的 UID→抖音号映射，
            // 供关注/粉丝/互关列表（只有 userID/UID）反查抖音号命中黑名单。
            [self registerUserObject:pu];
            NSString *cidUid = hf_uidFromConversationIDString(hf_conversationIDOf(cv));
            if (cidUid.length > 0) {
                NSString *dyId = hf_stringProperty(pu, @"uniqueID");
                if (dyId.length == 0) dyId = hf_stringProperty(pu, @"shortID");
                if (dyId.length == 0) dyId = hf_stringProperty(pu, @"douyinId");
                if (dyId.length == 0) dyId = hf_stringProperty(pu, @"dy");
                if (dyId.length > 0) {
                    // v1.3.43：peerUser 的昵称字段是 nick（不是 nickname），一并捕获，
                    // 供关注/粉丝/互关列表按「显示昵称」文本兜底匹配隐藏。
                    NSString *nick = hf_stringProperty(pu, @"nickname");
                    if (nick.length == 0) nick = hf_stringProperty(pu, @"nick");
                    [self registerUid:cidUid uniqueID:dyId shortID:nil nickname:nick];
                }
            }
            NSArray *puFields = @[ @"uniqueID", @"shortID", @"douyinId", @"dy", @"uid", @"userId", @"userID", @"nickname" ];
            for (NSString *pf in puFields) {
                NSString *pv = hf_stringProperty(pu, pf);
                if (pv.length == 0) continue;
                for (NSString *bid in ids) {
                    if (bid.length > 0 && ([pv isEqualToString:bid] ||
                                           [pv.lowercaseString isEqualToString:bid.lowercaseString])) {
                        m = @{ @"blocked_id": pv, @"matched_field": @"chat.peerUser" };
                        break;
                    }
                }
                if (m) break;
            }
        }
        // 3) 兜底：全属性扫描（首次/peerUser 缺失时）
        if (!m) m = [self matchBlacklistInObjectDeep:cv];
        // 4) 写缓存
        if (m) {
            objc_setAssociatedObject(cv, &kHFChatHitKey,
                                     @{ @"v": @(gChatCacheVersion), @"hit": @YES, @"bid": m[@"blocked_id"] ?: @"" },
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return m;
        }
        objc_setAssociatedObject(cv, &kHFChatHitKey,
                                 @{ @"v": @(gChatCacheVersion), @"hit": @NO },
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return nil;
}

/// v1.3.26：黑名单变更时使 chat 缓存失效（通知回调里调用）
+ (void)bumpChatCacheVersion {
    gChatCacheVersion++;
    // v1.3.52：同时清空黑名单显示名缓存（黑名单变了，反查的昵称集合也要重算）
    gBlacklistDisplayNamesCache = nil;
}

/// v1.3.24：扫描快路径——cell → cellViewModel → chat 容器直查（避免每次扫描跑完整 deepFind）
+ (NSDictionary *)matchChatInCellQuick:(UIView *)cell {
    if (!cell) return nil;
    for (NSString *vk in @[ @"cellViewModel", @"viewModel", @"cellModel", @"model", @"itemModel" ]) {
        id vm = hf_safeKV(cell, vk);
        if (!vm || vm == cell || hf_isProxy(vm)) continue;
        NSDictionary *m = [self matchChatInViewModel:vm];
        if (m) return m;
    }
    return nil;
}

/// v1.3.19：VM 绑定钩子（hook setCellViewModel:）——绑定后立即检查并标记/恢复 cell。
/// 消息刷新、复用重绑定时都会触发，比 3 秒扫描更及时。
+ (void)checkAndMarkCell:(UIView *)cell viewModel:(id)vm {
    if (!cell) return;
    if ([self matchChatInViewModel:vm]) {
        // v1.3.26：统一隐藏状态（标记 + contentView 隐藏）
        [self hideCellState:cell];
        // v1.3.29：命中即写行缓存（需要 indexPath——从 cell.superview 是 UITableView 取）
        UIView *sv = cell.superview;
        if ([sv isKindOfClass:[UITableView class]]) {
            NSIndexPath *ip = [(UITableView *)sv indexPathForCell:(UITableViewCell *)cell];
            if (ip) [self markRowBlocked:ip list:sv];
        }
    } else {
        BOOL wasBlocked = [objc_getAssociatedObject(cell, &kHFBlockedCellKey) boolValue];
        if (wasBlocked) {
            // v1.3.26：统一恢复状态（含 contentView.hidden=NO——修复复用后正常会话变空白）
            [self restoreCellState:cell];
        }
    }
}

/// v1.3.19：layoutSubviews 钩子——标记过的黑名单 cell 每次布局后强制隐藏（防重绘覆盖）
/// v1.3.22（关键修复）：绝不在 layoutSubviews 内 setFrame / 改约束——
/// 设置 frame/约束会再次触发 setNeedsLayout → 递归 layoutSubviews → 主线程死循环（页面卡死）。
/// 只做轻量隐藏（hidden/alpha），row 高度归零由 delegate 行高钩子负责。
+ (void)enforceHideOnMarkedCell:(UIView *)cell {
    if (!cell) return;
    if (![objc_getAssociatedObject(cell, &kHFBlockedCellKey) boolValue]) return;
    cell.hidden = YES;
    cell.alpha = 0.0;
    cell.userInteractionEnabled = NO;
    if ([cell isKindOfClass:[UITableViewCell class]] || [cell isKindOfClass:[UICollectionViewCell class]]) {
        UIView *content = (UIView *)[cell valueForKey:@"contentView"];
        if (content) content.hidden = YES;
    }
}

/// v1.3.19：安装持久隐藏钩子——swizzle 消息会话列表 cell 的 layoutSubviews + setCellViewModel:。
/// 类晚加载：由 setupUserRegistry（心跳每 30s 调用）反复触发，类出现后只安装一次。
static void hf_installCellPersistenceHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = NSClassFromString(@"AWEIMChatListCommonCell");
    if (!cls) return;
    installed = YES;
    // 1) layoutSubviews：每次布局后强制隐藏标记 cell
    SEL lsSel = @selector(layoutSubviews);
    Method m = class_getInstanceMethod(cls, lsSel);
    if (m) {
        IMP orig = method_getImplementation(m);
        IMP newImp = imp_implementationWithBlock(^(id selfV) {
            ((void (*)(id, SEL))orig)(selfV, lsSel);
            [HFBlacklist enforceHideOnMarkedCell:selfV];
        });
        method_setImplementation(m, newImp);
    }
    // 2) setCellViewModel:：绑定后立即检查 chat 是否命中黑名单
    SEL svmSel = NSSelectorFromString(@"setCellViewModel:");
    Method m2 = class_getInstanceMethod(cls, svmSel);
    if (m2) {
        IMP orig2 = method_getImplementation(m2);
        IMP newImp2 = imp_implementationWithBlock(^(id selfV, id vm) {
            ((void (*)(id, SEL, id))orig2)(selfV, svmSel, vm);
            [HFBlacklist checkAndMarkCell:selfV viewModel:vm];
        });
        method_setImplementation(m2, newImp2);
    }
    NSLog(@"[HideFriends] cell persistence hooks installed (AWEIMChatListCommonCell)");
}

/// v1.3.28：hook UIView 基类的 systemLayoutSizeFittingSize 系列——cell 和 contentView
/// 全覆盖（自动布局行高计算的实际入口；v1.3.27 只 hook cell 级无参版不生效，
/// 因为 TableView 走 contentView / 带 fittingPriority 的新 API）。
/// 只对打了 kHFBlockedCellKey 标记的 view 返回高度 0；无标记的 view 零影响。
static void hf_installSystemLayoutHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    Class uiView = [UIView class];
    // 1) systemLayoutSizeFittingSize:
    SEL s1 = @selector(systemLayoutSizeFittingSize:);
    Method m1 = class_getInstanceMethod(uiView, s1);
    if (m1) {
        IMP orig1 = method_getImplementation(m1);
        IMP newImp1 = imp_implementationWithBlock(^(id selfV, CGSize targetSize) {
            CGSize s = ((CGSize (*)(id, SEL, CGSize))orig1)(selfV, s1, targetSize);
            if ([objc_getAssociatedObject(selfV, &kHFBlockedCellKey) boolValue]) {
                s.height = 0;
            }
            return s;
        });
        method_setImplementation(m1, newImp1);
    }
    // 2) systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:
    SEL s2 = @selector(systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:);
    Method m2 = class_getInstanceMethod(uiView, s2);
    if (m2) {
        IMP orig2 = method_getImplementation(m2);
        IMP newImp2 = imp_implementationWithBlock(^(id selfV, CGSize targetSize, UILayoutPriority h, UILayoutPriority v) {
            CGSize s = ((CGSize (*)(id, SEL, CGSize, UILayoutPriority, UILayoutPriority))orig2)(selfV, s2, targetSize, h, v);
            if ([objc_getAssociatedObject(selfV, &kHFBlockedCellKey) boolValue]) {
                s.height = 0;
            }
            return s;
        });
        method_setImplementation(m2, newImp2);
    }
    NSLog(@"[HideFriends] systemLayoutSize hooks installed (UIView base)");
}

/// v1.3.20：hook 消息会话列表 TableView 的行高查询——黑名单 cell 所在行返回 0，
/// row 高度直接变 0，不再占空白位。
/// 只对 AWEIMChatTabTableView 实例生效（不影响其他 TableView）。
static void hf_installRowHeightHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = NSClassFromString(@"AWEIMChatTabTableView");
    if (!cls) return;
    installed = YES;
    Class targetCls = cls;   // 仅 selfV 是 AWEIMChatTabTableView 时返回 0
    // 1) tableView:heightForRowAtIndexPath:
    SEL hSel = @selector(tableView:heightForRowAtIndexPath:);
    Method m = class_getInstanceMethod(cls, hSel);
    if (m) {
        IMP orig = method_getImplementation(m);
        IMP newImp = imp_implementationWithBlock(^(id selfV, UITableView *tv, NSIndexPath *ip) {
            CGFloat origH = ((CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))orig)(selfV, hSel, tv, ip);
            if (![selfV isKindOfClass:targetCls]) return origH;
            if (origH <= 0) return origH;   // 已经是 0 没必要再查
            for (UITableViewCell *c in tv.visibleCells) {
                NSIndexPath *cip = objc_getAssociatedObject(c, &kHFIndexPathKey);
                if (cip && [cip isEqual:ip] &&
                    [objc_getAssociatedObject(c, &kHFBlockedCellKey) boolValue]) {
                    return (CGFloat)0;
                }
            }
            return origH;
        });
        method_setImplementation(m, newImp);
    }
    // 2) tableView:estimatedHeightForRowAtIndexPath:（自动布局用）
    SEL ehSel = @selector(tableView:estimatedHeightForRowAtIndexPath:);
    Method m2 = class_getInstanceMethod(cls, ehSel);
    if (m2) {
        IMP orig2 = method_getImplementation(m2);
        IMP newImp2 = imp_implementationWithBlock(^(id selfV, UITableView *tv, NSIndexPath *ip) {
            CGFloat origH = ((CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))orig2)(selfV, ehSel, tv, ip);
            if (![selfV isKindOfClass:targetCls]) return origH;
            for (UITableViewCell *c in tv.visibleCells) {
                NSIndexPath *cip = objc_getAssociatedObject(c, &kHFIndexPathKey);
                if (cip && [cip isEqual:ip] &&
                    [objc_getAssociatedObject(c, &kHFBlockedCellKey) boolValue]) {
                    return (CGFloat)0;
                }
            }
            return origH;
        });
        method_setImplementation(m2, newImp2);
    }
    NSLog(@"[HideFriends] row height hooks installed (AWEIMChatTabTableView)");
}

// delegate 类名（hook 去重用，避免同一 delegate 类被重复 hook）
static NSString *gDelegateClassName = nil;

// v1.3.24：黑名单行缓存（section-row）——行高钩子 O(1) 查询，不依赖 cell 可见性
static NSMutableSet<NSString *> *gBlockedRowKeys = nil;
/// v1.3.73：行缓存 key 必须带「列表实例」标识——此前用全局 "section-row" 字符串，
/// 不同列表（消息/关注/粉丝/个人主页）的相同 indexPath 会互相污染：消息列表命中 "0-4"，
/// 切到个人主页后个人主页的 "0-4" 也被判为黑名单行（误隐藏根因）。
static NSString *hf_rowKeyForListAndIP(id list, NSIndexPath *ip) {
    return [NSString stringWithFormat:@"%p|%ld-%ld", list, (long)ip.section, (long)ip.row];
}
+ (void)markRowBlocked:(NSIndexPath *)ip list:(id)list {
    if (!ip || !list) return;
    if (!gBlockedRowKeys) gBlockedRowKeys = [NSMutableSet set];
    [gBlockedRowKeys addObject:hf_rowKeyForListAndIP(list, ip)];
}
+ (void)unmarkRowBlocked:(NSIndexPath *)ip list:(id)list {
    if (!ip || !list || !gBlockedRowKeys) return;
    [gBlockedRowKeys removeObject:hf_rowKeyForListAndIP(list, ip)];
}
+ (BOOL)isRowBlocked:(NSIndexPath *)ip list:(id)list {
    if (!ip || !list || !gBlockedRowKeys) return NO;
    return [gBlockedRowKeys containsObject:hf_rowKeyForListAndIP(list, ip)];
}

/// v1.3.21：动态发现 AWEIMChatTabTableView 的 delegate 并 hook 其行高方法。
/// 关键：tableView:heightForRowAtIndexPath: 是 delegate 方法，TableView 类本身不实现，
/// 必须 hook 真正的 delegate（ListKit adapter / VC）才能让黑名单行返回 0 高度。
+ (void)installDelegateHeightHooksForTableView:(UITableView *)tv {
    if (!tv) return;
    id delegate = tv.delegate;
    if (!delegate) return;
    Class dcls = object_getClass(delegate);
    if (!dcls) return;
    gDelegateClassName = NSStringFromClass(dcls);
    // v1.3.61：按 delegate 类去重（支持关注/粉丝/互关等多个列表的 delegate），
    // 不再用 gDelegateHeightHookOK 全局一次性（那会导致只有消息列表 delegate 被 hook，
    // 关注/粉丝/互关列表的 willDisplayCell 从不触发匹配隐藏）。
    static NSMutableSet<NSString *> *hookedDelegates = nil;
    if (!hookedDelegates) hookedDelegates = [NSMutableSet set];
    if ([hookedDelegates containsObject:gDelegateClassName]) return;
    [hookedDelegates addObject:gDelegateClassName];
    // 1) tableView:heightForRowAtIndexPath:（v1.3.24：查缓存 O(1)，不再遍历 visibleCells）
    SEL hSel = @selector(tableView:heightForRowAtIndexPath:);
    Method hm = class_getInstanceMethod(dcls, hSel);
    if (hm) {
        IMP orig = method_getImplementation(hm);
        IMP newImp = imp_implementationWithBlock(^(id selfV, UITableView *t2, NSIndexPath *ip) {
            if ([HFBlacklist isRowBlocked:ip list:t2]) return (CGFloat)0;
            CGFloat origH = ((CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))orig)(selfV, hSel, t2, ip);
            return origH;
        });
        method_setImplementation(hm, newImp);
    }
    // 2) tableView:estimatedHeightForRowAtIndexPath:
    SEL ehSel = @selector(tableView:estimatedHeightForRowAtIndexPath:);
    Method em = class_getInstanceMethod(dcls, ehSel);
    if (em) {
        IMP origE = method_getImplementation(em);
        IMP newImpE = imp_implementationWithBlock(^(id selfV, UITableView *t2, NSIndexPath *ip) {
            if ([HFBlacklist isRowBlocked:ip list:t2]) return (CGFloat)0;
            CGFloat origH = ((CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))origE)(selfV, ehSel, t2, ip);
            return origH;
        });
        method_setImplementation(em, newImpE);
    }
    // 3) tableView:willDisplayCell:forRowAtIndexPath:（记录 cell→indexPath + 即时匹配隐藏）
    // v1.3.61：willDisplayCell 是 delegate 方法，必须 hook delegate 才会被调用——
    // 之前在 HideFriends.xm 里 %hook UITableView 类上的这个方法拦不到，是关注/粉丝/互关
    // 列表「隐藏不生效」的根因。这里才是真正的 cell 显示时机。
    SEL wdSel = @selector(tableView:willDisplayCell:forRowAtIndexPath:);
    Method wm = class_getInstanceMethod(dcls, wdSel);
    if (wm) {
        IMP origW = method_getImplementation(wm);
        IMP newImpW = imp_implementationWithBlock(^(id selfV, UITableView *t2, UITableViewCell *cell, NSIndexPath *ip) {
            if (cell && ip) {
                // v1.3.67：复用换位时先撤旧位置行缓存——旧位置已不再是目标，否则 heightForRow
                // 会对旧位置返回 0（误伤）。条件：旧 ip 存在、与新 ip 不同、且新 ip 非目标。
                NSIndexPath *oldIP = objc_getAssociatedObject(cell, &kHFIndexPathKey);
                if (oldIP && ![oldIP isEqual:ip] && ![HFBlacklist isRowBlocked:ip list:t2]) {
                    [HFBlacklist unmarkRowBlocked:oldIP list:t2];
                }
                objc_setAssociatedObject(cell, &kHFIndexPathKey, ip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            ((void (*)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *))origW)(selfV, wdSel, t2, cell, ip);
            // v1.3.67：该位置已判定为目标（行缓存命中）→ 立即隐藏，不再等 0.5s 延迟匹配。
            // 这是「快速滑动时目标闪出来」的根治——复用后目标位置 O(1) 判断直接隐藏。
            if (ip && [HFBlacklist isRowBlocked:ip list:t2]) {
                [HFBlacklist hideCellState:cell];
                objc_setAssociatedObject(cell, &kHFHiddenFlagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else {
                // v1.3.75：双重延迟匹配——慢加载 cell 也能命中
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [HFBlacklist matchAndHideCellIfBlocked:cell];
                });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [HFBlacklist matchAndHideCellIfBlocked:cell];
                });
            }
        });
        method_setImplementation(wm, newImpW);
    }
}

/// v1.3.62：hook UICollectionView delegate 的 willDisplayCell——关注/粉丝列表是
/// UICollectionView（cell 是 AWEFollowListUserListCell），之前只 hook 了 UITableView
/// 的 delegate，导致关注/粉丝列表的即时隐藏一直没生效（只有互关列表 UITableView 生效）。
+ (void)installDelegateHooksForCollectionView:(UICollectionView *)cv {
    if (!cv) return;
    id delegate = cv.delegate;
    if (!delegate) return;
    Class dcls = object_getClass(delegate);
    if (!dcls) return;
    static NSMutableSet<NSString *> *hooked = nil;
    if (!hooked) hooked = [NSMutableSet set];
    NSString *name = NSStringFromClass(dcls);
    if ([hooked containsObject:name]) return;
    [hooked addObject:name];
    SEL wdSel = @selector(collectionView:willDisplayCell:forItemAtIndexPath:);
    Method wm = class_getInstanceMethod(dcls, wdSel);
    if (wm) {
        IMP origW = method_getImplementation(wm);
        IMP newImpW = imp_implementationWithBlock(^(id selfV, UICollectionView *c2, UICollectionViewCell *cell, NSIndexPath *ip) {
            if (cell && ip) {
                // v1.3.67：复用换位时先撤旧位置行缓存（同 UITableView 逻辑，避免旧位置误伤）
                NSIndexPath *oldIP = objc_getAssociatedObject(cell, &kHFIndexPathKey);
                if (oldIP && ![oldIP isEqual:ip] && ![HFBlacklist isRowBlocked:ip list:c2]) {
                    [HFBlacklist unmarkRowBlocked:oldIP list:c2];
                }
                // v1.3.65 修复：记录 cell→indexPath（此前漏了，导致 markRowBlocked/行高归零失效）
                objc_setAssociatedObject(cell, &kHFIndexPathKey, ip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            ((void (*)(id, SEL, UICollectionView *, UICollectionViewCell *, NSIndexPath *))origW)(selfV, wdSel, c2, cell, ip);
            // v1.3.67：目标位置立即隐藏（快速滑动不闪）；首次遇到则延迟匹配
            if (ip && [HFBlacklist isRowBlocked:ip list:c2]) {
                [HFBlacklist hideCellState:cell];
                objc_setAssociatedObject(cell, &kHFHiddenFlagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else {
                // v1.3.75：双重延迟匹配——消息页"限时日常"等横滑窗口的 cell 数据异步加载慢，
                // 0.5s 时数据可能还没填（命中落空、漏隐藏），1.5s 再试一次兜底。
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [HFBlacklist matchAndHideCellIfBlocked:cell];
                });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [HFBlacklist matchAndHideCellIfBlocked:cell];
                });
            }
        });
        method_setImplementation(wm, newImpW);
    }
    // v1.3.74 修复崩溃：移除 sizeForItem delegate hook + forwardingTargetForSelector 探测。
    // 这两个 hook 试图在 ListKit 的 BSTCollectionViewDelegateProxy 上拦尺寸查询，但 proxy
    // 的转发链被 hook 破坏后，UICollectionViewFlowLayout prepareLayout → _fetchItemsInfoForRect
    // 向 delegate 发 sizeForItem 时 unrecognized selector，启动即崩溃。
    // 尺寸归零已由 hf_installCollectionLayoutHook（layout attributes 层）可靠实现，无需 delegate 层。
    NSLog(@"[HideFriends] collection delegate hook installed on %@", name);
}

/// v1.3.21：通用 cell 布局钩子——hook UITableViewCell/UICollectionViewCell 基类，
/// 覆盖所有 cell 类型（含顶部好友横排 AWEIMSkylightCommonCell）。
/// 无标记的 cell 零开销（一次关联对象查询）。
static void hf_installGenericCellLayoutHook(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    void (^installForClass)(Class) = ^(Class cls) {
        if (!cls) return;
        SEL sel = @selector(layoutSubviews);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            IMP orig = method_getImplementation(m);
            IMP newImp = imp_implementationWithBlock(^(id selfV) {
                ((void (*)(id, SEL))orig)(selfV, sel);
                [HFBlacklist enforceHideOnMarkedCell:selfV];
            });
            method_setImplementation(m, newImp);
        }
        // v1.3.65 修复（误隐藏根治）：hook prepareForReuse——cell 复用时清除黑名单标记 +
        // 恢复显示。此前标记残留导致「隐藏错、隐藏到没设置的好友」。prepareForReuse 是
        // ListKit 复用的必经入口，比 willDisplayCell 的未命中恢复更早、更可靠。
        SEL prSel = @selector(prepareForReuse);
        Method pm = class_getInstanceMethod(cls, prSel);
        if (pm) {
            IMP origP = method_getImplementation(pm);
            IMP newImpP = imp_implementationWithBlock(^(id selfV) {
                ((void (*)(id, SEL))origP)(selfV, prSel);
                [HFBlacklist restoreCellState:selfV];
            });
            method_setImplementation(pm, newImpP);
        }
    };
    installForClass([UITableViewCell class]);
    installForClass([UICollectionViewCell class]);
    NSLog(@"[HideFriends] generic cell layout + prepareForReuse hook installed");
}

/// v1.3.21：行高钩子安装器——hook UITableView 基类 layoutSubviews，
/// 实例布局时动态发现 delegate 并装钩子（覆盖所有列表：消息/关注/粉丝/互关）。
/// v1.3.61：从 AWEIMChatTabTableView（仅消息列表）改为 UITableView 基类，
/// 否则关注/粉丝/互关列表的 delegate 永远不会被 hook，willDisplayCell 匹配失效。
static void hf_installRowHeightHookInstaller(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    SEL lsSel = @selector(layoutSubviews);
    // v1.3.62：同时 hook UITableView 和 UICollectionView 基类——关注/粉丝列表是
    // UICollectionView，只 hook UITableView 会导致它们的 delegate 永远不被 hook。
    void (^installForClass)(Class) = ^(Class cls) {
        Method m = class_getInstanceMethod(cls, lsSel);
        if (!m) return;
        IMP orig = method_getImplementation(m);
        IMP newImp = imp_implementationWithBlock(^(id selfV) {
            ((void (*)(id, SEL))orig)(selfV, lsSel);
            if ([selfV isKindOfClass:[UITableView class]]) {
                [HFBlacklist installDelegateHeightHooksForTableView:(UITableView *)selfV];
            } else if ([selfV isKindOfClass:[UICollectionView class]]) {
                [HFBlacklist installDelegateHooksForCollectionView:(UICollectionView *)selfV];
            }
        });
        method_setImplementation(m, newImp);
    };
    installForClass([UITableView class]);
    installForClass([UICollectionView class]);
    NSLog(@"[HideFriends] row-height hook installer installed (UITableView+UICollectionView base)");
}

/// v1.3.29：动态发现并 hook 真实 delegate target 的 heightForRowAtIndexPath。
/// ListKit proxy（BSTTableViewDelegateOptProxy）把行高查询转发给背后 target，
/// swizzle proxy 无效——必须 hook 真正的 target。
+ (void)installHeightHookOnTarget:(id)target {
    if (!target) return;
    static NSMutableSet<NSString *> *hooked = nil;
    if (!hooked) hooked = [NSMutableSet set];
    Class tcls = object_getClass(target);
    NSString *name = NSStringFromClass(tcls) ?: @"?";
    if ([hooked containsObject:name]) return;
    [hooked addObject:name];
    SEL hSel = @selector(tableView:heightForRowAtIndexPath:);
    Method hm = class_getInstanceMethod(tcls, hSel);
    if (hm) {
        IMP origH = method_getImplementation(hm);
        IMP newImpH = imp_implementationWithBlock(^(id selfV, UITableView *tv, NSIndexPath *ip) {
            if ([HFBlacklist isRowBlocked:ip list:tv]) return (CGFloat)0;
            return ((CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))origH)(selfV, hSel, tv, ip);
        });
        method_setImplementation(hm, newImpH);
        NSLog(@"[HideFriends] height hook installed on real target %@", name);
    }
}

/// v1.3.66：动态发现并 hook 真实 delegate target 的 collectionView:layout:sizeForItemAtIndexPath:。
/// 关注/粉丝列表是 UICollectionView，ListKit 的 delegate proxy（BSTTableViewDelegateOptProxy 等）
/// 把 sizeForItem 查询转发给背后 target，swizzle proxy 无效——必须 hook 真正的 target，
/// 否则命中行不会归零（v1.3.65 在朋友页采集的诊断里 sizeForItem=0 即此原因）。
+ (void)installSizeForItemHookOnTarget:(id)target {
    if (!target) return;
    static NSMutableSet<NSString *> *hooked = nil;
    if (!hooked) hooked = [NSMutableSet set];
    Class tcls = object_getClass(target);
    NSString *name = NSStringFromClass(tcls) ?: @"?";
    if ([hooked containsObject:name]) return;
    [hooked addObject:name];
    SEL sSel = @selector(collectionView:layout:sizeForItemAtIndexPath:);
    Method sm = class_getInstanceMethod(tcls, sSel);
    if (sm) {
        IMP origS = method_getImplementation(sm);
        IMP newImpS = imp_implementationWithBlock(^(id selfV, UICollectionView *c2, UICollectionViewLayout *layout, NSIndexPath *ip) {
            if ([HFBlacklist isRowBlocked:ip list:c2]) return CGSizeZero;
            return ((CGSize (*)(id, SEL, UICollectionView *, UICollectionViewLayout *, NSIndexPath *))origS)(selfV, sSel, c2, layout, ip);
        });
        method_setImplementation(sm, newImpS);
        NSLog(@"[HideFriends] sizeForItem hook installed on real target %@", name);
    }
}

/// v1.3.29：hook proxy 的转发入口——快转发 + 慢转发双覆盖，
/// 顺转发链动态发现并 hook 真正的行高计算 target。
static void hf_installProxyForwardHook(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class proxyCls = NSClassFromString(@"BSTTableViewDelegateOptProxy");
    if (!proxyCls) return;
    installed = YES;
    // 1) forwardingTargetForSelector:（快转发）
    SEL fSel = @selector(forwardingTargetForSelector:);
    Method m = class_getInstanceMethod(proxyCls, fSel);
    if (m) {
        IMP orig = method_getImplementation(m);
        IMP newImp = imp_implementationWithBlock(^(id selfV, SEL sel) {
            id target = ((id (*)(id, SEL, SEL))orig)(selfV, fSel, sel);
            // 拦截高度/尺寸查询，顺转发链 hook 真实 target——这是关注/粉丝列表
            // 行高归零的关键（v1.3.65 在 proxy 上直接 hook 无效，sizeForItem=0）。
            if (target) {
                if (sel == @selector(tableView:heightForRowAtIndexPath:)) {
                    [HFBlacklist installHeightHookOnTarget:target];
                } else if (sel == @selector(collectionView:layout:sizeForItemAtIndexPath:)) {
                    [HFBlacklist installSizeForItemHookOnTarget:target];
                }
            }
            return target;
        });
        method_setImplementation(m, newImp);
    }
    // 2) forwardInvocation:（慢转发兜底）
    SEL fiSel = @selector(forwardInvocation:);
    Method m2 = class_getInstanceMethod(proxyCls, fiSel);
    if (m2) {
        IMP orig2 = method_getImplementation(m2);
        IMP newImp2 = imp_implementationWithBlock(^(id selfV, NSInvocation *inv) {
            SEL sel = inv.selector;
            if (sel == @selector(tableView:heightForRowAtIndexPath:)) {
                UITableView *tv = nil;
                if (inv.methodSignature.numberOfArguments > 2) [inv getArgument:&tv atIndex:2];
                NSIndexPath *ip = nil;
                if (inv.methodSignature.numberOfArguments > 3) [inv getArgument:&ip atIndex:3];
                if (ip && [HFBlacklist isRowBlocked:ip list:tv]) {
                    CGFloat zero = 0;
                    [inv setReturnValue:&zero];
                    return;
                }
            } else if (sel == @selector(collectionView:layout:sizeForItemAtIndexPath:)) {
                // 慢转发兜底：直接拦截返回值（拿不到真实 target 也保证行归零）
                UICollectionView *c2 = nil;
                if (inv.methodSignature.numberOfArguments > 2) [inv getArgument:&c2 atIndex:2];
                NSIndexPath *ip = nil;
                if (inv.methodSignature.numberOfArguments > 4) [inv getArgument:&ip atIndex:4];
                if (ip && [HFBlacklist isRowBlocked:ip list:c2]) {
                    CGSize zero = CGSizeZero;
                    [inv setReturnValue:&zero];
                    return;
                }
            }
            ((void (*)(id, SEL, NSInvocation *))orig2)(selfV, fiSel, inv);
        });
        method_setImplementation(m2, newImp2);
    }
    NSLog(@"[HideFriends] proxy forward hook installed");
}

/// v1.3.69：hook 关注/粉丝列表的 CollectionView delegate proxy（BSTCollectionViewDelegateProxy）
/// 的转发入口。此前 hf_installProxyForwardHook 只 hook 了 TableView 的 BSTTableViewDelegateOptProxy，
/// 而关注/粉丝列表的 collectionView delegate 是另一个 proxy（BSTCollectionViewDelegateProxy），
/// sizeForItemAtIndexPath 经它转发到真实 target，导致我们的尺寸归零钩子一直没生效（sizeForItem=0）。
static void hf_installCollectionProxyForwardHook(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class proxyCls = NSClassFromString(@"BSTCollectionViewDelegateProxy");
    if (!proxyCls) return;
    installed = YES;
    // 1) forwardInvocation:（慢转发兜底——直接拦截 sizeForItem 返回值，保证行归零）
    SEL fiSel = @selector(forwardInvocation:);
    Method m = class_getInstanceMethod(proxyCls, fiSel);
    if (m) {
        IMP orig = method_getImplementation(m);
        IMP newImp = imp_implementationWithBlock(^(id selfV, NSInvocation *inv) {
            SEL sel = inv.selector;
            if (sel == @selector(collectionView:layout:sizeForItemAtIndexPath:)) {
                UICollectionView *c2 = nil;
                if (inv.methodSignature.numberOfArguments > 2) [inv getArgument:&c2 atIndex:2];
                NSIndexPath *ip = nil;
                if (inv.methodSignature.numberOfArguments > 4) [inv getArgument:&ip atIndex:4];
                if (ip && [HFBlacklist isRowBlocked:ip list:c2]) {
                    CGSize zero = CGSizeZero;
                    [inv setReturnValue:&zero];
                    return;
                }
            }
            ((void (*)(id, SEL, NSInvocation *))orig)(selfV, fiSel, inv);
        });
        method_setImplementation(m, newImp);
    }
    // 2) forwardingTargetForSelector:（快转发——顺转发链 hook 真实 target）
    SEL fSel = @selector(forwardingTargetForSelector:);
    Method m2 = class_getInstanceMethod(proxyCls, fSel);
    if (m2) {
        IMP orig2 = method_getImplementation(m2);
        IMP newImp2 = imp_implementationWithBlock(^(id selfV, SEL sel) {
            id target = ((id (*)(id, SEL, SEL))orig2)(selfV, fSel, sel);
            if (target && sel == @selector(collectionView:layout:sizeForItemAtIndexPath:)) {
                [HFBlacklist installSizeForItemHookOnTarget:target];
            }
            return target;
        });
        method_setImplementation(m2, newImp2);
    }
    NSLog(@"[HideFriends] collection proxy forward hook installed");
}

/// v1.3.67：hook UICollectionViewLayout 的 layout attributes——关注/粉丝列表是
/// UICollectionView，ListKit 的 cell 尺寸不走标准 delegate 的 sizeForItemAtIndexPath
/// （诊断 sizeForItem=0 证明 delegate 钩子根本没被调用），而是由 layout attributes 决定。
/// 这里直接对标记行返回 size=0，让命中 cell 真正消失，不留 80pt 空白框。
/// 只改「黑名单行」的 attributes，其余行零影响；不 setFrame、不改约束，避免布局递归卡死。
static void hf_installCollectionLayoutHook(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    // v1.3.70：此前只 hook UICollectionViewLayout 基类，但 ListKit 的 AWEBaseListFlowLayout
    // 重写了 attributes 方法且不调 super，基类 hook 拦不到（诊断 sizeForItem 一直为 0）。
    // 这里改为 hook 具体 layout 类 + 父类兜底，按类去重避免重复 hook。
    void (^installForClass)(Class) = ^(Class layoutCls) {
        if (!layoutCls) return;
        static NSMutableSet<NSString *> *hooked = nil;
        if (!hooked) hooked = [NSMutableSet set];
        NSString *nm = NSStringFromClass(layoutCls);
        if ([hooked containsObject:nm]) return;
        [hooked addObject:nm];
        // 1) layoutAttributesForItemAtIndexPath:（单 cell 尺寸查询）
        SEL s1 = @selector(layoutAttributesForItemAtIndexPath:);
        Method m1 = class_getInstanceMethod(layoutCls, s1);
        if (m1) {
            IMP orig1 = method_getImplementation(m1);
            IMP new1 = imp_implementationWithBlock(^(id selfV, NSIndexPath *ip) {
                UICollectionViewLayoutAttributes *attr =
                    ((UICollectionViewLayoutAttributes *(*)(id, SEL, NSIndexPath *))orig1)(selfV, s1, ip);
                if (attr && [HFBlacklist isRowBlocked:ip list:[selfV collectionView]]) {
                    attr.size = CGSizeZero;
                }
                return attr;
            });
            method_setImplementation(m1, new1);
        }
        // 2) layoutAttributesForElementsInRect:（批量尺寸查询，滚动/布局主入口）
        SEL s2 = @selector(layoutAttributesForElementsInRect:);
        Method m2 = class_getInstanceMethod(layoutCls, s2);
        if (m2) {
            IMP orig2 = method_getImplementation(m2);
            IMP new2 = imp_implementationWithBlock(^(id selfV, CGRect rect) {
                NSArray *arr = ((NSArray *(*)(id, SEL, CGRect))orig2)(selfV, s2, rect);
                if (!arr || arr.count == 0) return arr;
                // v1.3.72：命中行尺寸归零后，必须把「后续行」的 y 坐标上移，否则只把
                // cell 高度改 0 但 layout 在 prepare 阶段已按 80pt 排好位置，后续 cell 不
                // 上移 → 命中行位置留 80pt 空白。这里按 y 排序后累加上移偏移量。
                NSArray *sorted = [arr sortedArrayUsingComparator:^NSComparisonResult(UICollectionViewLayoutAttributes *a, UICollectionViewLayoutAttributes *b) {
                    if (a.frame.origin.y < b.frame.origin.y) return NSOrderedAscending;
                    if (a.frame.origin.y > b.frame.origin.y) return NSOrderedDescending;
                    if (a.frame.origin.x < b.frame.origin.x) return NSOrderedAscending;
                    if (a.frame.origin.x > b.frame.origin.x) return NSOrderedDescending;
                    return NSOrderedSame;
                }];
                CGFloat offset = 0;
                id list = [selfV collectionView];   // v1.3.73：行缓存带列表标识，这里取所属 collectionView
                for (UICollectionViewLayoutAttributes *attr in sorted) {
                    if (attr && [HFBlacklist isRowBlocked:attr.indexPath list:list]) {
                        offset += attr.size.height;   // 该行高度归零，后续行累计上移
                        attr.size = CGSizeZero;
                    } else if (offset > 0) {
                        CGRect f = attr.frame;
                        f.origin.y -= offset;
                        attr.frame = f;
                    }
                }
                return arr;
            });
            method_setImplementation(m2, new2);
        }
    };
    // 具体 layout 类优先（ListKit 自定义），父类兜底
    installForClass(NSClassFromString(@"AWEBaseListFlowLayout"));
    installForClass(NSClassFromString(@"IESSegmentedCollectionViewFlowLayout"));
    installForClass(NSClassFromString(@"AWEUserWorkFlowLayout"));
    // v1.3.75：消息页"限时日常"窗口的 layout（横向滚动 Skylight），单独 hook 保证尺寸归零
    installForClass(NSClassFromString(@"AWELiveSkylightNormalLayout"));
    installForClass([UICollectionViewFlowLayout class]);
    installForClass([UICollectionViewLayout class]);
    NSLog(@"[HideFriends] collection layout hook installed (multi-class)");
}

/// 主动扫描隐藏：遍历所有 window 的所有可见列表 cell，
/// 命中的立即隐藏——不依赖 willDisplayCell（已显示的 cell 也会被处理）。
+ (void)scanAndHideVisibleCells {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self scanAndHideVisibleCells];
        });
        return;
    }
    if (!HFGetBool(HF_KEY_BLACKLIST_ENABLED)) return;
    NSArray *ids = [self blockedIDs];
    // 黑名单为空时也继续遍历 cell 标记互关好友（供「添加好友」页）。
    // 之前 ids.count==0 直接 return，导致互关好友集合永远为空。
    NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *w in windows) {
        if (!w.rootViewController) continue;
        NSMutableArray<UIScrollView *> *lists = [NSMutableArray array];
        [self collectListsInView:w.rootViewController.view into:lists max:8];
        for (UIScrollView *list in lists) {
            NSArray<UIView *> *cells = nil;
            if ([list isKindOfClass:[UITableView class]]) {
                cells = [(UITableView *)list visibleCells];
            } else if ([list isKindOfClass:[UICollectionView class]]) {
                cells = [(UICollectionView *)list visibleCells];
            }
            for (UIView *cell in cells) {
                if (!cell) continue;
                // 标记互关好友（无论黑名单是否为空——「添加好友」页依赖它）
                [self markMutualFollowCell:cell userObj:nil];
                if (ids.count == 0) continue;   // 黑名单为空：只标记，不做匹配隐藏
                // v1.3.20：记录 cell → indexPath（行高钩子用）
                NSIndexPath *ip = nil;
                if ([list isKindOfClass:[UITableView class]]) {
                    ip = [(UITableView *)list indexPathForCell:(UITableViewCell *)cell];
                } else if ([list isKindOfClass:[UICollectionView class]]) {
                    ip = [(UICollectionView *)list indexPathForCell:(UICollectionViewCell *)cell];
                }
                if (ip) objc_setAssociatedObject(cell, &kHFIndexPathKey, ip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                // v1.3.15：标记只用于上报去重，不跳过隐藏——cell 复用到目标内容时每次重新隐藏
                BOOL alreadyReported = [objc_getAssociatedObject(cell, &kHFHiddenFlagKey) boolValue];
                // v1.3.24：轻量匹配优先（chat 容器直查），未命中再走完整匹配
                NSDictionary *match = [self matchChatInCellQuick:cell];
                if (!match) match = [self blockedMatchInCell:cell];
                if (match) {
                    [self hideCellIfContainsBlockedUser:cell];
                    // 黑名单行入缓存（行高钩子 O(1) 归零）
                    NSIndexPath *tip = objc_getAssociatedObject(cell, &kHFIndexPathKey);
                    if (tip) [self markRowBlocked:tip list:list];
                    // 触发单行 reload（行高归零重算，10 秒节流）
                    if (tip && [list isKindOfClass:[UITableView class]]) {
                        [self scheduleRowHeightReload:(UITableView *)list indexPath:tip];
                    }
                } else if (alreadyReported) {
                    // cell 复用了非目标内容：统一恢复显示 + 清标记（避免误伤正常内容）
                    [self restoreCellState:cell];
                    NSIndexPath *tip = objc_getAssociatedObject(cell, &kHFIndexPathKey);
                    if (tip) [self unmarkRowBlocked:tip list:list];
                }
            }
        }
    }
}

/// v1.2.2：直接在 cell 上读取用户标识字符串字段与黑名单比对（不依赖找到用户模型）
/// v1.3.0：cell.userID（UID）→ 查注册表得到抖音号 → 比对黑名单
+ (NSDictionary *)cellDirectFieldMatch:(UIView *)cell {
    if (!cell) return nil;
    NSArray *ids = [self blockedIDs];
    if (ids.count == 0) return nil;
    NSArray *directKeys = @[ @"userID", @"userId", @"shortID", @"uniqueID",
                             @"secUid", @"uid", @"douyinId", @"nickname" ];
    for (NSString *k in directKeys) {
        NSString *v = hf_stringProperty(cell, k);
        if (v.length == 0) continue;
        NSString *lowerV = v.lowercaseString;
        for (NSString *bid in ids) {
            if (bid.length == 0) continue;
            if ([v isEqualToString:bid] || [lowerV isEqualToString:bid.lowercaseString]) {
                return @{ @"blocked_id": v, @"matched_field": k };
            }
        }
        if ([k isEqualToString:@"nickname"]) {
            for (NSString *bid in ids) {
                if (bid.length > 0 && [v containsString:bid]) {
                    return @{ @"blocked_id": v, @"matched_field": k };
                }
            }
        }
    }
    // v1.3.0 方案D：cell 的 UID → 查注册表 → 得抖音号/昵称 → 比对黑名单
    // v1.3.9：UID 来源扩展——cell 直接字段取不到时，穿透 cellViewModel/viewModel→conversation/user 取 UID
    NSString *cellUid = hf_stringProperty(cell, @"userID");
    if (cellUid.length == 0) cellUid = hf_stringProperty(cell, @"userId");
    if (cellUid.length == 0) cellUid = hf_stringProperty(cell, @"uid");
    if (cellUid.length == 0) cellUid = hf_findUidDeep(cell);   // v1.3.9 ViewModel 穿透
    if (cellUid.length > 0) {
        NSString *dyId = [self douyinIDForUid:cellUid];
        if (dyId.length > 0) {
            for (NSString *bid in ids) {
                if (bid.length > 0 &&
                    ([dyId isEqualToString:bid] || [dyId.lowercaseString isEqualToString:bid.lowercaseString])) {
                    return @{ @"blocked_id": dyId, @"matched_field": @"uid→douyinID(registry)" };
                }
            }
        }
        NSString *nick = [self nicknameForUid:cellUid];
        if (nick.length > 0) {
            for (NSString *bid in ids) {
                if (bid.length > 0 && [nick containsString:bid]) {
                    return @{ @"blocked_id": nick, @"matched_field": @"uid→nickname(registry)" };
                }
            }
        }
    }
    return nil;
}

/// v1.3.11 黑名单显示名集合：黑名单抖音号 + 注册表反查的昵称（消息页显示昵称，必须用昵称匹配）
/// v1.3.52：加缓存——原实现每次 cell 匹配都遍历整个注册表（数千条）反查昵称，
/// 是刷视频卡顿主因之一。黑名单/注册表变化频率远低于 cell 匹配频率，黑名单变更时失效即可。
+ (NSArray<NSString *> *)blacklistDisplayNames {
    if (gBlacklistDisplayNamesCache) return gBlacklistDisplayNamesCache;
    NSArray *ids = [self blockedIDs];
    if (ids.count == 0) {
        gBlacklistDisplayNamesCache = @[];
        return gBlacklistDisplayNamesCache;
    }
    NSMutableArray *names = [ids mutableCopy];
    if (gUserRegistry.count > 0) {
        [gRegistryLock lock];
        for (NSString *bid in ids) {
            if (bid.length == 0) continue;
            for (NSString *uidKey in gUserRegistry) {
                NSDictionary *e = gUserRegistry[uidKey];
                NSString *dy = e[@"uniqueID"];
                if (dy.length == 0) dy = e[@"shortID"];
                if (dy.length > 0 && [dy isEqualToString:bid]) {
                    NSString *nick = e[@"nickname"];
                    if (nick.length > 0 && ![names containsObject:nick]) {
                        [names addObject:nick];
                    }
                    break;
                }
            }
        }
        [gRegistryLock unlock];
    }
    gBlacklistDisplayNamesCache = [names copy];
    return gBlacklistDisplayNamesCache;
}

/// v1.3.4 UI 文本兜底匹配：遍历 cell 全部子视图的 UILabel 文本，
/// 与黑名单（抖音号/昵称）比对——不猜数据结构，界面上显示了目标即命中。
/// v1.3.11：匹配集合加入注册表反查的昵称（消息页显示昵称，不显示抖音号）
/// 安全：只读 .text；每 cell ≤ 80 个视图；文本精确或包含（bid 长度 ≥ 4）匹配。
+ (BOOL)cellTextMatchesBlacklist:(UIView *)cell {
    if (!cell) return NO;
    NSArray *names = [self blacklistDisplayNames];
    if (names.count == 0) return NO;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell];
    NSInteger scanned = 0;
    NSCharacterSet *nonDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    while (queue.count > 0 && scanned < 80) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        scanned++;
        if (!v) continue;
        if ([v isKindOfClass:[UILabel class]]) {
            NSString *text = ((UILabel *)v).text;
            if (text.length > 0 && text.length <= 64) {
                for (NSString *bid in names) {
                    if (bid.length == 0) continue;
                    // 精确匹配：抖音号 / UID / 昵称完全一致
                    if ([text isEqualToString:bid]) return YES;
                    // 包含匹配仅对「非纯数字」黑名单（昵称）生效，且文本需较短（≈用户名/昵称标签）。
                    // 纯数字黑名单（如 8 位抖音号）不再做 substring 包含，避免误匹配到
                    // 任意包含该数字的长文本/容器 cell，导致整个 Tab 分区被误隐藏。
                    BOOL isNumeric = [bid rangeOfCharacterFromSet:nonDigit].location == NSNotFound;
                    if (!isNumeric && bid.length >= 2 && text.length <= 20 &&
                        [text containsString:bid]) {
                        return YES;
                    }
                }
            }
        }
        if (v.subviews.count > 0) {
            [queue addObjectsFromArray:v.subviews];
        }
    }
    return NO;
}

/// v1.1.0：返回 cell 命中黑名单的详情（blocked_id + matched_field），供 HFReporter 上报
+ (NSDictionary *)blockedMatchInCell:(UIView *)cell {
    if (!cell) return nil;
    id userObj = [self findUserObjectInObject:cell];
    NSArray *ids = [self blockedIDs];
    if (ids.count == 0) return nil;
    // v1.3.36：深度登记——扫描遍历到任何用户 cell 时，把顶层+内部模型的
    // UID↔抖音号补录进注册表。互关列表命中时内部 userModel 有抖音号，登记后
    // 关注/粉丝列表（只有 userID/UID）才能反查命中。
    if (userObj) [self registerDeepModels:userObj];
    // v1.3.47：互关列表 cell 的用户标记为互关好友（供「添加好友」页只展示互关）
    [self markMutualFollowCell:cell userObj:userObj];
    if (userObj) {
        // 与 isUserObjectBlocked 相同的字段合并逻辑
        NSMutableArray *fields = [NSMutableArray arrayWithObjects:
            @"shortID", @"uniqueID", @"secUid", @"uid", @"douyinId", @"userId", @"userID", @"nickname", nil];
        for (NSString *f in [HFDiscovery detectedIDFields]) {
            if (![fields containsObject:f]) [fields addObject:f];
        }
        for (NSString *f in [HFDiscovery detectedNameFields]) {
            if (![fields containsObject:f]) [fields addObject:f];
        }
        for (NSString *field in fields) {
            NSString *v = hf_stringProperty(userObj, field);
            if (v.length == 0) continue;
            NSString *lowerV = v.lowercaseString;
            for (NSString *bid in ids) {
                if (bid.length == 0) continue;
                if ([v isEqualToString:bid] || [lowerV isEqualToString:bid.lowercaseString]) {
                    return @{ @"blocked_id": v, @"matched_field": field };
                }
            }
            if ([field isEqualToString:@"nickname"] || [field isEqualToString:@"name"]) {
                for (NSString *bid in ids) {
                    if (bid.length > 0 && [v containsString:bid]) {
                        return @{ @"blocked_id": v, @"matched_field": field };
                    }
                }
            }
        }
    }
    // v1.3.35：复用 isUserObjectBlocked 完整匹配（含 innerKeys 穿透 / 注册表反查），
    // 修复"诊断命中但扫描不隐藏"——关注/粉丝/互关列表 cell（AWEAdaptorUserModel）
    // 抖音号藏在内部模型（userModel/user），上面字段循环只查了外层取不到 → 扫描漏判
    if (userObj && [self isUserObjectBlocked:userObj]) {
        return @{ @"blocked_id": [self blockedIDs].firstObject ?: @"?", @"matched_field": @"user-obj-deep" };
    }
    // v1.2.2：cell 直接字段匹配兜底
    NSDictionary *direct = [self cellDirectFieldMatch:cell];
    if (direct) return direct;
    // v1.3.9：会话模型深度匹配（userObj 是 AWEIMMessageConversation 等，自身无用户字段）
    if (userObj) {
        NSString *deepUid = hf_findUidDeep(userObj);
        if (deepUid.length > 0) {
            NSString *dyId = [self douyinIDForUid:deepUid];
            if (dyId.length > 0) {
                for (NSString *bid in ids) {
                    if (bid.length > 0 &&
                        ([dyId isEqualToString:bid] || [dyId.lowercaseString isEqualToString:bid.lowercaseString])) {
                        return @{ @"blocked_id": dyId, @"matched_field": @"conversation→uid(registry)" };
                    }
                }
            }
        }
    }
    // v1.3.17：chat 容器直查——cellViewModel.chat（实测 AWEIMOfficialChatModel）
    // 全属性与黑名单比对，不依赖注册表反查（12214274 不在注册表时仍可命中）
    {
        id chatObj = nil;
        NSArray *vmKeys2 = @[ @"cellViewModel", @"viewModel", @"cellModel", @"model", @"itemModel" ];
        for (NSString *vk2 in vmKeys2) {
            id vm2 = hf_safeKV(cell, vk2);
            if (!vm2 || vm2 == cell || hf_isProxy(vm2)) continue;
            for (NSString *ck2 in @[ @"chat", @"conversation", @"conversationInfo", @"session" ]) {
                id cv2 = hf_safeKV(vm2, ck2);
                if (!cv2 || cv2 == vm2 || hf_isProxy(cv2)) continue;
                chatObj = cv2;
                break;
            }
            if (chatObj) break;
        }
        if (!chatObj) {
            for (NSString *ck2 in @[ @"chat", @"conversation" ]) {
                id cv2 = hf_safeKV(cell, ck2);
                if (cv2 && cv2 != cell && !hf_isProxy(cv2)) { chatObj = cv2; break; }
            }
        }
        if (chatObj) {
            NSDictionary *chatMatch = [self matchBlacklistInObjectDeep:chatObj];
            if (chatMatch) return chatMatch;
        }
    }
    // v1.3.4：UI 文本兜底匹配
    if ([self cellTextMatchesBlacklist:cell]) {
        return @{ @"blocked_id": [self blockedIDs].firstObject ?: @"?", @"matched_field": @"ui-text" };
    }
    return nil;
}

/// v1.3.17：对象全属性黑名单匹配——遍历对象全部属性：
/// ① 字符串值：与黑名单精确比对（≥6 位黑名单额外做包含比对，兼容"抖音号：xxx"格式）；
/// ② 用户对象属性：取其 uniqueID/shortID/nickname 等标识字段比对。
/// 用于 chat 容器（AWEIMOfficialChatModel）直查，不依赖 UID↔抖音号注册表。
+ (NSDictionary *)matchBlacklistInObjectDeep:(id)obj {
    if (!obj || hf_isProxy(obj)) return nil;
    NSArray *ids = [self blockedIDs];
    if (ids.count == 0) return nil;
    NSArray *idFields = @[ @"uniqueID", @"shortID", @"secUid", @"douyinId",
                           @"uid", @"userId", @"userID", @"nickname", @"dy" ];
    BOOL (^matchStr)(NSString *) = ^BOOL(NSString *v) {
        for (NSString *bid in ids) {
            if (bid.length == 0) continue;
            if ([v isEqualToString:bid] || [v.lowercaseString isEqualToString:bid.lowercaseString]) return YES;
        }
        return NO;
    };
    // 1) 对象自身若是用户对象：标识字段直比
    if (hf_looksLikeUserObject(obj)) {
        for (NSString *f in idFields) {
            NSString *v = hf_stringProperty(obj, f);
            if (v.length > 0 && matchStr(v)) {
                return @{ @"blocked_id": v, @"matched_field": [@"chat." stringByAppendingString:f] };
            }
        }
    }
    // 2) 全属性扫描（类+父类链，v1.3.18 修复：peerID/peerUser 定义在父类上，
    //    单层 class_copyPropertyList 扫不到）：字符串值直比 + 用户对象字段比
    NSMutableSet<NSString *> *seenProps = [NSMutableSet set];
    NSInteger scanned = 0;
    Class cls = object_getClass(obj);
    while (cls && cls != [NSObject class] && scanned < 60) {
        unsigned int count = 0;
        objc_property_t *props = class_copyPropertyList(cls, &count);
        for (unsigned i = 0; i < count && scanned < 60; i++) {
            const char *pn = property_getName(props[i]);
            if (!pn) continue;
            NSString *name = [NSString stringWithUTF8String:pn];
            if (name.length == 0 || [seenProps containsObject:name]) continue;
            [seenProps addObject:name];
            id v = hf_safeKV(obj, name);
            if (!v || hf_isProxy(v)) continue;
            scanned++;
            if ([v isKindOfClass:[NSString class]]) {
                NSString *s = (NSString *)v;
                if (s.length == 0 || s.length > 64) continue;
                if (matchStr(s)) {
                    free(props);
                    return @{ @"blocked_id": s, @"matched_field": [@"chat." stringByAppendingString:name] };
                }
            } else if (hf_looksLikeUserObject(v)) {
                for (NSString *f in idFields) {
                    NSString *sv = hf_stringProperty(v, f);
                    if (sv.length == 0) continue;
                    for (NSString *bid in ids) {
                        if (bid.length > 0 && ([sv isEqualToString:bid] ||
                                               [sv.lowercaseString isEqualToString:bid.lowercaseString])) {
                            free(props);
                            return @{ @"blocked_id": sv, @"matched_field": [@"chat." stringByAppendingString:name] };
                        }
                    }
                }
            }
        }
        free(props);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

#pragma mark - 通知与刷新

+ (void)postBlacklistChangedNotification {
    [self bumpChatCacheVersion];   // v1.3.26：黑名单变更使 chat 命中缓存失效
    [[NSNotificationCenter defaultCenter] postNotificationName:HF_BLACKLIST_CHANGED_NOTIFICATION object:nil];
}

+ (void)reloadAllListsInView:(UIView *)view {
    if (!view) return;
    if ([view isKindOfClass:[UICollectionView class]]) {
        [(UICollectionView *)view reloadData];
    } else if ([view isKindOfClass:[UITableView class]]) {
        [(UITableView *)view reloadData];
    }
    for (UIView *sub in view.subviews) {
        [self reloadAllListsInView:sub];
    }
}


/// 收集视图层级中的可滚动列表（v1.1.9：深入嵌套容器，最多 max 个）
+ (void)collectListsInView:(UIView *)view into:(NSMutableArray<UIScrollView *> *)outArray max:(NSInteger)max {
    if (!view || outArray.count >= max) return;
    if ([view isKindOfClass:[UITableView class]] || [view isKindOfClass:[UICollectionView class]]) {
        // 去重加入（Tab 容器内嵌的关注/粉丝/作品子列表也要收集，不再 return 截断）
        if (![outArray containsObject:view]) {
            [outArray addObject:(UIScrollView *)view];
        }
    }
    for (UIView *sub in view.subviews) {
        [self collectListsInView:sub into:outArray max:max];
    }
}

#pragma mark - v1.3.0 用户注册表（方案D：UID↔抖音号映射）

/// 登记一个用户对象（读 uid/uniqueID/shortID/nickname 入表，幂等）
/// v1.3.34：注册表持久化——UID↔抖音号映射写入 NSUserDefaults，重启不丢
/// （否则重启后注册表清空，关注/粉丝/互关列表无法通过 UID 反查匹配黑名单）
+ (void)persistRegistry {
    if (!gUserRegistry) return;
    // v1.3.39 性能修复：注册表会被 KVC/setter 钩子高频触发（每渲染一个用户 cell 都可能
    // 触发多次），原实现每次都在主线程做 JSON 序列化 + synchronize 同步磁盘写，是卡顿主因。
    // 改为 3 秒节流 + 后台持久化：主线程只做内存合并，绝不阻塞 UI。
    // v1.3.53 再优化：JSON 序列化原本在持有 gRegistryLock 的情况下进行，锁会被占用几十 ms，
    // 期间主线程匹配读注册表（douyinIDForUid 等）全部阻塞。改为先短锁浅拷贝快照，
    // 解锁后再序列化，锁持有时间从「几十 ms」降到「一次字典拷贝」。
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - gLastPersistTs < 3.0) {
        return;
    }
    gLastPersistTs = now;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [gRegistryLock lock];
        NSDictionary *snapshot = [gUserRegistry copy];   // 浅拷贝，快速
        [gRegistryLock unlock];
        NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
        if (data) {
            [[NSUserDefaults standardUserDefaults] setObject:data forKey:HF_REGISTRY_CACHE];
        }
    });
}

/// v1.3.34：启动时恢复注册表
+ (void)loadRegistry {
    NSData *data = [[NSUserDefaults standardUserDefaults] dataForKey:HF_REGISTRY_CACHE];
    if (!data) return;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        if (!gRegistryLock) gRegistryLock = [[NSLock alloc] init];
        [gRegistryLock lock];
        if (!gUserRegistry) gUserRegistry = [NSMutableDictionary dictionary];
        [gUserRegistry addEntriesFromDictionary:obj];
        [gRegistryLock unlock];
    }
}

/// v1.3.38：底层登记入口——把 UID + 抖音号 + 昵称合并写进注册表（保留旧非空值）。
/// 供 registerUserObject 与消息列表（conversationID 解析 UID + peerUser 抖音号）复用。
+ (void)registerUid:(NSString *)uid
           uniqueID:(NSString *)uniqueID
            shortID:(NSString *)shortID
           nickname:(NSString *)nickname {
    if (uid.length < 8 || uid.length > 25) return;
    NSCharacterSet *nonDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([uid rangeOfCharacterFromSet:nonDigit].location != NSNotFound) return;
    if (!gRegistryLock) gRegistryLock = [[NSLock alloc] init];
    [gRegistryLock lock];
    if (!gUserRegistry) gUserRegistry = [NSMutableDictionary dictionary];
    // 合并而非覆盖：关注/粉丝/互关列表的 ViewModel 只有 UID 没有抖音号，
    // 直接覆盖会把此前从消息列表/推荐流捕获到的「UID→抖音号」映射清空。保留旧非空值。
    NSDictionary *existing = gUserRegistry[uid];
    NSDictionary *entry = @{
        @"uniqueID": (uniqueID.length > 0 ? uniqueID : (existing[@"uniqueID"] ?: @"")),
        @"shortID":  (shortID.length > 0  ? shortID  : (existing[@"shortID"]  ?: @"")),
        @"nickname": (nickname.length > 0 ? nickname : (existing[@"nickname"] ?: @"")),
    };
    gUserRegistry[uid] = entry;
    [gRegistryLock unlock];
    [self persistRegistry];
}

/// 登记一个用户对象（读 uid/uniqueID/shortID/nickname 入表，幂等）
+ (void)registerUserObject:(id)userObj {
    if (!userObj || hf_isProxy(userObj)) return;
    if (hf_clsIsKindOf(object_getClass(userObj), [UIView class])) return;  // 视图不登记
    NSString *uid = hf_stringProperty(userObj, @"uid");
    if (uid.length == 0) uid = hf_stringProperty(userObj, @"userId");
    if (uid.length == 0) uid = hf_stringProperty(userObj, @"userID");
    if (uid.length == 0) return;   // 无 UID 不登记
    NSString *uniqueID = hf_stringProperty(userObj, @"uniqueID");
    NSString *shortID = hf_stringProperty(userObj, @"shortID");
    NSString *nickname = hf_stringProperty(userObj, @"nickname");
    if (nickname.length == 0) nickname = hf_stringProperty(userObj, @"nick");   // v1.3.43：昵称字段兼容 nick
    [self registerUid:uid uniqueID:uniqueID shortID:shortID nickname:nickname];
}

/// v1.3.36：深度登记——把对象及其内部用户模型都登记进注册表。
/// 解决关注/粉丝列表隐藏：互关列表的 AWEAdaptorUserModel 顶层无 UID，
/// UID+抖音号藏在内部 userModel 里，registerUserObject 只查顶层导致登记失败
/// → 关注/粉丝列表（只有 userID/UID）反查不到抖音号。
+ (void)registerDeepModels:(id)obj {
    if (!obj || hf_isProxy(obj)) return;
    [self registerUserObject:obj];
    NSArray *innerKeys = @[ @"user", @"userModel", @"targetUser", @"aweme", @"awemeModel", @"author" ];
    for (NSString *k in innerKeys) {
        id inner = hf_safeKV(obj, k);
        if (!inner || inner == obj || hf_isProxy(inner)) continue;
        [self registerUserObject:inner];
    }
}

/// 根据 UID 查询抖音号（uniqueID 优先，其次 shortID）
+ (NSString *)douyinIDForUid:(NSString *)uid {
    if (uid.length == 0 || !gUserRegistry) return nil;
    [gRegistryLock lock];
    NSDictionary *e = gUserRegistry[uid];
    [gRegistryLock unlock];
    if (!e) return nil;
    NSString *u = e[@"uniqueID"];
    if (u.length > 0) return u;
    NSString *s = e[@"shortID"];
    if (s.length > 0) return s;
    return nil;
}

/// 根据 UID 查询昵称
+ (NSString *)nicknameForUid:(NSString *)uid {
    if (uid.length == 0 || !gUserRegistry) return nil;
    [gRegistryLock lock];
    NSDictionary *e = gUserRegistry[uid];
    [gRegistryLock unlock];
    return e[@"nickname"];
}

/// v1.3.2：返回已捕获用户列表（uid/抖音号/昵称），供设置页选择加入黑名单
+ (NSArray<NSDictionary *> *)knownUsers {
    if (!gUserRegistry) return @[];
    [gRegistryLock lock];
    NSMutableArray *arr = [NSMutableArray array];
    for (NSString *uid in gUserRegistry) {
        NSDictionary *e = gUserRegistry[uid];
        [arr addObject:@{
            @"uid": uid,
            @"uniqueID": e[@"uniqueID"] ?: @"",
            @"shortID": e[@"shortID"] ?: @"",
            @"nickname": e[@"nickname"] ?: @"",
        }];
    }
    [gRegistryLock unlock];
    // 按昵称排序
    [arr sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"nickname"] compare:b[@"nickname"]];
    }];
    return arr;
}

/// v1.3.56：从任意用户模型提取互关好友信息（抖音号 + 昵称 + UID），存入互关集合。
/// 重构：不再依赖「猜 UID 字段名」——以抖音号为主标识（之前黑名单能命中靠的就是抖音号），
/// 顶层读不到就穿透内部 userModel/user；有抖音号或昵称或 UID 任一即可入集。
+ (void)markMutualFollowModel:(id)model {
    if (!model || hf_isProxy(model)) return;
    NSString *dyId = hf_stringProperty(model, @"uniqueID");
    if (dyId.length == 0) dyId = hf_stringProperty(model, @"shortID");
    NSString *nick = hf_stringProperty(model, @"nickname");
    if (nick.length == 0) nick = hf_stringProperty(model, @"nick");
    NSString *uid = hf_stringProperty(model, @"uid");
    if (uid.length == 0) uid = hf_stringProperty(model, @"userID");
    // 穿透内部用户模型（AWEAdaptorUserModel 顶层可能无抖音号，藏在 userModel/user）
    for (NSString *k in @[ @"userModel", @"user", @"targetUser", @"friendUser" ]) {
        id inner = hf_safeKV(model, k);
        if (!inner || inner == model || hf_isProxy(inner)) continue;
        if (dyId.length == 0) {
            dyId = hf_stringProperty(inner, @"uniqueID");
            if (dyId.length == 0) dyId = hf_stringProperty(inner, @"shortID");
        }
        if (nick.length == 0) {
            nick = hf_stringProperty(inner, @"nickname");
            if (nick.length == 0) nick = hf_stringProperty(inner, @"nick");
        }
        if (uid.length == 0) {
            uid = hf_stringProperty(inner, @"uid");
            if (uid.length == 0) uid = hf_stringProperty(inner, @"userID");
        }
        if (dyId.length > 0 && uid.length > 0) break;
    }
    // v1.3.57：过滤占位符昵称（TEXT、.、？、空白等——列表加载占位，不是真实好友）
    if (nick.length > 0) {
        NSString *t = [nick stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        BOOL isPlaceholder = NO;
        if (t.length == 0 || [t isEqualToString:@"TEXT"]) {
            isPlaceholder = YES;
        } else if (t.length <= 2) {
            BOOL hasAlnumOrCJK = NO;
            for (NSInteger i = 0; i < (NSInteger)t.length; i++) {
                unichar c = [t characterAtIndex:i];
                BOOL alnum = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
                BOOL cjk = (c >= 0x4E00 && c <= 0x9FFF);
                if (alnum || cjk) { hasAlnumOrCJK = YES; break; }
            }
            if (!hasAlnumOrCJK) isPlaceholder = YES;
        }
        if (isPlaceholder) nick = nil;
    }
    if (dyId.length == 0 && nick.length == 0 && uid.length == 0) return;
    NSString *key = dyId.length > 0 ? dyId : (uid.length > 0 ? uid : nick);
    if (!gMutualFollowLock) gMutualFollowLock = [[NSLock alloc] init];
    [gMutualFollowLock lock];
    if (!gMutualFollowUsers) gMutualFollowUsers = [NSMutableDictionary dictionary];
    gMutualFollowUsers[key] = @{
        @"uniqueID": dyId ?: @"",
        @"nickname": nick ?: @"",
        @"uid": uid ?: @"",
    };
    [gMutualFollowLock unlock];
    [self persistMutualFollow];
}

/// v1.3.59：互关好友集合持久化（节流 + 后台，避免重启丢失）
+ (void)persistMutualFollow {
    if (!gMutualFollowUsers) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - gMutualFollowPersistTs < 3.0) return;
    gMutualFollowPersistTs = now;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [gMutualFollowLock lock];
        NSDictionary *snapshot = [gMutualFollowUsers copy];
        [gMutualFollowLock unlock];
        NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
        if (data) {
            [[NSUserDefaults standardUserDefaults] setObject:data forKey:HF_MUTUAL_FOLLOW_CACHE];
        }
    });
}

/// v1.3.59：启动时恢复互关好友集合
+ (void)loadMutualFollow {
    NSData *data = [[NSUserDefaults standardUserDefaults] dataForKey:HF_MUTUAL_FOLLOW_CACHE];
    if (!data) return;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        if (!gMutualFollowLock) gMutualFollowLock = [[NSLock alloc] init];
        [gMutualFollowLock lock];
        if (!gMutualFollowUsers) gMutualFollowUsers = [NSMutableDictionary dictionary];
        [gMutualFollowUsers addEntriesFromDictionary:obj];
        [gMutualFollowLock unlock];
    }
}

/// v1.3.60：从关注列表的 sectionViewModel（AWEFollowListUserListViewModel）一次性拿全量好友。
/// 关注列表的每个 cell 都挂同一个 sectionViewModel，它持有全部好友数组；
/// 遍历它的 NSArray 属性即可拿全量，不用滚动到每个 cell。
+ (void)markMutualFollowFromListViewModel:(id)vm {
    if (!vm || hf_isProxy(vm)) return;
    static NSTimeInterval gLastVMScanTs = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - gLastVMScanTs < 1.0) return;   // 节流：VM 赋值可能高频
    gLastVMScanTs = now;
    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(object_getClass(vm), &count);
    for (unsigned i = 0; i < count; i++) {
        const char *pn = property_getName(props[i]);
        if (!pn) continue;
        NSString *name = [NSString stringWithUTF8String:pn];
        id val = hf_safeKV(vm, name);
        if (![val isKindOfClass:[NSArray class]]) continue;
        NSInteger n = 0;
        for (id item in (NSArray *)val) {
            if (n >= 200) break;
            n++;
            if (!item || hf_isProxy(item)) continue;
            [self markMutualFollowModel:item];
        }
    }
    free(props);
}

/// v1.3.47：互关列表 cell（AWEFeedFriendsListCell）的用户标记为「互关好友」。
/// 「添加好友」页只展示互关好友，不再混入推荐流/消息里碰巧见过的陌生人。
/// 自包含：内部自行查找用户对象 + 登记注册表，不依赖黑名单是否为空。
+ (void)markMutualFollowCell:(UIView *)cell userObj:(id)userObj {
    NSString *cls = NSStringFromClass(cell.class);
    if (![cls isEqualToString:@"AWEFeedFriendsListCell"]) return;
    if (!userObj) userObj = [self findUserObjectInObject:cell];
    if (!userObj) return;
    [self registerDeepModels:userObj];
    [self markMutualFollowModel:userObj];
}

/// v1.3.47：返回互关好友列表（抖音号/昵称/uid），供「添加好友」页选择。
/// 只返回出现在互关列表（AWEFeedFriendsListCell）里的用户。
+ (NSArray<NSDictionary *> *)mutualFollowUsers {
    if (!gMutualFollowLock) gMutualFollowLock = [[NSLock alloc] init];
    [gMutualFollowLock lock];
    NSArray *vals = gMutualFollowUsers ? [gMutualFollowUsers allValues] : @[];
    [gMutualFollowLock unlock];
    NSMutableArray *arr = [NSMutableArray array];
    for (NSDictionary *e in vals) {
        NSString *dy = e[@"uniqueID"] ?: @"";
        [arr addObject:@{
            @"uid": e[@"uid"] ?: @"",
            @"uniqueID": dy,
            @"shortID": dy,
            @"nickname": e[@"nickname"] ?: @"",
        }];
    }
    [arr sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"nickname"] compare:b[@"nickname"]];
    }];
    return arr;
}

/// 安全 swizzle：方法存在才替换，替换后登记用户
+ (void)hf_swizzleSetter:(SEL)sel ofClass:(Class)cls withBlock:(void (^)(id))block {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    // 用 SEL 本身作为关联 key 保存原实现（不同 SEL 互不覆盖）
    IMP origImp = method_getImplementation(m);
    objc_setAssociatedObject(cls, sel, [NSValue valueWithPointer:origImp],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    IMP newImp = imp_implementationWithBlock(^(id selfV) {
        IMP imp = origImp;
        ((void (*)(id, SEL))imp)(selfV, sel);
        if (block) block(selfV);
    });
    method_setImplementation(m, newImp);
}

/// v1.3.4 KVC 全局登记：hook NSObject setValue:forKey:（KVC 赋值入口），
/// 凡 key 是用户标识字段（uid/uniqueID/shortID/nickname…）即登记 self 进注册表。
/// 抖音 39.9.0 用户模型赋值不走 ObjC setter 时，KVC 路径是唯一可靠入口。
/// v1.3.16 补漏：① 追加 hook setValue:forKeyPath:（keyPath 赋值入口）；
///   ② 值为 NSDictionary（用户数据常见载体）时按字典字段直接登记。
/// 只安装一次；key 快速过滤，非候选 key 零开销；全程 @try 防崩。
static void hf_installKVCRegister(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    void (^handleKV)(id, id, NSString *) = ^(id selfV, id value, NSString *key) {
        // v1.3.40：移除 hf_isProxy(selfV)——setValue:forKey: 只挂在 NSObject 上，
        // selfV 一定是 NSObject 实例，走类层级遍历判断纯属浪费（每次 KVC 都白跑一遍）。
        if (!key || value == nil) return;
        if (key.length > 12) return;   // 快速过滤：候选 key 都很短
        // v1.3.56：互关列表用户模型（AWEAdaptorUserModel）赋值时直接标记互关好友。
        // 不再依赖 cell 路径——直接 hook 模型赋值，只要模型被填充就能可靠捕获。
        NSString *clsName = NSStringFromClass(object_getClass(selfV));
        if ([clsName hasPrefix:@"AWEAdaptorUserModel"]) {
            [HFBlacklist markMutualFollowModel:selfV];
        }
        // v1.3.60：关注列表 sectionViewModel（AWEFollowListUserListViewModel）赋值时
        // 一次性遍历其数据源数组拿全量好友，不用滚动到每个 cell。
        if ([clsName hasPrefix:@"AWEFollowListUserListViewModel"]) {
            [HFBlacklist markMutualFollowFromListViewModel:selfV];
        }
        if ([key isEqualToString:@"uid"] || [key isEqualToString:@"userId"] ||
            [key isEqualToString:@"userID"] || [key isEqualToString:@"uniqueID"] ||
            [key isEqualToString:@"shortID"] || [key isEqualToString:@"nickname"] ||
            [key isEqualToString:@"secUid"] || [key isEqualToString:@"douyinId"]) {
            @try {
                [HFBlacklist registerUserObject:selfV];
                // v1.3.16：值若是字典，按字典字段登记（字典对 KVC 读取原生支持）
                if ([value isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *d = (NSDictionary *)value;
                    id dUid = d[@"uid"] ?: d[@"userId"] ?: d[@"userID"];
                    if (dUid) [HFBlacklist registerUserObject:d];
                }
            } @catch (NSException *e) {}
        }
    };
    // 1) setValue:forKey:
    Method m = class_getInstanceMethod([NSObject class], @selector(setValue:forKey:));
    if (m) {
        IMP origImp = method_getImplementation(m);
        IMP newImp = imp_implementationWithBlock(^(id selfV, id value, NSString *key) {
            ((void (*)(id, SEL, id, id))origImp)(selfV, @selector(setValue:forKey:), value, key);
            handleKV(selfV, value, key);
        });
        method_setImplementation(m, newImp);
    }
    // 2) setValue:forKeyPath:（v1.3.16 补漏：keyPath 形式如 user.uniqueID）
    Method m2 = class_getInstanceMethod([NSObject class], @selector(setValue:forKeyPath:));
    if (m2) {
        IMP origImp2 = method_getImplementation(m2);
        IMP newImp2 = imp_implementationWithBlock(^(id selfV, id value, NSString *keyPath) {
            ((void (*)(id, SEL, id, id))origImp2)(selfV, @selector(setValue:forKeyPath:), value, keyPath);
            // v1.3.47 性能：setValue:forKeyPath: 是全 App 最高频 KVC 路径之一，
            // 原 componentsSeparatedByString 对不含"."的 keyPath 也会分配数组。
            // 改为仅在有"."时截取，绝大多数调用零分配。
            NSString *lastComp = keyPath;
            NSRange dot = [keyPath rangeOfString:@"."];
            if (dot.location != NSNotFound) {
                lastComp = [keyPath substringFromIndex:dot.location + dot.length];
            }
            handleKV(selfV, value, lastComp ?: keyPath);
        });
        method_setImplementation(m2, newImp2);
    }
    NSLog(@"[HideFriends] KVC register installed (forKey + forKeyPath)");
}

/// 初始化注册表：安全 hook 用户模型类的 setter（类/方法不存在则跳过，绝不崩）
/// v1.3.0：hook AWEUserModel 建立 UID↔抖音号注册表
/// v1.3.3：多类 hook（固定候选类 + 自适应发现的用户类），幂等 + 可反复调用
///         （心跳每 30s 调用，类晚加载也能补上；已 hook 的类不再重复）
+ (void)setupUserRegistry {
    if (!gRegistryHookedClasses) gRegistryHookedClasses = [NSMutableSet set];
    // v1.3.34：恢复持久化的注册表（关注/粉丝/互关列表 UID 反查依赖）
    // v1.3.52：loadRegistry 只加载一次——每次心跳都 JSON 反序列化整个注册表是
    // 后台重活，会抢占 CPU 导致刷视频卡顿；注册表加载后由内存维护 + 节流写回。
    static BOOL registryLoaded = NO;
    if (!registryLoaded) {
        [self loadRegistry];
        registryLoaded = YES;
    }
    // v1.3.59：恢复互关好友集合（重启不丢，不用每次重新滚动）
    static BOOL mutualFollowLoaded = NO;
    if (!mutualFollowLoaded) {
        [self loadMutualFollow];
        mutualFollowLoaded = YES;
    }
    // v1.3.19：安装消息会话列表 cell 的持久隐藏钩子（类晚加载，心跳反复触发）
    hf_installCellPersistenceHooks();
    // v1.3.28：hook UIView 基类 systemLayoutSize（行高归零——cell/contentView 全覆盖）
    hf_installSystemLayoutHooks();
    // v1.3.29：hook proxy 转发入口（动态 hook 真实行高 target）
    hf_installProxyForwardHook();
    // v1.3.74 修复崩溃：不再调用 hf_installCollectionProxyForwardHook——它 hook
    // BSTCollectionViewDelegateProxy 的 forwardInvocation/forwardingTargetForSelector，
    // 破坏 ListKit 转发链导致启动崩溃。尺寸归零由 layout attributes 层负责。
    // v1.3.67：hook UICollectionViewLayout 尺寸（关注/粉丝列表行归零——sizeForItem 钩子走不通）
    hf_installCollectionLayoutHook();
    // v1.3.20/21：通用 cell 布局钩子（覆盖全部 cell 类）+ 行高钩子安装器（动态发现 delegate）
    hf_installGenericCellLayoutHook();
    hf_installRowHeightHookInstaller();
    // v1.3.4 KVC 全局登记（不猜类名——所有走 KVC 赋值的用户字段都会入表）
    hf_installKVCRegister();
    void (^registerBlock)(id) = ^(id selfV) {
        [HFBlacklist registerUserObject:selfV];
    };
    // 1) 固定候选类（各版本抖音常见用户模型类名）
    NSArray *candidateNames = @[ @"AWEUserModel", @"AWEUser", @"AWEUserProfile",
                                 @"BDFlowUserInfoModel", @"FlowUserInfo", @"FlowSDK.BDFlowUserInfoModel",
                                 @"AWERelationListCellBaseViewModel" ];
    for (NSString *name in candidateNames) {
        Class cls = NSClassFromString(name);
        if (!cls) continue;
        if ([gRegistryHookedClasses containsObject:cls]) continue;
        [self hf_swizzleSetter:@selector(setUid:) ofClass:cls withBlock:registerBlock];
        [self hf_swizzleSetter:@selector(setUniqueID:) ofClass:cls withBlock:registerBlock];
        [self hf_swizzleSetter:@selector(setShortID:) ofClass:cls withBlock:registerBlock];
        [self hf_swizzleSetter:@selector(setNickname:) ofClass:cls withBlock:registerBlock];
        [self hf_swizzleSetter:@selector(setSecUid:) ofClass:cls withBlock:registerBlock];
        [gRegistryHookedClasses addObject:cls];
        NSLog(@"[HideFriends] registry hooked: %@", name);
    }
    // v1.3.56：互关列表用户模型 AWEAdaptorUserModel 的 setter hook——赋值时即时标记互关好友。
    // 不再依赖 willDisplayCell（delegate 方法，hook UITableView 类拦不到）或 60s 扫描的延迟。
    {
        Class adaptorCls = NSClassFromString(@"AWEAdaptorUserModel");
        if (adaptorCls) {
            [self hf_swizzleSetter:@selector(setNickname:) ofClass:adaptorCls withBlock:^(id selfV) {
                [HFBlacklist markMutualFollowModel:selfV];
            }];
            [self hf_swizzleSetter:@selector(setUserID:) ofClass:adaptorCls withBlock:^(id selfV) {
                [HFBlacklist markMutualFollowModel:selfV];
            }];
            [self hf_swizzleSetter:@selector(setUid:) ofClass:adaptorCls withBlock:^(id selfV) {
                [HFBlacklist markMutualFollowModel:selfV];
            }];
            NSLog(@"[HideFriends] mutual-follow hook installed on AWEAdaptorUserModel");
        }
    }
    // 2) 自适应发现的用户类（HFDiscovery 扫描结果，覆盖未列出的新类）
    NSArray *userClassNames = [HFDiscovery detectedUserClassNames];
    for (NSString *name in userClassNames) {
        if (name.length == 0 || name.length > 100) continue;
        Class cls = NSClassFromString(name);
        if (!cls) continue;
        if ([gRegistryHookedClasses containsObject:cls]) continue;
        // 只 hook 非 UIView 类（cell 等视图类跳过）
        Class uiv = [UIView class];
        Class c = cls;
        BOOL isView = NO;
        while (c && c != [NSObject class]) {
            if (c == uiv) { isView = YES; break; }
            c = class_getSuperclass(c);
        }
        if (isView) continue;
        [self hf_swizzleSetter:@selector(setUid:) ofClass:cls withBlock:registerBlock];
        [self hf_swizzleSetter:@selector(setUniqueID:) ofClass:cls withBlock:registerBlock];
        [self hf_swizzleSetter:@selector(setShortID:) ofClass:cls withBlock:registerBlock];
        [self hf_swizzleSetter:@selector(setNickname:) ofClass:cls withBlock:registerBlock];
        [self hf_swizzleSetter:@selector(setSecUid:) ofClass:cls withBlock:registerBlock];
        [gRegistryHookedClasses addObject:cls];
        NSLog(@"[HideFriends] registry hooked(auto): %@", name);
    }
    if (gRegistryHookedClasses.count > 0) {
        NSLog(@"[HideFriends] user registry total hooked classes: %lu", (unsigned long)gRegistryHookedClasses.count);
    }
}

@end
