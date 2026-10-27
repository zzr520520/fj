#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

#pragma mark - 0. 安全转换函数
static inline NSDictionary *ACSafeDict(id obj) {
    return (obj && [obj isKindOfClass:[NSDictionary class]]) ? (NSDictionary *)obj : nil;
}
static inline NSArray *ACSafeArray(id obj) {
    return (obj && [obj isKindOfClass:[NSArray class]]) ? (NSArray *)obj : nil;
}
static inline NSString *ACSafeStr(id obj) {
    if (!obj || [obj isKindOfClass:[NSNull class]]) return @"";
    if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
    if ([obj isKindOfClass:[NSNumber class]]) return [(NSNumber *)obj stringValue];
    return [NSString stringWithFormat:@"%@", obj];
}

typedef NS_ENUM(NSInteger, ACMediaSlot) {
    ACMediaSlotBatchSend = 0,
    ACMediaSlotWelcome   = 1,
    ACMediaSlotAutoReply = 2,
    ACMediaSlotMoment    = 3
};

#pragma mark - 1. 数据模型
@interface ACContactItem : NSObject
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *fromGroupId;
@property (nonatomic, copy) NSString *roleDesc;
@property (nonatomic, assign) NSInteger sourceType;
@property (nonatomic, assign) NSInteger chatMeType;
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

@interface ACAutoReplyRule : NSObject
@property (nonatomic, copy) NSString *ruleId;
@property (nonatomic, copy) NSString *keyword;
@property (nonatomic, copy) NSString *replyText;
@property (nonatomic, assign) BOOL attachMedia;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) NSInteger customMediaType;
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

@interface ACMomentTaskItem : NSObject
@property (nonatomic, copy) NSString *taskId;
@property (nonatomic, copy) NSString *contentText;
@property (nonatomic, strong) NSArray *capturedMediaList;
@property (nonatomic, assign) NSInteger localMediaType;
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
    md[@"localMediaPath"] = self.localMediaPath ?: @"";
    md[@"capturedMediaList"] = ACSafeArray(self.capturedMediaList) ?: @[];
    return md;
}
+ (instancetype)fromDict:(NSDictionary *)d {
    NSDictionary *dict = ACSafeDict(d);
    if (!dict) return nil;
    ACMomentTaskItem *t = [[ACMomentTaskItem alloc] init];
    t.taskId = ACSafeStr(dict[@"taskId"]);
    t.contentText = ACSafeStr(dict[@"contentText"]);
    t.capturedMediaList = ACSafeArray(dict[@"capturedMediaList"]);
    t.localMediaType = [ACSafeStr(dict[@"localMediaType"]) integerValue];
    t.localMediaPath = ACSafeStr(dict[@"localMediaPath"]);
    t.enabled = dict[@"enabled"] ? [ACSafeStr(dict[@"enabled"]) boolValue] : YES;
    t.sentCount = [ACSafeStr(dict[@"sentCount"]) integerValue];
    t.lastSentTimeStr = ACSafeStr(dict[@"lastSentTimeStr"]);
    if (t.lastSentTimeStr.length == 0) t.lastSentTimeStr = @"待发布";
    return t;
}
@end

#pragma mark - 2. 管理中枢
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

@property (nonatomic, assign) BOOL autoWelcomeEnabled;
@property (nonatomic, copy) NSString *welcomeMessageText;
@property (nonatomic, strong) NSMutableSet<NSString *> *welcomeGroupIds;
@property (nonatomic, strong) NSMutableSet<NSString *> *greetedUserIds;
@property (nonatomic, assign) NSInteger greetedCount;
@property (nonatomic, copy) NSString *lastGreetLog;

@property (nonatomic, assign) BOOL autoReplyEnabled;
@property (nonatomic, strong) NSMutableArray<ACAutoReplyRule *> *autoReplyRules;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *autoReplyCooldownMap;
@property (nonatomic, assign) NSInteger autoRepliedCount;
@property (nonatomic, copy) NSString *lastAutoReplyLog;

@property (nonatomic, assign) BOOL autoMomentEnabled;
@property (nonatomic, assign) NSInteger momentIntervalMinutes;
@property (nonatomic, strong) NSMutableArray<ACMomentTaskItem *> *momentTasks;
@property (nonatomic, assign) NSInteger currentMomentRotationIdx;
@property (nonatomic, strong) NSTimer *momentTimer;
@property (nonatomic, strong) NSArray *latestCapturedMomentMediaList;
@property (nonatomic, copy) NSString *lastMomentLog;
@property (nonatomic, assign) NSTimeInterval lastMomentPublishTimestamp;

+ (instancetype)shared;
- (NSInteger)mediaTypeForSlot:(ACMediaSlot)slot;
- (UIImage *)previewImageForSlot:(ACMediaSlot)slot;
- (int)videoDurationForSlot:(ACMediaSlot)slot;
- (NSString *)imagePathForSlot:(ACMediaSlot)slot;
- (NSString *)videoPathForSlot:(ACMediaSlot)slot;
- (NSString *)videoThumbPathForSlot:(ACMediaSlot)slot;
- (void)saveImage:(UIImage *)img forSlot:(ACMediaSlot)slot;
- (void)saveVideoAtURL:(NSURL *)videoURL forSlot:(ACMediaSlot)slot;
- (void)clearMediaForSlot:(ACMediaSlot)slot;
- (void)registerTIMListenersExplicitly;
- (void)loadLocalPermanentCache;
- (void)saveLocalPermanentCache;
- (void)clearAllGroupMembersCache;
- (void)saveAllCustomSettings;
- (void)parseJSONWithContext:(id)jsonObj;
- (void)dispatchIncomingPrivateMessage:(id)msg;
- (void)sendText:(NSString *)text mediaSlot:(ACMediaSlot)slot attachMedia:(BOOL)attachMedia toItem:(ACContactItem *)item completion:(void(^)(BOOL ok, NSString *detail))completion;
- (void)sendText:(NSString *)text customMediaType:(NSInteger)mType customMediaPath:(NSString *)mPath customThumbPath:(NSString *)tPath customVideoDuration:(int)vDur toItem:(ACContactItem *)item completion:(void(^)(BOOL ok, NSString *detail))completion;
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
        instance.welcomeGroupIds = [NSMutableSet set];
        instance.greetedUserIds = [NSMutableSet set];
        instance.lastGreetLog = @"等待新人进群...";
        instance.autoReplyRules = [NSMutableArray array];
        instance.autoReplyCooldownMap = [NSMutableDictionary dictionary];
        instance.lastAutoReplyLog = @"等待收到私信...";
        instance.momentTasks = [NSMutableArray array];
        instance.momentIntervalMinutes = 10;
        instance.lastMomentLog = @"等待发布动态...";
        instance.lastMomentPublishTimestamp = 0;
        [instance loadLocalPermanentCache];
        [instance loadAllCustomSettings];
        [instance restartMomentScheduler];
    });
    return instance;
}

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
    if (t == 1) return [UIImage imageWithContentsOfFile:[self imagePathForSlot:slot]];
    else if (t == 2) return [UIImage imageWithContentsOfFile:[self videoThumbPathForSlot:slot]];
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
        if (self.capturedClientTypeV2) [ud setObject:self.capturedClientTypeV2 forKey:@"AC_Captured_ClientTypeV2"];
        if (self.latestHTTPHeaders.count > 0) [ud setObject:[self.latestHTTPHeaders copy] forKey:@"AC_Saved_HTTPHeaders"];
        if (self.selfUserId.length > 5) [ud setObject:self.selfUserId forKey:@"AC_Saved_SelfUserId"];
        [ud setBool:self.autoReplyEnabled forKey:@"AC_AutoReply_Enabled"];
        NSMutableArray *rDicts = [NSMutableArray array];
        for (ACAutoReplyRule *r in self.autoReplyRules) [rDicts addObject:[r toDict]];
        [rDicts writeToFile:[self cacheFilePath:@"autoreply_rules"] atomically:YES];
        [ud setBool:self.autoMomentEnabled forKey:@"AC_AutoMoment_Enabled"];
        [ud setInteger:MAX(5, self.momentIntervalMinutes) forKey:@"AC_AutoMoment_Interval"];
        NSMutableArray *mDicts = [NSMutableArray array];
        for (ACMomentTaskItem *t in self.momentTasks) [mDicts addObject:[t toDict]];
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
        if (savedV2.length > 10) self.capturedClientTypeV2 = savedV2;
        NSDictionary *savedHeaders = ACSafeDict([ud objectForKey:@"AC_Saved_HTTPHeaders"]);
        if (savedHeaders) [self.latestHTTPHeaders addEntriesFromDictionary:savedHeaders];
        NSString *savedUid = ACSafeStr([ud objectForKey:@"AC_Saved_SelfUserId"]);
        if (savedUid.length > 5) self.selfUserId = savedUid;
        
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
            defRule.keyword = @"*";
            defRule.replyText = @"您好 {name}，消息已收到，稍后第一时间回复您！";
            defRule.attachMedia = YES;
            defRule.enabled = YES;
            [self.autoReplyRules addObject:defRule];
        }
        self.autoMomentEnabled = [ud boolForKey:@"AC_AutoMoment_Enabled"];
        NSInteger savedInt = [ud integerForKey:@"AC_AutoMoment_Interval"];
        self.momentIntervalMinutes = savedInt >= 5 ? savedInt : 10;
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

- (void)registerTIMListenersExplicitly {
    @try {
        Class v2Cls = NSClassFromString(@"V2TIMManager");
        if (!v2Cls || ![v2Cls respondsToSelector:@selector(sharedInstance)]) return;
        id mgr = ((id (*)(id, SEL))objc_msgSend)(v2Cls, @selector(sharedInstance));
        if (!mgr) return;
        SEL addGrpListenerSel = NSSelectorFromString(@"addGroupListener:");
        if ([mgr respondsToSelector:addGrpListenerSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(mgr, addGrpListenerSel, self);
        }
        SEL addMsgListenerSel = NSSelectorFromString(@"addAdvancedMsgListener:");
        if ([mgr respondsToSelector:addMsgListenerSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(mgr, addMsgListenerSel, self);
        }
    } @catch (NSException *e) {}
}

#pragma mark - 自动回复核心派发逻辑
- (void)dispatchIncomingPrivateMessage:(id)msg {
    if (!msg) return;
    @try {
        BOOL isSelf = [[msg valueForKey:@"isSelf"] boolValue];
        NSString *groupID = ACSafeStr([msg valueForKey:@"groupID"]);
        NSString *userID = ACSafeStr([msg valueForKey:@"userID"]);
        NSString *sender = ACSafeStr([msg valueForKey:@"sender"]);
        if (sender.length == 0) sender = userID;
        
        // 严格只响应他人发来的私信
        if (isSelf || [sender isEqualToString:self.selfUserId] || sender.length < 5) return;
        if (groupID.length > 0) return; // 忽略群消息
        
        NSString *nickName = ACSafeStr([msg valueForKey:@"nickName"]);
        if (nickName.length == 0) nickName = ACSafeStr([msg valueForKey:@"nameCard"]);
        [self addFriendWithId:sender name:nickName tag:@"主动来信" chatMeType:0];
        [self saveLocalPermanentCache];
        
        if (!self.autoReplyEnabled || self.autoReplyRules.count == 0) return;

        NSString *incomingText = @"";
        id textElem = [msg valueForKey:@"textElem"];
        if (textElem && ![textElem isKindOfClass:[NSNull class]]) {
            incomingText = ACSafeStr([textElem valueForKey:@"text"]);
        }
        
        // 频控检查（同一个人 20 秒内不重复发）
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        NSNumber *lastTimeNum = self.autoReplyCooldownMap[sender];
        if (lastTimeNum && (now - [lastTimeNum doubleValue] < 20.0)) return;

        ACAutoReplyRule *matchedRule = nil;
        ACAutoReplyRule *wildcardRule = nil;
        for (ACAutoReplyRule *rule in self.autoReplyRules) {
            if (!rule.enabled || rule.replyText.length == 0) continue;
            NSString *kw = [rule.keyword stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (kw.length == 0 || [kw isEqualToString:@"*"] || [kw isEqualToString:@"全部"]) {
                if (!wildcardRule) wildcardRule = rule;
            } else if (incomingText.length > 0 && [incomingText localizedCaseInsensitiveContainsString:kw]) {
                matchedRule = rule;
                break;
            }
        }
        ACAutoReplyRule *finalRule = matchedRule ?: wildcardRule;
        if (!finalRule) return;
        self.autoReplyCooldownMap[sender] = @(now);

        NSString *displayNick = (nickName.length > 0) ? nickName : @"朋友";
        NSString *replyContent = [finalRule.replyText stringByReplacingOccurrencesOfString:@"{name}" withString:displayNick];
        ACContactItem *peer = self.friendMap[sender] ?: [[ACContactItem alloc] init];
        peer.targetId = sender;
        peer.name = displayNick;
        peer.sourceType = 0;
        peer.chatMeType = 0;

        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!weakSelf.autoReplyEnabled) return;
            [weakSelf sendText:replyContent mediaSlot:ACMediaSlotAutoReply attachMedia:finalRule.attachMedia toItem:peer completion:^(BOOL ok, NSString *detail) {
                if (ok) {
                    weakSelf.autoRepliedCount++;
                    weakSelf.lastAutoReplyLog = [NSString stringWithFormat:@"✅ 回复 %@: 成功(%@)", displayNick, detail];
                } else {
                    weakSelf.lastAutoReplyLog = [NSString stringWithFormat:@"⚠️ 回复失败: %@", detail];
                }
                [[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
            }];
        });
    } @catch (NSException *e) {}
}

#pragma mark - 动态发布核心逻辑（带5分钟频控自保护）
- (void)restartMomentScheduler {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.momentTimer) {
            [self.momentTimer invalidate];
            self.momentTimer = nil;
        }
        if (!self.autoMomentEnabled) return;
        NSTimeInterval intervalSec = MAX(5, self.momentIntervalMinutes) * 60.0;
        self.momentTimer = [NSTimer scheduledTimerWithTimeInterval:intervalSec target:self selector:@selector(onMomentTimerTick) userInfo:nil repeats:YES];
    });
}
- (void)onMomentTimerTick {
    if (!self.autoMomentEnabled || self.momentTasks.count == 0) return;
    NSMutableArray<ACMomentTaskItem *> *activeTasks = [NSMutableArray array];
    for (ACMomentTaskItem *t in self.momentTasks) {
        if (t.enabled && t.contentText.length > 0) [activeTasks addObject:t];
    }
    if (activeTasks.count == 0) return;
    if (self.currentMomentRotationIdx >= activeTasks.count) self.currentMomentRotationIdx = 0;
    ACMomentTaskItem *task = activeTasks[self.currentMomentRotationIdx];
    self.currentMomentRotationIdx = (self.currentMomentRotationIdx + 1) % activeTasks.count;
    [self publishMomentTask:task completion:nil];
}

- (void)publishMomentTask:(ACMomentTaskItem *)task completion:(void(^)(BOOL ok, NSString *msg))completion {
    if (!task || task.contentText.length == 0) {
        if (completion) completion(NO, @"动态内容为空");
        return;
    }
    // 5分钟频控本地自保护：防止频繁向服务器发起报错导致账号风控
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (self.lastMomentPublishTimestamp > 0 && (now - self.lastMomentPublishTimestamp < 305.0)) {
        NSInteger waitSec = (NSInteger)(305.0 - (now - self.lastMomentPublishTimestamp));
        NSString *tip = [NSString stringWithFormat:@"⚠️ 服务端限制非SVIP发动态需间隔5分钟，还需等待 %ld 秒", (long)waitSec];
        self.lastMomentLog = tip;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
        if (completion) completion(NO, tip);
        return;
    }
    
    NSString *token = self.latestHTTPHeaders[@"token"];
    NSString *ltsId = self.latestHTTPHeaders[@"X-Lts-Id"] ?: self.latestHTTPHeaders[@"x-lts-id"];
    if (!token || !ltsId) {
        NSString *err = @"⚠️ 缺少网关签名，请在App内刷新任意页面以捕获凭证";
        self.lastMomentLog = err;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
        if (completion) completion(NO, err);
        return;
    }

    @try {
        NSURL *url = [NSURL URLWithString:@"https://apiv1.airchat.cc/client/biz/v2/post/app/publish"];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"POST";
        [req setValue:@"*/*" forHTTPHeaderField:@"Accept"];
        [req setValue:@"zh-CN,zh-Hans;q=0.9" forHTTPHeaderField:@"Accept-Language"];
        [req setValue:@"gzip, deflate, br" forHTTPHeaderField:@"Accept-Encoding"];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
        [req setValue:token forHTTPHeaderField:@"token"];
        [req setValue:(self.selfUserId ?: @"1980559125632786434") forHTTPHeaderField:@"x-userid"];
        [req setValue:(self.latestHTTPHeaders[@"version"] ?: @"2.1.8 (1017)") forHTTPHeaderField:@"version"];
        [req setValue:(self.latestHTTPHeaders[@"User-Agent"] ?: @"airchat/1017 CFNetwork/1490.0.4 Darwin/23.2.0") forHTTPHeaderField:@"User-Agent"];
        [req setValue:(self.latestHTTPHeaders[@"channel"] ?: @"ios, iPhone iOS 17.2.1, 2A2BBADD-BD22-4D48-B795-8AB72EB246C8 (iPhone16,2), zh, Asia/Shanghai") forHTTPHeaderField:@"channel"];
        [req setValue:ltsId forHTTPHeaderField:@"X-Lts-Id"];
        
        NSString *reqNo = [NSString stringWithFormat:@"22950%010llu", (unsigned long long)arc4random_uniform(999999999)];
        [req setValue:reqNo forHTTPHeaderField:@"X-Request-No"];

        // 严格按照抓包 200 格式封装
        NSArray *mediaArr = ACSafeArray(task.capturedMediaList);
        NSMutableDictionary *bodyDict = [NSMutableDictionary dictionary];
        bodyDict[@"commentPermission"] = @(1);
        bodyDict[@"contentText"] = task.contentText;
        if (mediaArr && mediaArr.count > 0) {
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
                    NSString *msg = [NSString stringWithFormat:@"❌ 发布异常: %@", error.localizedDescription ?: @"网络错误"];
                    weakSelf.lastMomentLog = msg;
                    if (completion) completion(NO, msg);
                    return;
                }
                NSDictionary *resp = ACSafeDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
                NSInteger code = [ACSafeStr(resp[@"code"]) integerValue];
                if (code == 200) {
                    weakSelf.lastMomentPublishTimestamp = [[NSDate date] timeIntervalSince1970];
                    task.sentCount++;
                    NSDateFormatter *df = [[NSDateFormatter alloc] init];
                    df.dateFormat = @"HH:mm";
                    task.lastSentTimeStr = [df stringFromDate:[NSDate date]];
                    [weakSelf saveAllCustomSettings];
                    NSString *ok = [NSString stringWithFormat:@"✅ 动态发布成功(%@) | 累计%ld次", task.lastSentTimeStr, (long)task.sentCount];
                    weakSelf.lastMomentLog = ok;
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
                    if (completion) completion(YES, ok);
                } else {
                    NSString *failMsg = ACSafeStr(resp[@"msg"]);
                    if ([failMsg containsString:@"5分钟"]) {
                        weakSelf.lastMomentPublishTimestamp = [[NSDate date] timeIntervalSince1970];
                    }
                    NSString *errLog = [NSString stringWithFormat:@"⚠️ 失败(%ld): %@", (long)code, failMsg];
                    weakSelf.lastMomentLog = errLog;
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
                    if (completion) completion(NO, errLog);
                }
            });
        }] resume];
    } @catch (NSException *e) {
        if (completion) completion(NO, @"动态构造异常");
    }
}

#pragma mark - 破盾发信双通道实现
- (void)sendOfflineBusinessMessageToTargetId:(NSString *)targetId completion:(void(^)(BOOL ok))completion {
    if (!targetId || targetId.length < 5 || !self.latestHTTPHeaders[@"token"]) {
        if (completion) completion(NO);
        return;
    }
    @try {
        NSURL *url = [NSURL URLWithString:@"https://apiv1.airchat.cc/client/biz/v2/business/reply/offline/send"];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"POST";
        [self.latestHTTPHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
            [req setValue:v forHTTPHeaderField:k];
        }];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"businessUserId": targetId} options:0 error:nil];
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            NSDictionary *resp = ACSafeDict([NSJSONSerialization JSONObjectWithData:d options:0 error:nil]);
            BOOL success = ([ACSafeStr(resp[@"code"]) integerValue] == 200);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
        }] resume];
    } @catch (NSException *e) {
        if (completion) completion(NO);
    }
}

- (void)sendText:(NSString *)text mediaSlot:(ACMediaSlot)slot attachMedia:(BOOL)attachMedia toItem:(ACContactItem *)item completion:(void(^)(BOOL ok, NSString *detail))completion {
    NSInteger mType = attachMedia ? [self mediaTypeForSlot:slot] : 0;
    NSString *mPath = (mType == 1) ? [self imagePathForSlot:slot] : ((mType == 2) ? [self videoPathForSlot:slot] : @"");
    NSString *tPath = (mType == 2) ? [self videoThumbPathForSlot:slot] : @"";
    int vDur = (mType == 2) ? [self videoDurationForSlot:slot] : 0;
    [self sendText:text customMediaType:mType customMediaPath:mPath customThumbPath:tPath customVideoDuration:vDur toItem:item completion:completion];
}

- (void)sendText:(NSString *)text customMediaType:(NSInteger)mType customMediaPath:(NSString *)mPath customThumbPath:(NSString *)tPath customVideoDuration:(int)vDur toItem:(ACContactItem *)item completion:(void(^)(BOOL ok, NSString *detail))completion {
    @try {
        Class v2MgrCls = NSClassFromString(@"V2TIMManager");
        id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));
        NSFileManager *fm = [NSFileManager defaultManager];
        id v2MediaMsg = nil;
        if (mType == 1 && mPath.length > 0 && [fm fileExistsAtPath:mPath]) {
            SEL createImgSel = NSSelectorFromString(@"createImageMessage:");
            if ([manager respondsToSelector:createImgSel]) v2MediaMsg = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createImgSel, mPath);
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
                __unsafe_unretained id tempVid = nil;
                [inv getReturnValue:&tempVid];
                v2MediaMsg = tempVid;
            }
        }
        NSString *cleanText = [ACSafeStr(text) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *obfuscatedText = cleanText.length > 0 ? [NSString stringWithFormat:@"%@ ~", cleanText] : @"";
        id v2TextMsg = nil;
        if (obfuscatedText.length > 0) {
            SEL createTextSel = NSSelectorFromString(@"createTextMessage:");
            if ([manager respondsToSelector:createTextSel]) v2TextMsg = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createTextSel, obfuscatedText);
        }
        id primaryMsg = v2MediaMsg ?: v2TextMsg;
        if (!primaryMsg) {
            if (completion) completion(NO, @"内容为空");
            return;
        }

        SEL sendMsgSel = NSSelectorFromString(@"sendMessage:receiver:groupID:priority:onlineUserOnly:offlinePushInfo:progress:succ:fail:");
        if (![manager respondsToSelector:sendMsgSel]) {
            if (completion) completion(NO, @"IM通道异常");
            return;
        }

        NSString *receiver = (item.sourceType == 2) ? nil : item.targetId;
        NSString *groupID = (item.sourceType == 2) ? item.targetId : nil;
        void (^succBlock)(void) = ^{ if (completion) completion(YES, @"送达"); };
        void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) {
            // IM 通道因权限失败时（如 120001），立刻降级触发商务离线发送通道
            [self sendOfflineBusinessMessageToTargetId:item.targetId completion:^(BOOL bOk) {
                if (bOk) {
                    if (completion) completion(YES, @"商务通道破盾送达");
                } else {
                    if (completion) completion(NO, [NSString stringWithFormat:@"(%d)%@", code, desc ?: @"发信拦截"]);
                }
            }];
        };

        NSMethodSignature *sig = [manager methodSignatureForSelector:sendMsgSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:manager];
        [inv setSelector:sendMsgSel];
        [inv setArgument:&primaryMsg atIndex:2];
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
        if (completion) completion(NO, @"发送异常");
    }
}

- (void)addFriendWithId:(NSString *)uid name:(NSString *)name tag:(NSString *)tag chatMeType:(NSInteger)chatMeType {
    NSString *cleanId = [ACSafeStr(uid) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 5 || [cleanId isEqualToString:self.selfUserId]) return;
    NSString *cleanName = ACSafeStr(name);
    @synchronized (self) {
        ACContactItem *existing = self.friendMap[cleanId];
        if (existing) {
            if (cleanName.length > 0 && [existing.name hasPrefix:@"用户_"]) existing.name = cleanName;
            existing.chatMeType = chatMeType;
            return;
        }
        ACContactItem *item = [[ACContactItem alloc] init];
        item.targetId = cleanId;
        item.name = cleanName.length > 0 ? cleanName : [NSString stringWithFormat:@"用户_%@", [cleanId substringFromIndex:MAX(0, (int)cleanId.length - 4)]];
        item.roleDesc = tag ?: @"好友";
        item.sourceType = 0;
        item.chatMeType = chatMeType;
        self.friendMap[cleanId] = item;
        [self.friendList insertObject:item atIndex:0];
    }
}
@end

#pragma mark - 3. UI 界面与操作面板
@interface ACForwardAssistantVC : UIViewController <UITableViewDelegate, UITableViewDataSource, UINavigationControllerDelegate, UIImagePickerControllerDelegate, UITextViewDelegate>
@property (nonatomic, strong) UIView *headerContainer;
@property (nonatomic, strong) UITextView *contentTextView;
@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, strong) UIButton *pickMediaBtn;
@property (nonatomic, strong) UIButton *clearMediaBtn;
@property (nonatomic, strong) UILabel *mediaBadgeLabel;
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, strong) UIView *autoReplyBar;
@property (nonatomic, strong) UISwitch *autoReplySwitch;
@property (nonatomic, strong) UIView *momentTaskBar;
@property (nonatomic, strong) UISwitch *momentSwitch;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIButton *floatingSendBtn;
@end

@implementation ACForwardAssistantVC
- (ACMediaSlot)currentActiveMediaSlot {
    NSInteger idx = self.tabControl ? self.tabControl.selectedSegmentIndex : 0;
    if (idx == 3) return ACMediaSlotWelcome;
    if (idx == 4) return ACMediaSlotAutoReply;
    if (idx == 5) return ACMediaSlotMoment;
    return ACMediaSlotBatchSend;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"全能助手 (频控保护+破盾版)";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(dismissSelf)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onStatusUpdateNotification) name:@"ACWelcomeStatusUpdated" object:nil];
    [self setupCleanUI];
    [self refreshMediaPreviewUI];
    [self updateUI];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)onStatusUpdateNotification {
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    NSInteger idx = self.tabControl.selectedSegmentIndex;
    if (idx == 4) { self.statusLabel.textColor = [UIColor systemGreenColor]; self.statusLabel.text = mgr.lastAutoReplyLog; }
    else if (idx == 5) { self.statusLabel.textColor = [UIColor systemGreenColor]; self.statusLabel.text = mgr.lastMomentLog; [self.tableView reloadData]; }
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
    self.contentTextView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.contentTextView.layer.cornerRadius = 12;
    self.contentTextView.text = @"您好，认识一下！";
    [self.headerContainer addSubview:self.contentTextView];
    
    self.previewImageView = [[UIImageView alloc] initWithFrame:CGRectMake(width - 16 - imgBoxW, 18, imgBoxW, 84)];
    self.previewImageView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.previewImageView.layer.cornerRadius = 12;
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
    
    self.clearMediaBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.clearMediaBtn.frame = CGRectMake(imgBoxW - 24, 2, 22, 22);
    self.clearMediaBtn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.65];
    self.clearMediaBtn.layer.cornerRadius = 11;
    [self.clearMediaBtn setTitle:@"✕" forState:UIControlStateNormal];
    self.clearMediaBtn.hidden = YES;
    [self.clearMediaBtn addTarget:self action:@selector(clearSelectedMedia) forControlEvents:UIControlEventTouchUpInside];
    [self.previewImageView addSubview:self.clearMediaBtn];
    
    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"好友", @"群员", @"群聊", @"迎新", @"自动回复", @"定时动态"]];
    self.tabControl.frame = CGRectMake(12, 114, width - 24, 34);
    self.tabControl.selectedSegmentIndex = 4; // 默认打开自动回复
    [self.tabControl addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    [self.headerContainer addSubview:self.tabControl];
    
    self.autoReplyBar = [[UIView alloc] initWithFrame:CGRectMake(16, 156, width - 32, 38)];
    self.autoReplyBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.autoReplyBar.layer.cornerRadius = 10;
    UILabel *arLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, 145, 38)];
    arLabel.font = [UIFont boldSystemFontOfSize:12];
    arLabel.text = @"💬 自动回复 (含*通配)";
    [self.autoReplyBar addSubview:arLabel];
    UIButton *addRuleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    addRuleBtn.frame = CGRectMake(width - 32 - 148, 5, 84, 28);
    [addRuleBtn setTitle:@"➕添加规则" forState:UIControlStateNormal];
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
    UIButton *addMomentBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    addMomentBtn.frame = CGRectMake(width - 32 - 148, 5, 84, 28);
    [addMomentBtn setTitle:@"➕添加动态" forState:UIControlStateNormal];
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
    [self.headerContainer addSubview:self.statusLabel];
    
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = 58.0;
    [self.view addSubview:self.tableView];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;
    CGFloat topOffset = self.view.safeAreaInsets.top;
    self.headerContainer.frame = CGRectMake(0, topOffset, width, 232.0);
    CGFloat tableY = topOffset + 232.0;
    self.tableView.frame = CGRectMake(0, tableY, width, height - tableY);
}

- (void)refreshMediaPreviewUI {
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    ACMediaSlot slot = [self currentActiveMediaSlot];
    NSInteger mType = [mgr mediaTypeForSlot:slot];
    UIImage *previewImg = [mgr previewImageForSlot:slot];
    if (previewImg) {
        self.previewImageView.image = previewImg;
        [self.pickMediaBtn setTitle:@"" forState:UIControlStateNormal];
        self.clearMediaBtn.hidden = NO;
    } else {
        self.previewImageView.image = nil;
        [self.pickMediaBtn setTitle:@"点此上传\n独立媒体" forState:UIControlStateNormal];
        self.clearMediaBtn.hidden = YES;
    }
}

- (void)autoReplySwitchChanged:(UISwitch *)sw {
    ACForwardHelperManager.shared.autoReplyEnabled = sw.isOn;
    [ACForwardHelperManager.shared saveAllCustomSettings];
    [self updateUI];
}
- (void)momentSwitchChanged:(UISwitch *)sw {
    ACForwardHelperManager.shared.autoMomentEnabled = sw.isOn;
    [ACForwardHelperManager.shared saveAllCustomSettings];
    [ACForwardHelperManager.shared restartMomentScheduler];
    [self updateUI];
}
- (void)addAutoReplyRuleFromInput {
    NSString *raw = [self.contentTextView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw.length == 0) return;
    ACForwardHelperManager *mgr = ACForwardHelperManager.shared;
    ACAutoReplyRule *rule = [[ACAutoReplyRule alloc] init];
    rule.ruleId = [[NSUUID UUID] UUIDString];
    rule.attachMedia = YES;
    rule.enabled = YES;
    
    NSRange eqRange = [raw rangeOfString:@"="];
    if (eqRange.location == NSNotFound) eqRange = [raw rangeOfString:@"＝"];
    if (eqRange.location != NSNotFound && eqRange.location > 0) {
        rule.keyword = [[raw substringToIndex:eqRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        rule.replyText = [[raw substringFromIndex:eqRange.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } else {
        rule.keyword = @"*"; // 允许全量通配匹配任意来信
        rule.replyText = raw;
    }
    [mgr.autoReplyRules insertObject:rule atIndex:0];
    [mgr saveAllCustomSettings];
    self.contentTextView.text = @"";
    self.statusLabel.textColor = [UIColor systemGreenColor];
    self.statusLabel.text = [NSString stringWithFormat:@"✅ 已添加规则: [%@]", rule.keyword];
    [self.tableView reloadData];
}

- (void)addMomentTaskFromInput {
    NSString *raw = [self.contentTextView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw.length == 0) return;
    ACForwardHelperManager *mgr = ACForwardHelperManager.shared;
    ACMomentTaskItem *task = [[ACMomentTaskItem alloc] init];
    task.taskId = [[NSUUID UUID] UUIDString];
    task.contentText = raw;
    task.capturedMediaList = mgr.latestCapturedMomentMediaList;
    task.enabled = YES;
    [mgr.momentTasks insertObject:task atIndex:0];
    [mgr saveAllCustomSettings];
    self.contentTextView.text = @"";
    self.statusLabel.textColor = [UIColor systemGreenColor];
    self.statusLabel.text = @"✅ 动态任务已添加";
    [self.tableView reloadData];
}

- (void)chooseMediaFromAlbum {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[@"public.image", @"public.movie"];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    ACMediaSlot slot = [self currentActiveMediaSlot];
    NSString *mediaType = info[UIImagePickerControllerMediaType];
    if ([mediaType isEqualToString:@"public.movie"]) {
        NSURL *url = info[UIImagePickerControllerMediaURL];
        if (url) [[ACForwardHelperManager shared] saveVideoAtURL:url forSlot:slot];
    } else {
        UIImage *img = info[UIImagePickerControllerOriginalImage];
        if (img) [[ACForwardHelperManager shared] saveImage:img forSlot:slot];
    }
    [self refreshMediaPreviewUI];
    [picker dismissViewControllerAnimated:YES completion:nil];
}
- (void)clearSelectedMedia {
    [[ACForwardHelperManager shared] clearMediaForSlot:[self currentActiveMediaSlot]];
    [self refreshMediaPreviewUI];
}

- (void)tabChanged {
    NSInteger idx = self.tabControl.selectedSegmentIndex;
    self.autoReplyBar.hidden = (idx != 4);
    self.momentTaskBar.hidden = (idx != 5);
    [self refreshMediaPreviewUI];
    [self updateUI];
    [self.tableView reloadData];
}

- (void)updateUI {
    ACForwardHelperManager *mgr = ACForwardHelperManager.shared;
    [self.tabControl setTitle:[NSString stringWithFormat:@"💬回复(%@)", mgr.autoReplyEnabled ? @"开" : @"关"] forSegmentAtIndex:4];
    [self.tabControl setTitle:[NSString stringWithFormat:@"📝动态(%@)", mgr.autoMomentEnabled ? @"开" : @"关"] forSegmentAtIndex:5];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    ACForwardHelperManager *mgr = ACForwardHelperManager.shared;
    if (self.tabControl.selectedSegmentIndex == 4) return mgr.autoReplyRules.count;
    if (self.tabControl.selectedSegmentIndex == 5) return mgr.momentTasks.count;
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"Cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    ACForwardHelperManager *mgr = ACForwardHelperManager.shared;
    if (self.tabControl.selectedSegmentIndex == 4) {
        ACAutoReplyRule *rule = mgr.autoReplyRules[indexPath.row];
        cell.textLabel.text = [NSString stringWithFormat:@"🔑 [%@] %@", rule.keyword, rule.replyText];
        cell.detailTextLabel.text = rule.enabled ? @"🟢 规则启用中" : @"⚪ 已暂停";
        return cell;
    }
    if (self.tabControl.selectedSegmentIndex == 5) {
        ACMomentTaskItem *task = mgr.momentTasks[indexPath.row];
        cell.textLabel.text = [NSString stringWithFormat:@"📝 %@", task.contentText];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"已发 %ld 次 | 状态: %@", (long)task.sentCount, task.lastSentTimeStr];
        UIButton *pubNowBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        pubNowBtn.frame = CGRectMake(0, 0, 58, 28);
        [pubNowBtn setTitle:@"立即发" forState:UIControlStateNormal];
        pubNowBtn.backgroundColor = [UIColor systemGreenColor];
        [pubNowBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        pubNowBtn.layer.cornerRadius = 6;
        pubNowBtn.tag = indexPath.row;
        [pubNowBtn addTarget:self action:@selector(publishSingleMomentTaskNow:) forControlEvents:UIControlEventTouchUpInside];
        cell.accessoryView = pubNowBtn;
        return cell;
    }
    return cell;
}

- (void)publishSingleMomentTaskNow:(UIButton *)sender {
    ACForwardHelperManager *mgr = ACForwardHelperManager.shared;
    if (sender.tag < 0 || sender.tag >= mgr.momentTasks.count) return;
    ACMomentTaskItem *task = mgr.momentTasks[sender.tag];
    self.statusLabel.textColor = [UIColor systemBlueColor];
    self.statusLabel.text = @"⏳ 正在发送动态...";
    [mgr publishMomentTask:task completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ACForwardHelperManager *mgr = ACForwardHelperManager.shared;
    if (self.tabControl.selectedSegmentIndex == 4) {
        mgr.autoReplyRules[indexPath.row].enabled = !mgr.autoReplyRules[indexPath.row].enabled;
        [mgr saveAllCustomSettings];
    } else if (self.tabControl.selectedSegmentIndex == 5) {
        mgr.momentTasks[indexPath.row].enabled = !mgr.momentTasks[indexPath.row].enabled;
        [mgr saveAllCustomSettings];
    }
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

#pragma mark - 4. 核心 Hook 与深度消息拦截注入
%hook V2TIMManager
- (void)addAdvancedMsgListener:(id)listener {
    %orig;
    // 强制把插件管理器追加进监听队列，防止原生覆盖我们的监听通道
    [[ACForwardHelperManager shared] registerTIMListenersExplicitly];
}
%end

%hook TUICore
+ (void)initialize {
    %orig;
    [[ACForwardHelperManager shared] registerTIMListenersExplicitly];
}
%end

// 双重挂钩：无论原生层如何接收，均拦截下私信并派发自动回复
%hook NSObject
- (void)onRecvNewMessage:(id)msg {
    %orig;
    [[ACForwardHelperManager shared] dispatchIncomingPrivateMessage:msg];
}
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSString *urlStr = request.URL.absoluteString;
    if ([urlStr containsString:@"apiv1.airchat.cc"] && request.allHTTPHeaderFields) {
        NSDictionary *headers = request.allHTTPHeaderFields;
        ACForwardHelperManager *mgr = ACForwardHelperManager.shared;
        [headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
            if ([k isKindOfClass:[NSString class]] && [v isKindOfClass:[NSString class]]) {
                mgr.latestHTTPHeaders[k] = v;
                if ([k.lowercaseString isEqualToString:@"x-userid"] && v.length > 5) mgr.selfUserId = v;
            }
        }];
    }
    return %orig;
}
%end

%hook NSMutableURLRequest
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    %orig;
    if (field && value && [field isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) {
        NSString *lower = field.lowercaseString;
        if ([lower isEqualToString:@"token"] || [lower isEqualToString:@"x-userid"] || [lower isEqualToString:@"x-lts-id"] || [lower isEqualToString:@"x-request-no"]) {
            ACForwardHelperManager.shared.latestHTTPHeaders[field] = value;
        }
    }
}
%end

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @try {
        [[ACForwardHelperManager shared] registerTIMListenersExplicitly];
        NSString *cls = NSStringFromClass([self class]);
        if ([cls containsString:@"HelpAboutViewController"] && self.navigationItem) {
            self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"🚀 转发助手" style:UIBarButtonItemStyleDone target:self action:@selector(ac_openFromAbout)];
        }
    } @catch (NSException *e) {}
}
%new
- (void)ac_openFromAbout {
    UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
    UIViewController *topVC = keyWin.rootViewController;
    while (topVC.presentedViewController) topVC = topVC.presentedViewController;
    ACForwardAssistantVC *vc = [[ACForwardAssistantVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [topVC presentViewController:nav animated:YES completion:nil];
}
%end
