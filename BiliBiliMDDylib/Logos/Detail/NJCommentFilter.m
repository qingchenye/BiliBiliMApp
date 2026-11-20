//
//  NJCommentFilter.m
//  BiliBiliTweak
//
//  按等级屏蔽视频评论（含楼中楼）
//
//  一、为什么不用 Logos 的 %hook 直接写具体的评论 model 类？
//  B站评论数据走 Protobuf，模型类是 GPBMessage 的子类，不同 App 版本、不同接口
//  （主评论列表 / 楼中楼详情 / 置顶评论）的类名都不一样，直接写死类名很容易在
//  某个版本上失效。因此这里只 hook Protobuf 的解析入口（GPBMessage 的 init 系列），
//  解析完成后由 NJCommentFilterTool 按“字段名”通用识别评论数组：
//      repliesArray / topRepliesArray / subRepliesArray / replyListArray
//  再从 member / memberV2 的 level（或 levelInfo.currentLevel）取用户等级做过滤。
//
//  二、为什么用运行时替换 IMP，而不是写 @implementation GPBMessage (Category)？
//  GPBMessage 是宿主 App（哔哩哔哩）里的类，本 dylib 链接时并没有它的符号，
//  而本工程没有 -undefined dynamic_lookup，所以静态引用 _OBJC_CLASS_$_GPBMessage
//  会直接链接失败。用 NSClassFromString + method_setImplementation 只在运行时按
//  类名查找，编译期不产生任何对宿主类的符号依赖（和 Logos %hook 的做法一致）。
//
//  三、楼中楼（子评论）怎么处理？
//  - 每条保留下来的评论都会递归过滤它自己的子评论数组（子评论按自己的等级判断）；
//  - 父评论被屏蔽时，它的子评论随之一起不再展示（不会出现“只有子评论没有父评论”）；
//  - 展开楼中楼时 App 会重新请求子评论列表，该列表同样会走 Protobuf 解析入口，
//    因此展开后的子评论同样被过滤，不会出现“展开后又看到低等级评论”的问题。
//
//  四、如果某个版本评论区没生效怎么办？
//  1. 把 NJCommentFilterTool.m 顶部的 NJCF_DEBUG_LOG 改成 1，重启 App 进评论区，
//     控制台会打印被识别到的评论数组和等级；
//  2. 如果完全没有日志，说明该版本的评论数据不是走 GPBMessage 的 init 解析
//     （可能是 JSON 接口），需要在 NJApiDataManger 里加一个 NJApiDataItem；
//  3. 如果识别到了评论但没有屏蔽，说明字段名不同，在
//     +[NJCommentFilterTool replyArrayKeys] / -levelOfUser: 里补上字段名即可。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "NJCommentFilterTool.h"
#import "NJCommonDefine.h"
#import "NJSettingCache.h"

#pragma mark - 解析入口的替换实现

/// -initWithData:error:
typedef id (*NJCFInitDataErrorIMP)(id, SEL, NSData *, NSError **);
static NJCFInitDataErrorIMP NJCFOriginalInitWithDataError = NULL;

static id NJCFInitWithDataError(id self, SEL _cmd, NSData *data, NSError **error) {
    id message = NJCFOriginalInitWithDataError(self, _cmd, data, error);
    [[NJCommentFilterTool sharedInstance] filterMessageIfNeeded:message];
    return message;
}

/// -initWithData:extensionRegistry:error:
typedef id (*NJCFInitDataRegistryErrorIMP)(id, SEL, NSData *, id, NSError **);
static NJCFInitDataRegistryErrorIMP NJCFOriginalInitWithDataRegistryError = NULL;

static id NJCFInitWithDataRegistryError(id self, SEL _cmd, NSData *data, id extensionRegistry, NSError **error) {
    id message = NJCFOriginalInitWithDataRegistryError(self, _cmd, data, extensionRegistry, error);
    [[NJCommentFilterTool sharedInstance] filterMessageIfNeeded:message];
    return message;
}

/// -initWithCodedInputStream:extensionRegistry:error:
typedef id (*NJCFInitStreamRegistryErrorIMP)(id, SEL, id, id, NSError **);
static NJCFInitStreamRegistryErrorIMP NJCFOriginalInitStreamRegistryError = NULL;

static id NJCFInitStreamRegistryError(id self, SEL _cmd, id input, id extensionRegistry, NSError **error) {
    id message = NJCFOriginalInitStreamRegistryError(self, _cmd, input, extensionRegistry, error);
    [[NJCommentFilterTool sharedInstance] filterMessageIfNeeded:message];
    return message;
}

/// -mergeFromData:extensionRegistry:error:
typedef BOOL (*NJCFMergeDataRegistryErrorIMP)(id, SEL, NSData *, id, NSError **);
static NJCFMergeDataRegistryErrorIMP NJCFOriginalMergeDataRegistryError = NULL;

static BOOL NJCFMergeDataRegistryError(id self, SEL _cmd, NSData *data, id extensionRegistry, NSError **error) {
    BOOL result = NJCFOriginalMergeDataRegistryError(self, _cmd, data, extensionRegistry, error);
    if (result) {
        [[NJCommentFilterTool sharedInstance] filterMessageIfNeeded:self];
    }
    return result;
}

#pragma mark - 安装

/// 替换实例方法的实现（类和方法都按运行时查找，不产生编译期符号依赖）
static BOOL NJCFReplaceInstanceMethod(Class cls, SEL selector, IMP newIMP, IMP *outOriginal) {
    if (!cls || !selector || !newIMP) {
        return NO;
    }
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return NO;
    }
    IMP currentIMP = method_getImplementation(method);
    if (currentIMP == newIMP) {
        // 已经替换过，避免重复安装
        return YES;
    }
    if (outOriginal) {
        *outOriginal = currentIMP;
    }
    method_setImplementation(method, newIMP);
    return YES;
}

/// 安装评论等级过滤
/// @return YES 表示已成功安装（或之前已安装过）
static BOOL NJCFInstall(void) {
    Class gpbMessageClass = NSClassFromString(@"GPBMessage");
    if (!gpbMessageClass) {
        return NO;
    }

    // Protobuf 解析入口（不同版本可能只走其中一两个）
    NJCFReplaceInstanceMethod(gpbMessageClass,
                              @selector(initWithData:error:),
                              (IMP)NJCFInitWithDataError,
                              (IMP *)&NJCFOriginalInitWithDataError);
    NJCFReplaceInstanceMethod(gpbMessageClass,
                              @selector(initWithData:extensionRegistry:error:),
                              (IMP)NJCFInitWithDataRegistryError,
                              (IMP *)&NJCFOriginalInitWithDataRegistryError);
    NJCFReplaceInstanceMethod(gpbMessageClass,
                              @selector(initWithCodedInputStream:extensionRegistry:error:),
                              (IMP)NJCFInitStreamRegistryError,
                              (IMP *)&NJCFOriginalInitStreamRegistryError);
    NJCFReplaceInstanceMethod(gpbMessageClass,
                              @selector(mergeFromData:extensionRegistry:error:),
                              (IMP)NJCFMergeDataRegistryError,
                              (IMP *)&NJCFOriginalMergeDataRegistryError);

    // 配置每次过滤时从设置缓存中读取，修改设置后无需改代码
    [NJCommentFilterTool sharedInstance].configProvider = ^NJCommentFilterConfig{
        NJCommentFilterConfig config;
        config.enabled = NJ_COMMENT_FILTER_VALUE;
        config.threshold = [[[NJSettingCache sharedInstance] commentFilterLevel] integerValue];
        return config;
    };
    return YES;
}

/// 安装，失败时在主线程稍后重试（dylib 初始化时宿主 App 的类可能还没注册完）
static void NJCFInstallWithRetry(NSInteger remainingAttempts) {
    if (NJCFInstall()) {
        return;
    }
    if (remainingAttempts <= 0) {
        NSLog(@"[NJCommentFilter] 未找到 GPBMessage，按等级屏蔽评论不生效");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NJCFInstallWithRetry(remainingAttempts - 1);
    });
}

__attribute__((constructor)) static void NJCommentFilterInit(void) {
    // 跟随总开关，总开关关闭时不做任何处理
    if (!NJ_MASTER_SWITCH_VALUE) {
        return;
    }
    NJCFInstallWithRetry(3);
}
