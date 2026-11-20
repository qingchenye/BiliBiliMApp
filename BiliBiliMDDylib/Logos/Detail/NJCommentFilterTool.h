//
//  NJCommentFilterTool.h
//  BiliBiliTweak
//
//  按等级屏蔽评论：过滤视频评论区的评论，楼中楼（子评论）同样按等级过滤。
//
//  设计说明：
//  1. B站评论数据是 Protobuf 模型（GPBMessage 子类），不同版本/不同接口的
//     model 类名并不稳定，因此这里不依赖具体类名，而是按“字段名”做通用过滤：
//      - 评论数组字段：repliesArray / topRepliesArray / subRepliesArray / replyListArray
//      - 评论用户字段：member / memberV2，用户等级字段：level 或 levelInfo.currentLevel
//  2. 楼中楼处理：
//      - 每条被保留的评论都会递归过滤它自己的子评论数组；
//      - 父评论被屏蔽时，其子评论随父评论一起不再展示（不单独保留孤儿评论）。
//  3. 取不到用户等级时一律保留（宁可不屏蔽，也不能误伤）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 过滤配置
typedef struct {
    /// 是否开启
    BOOL enabled;
    /// 屏蔽等级阈值：用户等级 <= threshold 时屏蔽
    NSInteger threshold;
} NJCommentFilterConfig;

/// 配置提供者（由 Hook 层从设置缓存中读取，避免每条 protobuf 消息都去读缓存）
typedef NJCommentFilterConfig (^NJCommentFilterConfigProvider)(void);

@interface NJCommentFilterTool : NSObject

/// 单例
+ (instancetype)sharedInstance;

/// 是否开启（configProvider 为 nil 时生效，便于单元测试）
@property (nonatomic, assign) BOOL enabled;

/// 屏蔽等级阈值（configProvider 为 nil 时生效，便于单元测试）
@property (nonatomic, assign) NSInteger threshold;

/// 配置提供者，nil 时使用 enabled / threshold
@property (nonatomic, copy, nullable) NJCommentFilterConfigProvider configProvider;

/// 支持的评论数组字段名
+ (NSArray<NSString *> *)replyArrayKeys;

/// 过滤一条 protobuf 消息中所有的评论数组（含楼中楼递归）
/// @param message GPBMessage 实例
- (void)filterMessageIfNeeded:(id)message;

/// 过滤一组评论（含楼中楼递归），返回过滤后的数组
/// @param replies 评论数组
/// @param threshold 屏蔽等级阈值（用户等级 <= threshold 时屏蔽）
- (NSArray *)filterReplies:(NSArray *)replies threshold:(NSInteger)threshold;

/// 获取评论的用户等级，取不到返回 -1
- (NSInteger)userLevelOfReply:(id)reply;

@end

NS_ASSUME_NONNULL_END
