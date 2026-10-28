#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>
#pragma mark - 0. 防闪退安全转换工具函数（彻底杜绝 NSNull 崩溃）
static inline NSDictionary *ACSafeDict(id obj) {
if (obj && [obj isKindOfClass:[NSDictionary class]]) {
return (NSDictionary *)obj;
}
return nil;
}
static inline NSArray *ACSafeArray(id obj) {
if (obj && [obj isKindOfClass:[NSArray class]]) {
return (NSArray *)obj;
}
return nil;
}
static inline NSString *ACSafeStr(id obj) {
if (!obj || [obj isKindOfClass:[NSNull class]]) return @"";
if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
if ([obj isKindOfClass:[NSNumber class]]) return [(NSNumber *)obj stringValue];
return [NSString stringWithFormat:@"%@", obj];
}
// 媒体独立槽位枚举（彻底隔离 4 个功能的图片/视频，绝不互通串用）
// 安全 KVC：任何字段名不存在时返回 nil，绝不让 NSUnknownKeyException 中断整条消息处理链
static inline id ACSafeValue(id obj, NSString *key) {
if (!obj || !key) return nil;
@try { return [obj valueForKey:key]; } @catch (NSException *e) { return nil; }
}
// Header 大小写无关读取（抓包里 token / Token / X-Lts-Id 大小写并不统一）
static inline NSString *ACHeaderValue(NSDictionary *headers, NSString *key) {
if (!headers || key.length == 0) return nil;
id v = headers[key];
if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return (NSString *)v;
for (NSString *k in headers) {
if ([k isKindOfClass:[NSString class]] && [k caseInsensitiveCompare:key] == NSOrderedSame) {
id hv = headers[k];
if ([hv isKindOfClass:[NSString class]] && [(NSString *)hv length] > 0) return (NSString *)hv;
}
}
return nil;
}
// 触发词归一化：空串 / 全部 / 任意 / 所有 / * 都视为“匹配任意消息”
static inline BOOL ACIsCatchAllKeyword(NSString *kw) {
NSString *k = ACSafeStr(kw);
k = [k stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
if (k.length == 0) return YES;
NSString *lower = k.lowercaseString;
return ([k isEqualToString:@"全部"] || [k isEqualToString:@"任意"] || [k isEqualToString:@"所有"] ||
[k isEqualToString:@"*"] || [k isEqualToString:@"＊"] ||
[lower isEqualToString:@"any"] || [lower isEqualToString:@"all"]);
}
// 递归清洗：去掉 NSNull 等不可 plist/JSON 序列化对象，避免 writeToFile / dataWithJSONObject 静默失败
static inline id ACJSONSafeObject(id obj, NSInteger depth) {
if (depth > 8 || !obj) return nil;
if ([obj isKindOfClass:[NSNull class]]) return nil;
if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]]) return obj;
if ([obj isKindOfClass:[NSArray class]]) {
NSMutableArray *arr = [NSMutableArray array];
for (id v in (NSArray *)obj) {
id sv = ACJSONSafeObject(v, depth + 1);
if (sv) [arr addObject:sv];
}
return arr;
}
if ([obj isKindOfClass:[NSDictionary class]]) {
NSMutableDictionary *dic = [NSMutableDictionary dictionary];
[(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
if (![k isKindOfClass:[NSString class]]) return;
id sv = ACJSONSafeObject(v, depth + 1);
if (sv) dic[k] = sv;
}];
return dic;
}
return nil;
}
// 插件自身发出的请求（发布动态）不参与 Header 嗅探，避免自我污染
static BOOL acInternalRequest = NO;
static NSString * const kACNativeUserAgent = @"airchat/1017 CFNetwork/1490.0.4 Darwin/23.2.0";

// 持久化诊断日志：沙盒 Documents/AirChatTweak.log，可直接用 Filza 打开
static void ACLog(NSString *fmt, ...) {
@autoreleasepool {
va_list ap; va_start(ap, fmt);
NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
va_end(ap);
NSDateFormatter *df = [[NSDateFormatter alloc] init];
df.dateFormat = @"MM-dd HH:mm:ss.SSS";
NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
NSString *path = [dir stringByAppendingPathComponent:@"AirChatTweak.log"];
NSFileManager *fm = [NSFileManager defaultManager];
if (![fm fileExistsAtPath:path]) { [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
else {
NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}
NSLog(@"[AirChatTweak] %@", msg);
}
}
typedef NS_ENUM(NSInteger, ACMediaSlot) {
ACMediaSlotBatchSend = 0, // 槽位0：群发专属媒体（好友/群员/群聊）
ACMediaSlotWelcome   = 1, // 槽位1：🤖迎新专属媒体
ACMediaSlotAutoReply = 2, // 槽位2：💬自动回复专属媒体
ACMediaSlotMoment    = 3  // 槽位3：📝发动态专属媒体
};
#pragma mark - 1. 数据模型（采用纯 NSDictionary 转换，支持每条规则/任务独立媒体）
@interface ACContactItem : NSObject
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *fromGroupId;
@property (nonatomic, copy) NSString *roleDesc;
@property (nonatomic, assign) NSInteger sourceType; // 0: 好友, 1: 群成员, 2: 群聊
@property (nonatomic, assign) NSInteger chatMeType; // 0: 开放私聊, 1: 仅双向好友
@property (nonatomic, assign) BOOL isGroupBanned;
@property (nonatomic, assign) BOOL isSelected;
- (NSDictionary *)toDict;
+ (instancetype)fromDict:(NSDictionary *)dict;
@end
@implementation ACContactItem
- (NSDictionary *)toDict {
return @{
@"targetId": self.targetId ?: @"",
@"name": self.name ?: @"",
@"fromGroupId": self.fromGroupId ?: @"",
@"roleDesc": self.roleDesc ?: @"",
@"sourceType": @(self.sourceType),
@"chatMeType": @(self.chatMeType),
@"isGroupBanned": @(self.isGroupBanned)
};
}
+ (instancetype)fromDict:(NSDictionary *)d {
NSDictionary *dict = ACSafeDict(d);
if (!dict) return nil;
ACContactItem *item = [[ACContactItem alloc] init];
item.targetId = ACSafeStr(dict[@"targetId"]);
item.name = ACSafeStr(dict[@"name"]);
item.fromGroupId = ACSafeStr(dict[@"fromGroupId"]);
item.roleDesc = ACSafeStr(dict[@"roleDesc"]);
item.sourceType = [ACSafeStr(dict[@"sourceType"]) integerValue];
item.chatMeType = [ACSafeStr(dict[@"chatMeType"]) integerValue];
item.isGroupBanned = [ACSafeStr(dict[@"isGroupBanned"]) boolValue];
item.isSelected = NO;
return item;
}
@end
// 自动回复规则模型（每条规则可拥有自己独立的专属图片/视频文件）
@interface ACAutoReplyRule : NSObject
@property (nonatomic, copy) NSString *ruleId;
@property (nonatomic, copy) NSString *keyword;
@property (nonatomic, copy) NSString *replyText;
@property (nonatomic, assign) BOOL attachMedia;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) NSInteger customMediaType; // 0: 使用槽位2默认媒体, 1: 规则专属图片, 2: 规则专属视频
@property (nonatomic, copy) NSString *customMediaPath;
@property (nonatomic, copy) NSString *customThumbPath;
@property (nonatomic, assign) int customVideoDuration;
- (NSDictionary *)toDict;
+ (instancetype)fromDict:(NSDictionary *)dict;
@end
@implementation ACAutoReplyRule
- (NSDictionary *)toDict {
return @{
@"ruleId": self.ruleId ?: @"",
@"keyword": self.keyword ?: @"",
@"replyText": self.replyText ?: @"",
@"attachMedia": @(self.attachMedia),
@"enabled": @(self.enabled),
@"customMediaType": @(self.customMediaType),
@"customMediaPath": self.customMediaPath ?: @"",
@"customThumbPath": self.customThumbPath ?: @"",
@"customVideoDuration": @(self.customVideoDuration)
};
}
+ (instancetype)fromDict:(NSDictionary *)d {
NSDictionary *dict = ACSafeDict(d);
if (!dict) return nil;
ACAutoReplyRule *r = [[ACAutoReplyRule alloc] init];
r.ruleId = ACSafeStr(dict[@"ruleId"]);
r.keyword = ACSafeStr(dict[@"keyword"]);
r.replyText = ACSafeStr(dict[@"replyText"]);
r.attachMedia = dict[@"attachMedia"] ? [ACSafeStr(dict[@"attachMedia"]) boolValue] : YES;
r.enabled = dict[@"enabled"] ? [ACSafeStr(dict[@"enabled"]) boolValue] : YES;
r.customMediaType = [ACSafeStr(dict[@"customMediaType"]) integerValue];
r.customMediaPath = ACSafeStr(dict[@"customMediaPath"]);
r.customThumbPath = ACSafeStr(dict[@"customThumbPath"]);
r.customVideoDuration = [ACSafeStr(dict[@"customVideoDuration"]) intValue];
return r;
}
@end
// 定时发动态任务模型（每条动态任务拥有独立的文案与媒体列表）
@interface ACMomentTaskItem : NSObject
@property (nonatomic, copy) NSString *taskId;
@property (nonatomic, copy) NSString *contentText;
@property (nonatomic, strong) NSArray *capturedMediaList; // 远程 COS 媒体列表
@property (nonatomic, assign) NSInteger localMediaType;   // 0: 无本地图, 1: 本地图, 2: 本地视频
@property (nonatomic, copy) NSString *localMediaPath;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) NSInteger sentCount;
@property (nonatomic, copy) NSString *lastSentTimeStr;
- (NSDictionary *)toDict;
+ (instancetype)fromDict:(NSDictionary *)dict;
@end
@implementation ACMomentTaskItem
- (NSDictionary *)toDict {
NSMutableDictionary *md = [NSMutableDictionary dictionary];
md[@"taskId"] = self.taskId ?: @"";
md[@"contentText"] = self.contentText ?: @"";
md[@"enabled"] = @(self.enabled);
md[@"sentCount"] = @(self.sentCount);
md[@"lastSentTimeStr"] = self.lastSentTimeStr ?: @"待发布";
md[@"localMediaType"] = @(self.localMediaType);
md[@"localMediaPath"] = self.localMediaPath ?: @"",
md[@"capturedMediaList"] = ACSafeArray(self.capturedMediaList) ?: @[];
return md;
}
+ (instancetype)fromDict:(NSDictionary *)d {
NSDictionary *dict = ACSafeDict(d);
if (!dict) return nil;
ACMomentTaskItem *t = [[ACMomentTaskItem alloc] init];
t.taskId = ACSafeStr(dict[@"taskId"]);
t.contentText = ACSafeStr(dict[@"contentText"]);
NSArray *mArr = ACSafeArray(dict[@"capturedMediaList"]);
t.capturedMediaList = (mArr && mArr.count > 0) ? mArr : nil;
t.localMediaType = [ACSafeStr(dict[@"localMediaType"]) integerValue];
t.localMediaPath = ACSafeStr(dict[@"localMediaPath"]);
t.enabled = dict[@"enabled"] ? [ACSafeStr(dict[@"enabled"]) boolValue] : YES;
t.sentCount = [ACSafeStr(dict[@"sentCount"]) integerValue];
t.lastSentTimeStr = ACSafeStr(dict[@"lastSentTimeStr"]);
if (t.lastSentTimeStr.length == 0) t.lastSentTimeStr = @"待发布";
return t;
}
@end
static __weak UIView *__lastLongPressedView = nil;
static NSString *__pendingForwardText = nil;
static NSString *__currentChatPeerId = nil;
#pragma mark - 2. 核心管理器（四槽位媒体完全隔离 + 原生动态发布引擎）
@interface ACForwardHelperManager : NSObject
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *friendList;
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *groupMemberList;
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *groupList;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *friendMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *groupMemberMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *groupMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *groupBanStatusMap;
@property (nonatomic, copy) NSString *selfUserId;
@property (nonatomic, copy) NSString *capturedClientTypeV2;
@property (nonatomic, strong) NSData *capturedCloudCustomData;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *latestHTTPHeaders;
// --- 1. 迎新配置 ---
@property (nonatomic, assign) BOOL autoWelcomeEnabled;
@property (nonatomic, copy) NSString *welcomeMessageText;
@property (nonatomic, strong) NSMutableSet<NSString *> *welcomeGroupIds;
@property (nonatomic, strong) NSMutableSet<NSString *> *greetedUserIds;
@property (nonatomic, assign) NSInteger greetedCount;
@property (nonatomic, copy) NSString *lastGreetLog;
// --- 2. 别人发消息自动回复配置 ---
@property (nonatomic, assign) BOOL autoReplyEnabled;
@property (nonatomic, strong) NSMutableArray<ACAutoReplyRule *> *autoReplyRules;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *autoReplyCooldownMap;
@property (nonatomic, assign) NSInteger autoRepliedCount;
@property (nonatomic, copy) NSString *lastAutoReplyLog;
// --- 3. 多任务定时自动发动态配置 ---
@property (nonatomic, assign) BOOL autoMomentEnabled;
@property (nonatomic, assign) NSInteger momentIntervalMinutes;
@property (nonatomic, strong) NSMutableArray<ACMomentTaskItem *> *momentTasks;
@property (nonatomic, assign) NSInteger currentMomentRotationIdx;
@property (nonatomic, strong) NSTimer *momentTimer;
@property (nonatomic, strong) NSArray *latestCapturedMomentMediaList;
@property (nonatomic, copy) NSString *lastMomentLog;
@property (nonatomic, assign) BOOL listenerRegistered;
@property (nonatomic, assign) BOOL groupListenerRegistered;
@property (nonatomic, assign) BOOL msgListenerRegistered;
@property (nonatomic, assign) BOOL listenerRetryScheduled;
@property (nonatomic, assign) BOOL momentPublishing;
// 仅缓存“原生发布动态”请求的完整 Header 模板（UA / Accept / X-Lts-Id 都以它为准）
@property (nonatomic, strong) NSMutableDictionary *lastPublishHeaders;
// —— 自动评论（别人发动态后自动跟评）——
@property (nonatomic, assign) BOOL autoCommentEnabled;
@property (nonatomic, copy) NSString *autoCommentText;
@property (nonatomic, strong) NSMutableSet *autoCommentSeenIds;
@property (nonatomic, assign) BOOL autoCommentSeeded;
@property (nonatomic, strong) NSMutableArray *autoCommentQueue;
@property (nonatomic, assign) BOOL autoCommentSending;
@property (nonatomic, assign) NSTimeInterval momentPublishingSince;
@property (nonatomic, assign) NSTimeInterval autoCommentEnabledAt;
@property (nonatomic, weak) NSURLSession *latestAppSession;
@property (nonatomic, assign) NSTimeInterval latestLtsAt;
@property (nonatomic, assign) BOOL momentRetryScheduled;
+ (instancetype)shared;
// 四槽位独立媒体管理 API（0:群发, 1:迎新, 2:自动回复, 3:发动态）
- (NSInteger)mediaTypeForSlot:(ACMediaSlot)slot; // 0:无, 1:图片, 2:视频
- (UIImage *)previewImageForSlot:(ACMediaSlot)slot;
- (int)videoDurationForSlot:(ACMediaSlot)slot;
- (NSString *)imagePathForSlot:(ACMediaSlot)slot;
- (NSString *)videoPathForSlot:(ACMediaSlot)slot;
- (NSString *)videoThumbPathForSlot:(ACMediaSlot)slot;
- (void)saveImage:(UIImage *)img forSlot:(ACMediaSlot)slot;
- (void)saveVideoAtURL:(NSURL *)videoURL forSlot:(ACMediaSlot)slot;
- (void)clearMediaForSlot:(ACMediaSlot)slot;
- (void)setupIMGroupWelcomeListener;
- (void)loadLocalPermanentCache;
- (void)saveLocalPermanentCache;
- (void)clearAllGroupMembersCache;
- (void)saveAllCustomSettings;
- (void)parseJSONWithContext:(id)jsonObj;
- (void)reloadSelectedGroupsData:(NSArray<NSString *> *)targetGroupIds
progress:(void(^)(NSString *progressMsg))progressBlock
completion:(void(^)(NSString *finalMsg))completion;
- (void)reloadAllDataWithProgress:(void(^)(NSString *progressMsg))progressBlock
completion:(void(^)(NSString *finalMsg))completion;
// 支持指定独立媒体槽位或独立文件路径的发送引擎
- (void)sendText:(NSString *)text
mediaSlot:(ACMediaSlot)slot
attachMedia:(BOOL)attachMedia
toItem:(ACContactItem *)item
completion:(void(^)(BOOL ok, NSString *detail))completion;
- (void)sendText:(NSString *)text
customMediaType:(NSInteger)mType
customMediaPath:(NSString *)mPath
customThumbPath:(NSString *)tPath
customVideoDuration:(int)vDur
toItem:(ACContactItem *)item
completion:(void(^)(BOOL ok, NSString *detail))completion;
- (void)restartMomentScheduler;
- (void)onMomentTimerTick;
- (void)publishMomentTask:(ACMomentTaskItem *)task completion:(void(^)(BOOL ok, NSString *msg))completion;
// v2.1 新增：统一消息入口（TIM 监听代理与直接监听共用）、发动态节流/重试
- (void)ac_handleIncomingMessage:(id)msg;
- (void)ac_handleMembersJoined:(NSArray *)memberList groupID:(NSString *)groupID;
- (void)ac_applyCapturedHeadersToRequest:(NSMutableURLRequest *)req;
- (void)ac_scheduleMomentRetryAfter:(NSTimeInterval)delay;
- (void)ac_handleFeedResponse:(NSDictionary *)json;
- (void)ac_enqueueAutoCommentForPostId:(NSString *)postId;
- (void)ac_pumpAutoCommentQueue;
- (void)ac_commentPostId:(NSString *)postId text:(NSString *)text;
@end
@implementation ACForwardHelperManager
+ (instancetype)shared {
static ACForwardHelperManager *instance = nil;
static dispatch_once_t onceToken;
dispatch_once(&onceToken, ^{
instance = [[ACForwardHelperManager alloc] init];
instance.friendList = [NSMutableArray array];
instance.groupMemberList = [NSMutableArray array];
instance.groupList = [NSMutableArray array];
instance.friendMap = [NSMutableDictionary dictionary];
instance.groupMemberMap = [NSMutableDictionary dictionary];
instance.groupMap = [NSMutableDictionary dictionary];
instance.groupBanStatusMap = [NSMutableDictionary dictionary];
instance.latestHTTPHeaders = [NSMutableDictionary dictionary];
instance.selfUserId = @"1980559125632786434";
instance.capturedClientTypeV2 = @"79b3h7aOxJurSbzVhPK2Wal1cKQzfppVutid7[d]gEtuxYU87uiCm3l2gMp7d5Eo3KZS3hFxBn8Db[d]yag55Ev1I3W[a]7xF6oF0FSXM[s]";
instance.welcomeGroupIds = [NSMutableSet set];
instance.greetedUserIds = [NSMutableSet set];
instance.lastGreetLog = @"等待新人进群...";
instance.autoReplyRules = [NSMutableArray array];
instance.autoReplyCooldownMap = [NSMutableDictionary dictionary];
instance.lastAutoReplyLog = @"等待别人发来私信...";
instance.momentTasks = [NSMutableArray array];
instance.momentIntervalMinutes = 30;
instance.lastMomentLog = @"等待定时发布动态...";
instance.autoCommentEnabled = NO;
instance.autoCommentText = @"不错";
instance.autoCommentSeenIds = [NSMutableSet set];
instance.autoCommentQueue = [NSMutableArray array];
instance.autoCommentSeeded = NO;
[instance loadLocalPermanentCache];
[instance loadAllCustomSettings];
[instance restartMomentScheduler];
});
return instance;
}
#pragma mark - 2.0 四槽位彻底隔离的永久媒体存储引擎
- (NSString *)imagePathForSlot:(ACMediaSlot)slot {
NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
return [docDir stringByAppendingPathComponent:[NSString stringWithFormat:@"AC_Slot_%ld_Image.jpg", (long)slot]];
}
- (NSString *)videoPathForSlot:(ACMediaSlot)slot {
NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
return [docDir stringByAppendingPathComponent:[NSString stringWithFormat:@"AC_Slot_%ld_Video.mp4", (long)slot]];
}
- (NSString *)videoThumbPathForSlot:(ACMediaSlot)slot {
NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
return [docDir stringByAppendingPathComponent:[NSString stringWithFormat:@"AC_Slot_%ld_Thumb.jpg", (long)slot]];
}
- (NSInteger)mediaTypeForSlot:(ACMediaSlot)slot {
NSString *key = [NSString stringWithFormat:@"AC_Slot_%ld_MediaType", (long)slot];
NSInteger t = [[NSUserDefaults standardUserDefaults] integerForKey:key];
NSFileManager *fm = [NSFileManager defaultManager];
if (t == 1 && [fm fileExistsAtPath:[self imagePathForSlot:slot]]) return 1;
if (t == 2 && [fm fileExistsAtPath:[self videoPathForSlot:slot]]) return 2;
return 0;
}
- (int)videoDurationForSlot:(ACMediaSlot)slot {
NSString *key = [NSString stringWithFormat:@"AC_Slot_%ld_VideoDur", (long)slot];
int d = (int)[[NSUserDefaults standardUserDefaults] integerForKey:key];
return d > 0 ? d : 5;
}
- (UIImage *)previewImageForSlot:(ACMediaSlot)slot {
NSInteger t = [self mediaTypeForSlot:slot];
if (t == 1) {
return [UIImage imageWithContentsOfFile:[self imagePathForSlot:slot]];
} else if (t == 2) {
return [UIImage imageWithContentsOfFile:[self videoThumbPathForSlot:slot]];
}
return nil;
}
- (void)saveImage:(UIImage *)img forSlot:(ACMediaSlot)slot {
if (!img) return;
@try {
NSData *jpgData = UIImageJPEGRepresentation(img, 0.88);
if (jpgData) {
[jpgData writeToFile:[self imagePathForSlot:slot] atomically:YES];
[[NSFileManager defaultManager] removeItemAtPath:[self videoPathForSlot:slot] error:nil];
NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
[ud setInteger:1 forKey:[NSString stringWithFormat:@"AC_Slot_%ld_MediaType", (long)slot]];
[ud setInteger:0 forKey:[NSString stringWithFormat:@"AC_Slot_%ld_VideoDur", (long)slot]];
[ud synchronize];
}
} @catch (NSException *e) {}
}
- (void)saveVideoAtURL:(NSURL *)videoURL forSlot:(ACMediaSlot)slot {
if (!videoURL) return;
@try {
NSFileManager *fm = [NSFileManager defaultManager];
NSString *destVideoPath = [self videoPathForSlot:slot];
[fm removeItemAtPath:destVideoPath error:nil];
[fm removeItemAtPath:[self imagePathForSlot:slot] error:nil];
BOOL copied = [fm copyItemAtURL:videoURL toURL:[NSURL fileURLWithPath:destVideoPath] error:nil];
if (!copied) {
NSData *vData = [NSData dataWithContentsOfURL:videoURL];
if (vData) copied = [vData writeToFile:destVideoPath atomically:YES];
}
if (!copied) return;
int durationSec = 5;
UIImage *thumbImg = nil;
@try {
AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:destVideoPath] options:nil];
CMTime durTime = asset.duration;
if (durTime.timescale > 0) {
durationSec = MAX(1, (int)round((double)durTime.value / (double)durTime.timescale));
}
AVAssetImageGenerator *gen = [[AVAssetImageGenerator alloc] initWithAsset:asset];
gen.appliesPreferredTrackTransform = YES;
CGImageRef cgImg = [gen copyCGImageAtTime:CMTimeMake(0, 1) actualTime:NULL error:NULL];
if (cgImg) {
thumbImg = [UIImage imageWithCGImage:cgImg];
CGImageRelease(cgImg);
}
} @catch (NSException *e) {}
if (!thumbImg) {
UIGraphicsBeginImageContextWithOptions(CGSizeMake(200, 200), YES, 1.0);
[[UIColor darkGrayColor] setFill];
UIRectFill(CGRectMake(0, 0, 200, 200));
thumbImg = UIGraphicsGetImageFromCurrentImageContext();
UIGraphicsEndImageContext();
}
NSData *thumbData = UIImageJPEGRepresentation(thumbImg, 0.85);
if (thumbData) [thumbData writeToFile:[self videoThumbPathForSlot:slot] atomically:YES];
NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
[ud setInteger:2 forKey:[NSString stringWithFormat:@"AC_Slot_%ld_MediaType", (long)slot]];
[ud setInteger:durationSec forKey:[NSString stringWithFormat:@"AC_Slot_%ld_VideoDur", (long)slot]];
[ud synchronize];
} @catch (NSException *e) {}
}
- (void)clearMediaForSlot:(ACMediaSlot)slot {
@try {
NSFileManager *fm = [NSFileManager defaultManager];
[fm removeItemAtPath:[self imagePathForSlot:slot] error:nil];
[fm removeItemAtPath:[self videoPathForSlot:slot] error:nil];
[fm removeItemAtPath:[self videoThumbPathForSlot:slot] error:nil];
NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
[ud setInteger:0 forKey:[NSString stringWithFormat:@"AC_Slot_%ld_MediaType", (long)slot]];
[ud setInteger:0 forKey:[NSString stringWithFormat:@"AC_Slot_%ld_VideoDur", (long)slot]];
[ud synchronize];
} @catch (NSException *e) {}
}
- (NSString *)cacheFilePath:(NSString *)type {
NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
return [docDir stringByAppendingPathComponent:[NSString stringWithFormat:@"AC_SafeCache_%@.plist", type]];
}
- (void)clearAllGroupMembersCache {
@synchronized (self) {
[self.groupMemberList removeAllObjects];
[self.groupMemberMap removeAllObjects];
[[NSFileManager defaultManager] removeItemAtPath:[self cacheFilePath:@"members"] error:nil];
[self saveLocalPermanentCache];
}
}
- (void)saveAllCustomSettings {
@try {
NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
[ud setBool:self.autoWelcomeEnabled forKey:@"AC_AutoWelcome_Enabled"];
[ud setObject:self.welcomeMessageText ?: @"您好 {name}，欢迎进群！认识一下~" forKey:@"AC_AutoWelcome_Text"];
[ud setObject:[self.welcomeGroupIds allObjects] forKey:@"AC_AutoWelcome_Groups"];
if (self.capturedClientTypeV2) {
[ud setObject:self.capturedClientTypeV2 forKey:@"AC_Captured_ClientTypeV2"];
}
if (self.latestHTTPHeaders.count > 0) {
NSMutableDictionary *safeHeaders = [NSMutableDictionary dictionary];
NSSet *allowed = [NSSet setWithObjects:@"token", @"x-userid", @"version", @"channel", @"x-lts-id", nil];
[self.latestHTTPHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
if (![k isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSString class]]) return;
NSString *lk = k.lowercaseString;
if (![allowed containsObject:lk]) return;
if ([lk isEqualToString:@"x-lts-id"] && ((NSString *)v).length < 140) return;
safeHeaders[lk] = v;
}];
[ud setObject:safeHeaders forKey:@"AC_Saved_HTTPHeaders"];
}
if (self.selfUserId.length > 5) {
[ud setObject:self.selfUserId forKey:@"AC_Saved_SelfUserId"];
}
[ud setBool:self.autoReplyEnabled forKey:@"AC_AutoReply_Enabled"];
NSMutableArray *rDicts = [NSMutableArray array];
for (ACAutoReplyRule *r in self.autoReplyRules) {
[rDicts addObject:(ACJSONSafeObject([r toDict], 0) ?: @{})];
}
[rDicts writeToFile:[self cacheFilePath:@"autoreply_rules"] atomically:YES];
[ud setBool:self.autoMomentEnabled forKey:@"AC_AutoMoment_Enabled"];
[ud setInteger:MAX(1, self.momentIntervalMinutes) forKey:@"AC_AutoMoment_Interval"];
[ud setBool:self.autoCommentEnabled forKey:@"AC_AutoComment_Enabled"];
[ud setObject:(self.autoCommentText ?: @"不错") forKey:@"AC_AutoComment_Text"];
NSArray *seenArr = [[self.autoCommentSeenIds allObjects] sortedArrayUsingSelector:@selector(compare:)];
if (seenArr.count > 1500) seenArr = [seenArr subarrayWithRange:NSMakeRange(seenArr.count - 1500, 1500)];
[ud setObject:seenArr forKey:@"AC_AutoComment_Seen"];
NSMutableArray *mDicts = [NSMutableArray array];
for (ACMomentTaskItem *t in self.momentTasks) {
[mDicts addObject:(ACJSONSafeObject([t toDict], 0) ?: @{})];
}
[mDicts writeToFile:[self cacheFilePath:@"moment_tasks"] atomically:YES];
[ud synchronize];
} @catch (NSException *e) {}
}
- (void)loadAllCustomSettings {
@try {
NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
self.autoWelcomeEnabled = [ud boolForKey:@"AC_AutoWelcome_Enabled"];
NSString *savedText = ACSafeStr([ud objectForKey:@"AC_AutoWelcome_Text"]);
self.welcomeMessageText = (savedText.length > 0) ? savedText : @"您好 {name}，欢迎进群！认识一下~";
NSArray *savedGroups = ACSafeArray([ud objectForKey:@"AC_AutoWelcome_Groups"]);
if (savedGroups) {
for (id g in savedGroups) {
NSString *gs = ACSafeStr(g);
if (gs.length > 0) [self.welcomeGroupIds addObject:gs];
}
}
NSString *savedV2 = ACSafeStr([ud objectForKey:@"AC_Captured_ClientTypeV2"]);
if (savedV2.length > 10) {
self.capturedClientTypeV2 = savedV2;
}
self.autoCommentEnabled = [ud boolForKey:@"AC_AutoComment_Enabled"];
NSString *savedComment = ACSafeStr([ud objectForKey:@"AC_AutoComment_Text"]);
self.autoCommentText = savedComment.length > 0 ? savedComment : @"不错";
NSArray *savedSeen = ACSafeArray([ud objectForKey:@"AC_AutoComment_Seen"]);
if (savedSeen.count > 0) {
for (id v in savedSeen) { NSString *sid = ACSafeStr(v); if (sid.length > 3) [self.autoCommentSeenIds addObject:sid]; }
self.autoCommentSeeded = YES;
}
// 兼容旧版本：只恢复合法 Header，丢弃被 COS/上传请求污染的 UA 与短格式 X-Lts-Id
NSDictionary *savedHeaders = ACSafeDict([ud objectForKey:@"AC_Saved_HTTPHeaders"]);
if (savedHeaders) {
NSMutableDictionary *clean = [NSMutableDictionary dictionary];
[savedHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
if (![k isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSString class]]) return;
NSString *lk = k.lowercaseString;
if (!([lk isEqualToString:@"token"] || [lk isEqualToString:@"x-userid"] ||
[lk isEqualToString:@"version"] || [lk isEqualToString:@"channel"] || [lk isEqualToString:@"x-lts-id"])) return;
if ([lk isEqualToString:@"x-lts-id"] && ((NSString *)v).length < 140) return;
clean[lk] = v;
}];
[self.latestHTTPHeaders addEntriesFromDictionary:clean];
savedHeaders = clean;
// 旧版本可能只存了原始大小写，统一补一份小写键
for (NSString *k in savedHeaders) {
if ([k isKindOfClass:[NSString class]]) {
id v = savedHeaders[k];
if ([v isKindOfClass:[NSString class]]) self.latestHTTPHeaders[k.lowercaseString] = v;
}
}
}
NSString *savedUid = ACSafeStr([ud objectForKey:@"AC_Saved_SelfUserId"]);
if (savedUid.length > 5) {
self.selfUserId = savedUid;
}
self.autoReplyEnabled = [ud boolForKey:@"AC_AutoReply_Enabled"];
NSArray *rArr = [NSArray arrayWithContentsOfFile:[self cacheFilePath:@"autoreply_rules"]];
if ([rArr isKindOfClass:[NSArray class]] && rArr.count > 0) {
for (NSDictionary *d in rArr) {
ACAutoReplyRule *r = [ACAutoReplyRule fromDict:d];
if (r) [self.autoReplyRules addObject:r];
}
}
if (self.autoReplyRules.count == 0) {
ACAutoReplyRule *defRule = [[ACAutoReplyRule alloc] init];
defRule.ruleId = @"default_1";
defRule.keyword = @"";
defRule.replyText = @"您好 {name}，消息已收到，稍后第一时间回复您！";
defRule.attachMedia = YES;
defRule.enabled = YES;
[self.autoReplyRules addObject:defRule];
}
self.autoMomentEnabled = [ud boolForKey:@"AC_AutoMoment_Enabled"];
NSInteger savedInt = [ud integerForKey:@"AC_AutoMoment_Interval"];
self.momentIntervalMinutes = savedInt > 0 ? savedInt : 30;
NSArray *mArr = [NSArray arrayWithContentsOfFile:[self cacheFilePath:@"moment_tasks"]];
if ([mArr isKindOfClass:[NSArray class]] && mArr.count > 0) {
for (NSDictionary *d in mArr) {
ACMomentTaskItem *t = [ACMomentTaskItem fromDict:d];
if (t) [self.momentTasks addObject:t];
}
}
if (self.momentTasks.count == 0) {
ACMomentTaskItem *t1 = [[ACMomentTaskItem alloc] init];
t1.taskId = @"m_1";
t1.contentText = @"✨欢迎各位宝子来到飞机大家庭\n一起努力、一起交流❤️\n有问题随时私信咨询，一直在线哦~";
t1.enabled = YES;
t1.lastSentTimeStr = @"待发布";
[self.momentTasks addObject:t1];
ACMomentTaskItem *t2 = [[ACMomentTaskItem alloc] init];
t2.taskId = @"m_2";
t2.contentText = @"☀️新的一天，机会总是留给有准备的人！\n长期稳定靠谱，欢迎新老朋友交流合作🔥";
t2.enabled = YES;
t2.lastSentTimeStr = @"待发布";
[self.momentTasks addObject:t2];
}
} @catch (NSException *e) {}
}
- (void)saveLocalPermanentCache {
dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
@synchronized (self) {
@try {
NSMutableArray *fArr = [NSMutableArray array];
for (ACContactItem *i in self.friendList) [fArr addObject:[i toDict]];
[fArr writeToFile:[self cacheFilePath:@"friends"] atomically:YES];
NSMutableArray *mArr = [NSMutableArray array];
for (ACContactItem *i in self.groupMemberList) [mArr addObject:[i toDict]];
[mArr writeToFile:[self cacheFilePath:@"members"] atomically:YES];
NSMutableArray *gArr = [NSMutableArray array];
for (ACContactItem *i in self.groupList) [gArr addObject:[i toDict]];
[gArr writeToFile:[self cacheFilePath:@"groups"] atomically:YES];
} @catch (NSException *e) {}
}
});
}
- (void)loadLocalPermanentCache {
@synchronized (self) {
@try {
NSArray *fArr = [NSArray arrayWithContentsOfFile:[self cacheFilePath:@"friends"]];
if ([fArr isKindOfClass:[NSArray class]]) {
for (NSDictionary *d in fArr) {
ACContactItem *item = [ACContactItem fromDict:d];
if (item && item.targetId.length > 0 && !self.friendMap[item.targetId]) {
self.friendMap[item.targetId] = item;
[self.friendList addObject:item];
}
}
}
NSArray *mArr = [NSArray arrayWithContentsOfFile:[self cacheFilePath:@"members"]];
if ([mArr isKindOfClass:[NSArray class]]) {
for (NSDictionary *d in mArr) {
ACContactItem *item = [ACContactItem fromDict:d];
if (item && item.targetId.length > 0 && !self.groupMemberMap[item.targetId]) {
self.groupMemberMap[item.targetId] = item;
[self.groupMemberList addObject:item];
}
}
}
NSArray *gArr = [NSArray arrayWithContentsOfFile:[self cacheFilePath:@"groups"]];
if ([gArr isKindOfClass:[NSArray class]]) {
for (NSDictionary *d in gArr) {
ACContactItem *item = [ACContactItem fromDict:d];
if (item && item.targetId.length > 0 && !self.groupMap[item.targetId]) {
self.groupMap[item.targetId] = item;
[self.groupList addObject:item];
}
}
}
} @catch (NSException *e) {}
}
}
#pragma mark - 2.1 腾讯云 IM 实时监听（迎新使用槽位1，自动回复使用规则专属媒体或槽位2）
- (void)setupIMGroupWelcomeListener {
@try {
Class v2Cls = NSClassFromString(@"V2TIMManager");
if (!v2Cls || ![v2Cls respondsToSelector:@selector(sharedInstance)]) return;
id mgr = ((id (*)(id, SEL))objc_msgSend)(v2Cls, @selector(sharedInstance));
if (!mgr) return;
BOOL allOK = YES;
SEL addGrpSel = NSSelectorFromString(@"addGroupListener:");
if ([mgr respondsToSelector:addGrpSel]) {
if (!self.groupListenerRegistered) {
((void (*)(id, SEL, id))objc_msgSend)(mgr, addGrpSel, self);
self.groupListenerRegistered = YES;
}
} else { allOK = NO; }
SEL addMsgSel = NSSelectorFromString(@"addAdvancedMsgListener:");
if ([mgr respondsToSelector:addMsgSel]) {
if (!self.msgListenerRegistered) {
((void (*)(id, SEL, id))objc_msgSend)(mgr, addMsgSel, self);
self.msgListenerRegistered = YES;
}
} else { allOK = NO; }
self.listenerRegistered = allOK;
// 修复：任一监听注册失败就定时重试，避免“第一次没注册上就永远收不到消息”
if (!allOK && !self.listenerRetryScheduled) {
self.listenerRetryScheduled = YES;
__weak typeof(self) weakSelf = self;
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
weakSelf.listenerRetryScheduled = NO;
[weakSelf setupIMGroupWelcomeListener];
});
}
} @catch (NSException *e) {}
}

- (void)onMemberEnter:(NSString *)groupID memberList:(NSArray *)memberList {
[self ac_handleMembersJoined:memberList groupID:groupID];
}
- (void)onMemberInvited:(NSString *)groupID opUser:(id)opUser memberList:(NSArray *)memberList {
[self ac_handleMembersJoined:memberList groupID:groupID];
}
- (void)ac_handleMembersJoined:(NSArray *)memberList groupID:(NSString *)groupID {
[self handleNewMembersJoinedGroup:groupID memberList:memberList];
}
- (void)onRecvNewMessage:(id)msg {
[self ac_handleIncomingMessage:msg];
}
- (void)ac_handleIncomingMessage:(id)msg {
if (!msg) return;
@try {
NSData *cData = ACSafeValue(msg, @"cloudCustomData");
if ([cData isKindOfClass:[NSData class]] && cData.length > 10) {
NSDictionary *cDict = ACSafeDict([NSJSONSerialization JSONObjectWithData:cData options:0 error:nil]);
NSString *v2Str = ACSafeStr(cDict[@"client_typeV2"]);
if (v2Str.length > 10) {
self.capturedClientTypeV2 = v2Str;
self.capturedCloudCustomData = cData;
}
}
BOOL isSelf = [ACSafeValue(msg, @"isSelf") boolValue];
NSString *groupID = ACSafeStr(ACSafeValue(msg, @"groupID"));
NSString *userID = ACSafeStr(ACSafeValue(msg, @"userID"));
NSString *sender = ACSafeStr(ACSafeValue(msg, @"sender"));
if (sender.length == 0) sender = userID;
if (sender.length == 0) sender = ACSafeStr(ACSafeValue(msg, @"fromUser"));
if (sender.length == 0) sender = ACSafeStr(ACSafeValue(msg, @"from"));
NSString *nickName = ACSafeStr(ACSafeValue(msg, @"nickName"));
if (nickName.length == 0) nickName = ACSafeStr(ACSafeValue(msg, @"nameCard"));
if (nickName.length == 0) nickName = ACSafeStr(ACSafeValue(msg, @"friendRemark"));
// A. 别人发来的 C2C 私信 -> 自动回复（严格使用槽位2或该条规则绑定的专属图片/视频）
if (groupID.length == 0 && sender.length >= 5 && !isSelf && ![sender isEqualToString:self.selfUserId]) {
[self addFriendWithId:sender name:nickName tag:@"主动来信" chatMeType:0];
[self saveLocalPermanentCache];
if (self.autoReplyEnabled && self.autoReplyRules.count > 0) {
NSString *incomingText = @"";
id textElem = ACSafeValue(msg, @"textElem");
if (textElem && ![textElem isKindOfClass:[NSNull class]]) {
incomingText = ACSafeStr(ACSafeValue(textElem, @"text"));
}
if (incomingText.length == 0) incomingText = ACSafeStr(ACSafeValue(msg, @"text"));
if (incomingText.length == 0) incomingText = ACSafeStr(ACSafeValue(msg, @"description"));
[self handleIncomingPrivateMessageFrom:sender nickName:nickName text:incomingText];
}
return;
}
// B. 群消息处理
if (groupID.length == 0) return;
if (sender.length > 0 && !isSelf) {
if ([self addGroupMemberWithId:sender name:nickName groupId:groupID role:@"群活跃" chatMeType:0]) {
[self saveLocalPermanentCache];
}
}
id tipsElem = ACSafeValue(msg, @"groupTipsElem");
if (tipsElem && ![tipsElem isKindOfClass:[NSNull class]]) {
NSInteger tipsType = [ACSafeStr(ACSafeValue(tipsElem, @"type")) integerValue];
if (tipsType == 1 || tipsType == 2) {
NSArray *memberList = ACSafeArray(ACSafeValue(tipsElem, @"memberList"));
if (memberList.count > 0) {
[self handleNewMembersJoinedGroup:groupID memberList:memberList];
}
}
}
} @catch (NSException *e) {}
}
- (void)handleIncomingPrivateMessageFrom:(NSString *)senderId nickName:(NSString *)nick text:(NSString *)incomingText {
@try {
NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
NSNumber *lastTimeNum = self.autoReplyCooldownMap[senderId];
if (lastTimeNum && (now - [lastTimeNum doubleValue] < 60.0)) {
return;
}
ACAutoReplyRule *matchedRule = nil;
ACAutoReplyRule *fallbackRule = nil;
ACAutoReplyRule *firstEnabledRule = nil;
for (ACAutoReplyRule *rule in self.autoReplyRules) {
if (!rule.enabled || rule.replyText.length == 0) continue;
if (!firstEnabledRule) firstEnabledRule = rule;
NSString *kw = [rule.keyword stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
if (ACIsCatchAllKeyword(kw)) {
if (!fallbackRule) fallbackRule = rule;
} else if (incomingText.length > 0 && [incomingText localizedCaseInsensitiveContainsString:kw]) {
matchedRule = rule;
break;
}
}
// 修复：关键词未命中时也回落到首条启用规则，避免“只填回复内容却永远不触发”
ACAutoReplyRule *finalRule = matchedRule ?: fallbackRule ?: firstEnabledRule;
if (!finalRule) return;
self.autoReplyCooldownMap[senderId] = @(now);
NSString *displayNick = (nick.length > 0) ? nick : @"朋友";
NSString *replyContent = [finalRule.replyText stringByReplacingOccurrencesOfString:@"{name}" withString:displayNick];
ACContactItem *peer = self.friendMap[senderId];
if (!peer) {
peer = [[ACContactItem alloc] init];
peer.targetId = senderId;
peer.name = displayNick;
peer.sourceType = 0;
peer.chatMeType = 0;
}
NSTimeInterval replyDelay = 3.0 + (arc4random_uniform(41) / 10.0);
__weak typeof(self) weakSelf = self;
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(replyDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
if (!weakSelf.autoReplyEnabled) return;
NSFileManager *fm = [NSFileManager defaultManager];
if (finalRule.attachMedia && finalRule.customMediaType > 0 && finalRule.customMediaPath.length > 0 && [fm fileExistsAtPath:finalRule.customMediaPath]) {
// 如果该条规则绑定了独立媒体文件，优先发送该规则自己的独立媒体
[weakSelf sendText:replyContent
customMediaType:finalRule.customMediaType
customMediaPath:finalRule.customMediaPath
customThumbPath:finalRule.customThumbPath
customVideoDuration:finalRule.customVideoDuration
toItem:peer
completion:^(BOOL ok, NSString *detail) {
if (ok) {
weakSelf.autoRepliedCount++;
weakSelf.lastAutoReplyLog = [NSString stringWithFormat:@"✅ 已自动回复 %@ (%@) | 累计%ld次", displayNick, detail, (long)weakSelf.autoRepliedCount];
} else {
weakSelf.lastAutoReplyLog = [NSString stringWithFormat:@"⚠️ 自动回复 %@ 失败: %@", displayNick, detail];
}
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
}];
} else {
// 否则使用槽位2（ACMediaSlotAutoReply 自动回复专属槽位，与群发槽位0完全隔离）
[weakSelf sendText:replyContent
mediaSlot:ACMediaSlotAutoReply
attachMedia:finalRule.attachMedia
toItem:peer
completion:^(BOOL ok, NSString *detail) {
if (ok) {
weakSelf.autoRepliedCount++;
weakSelf.lastAutoReplyLog = [NSString stringWithFormat:@"✅ 已自动回复 %@ (%@) | 累计%ld次", displayNick, detail, (long)weakSelf.autoRepliedCount];
} else {
weakSelf.lastAutoReplyLog = [NSString stringWithFormat:@"⚠️ 自动回复 %@ 失败: %@", displayNick, detail];
}
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
}];
}
});
} @catch (NSException *e) {}
}
#pragma mark - 2.1.2 多任务定时自动发动态（严格还原抓包报文结构 + 独立媒体上传）
- (void)restartMomentScheduler {
dispatch_async(dispatch_get_main_queue(), ^{
if (self.momentTimer) {
[self.momentTimer invalidate];
self.momentTimer = nil;
}
if (!self.autoMomentEnabled) return;
// 本地不做发布冷却；间隔由用户设置（最低 1 分钟），服务端限频时按其文案退避
NSTimeInterval intervalSec = MAX(1, self.momentIntervalMinutes) * 60.0;
self.momentTimer = [NSTimer scheduledTimerWithTimeInterval:intervalSec
target:self
selector:@selector(onMomentTimerTick)
userInfo:nil
repeats:YES];
});
}
- (void)onMomentTimerTick {
if (!self.autoMomentEnabled || self.momentTasks.count == 0) return;
NSMutableArray<ACMomentTaskItem *> *activeTasks = [NSMutableArray array];
for (ACMomentTaskItem *t in self.momentTasks) {
if (t.enabled && t.contentText.length > 0) {
[activeTasks addObject:t];
}
}
if (activeTasks.count == 0) return;
if (self.currentMomentRotationIdx >= activeTasks.count) {
self.currentMomentRotationIdx = 0;
}
ACMomentTaskItem *taskToPublish = activeTasks[self.currentMomentRotationIdx];
self.currentMomentRotationIdx = (self.currentMomentRotationIdx + 1) % activeTasks.count;
[self publishMomentTask:taskToPublish completion:nil];
}
// 仅在失败/服务端明确限频时安排一次重试，不影响用户手动发布
- (void)ac_scheduleMomentRetryAfter:(NSTimeInterval)delay {
if (self.momentRetryScheduled) return;
self.momentRetryScheduled = YES;
__weak typeof(self) weakSelf = self;
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(30.0, delay) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
weakSelf.momentRetryScheduled = NO;
if (weakSelf.autoMomentEnabled) [weakSelf onMomentTimerTick];
});
}
#pragma mark - 自动评论引擎（信息流有新动态即跟评）
- (void)ac_handleFeedResponse:(NSDictionary *)json {
@try {
if (!self.autoCommentEnabled) return;
NSDictionary *data = ACSafeDict(json[@"data"]);
NSArray *records = ACSafeArray(data[@"records"]);
if (records.count == 0) return;
NSDateFormatter *df = [[NSDateFormatter alloc] init];
df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
NSMutableArray *fresh = [NSMutableArray array];
for (NSDictionary *rec in records) {
if (![rec isKindOfClass:[NSDictionary class]]) continue;
NSString *pid = ACSafeStr(rec[@"id"]);
NSString *uid = ACSafeStr(rec[@"userId"]);
if (pid.length < 5) continue;
BOOL seen = [self.autoCommentSeenIds containsObject:pid];
[self.autoCommentSeenIds addObject:pid];
if (seen) continue;
if (uid.length > 3 && [uid isEqualToString:self.selfUserId]) continue; // 自己的动态不评论
id perm = rec[@"commentPermission"];
if (perm && [perm respondsToSelector:@selector(integerValue)] && [perm integerValue] == 0) continue;
NSTimeInterval ct = 0;
NSDate *created = [df dateFromString:ACSafeStr(rec[@"createTime"])];
if (created) ct = [created timeIntervalSince1970];
if (!self.autoCommentSeeded) {
// 刚开启功能：只评论“开启之后”发布的动态，避免把历史动态全部刷一遍
if (self.autoCommentEnabledAt > 0 && ct >= self.autoCommentEnabledAt - 5.0) [fresh addObject:pid];
continue;
}
[fresh addObject:pid];
}
if (!self.autoCommentSeeded) {
self.autoCommentSeeded = YES;
ACLog(@"[自动评论] 首次信息流播种完成，历史 %lu 条不评论，本次新动态 %lu 条",
(unsigned long)records.count, (unsigned long)fresh.count);
} else if (fresh.count > 0) {
ACLog(@"[自动评论] 发现 %lu 条新动态：%@", (unsigned long)fresh.count, fresh);
}
// 倒序：先处理较新的
for (NSString *pid in [[fresh reverseObjectEnumerator] allObjects]) {
[self ac_enqueueAutoCommentForPostId:pid];
}
} @catch (NSException *e) {
ACLog(@"[自动评论] 解析信息流异常 %@: %@", e.name, e.reason);
}
}
- (void)ac_enqueueAutoCommentForPostId:(NSString *)postId {
if (postId.length < 5) return;
if (!self.autoCommentQueue) self.autoCommentQueue = [NSMutableArray array];
if ([self.autoCommentQueue containsObject:postId]) return;
[self.autoCommentQueue addObject:postId];
[self ac_pumpAutoCommentQueue];
}
- (void)ac_pumpAutoCommentQueue {
if (self.autoCommentSending) return;
if (self.autoCommentQueue.count == 0) return;
if (!self.autoCommentEnabled) { [self.autoCommentQueue removeAllObjects]; return; }
NSString *pid = self.autoCommentQueue.firstObject;
[self.autoCommentQueue removeObjectAtIndex:0];
self.autoCommentSending = YES;
NSString *text = self.autoCommentText.length > 0 ? self.autoCommentText : @"不错";
[self ac_commentPostId:pid text:text];
}
- (void)ac_commentPostId:(NSString *)postId text:(NSString *)text {
@try {
NSString *token = ACHeaderValue(self.latestHTTPHeaders, @"token");
if (token.length == 0) {
self.autoCommentSending = NO;
ACLog(@"[自动评论] 跳过 %@：token 未捕获", postId);
return;
}
NSURL *url = [NSURL URLWithString:@"https://apiv1.airchat.cc/client/biz/v2/post/interaction/comment/publish"];
NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
req.HTTPMethod = @"POST";
[req setValue:@"*/*" forHTTPHeaderField:@"Accept"];
[req setValue:@"zh-CN,zh-Hans;q=0.9" forHTTPHeaderField:@"Accept-Language"];
[req setValue:@"gzip, deflate, br" forHTTPHeaderField:@"Accept-Encoding"];
[req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
[req setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
[req setValue:kACNativeUserAgent forHTTPHeaderField:@"User-Agent"];
[req setValue:token forHTTPHeaderField:@"token"];
[req setValue:(self.selfUserId ?: @"") forHTTPHeaderField:@"x-userid"];
[req setValue:(ACHeaderValue(self.latestHTTPHeaders, @"version") ?: @"2.1.8 (1017)") forHTTPHeaderField:@"version"];
[req setValue:(ACHeaderValue(self.latestHTTPHeaders, @"channel") ?: @"ios") forHTTPHeaderField:@"channel"];
NSString *ltsId = ACHeaderValue(self.lastPublishHeaders, @"X-Lts-Id");
if (ltsId.length == 0) ltsId = ACHeaderValue(self.latestHTTPHeaders, @"X-Lts-Id");
if (ltsId.length < 140 && self.latestAppSession) {
NSString *sessLts = ACHeaderValue(self.latestAppSession.configuration.HTTPAdditionalHeaders, @"X-Lts-Id");
if (sessLts.length >= 140) ltsId = sessLts;
}
NSTimeInterval ltsAge = self.latestLtsAt > 0 ? [[NSDate date] timeIntervalSince1970] - self.latestLtsAt : -1;
if (ltsId.length >= 140 && (ltsAge <= 30 || self.latestAppSession)) {
[req setValue:ltsId forHTTPHeaderField:@"X-Lts-Id"];
}
uint64_t nowMs = (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
static uint64_t acReqSeq = 0;
acReqSeq = (acReqSeq + 1) & 0x7F;
[req setValue:[NSString stringWithFormat:@"%015llu", (nowMs << 7) | acReqSeq] forHTTPHeaderField:@"X-Request-No"];
NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"content": text ?: @"不错", @"postId": postId} options:0 error:nil];
if (!body) { self.autoCommentSending = NO; return; }
req.HTTPBody = body;
[req setValue:[NSString stringWithFormat:@"%lu", (unsigned long)body.length] forHTTPHeaderField:@"Content-Length"];
ACLog(@"[自动评论] 发送 postId=%@ text=%@ ltsLen=%lu", postId, text, (unsigned long)ltsId.length);
acInternalRequest = YES;
NSURLSession *acSession = [ACForwardHelperManager shared].latestAppSession;
if (!acSession) acSession = [NSURLSession sharedSession];
ACLog(@"[自动评论] 使用 AppSession=%@", acSession == [NSURLSession sharedSession] ? @"否(shared)" : @"是");
NSURLSessionDataTask *t = [acSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
dispatch_async(dispatch_get_main_queue(), ^{
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
mgr.autoCommentSending = NO;
NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
NSString *raw = data.length ? ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"") : @"";
NSInteger code = 0;
NSDictionary *jd = ACSafeDict([NSJSONSerialization JSONObjectWithData:(data ?: [NSData data]) options:0 error:nil]);
if (jd) code = [ACSafeStr(jd[@"code"]) integerValue];
if (code == 200) {
mgr.lastMomentLog = [NSString stringWithFormat:@"💬 已自动评论：%@", text];
} else {
mgr.lastMomentLog = [NSString stringWithFormat:@"⚠️ 自动评论失败 HTTP %ld / code %ld %@", (long)status, (long)code,
raw.length > 60 ? [raw substringToIndex:60] : raw];
}
ACLog(@"[自动评论] 回调 %@ HTTP %ld code=%ld body=%@", postId, (long)status, (long)code, raw.length > 160 ? [raw substringToIndex:160] : raw);
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
[mgr saveAllCustomSettings];
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
[mgr ac_pumpAutoCommentQueue];
});
});
}];
acInternalRequest = NO;
[t resume];
} @catch (NSException *e) {
self.autoCommentSending = NO;
ACLog(@"[自动评论] 异常 %@: %@", e.name, e.reason);
}
}
static NSInteger ACParseRetryMinutes(NSString *msg) {
// 服务端文案：“发布过于频繁，请5分钟后再次尝试。#SVIP”
if (msg.length == 0) return 5;
NSRange r = [msg rangeOfString:@"分钟"];
if (r.location == NSNotFound) return 5;
NSInteger end = (NSInteger)r.location;
NSInteger start = end;
while (start > 0) {
unichar c = [msg characterAtIndex:(NSUInteger)(start - 1)];
if (c >= '0' && c <= '9') start--; else break;
}
if (start >= end) return 5;
NSInteger v = [[msg substringWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)(end - start))] integerValue];
return (v > 0 && v <= 720) ? v : 5;
}
- (void)publishMomentTask:(ACMomentTaskItem *)task completion:(void(^)(BOOL ok, NSString *msg))completion {
ACLog(@"[发布] 入口 task=%@ textLen=%lu token=%lu lts=%lu publishing=%d",
task ? @"有" : @"无", (unsigned long)task.contentText.length,
(unsigned long)ACHeaderValue(self.latestHTTPHeaders, @"token").length,
(unsigned long)ACHeaderValue(self.latestHTTPHeaders, @"X-Lts-Id").length,
(int)self.momentPublishing);
if (!task || task.contentText.length == 0) {
self.lastMomentLog = @"❌ 动态内容为空，发布被跳过";
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(NO, self.lastMomentLog);
return;
}
// 自愈：上一次发布如果因进程挂起/会话失效没有回调，不能永久卡住后续发布
if (self.momentPublishing && self.momentPublishingSince > 0 &&
[[NSDate date] timeIntervalSince1970] - self.momentPublishingSince > 120.0) {
ACLog(@"[发布] 检测到上一次发布超过120秒未回调，强制解锁");
self.momentPublishing = NO;
}
if (self.momentPublishing) {
self.lastMomentLog = @"⏳ 上一条动态仍在发布中，请稍后再试";
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(NO, self.lastMomentLog);
return;
}
// 修复：token 大小写无关，并允许等待 App 后续请求把 token 捕获进来
NSString *token = ACHeaderValue(self.latestHTTPHeaders, @"token");
if (token.length == 0) {
self.lastMomentLog = @"⏳ 正在获取登录凭证（最多等待 20 秒，请保持 App 前台）...";
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
__weak typeof(self) weakSelf = self;
__block NSInteger tries = 0;
__block void (^waitBlock)(void);
waitBlock = ^{
NSString *tk = ACHeaderValue(weakSelf.latestHTTPHeaders, @"token");
if (tk.length > 0) {
[weakSelf publishMomentTask:task completion:completion];
return;
}
if (++tries >= 40) {
weakSelf.lastMomentLog = @"❌ 未捕获到登录凭证：请先在 App 内切换一次页面（任意 API 请求）后重试";
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(NO, weakSelf.lastMomentLog);
return;
}
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), waitBlock);
};
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), waitBlock);
return;
}
@try {
acInternalRequest = NO;
self.momentPublishing = YES;
self.momentPublishingSince = [[NSDate date] timeIntervalSince1970];
NSURL *url = [NSURL URLWithString:@"https://apiv1.airchat.cc/client/biz/v2/post/app/publish"];
NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
req.HTTPMethod = @"POST";
// 修复：Accept 必须是 */*；UA 必须固定为 App 原生 UA。
// 旧版从全局 Header 池取值，会被 COS 上传请求污染成 cos-xml-ios-sdk + Accept "/"，
// 网关直接返回 HTTP 500（空 body），这就是“发布没效果”的主因。
[req setValue:@"*/*" forHTTPHeaderField:@"Accept"];
[req setValue:@"zh-CN,zh-Hans;q=0.9" forHTTPHeaderField:@"Accept-Language"];
[req setValue:@"gzip, deflate, br" forHTTPHeaderField:@"Accept-Encoding"];
[req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
[req setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
[req setValue:kACNativeUserAgent forHTTPHeaderField:@"User-Agent"];
[req setValue:token forHTTPHeaderField:@"token"];
[req setValue:(self.selfUserId ?: @"") forHTTPHeaderField:@"x-userid"];
[req setValue:(ACHeaderValue(self.latestHTTPHeaders, @"version") ?: @"2.1.8 (1017)") forHTTPHeaderField:@"version"];
[req setValue:(ACHeaderValue(self.latestHTTPHeaders, @"channel") ?: @"ios") forHTTPHeaderField:@"channel"];
// X-Lts-Id 优先取最近一次“原生发布动态”请求的模板；全局池只接受合法长格式
NSString *ltsId = ACHeaderValue(self.lastPublishHeaders, @"X-Lts-Id");
if (ltsId.length == 0) ltsId = ACHeaderValue(self.latestHTTPHeaders, @"X-Lts-Id");
if (ltsId.length < 140 && self.latestAppSession) {
NSString *sessLts = ACHeaderValue(self.latestAppSession.configuration.HTTPAdditionalHeaders, @"X-Lts-Id");
if (sessLts.length >= 140) ltsId = sessLts;
}
NSTimeInterval ltsAge = self.latestLtsAt > 0 ? [[NSDate date] timeIntervalSince1970] - self.latestLtsAt : -1;
if (ltsId.length >= 140 && (ltsAge <= 30 || self.latestAppSession)) {
[req setValue:ltsId forHTTPHeaderField:@"X-Lts-Id"];
}
// 修复：X-Request-No 与 App 原生一致 = (毫秒时间戳 << 7) | 0~127 序号，15 位数字
uint64_t nowMs = (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
uint64_t reqNoVal = (nowMs << 7) | (uint64_t)(arc4random() & 0x7F);
NSString *reqNo = [NSString stringWithFormat:@"%015llu", reqNoVal];
[req setValue:reqNo forHTTPHeaderField:@"X-Request-No"];
// 请求体：纯文本 contentType=1；带远端媒体 contentType=2（抓包实证）
id safeMedia = ACJSONSafeObject(task.capturedMediaList, 0);
NSArray *mediaArr = [safeMedia isKindOfClass:[NSArray class]] ? (NSArray *)safeMedia : nil;
BOOL hasRemoteMedia = (mediaArr.count > 0);
NSMutableDictionary *bodyDict = [NSMutableDictionary dictionary];
bodyDict[@"commentPermission"] = @(1);
bodyDict[@"contentText"] = ACSafeStr(task.contentText);
if (hasRemoteMedia) {
// 抓包实证：原生带图动态 contentType = 2（不是 3），3 会被业务层判非法
bodyDict[@"contentType"] = @(2);
bodyDict[@"mediaList"] = mediaArr;
} else {
bodyDict[@"contentType"] = @(1);
}
NSData *bodyData = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil];
if (!bodyData) {
self.momentPublishing = NO;
self.lastMomentLog = @"❌ 请求体序列化失败（文案含非法字符）";
ACLog(@"[发布] 请求体序列化失败");
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(NO, self.lastMomentLog);
return;
}
req.HTTPBody = bodyData;
[req setValue:[NSString stringWithFormat:@"%lu", (unsigned long)bodyData.length] forHTTPHeaderField:@"Content-Length"];
ACLog(@"[发布] 实际头发送 Lts=%lu keys=%@",
(unsigned long)ACHeaderValue([req allHTTPHeaderFields], @"X-Lts-Id").length,
[[req allHTTPHeaderFields] allKeys]);
ACLog(@"[发布] 即将发送 tokenLen=%lu ltsLen=%lu reqNo=%@ bodyLen=%lu media=%d",
(unsigned long)token.length, (unsigned long)ltsId.length, reqNo,
(unsigned long)bodyData.length, (int)hasRemoteMedia);
__weak typeof(self) weakSelf = self;
acInternalRequest = YES;
NSURLSession *acPubSession = [ACForwardHelperManager shared].latestAppSession;
if (!acPubSession) acPubSession = [NSURLSession sharedSession];
ACLog(@"[发布] AppSession=%@ ltsAge=%.1fs", acPubSession == [NSURLSession sharedSession] ? @"否(shared)" : @"是",
self.latestLtsAt > 0 ? [[NSDate date] timeIntervalSince1970] - self.latestLtsAt : -1.0);
NSURLSessionDataTask *publishTask =
[acPubSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
dispatch_async(dispatch_get_main_queue(), ^{
weakSelf.momentPublishing = NO;
NSHTTPURLResponse *httpResp = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
NSInteger httpStatus = httpResp ? (NSInteger)httpResp.statusCode : 0;
NSString *rawText = data.length > 0 ? ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"") : @"";
ACLog(@"[发布] 回调 HTTP %ld err=%@ body=%@", (long)httpStatus,
error.localizedDescription ?: @"无",
rawText.length > 200 ? [rawText substringToIndex:200] : rawText);
if (error) {
NSString *failMsg = [NSString stringWithFormat:@"❌ 发布异常 HTTP %ld: %@", (long)httpStatus, error.localizedDescription ?: @"网络错误"];
weakSelf.lastMomentLog = failMsg;
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(NO, failMsg);
[weakSelf ac_scheduleMomentRetryAfter:60.0];
return;
}
NSDictionary *respDict = ACSafeDict([NSJSONSerialization JSONObjectWithData:(data ?: [NSData data]) options:0 error:nil]);
if (!respDict) {
// 没有 JSON：网关/鉴权层直接拒绝（例如 Header 被污染导致 HTTP 500 空 body）
NSString *snippet = rawText.length > 120 ? [rawText substringToIndex:120] : rawText;
NSString *failMsg = [NSString stringWithFormat:@"❌ 发布被拒 HTTP %ld：%@", (long)httpStatus, snippet.length ? snippet : @"(空响应)"];
weakSelf.lastMomentLog = failMsg;
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(NO, failMsg);
[weakSelf ac_scheduleMomentRetryAfter:60.0];
return;
}
NSInteger code = [ACSafeStr(respDict[@"code"]) integerValue];
if (code == 200) {
task.sentCount++;
NSDateFormatter *df = [[NSDateFormatter alloc] init];
df.dateFormat = @"HH:mm:ss";
task.lastSentTimeStr = [df stringFromDate:[NSDate date]];
[weakSelf saveAllCustomSettings];
NSString *postIdStr = ACSafeStr(respDict[@"data"]);
NSString *okMsg = [NSString stringWithFormat:@"✅ 动态发布成功(%@) ID:%@ | 累计%ld次", task.lastSentTimeStr, postIdStr, (long)task.sentCount];
weakSelf.lastMomentLog = okMsg;
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(YES, okMsg);
return;
}
NSString *serverMsg = ACSafeStr(respDict[@"msg"]);
if (serverMsg.length == 0) serverMsg = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"接口返回非200";
// 修复：识别 token 过期与频率限制，分别走“重新抓 token”和“按服务端时间退避”
if (code == 401 || code == 403 || [serverMsg.lowercaseString containsString:@"token"] ||
[serverMsg containsString:@"登录"] || [serverMsg containsString:@"未授权"]) {
[weakSelf.latestHTTPHeaders removeObjectForKey:@"token"];
[weakSelf.latestHTTPHeaders removeObjectForKey:@"Token"];
[weakSelf saveAllCustomSettings];
NSString *errMsg = [NSString stringWithFormat:@"⚠️ 登录凭证失效(%ld): %@（已清除旧 token，60 秒后自动重试）", (long)code, serverMsg];
weakSelf.lastMomentLog = errMsg;
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(NO, errMsg);
[weakSelf ac_scheduleMomentRetryAfter:60.0];
return;
}
if ([serverMsg containsString:@"频繁"] || [serverMsg containsString:@"分钟"] || [serverMsg containsString:@"限制"]) {
NSInteger waitMin = ACParseRetryMinutes(serverMsg);
NSString *errMsg = [NSString stringWithFormat:@"⏳ 服务端限频(%ld): %@ | 已安排 %ld 分钟后自动重试", (long)code, serverMsg, (long)waitMin];
weakSelf.lastMomentLog = errMsg;
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(NO, errMsg);
[weakSelf ac_scheduleMomentRetryAfter:(NSTimeInterval)waitMin * 60.0];
return;
}
NSString *errLog = [NSString stringWithFormat:@"⚠️ 动态返回 HTTP %ld / code %ld: %@", (long)httpStatus, (long)code, serverMsg];
weakSelf.lastMomentLog = errLog;
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(NO, errLog);
});
}];
acInternalRequest = NO;
[publishTask resume];
} @catch (NSException *e) {
acInternalRequest = NO;
self.momentPublishing = NO;
ACLog(@"[发布] 异常 %@: %@", e.name, e.reason);
self.lastMomentLog = [NSString stringWithFormat:@"❌ 发布异常: %@", e.reason ?: e.name];
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(NO, self.lastMomentLog);
}
}

#pragma mark - 2.1.3 新人进群迎新处理（严格使用槽位1：ACMediaSlotWelcome）
- (void)handleNewMembersJoinedGroup:(NSString *)groupID memberList:(NSArray *)memberList {
NSString *cleanGid = ACSafeStr(groupID);
NSArray *cleanList = ACSafeArray(memberList);
if (cleanGid.length == 0 || cleanList.count == 0) return;
NSMutableArray<ACContactItem *> *newTargetsToGreet = [NSMutableArray array];
for (id mem in cleanList) {
@try {
if (!mem || [mem isKindOfClass:[NSNull class]]) continue;
NSString *uid = ACSafeStr([mem valueForKey:@"userID"]);
if (uid.length < 5 || [uid isEqualToString:self.selfUserId]) continue;
NSString *nick = ACSafeStr([mem valueForKey:@"nickName"]);
if (nick.length == 0) nick = ACSafeStr([mem valueForKey:@"nameCard"]);
if (nick.length == 0) nick = ACSafeStr([mem valueForKey:@"friendRemark"]);
[self addGroupMemberWithId:uid name:nick groupId:cleanGid role:@"新进群" chatMeType:0];
if (self.autoWelcomeEnabled && [self.welcomeGroupIds containsObject:cleanGid]) {
if (![self.greetedUserIds containsObject:uid]) {
[self.greetedUserIds addObject:uid];
ACContactItem *target = self.groupMemberMap[uid];
if (!target) {
target = [[ACContactItem alloc] init];
target.targetId = uid;
target.name = (nick.length > 0) ? nick : uid;
target.fromGroupId = cleanGid;
target.sourceType = 1;
target.chatMeType = 0;
}
[newTargetsToGreet addObject:target];
}
}
} @catch (NSException *e) {}
}
[self saveLocalPermanentCache];
if (newTargetsToGreet.count == 0) return;
__block NSInteger idx = 0;
__weak typeof(self) weakSelf = self;
__block void (^greetNext)(void) = ^{
if (idx >= newTargetsToGreet.count) return;
ACContactItem *newMember = newTargetsToGreet[idx];
NSString *templateText = weakSelf.welcomeMessageText ?: @"";
NSString *displayNick = (newMember.name && ![newMember.name hasPrefix:@"群友_"]) ? newMember.name : @"新朋友";
NSString *finalGreeting = [templateText stringByReplacingOccurrencesOfString:@"{name}" withString:displayNick];
// 迎新只使用槽位1（ACMediaSlotWelcome）的专属图片或视频，绝不跟群发或自动回复混用
[weakSelf sendText:finalGreeting mediaSlot:ACMediaSlotWelcome attachMedia:YES toItem:newMember completion:^(BOOL ok, NSString *detail) {
if (ok) {
weakSelf.greetedCount++;
weakSelf.lastGreetLog = [NSString stringWithFormat:@"✅ 已安全迎新(%@): %@ (共%ld人)", detail, newMember.name, (long)weakSelf.greetedCount];
} else {
weakSelf.lastGreetLog = [NSString stringWithFormat:@"⚠️ 迎新 %@: %@", newMember.name, detail];
}
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
idx++;
NSTimeInterval safeRandomDelay = 8.0 + (arc4random_uniform(71) / 10.0);
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(safeRandomDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
greetNext();
});
}];
};
NSTimeInterval initialDelay = 8.0 + (arc4random_uniform(71) / 10.0);
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(initialDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
greetNext();
});
}
#pragma mark - 2.2 联系人与群成员管理
- (void)addFriendWithId:(NSString *)uid name:(NSString *)name tag:(NSString *)tag chatMeType:(NSInteger)chatMeType {
NSString *cleanId = [ACSafeStr(uid) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
if (cleanId.length < 5 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"<null>"] || [cleanId isEqualToString:@"-1"]) return;
if ([cleanId isEqualToString:self.selfUserId] || [cleanId hasSuffix:@"_collection"] || [cleanId hasPrefix:@"@TGS#"]) return;
NSString *cleanName = ACSafeStr(name);
if ([cleanName isEqualToString:@"柠檬008"] || [cleanName isEqualToString:@"收藏夹"]) return;
@synchronized (self) {
ACContactItem *existing = self.friendMap[cleanId];
if (existing) {
if (cleanName.length > 0 && ![cleanName isEqualToString:cleanId] && ([existing.name isEqualToString:cleanId] || [existing.name hasPrefix:@"用户_"])) {
existing.name = cleanName;
}
existing.chatMeType = chatMeType;
if (tag && tag.length > 0) existing.roleDesc = tag;
return;
}
ACContactItem *item = [[ACContactItem alloc] init];
item.targetId = cleanId;
item.name = cleanName.length > 0 ? cleanName : [NSString stringWithFormat:@"用户_%@", [cleanId substringFromIndex:MAX(0, (int)cleanId.length - 4)]];
item.roleDesc = tag ?: @"好友";
item.sourceType = 0;
item.chatMeType = chatMeType;
item.isSelected = NO;
self.friendMap[cleanId] = item;
if (chatMeType == 0) {
[self.friendList insertObject:item atIndex:0];
} else {
[self.friendList addObject:item];
}
}
}
- (BOOL)addGroupMemberWithId:(NSString *)uid name:(NSString *)name groupId:(NSString *)gid role:(NSString *)role chatMeType:(NSInteger)chatMeType {
NSString *cleanId = [ACSafeStr(uid) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
if (cleanId.length < 5 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"<null>"] || [cleanId isEqualToString:@"-1"] || [cleanId isEqualToString:@"0"]) return NO;
if ([cleanId isEqualToString:self.selfUserId] || [cleanId hasPrefix:@"@TGS#"]) return NO;
NSString *cleanName = ACSafeStr(name);
NSString *cleanGid = ACSafeStr(gid);
NSString *cleanRole = ACSafeStr(role);
@synchronized (self) {
ACContactItem *existing = self.groupMemberMap[cleanId];
if (existing) {
if (cleanName.length > 0 && ![cleanName isEqualToString:cleanId] && ([existing.name isEqualToString:cleanId] || [existing.name hasPrefix:@"群友_"])) {
existing.name = cleanName;
}
if (cleanGid.length > 0) existing.fromGroupId = cleanGid;
if (cleanRole.length > 0) existing.roleDesc = cleanRole;
existing.chatMeType = chatMeType;
return NO;
}
ACContactItem *item = [[ACContactItem alloc] init];
item.targetId = cleanId;
item.name = cleanName.length > 0 ? cleanName : [NSString stringWithFormat:@"群友_%@", [cleanId substringFromIndex:MAX(0, (int)cleanId.length - 4)]];
item.fromGroupId = cleanGid;
item.roleDesc = cleanRole.length > 0 ? cleanRole : @"群成员";
item.sourceType = 1;
item.chatMeType = chatMeType;
item.isSelected = NO;
self.groupMemberMap[cleanId] = item;
if (chatMeType == 0) {
[self.groupMemberList insertObject:item atIndex:0];
} else {
[self.groupMemberList addObject:item];
}
return YES;
}
}
- (void)addGroupWithId:(NSString *)gid name:(NSString *)name ban:(BOOL)ban {
NSString *cleanId = [ACSafeStr(gid) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
if (cleanId.length < 3 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"<null>"] || [cleanId isEqualToString:@"0"]) return;
if (![cleanId hasPrefix:@"@TGS#"] && cleanId.length > 15) return;
NSString *cleanName = ACSafeStr(name);
@synchronized (self) {
self.groupBanStatusMap[cleanId] = @(ban);
ACContactItem *existing = self.groupMap[cleanId];
if (existing) {
if (cleanName.length > 0 && ![cleanName isEqualToString:cleanId] && [existing.name hasPrefix:@"群聊"]) {
existing.name = cleanName;
}
return;
}
ACContactItem *item = [[ACContactItem alloc] init];
item.targetId = cleanId;
item.name = cleanName.length > 0 ? cleanName : [NSString stringWithFormat:@"群聊 (%@)", cleanId];
item.sourceType = 2;
item.roleDesc = ban ? @"🔒 [禁言群]" : @"🟢 [开放群]";
item.chatMeType = 0;
item.isSelected = NO;
self.groupMap[cleanId] = item;
[self.groupList addObject:item];
}
}
- (void)parseJSONWithContext:(id)jsonObj {
if (!jsonObj || [jsonObj isKindOfClass:[NSNull class]]) return;
@try {
NSDictionary *dict = ACSafeDict(jsonObj);
if (dict) {
if (dict[@"appUserExperienceList"] || dict[@"realityValue"]) return;
NSString *objStr = ACSafeStr(dict[@"objectId"]);
if ([objStr hasPrefix:@"会话："] && objStr.length > 3) {
__currentChatPeerId = [objStr substringFromIndex:3];
}
// 如果抓到用户自己的动态记录且包含 mediaList，自动更新捕获的动态图片模板
NSArray *mList = ACSafeArray(dict[@"mediaList"]);
if (mList && mList.count > 0 && dict[@"contentText"] && dict[@"commentPermission"]) {
self.latestCapturedMomentMediaList = mList;
}
NSString *cNick = ACSafeStr(dict[@"clientUserNickName"]);
NSString *cId = ACSafeStr(dict[@"id"]);
NSString *cmStr = ACSafeStr(dict[@"chatMeType"]);
if (cNick.length > 0 && cId.length >= 5 && cmStr.length > 0 && ![cId isEqualToString:self.selfUserId]) {
NSInteger cmType = [cmStr integerValue];
[self addFriendWithId:cId name:cNick tag:(cmType == 0 ? @"开放私聊(必达)" : @"限制非好友(chatMe=1)") chatMeType:cmType];
if (self.groupMemberMap[cId]) {
self.groupMemberMap[cId].chatMeType = cmType;
self.groupMemberMap[cId].name = cNick;
}
}
NSDictionary *customDict = ACSafeDict(dict[@"cloudCustomData"]);
if (customDict) {
NSString *v2Token = ACSafeStr(customDict[@"client_typeV2"]);
if (v2Token.length > 10) {
self.capturedClientTypeV2 = v2Token;
}
}
NSString *directId = ACSafeStr(dict[@"id"]);
if ([directId hasPrefix:@"@TGS#"] && ACSafeStr(dict[@"name"]).length > 0) {
BOOL isBan = [ACSafeStr(dict[@"ban"]) isEqualToString:@"true"];
[self addGroupWithId:directId name:ACSafeStr(dict[@"name"]) ban:isBan];
NSString *ownerId = ACSafeStr(dict[@"owner"]);
if (ownerId.length >= 5) {
[self addGroupMemberWithId:ownerId name:@"群主" groupId:directId role:@"群主" chatMeType:0];
}
}
NSString *groupId = ACSafeStr(dict[@"groupId"]);
if ([groupId hasPrefix:@"@TGS#"]) {
BOOL isBan = [ACSafeStr(dict[@"ban"]) isEqualToString:@"true"];
[self addGroupWithId:groupId name:ACSafeStr(dict[@"groupName"]) ban:isBan];
NSDictionary *uInfo = ACSafeDict(dict[@"userInfo"]);
NSString *uid = ACSafeStr(dict[@"userId"]);
if (uid.length >= 5 && uInfo) {
NSInteger cmType = [ACSafeStr(uInfo[@"chatMeType"]) integerValue];
NSString *uNick = ACSafeStr(uInfo[@"clientUserNickName"]);
if (uNick.length == 0) uNick = ACSafeStr(dict[@"customName"]);
NSString *uRole = ACSafeStr(dict[@"customName"]);
if (uRole.length == 0) uRole = ACSafeStr(dict[@"role"]);
[self addGroupMemberWithId:uid name:uNick groupId:groupId role:(uRole.length > 0 ? uRole : @"群管") chatMeType:cmType];
}
NSDictionary *appUInfo = ACSafeDict(dict[@"appUserInfo"]);
NSString *createUser = ACSafeStr(dict[@"createUser"]);
if (createUser.length >= 5 && appUInfo) {
NSInteger cmType = [ACSafeStr(appUInfo[@"chatMeType"]) integerValue];
NSString *targetUid = ACSafeStr(appUInfo[@"id"]);
if (targetUid.length == 0) targetUid = createUser;
[self addGroupMemberWithId:targetUid name:ACSafeStr(appUInfo[@"clientUserNickName"]) groupId:groupId role:@"群活跃" chatMeType:cmType];
}
}
NSString *friendIdStr = ACSafeStr(dict[@"friendId"]);
if (friendIdStr.length >= 5) {
NSString *remark = ACSafeStr(dict[@"remark"]);
NSString *nick = ACSafeStr(dict[@"nickname"]);
NSDictionary *appU = ACSafeDict(dict[@"appUserInfo"]);
if (nick.length == 0 && appU) {
nick = ACSafeStr(appU[@"clientUserNickName"]);
}
BOOL isMutual = [ACSafeStr(dict[@"mutual"]) isEqualToString:@"true"];
NSInteger cmType = 0;
if (!isMutual && appU && ACSafeStr(appU[@"chatMeType"]).length > 0) {
cmType = [ACSafeStr(appU[@"chatMeType"]) integerValue];
}
NSString *finalName = (remark.length > 0) ? [NSString stringWithFormat:@"%@ (%@)", remark, nick] : nick;
[self addFriendWithId:friendIdStr name:finalName tag:(isMutual ? @"双向好友(必达)" : @"单向好友") chatMeType:cmType];
}
for (id key in dict) {
id val = dict[key];
if ([val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSArray class]]) {
[self parseJSONWithContext:val];
}
}
return;
}
NSArray *arr = ACSafeArray(jsonObj);
if (arr) {
for (id sub in arr) {
[self parseJSONWithContext:sub];
}
}
} @catch (NSException *e) {}
}
#pragma mark - 2.3 群成员拉取
- (void)crawlGroupMembersPageForGroup:(NSString *)gid
nextSeq:(uint64_t)seq
pageIndex:(NSInteger)pageIdx
progress:(void(^)( NSString *msg))progressBlock
completion:(void(^)(void))completion {
@try {
Class v2Cls = NSClassFromString(@"V2TIMManager");
if (!v2Cls || ![v2Cls respondsToSelector:@selector(sharedInstance)]) {
if (completion) completion();
return;
}
id mgr = ((id (*)(id, SEL))objc_msgSend)(v2Cls, @selector(sharedInstance));
SEL getMemSel = NSSelectorFromString(@"getGroupMemberList:filter:nextSeq:succ:fail:");
if (![mgr respondsToSelector:getMemSel]) {
if (completion) completion();
return;
}
__weak typeof(self) weakSelf = self;
void (^succBlock)(uint64_t, NSArray *) = ^(uint64_t nextSeq, NSArray *memberList) {
NSArray *safeList = ACSafeArray(memberList);
if (safeList) {
for (id mem in safeList) {
@try {
if (!mem || [mem isKindOfClass:[NSNull class]]) continue;
NSString *uid = ACSafeStr([mem valueForKey:@"userID"]);
NSString *nick = ACSafeStr([mem valueForKey:@"nickName"]);
if (nick.length == 0) nick = ACSafeStr([mem valueForKey:@"nameCard"]);
if (nick.length == 0) nick = ACSafeStr([mem valueForKey:@"friendRemark"]);
[weakSelf addGroupMemberWithId:uid name:nick groupId:gid role:@"群成员" chatMeType:0];
} @catch (NSException *e) {}
}
}
dispatch_async(dispatch_get_main_queue(), ^{
if (progressBlock) {
progressBlock([NSString stringWithFormat:@"⏳ 正在采集(第%ld页)：已获 %lu 人...",
(long)(pageIdx + 1), (unsigned long)weakSelf.groupMemberList.count]);
}
});
if (pageIdx % 5 == 0) [weakSelf saveLocalPermanentCache];
if (nextSeq != 0 && nextSeq != seq && safeList.count > 0 && pageIdx < 800) {
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
[weakSelf crawlGroupMembersPageForGroup:gid nextSeq:nextSeq pageIndex:pageIdx + 1 progress:progressBlock completion:completion];
});
} else {
if (completion) completion();
}
};
void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) { if (completion) completion(); };
NSMethodSignature *sig = [mgr methodSignatureForSelector:getMemSel];
NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
[inv setTarget:mgr];
[inv setSelector:getMemSel];
uint32_t filter = 0;
uint64_t currentSeq = seq;
[inv setArgument:&gid atIndex:2];
[inv setArgument:&filter atIndex:3];
[inv setArgument:&currentSeq atIndex:4];
[inv setArgument:&succBlock atIndex:5];
[inv setArgument:&failBlock atIndex:6];
[inv invoke];
} @catch (NSException *e) {
if (completion) completion();
}
}
- (void)crawlGroupHistoryMessages:(NSString *)gid
lastMsg:(id)lastMsg
pageIndex:(NSInteger)pageIdx
completion:(void(^)(void))completion {
@try {
Class v2Cls = NSClassFromString(@"V2TIMManager");
if (!v2Cls || ![v2Cls respondsToSelector:@selector(sharedInstance)]) {
if (completion) completion();
return;
}
id mgr = ((id (*)(id, SEL))objc_msgSend)(v2Cls, @selector(sharedInstance));
SEL getHistSel = NSSelectorFromString(@"getGroupHistoryMessageList:count:lastMsg:succ:fail:");
if (![mgr respondsToSelector:getHistSel]) {
if (completion) completion();
return;
}
__weak typeof(self) weakSelf = self;
void (^succBlock)(NSArray *) = ^(NSArray *msgs) {
NSArray *safeMsgs = ACSafeArray(msgs);
if (!safeMsgs || safeMsgs.count == 0) {
if (completion) completion();
return;
}
for (id msg in safeMsgs) {
@try {
if (!msg || [msg isKindOfClass:[NSNull class]]) continue;
NSString *sender = ACSafeStr([msg valueForKey:@"sender"]);
NSString *nick = ACSafeStr([msg valueForKey:@"nickName"]);
if (nick.length == 0) nick = ACSafeStr([msg valueForKey:@"nameCard"]);
[weakSelf addGroupMemberWithId:sender name:nick groupId:gid role:@"群发言" chatMeType:0];
} @catch (NSException *e) {}
}
if (safeMsgs.count >= 50 && pageIdx < 25) {
id oldestMsg = [safeMsgs lastObject];
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
[weakSelf crawlGroupHistoryMessages:gid lastMsg:oldestMsg pageIndex:pageIdx + 1 completion:completion];
});
} else {
if (completion) completion();
}
};
void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) { if (completion) completion(); };
NSMethodSignature *sig = [mgr methodSignatureForSelector:getHistSel];
NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
[inv setTarget:mgr];
[inv setSelector:getHistSel];
int count = 100;
id lastM = lastMsg;
[inv setArgument:&gid atIndex:2];
[inv setArgument:&count atIndex:3];
[inv setArgument:&lastM atIndex:4];
[inv setArgument:&succBlock atIndex:5];
[inv setArgument:&failBlock atIndex:6];
[inv invoke];
} @catch (NSException *e) {
if (completion) completion();
}
}
- (void)scanLocalDatabasesAsyncWithCompletion:(void(^)(void))doneBlock {
dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
@try {
NSString *home = NSHomeDirectory();
NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:home];
NSString *relPath;
while ((relPath = [enumerator nextObject])) {
NSString *lower = relPath.lowercaseString;
if ([lower containsString:@"ranking"]) continue;
if ([lower hasSuffix:@".db"] || [lower hasSuffix:@".sqlite"] || [lower hasSuffix:@".sqlite3"]) {
NSString *fullPath = [home stringByAppendingPathComponent:relPath];
sqlite3 *db = NULL;
if (sqlite3_open_v2([fullPath UTF8String], &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
sqlite3_stmt *tableStmt = NULL;
if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table';", -1, &tableStmt, NULL) == SQLITE_OK) {
NSMutableArray<NSString *> *tables = [NSMutableArray array];
while (sqlite3_step(tableStmt) == SQLITE_ROW) {
const char *tName = (const char *)sqlite3_column_text(tableStmt, 0);
if (tName) [tables addObject:[NSString stringWithUTF8String:tName]];
}
sqlite3_finalize(tableStmt);
for (NSString *t in tables) {
NSString *sql = [NSString stringWithFormat:@"SELECT * FROM \"%@\" LIMIT 10000;", t];
sqlite3_stmt *rowStmt = NULL;
if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &rowStmt, NULL) == SQLITE_OK) {
int colCount = sqlite3_column_count(rowStmt);
while (sqlite3_step(rowStmt) == SQLITE_ROW) {
for (int c = 0; c < colCount; c++) {
const char *colText = (const char *)sqlite3_column_text(rowStmt, c);
if (!colText) continue;
NSString *v = [NSString stringWithUTF8String:colText];
if ([v hasPrefix:@"{"] || [v hasPrefix:@"["]) {
NSData *d = [v dataUsingEncoding:NSUTF8StringEncoding];
id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
if (j) [self parseJSONWithContext:j];
}
}
}
sqlite3_finalize(rowStmt);
}
}
}
sqlite3_close(db);
}
}
}
} @catch (NSException *e) {}
dispatch_async(dispatch_get_main_queue(), ^{
if (doneBlock) doneBlock();
});
});
}
- (void)reloadSelectedGroupsData:(NSArray<NSString *> *)targetGroupIds
progress:(void(^)(NSString *progressMsg))progressBlock
completion:(void(^)(NSString *finalMsg))completion {
[self setupIMGroupWelcomeListener];
if (!targetGroupIds || targetGroupIds.count == 0) {
if (completion) completion(@"❌ 请先在「群聊」面板勾选要采集的指定群聊！");
return;
}
dispatch_group_t memberCrawlGroup = dispatch_group_create();
for (NSString *gid in targetGroupIds) {
if (![gid hasPrefix:@"@TGS#"]) continue;
dispatch_group_enter(memberCrawlGroup);
[self crawlGroupMembersPageForGroup:gid nextSeq:0 pageIndex:0 progress:progressBlock completion:^{
dispatch_group_leave(memberCrawlGroup);
}];
dispatch_group_enter(memberCrawlGroup);
[self crawlGroupHistoryMessages:gid lastMsg:nil pageIndex:0 completion:^{
dispatch_group_leave(memberCrawlGroup);
}];
}
dispatch_group_notify(memberCrawlGroup, dispatch_get_main_queue(), ^{
[self saveLocalPermanentCache];
[self saveAllCustomSettings];
NSString *finalStr = [NSString stringWithFormat:@"✅ 指定群采集完成：当前共有 %lu 个群成员", (unsigned long)self.groupMemberList.count];
if (completion) completion(finalStr);
});
}
- (void)reloadAllDataWithProgress:(void(^)(NSString *progressMsg))progressBlock
completion:(void(^)(NSString *finalMsg))completion {
[self setupIMGroupWelcomeListener];
[self scanLocalDatabasesAsyncWithCompletion:^{
Class v2Cls = NSClassFromString(@"V2TIMManager");
if (!v2Cls || ![v2Cls respondsToSelector:@selector(sharedInstance)]) {
[self saveLocalPermanentCache];
if (completion) completion(@"IM未就绪，已加载本地永久缓存");
return;
}
id mgr = ((id (*)(id, SEL))objc_msgSend)(v2Cls, @selector(sharedInstance));
dispatch_group_t baseGroup = dispatch_group_create();
SEL getGroupsSel = NSSelectorFromString(@"getJoinedGroupList:fail:");
if ([mgr respondsToSelector:getGroupsSel]) {
dispatch_group_enter(baseGroup);
void (^succBlock)(NSArray *) = ^(NSArray *groupInfos) {
NSArray *safeGroups = ACSafeArray(groupInfos);
if (safeGroups) {
for (id gInfo in safeGroups) {
@try {
if (!gInfo || [gInfo isKindOfClass:[NSNull class]]) continue;
NSString *gid = ACSafeStr([gInfo valueForKey:@"groupID"]);
NSString *gName = ACSafeStr([gInfo valueForKey:@"groupName"]);
[self addGroupWithId:gid name:gName ban:NO];
} @catch (NSException *e) {}
}
}
dispatch_group_leave(baseGroup);
};
void (^failBlock)(int, NSString *) = ^(int code,  NSString *desc) { dispatch_group_leave(baseGroup); };
((void (*)(id, SEL, id, id))objc_msgSend)(mgr, getGroupsSel, succBlock, failBlock);
}
dispatch_group_notify(baseGroup, dispatch_get_main_queue(), ^{
NSArray<ACContactItem *> *allGroups = [self.groupList copy];
if (allGroups.count == 0) {
[self saveLocalPermanentCache];
if (completion) completion([NSString stringWithFormat:@"已就绪：%lu 好友 | %lu 群员 | %lu 群聊",
(unsigned long)self.friendList.count,
(unsigned long)self.groupMemberList.count,
(unsigned long)self.groupList.count]);
return;
}
dispatch_group_t memberCrawlGroup = dispatch_group_create();
for (ACContactItem *grp in allGroups) {
NSString *gid = grp.targetId;
if (![gid hasPrefix:@"@TGS#"]) continue;
dispatch_group_enter(memberCrawlGroup);
[self crawlGroupMembersPageForGroup:gid nextSeq:0 pageIndex:0 progress:progressBlock completion:^{
dispatch_group_leave(memberCrawlGroup);
}];
dispatch_group_enter(memberCrawlGroup);
[self crawlGroupHistoryMessages:gid lastMsg:nil pageIndex:0 completion:^{
dispatch_group_leave(memberCrawlGroup);
}];
}
dispatch_group_notify(memberCrawlGroup, dispatch_get_main_queue(), ^{
[self saveLocalPermanentCache];
[self saveAllCustomSettings];
NSString *finalStr = [NSString stringWithFormat:@"✅ 已永久保存：%lu 好友 | %lu 群员 | %lu 群聊",
(unsigned long)self.friendList.count,
(unsigned long)self.groupMemberList.count,
(unsigned long)self.groupList.count];
if (completion) completion(finalStr);
});
});
}];
}
#pragma mark - 3. 防封号文本动态混淆包装
- (NSString *)obfuscateMessageText:(NSString *)originalText {
if (!originalText || originalText.length == 0) return @"";
NSArray *tails = @[@"~", @" ✨", @" 👍", @" 😊", @" ~", @" 💡"];
NSString *randomTail = tails[arc4random_uniform((uint32_t)tails.count)];
return [originalText stringByAppendingString:randomTail];
}
#pragma mark - 4. 支持「四槽位独立图片 / 独立视频 / 文本」破盾发送引擎
- (void)ac_applyCapturedHeadersToRequest:(NSMutableURLRequest *)req {
if (!req) return;
[self.latestHTTPHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
if (![k isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSString class]]) return;
NSString *lk = k.lowercaseString;
// 修复：重放抓包 Header 时不能带上一次的 Content-Length / Host / Connection / Accept-Encoding
if ([lk isEqualToString:@"content-length"] || [lk isEqualToString:@"host"] ||
[lk isEqualToString:@"connection"] || [lk isEqualToString:@"accept-encoding"] ||
[lk isEqualToString:@"content-type"] || [lk isEqualToString:@"accept"] ||
[lk isEqualToString:@"user-agent"]) return;
[req setValue:v forHTTPHeaderField:k];
}];
}
- (void)callAirChatBackendAddFriendAndUnlock:(NSString *)targetUserId completion:(void(^)(void))completion {
if (!targetUserId || targetUserId.length == 0 || ACHeaderValue(self.latestHTTPHeaders, @"token").length == 0) {
if (completion) completion();
return;
}
@try {
dispatch_group_t apiGroup = dispatch_group_create();
dispatch_group_enter(apiGroup);
NSMutableURLRequest *req1 = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://apiv1.airchat.cc/client/biz/userfriends/add"]];
req1.HTTPMethod = @"POST";
[self ac_applyCapturedHeadersToRequest:req1];
[req1 setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
req1.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"friendId": targetUserId} options:0 error:nil];
[[[NSURLSession sharedSession] dataTaskWithRequest:req1 completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
dispatch_group_leave(apiGroup);
}] resume];
dispatch_group_enter(apiGroup);
NSMutableURLRequest *req2 = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://apiv1.airchat.cc/client/biz/useronechat/add"]];
req2.HTTPMethod = @"POST";
[self ac_applyCapturedHeadersToRequest:req2];
[req2 setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
req2.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"chatWithHimId": targetUserId, @"id": targetUserId, @"userId": self.selfUserId ?: @""} options:0 error:nil];
[[[NSURLSession sharedSession] dataTaskWithRequest:req2 completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
dispatch_group_leave(apiGroup);
}] resume];
dispatch_group_notify(apiGroup, dispatch_get_main_queue(), ^{
if (completion) completion();
});
} @catch (NSException *e) {
if (completion) completion();
}
}
- (void)simulateIncomingMessageFrom:(NSString *)targetUserId completion:(void(^)(void))completion {
@try {
Class v2MgrCls = NSClassFromString(@"V2TIMManager");
if (v2MgrCls && [v2MgrCls respondsToSelector:@selector(sharedInstance)]) {
id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));
SEL createTextSel = NSSelectorFromString(@"createTextMessage:");
SEL insertSel = NSSelectorFromString(@"insertC2CMessageToLocalStorage:to:sender:succ:fail:");
if ([manager respondsToSelector:createTextSel] && [manager respondsToSelector:insertSel]) {
id fakeMsg = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createTextSel, @"👋");
NSString *myId = self.selfUserId ?: @"";
void (^succ)(void) = ^{ if (completion) dispatch_async(dispatch_get_main_queue(), completion); };
void (^fail)(int, NSString *) = ^(int c,  NSString *d) { if (completion) dispatch_async(dispatch_get_main_queue(), completion); };
((void (*)(id, SEL, id, id, id, id, id))objc_msgSend)(manager, insertSel, fakeMsg, myId, targetUserId, succ, fail);
return;
}
}
} @catch (NSException *e) {}
if (completion) completion();
}
- (void)autoAddIMFriend:(NSString *)userId completion:(void(^)(void))completion {
@try {
Class v2MgrCls = NSClassFromString(@"V2TIMManager");
Class reqCls = NSClassFromString(@"V2TIMFriendAddApplication");
if (v2MgrCls && reqCls) {
id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));
SEL addFriendSel = NSSelectorFromString(@"addFriend:succ:fail:");
if ([manager respondsToSelector:addFriendSel]) {
id req = [[reqCls alloc] init];
[req setValue:userId forKey:@"userID"];
[req setValue:@"你好" forKey:@"addWording"];
[req setValue:@(2) forKey:@"addType"];
void (^succ)(id) = ^(id res) { if (completion) dispatch_async(dispatch_get_main_queue(), completion); };
void (^fail)(int, NSString *) = ^(int c,  NSString *d) { if (completion) dispatch_async(dispatch_get_main_queue(), completion); };
((void (*)(id, SEL, id, id, id))objc_msgSend)(manager, addFriendSel, req, succ, fail);
return;
}
}
} @catch (NSException *e) {}
if (completion) completion();
}
- (void)rawSendV2Message:(id)v2Msg toItem:(ACContactItem *)item completion:(void(^)(BOOL ok, int code, NSString *desc))completion {
@try {
Class v2MgrCls = NSClassFromString(@"V2TIMManager");
if (!v2MgrCls || !v2Msg) {
if (completion) completion(NO, -1, @"构造消息失败");
return;
}
id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));
if (!manager) {
if (completion) completion(NO, -1, @"IM未初始化");
return;
}
// cloudCustomData 为可选字段，任何异常都不能影响发送
@try {
if (self.capturedCloudCustomData) {
[v2Msg setValue:self.capturedCloudCustomData forKey:@"cloudCustomData"];
} else {
NSDictionary *nativeCustom = @{
@"client_typeV2": self.capturedClientTypeV2 ?: @"",
@"client_type": @"iOS"
};
NSData *customData = [NSJSONSerialization dataWithJSONObject:nativeCustom options:0 error:nil];
if (customData) [v2Msg setValue:customData forKey:@"cloudCustomData"];
}
} @catch (NSException *ignore) {}
BOOL isGroup = (item.sourceType == 2);
NSString *receiver = isGroup ? nil : item.targetId;
NSString *groupID = isGroup ? item.targetId : nil;
void (^succBlock)(void) = ^{
if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, 0, nil); });
};
void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) {
if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, code, desc); });
};
NSInteger priority = 1;
BOOL onlineOnly = NO;
id nilObj = nil;
SEL selA = NSSelectorFromString(@"sendMessage:receiver:groupID:priority:onlineUserOnly:offlinePushInfo:progress:succ:fail:");
SEL selB = NSSelectorFromString(@"sendMessage:to:priority:onlineUserOnly:offlinePushInfo:succ:fail:");
SEL selC = NSSelectorFromString(@"sendC2CMessage:to:succ:fail:");
SEL selD = NSSelectorFromString(@"sendGroupMessage:to:succ:fail:");
if ([manager respondsToSelector:selA]) {
((void (*)(id, SEL, id, id, id, NSInteger, BOOL, id, id, id, id))objc_msgSend)(manager, selA, v2Msg, receiver, groupID, priority, onlineOnly, nilObj, nilObj, succBlock, failBlock);
} else if (!isGroup && [manager respondsToSelector:selB]) {
((void (*)(id, SEL, id, id, NSInteger, BOOL, id, id, id))objc_msgSend)(manager, selB, v2Msg, receiver, priority, onlineOnly, nilObj, succBlock, failBlock);
} else if (!isGroup && [manager respondsToSelector:selC]) {
((void (*)(id, SEL, id, id, id, id))objc_msgSend)(manager, selC, v2Msg, receiver, succBlock, failBlock);
} else if (isGroup && [manager respondsToSelector:selD]) {
((void (*)(id, SEL, id, id, id, id))objc_msgSend)(manager, selD, v2Msg, groupID, succBlock, failBlock);
} else {
if (completion) completion(NO, -1, @"当前IM版本不支持该发送接口");
}
} @catch (NSException *e) {
if (completion) completion(NO, -1, @"发送异常");
}
}

// 按指定槽位发送（0:群发槽, 1:迎新槽, 2:自动回复槽）
- (void)sendText:(NSString *)text
mediaSlot:(ACMediaSlot)slot
attachMedia:(BOOL)attachMedia
toItem:(ACContactItem *)item
completion:(void(^)(BOOL ok, NSString *detail))completion {
NSInteger mType = attachMedia ? [self mediaTypeForSlot:slot] : 0;
NSString *mPath = (mType == 1) ? [self imagePathForSlot:slot] : ((mType == 2) ? [self videoPathForSlot:slot] : @"");
NSString *tPath = (mType == 2) ? [self videoThumbPathForSlot:slot] : @"";
int vDur = (mType == 2) ? [self videoDurationForSlot:slot] : 0;
[self sendText:text
customMediaType:mType
customMediaPath:mPath
customThumbPath:tPath
customVideoDuration:vDur
toItem:item
completion:completion];
}
// 底层通用媒体+文字发送实现
- (void)sendText:(NSString *)text
customMediaType:(NSInteger)mType
customMediaPath:(NSString *)mPath
customThumbPath:(NSString *)tPath
customVideoDuration:(int)vDur
toItem:(ACContactItem *)item
completion:(void(^)(BOOL ok,  NSString *detail))completion {
@try {
Class v2MgrCls = NSClassFromString(@"V2TIMManager");
if (!v2MgrCls || ![v2MgrCls respondsToSelector:@selector(sharedInstance)]) {
if (completion) completion(NO, @"IM未初始化");
return;
}
id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));
NSFileManager *fm = [NSFileManager defaultManager];
id v2MediaMsg = nil;
if (mType == 1 && mPath.length > 0 && [fm fileExistsAtPath:mPath]) {
SEL createImgSel = NSSelectorFromString(@"createImageMessage:");
if ([manager respondsToSelector:createImgSel]) {
v2MediaMsg = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createImgSel, mPath);
} else {
Class msgCls = NSClassFromString(@"V2TIMMessage");
if (msgCls && [msgCls respondsToSelector:createImgSel]) {
v2MediaMsg = ((id (*)(id, SEL, NSString *))objc_msgSend)(msgCls, createImgSel, mPath);
}
}
} else if (mType == 2 && mPath.length > 0 && [fm fileExistsAtPath:mPath]) {
SEL createVidSel = NSSelectorFromString(@"createVideoMessage:type:duration:snapshotPath:");
if ([manager respondsToSelector:createVidSel]) {
NSString *vType = @"mp4";
int dur = vDur > 0 ? vDur : 5;
NSString *sPath = (tPath.length > 0 && [fm fileExistsAtPath:tPath]) ? tPath : @"";
NSMethodSignature *sig = [manager methodSignatureForSelector:createVidSel];
NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
[inv setTarget:manager];
[inv setSelector:createVidSel];
[inv setArgument:&mPath atIndex:2];
[inv setArgument:&vType atIndex:3];
[inv setArgument:&dur atIndex:4];
[inv setArgument:&sPath atIndex:5];
[inv invoke];
__unsafe_unretained id tempVideoMsg = nil;
[inv getReturnValue:&tempVideoMsg];
v2MediaMsg = tempVideoMsg;
}
}
NSString *cleanText = [ACSafeStr(text) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
NSString *obfuscatedText = cleanText.length > 0 ? [self obfuscateMessageText:cleanText] : @"";
id v2TextMsg = nil;
if (obfuscatedText.length > 0) {
SEL createTextSel = NSSelectorFromString(@"createTextMessage:");
if ([manager respondsToSelector:createTextSel]) {
v2TextMsg = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createTextSel, obfuscatedText);
} else {
Class msgCls = NSClassFromString(@"V2TIMMessage");
if (msgCls && [msgCls respondsToSelector:createTextSel]) {
v2TextMsg = ((id (*)(id, SEL, NSString *))objc_msgSend)(msgCls, createTextSel, obfuscatedText);
}
}
}
id primaryMsg = v2MediaMsg ?: v2TextMsg;
if (!primaryMsg) {
if (completion) completion(NO, @"内容为空");
return;
}
[self rawSendV2Message:primaryMsg toItem:item completion:^(BOOL ok, int code, NSString *desc) {
if (ok) {
item.chatMeType = 0;
if (v2MediaMsg && v2TextMsg) {
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
[self rawSendV2Message:v2TextMsg toItem:item completion:^(BOOL okT, int cT, NSString *dT) {
if (completion) completion(YES, mType == 2 ? @"视频+文送达" : @"图+文送达");
}];
});
} else {
if (completion) completion(YES, v2MediaMsg ? (mType == 2 ? @"视频送达" : @"图片送达") : @"文本送达");
}
return;
}
if (item.sourceType != 2) {
item.chatMeType = 1;
[self callAirChatBackendAddFriendAndUnlock:item.targetId completion:^{
[self simulateIncomingMessageFrom:item.targetId completion:^{
[self autoAddIMFriend:item.targetId completion:^{
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
[self rawSendV2Message:primaryMsg toItem:item completion:^(BOOL ok2, int code2, NSString *desc2) {
if (ok2) {
if (v2MediaMsg && v2TextMsg) {
[self rawSendV2Message:v2TextMsg toItem:item completion:nil];
}
if (completion) completion(YES, @"破盾成功");
} else {
if (completion) completion(NO, @"(120001)已自动申请加好友");
}
}];
});
}];
}];
}];
} else {
if (completion) completion(NO, [NSString stringWithFormat:@"(%d)%@", code, desc ?: @"群禁言"]);
}
}];
} @catch (NSException *e) {
if (completion) completion(NO, @"发送异常");
}
}
@end
#pragma mark - 5. 转发/迎新/自动回复/定时动态 六合一主界面控制器（各面板媒体独立切换）
@interface ACForwardAssistantVC : UIViewController <UITableViewDelegate, UITableViewDataSource, UINavigationControllerDelegate, UIImagePickerControllerDelegate, UITextViewDelegate>
@property (nonatomic, strong) UIView *headerContainer;
@property (nonatomic, strong) UITextView *contentTextView;
@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, strong) UIButton *pickMediaBtn;
@property (nonatomic, strong) UIButton *clearMediaBtn;
@property (nonatomic, strong) UILabel *mediaBadgeLabel;
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, strong) UIView *actionBar;
@property (nonatomic, strong) UIView *welcomeControlBar;
@property (nonatomic, strong) UISwitch *welcomeSwitch;
@property (nonatomic, strong) UIView *autoReplyBar;
@property (nonatomic, strong) UISwitch *autoReplySwitch;
@property (nonatomic, strong) UIView *momentTaskBar;
@property (nonatomic, strong) UISwitch *momentSwitch;
@property (nonatomic, strong) UIButton *intervalBtn;
@property (nonatomic, strong) UIView *autoCommentBar;
@property (nonatomic, strong) UISwitch *autoCommentSwitch;
@property (nonatomic, strong) UITextField *autoCommentField;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIButton *floatingSendBtn;
@end
@implementation ACForwardAssistantVC
// 根据当前选中的 Tab 决定右上角图片/视频框操作的是哪一个独立媒体槽位
- (ACMediaSlot)currentActiveMediaSlot {
NSInteger idx = self.tabControl ? self.tabControl.selectedSegmentIndex : 0;
if (idx == 3) return ACMediaSlotWelcome;   // 🤖迎新专属图片/视频槽
if (idx == 4) return ACMediaSlotAutoReply; // 💬自动回复专属图片/视频槽
if (idx == 5) return ACMediaSlotMoment;    // 📝动态专属图片/视频槽
return ACMediaSlotBatchSend;               // 好友/群员/群聊 群发专属图片/视频槽
}
- (NSString *)slotNameForSlot:(ACMediaSlot)slot {
switch (slot) {
case ACMediaSlotWelcome:   return @"迎新专属";
case ACMediaSlotAutoReply: return @"回复专属";
case ACMediaSlotMoment:    return @"动态专属";
default:                   return @"群发专属";
}
}
- (void)viewDidLoad {
[super viewDidLoad];
@try {
self.title = @"全能助手 (四套媒体独立隔离)";
self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
self.edgesForExtendedLayout = UIRectEdgeNone;
self.extendedLayoutIncludesOpaqueBars = NO;
self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(dismissSelf)];
self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"全量刷新" style:UIBarButtonItemStyleDone target:self action:@selector(refreshData)];
[[ACForwardHelperManager shared] setupIMGroupWelcomeListener];
[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onStatusUpdateNotification) name:@"ACWelcomeStatusUpdated" object:nil];
[self setupCleanUI];
[self refreshMediaPreviewUI];
[self updateUI];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
if (mgr.friendList.count > 0 || mgr.groupMemberList.count > 0) {
self.statusLabel.text = [NSString stringWithFormat:@"📁 本地缓存：%lu 好友 | %lu 群员 | %lu 群聊 (各功能图片已独立)",
(unsigned long)mgr.friendList.count,
(unsigned long)mgr.groupMemberList.count,
(unsigned long)mgr.groupList.count];
} else {
[self refreshData];
}
} @catch (NSException *e) {}
}
- (void)dealloc {
[[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)onStatusUpdateNotification {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
NSInteger idx = self.tabControl.selectedSegmentIndex;
if (idx == 3) {
self.statusLabel.textColor = [UIColor systemGreenColor];
self.statusLabel.text = mgr.lastGreetLog;
} else if (idx == 4) {
self.statusLabel.textColor = [UIColor systemGreenColor];
self.statusLabel.text = mgr.lastAutoReplyLog;
} else if (idx == 5) {
self.statusLabel.textColor = [UIColor systemGreenColor];
self.statusLabel.text = mgr.lastMomentLog;
[self.tableView reloadData];
}
[self updateUI];
}
- (void)setupCleanUI {
CGFloat width = self.view.bounds.size.width;
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
self.headerContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 236)];
self.headerContainer.backgroundColor = [UIColor systemGroupedBackgroundColor];
[self.view addSubview:self.headerContainer];
CGFloat imgBoxW = 90.0;
self.contentTextView = [[UITextView alloc] initWithFrame:CGRectMake(16, 18, width - 32 - imgBoxW - 10, 84)];
self.contentTextView.font = [UIFont systemFontOfSize:14.5];
self.contentTextView.textContainerInset = UIEdgeInsetsMake(8, 6, 8, 6);
self.contentTextView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
self.contentTextView.layer.cornerRadius = 12;
self.contentTextView.layer.borderColor = [UIColor separatorColor].CGColor;
self.contentTextView.layer.borderWidth = 0.5;
self.contentTextView.delegate = self;
if (__pendingForwardText && __pendingForwardText.length > 0) {
self.contentTextView.text = __pendingForwardText;
} else {
self.contentTextView.text = @"您好，认识一下！";
}
[self.headerContainer addSubview:self.contentTextView];
self.previewImageView = [[UIImageView alloc] initWithFrame:CGRectMake(width - 16 - imgBoxW, 18, imgBoxW, 84)];
self.previewImageView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
self.previewImageView.layer.cornerRadius = 12;
self.previewImageView.layer.borderColor = [UIColor separatorColor].CGColor;
self.previewImageView.layer.borderWidth = 0.5;
self.previewImageView.contentMode = UIViewContentModeScaleAspectFill;
self.previewImageView.clipsToBounds = YES;
self.previewImageView.userInteractionEnabled = YES;
[self.headerContainer addSubview:self.previewImageView];
self.pickMediaBtn = [UIButton buttonWithType:UIButtonTypeSystem];
self.pickMediaBtn.frame = self.previewImageView.bounds;
self.pickMediaBtn.titleLabel.numberOfLines = 3;
self.pickMediaBtn.titleLabel.textAlignment = NSTextAlignmentCenter;
self.pickMediaBtn.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
[self.pickMediaBtn addTarget:self action:@selector(chooseMediaFromAlbum) forControlEvents:UIControlEventTouchUpInside];
[self.previewImageView addSubview:self.pickMediaBtn];
self.mediaBadgeLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 62, imgBoxW, 22)];
self.mediaBadgeLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
self.mediaBadgeLabel.textColor = [UIColor whiteColor];
self.mediaBadgeLabel.font = [UIFont boldSystemFontOfSize:9.5];
self.mediaBadgeLabel.textAlignment = NSTextAlignmentCenter;
self.mediaBadgeLabel.hidden = YES;
[self.previewImageView addSubview:self.mediaBadgeLabel];
self.clearMediaBtn = [UIButton buttonWithType:UIButtonTypeCustom];
self.clearMediaBtn.frame = CGRectMake(imgBoxW - 24, 2, 22, 22);
self.clearMediaBtn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.65];
self.clearMediaBtn.layer.cornerRadius = 11;
[self.clearMediaBtn setTitle:@"✕" forState:UIControlStateNormal];
self.clearMediaBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
self.clearMediaBtn.hidden = YES;
[self.clearMediaBtn addTarget:self action:@selector(clearSelectedMedia) forControlEvents:UIControlEventTouchUpInside];
[self.previewImageView addSubview:self.clearMediaBtn];
self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"好友", @"群员", @"群聊", @"🤖迎新", @"💬回复", @"📝动态"]];
self.tabControl.frame = CGRectMake(12, 114, width - 24, 34);
self.tabControl.selectedSegmentIndex = 1;
[self.tabControl addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
[self.headerContainer addSubview:self.tabControl];
self.actionBar = [[UIView alloc] initWithFrame:CGRectMake(16, 158, width - 32, 34)];
NSArray *btnTitles = @[@"🟢只选必达", @"🗑️清群成员", @"🎯定向采集", @"清空已选"];
CGFloat btnW = (width - 32 - 24) / 4.0;
for (int i = 0; i < 4; i++) {
UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
btn.frame = CGRectMake(i * (btnW + 8), 0, btnW, 34);
[btn setTitle:btnTitles[i] forState:UIControlStateNormal];
btn.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
btn.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
btn.layer.cornerRadius = 8;
btn.tag = 600 + i;
[btn addTarget:self action:@selector(quickSelectAction:) forControlEvents:UIControlEventTouchUpInside];
[self.actionBar addSubview:btn];
}
[self.headerContainer addSubview:self.actionBar];
self.welcomeControlBar = [[UIView alloc] initWithFrame:CGRectMake(16, 156, width - 32, 38)];
self.welcomeControlBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
self.welcomeControlBar.layer.cornerRadius = 10;
self.welcomeControlBar.hidden = YES;
UILabel *wLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, width - 190, 38)];
wLabel.font = [UIFont boldSystemFontOfSize:12];
wLabel.text = @"🤖 迎新(独立图/视频 | 8-15s)";
[self.welcomeControlBar addSubview:wLabel];
UIButton *allWelcomeGrpBtn = [UIButton buttonWithType:UIButtonTypeSystem];
allWelcomeGrpBtn.frame = CGRectMake(width - 32 - 118, 5, 56, 28);
[allWelcomeGrpBtn setTitle:@"全选群" forState:UIControlStateNormal];
allWelcomeGrpBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
allWelcomeGrpBtn.backgroundColor = [UIColor systemGroupedBackgroundColor];
allWelcomeGrpBtn.layer.cornerRadius = 6;
[allWelcomeGrpBtn addTarget:self action:@selector(selectAllWelcomeGroups) forControlEvents:UIControlEventTouchUpInside];
[self.welcomeControlBar addSubview:allWelcomeGrpBtn];
self.welcomeSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(width - 32 - 56, 3.5, 51, 31)];
self.welcomeSwitch.on = mgr.autoWelcomeEnabled;
[self.welcomeSwitch addTarget:self action:@selector(welcomeSwitchChanged:) forControlEvents:UIControlEventValueChanged];
[self.welcomeControlBar addSubview:self.welcomeSwitch];
[self.headerContainer addSubview:self.welcomeControlBar];
self.autoReplyBar = [[UIView alloc] initWithFrame:CGRectMake(16, 156, width - 32, 38)];
self.autoReplyBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
self.autoReplyBar.layer.cornerRadius = 10;
self.autoReplyBar.hidden = YES;
UILabel *arLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, 145, 38)];
arLabel.font = [UIFont boldSystemFontOfSize:12];
arLabel.text = @"💬 自动回复(独立图/视频)";
[self.autoReplyBar addSubview:arLabel];
UIButton *addRuleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
addRuleBtn.frame = CGRectMake(width - 32 - 148, 5, 84, 28);
[addRuleBtn setTitle:@"➕添加规则" forState:UIControlStateNormal];
addRuleBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
addRuleBtn.backgroundColor = [UIColor systemBlueColor];
[addRuleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
addRuleBtn.layer.cornerRadius = 6;
[addRuleBtn addTarget:self action:@selector(addAutoReplyRuleFromInput) forControlEvents:UIControlEventTouchUpInside];
[self.autoReplyBar addSubview:addRuleBtn];
self.autoReplySwitch = [[UISwitch alloc] initWithFrame:CGRectMake(width - 32 - 56, 3.5, 51, 31)];
self.autoReplySwitch.on = mgr.autoReplyEnabled;
[self.autoReplySwitch addTarget:self action:@selector(autoReplySwitchChanged:) forControlEvents:UIControlEventValueChanged];
[self.autoReplyBar addSubview:self.autoReplySwitch];
[self.headerContainer addSubview:self.autoReplyBar];
self.momentTaskBar = [[UIView alloc] initWithFrame:CGRectMake(16, 156, width - 32, 38)];
self.momentTaskBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
self.momentTaskBar.layer.cornerRadius = 10;
self.momentTaskBar.hidden = YES;
self.intervalBtn = [UIButton buttonWithType:UIButtonTypeSystem];
self.intervalBtn.frame = CGRectMake(8, 5, 118, 28);
[self.intervalBtn setTitle:[NSString stringWithFormat:@"⏱间隔:%ld分钟", (long)mgr.momentIntervalMinutes] forState:UIControlStateNormal];
self.intervalBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
self.intervalBtn.backgroundColor = [UIColor systemGroupedBackgroundColor];
self.intervalBtn.layer.cornerRadius = 6;
[self.intervalBtn addTarget:self action:@selector(cycleMomentInterval) forControlEvents:UIControlEventTouchUpInside];
[self.momentTaskBar addSubview:self.intervalBtn];
UIButton *addMomentBtn = [UIButton buttonWithType:UIButtonTypeSystem];
addMomentBtn.frame = CGRectMake(width - 32 - 148, 5, 84, 28);
[addMomentBtn setTitle:@"➕添加任务" forState:UIControlStateNormal];
addMomentBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
addMomentBtn.backgroundColor = [UIColor systemBlueColor];
[addMomentBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
addMomentBtn.layer.cornerRadius = 6;
[addMomentBtn addTarget:self action:@selector(addMomentTaskFromInput) forControlEvents:UIControlEventTouchUpInside];
[self.momentTaskBar addSubview:addMomentBtn];
self.momentSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(width - 32 - 56, 3.5, 51, 31)];
self.momentSwitch.on = mgr.autoMomentEnabled;
[self.momentSwitch addTarget:self action:@selector(momentSwitchChanged:) forControlEvents:UIControlEventValueChanged];
[self.momentTaskBar addSubview:self.momentSwitch];
[self.headerContainer addSubview:self.momentTaskBar];
self.autoCommentBar = [[UIView alloc] initWithFrame:CGRectMake(16, 200, width - 32, 38)];
self.autoCommentBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
self.autoCommentBar.layer.cornerRadius = 10;
self.autoCommentBar.hidden = YES;
UILabel *acLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, 118, 38)];
acLabel.font = [UIFont boldSystemFontOfSize:11.5];
acLabel.text = @"💬 新动态自动评论";
[self.autoCommentBar addSubview:acLabel];
self.autoCommentField = [[UITextField alloc] initWithFrame:CGRectMake(126, 5, width - 32 - 126 - 64, 28)];
self.autoCommentField.borderStyle = UITextBorderStyleRoundedRect;
self.autoCommentField.font = [UIFont systemFontOfSize:11.5];
self.autoCommentField.placeholder = @"评论内容";
self.autoCommentField.text = mgr.autoCommentText ?: @"不错";
self.autoCommentField.clearButtonMode = UITextFieldViewModeWhileEditing;
[self.autoCommentField addTarget:self action:@selector(autoCommentFieldChanged:) forControlEvents:UIControlEventEditingDidEnd];
[self.autoCommentBar addSubview:self.autoCommentField];
self.autoCommentSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(width - 32 - 56, 3.5, 51, 31)];
self.autoCommentSwitch.transform = CGAffineTransformMakeScale(0.82, 0.82);
self.autoCommentSwitch.on = mgr.autoCommentEnabled;
[self.autoCommentSwitch addTarget:self action:@selector(autoCommentSwitchChanged:) forControlEvents:UIControlEventValueChanged];
[self.autoCommentBar addSubview:self.autoCommentSwitch];
[self.headerContainer addSubview:self.autoCommentBar];
self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 244, width - 32, 24)];
self.statusLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
self.statusLabel.textColor = [UIColor secondaryLabelColor];
self.statusLabel.textAlignment = NSTextAlignmentCenter;
self.statusLabel.adjustsFontSizeToFitWidth = YES;
[self.headerContainer addSubview:self.statusLabel];
self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
self.tableView.delegate = self;
self.tableView.dataSource = self;
self.tableView.rowHeight = 58.0;
self.tableView.contentInset = UIEdgeInsetsMake(4, 0, 100, 0);
[self.view addSubview:self.tableView];
[self setupFloatingButton];
}
// 刷新右上角预览框：每个面板只显示自己独立槽位的图片/视频
- (void)refreshMediaPreviewUI {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
ACMediaSlot slot = [self currentActiveMediaSlot];
NSString *slotTitle = [self slotNameForSlot:slot];
NSInteger mType = [mgr mediaTypeForSlot:slot];
UIImage *previewImg = [mgr previewImageForSlot:slot];
if (mType == 1 && previewImg) {
self.previewImageView.image = previewImg;
[self.pickMediaBtn setTitle:@"" forState:UIControlStateNormal];
self.clearMediaBtn.hidden = NO;
self.mediaBadgeLabel.hidden = NO;
self.mediaBadgeLabel.text = [NSString stringWithFormat:@"🖼️%@", slotTitle];
} else if (mType == 2 && previewImg) {
self.previewImageView.image = previewImg;
[self.pickMediaBtn setTitle:@"" forState:UIControlStateNormal];
self.clearMediaBtn.hidden = NO;
self.mediaBadgeLabel.hidden = NO;
self.mediaBadgeLabel.text = [NSString stringWithFormat:@"🎬%@(%ds)", slotTitle, [mgr videoDurationForSlot:slot]];
} else {
self.previewImageView.image = nil;
[self.pickMediaBtn setTitle:[NSString stringWithFormat:@"🖼️/🎬\n%@\n点此上传", slotTitle] forState:UIControlStateNormal];
self.clearMediaBtn.hidden = YES;
self.mediaBadgeLabel.hidden = YES;
}
}
- (void)viewDidLayoutSubviews {
[super viewDidLayoutSubviews];
CGFloat width = self.view.bounds.size.width;
CGFloat height = self.view.bounds.size.height;
CGFloat topOffset = self.view.safeAreaInsets.top;
CGFloat headerH = 276.0;
self.headerContainer.frame = CGRectMake(0, topOffset, width, headerH);
CGFloat tableY = topOffset + headerH;
self.tableView.frame = CGRectMake(0, tableY, width, height - tableY);
if (self.floatingSendBtn && self.floatingSendBtn.tag != 999) {
CGFloat btnW = 138.0;
CGFloat btnH = 50.0;
CGFloat x = width - btnW - 20.0;
CGFloat y = height - btnH - MAX(28.0, self.view.safeAreaInsets.bottom + 12.0);
self.floatingSendBtn.frame = CGRectMake(x, y, btnW, btnH);
}
[self.view bringSubviewToFront:self.headerContainer];
[self.view bringSubviewToFront:self.floatingSendBtn];
}
- (void)setupFloatingButton {
self.floatingSendBtn = [UIButton buttonWithType:UIButtonTypeCustom];
self.floatingSendBtn.backgroundColor = [UIColor systemBlueColor];
[self.floatingSendBtn setTitle:@"🚀 发送 (0)" forState:UIControlStateNormal];
[self.floatingSendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
self.floatingSendBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
self.floatingSendBtn.layer.cornerRadius = 25.0;
self.floatingSendBtn.layer.shadowColor = [UIColor blackColor].CGColor;
self.floatingSendBtn.layer.shadowOffset = CGSizeMake(0, 4);
self.floatingSendBtn.layer.shadowOpacity = 0.3;
self.floatingSendBtn.layer.shadowRadius = 8.0;
[self.floatingSendBtn addTarget:self action:@selector(startBatchSend) forControlEvents:UIControlEventTouchUpInside];
UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
[self.floatingSendBtn addGestureRecognizer:pan];
[self.view addSubview:self.floatingSendBtn];
}
- (void)handlePan:(UIPanGestureRecognizer * _Nonnull)pan {
UIView *btn = pan.view;
btn.tag = 999;
CGPoint translation = [pan translationInView:self.view];
btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
[pan setTranslation:CGPointZero inView:self.view];
}
- (void)textViewDidChange:(UITextView * _Nonnull)textView {
if (self.tabControl.selectedSegmentIndex == 3) {
[ACForwardHelperManager shared].welcomeMessageText = textView.text;
[[ACForwardHelperManager shared] saveAllCustomSettings];
}
}
#pragma mark - 5.1 迎新 / 自动回复 / 定时发动态 按钮事件
- (void)welcomeSwitchChanged:(UISwitch * _Nonnull)sw {
[self.view endEditing:YES];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
mgr.autoWelcomeEnabled = sw.isOn;
mgr.welcomeMessageText = self.contentTextView.text;
[mgr saveAllCustomSettings];
[mgr setupIMGroupWelcomeListener];
if (sw.isOn) {
NSInteger wType = [mgr mediaTypeForSlot:ACMediaSlotWelcome];
NSString *mediaTip = wType == 2 ? @"+迎新专属视频" : (wType == 1 ? @"+迎新专属图" : @"纯文本");
self.statusLabel.textColor = [UIColor systemGreenColor];
self.statusLabel.text = [NSString stringWithFormat:@"🟢 迎新已开启(8-15s|%@) | 监控 %lu 群", mediaTip, (unsigned long)mgr.welcomeGroupIds.count];
} else {
self.statusLabel.textColor = [UIColor secondaryLabelColor];
self.statusLabel.text = @"⚪ 迎新已关闭";
}
[self updateUI];
}
- (void)autoReplySwitchChanged:(UISwitch *)sw {
[self.view endEditing:YES];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
mgr.autoReplyEnabled = sw.isOn;
[mgr saveAllCustomSettings];
[mgr setupIMGroupWelcomeListener];
if (sw.isOn) {
self.statusLabel.textColor = [UIColor systemGreenColor];
self.statusLabel.text = [NSString stringWithFormat:@"🟢 自动回复已开启！共 %lu 条规则 (使用回复专属图/视频，不与群发互通)", (unsigned long)mgr.autoReplyRules.count];
} else {
self.statusLabel.textColor = [UIColor secondaryLabelColor];
self.statusLabel.text = @"⚪ 自动回复已关闭";
}
[self updateUI];
}
// 添加自动回复规则时，如果当前回复槽有选中的图片/视频，自动复制一份独立绑定给该条规则
- (void)addAutoReplyRuleFromInput {
[self.view endEditing:YES];
NSString *raw = [self.contentTextView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
if (raw.length == 0) {
self.statusLabel.textColor = [UIColor systemRedColor];
self.statusLabel.text = @"❌ 请先在上方输入框填写【关键词=回复内容】或【直接写回复内容】";
return;
}
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
ACAutoReplyRule *rule = [[ACAutoReplyRule alloc] init];
rule.ruleId = [[NSUUID UUID] UUIDString];
rule.attachMedia = YES;
rule.enabled = YES;
// 将当前回复槽（Slot 2）的媒体复制一份固化到这条规则专属文件中，这样后续换图也不会影响旧规则
NSInteger slotType = [mgr mediaTypeForSlot:ACMediaSlotAutoReply];
NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
NSFileManager *fm = [NSFileManager defaultManager];
if (slotType == 1) {
NSString *ruleImgPath = [docDir stringByAppendingPathComponent:[NSString stringWithFormat:@"AC_Rule_%@.jpg", rule.ruleId]];
if ([fm copyItemAtPath:[mgr imagePathForSlot:ACMediaSlotAutoReply] toPath:ruleImgPath error:nil]) {
rule.customMediaType = 1;
rule.customMediaPath = ruleImgPath;
}
} else if (slotType == 2) {
NSString *ruleVidPath = [docDir stringByAppendingPathComponent:[NSString stringWithFormat:@"AC_Rule_%@.mp4", rule.ruleId]];
NSString *ruleThumbPath = [docDir stringByAppendingPathComponent:[NSString stringWithFormat:@"AC_Rule_%@_thumb.jpg", rule.ruleId]];
if ([fm copyItemAtPath:[mgr videoPathForSlot:ACMediaSlotAutoReply] toPath:ruleVidPath error:nil]) {
[fm copyItemAtPath:[mgr videoThumbPathForSlot:ACMediaSlotAutoReply] toPath:ruleThumbPath error:nil];
rule.customMediaType = 2;
rule.customMediaPath = ruleVidPath;
rule.customThumbPath = ruleThumbPath;
rule.customVideoDuration = [mgr videoDurationForSlot:ACMediaSlotAutoReply];
}
}
NSRange eqRange = [raw rangeOfString:@"="];
if (eqRange.location == NSNotFound) eqRange = [raw rangeOfString:@"＝"];
if (eqRange.location != NSNotFound && eqRange.location > 0 && eqRange.location < raw.length - 1) {
rule.keyword = [[raw substringToIndex:eqRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
rule.replyText = [[raw substringFromIndex:eqRange.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
} else {
rule.keyword = @"*";
rule.replyText = raw;
}
[mgr.autoReplyRules insertObject:rule atIndex:0];
[mgr saveAllCustomSettings];
self.contentTextView.text = @"";
self.statusLabel.textColor = [UIColor systemGreenColor];
self.statusLabel.text = [NSString stringWithFormat:@"✅ 已添加自动回复规则（触发词:%@ | 专属媒体已独立绑定）", [rule.keyword isEqualToString:@"*"] ? @"任意消息" : rule.keyword];
[self updateUI];
[self.tableView reloadData];
}
- (void)momentSwitchChanged:(UISwitch *)sw {
[self.view endEditing:YES];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
mgr.autoMomentEnabled = sw.isOn;
[mgr saveAllCustomSettings];
[mgr restartMomentScheduler];
if (sw.isOn) {
self.statusLabel.textColor = [UIColor systemGreenColor];
self.statusLabel.text = [NSString stringWithFormat:@"🟢 定时发动态已开启！每 %ld 分钟自动轮播发送一条任务", (long)mgr.momentIntervalMinutes];
[mgr onMomentTimerTick];
} else {
self.statusLabel.textColor = [UIColor secondaryLabelColor];
self.statusLabel.text = @"⚪ 定时发动态已关闭";
}
[self updateUI];
}
- (void)autoCommentSwitchChanged:(UISwitch *)sw {
[self.view endEditing:YES];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
mgr.autoCommentEnabled = sw.isOn;
if (sw.isOn) {
// 重新播种：从此刻起出现的新动态才评论，不刷历史
mgr.autoCommentEnabledAt = [[NSDate date] timeIntervalSince1970];
mgr.autoCommentSeeded = NO;
[mgr.autoCommentSeenIds removeAllObjects];
self.statusLabel.textColor = [UIColor systemGreenColor];
self.statusLabel.text = @"🟢 自动评论已开启：别人发布新动态后会自动跟评";
ACLog(@"[自动评论] 用户开启，已重置播种时间");
} else {
self.statusLabel.textColor = [UIColor secondaryLabelColor];
self.statusLabel.text = @"⚪ 自动评论已关闭";
ACLog(@"[自动评论] 用户关闭");
}
[mgr saveAllCustomSettings];
[self updateUI];
}
- (void)autoCommentFieldChanged:(UITextField *)tf {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
NSString *txt = tf.text;
mgr.autoCommentText = txt.length > 0 ? txt : @"不错";
[mgr saveAllCustomSettings];
self.statusLabel.text = [NSString stringWithFormat:@"✅ 自动评论内容已保存：%@", mgr.autoCommentText];
}
- (void)cycleMomentInterval {
[self.view endEditing:YES];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⏱ 设置自动发动态间隔时长"
message:@"请输入每隔多少分钟自动发布一条动态（多条任务将按顺序轮播发布）"
preferredStyle:UIAlertControllerStyleAlert];
[alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
tf.placeholder = @"输入分钟数，如 30";
tf.keyboardType = UIKeyboardTypeNumberPad;
tf.text = [NSString stringWithFormat:@"%ld", (long)mgr.momentIntervalMinutes];
}];
[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
[alert addAction:[UIAlertAction actionWithTitle:@"保存生效" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
NSInteger mins = [alert.textFields.firstObject.text integerValue];
if (mins < 1) mins = 10;
mgr.momentIntervalMinutes = mins;
[mgr saveAllCustomSettings];
[mgr restartMomentScheduler];
[self.intervalBtn setTitle:[NSString stringWithFormat:@"⏱间隔:%ld分钟", (long)mins] forState:UIControlStateNormal];
self.statusLabel.textColor = [UIColor systemGreenColor];
self.statusLabel.text = [NSString stringWithFormat:@"✅ 已设置每 %ld 分钟自动发布一条动态任务", (long)mins];
}]];
[self presentViewController:alert animated:YES completion:nil];
}
- (void)addMomentTaskFromInput {
[self.view endEditing:YES];
NSString *raw = [self.contentTextView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
if (raw.length == 0) {
self.statusLabel.textColor = [UIColor systemRedColor];
self.statusLabel.text = @"❌ 请先在上方输入框填写要定时发布的动态文案！";
return;
}
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
ACMomentTaskItem *task = [[ACMomentTaskItem alloc] init];
task.taskId = [[NSUUID UUID] UUIDString];
task.contentText = raw;
task.capturedMediaList = mgr.latestCapturedMomentMediaList;
task.enabled = YES;
task.sentCount = 0;
task.lastSentTimeStr = @"待发布";
[mgr.momentTasks insertObject:task atIndex:0];
[mgr saveAllCustomSettings];
self.contentTextView.text = @"";
self.statusLabel.textColor = [UIColor systemGreenColor];
self.statusLabel.text = [NSString stringWithFormat:@"✅ 已添加第 %lu 条动态任务（点击任务右侧「立即发」可直接测试）", (unsigned long)mgr.momentTasks.count];
[self updateUI];
[self.tableView reloadData];
}
- (void)selectAllWelcomeGroups {
[self.view endEditing:YES];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
if (mgr.welcomeGroupIds.count < mgr.groupList.count) {
for (ACContactItem *g in mgr.groupList) {
[mgr.welcomeGroupIds addObject:g.targetId];
}
} else {
[mgr.welcomeGroupIds removeAllObjects];
}
[mgr saveAllCustomSettings];
[self updateUI];
[self.tableView reloadData];
}
- (void)chooseMediaFromAlbum {
[self.view endEditing:YES];
UIImagePickerController *picker = [[UIImagePickerController alloc] init];
picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
picker.mediaTypes = @[@"public.image", @"public.movie"];
picker.videoQuality = UIImagePickerControllerQualityTypeMedium;
picker.delegate = self;
[self presentViewController:picker animated:YES completion:nil];
}
// 选图或选视频时，严格保存到当前面板对应的独立槽位中，绝不串用！
- (void)imagePickerController:(UIImagePickerController * _Nonnull)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> * _Nonnull)info {
ACMediaSlot slot = [self currentActiveMediaSlot];
NSString *slotTitle = [self slotNameForSlot:slot];
NSString *mediaType = info[UIImagePickerControllerMediaType];
if ([mediaType isEqualToString:@"public.movie"]) {
NSURL *videoURL = info[UIImagePickerControllerMediaURL];
if (videoURL) {
[[ACForwardHelperManager shared] saveVideoAtURL:videoURL forSlot:slot];
self.statusLabel.textColor = [UIColor systemGreenColor];
self.statusLabel.text = [NSString stringWithFormat:@"🎬 已保存【%@】独立视频(%d秒)，与其他功能彻底隔离！", slotTitle, [[ACForwardHelperManager shared] videoDurationForSlot:slot]];
}
} else {
UIImage *img = info[UIImagePickerControllerOriginalImage];
if (img) {
[[ACForwardHelperManager shared] saveImage:img forSlot:slot];
self.statusLabel.textColor = [UIColor systemGreenColor];
self.statusLabel.text = [NSString stringWithFormat:@"🖼️ 已保存【%@】独立图片，与其他功能彻底隔离！", slotTitle];
}
}
[self refreshMediaPreviewUI];
[picker dismissViewControllerAnimated:YES completion:nil];
}
- (void)clearSelectedMedia {
ACMediaSlot slot = [self currentActiveMediaSlot];
[[ACForwardHelperManager shared] clearMediaForSlot:slot];
[self refreshMediaPreviewUI];
self.statusLabel.textColor = [UIColor secondaryLabelColor];
self.statusLabel.text = [NSString stringWithFormat:@"已清除【%@】的独立图片/视频", [self slotNameForSlot:slot]];
}
- (void)refreshData {
[self.view endEditing:YES];
self.statusLabel.textColor = [UIColor systemBlueColor];
self.statusLabel.text = @"⏳ 正在后台递归拉取...";
__weak typeof(self) weakSelf = self;
[[ACForwardHelperManager shared] reloadAllDataWithProgress:^(NSString *progressMsg) {
weakSelf.statusLabel.text = progressMsg;
[weakSelf updateUI];
[weakSelf.tableView reloadData];
} completion:^(NSString *finalMsg) {
weakSelf.statusLabel.textColor = [UIColor secondaryLabelColor];
weakSelf.statusLabel.text = finalMsg;
[weakSelf updateUI];
[weakSelf.tableView reloadData];
}];
}
- (NSArray<ACContactItem *> *)currentItems {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
if (self.tabControl.selectedSegmentIndex == 0) return mgr.friendList;
if (self.tabControl.selectedSegmentIndex == 1) return mgr.groupMemberList;
return mgr.groupList;
}
- (void)quickSelectAction:(UIButton * _Nonnull)sender {
[self.view endEditing:YES];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
if (sender.tag == 600) {
for (ACContactItem *i in [self currentItems]) {
i.isSelected = (i.chatMeType == 0);
}
} else if (sender.tag == 601) {
[mgr clearAllGroupMembersCache];
self.statusLabel.textColor = [UIColor systemOrangeColor];
self.statusLabel.text = @"🗑️ 已清空本地群成员缓存";
[self updateUI];
[self.tableView reloadData];
return;
} else if (sender.tag == 602) {
if (self.tabControl.selectedSegmentIndex == 2) {
NSMutableArray<NSString *> *selectedGids = [NSMutableArray array];
for (ACContactItem *g in mgr.groupList) {
if (g.isSelected) [selectedGids addObject:g.targetId];
}
if (selectedGids.count == 0) {
self.statusLabel.textColor = [UIColor systemRedColor];
self.statusLabel.text = @"❌ 请先在群聊列表中勾选要采集的群！";
return;
}
self.statusLabel.textColor = [UIColor systemBlueColor];
self.statusLabel.text = @"⏳ 正在定向采集勾选群的成员...";
__weak typeof(self) weakSelf = self;
[mgr reloadSelectedGroupsData:selectedGids progress:^(NSString *msg) {
weakSelf.statusLabel.text = msg;
[weakSelf updateUI];
[weakSelf.tableView reloadData];
} completion:^(NSString *finalMsg) {
weakSelf.statusLabel.textColor = [UIColor systemGreenColor];
weakSelf.statusLabel.text = finalMsg;
[weakSelf updateUI];
[weakSelf.tableView reloadData];
}];
return;
} else {
self.statusLabel.textColor = [UIColor systemRedColor];
self.statusLabel.text = @"💡 请先切换到【群聊】面板勾选群，再点定向采集！";
return;
}
} else if (sender.tag == 603) {
for (ACContactItem *i in mgr.friendList) i.isSelected = NO;
for (ACContactItem *i in mgr.groupMemberList) i.isSelected = NO;
for (ACContactItem *i in mgr.groupList) i.isSelected = NO;
}
[self updateUI];
[self.tableView reloadData];
}
// 切换面板时，右上角的图片/视频预览框同步切换为该面板自己的独立槽位
- (void)tabChanged {
[self.view endEditing:YES];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
NSInteger idx = self.tabControl.selectedSegmentIndex;
self.actionBar.hidden = (idx >= 3);
self.welcomeControlBar.hidden = (idx != 3);
self.autoReplyBar.hidden = (idx != 4);
self.momentTaskBar.hidden = (idx != 5);
self.autoCommentBar.hidden = (idx != 5);
self.floatingSendBtn.hidden = (idx >= 3);
[self refreshMediaPreviewUI];
if (idx == 3) {
self.contentTextView.text = mgr.welcomeMessageText ?: @"您好 {name}，欢迎进群！认识一下~";
self.statusLabel.textColor = mgr.autoWelcomeEnabled ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
self.statusLabel.text = [NSString stringWithFormat:@"%@ | 右上角为【迎新专属图/视频】，不与群发互通",
mgr.autoWelcomeEnabled ? @"🟢 8-15s迎新中" : @"⚪ 迎新未开启"];
} else if (idx == 4) {
self.contentTextView.text = @"价格=您好 {name}，具体介绍请看我发您的资料哦~";
self.statusLabel.textColor = mgr.autoReplyEnabled ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
self.statusLabel.text = @"💡 右上角选【回复专属图/视频】，点➕添加规则即绑定给该条规则";
} else if (idx == 5) {
self.contentTextView.text = @"✨欢迎各位新朋友，长期稳定靠谱，有问题随时咨询我❤️";
self.statusLabel.textColor = mgr.autoMomentEnabled ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
self.statusLabel.text = @"💡 输入动态文案点➕添加任务，点任务右侧「立即发」可马上发布测试";
} else {
self.statusLabel.textColor = [UIColor secondaryLabelColor];
self.statusLabel.text = @"💡 当前右上角为【群发专属图/视频】，仅用于勾选好友/群员群发";
}
[self updateUI];
[self.tableView reloadData];
}
- (void)updateUI {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
[self.tabControl setTitle:[NSString stringWithFormat:@"好友(%lu)", (unsigned long)mgr.friendList.count] forSegmentAtIndex:0];
[self.tabControl setTitle:[NSString stringWithFormat:@"群员(%lu)", (unsigned long)mgr.groupMemberList.count] forSegmentAtIndex:1];
[self.tabControl setTitle:[NSString stringWithFormat:@"群聊(%lu)", (unsigned long)mgr.groupList.count] forSegmentAtIndex:2];
[self.tabControl setTitle:[NSString stringWithFormat:@"🤖迎新(%@)", mgr.autoWelcomeEnabled ? @"开" : @"关"] forSegmentAtIndex:3];
[self.tabControl setTitle:[NSString stringWithFormat:@"💬回复(%@)", mgr.autoReplyEnabled ? @"开" : @"关"] forSegmentAtIndex:4];
[self.tabControl setTitle:[NSString stringWithFormat:@"📝动态(%@)", mgr.autoMomentEnabled ? @"开" : @"关"] forSegmentAtIndex:5];
NSInteger selCount = 0;
for (ACContactItem *i in mgr.friendList) if (i.isSelected) selCount++;
for (ACContactItem *i in mgr.groupMemberList) if (i.isSelected) selCount++;
for (ACContactItem *i in mgr.groupList) if (i.isSelected) selCount++;
[self.floatingSendBtn setTitle:[NSString stringWithFormat:@"🚀 发送 (%ld)", (long)selCount] forState:UIControlStateNormal];
}
#pragma mark - 5.2 列表数据源与交互
- (NSInteger)tableView:(UITableView * _Nonnull)tableView numberOfRowsInSection:(NSInteger)section {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
NSInteger idx = self.tabControl.selectedSegmentIndex;
if (idx == 4) return mgr.autoReplyRules.count;
if (idx == 5) return mgr.momentTasks.count;
return [self currentItems].count;
}
- (UITableViewCell * _Nonnull)tableView:(UITableView * _Nonnull)tableView cellForRowAtIndexPath:(NSIndexPath * _Nonnull)indexPath {
static NSString *cid = @"ACMultiFuncCell";
UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
if (!cell) {
cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
cell.textLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightMedium];
cell.detailTextLabel.font = [UIFont systemFontOfSize:11.5];
cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
}
cell.accessoryView = nil;
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
NSInteger idx = self.tabControl.selectedSegmentIndex;
if (idx == 4) {
ACAutoReplyRule *rule = mgr.autoReplyRules[indexPath.row];
BOOL isAll = (!rule.keyword || rule.keyword.length == 0 || [rule.keyword isEqualToString:@""]);
NSString *kwBadge = isAll ? @"🌟 [匹配任意来信]" : [NSString stringWithFormat:@"🔑 [含词: %@]", rule.keyword];
NSString *mediaDesc = @"默认带回复槽媒体";
if (rule.customMediaType == 1) mediaDesc = @"🖼️已绑独立专属图";
else if (rule.customMediaType == 2) mediaDesc = [NSString stringWithFormat:@"🎬已绑独立视频(%ds)", rule.customVideoDuration];
cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", kwBadge, rule.replyText];
cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ | %@ (点击开关，左滑删除)",
rule.enabled ? @"🟢启用中" : @"⚪已暂停", mediaDesc];
cell.accessoryType = rule.enabled ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
return cell;
}
if (idx == 5) {
ACMomentTaskItem *task = mgr.momentTasks[indexPath.row];
cell.textLabel.text = [NSString stringWithFormat:@"📝 [任务%ld] %@", (long)(indexPath.row + 1), task.contentText];
cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ | 已发 %ld 次 | 上次: %@ (左滑删除)",
task.enabled ? @"🟢参与轮播" : @"⚪暂停",
(long)task.sentCount,
task.lastSentTimeStr ?: @"待发布"];
UIButton *pubNowBtn = [UIButton buttonWithType:UIButtonTypeSystem];
pubNowBtn.frame = CGRectMake(0, 0, 58, 28);
[pubNowBtn setTitle:@"立即发" forState:UIControlStateNormal];
pubNowBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
pubNowBtn.backgroundColor = [UIColor systemGreenColor];
[pubNowBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
pubNowBtn.layer.cornerRadius = 6;
pubNowBtn.tag = indexPath.row;
[pubNowBtn addTarget:self action:@selector(publishSingleMomentTaskNow:) forControlEvents:UIControlEventTouchUpInside];
cell.accessoryView = pubNowBtn;
return cell;
}
ACContactItem *item = [self currentItems][indexPath.row];
if (idx == 3) {
BOOL isMonitored = [mgr.welcomeGroupIds containsObject:item.targetId];
cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", isMonitored ? @"📡 [监控迎新中]" : @"👥 [未监控]", item.name];
cell.detailTextLabel.text = [NSString stringWithFormat:@"群ID: %@ (点击切换是否监控新人进群)", item.targetId];
cell.accessoryType = isMonitored ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
return cell;
}
NSString *badge = @"";
if (item.sourceType == 2) {
BOOL banned = mgr.groupBanStatusMap[item.targetId].boolValue;
badge = banned ? @"🔒 [禁言群]" : @"🟢 [开放群]";
} else if (item.chatMeType == 0) {
badge = [NSString stringWithFormat:@"🟢 [%@]", item.roleDesc ?: @"可直聊"];
} else {
badge = @"🔒 [仅好友可聊]";
}
cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", badge, item.name];
cell.detailTextLabel.text = [NSString stringWithFormat:@"ID: %@ %@", item.targetId, item.fromGroupId.length > 0 ? [NSString stringWithFormat:@"| 群:%@", item.fromGroupId] : @""];
cell.accessoryType = item.isSelected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
return cell;
}
- (void)publishSingleMomentTaskNow:(UIButton *)sender {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
if (sender.tag < 0 || sender.tag >= mgr.momentTasks.count) return;
ACMomentTaskItem *task = mgr.momentTasks[sender.tag];
self.statusLabel.textColor = [UIColor systemBlueColor];
self.statusLabel.text = @"⏳ 正在立即发布该条动态任务...（若未捕获登录凭证最多等待20秒）";
__weak typeof(self) weakSelfVC = self;
[mgr publishMomentTask:task completion:^(BOOL ok, NSString *msg) {
weakSelfVC.statusLabel.textColor = ok ? [UIColor systemGreenColor] : [UIColor systemRedColor];
weakSelfVC.statusLabel.text = msg ?: (ok ? @"发布成功" : @"发布失败");
UIAlertController *a = [UIAlertController alertControllerWithTitle:(ok ? @"✅ 发布成功" : @"❌ 发布失败")
message:(msg ?: @"")
preferredStyle:UIAlertControllerStyleAlert];
[a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
[weakSelfVC presentViewController:a animated:YES completion:nil];
}];
}
- (void)tableView:(UITableView * _Nonnull)tableView didSelectRowAtIndexPath:(NSIndexPath * _Nonnull)indexPath {
[tableView deselectRowAtIndexPath:indexPath animated:YES];
[self.view endEditing:YES];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
NSInteger idx = self.tabControl.selectedSegmentIndex;
if (idx == 4) {
ACAutoReplyRule *rule = mgr.autoReplyRules[indexPath.row];
rule.enabled = !rule.enabled;
[mgr saveAllCustomSettings];
[tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
return;
}
if (idx == 5) {
ACMomentTaskItem *task = mgr.momentTasks[indexPath.row];
task.enabled = !task.enabled;
[mgr saveAllCustomSettings];
[tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
return;
}
ACContactItem *item = [self currentItems][indexPath.row];
if (idx == 3) {
if ([mgr.welcomeGroupIds containsObject:item.targetId]) {
[mgr.welcomeGroupIds removeObject:item.targetId];
} else {
[mgr.welcomeGroupIds addObject:item.targetId];
}
[mgr saveAllCustomSettings];
self.statusLabel.text = [NSString stringWithFormat:@"%@ | 已勾选监控 %lu 个群",
mgr.autoWelcomeEnabled ? @"🟢 迎新监听中" : @"⚪ 迎新未开启",
(unsigned long)mgr.welcomeGroupIds.count];
[tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
return;
}
item.isSelected = !item.isSelected;
[tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
[self updateUI];
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
NSInteger idx = self.tabControl.selectedSegmentIndex;
return (idx == 4 || idx == 5);
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
if (editingStyle == UITableViewCellEditingStyleDelete) {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
if (self.tabControl.selectedSegmentIndex == 4 && indexPath.row < mgr.autoReplyRules.count) {
ACAutoReplyRule *rule = mgr.autoReplyRules[indexPath.row];
if (rule.customMediaPath.length > 0) {
[[NSFileManager defaultManager] removeItemAtPath:rule.customMediaPath error:nil];
}
if (rule.customThumbPath.length > 0) {
[[NSFileManager defaultManager] removeItemAtPath:rule.customThumbPath error:nil];
}
[mgr.autoReplyRules removeObjectAtIndex:indexPath.row];
[mgr saveAllCustomSettings];
[tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
} else if (self.tabControl.selectedSegmentIndex == 5 && indexPath.row < mgr.momentTasks.count) {
[mgr.momentTasks removeObjectAtIndex:indexPath.row];
[mgr saveAllCustomSettings];
[tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}
}
}
// 群发严格只使用槽位0（ACMediaSlotBatchSend），绝不会用到自动回复或迎新的图片/视频
- (void)startBatchSend {
[self.view endEditing:YES];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
NSString *text = [self.contentTextView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
if (text.length == 0 && [mgr mediaTypeForSlot:ACMediaSlotBatchSend] == 0) {
self.statusLabel.textColor = [UIColor systemRedColor];
self.statusLabel.text = @"❌ 请输入群发文字，或上传【群发专属】图片/视频！";
return;
}
NSMutableArray<ACContactItem *> *targets = [NSMutableArray array];
for (ACContactItem *i in mgr.friendList) if (i.isSelected) [targets addObject:i];
for (ACContactItem *i in mgr.groupMemberList) if (i.isSelected) [targets addObject:i];
for (ACContactItem *i in mgr.groupList) if (i.isSelected) [targets addObject:i];
if (targets.count == 0) {
self.statusLabel.textColor = [UIColor systemRedColor];
self.statusLabel.text = @"❌ 请先勾选好友、群成员或群聊！";
return;
}
self.floatingSendBtn.enabled = NO;
__block NSInteger okCount = 0;
__block NSInteger failCount = 0;
__block NSString *lastFail = @"";
__block NSInteger idx = 0;
NSInteger total = targets.count;
__weak typeof(self) weakSelf = self;
__block void (^nextStep)(void) = ^{
if (idx >= total) {
weakSelf.floatingSendBtn.enabled = YES;
weakSelf.statusLabel.textColor = okCount > 0 ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
weakSelf.statusLabel.text = [NSString stringWithFormat:@"✅ 群发完成：成功送达 %ld | 受限已处理 %ld %@", (long)okCount, (long)failCount, lastFail];
[weakSelf.tableView reloadData];
return;
}
ACContactItem *cur = targets[idx];
weakSelf.statusLabel.textColor = [UIColor systemBlueColor];
weakSelf.statusLabel.text = [NSString stringWithFormat:@"⏳ 正在群发 (%ld/%ld): %@", (long)(idx + 1), (long)total, cur.name];
[[ACForwardHelperManager shared] sendText:text mediaSlot:ACMediaSlotBatchSend attachMedia:YES toItem:cur completion:^(BOOL ok, NSString *detail) {
if (ok) okCount++;
else { failCount++; lastFail = detail ?: @""; }
idx++;
NSTimeInterval randDelay = 3.5 + (arc4random_uniform(31) / 10.0);
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(randDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
nextStep();
});
}];
};
nextStep();
}
- (void)dismissSelf {
[self dismissViewControllerAnimated:YES completion:nil];
}
@end
#pragma mark - 6. 视图树提取工具
static UIImage *ACFindLargestImageInView(UIView *view) {
if (!view || view.hidden || view.alpha < 0.05) return nil;
UIImage *bestImg = nil;
CGFloat maxArea = 0;
if ([view isKindOfClass:[UIImageView class]]) {
UIImageView *iv = (UIImageView *)view;
if (iv.image && iv.bounds.size.width > 45 && iv.bounds.size.height > 45) {
bestImg = iv.image;
maxArea = iv.bounds.size.width * iv.bounds.size.height;
}
}
for (UIView *sub in view.subviews) {
UIImage *subImg = ACFindLargestImageInView(sub);
if (subImg && (sub.bounds.size.width * sub.bounds.size.height >= maxArea)) {
bestImg = subImg;
maxArea = sub.bounds.size.width * sub.bounds.size.height;
}
}
return bestImg;
}
static NSString *ACFindChatTextInView(UIView *view) {
if (!view || view.hidden) return nil;
if ([view isKindOfClass:[UITextView class]]) {
NSString *t = ((UITextView *)view).text;
if (t.length > 0) return t;
}
if ([view isKindOfClass:[UILabel class]]) {
NSString *t = ((UILabel *)view).text;
if (t.length > 0 && ![t hasSuffix:@"✓"] && t.length > 2) {
return t;
}
}
for (UIView *sub in view.subviews) {
NSString *subText = ACFindChatTextInView(sub);
if (subText.length > 0) return subText;
}
return nil;
}
static UITextView *ACFindInputTextViewInView(UIView *view) {
if (!view || view.hidden) return nil;
if ([view isKindOfClass:[UITextView class]] && view.frame.size.height >= 28 && view.frame.size.height <= 120) {
return (UITextView *)view;
}
for (UIView *sub in view.subviews) {
UITextView *found = ACFindInputTextViewInView(sub);
if (found) return found;
}
return nil;
}
static void ACPresentForwardAssistantFromTopVC(void) {
@try {
UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
if (!keyWin) {
for (UIWindow *w in [UIApplication sharedApplication].windows) {
if (w.isKeyWindow) { keyWin = w; break; }
}
}
UIViewController *topVC = keyWin.rootViewController;
while (topVC.presentedViewController) {
topVC = topVC.presentedViewController;
}
if (!topVC || [NSStringFromClass([topVC class]) containsString:@"ACForwardAssistantVC"]) return;
ACForwardAssistantVC *vc = [[ACForwardAssistantVC alloc] init];
UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
nav.modalPresentationStyle = UIModalPresentationPageSheet;
[topVC presentViewController:nav animated:YES completion:nil];
} @catch (NSException *e) {}
}
#pragma mark - 7. 换绑突破与全局请求头嗅探钩子
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
NSString *urlStr = request.URL.absoluteString;
// 自动捕获 apiv1.airchat.cc 请求中的全部真实 Header（用于动态发布鉴权）
BOOL acIsAirChatHost = ([urlStr containsString:@"airchat.cc"] || [urlStr containsString:@"airchat.cn"] || [urlStr containsString:@"airchat.ltd"]);
if (!acInternalRequest && acIsAirChatHost && request.allHTTPHeaderFields) {
NSDictionary *headers = request.allHTTPHeaderFields;
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
// 原生发布请求：整份 Header 作为模板保存（UA/Accept/X-Lts-Id 都与该接口匹配）
if ([urlStr containsString:@"/post/app/publish"]) {
mgr.lastPublishHeaders = [headers mutableCopy];
}
[headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
if (![k isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSString class]]) return;
NSString *lk = k.lowercaseString;
if ([lk isEqualToString:@"x-lts-id"]) {
// 修复：只接受 App 正常业务请求生成的 LtsId（约 150 字符且以 [s] 结尾），
// COS SDK 等短格式会让服务端直接 500
if (v.length >= 140 && [v hasSuffix:@"[s]"]) {
mgr.latestHTTPHeaders[@"X-Lts-Id"] = v;
mgr.latestHTTPHeaders[@"x-lts-id"] = v;
mgr.latestLtsAt = [[NSDate date] timeIntervalSince1970];
}
return;
}
if ([lk isEqualToString:@"token"] || [lk isEqualToString:@"x-userid"] ||
[lk isEqualToString:@"version"] || [lk isEqualToString:@"channel"]) {
mgr.latestHTTPHeaders[k] = v;
mgr.latestHTTPHeaders[lk] = v;
}
if ([lk isEqualToString:@"x-userid"] && v.length > 5) mgr.selfUserId = v;
}];
}
if ([urlStr containsString:@"/post/app/publish"] && request.HTTPBody) {
@try {
NSDictionary *sentBody = ACSafeDict([NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil]);
NSArray *mList = ACSafeArray(sentBody[@"mediaList"]);
if (mList && mList.count > 0) {
[ACForwardHelperManager shared].latestCapturedMomentMediaList = mList;
}
} @catch (NSException *e) {}
}
if ([urlStr containsString:@"checkPhoneRegister"] || [urlStr containsString:@"updateMyPhoneNumber"] || [urlStr containsString:@"validate"]) {
if (completionHandler) {
void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
NSDictionary *successDict = @{@"code": @200, @"msg": @"操作成功", @"data": @YES};
NSData *newData = [NSJSONSerialization dataWithJSONObject:successDict options:0 error:nil];
completionHandler(newData, response, error);
};
return %orig(request, wrappedHandler);
}
}
if ([urlStr containsString:@"/post/app/batchQueryPostInfo"] && completionHandler) {
void (^origHandler)(NSData *, NSURLResponse *, NSError *) = [completionHandler copy];
void (^feedHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
if (origHandler) origHandler(data, response, error);
if (!error && data.length > 0) {
@try {
NSDictionary *json = ACSafeDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
if (json) [[ACForwardHelperManager shared] ac_handleFeedResponse:json];
} @catch (NSException *e) {
ACLog(@"[自动评论] 响应解析异常 %@", e.reason);
}
}
};
return %orig(request, feedHandler);
}
return %orig;
}
// Alamofire 5 走的是 delegate 版本（无 completionHandler），
// 在这里抓 Session 实例与最终请求头，发布时复用同一个 Session 即可自动带上会话级头
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
if (!acInternalRequest && request && request.URL) {
NSString *urlStr = request.URL.absoluteString ?: @"";
if (urlStr.length > 0 && ([urlStr containsString:@"airchat.cc"] || [urlStr containsString:@"airchat.cn"])) {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
mgr.latestAppSession = self;
NSDictionary *headers = request.allHTTPHeaderFields;
if (headers) {
if ([urlStr containsString:@"/post/app/publish"]) {
mgr.lastPublishHeaders = [headers mutableCopy];
ACLog(@"[抓包] 原生发布模板 Lts=%lu", (unsigned long)ACHeaderValue(headers, @"X-Lts-Id").length);
}
[headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
if (![k isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSString class]]) return;
NSString *lk = k.lowercaseString;
if ([lk isEqualToString:@"x-lts-id"]) {
if (v.length >= 140 && [v hasSuffix:@"[s]"]) {
mgr.latestHTTPHeaders[@"X-Lts-Id"] = v;
mgr.latestHTTPHeaders[@"x-lts-id"] = v;
mgr.latestLtsAt = [[NSDate date] timeIntervalSince1970];
}
return;
}
if ([lk isEqualToString:@"token"] || [lk isEqualToString:@"x-userid"] ||
[lk isEqualToString:@"version"] || [lk isEqualToString:@"channel"]) {
mgr.latestHTTPHeaders[k] = v;
mgr.latestHTTPHeaders[lk] = v;
}
if ([lk isEqualToString:@"x-userid"] && v.length > 5) mgr.selfUserId = v;
}];
}
}
}
return %orig;
}
%end
%hook NSMutableURLRequest
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString * _Nullable)field {
%orig;
if (acInternalRequest) return;
if (field && value && [field isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) {
NSString *lowerField = field.lowercaseString;
BOOL stable = ([lowerField isEqualToString:@"token"] ||
[lowerField isEqualToString:@"x-userid"] ||
[lowerField isEqualToString:@"version"] ||
[lowerField isEqualToString:@"channel"]);
BOOL validLts = ([lowerField isEqualToString:@"x-lts-id"] && value.length >= 140 && [value hasSuffix:@"[s]"]);
if (stable || validLts) {
[ACForwardHelperManager shared].latestHTTPHeaders[field] = value;
[ACForwardHelperManager shared].latestHTTPHeaders[lowerField] = value;
if ([lowerField isEqualToString:@"x-userid"] && value.length > 5) {
[ACForwardHelperManager shared].selfUserId = value;
}
}
}
}
%end
%hook NSMutableURLRequest
- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
%orig;
if (acInternalRequest) return;
if (![field isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]]) return;
NSString *lf = field.lowercaseString;
if ([lf isEqualToString:@"x-lts-id"] && value.length >= 140 && [value hasSuffix:@"[s]"]) {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
mgr.latestHTTPHeaders[@"X-Lts-Id"] = value;
mgr.latestHTTPHeaders[@"x-lts-id"] = value;
mgr.latestLtsAt = [[NSDate date] timeIntervalSince1970];
}
}
- (void)setAllHTTPHeaderFields:(NSDictionary<NSString *,NSString *> *)headers {
%orig;
if (acInternalRequest || headers.count == 0) return;
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
[headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
if (![k isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSString class]]) return;
NSString *lk = k.lowercaseString;
if ([lk isEqualToString:@"x-lts-id"] && v.length >= 140 && [v hasSuffix:@"[s]"]) {
mgr.latestHTTPHeaders[@"X-Lts-Id"] = v;
mgr.latestHTTPHeaders[@"x-lts-id"] = v;
mgr.latestLtsAt = [[NSDate date] timeIntervalSince1970];
}
if ([lk isEqualToString:@"token"] || [lk isEqualToString:@"x-userid"] ||
[lk isEqualToString:@"version"] || [lk isEqualToString:@"channel"]) {
mgr.latestHTTPHeaders[k] = v;
mgr.latestHTTPHeaders[lk] = v;
}
if ([lk isEqualToString:@"x-userid"] && v.length > 5) mgr.selfUserId = v;
}];
}
%end
%hook NSJSONSerialization
+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError * _Nullable *)error {
id res = %orig;
NSDictionary *dict = ACSafeDict(res);
// 修复：只处理成功响应中的业务数据；0.5s 节流，避免全 App 每个 JSON 都触发解析+落盘
if (dict && dict[@"code"] && dict[@"data"] && ![dict[@"data"] isKindOfClass:[NSNull class]]) {
// 信息流响应结构 { data: { records: [ {id, userId, contentText, createTime...} ] } }
// 从这里触发自动评论，不受 App 使用哪种网络 API 影响
NSDictionary *acFeedData = ACSafeDict(dict[@"data"]);
NSArray *acFeedRecords = ACSafeArray(acFeedData[@"records"]);
if (acFeedRecords.count > 0) {
NSDictionary *acFirst = ACSafeDict(acFeedRecords.firstObject);
if (acFirst[@"id"] && (acFirst[@"contentText"] || acFirst[@"mediaList"] || acFirst[@"commentPermission"])) {
dispatch_async(dispatch_get_main_queue(), ^{
@try { [[ACForwardHelperManager shared] ac_handleFeedResponse:dict]; }
@catch (NSException *e) { ACLog(@"[自动评论] 触发异常 %@", e.reason); }
});
}
}
static NSTimeInterval acLastJSONParse = 0;
NSTimeInterval nowT = [[NSDate date] timeIntervalSince1970];
if (nowT - acLastJSONParse >= 0.5) {
acLastJSONParse = nowT;
id dataObj = dict[@"data"];
dispatch_async(dispatch_get_main_queue(), ^{
@try {
[[ACForwardHelperManager shared] parseJSONWithContext:dataObj];
[[ACForwardHelperManager shared] setupIMGroupWelcomeListener];
} @catch (NSException *e) {}
});
}
}
return res;
}
%end
%hook UILongPressGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state {
%orig;
if (state == UIGestureRecognizerStateBegan) {
@try {
UIView *v = self.view;
if (!v) return;
UIView *cellView = v;
while (cellView && ![cellView isKindOfClass:[UITableViewCell class]] && cellView.superview) {
cellView = cellView.superview;
}
NSString *cellCls = NSStringFromClass([cellView class]);
if ([cellCls containsString:@"Chat"] || [cellCls containsString:@"Bubble"] || [cellCls containsString:@"Message"]) {
__lastLongPressedView = cellView;
UIImage *extractedImg = ACFindLargestImageInView(cellView);
if (extractedImg) {
// 长按聊天气泡提取的图片仅存入群发槽（Slot 0），不影响自动回复或迎新槽
[[ACForwardHelperManager shared] saveImage:extractedImg forSlot:ACMediaSlotBatchSend];
}
__pendingForwardText = ACFindChatTextInView(cellView);
UIWindow *win = v.window ?: [UIApplication sharedApplication].keyWindow;
UIView *oldBar = [win viewWithTag:778899];
[oldBar removeFromSuperview];
UIButton *quickForwardPill = [UIButton buttonWithType:UIButtonTypeCustom];
quickForwardPill.tag = 778899;
CGFloat pillW = 210.0;
CGFloat pillH = 42.0;
CGPoint touchPt = [self locationInView:win];
CGFloat pillX = MIN(MAX(16.0, touchPt.x - pillW / 2.0), win.bounds.size.width - pillW - 16.0);
CGFloat pillY = MAX(64.0, touchPt.y - 95.0);
quickForwardPill.frame = CGRectMake(pillX, pillY, pillW, pillH);
quickForwardPill.backgroundColor = [UIColor systemBlueColor];
quickForwardPill.layer.cornerRadius = 21.0;
quickForwardPill.layer.shadowColor = [UIColor blackColor].CGColor;
quickForwardPill.layer.shadowOpacity = 0.35;
quickForwardPill.layer.shadowOffset = CGSizeMake(0, 4);
quickForwardPill.layer.shadowRadius = 6.0;
NSString *typeTag = extractedImg ? @"🖼️已存群发图" : @"📝群发此消息";
[quickForwardPill setTitle:[NSString stringWithFormat:@"🚀 转发助手 (%@)", typeTag] forState:UIControlStateNormal];
[quickForwardPill setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
quickForwardPill.titleLabel.font = [UIFont boldSystemFontOfSize:14];
[quickForwardPill addTarget:win action:@selector(ac_onQuickPillTap:) forControlEvents:UIControlEventTouchUpInside];
[win addSubview:quickForwardPill];
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
if (quickForwardPill.superview) [quickForwardPill removeFromSuperview];
});
}
} @catch (NSException *e) {}
}
}
%end
%hook UIWindow
%new
- (void)ac_onQuickPillTap:(UIButton * _Nonnull)sender {
[sender removeFromSuperview];
ACPresentForwardAssistantFromTopVC();
}
%end
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
%orig;
@try {
[[ACForwardHelperManager shared] setupIMGroupWelcomeListener];
NSString *clsName = NSStringFromClass([self class]);
if ([clsName containsString:@"HelpAboutViewController"]) {
if (self.navigationItem) {
UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"🚀 转发助手"
style:UIBarButtonItemStyleDone
target:self
action:@selector(ac_openFromAbout)];
btn.tintColor = [UIColor systemBlueColor];
self.navigationItem.rightBarButtonItem = btn;
}
}
if ([clsName containsString:@"ChatC2CViewController"]) {
UIView *existingForceBtn = [self.view viewWithTag:665544];
if (!existingForceBtn) {
UIButton *forceBtn = [UIButton buttonWithType:UIButtonTypeCustom];
forceBtn.tag = 665544;
forceBtn.frame = CGRectMake(self.view.bounds.size.width - 88, 54, 76, 32);
forceBtn.backgroundColor = [UIColor systemOrangeColor];
forceBtn.layer.cornerRadius = 16;
[forceBtn setTitle:@"⚡破盾发" forState:UIControlStateNormal];
[forceBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
forceBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
[forceBtn addTarget:self action:@selector(ac_forceSendInCurrentChat) forControlEvents:UIControlEventTouchUpInside];
[self.view addSubview:forceBtn];
}
}
} @catch (NSException *e) {}
}
%new
- (void)ac_openFromAbout {
__pendingForwardText = nil;
ACPresentForwardAssistantFromTopVC();
}
%new
- (void)ac_forceSendInCurrentChat {
UITextView *inputTV = ACFindInputTextViewInView(self.view);
NSString *text = inputTV ? [inputTV.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
if (text.length == 0 && [[ACForwardHelperManager shared] mediaTypeForSlot:ACMediaSlotBatchSend] == 0) text = @"你好";
if (!__currentChatPeerId || __currentChatPeerId.length < 5) return;
ACContactItem *peer = [[ACContactItem alloc] init];
peer.targetId = __currentChatPeerId;
peer.name = self.title ?: __currentChatPeerId;
peer.sourceType = 0;
[[ACForwardHelperManager shared] sendText:text mediaSlot:ACMediaSlotBatchSend attachMedia:YES toItem:peer completion:^(BOOL ok, NSString *detail) {
if (ok && inputTV) inputTV.text = @"";
UIAlertController *alert = [UIAlertController alertControllerWithTitle:(ok ? @"✅ 强发成功" : @"⚠️ 发送结果")
message:detail
preferredStyle:UIAlertControllerStyleAlert];
[alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
[self presentViewController:alert animated:YES completion:nil];
}];
}
%end

#pragma mark - 8. TIM 监听代理（保证消息一定能进入自动回复引擎）
// 说明：部分 ImSDK_Plus 版本在未登录/尚未初始化时 addAdvancedMsgListener: 会静默失败，
// 或只把消息回调派发给 App 自己的监听器。这里把 App 注册的监听器包一层代理，
// 由代理同时把消息喂给本插件，再原样转发给 App 原监听器。
@interface ACTIMListenerProxy : NSObject
@property (nonatomic, weak) id originalListener;
+ (NSMutableArray *)ac_proxyPool;
+ (instancetype)proxyForListener:(id)listener;
@end
@implementation ACTIMListenerProxy
+ (NSMutableArray *)ac_proxyPool {
static NSMutableArray *pool = nil;
static dispatch_once_t once;
dispatch_once(&once, ^{ pool = [NSMutableArray array]; });
return pool;
}
+ (instancetype)proxyForListener:(id)listener {
if (!listener) return nil;
NSMutableArray *pool = [[self class] ac_proxyPool];
@synchronized (pool) {
for (ACTIMListenerProxy *p in pool) {
if (p.originalListener == listener) return p;
}
ACTIMListenerProxy *p = [[ACTIMListenerProxy alloc] init];
p.originalListener = listener;
[pool addObject:p];
return p;
}
}
- (BOOL)respondsToSelector:(SEL)aSelector {
return [super respondsToSelector:aSelector] || [self.originalListener respondsToSelector:aSelector];
}
- (BOOL)conformsToProtocol:(Protocol *)aProtocol {
return [super conformsToProtocol:aProtocol] || [self.originalListener conformsToProtocol:aProtocol];
}
- (id)forwardingTargetForSelector:(SEL)aSelector {
if ([self.originalListener respondsToSelector:aSelector]) return self.originalListener;
return nil;
}
- (void)onRecvNewMessage:(id)msg {
@try { [[ACForwardHelperManager shared] ac_handleIncomingMessage:msg]; } @catch (NSException *e) {}
id orig = self.originalListener;
if (orig && orig != [ACForwardHelperManager shared] && [orig respondsToSelector:_cmd]) {
((void (*)(id, SEL, id))objc_msgSend)(orig, _cmd, msg);
}
}
- (void)onMemberEnter:(NSString *)groupID memberList:(NSArray *)memberList {
@try { [[ACForwardHelperManager shared] ac_handleMembersJoined:memberList groupID:groupID]; } @catch (NSException *e) {}
id orig = self.originalListener;
if (orig && orig != [ACForwardHelperManager shared] && [orig respondsToSelector:_cmd]) {
((void (*)(id, SEL, id, id))objc_msgSend)(orig, _cmd, groupID, memberList);
}
}
- (void)onMemberInvited:(NSString *)groupID opUser:(id)opUser memberList:(NSArray *)memberList {
@try { [[ACForwardHelperManager shared] ac_handleMembersJoined:memberList groupID:groupID]; } @catch (NSException *e) {}
id orig = self.originalListener;
if (orig && orig != [ACForwardHelperManager shared] && [orig respondsToSelector:_cmd]) {
((void (*)(id, SEL, id, id, id))objc_msgSend)(orig, _cmd, groupID, opUser, memberList);
}
}
@end

static IMP ac_orig_addAdvancedMsgListener = NULL;
static IMP ac_orig_addGroupListener = NULL;

static void ac_addAdvancedMsgListenerHook(id self, SEL _cmd, id listener) {
id proxy = listener ? [ACTIMListenerProxy proxyForListener:listener] : listener;
if (ac_orig_addAdvancedMsgListener) {
((void (*)(id, SEL, id))ac_orig_addAdvancedMsgListener)(self, _cmd, proxy);
}
}
static void ac_addGroupListenerHook(id self, SEL _cmd, id listener) {
id proxy = listener ? [ACTIMListenerProxy proxyForListener:listener] : listener;
if (ac_orig_addGroupListener) {
((void (*)(id, SEL, id))ac_orig_addGroupListener)(self, _cmd, proxy);
}
}
static void ACSwizzleIMP(Class cls, NSString *selName, IMP newImp, IMP *store) {
if (!cls || !newImp) return;
SEL sel = NSSelectorFromString(selName);
Method m = class_getInstanceMethod(cls, sel);
if (!m) return;
if (store && *store) return; // 已安装，避免重复包裹
IMP oldImp = method_setImplementation(m, newImp);
if (store) *store = oldImp;
}
static void ACInstallTIMHooks(void) {
Class c = NSClassFromString(@"V2TIMManager");
if (!c) return;
ACSwizzleIMP(c, @"addAdvancedMsgListener:", (IMP)ac_addAdvancedMsgListenerHook, &ac_orig_addAdvancedMsgListener);
ACSwizzleIMP(c, @"addGroupListener:", (IMP)ac_addGroupListenerHook, &ac_orig_addGroupListener);
}

%ctor {
// 延迟到 App 完成基础初始化后再安装钩子/注册监听，失败则多次重试
void (^install)(void) = ^{
ACInstallTIMHooks();
[[ACForwardHelperManager shared] setupIMGroupWelcomeListener];
};
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), install);
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), install);
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), install);
}
