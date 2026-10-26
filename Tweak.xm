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
[ud setObject:[self.latestHTTPHeaders copy] forKey:@"AC_Saved_HTTPHeaders"];
}
if (self.selfUserId.length > 5) {
[ud setObject:self.selfUserId forKey:@"AC_Saved_SelfUserId"];
}
[ud setBool:self.autoReplyEnabled forKey:@"AC_AutoReply_Enabled"];
NSMutableArray *rDicts = [NSMutableArray array];
for (ACAutoReplyRule *r in self.autoReplyRules) {
[rDicts addObject:[r toDict]];
}
[rDicts writeToFile:[self cacheFilePath:@"autoreply_rules"] atomically:YES];
[ud setBool:self.autoMomentEnabled forKey:@"AC_AutoMoment_Enabled"];
[ud setInteger:MAX(1, self.momentIntervalMinutes) forKey:@"AC_AutoMoment_Interval"];
NSMutableArray *mDicts = [NSMutableArray array];
for (ACMomentTaskItem *t in self.momentTasks) {
[mDicts addObject:[t toDict]];
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
NSDictionary *savedHeaders = ACSafeDict([ud objectForKey:@"AC_Saved_HTTPHeaders"]);
if (savedHeaders) {
[self.latestHTTPHeaders addEntriesFromDictionary:savedHeaders];
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
if (self.listenerRegistered) return;
@try {
Class v2Cls = NSClassFromString(@"V2TIMManager");
if (!v2Cls || ![v2Cls respondsToSelector:@selector(sharedInstance)]) return;
id mgr = ((id (*)(id, SEL))objc_msgSend)(v2Cls, @selector(sharedInstance));
if (!mgr) return;
SEL addGrpListenerSel = NSSelectorFromString(@"addGroupListener:");
if ([mgr respondsToSelector:addGrpListenerSel]) {
((void (*)(id, SEL, id))objc_msgSend)(mgr, addGrpListenerSel, self);
self.listenerRegistered = YES;
}
SEL addMsgListenerSel = NSSelectorFromString(@"addAdvancedMsgListener:");
if ([mgr respondsToSelector:addMsgListenerSel]) {
((void (*)(id, SEL, id))objc_msgSend)(mgr, addMsgListenerSel, self);
self.listenerRegistered = YES;
}
} @catch (NSException *e) {}
}
- (void)onMemberEnter:(NSString *)groupID memberList:(NSArray *)memberList {
[self handleNewMembersJoinedGroup:groupID memberList:memberList];
}
- (void)onMemberInvited:(NSString *)groupID opUser:(id)opUser memberList:(NSArray *)memberList {
[self handleNewMembersJoinedGroup:groupID memberList:memberList];
}
- (void)onRecvNewMessage:(id)msg {
if (!msg) return;
@try {
NSData *cData = [msg valueForKey:@"cloudCustomData"];
if ([cData isKindOfClass:[NSData class]] && cData.length > 10) {
NSDictionary *cDict = ACSafeDict([NSJSONSerialization JSONObjectWithData:cData options:0 error:nil]);
NSString *v2Str = ACSafeStr(cDict[@"client_typeV2"]);
if (v2Str.length > 10) {
self.capturedClientTypeV2 = v2Str;
self.capturedCloudCustomData = cData;
}
}
BOOL isSelf = [[msg valueForKey:@"isSelf"] boolValue];
NSString *groupID = ACSafeStr([msg valueForKey:@"groupID"]);
NSString *userID = ACSafeStr([msg valueForKey:@"userID"]);
NSString *sender = ACSafeStr([msg valueForKey:@"sender"]);
if (sender.length == 0) sender = userID;
NSString *nickName = ACSafeStr([msg valueForKey:@"nickName"]);
if (nickName.length == 0) nickName = ACSafeStr([msg valueForKey:@"nameCard"]);
// A. 别人发来的 C2C 私信 -> 自动回复（严格使用槽位2或该条规则绑定的专属图片/视频）
if (groupID.length == 0 && sender.length >= 5 && !isSelf && ![sender isEqualToString:self.selfUserId]) {
[self addFriendWithId:sender name:nickName tag:@"主动来信" chatMeType:0];
[self saveLocalPermanentCache];
if (self.autoReplyEnabled && self.autoReplyRules.count > 0) {
NSString *incomingText = @"";
id textElem = [msg valueForKey:@"textElem"];
if (textElem && ![textElem isKindOfClass:[NSNull class]]) {
incomingText = ACSafeStr([textElem valueForKey:@"text"]);
}
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
id tipsElem = [msg valueForKey:@"groupTipsElem"];
if (tipsElem && ![tipsElem isKindOfClass:[NSNull class]]) {
NSInteger tipsType = [ACSafeStr([tipsElem valueForKey:@"type"]) integerValue];
if (tipsType == 1 || tipsType == 2) {
NSArray *memberList = ACSafeArray([tipsElem valueForKey:@"memberList"]);
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
for (ACAutoReplyRule *rule in self.autoReplyRules) {
if (!rule.enabled || rule.replyText.length == 0) continue;
NSString *kw = [rule.keyword stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
if (kw.length == 0 || [kw isEqualToString:@""] || [kw isEqualToString:@"全部"]) {
if (!fallbackRule) fallbackRule = rule;
} else if (incomingText.length > 0 && [incomingText localizedCaseInsensitiveContainsString:kw]) {
matchedRule = rule;
break;
}
}
ACAutoReplyRule *finalRule = matchedRule ?: fallbackRule;
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
// 严格按照 StormSniffer 抓包 (04:36:23.102Z) 还原动态发布请求头与请求体
- (void)publishMomentTask:(ACMomentTaskItem *)task completion:(void(^)(BOOL ok, NSString *msg))completion {
if (!task || task.contentText.length == 0) {
if (completion) completion(NO, @"动态内容为空");
return;
}
NSString *token = self.latestHTTPHeaders[@"token"];
if (!token || token.length == 0) {
NSString *err = @"⚠️ 正在获取登录凭证，请随便点一下底栏切换页面后再试";
self.lastMomentLog = err;
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(NO, err);
return;
}
@try {
NSURL *url = [NSURL URLWithString:@"https://apiv1.airchat.cc/client/biz/v2/post/app/publish"];
NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
req.HTTPMethod = @"POST";
// 1. 填充抓包中必需的全部鉴权请求头（包含之前遗漏的 X-Request-No）
[req setValue:@"/" forHTTPHeaderField:@"Accept"];
[req setValue:@"zh-CN,zh-Hans;q=0.9" forHTTPHeaderField:@"Accept-Language"];
[req setValue:@"gzip, deflate, br" forHTTPHeaderField:@"Accept-Encoding"];
[req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
[req setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
[req setValue:token forHTTPHeaderField:@"token"];
[req setValue:(self.selfUserId ?: @"1980559125632786434") forHTTPHeaderField:@"x-userid"];
[req setValue:(self.latestHTTPHeaders[@"version"] ?: @"2.1.8 (1017)") forHTTPHeaderField:@"version"];
[req setValue:(self.latestHTTPHeaders[@"User-Agent"] ?: @"airchat/1017 CFNetwork/1490.0.4 Darwin/23.2.0") forHTTPHeaderField:@"User-Agent"];
[req setValue:(self.latestHTTPHeaders[@"channel"] ?: @"ios, iPhone iOS 17.2.1, 2A2BBADD-BD22-4D48-B795-8AB72EB246C8 (iPhone16,2), zh, Asia/Shanghai") forHTTPHeaderField:@"channel"];
NSString *ltsId = self.latestHTTPHeaders[@"X-Lts-Id"] ?: self.latestHTTPHeaders[@"x-lts-id"];
if (ltsId && ltsId.length > 0) {
[req setValue:ltsId forHTTPHeaderField:@"X-Lts-Id"];
}
// 生成与抓包一致的 15 位 X-Request-No
NSString *reqNo = self.latestHTTPHeaders[@"X-Request-No"] ?: [NSString stringWithFormat:@"2295089%08u", arc4random_uniform(99999999)];
[req setValue:reqNo forHTTPHeaderField:@"X-Request-No"];
// 2. 严格还原抓包中的请求体结构：
// 纯文字动态抓包真实 Body: {"commentPermission":1,"contentText":"u","contentType":1}（绝不传多余的 label 字段！）
NSArray *mediaArr = ACSafeArray(task.capturedMediaList);
BOOL hasRemoteMedia = (mediaArr && mediaArr.count > 0);
NSMutableDictionary *bodyDict = [NSMutableDictionary dictionary];
bodyDict[@"commentPermission"] = @(1);
bodyDict[@"contentText"] = task.contentText;
if (hasRemoteMedia) {
bodyDict[@"contentType"] = @(3);
bodyDict[@"mediaList"] = mediaArr;
} else {
bodyDict[@"contentType"] = @(1);
}
NSData *bodyData = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil];
req.HTTPBody = bodyData;
[req setValue:[NSString stringWithFormat:@"%lu", (unsigned long)bodyData.length] forHTTPHeaderField:@"Content-Length"];
__weak typeof(self) weakSelf = self;
[[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
dispatch_async(dispatch_get_main_queue(), ^{
if (error || !data) {
NSString *failMsg = [NSString stringWithFormat:@"❌ 发布异常: %@", error.localizedDescription ?: @"网络错误"];
weakSelf.lastMomentLog = failMsg;
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(NO, failMsg);
return;
}
NSDictionary *respDict = ACSafeDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
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
} else {
NSString *serverMsg = ACSafeStr(respDict[@"msg"]);
if (serverMsg.length == 0) {
serverMsg = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"接口返回非200";
}
NSString *errLog = [NSString stringWithFormat:@"⚠️ 动态返回(%ld): %@", (long)code, serverMsg];
weakSelf.lastMomentLog = errLog;
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(NO, errLog);
}
});
}] resume];
} @catch (NSException *e) {
if (completion) completion(NO, @"构造动态请求异常");
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
- (void)callAirChatBackendAddFriendAndUnlock:(NSString *)targetUserId completion:(void(^)(void))completion {
if (!targetUserId || targetUserId.length == 0 || !self.latestHTTPHeaders[@"token"]) {
if (completion) completion();
return;
}
@try {
dispatch_group_t apiGroup = dispatch_group_create();
dispatch_group_enter(apiGroup);
NSMutableURLRequest *req1 = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://apiv1.airchat.cc/client/biz/userfriends/add"]];
req1.HTTPMethod = @"POST";
[self.latestHTTPHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
[req1 setValue:v forHTTPHeaderField:k];
}];
[req1 setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
req1.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"friendId": targetUserId} options:0 error:nil];
[[[NSURLSession sharedSession] dataTaskWithRequest:req1 completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
dispatch_group_leave(apiGroup);
}] resume];
dispatch_group_enter(apiGroup);
NSMutableURLRequest *req2 = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://apiv1.airchat.cc/client/biz/useronechat/add"]];
req2.HTTPMethod = @"POST";
[self.latestHTTPHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
[req2 setValue:v forHTTPHeaderField:k];
}];
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
- (void)rawSendV2Message:(id)v2Msg toItem:(ACContactItem *)item completion:(void(^)(BOOL ok, int code,  NSString *desc))completion {
@try {
Class v2MgrCls = NSClassFromString(@"V2TIMManager");
id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));
SEL sendMsgSel = NSSelectorFromString(@"sendMessage:receiver:groupID:priority:onlineUserOnly:offlinePushInfo:progress:succ:fail:");
if (!v2Msg || ![manager respondsToSelector:sendMsgSel]) {
if (completion) completion(NO, -1, @"构造消息失败");
return;
}
if (self.capturedCloudCustomData) {
[v2Msg setValue:self.capturedCloudCustomData forKey:@"cloudCustomData"];
} else {
NSDictionary *nativeCustom = @{
@"client_typeV2": self.capturedClientTypeV2 ?: @"79b3h7aOxJurSbzVhPK2Wal1cKQzfppVutid7[d]gEtuxYU87uiCm3l2gMp7d5Eo3KZS3hFxBn8Db[d]yag55Ev1I3W[a]7xF6oF0FSXM[s]",
@"client_type": @"iOS"
};
NSData *customData = [NSJSONSerialization dataWithJSONObject:nativeCustom options:0 error:nil];
if (customData) [v2Msg setValue:customData forKey:@"cloudCustomData"];
}
BOOL isGroup = (item.sourceType == 2);
NSString *receiver = isGroup ? nil : item.targetId;
NSString *groupID = isGroup ? item.targetId : nil;
void (^succBlock)(void) = ^{
if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, 0, nil); });
};
void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) {
if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, code, desc); });
};
NSMethodSignature *sig = [manager methodSignatureForSelector:sendMsgSel];
NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
[inv setTarget:manager];
[inv setSelector:sendMsgSel];
[inv setArgument:&v2Msg atIndex:2];
[inv setArgument:&receiver atIndex:3];
[inv setArgument:&groupID atIndex:4];
NSInteger priority = 1;
BOOL onlineOnly = NO;
id nilObj = nil;
[inv setArgument:&priority atIndex:5];
[inv setArgument:&onlineOnly atIndex:6];
[inv setArgument:&nilObj atIndex:7];
[inv setArgument:&nilObj atIndex:8];
[inv setArgument:&succBlock atIndex:9];
[inv setArgument:&failBlock atIndex:10];
[inv invoke];
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
self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 200, width - 32, 24)];
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
CGFloat headerH = 232.0;
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
self.statusLabel.text = @"⏳ 正在立即发布该条动态任务...";
[mgr publishMomentTask:task completion:nil];
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
if ([urlStr containsString:@"apiv1.airchat.cc"] && request.allHTTPHeaderFields) {
NSDictionary *headers = request.allHTTPHeaderFields;
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
[headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
if ([k isKindOfClass:[NSString class]] && [v isKindOfClass:[NSString class]]) {
mgr.latestHTTPHeaders[k] = v;
if ([k.lowercaseString isEqualToString:@"x-userid"] && v.length > 5) {
mgr.selfUserId = v;
}
}
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
return %orig;
}
%end
%hook NSMutableURLRequest
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString * _Nullable)field {
%orig;
if (field && value && [field isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) {
NSString *lowerField = field.lowercaseString;
if ([lowerField isEqualToString:@"token"] ||
[lowerField isEqualToString:@"x-userid"] ||
[lowerField isEqualToString:@"x-lts-id"] ||
[lowerField isEqualToString:@"x-request-no"] ||
[lowerField isEqualToString:@"channel"] ||
[lowerField isEqualToString:@"version"] ||
[lowerField isEqualToString:@"user-agent"]) {
[ACForwardHelperManager shared].latestHTTPHeaders[field] = value;
if ([lowerField isEqualToString:@"x-userid"] && value.length > 5) {
[ACForwardHelperManager shared].selfUserId = value;
}
}
}
}
%end
%hook NSJSONSerialization
+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError * _Nullable *)error {
id res = %orig;
NSDictionary *dict = ACSafeDict(res);
if (dict && dict[@"code"] && dict[@"data"]) {
id dataObj = dict[@"data"];
dispatch_async(dispatch_get_main_queue(), ^{
[[ACForwardHelperManager shared] parseJSONWithContext:dataObj];
[[ACForwardHelperManager shared] saveLocalPermanentCache];
[[ACForwardHelperManager shared] setupIMGroupWelcomeListener];
});
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
