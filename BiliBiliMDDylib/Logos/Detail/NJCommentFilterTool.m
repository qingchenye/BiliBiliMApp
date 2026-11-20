//
//  NJCommentFilterTool.m
//  BiliBiliTweak
//

#import "NJCommentFilterTool.h"
#import <objc/message.h>

/// 调试日志开关：排查“某些版本评论区不生效”时改成 1，可在 Xcode 控制台看到被识别的评论数组与等级
#ifndef NJCF_DEBUG_LOG
#define NJCF_DEBUG_LOG 0
#endif

#if NJCF_DEBUG_LOG
#define NJCFLog(...) NSLog(@"[NJCommentFilter] " __VA_ARGS__)
#else
#define NJCFLog(...) do {} while (0)
#endif

/// 取不到等级
static const NSInteger NJCFUnknownLevel = -1;
/// 数组字段后缀
static NSString * const NJCFArraySuffix = @"Array";

@implementation NJCommentFilterTool

#pragma mark - Life Cycle Methods

+ (instancetype)sharedInstance {
    static NJCommentFilterTool *_sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedInstance = [[NJCommentFilterTool alloc] init];
    });
    return _sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _enabled = NO;
        _threshold = 2;
    }
    return self;
}

#pragma mark - Public Methods

/// 支持的评论数组字段名
+ (NSArray<NSString *> *)replyArrayKeys {
    return @[
        @"repliesArray",      // 评论列表 / 楼中楼子评论
        @"topRepliesArray",   // 置顶评论
        @"subRepliesArray",   // 部分版本的楼中楼子评论
        @"replyListArray",    // 部分版本的评论列表
    ];
}

- (void)filterMessageIfNeeded:(id)message {
    if (!message) {
        return;
    }
    // 先做廉价判断：不是评论类消息直接返回，避免影响其它 protobuf 解析性能
    if (![self hasReplyArray:message]) {
        return;
    }
    NJCommentFilterConfig config = [self currentConfig];
    if (!config.enabled) {
        return;
    }
    [self filterArraysOfMessage:message threshold:config.threshold];
}

- (NSArray *)filterReplies:(NSArray *)replies threshold:(NSInteger)threshold {
    if (![replies isKindOfClass:[NSArray class]] || replies.count == 0) {
        return replies ?: @[];
    }
    NSMutableArray *keptReplies = [NSMutableArray arrayWithCapacity:replies.count];
    for (id reply in replies) {
        NSInteger level = [self userLevelOfReply:reply];
        if (level != NJCFUnknownLevel && level <= threshold) {
            // 屏蔽该评论（其楼中楼子评论一并隐藏）
            NJCFLog(@"屏蔽评论 level=%ld class=%@", (long)level, NSStringFromClass([reply class]));
            continue;
        }
        // 楼中楼：递归过滤子评论
        [self filterArraysOfMessage:reply threshold:threshold];
        [keptReplies addObject:reply];
    }
    if (keptReplies.count == replies.count) {
        // 没有需要屏蔽的评论，返回原数组
        return replies;
    }
    NJCFLog(@"评论过滤：%lu -> %lu", (unsigned long)replies.count, (unsigned long)keptReplies.count);
    return [keptReplies copy];
}

/// 获取评论的用户等级，取不到返回 -1
- (NSInteger)userLevelOfReply:(id)reply {
    if (!reply) {
        return NJCFUnknownLevel;
    }
    // 评论用户：member / memberV2
    id user = [self objectForKey:@"member" ofObject:reply];
    if (!user) {
        user = [self objectForKey:@"memberV2" ofObject:reply];
    }
    if (!user) {
        user = [self objectForKey:@"member_v2" ofObject:reply];
    }
    if (user) {
        NSInteger level = [self levelOfUser:user];
        if (level != NJCFUnknownLevel) {
            return level;
        }
    }
    // 兜底：评论对象自身就带等级字段
    return [self levelOfUser:reply];
}

#pragma mark - Private Methods

/// 过滤一条消息里所有的评论数组，并把过滤结果写回消息
- (void)filterArraysOfMessage:(id)message threshold:(NSInteger)threshold {
    if (!message) {
        return;
    }
    for (NSString *key in [[self class] replyArrayKeys]) {
        NSArray *replies = [self objectForKey:key ofObject:message];
        if (![replies isKindOfClass:[NSArray class]] || replies.count == 0) {
            continue;
        }
        NSArray *filteredReplies = [self filterReplies:replies threshold:threshold];
        if (filteredReplies.count == replies.count) {
            continue;
        }
        [self writeBackReplies:filteredReplies forMessage:message key:key];
    }
}

/// 把过滤后的数组写回 protobuf 消息
/// 依次尝试：setXxxArray: -> clearXxx + addXxx: -> 直接改可变数组
- (BOOL)writeBackReplies:(NSArray *)replies forMessage:(id)message key:(NSString *)key {
    if (!message || key.length == 0) {
        return NO;
    }
    // 1、setXxxArray:（GPBMessage 会为 repeated 字段生成该 setter）
    NSString *setterName = [NSString stringWithFormat:@"set%@%@:",
                            [[key substringToIndex:1] uppercaseString],
                            [key substringFromIndex:1]];
    SEL setter = NSSelectorFromString(setterName);
    if ([message respondsToSelector:setter]) {
        ((void (*)(id, SEL, NSArray *))objc_msgSend)(message, setter, replies);
        return YES;
    }
    // 2、clearXxx + addXxx:（repeated 字段的增删接口）
    if ([key hasSuffix:NJCFArraySuffix]) {
        NSString *baseName = [key substringToIndex:key.length - NJCFArraySuffix.length];
        NSString *capitalizedBaseName = [NSString stringWithFormat:@"%@%@",
                                         [[baseName substringToIndex:1] uppercaseString],
                                         [baseName substringFromIndex:1]];
        SEL clearSelector = NSSelectorFromString([@"clear" stringByAppendingString:capitalizedBaseName]);
        SEL addSelector = NSSelectorFromString([NSString stringWithFormat:@"add%@:", capitalizedBaseName]);
        if ([message respondsToSelector:clearSelector] && [message respondsToSelector:addSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(message, clearSelector);
            for (id reply in replies) {
                ((void (*)(id, SEL, id))objc_msgSend)(message, addSelector, reply);
            }
            return YES;
        }
    }
    // 3、直接修改可变数组（部分版本返回的是内部 NSMutableArray）
    id currentReplies = [self objectForKey:key ofObject:message];
    if ([currentReplies isKindOfClass:[NSMutableArray class]]) {
        [(NSMutableArray *)currentReplies setArray:replies];
        return YES;
    }
    NJCFLog(@"写回过滤结果失败 class=%@ key=%@", NSStringFromClass([message class]), key);
    return NO;
}

/// 消息里是否有评论数组字段
- (BOOL)hasReplyArray:(id)message {
    for (NSString *key in [[self class] replyArrayKeys]) {
        if ([message respondsToSelector:NSSelectorFromString(key)]) {
            return YES;
        }
    }
    return NO;
}

/// 取用户等级：level 或 levelInfo.currentLevel
- (NSInteger)levelOfUser:(id)user {
    if (!user) {
        return NJCFUnknownLevel;
    }
    NSInteger level = [self intValueForKey:@"level" ofObject:user];
    if (level != NJCFUnknownLevel) {
        return level;
    }
    id levelInfo = [self objectForKey:@"levelInfo" ofObject:user];
    if (!levelInfo) {
        levelInfo = [self objectForKey:@"level_info" ofObject:user];
    }
    if (!levelInfo) {
        return NJCFUnknownLevel;
    }
    for (NSString *key in @[@"currentLevel", @"current_level", @"cur", @"level"]) {
        level = [self intValueForKey:key ofObject:levelInfo];
        if (level != NJCFUnknownLevel) {
            return level;
        }
    }
    return NJCFUnknownLevel;
}

/// 安全地取对象类型的字段值
- (id)objectForKey:(NSString *)key ofObject:(id)obj {
    if (!obj || key.length == 0) {
        return nil;
    }
    SEL selector = NSSelectorFromString(key);
    if (![obj respondsToSelector:selector]) {
        return nil;
    }
    // 只处理返回对象的 getter，避免标量返回值被当成指针
    NSMethodSignature *signature = [obj methodSignatureForSelector:selector];
    if (!signature || strcmp(signature.methodReturnType, @encode(id)) != 0) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(obj, selector);
}

/// 安全地取标量类型的字段值（level 可能是 int32/int64 等标量，不能用对象指针接收）
- (NSInteger)intValueForKey:(NSString *)key ofObject:(id)obj {
    if (!obj || key.length == 0) {
        return NJCFUnknownLevel;
    }
    SEL selector = NSSelectorFromString(key);
    if (![obj respondsToSelector:selector]) {
        return NJCFUnknownLevel;
    }
    NSMethodSignature *signature = [obj methodSignatureForSelector:selector];
    if (!signature) {
        return NJCFUnknownLevel;
    }
    const char *returnType = signature.methodReturnType;
    // 对象返回值：NSNumber / NSString
    if (strcmp(returnType, @encode(id)) == 0) {
        id value = ((id (*)(id, SEL))objc_msgSend)(obj, selector);
        if ([value isKindOfClass:[NSNumber class]]) {
            return [(NSNumber *)value integerValue];
        }
        if ([value isKindOfClass:[NSString class]]) {
            return [(NSString *)value integerValue];
        }
        return NJCFUnknownLevel;
    }
    // 结构体等复杂返回值不支持
    if (signature.methodReturnLength > 8 || returnType[0] == '{') {
        return NJCFUnknownLevel;
    }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = obj;
    invocation.selector = selector;
    [invocation invoke];
    uint8_t buffer[8] = {0};
    [invocation getReturnValue:buffer];
    switch (returnType[0]) {
        case 'c':
            return (NSInteger)*(int8_t *)buffer;
        case 'C':
            return (NSInteger)*(uint8_t *)buffer;
        case 's':
            return (NSInteger)*(int16_t *)buffer;
        case 'S':
            return (NSInteger)*(uint16_t *)buffer;
        case 'i':
            return (NSInteger)*(int32_t *)buffer;
        case 'I':
            return (NSInteger)*(uint32_t *)buffer;
        case 'l':
            return (NSInteger)*(long *)buffer;
        case 'L':
            return (NSInteger)*(unsigned long *)buffer;
        case 'q':
            return (NSInteger)*(long long *)buffer;
        case 'Q':
            return (NSInteger)*(unsigned long long *)buffer;
        case 'B':
            return (NSInteger)*(bool *)buffer;
        case 'f':
            return (NSInteger)*(float *)buffer;
        case 'd':
            return (NSInteger)*(double *)buffer;
        default:
            return NJCFUnknownLevel;
    }
}

/// 当前配置
- (NJCommentFilterConfig)currentConfig {
    NJCommentFilterConfig config;
    config.enabled = self.enabled;
    config.threshold = self.threshold;
    if (self.configProvider) {
        config = self.configProvider();
    }
    return config;
}

@end
