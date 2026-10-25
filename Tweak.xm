#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

#pragma mark - 1. 数据模型

@interface ACContactItem : NSObject <NSCoding>
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *fromGroupId;
@property (nonatomic, copy) NSString *roleDesc;
@property (nonatomic, assign) NSInteger sourceType; // 0: 好友, 1: 群成员, 2: 群聊
@property (nonatomic, assign) NSInteger chatMeType; // 0: 开放私聊, 1: 仅双向好友
@property (nonatomic, assign) BOOL isGroupBanned;   
@property (nonatomic, assign) BOOL isSelected;
@end

@implementation ACContactItem

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.targetId ?: @"" forKey:@"targetId"];
    [coder encodeObject:self.name ?: @"" forKey:@"name"];
    [coder encodeObject:self.fromGroupId ?: @"" forKey:@"fromGroupId"];
    [coder encodeObject:self.roleDesc ?: @"" forKey:@"roleDesc"];
    [coder encodeInteger:self.sourceType forKey:@"sourceType"];
    [coder encodeInteger:self.chatMeType forKey:@"chatMeType"];
    [coder encodeBool:self.isGroupBanned forKey:@"isGroupBanned"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        self.targetId = [coder decodeObjectForKey:@"targetId"];
        self.name = [coder decodeObjectForKey:@"name"];
        self.fromGroupId = [coder decodeObjectForKey:@"fromGroupId"];
        self.roleDesc = [coder decodeObjectForKey:@"roleDesc"];
        self.sourceType = [coder decodeIntegerForKey:@"sourceType"];
        self.chatMeType = [coder decodeIntegerForKey:@"chatMeType"];
        self.isGroupBanned = [coder decodeBoolForKey:@"isGroupBanned"];
        self.isSelected = NO;
    }
    return self;
}

@end

// 定时发动态任务模型
@interface ACPostTask : NSObject <NSCoding>
@property (nonatomic, copy) NSString *taskName;
@property (nonatomic, copy) NSString *content;
@property (nonatomic, assign) NSInteger intervalSeconds;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) NSTimeInterval lastExecutedTime;
@end

@implementation ACPostTask

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.taskName ?: @"" forKey:@"taskName"];
    [coder encodeObject:self.content ?: @"" forKey:@"content"];
    [coder encodeInteger:self.intervalSeconds forKey:@"intervalSeconds"];
    [coder encodeBool:self.enabled forKey:@"enabled"];
    [coder encodeDouble:self.lastExecutedTime forKey:@"lastExecutedTime"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        self.taskName = [coder decodeObjectForKey:@"taskName"];
        self.content = [coder decodeObjectForKey:@"content"];
        self.intervalSeconds = [coder decodeIntegerForKey:@"intervalSeconds"];
        self.enabled = [coder decodeBoolForKey:@"enabled"];
        self.lastExecutedTime = [coder decodeDoubleForKey:@"lastExecutedTime"];
    }
    return self;
}

@end

static __weak UIView *__lastLongPressedView = nil;
static NSString *__pendingForwardText = nil;
static NSString *__currentChatPeerId = nil;

#pragma mark - 2. 核心管理器

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

// --- 永久保存的媒体 ---
@property (nonatomic, assign) NSInteger savedMediaType; // 0: 无, 1: 图片, 2: 视频
@property (nonatomic, strong) UIImage *savedImage;
@property (nonatomic, assign) int savedVideoDuration;

// --- 迎新配置 ---
@property (nonatomic, assign) BOOL autoWelcomeEnabled;
@property (nonatomic, copy) NSString *welcomeMessageText;
@property (nonatomic, strong) NSMutableSet<NSString *> *welcomeGroupIds;
@property (nonatomic, strong) NSMutableSet<NSString *> *greetedUserIds;
@property (nonatomic, assign) NSInteger greetedCount;
@property (nonatomic, copy) NSString *lastGreetLog;
@property (nonatomic, assign) BOOL listenerRegistered;

// --- 1. 自动回复配置 ---
@property (nonatomic, assign) BOOL autoReplyEnabled;
@property (nonatomic, copy) NSString *autoReplyText;
@property (nonatomic, strong) NSMutableSet<NSString *> *repliedMsgIds;

// --- 2. 多任务定时发动态配置 ---
@property (nonatomic, assign) BOOL autoPostEnabled;
@property (nonatomic, strong) NSMutableArray<ACPostTask *> *postTasks;

// --- 3. 全局后台调度器与保活定时器 ---
@property (nonatomic, strong) NSTimer *globalSchedulerTimer;

+ (instancetype)shared;
- (NSString *)permanentImagePath;
- (NSString *)permanentVideoPath;
- (NSString *)permanentVideoThumbPath;
- (void)savePermanentImage:(UIImage *)img;
- (void)savePermanentVideoAtURL:(NSURL *)videoURL;
- (void)clearPermanentMedia;

- (void)setupIMGroupWelcomeListener;
- (void)loadLocalPermanentCache;
- (void)saveLocalPermanentCache;
- (void)clearAllGroupMembersCache;
- (void)saveWelcomeSettings;
- (void)saveAutoReplyAndPostSettings;
- (void)loadAutoReplyAndPostSettings;
- (void)publishDynamicWithContent:(NSString *)content completion:(void(^)(BOOL ok, NSString *msg))completion;

- (void)parseJSONWithContext:(id)jsonObj;
- (void)reloadSelectedGroupsData:(NSArray<NSString *> *)targetGroupIds
                        progress:(void(^)(NSString *progressMsg))progressBlock
                      completion:(void(^)(NSString *finalMsg))completion;
- (void)reloadAllDataWithProgress:(void(^)(NSString *progressMsg))progressBlock
                       completion:(void(^)(NSString *finalMsg))completion;
- (void)sendCurrentMediaAndText:(NSString *)text
                         toItem:(ACContactItem *)item
                     completion:(void(^)(BOOL ok, NSString *detail))completion;
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
        instance.selfUserId = @"1958179249315647489";
        instance.capturedClientTypeV2 = @"79b3h7aOxJurSbzVhPK2Wal1cKQzfppVutid7[d]gEtuxYU87uiCm3l2gMp7d5Eo3KZS3hFxBn8Db[d]yag55Ev1I3W[a]7xF6oF0FSXM[s]";

        instance.welcomeGroupIds = [NSMutableSet set];
        instance.greetedUserIds = [NSMutableSet set];
        instance.repliedMsgIds = [NSMutableSet set];
        instance.postTasks = [NSMutableArray array];
        instance.lastGreetLog = @"等待系统调度...";

        [instance loadLocalPermanentCache];
        [instance loadWelcomeSettings];
        [instance loadAutoReplyAndPostSettings];
        [instance loadPermanentMediaFromDisk];
        [instance startGlobalSchedulerTimer];
    });
    return instance;
}

#pragma mark - 2.0 全局后台定时任务调度器 (在线保活心跳 + 多任务定时发动态)

- (void)startGlobalSchedulerTimer {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.globalSchedulerTimer) return;
        self.globalSchedulerTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 target:self selector:@selector(onSchedulerTick) userInfo:nil repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:self.globalSchedulerTimer forMode:NSRunLoopCommonModes];
    });
}

- (void)onSchedulerTick {
    // 1. 在线心跳保活请求
    [self updateOnlineTimeHeartbeat];
    
    // 2. 检查并执行多任务定时发动态
    [self checkAndExecutePostTasks];
}

- (void)updateOnlineTimeHeartbeat {
    if (!self.latestHTTPHeaders[@"token"]) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://apiv1.airchat.cc/client/clientuser/updateOnlineTime"]];
    req.HTTPMethod = @"GET";
    [self.latestHTTPHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        [req setValue:v forHTTPHeaderField:k];
    }];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:nil] resume];
}

- (void)publishDynamicWithContent:(NSString *)content completion:(void(^)(BOOL ok, NSString *msg))completion {
    if (!content || content.length == 0 || !self.latestHTTPHeaders[@"token"]) {
        if (completion) completion(NO, @"Token或发布内容为空");
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://apiv1.airchat.cc/airchat/c/post/publish"]];
    req.HTTPMethod = @"POST";
    [self.latestHTTPHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        [req setValue:v forHTTPHeaderField:k];
    }];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{@"content": content, @"mediaUrls": @[], @"type": @0};
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!e && d) {
            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if ([dict[@"code"] integerValue] == 200) {
                if (completion) completion(YES, @"动态发布成功");
                return;
            }
        }
        if (completion) completion(NO, e.localizedDescription ?: @"发布失败");
    }] resume];
}

- (void)checkAndExecutePostTasks {
    if (!self.autoPostEnabled) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    @synchronized (self.postTasks) {
        for (ACPostTask *task in self.postTasks) {
            if (task.enabled && task.content.length > 0 && task.intervalSeconds > 0) {
                if (now - task.lastExecutedTime >= task.intervalSeconds) {
                    task.lastExecutedTime = now;
                    [self saveAutoReplyAndPostSettings];
                    [self publishDynamicWithContent:task.content completion:^(BOOL ok, NSString *msg) {
                        if (ok) {
                            self.lastGreetLog = [NSString stringWithFormat:@"📢 [定时动态] 成功发布: %@", task.taskName];
                        } else {
                            self.lastGreetLog = [NSString stringWithFormat:@"⚠️ [定时动态] 发布失败(%@): %@", task.taskName, msg];
                        }
                        [[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
                    }];
                }
            }
        }
    }
}

#pragma mark - 2.1 媒体与缓存持久化

- (NSString *)permanentImagePath {
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [docDir stringByAppendingPathComponent:@"AC_Permanent_Media.jpg"];
}

- (NSString *)permanentVideoPath {
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [docDir stringByAppendingPathComponent:@"AC_Permanent_Media.mp4"];
}

- (NSString *)permanentVideoThumbPath {
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [docDir stringByAppendingPathComponent:@"AC_Permanent_VideoThumb.jpg"];
}

- (void)loadPermanentMediaFromDisk {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    self.savedMediaType = [ud integerForKey:@"AC_SavedMediaType"];
    self.savedVideoDuration = (int)[ud integerForKey:@"AC_SavedVideoDuration"];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (self.savedMediaType == 1 && [fm fileExistsAtPath:[self permanentImagePath]]) {
        self.savedImage = [UIImage imageWithContentsOfFile:[self permanentImagePath]];
    } else if (self.savedMediaType == 2 && [fm fileExistsAtPath:[self permanentVideoPath]]) {
        if ([fm fileExistsAtPath:[self permanentVideoThumbPath]]) {
            self.savedImage = [UIImage imageWithContentsOfFile:[self permanentVideoThumbPath]];
        }
    } else {
        self.savedMediaType = 0;
        self.savedImage = nil;
    }
}

- (void)savePermanentImage:(UIImage *)img {
    if (!img) return;
    NSData *jpgData = UIImageJPEGRepresentation(img, 0.88);
    if (jpgData) {
        [jpgData writeToFile:[self permanentImagePath] atomically:YES];
        [[NSFileManager defaultManager] removeItemAtPath:[self permanentVideoPath] error:nil];
        self.savedImage = img;
        self.savedMediaType = 1;
        self.savedVideoDuration = 0;

        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setInteger:1 forKey:@"AC_SavedMediaType"];
        [ud setInteger:0 forKey:@"AC_SavedVideoDuration"];
        [ud synchronize];
    }
}

- (void)savePermanentVideoAtURL:(NSURL *)videoURL {
    if (!videoURL) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *destVideoPath = [self permanentVideoPath];
    [fm removeItemAtPath:destVideoPath error:nil];
    [fm removeItemAtPath:[self permanentImagePath] error:nil];

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
    if (thumbData) {
        [thumbData writeToFile:[self permanentVideoThumbPath] atomically:YES];
    }

    self.savedImage = thumbImg;
    self.savedMediaType = 2;
    self.savedVideoDuration = durationSec;

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setInteger:2 forKey:@"AC_SavedMediaType"];
    [ud setInteger:durationSec forKey:@"AC_SavedVideoDuration"];
    [ud synchronize];
}

- (void)clearPermanentMedia {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:[self permanentImagePath] error:nil];
    [fm removeItemAtPath:[self permanentVideoPath] error:nil];
    [fm removeItemAtPath:[self permanentVideoThumbPath] error:nil];
    self.savedMediaType = 0;
    self.savedImage = nil;
    self.savedVideoDuration = 0;

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setInteger:0 forKey:@"AC_SavedMediaType"];
    [ud setInteger:0 forKey:@"AC_SavedVideoDuration"];
    [ud synchronize];
}

- (NSString *)cacheFilePath:(NSString *)type {
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [docDir stringByAppendingPathComponent:[NSString stringWithFormat:@"AC_Permanent_%@.archive", type]];
}

- (void)clearAllGroupMembersCache {
    @synchronized (self) {
        [self.groupMemberList removeAllObjects];
        [self.groupMemberMap removeAllObjects];
        [[NSFileManager defaultManager] removeItemAtPath:[self cacheFilePath:@"members"] error:nil];
        [self saveLocalPermanentCache];
    }
}

- (void)saveWelcomeSettings {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:self.autoWelcomeEnabled forKey:@"AC_AutoWelcome_Enabled"];
    [ud setObject:self.welcomeMessageText ?: @"您好 {name}，欢迎进群！认识一下~" forKey:@"AC_AutoWelcome_Text"];
    [ud setObject:[self.welcomeGroupIds allObjects] forKey:@"AC_AutoWelcome_Groups"];
    if (self.capturedClientTypeV2) {
        [ud setObject:self.capturedClientTypeV2 forKey:@"AC_Captured_ClientTypeV2"];
    }
    [ud synchronize];
}

- (void)loadWelcomeSettings {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    self.autoWelcomeEnabled = [ud boolForKey:@"AC_AutoWelcome_Enabled"];
    NSString *savedText = [ud stringForKey:@"AC_AutoWelcome_Text"];
    self.welcomeMessageText = (savedText && savedText.length > 0) ? savedText : @"您好 {name}，欢迎进群！认识一下~";
    NSArray *savedGroups = [ud arrayForKey:@"AC_AutoWelcome_Groups"];
    if ([savedGroups isKindOfClass:[NSArray class]]) {
        [self.welcomeGroupIds addObjectsFromArray:savedGroups];
    }
    NSString *savedV2 = [ud stringForKey:@"AC_Captured_ClientTypeV2"];
    if (savedV2 && savedV2.length > 10) {
        self.capturedClientTypeV2 = savedV2;
    }
}

- (void)saveAutoReplyAndPostSettings {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:self.autoReplyEnabled forKey:@"AC_AutoReply_Enabled"];
    [ud setObject:self.autoReplyText ?: @"您好！我现在正在忙，看到消息后会第一时间回复您~" forKey:@"AC_AutoReply_Text"];
    [ud setBool:self.autoPostEnabled forKey:@"AC_AutoPost_Enabled"];

    @try {
        NSData *tasksData = [NSKeyedArchiver archivedDataWithRootObject:[self.postTasks copy] requiringSecureCoding:NO error:nil];
        if (tasksData) [ud setObject:tasksData forKey:@"AC_PostTasks_Data"];
    } @catch (NSException *e) {}

    [ud synchronize];
}

- (void)loadAutoReplyAndPostSettings {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    self.autoReplyEnabled = [ud boolForKey:@"AC_AutoReply_Enabled"];
    NSString *replyTxt = [ud stringForKey:@"AC_AutoReply_Text"];
    self.autoReplyText = (replyTxt && replyTxt.length > 0) ? replyTxt : @"您好！我现在正在忙，看到消息后会第一时间回复您~";
    self.autoPostEnabled = [ud boolForKey:@"AC_AutoPost_Enabled"];

    NSData *tasksData = [ud objectForKey:@"AC_PostTasks_Data"];
    if (tasksData) {
        @try {
            NSArray *arr = [NSKeyedUnarchiver unarchiveObjectWithData:tasksData];
            if ([arr isKindOfClass:[NSArray class]]) {
                [self.postTasks addObjectsFromArray:arr];
            }
        } @catch (NSException *e) {}
    }

    if (self.postTasks.count == 0) {
        ACPostTask *t1 = [[ACPostTask alloc] init];
        t1.taskName = @"任务1-早间动态";
        t1.content = @"大家早上好！新的一天加油！";
        t1.intervalSeconds = 3600;
        t1.enabled = YES;

        ACPostTask *t2 = [[ACPostTask alloc] init];
        t2.taskName = @"任务2-日常业务推广";
        t2.content = @"专业业务对接，欢迎私信咨询！";
        t2.intervalSeconds = 7200;
        t2.enabled = YES;

        [self.postTasks addObject:t1];
        [self.postTasks addObject:t2];
        [self saveAutoReplyAndPostSettings];
    }
}

- (void)saveLocalPermanentCache {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @synchronized (self) {
            @try {
                NSData *fData = [NSKeyedArchiver archivedDataWithRootObject:[self.friendList copy] requiringSecureCoding:NO error:nil];
                NSData *mData = [NSKeyedArchiver archivedDataWithRootObject:[self.groupMemberList copy] requiringSecureCoding:NO error:nil];
                NSData *gData = [NSKeyedArchiver archivedDataWithRootObject:[self.groupList copy] requiringSecureCoding:NO error:nil];
                if (fData) [fData writeToFile:[self cacheFilePath:@"friends"] atomically:YES];
                if (mData) [mData writeToFile:[self cacheFilePath:@"members"] atomically:YES];
                if (gData) [gData writeToFile:[self cacheFilePath:@"groups"] atomically:YES];
            } @catch (NSException *e) {}
        }
    });
}

- (void)loadLocalPermanentCache {
    @synchronized (self) {
        @try {
            NSArray *fArr = [NSKeyedUnarchiver unarchiveObjectWithFile:[self cacheFilePath:@"friends"]];
            if ([fArr isKindOfClass:[NSArray class]]) {
                for (ACContactItem *item in fArr) {
                    if (item.targetId.length > 0 && !self.friendMap[item.targetId]) {
                        self.friendMap[item.targetId] = item;
                        [self.friendList addObject:item];
                    }
                }
            }
            NSArray *mArr = [NSKeyedUnarchiver unarchiveObjectWithFile:[self cacheFilePath:@"members"]];
            if ([mArr isKindOfClass:[NSArray class]]) {
                for (ACContactItem *item in mArr) {
                    if (item.targetId.length > 0 && !self.groupMemberMap[item.targetId]) {
                        self.groupMemberMap[item.targetId] = item;
                        [self.groupMemberList addObject:item];
                    }
                }
            }
            NSArray *gArr = [NSKeyedUnarchiver unarchiveObjectWithFile:[self cacheFilePath:@"groups"]];
            if ([gArr isKindOfClass:[NSArray class]]) {
                for (ACContactItem *item in gArr) {
                    if (item.targetId.length > 0 && !self.groupMap[item.targetId]) {
                        self.groupMap[item.targetId] = item;
                        [self.groupList addObject:item];
                    }
                }
            }
        } @catch (NSException *e) {}
    }
}

#pragma mark - 2.2 腾讯云 IM 实时监听（迎新 + 自动回复私信）

- (void)setupIMGroupWelcomeListener {
    if (self.listenerRegistered) return;
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
            NSDictionary *cDict = [NSJSONSerialization JSONObjectWithData:cData options:0 error:nil];
            if ([cDict isKindOfClass:[NSDictionary class]] && cDict[@"client_typeV2"]) {
                self.capturedClientTypeV2 = cDict[@"client_typeV2"];
                self.capturedCloudCustomData = cData;
            }
        }

        NSString *groupID = [msg valueForKey:@"groupID"];
        NSString *sender = [msg valueForKey:@"sender"];
        NSString *msgId = [msg valueForKey:@"msgID"] ?: [msg valueForKey:@"id"];

        // 核心新增：私信自动回复机制
        BOOL isC2C = (!groupID || ![groupID isKindOfClass:[NSString class]] || groupID.length == 0);
        if (isC2C && sender && sender.length > 0 && ![sender isEqualToString:self.selfUserId]) {
            if (self.autoReplyEnabled && self.autoReplyText.length > 0) {
                if (msgId && ![self.repliedMsgIds containsObject:msgId]) {
                    [self.repliedMsgIds addObject:msgId];
                    ACContactItem *item = self.friendMap[sender] ?: self.groupMemberMap[sender];
                    if (!item) {
                        item = [[ACContactItem alloc] init];
                        item.targetId = sender;
                        item.name = sender;
                        item.sourceType = 0;
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [self sendCurrentMediaAndText:self.autoReplyText toItem:item completion:^(BOOL ok, NSString *detail) {
                            if (ok) {
                                self.lastGreetLog = [NSString stringWithFormat:@"💬 已自动回复私信给: %@", item.name];
                                [[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
                            }
                        }];
                    });
                }
            }
        }

        if (!isC2C) {
            NSString *nickName = [msg valueForKey:@"nickName"] ?: [msg valueForKey:@"nameCard"];
            if (sender && sender.length > 0) {
                if ([self addGroupMemberWithId:sender name:nickName groupId:groupID role:@"群活跃" chatMeType:0]) {
                    [self saveLocalPermanentCache];
                }
            }

            id tipsElem = [msg valueForKey:@"groupTipsElem"];
            if (tipsElem) {
                NSInteger tipsType = [[tipsElem valueForKey:@"type"] integerValue];
                if (tipsType == 1 || tipsType == 2) {
                    NSArray *memberList = [tipsElem valueForKey:@"memberList"];
                    if ([memberList isKindOfClass:[NSArray class]] && memberList.count > 0) {
                        [self handleNewMembersJoinedGroup:groupID memberList:memberList];
                    }
                }
            }
        }
    } @catch (NSException *e) {}
}

- (void)handleNewMembersJoinedGroup:(NSString *)groupID memberList:(NSArray *)memberList {
    if (!groupID || ![memberList isKindOfClass:[NSArray class]] || memberList.count == 0) return;

    NSMutableArray<ACContactItem *> *newTargetsToGreet = [NSMutableArray array];

    for (id mem in memberList) {
        @try {
            NSString *uid = [mem valueForKey:@"userID"];
            if (!uid || ![uid isKindOfClass:[NSString class]] || uid.length < 5) continue;
            if ([uid isEqualToString:self.selfUserId]) continue;

            NSString *nick = [mem valueForKey:@"nickName"];
            if (!nick || [nick isKindOfClass:[NSNull class]] || nick.length == 0) nick = [mem valueForKey:@"nameCard"];
            if (!nick || [nick isKindOfClass:[NSNull class]] || nick.length == 0) nick = [mem valueForKey:@"friendRemark"];

            [self addGroupMemberWithId:uid name:nick groupId:groupID role:@"新进群" chatMeType:0];

            if (self.autoWelcomeEnabled && [self.welcomeGroupIds containsObject:groupID]) {
                if (![self.greetedUserIds containsObject:uid]) {
                    [self.greetedUserIds addObject:uid];
                    ACContactItem *target = self.groupMemberMap[uid];
                    if (!target) {
                        target = [[ACContactItem alloc] init];
                        target.targetId = uid;
                        target.name = (nick && nick.length > 0) ? nick : uid;
                        target.fromGroupId = groupID;
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

        [weakSelf sendCurrentMediaAndText:finalGreeting toItem:newMember completion:^(BOOL ok, NSString *detail) {
            if (ok) {
                weakSelf.greetedCount++;
                weakSelf.lastGreetLog = [NSString stringWithFormat:@"✅ 已安全迎新: %@ (共%ld人)", newMember.name, (long)weakSelf.greetedCount];
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

#pragma mark - 2.3 联系人与群成员管理

- (void)addFriendWithId:(NSString *)uid name:(NSString *)name tag:(NSString *)tag chatMeType:(NSInteger)chatMeType {
    if (!uid) return;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", uid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 5 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"<null>"] || [cleanId isEqualToString:@"-1"]) return;
    if ([cleanId isEqualToString:self.selfUserId] || [cleanId hasSuffix:@"_collection"] || [cleanId hasPrefix:@"@TGS#"]) return;

    NSString *cleanName = (name && ![name isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", name] : @"";
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
    if (!uid) return NO;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", uid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 5 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"<null>"] || [cleanId isEqualToString:@"-1"] || [cleanId isEqualToString:@"0"]) return NO;
    if ([cleanId isEqualToString:self.selfUserId] || [cleanId hasPrefix:@"@TGS#"]) return NO;

    NSString *cleanName = (name && ![name isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", name] : @"";

    @synchronized (self) {
        ACContactItem *existing = self.groupMemberMap[cleanId];
        if (existing) {
            if (cleanName.length > 0 && ![cleanName isEqualToString:cleanId] && ([existing.name isEqualToString:cleanId] || [existing.name hasPrefix:@"群友_"])) {
                existing.name = cleanName;
            }
            if (gid && gid.length > 0) existing.fromGroupId = gid;
            if (role && role.length > 0) existing.roleDesc = role;
            existing.chatMeType = chatMeType;
            return NO;
        }

        ACContactItem *item = [[ACContactItem alloc] init];
        item.targetId = cleanId;
        item.name = cleanName.length > 0 ? cleanName : [NSString stringWithFormat:@"群友_%@", [cleanId substringFromIndex:MAX(0, (int)cleanId.length - 4)]];
        item.fromGroupId = gid ?: @"";
        item.roleDesc = role ?: @"群成员";
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
    if (!gid) return;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", gid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 3 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"<null>"] || [cleanId isEqualToString:@"0"]) return;
    if (![cleanId hasPrefix:@"@TGS#"] && cleanId.length > 15) return;

    NSString *cleanName = (name && ![name isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", name] : @"";

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
    if (!jsonObj) return;
    if ([jsonObj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)jsonObj;
        if (dict[@"appUserExperienceList"] || dict[@"realityValue"]) return;

        if ([dict[@"objectId"] isKindOfClass:[NSString class]]) {
            NSString *objStr = dict[@"objectId"];
            if ([objStr hasPrefix:@"会话："]) {
                __currentChatPeerId = [objStr substringFromIndex:3];
            }
        }

        if (dict[@"clientUserNickName"] && dict[@"id"] && dict[@"chatMeType"] && ![dict[@"chatMeType"] isKindOfClass:[NSNull class]]) {
            NSString *uid = [NSString stringWithFormat:@"%@", dict[@"id"]];
            NSString *nick = [NSString stringWithFormat:@"%@", dict[@"clientUserNickName"]];
            NSInteger cmType = [[NSString stringWithFormat:@"%@", dict[@"chatMeType"]] integerValue];
            [self addFriendWithId:uid name:nick tag:(cmType == 0 ? @"开放私聊(必达)" : @"限制非好友(chatMe=1)") chatMeType:cmType];
            if (self.groupMemberMap[uid]) {
                self.groupMemberMap[uid].chatMeType = cmType;
                self.groupMemberMap[uid].name = nick;
            }
        }

        if ([dict[@"cloudCustomData"] isKindOfClass:[NSDictionary class]]) {
            NSString *v2Token = dict[@"cloudCustomData"][@"client_typeV2"];
            if (v2Token && [v2Token isKindOfClass:[NSString class]] && v2Token.length > 10) {
                self.capturedClientTypeV2 = v2Token;
            }
        }

        NSString *directId = [NSString stringWithFormat:@"%@", dict[@"id"] ?: @""];
        if ([directId hasPrefix:@"@TGS#"] && dict[@"name"]) {
            BOOL isBan = [[NSString stringWithFormat:@"%@", dict[@"ban"] ?: @"false"] isEqualToString:@"true"];
            [self addGroupWithId:directId name:[NSString stringWithFormat:@"%@", dict[@"name"]] ban:isBan];
            if (dict[@"owner"]) {
                [self addGroupMemberWithId:[NSString stringWithFormat:@"%@", dict[@"owner"]] name:@"群主" groupId:directId role:@"群主" chatMeType:0];
            }
        }

        NSString *groupId = [NSString stringWithFormat:@"%@", dict[@"groupId"] ?: @""];
        if ([groupId hasPrefix:@"@TGS#"]) {
            BOOL isBan = [[NSString stringWithFormat:@"%@", dict[@"ban"] ?: @"false"] isEqualToString:@"true"];
            [self addGroupWithId:groupId name:dict[@"groupName"] ban:isBan];
            if (dict[@"userId"] && [dict[@"userInfo"] isKindOfClass:[NSDictionary class]]) {
                NSDictionary *uInfo = dict[@"userInfo"];
                NSInteger cmType = [[NSString stringWithFormat:@"%@", uInfo[@"chatMeType"] ?: @"0"] integerValue];
                [self addGroupMemberWithId:[NSString stringWithFormat:@"%@", dict[@"userId"]]
                                      name:uInfo[@"clientUserNickName"] ?: dict[@"customName"]
                                   groupId:groupId
                                      role:dict[@"customName"] ?: dict[@"role"] ?: @"群管"
                                chatMeType:cmType];
            }
            if (dict[@"createUser"] && [dict[@"appUserInfo"] isKindOfClass:[NSDictionary class]]) {
                NSDictionary *uInfo = dict[@"appUserInfo"];
                NSInteger cmType = [[NSString stringWithFormat:@"%@", uInfo[@"chatMeType"] ?: @"0"] integerValue];
                [self addGroupMemberWithId:[NSString stringWithFormat:@"%@", uInfo[@"id"] ?: dict[@"createUser"]]
                                      name:uInfo[@"clientUserNickName"]
                                   groupId:groupId
                                      role:@"群活跃"
                                chatMeType:cmType];
            }
        }

        for (id key in dict) {
            id val = dict[key];
            if ([val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSArray class]]) {
                [self parseJSONWithContext:val];
            }
        }
    } else if ([jsonObj isKindOfClass:[NSArray class]]) {
        for (id sub in (NSArray *)jsonObj) {
            [self parseJSONWithContext:sub];
        }
    }
}

#pragma mark - 2.4 群成员拉取

- (void)crawlGroupMembersPageForGroup:(NSString *)gid
                              nextSeq:(uint64_t)seq
                            pageIndex:(NSInteger)pageIdx
                             progress:(void(^)(NSString *msg))progressBlock
                           completion:(void(^)(void))completion {
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
        if ([memberList isKindOfClass:[NSArray class]]) {
            for (id mem in memberList) {
                @try {
                    NSString *uid = [mem valueForKey:@"userID"];
                    NSString *nick = [mem valueForKey:@"nickName"];
                    if (!nick || nick.length == 0) nick = [mem valueForKey:@"nameCard"];
                    if (!nick || nick.length == 0) nick = [mem valueForKey:@"friendRemark"];
                    [weakSelf addGroupMemberWithId:uid name:nick groupId:gid role:@"群成员" chatMeType:0];
                } @catch (NSException *e) {}
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (progressBlock) {
                progressBlock([NSString stringWithFormat:@"⏳ 定向采集(第%ld页)：已获 %lu 人...",
                               (long)(pageIdx + 1), (unsigned long)weakSelf.groupMemberList.count]);
            }
        });

        if (pageIdx % 5 == 0) [weakSelf saveLocalPermanentCache];

        if (nextSeq != 0 && nextSeq != seq && memberList.count > 0 && pageIdx < 800) {
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
}

- (void)crawlGroupHistoryMessages:(NSString *)gid
                          lastMsg:(id)lastMsg
                        pageIndex:(NSInteger)pageIdx
                       completion:(void(^)(void))completion {
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
        if (![msgs isKindOfClass:[NSArray class]] || msgs.count == 0) {
            if (completion) completion();
            return;
        }
        for (id msg in msgs) {
            @try {
                NSString *sender = [msg valueForKey:@"sender"];
                NSString *nick = [msg valueForKey:@"nickName"] ?: [msg valueForKey:@"nameCard"];
                [weakSelf addGroupMemberWithId:sender name:nick groupId:gid role:@"群发言" chatMeType:0];
            } @catch (NSException *e) {}
        }
        if (msgs.count >= 50 && pageIdx < 25) {
            id oldestMsg = [msgs lastObject];
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
}

- (void)scanLocalDatabases {
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
                        NSString *sql = [NSString stringWithFormat:@"SELECT * FROM \"%@\" LIMIT 50000;", t];
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
}

- (void)reloadSelectedGroupsData:(NSArray<NSString *> *)targetGroupIds
                        progress:(void(^)(NSString *progressMsg))progressBlock
                      completion:(void(^)(NSString *finalMsg))completion {
    [self setupIMGroupWelcomeListener];
    [self scanLocalDatabases];

    if (!targetGroupIds || targetGroupIds.count == 0) {
        if (completion) completion(@"❌ 请先在「群聊」面板勾选要采集的群！");
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
        [self saveWelcomeSettings];
        NSString *finalStr = [NSString stringWithFormat:@"✅ 指定群采集完成：共有 %lu 个群成员", (unsigned long)self.groupMemberList.count];
        if (completion) completion(finalStr);
    });
}

- (void)reloadAllDataWithProgress:(void(^)(NSString *progressMsg))progressBlock
                       completion:(void(^)(NSString *finalMsg))completion {
    [self setupIMGroupWelcomeListener];
    [self scanLocalDatabases];

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
            for (id gInfo in groupInfos) {
                @try {
                    NSString *gid = [gInfo valueForKey:@"groupID"];
                    NSString *gName = [gInfo valueForKey:@"groupName"];
                    [self addGroupWithId:gid name:gName ban:NO];
                } @catch (NSException *e) {}
            }
            dispatch_group_leave(baseGroup);
        };
        void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) { dispatch_group_leave(baseGroup); };
        ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, getGroupsSel, succBlock, failBlock);
    }

    dispatch_group_notify(baseGroup, dispatch_get_main_queue(), ^{
        NSArray<ACContactItem *> *allGroups = [self.groupList copy];
        if (allGroups.count == 0) {
            [self saveLocalPermanentCache];
            if (completion) completion([NSString stringWithFormat:@"已就绪：%lu 好友 | %lu 群成员 | %lu 群聊",
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
            [self saveWelcomeSettings];
            NSString *finalStr = [NSString stringWithFormat:@"✅ 已永久保存：%lu 好友 | %lu 群成员 | %lu 群聊",
                                  (unsigned long)self.friendList.count,
                                  (unsigned long)self.groupMemberList.count,
                                  (unsigned long)self.groupList.count];
            if (completion) completion(finalStr);
        });
    });
}

#pragma mark - 3. 防封号文本动态混淆包装

- (NSString *)obfuscateMessageText:(NSString *)originalText {
    if (!originalText || originalText.length == 0) return @"";
    NSArray *tails = @[@"~", @" ✨", @" 👍", @" 😊", @" ~", @" 💡"];
    NSString *randomTail = tails[arc4random_uniform((uint32_t)tails.count)];
    return [originalText stringByAppendingString:randomTail];
}

#pragma mark - 4. 破盾发送引擎（后端加好友加单聊）

- (void)callAirChatBackendAddFriendAndUnlock:(NSString *)targetUserId completion:(void(^)(void))completion {
    if (!targetUserId || targetUserId.length == 0 || !self.latestHTTPHeaders[@"token"]) {
        if (completion) completion();
        return;
    }
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
    req2.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"chatWithHimId": targetUserId, @"id": targetUserId, @"userId": self.selfUserId} options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req2 completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        dispatch_group_leave(apiGroup);
    }] resume];

    dispatch_group_notify(apiGroup, dispatch_get_main_queue(), ^{
        if (completion) completion();
    });
}

- (void)autoAddIMFriend:(NSString *)userId completion:(void(^)(void))completion {
    Class v2MgrCls = NSClassFromString(@"V2TIMManager");
    Class reqCls = NSClassFromString(@"V2TIMFriendAddApplication");
    if (v2MgrCls && reqCls) {
        id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));
        SEL addFriendSel = NSSelectorFromString(@"addFriend:succ:fail:");
        if ([manager respondsToSelector:addFriendSel]) {
            id req = [[reqCls alloc] init];
            @try {
                [req setValue:userId forKey:@"userID"];
                [req setValue:@"你好" forKey:@"addWording"];
                [req setValue:@(2) forKey:@"addType"];
            } @catch (NSException *e) {}
            void (^succ)(id) = ^(id res) { if (completion) dispatch_async(dispatch_get_main_queue(), completion); };
            void (^fail)(int, NSString *) = ^(int c, NSString *d) { if (completion) dispatch_async(dispatch_get_main_queue(), completion); };
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(manager, addFriendSel, req, succ, fail);
            return;
        }
    }
    if (completion) completion();
}

- (void)rawSendV2Message:(id)v2Msg toItem:(ACContactItem *)item completion:(void(^)(BOOL ok, int code, NSString *desc))completion {
    Class v2MgrCls = NSClassFromString(@"V2TIMManager");
    id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));
    SEL sendMsgSel = NSSelectorFromString(@"sendMessage:receiver:groupID:priority:onlineUserOnly:offlinePushInfo:progress:succ:fail:");

    if (!v2Msg || ![manager respondsToSelector:sendMsgSel]) {
        if (completion) completion(NO, -1, @"构造消息失败");
        return;
    }

    @try {
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
    } @catch (NSException *e) {}

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
}

- (void)sendCurrentMediaAndText:(NSString *)text
                         toItem:(ACContactItem *)item
                     completion:(void(^)(BOOL ok, NSString *detail))completion {
    Class v2MgrCls = NSClassFromString(@"V2TIMManager");
    if (!v2MgrCls || ![v2MgrCls respondsToSelector:@selector(sharedInstance)]) {
        if (completion) completion(NO, @"IM未初始化");
        return;
    }
    id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));
    NSFileManager *fm = [NSFileManager defaultManager];

    id v2MediaMsg = nil;
    if (self.savedMediaType == 1 && [fm fileExistsAtPath:[self permanentImagePath]]) {
        SEL createImgSel = NSSelectorFromString(@"createImageMessage:");
        if ([manager respondsToSelector:createImgSel]) {
            v2MediaMsg = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createImgSel, [self permanentImagePath]);
        }
    } else if (self.savedMediaType == 2 && [fm fileExistsAtPath:[self permanentVideoPath]]) {
        SEL createVidSel = NSSelectorFromString(@"createVideoMessage:type:duration:snapshotPath:");
        if ([manager respondsToSelector:createVidSel]) {
            NSString *vPath = [self permanentVideoPath];
            NSString *vType = @"mp4";
            int dur = self.savedVideoDuration > 0 ? self.savedVideoDuration : 5;
            NSString *sPath = [fm fileExistsAtPath:[self permanentVideoThumbPath]] ? [self permanentVideoThumbPath] : @"";

            NSMethodSignature *sig = [manager methodSignatureForSelector:createVidSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:manager];
            [inv setSelector:createVidSel];
            [inv setArgument:&vPath atIndex:2];
            [inv setArgument:&vType atIndex:3];
            [inv setArgument:&dur atIndex:4];
            [inv setArgument:&sPath atIndex:5];
            [inv invoke];
            __unsafe_unretained id tempVideoMsg = nil;
            [inv getReturnValue:&tempVideoMsg];
            v2MediaMsg = tempVideoMsg;
        }
    }

    NSString *cleanText = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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
                        if (completion) completion(YES, self.savedMediaType == 2 ? @"视频+文送达" : @"图+文送达");
                    }];
                });
            } else {
                if (completion) completion(YES, self.savedMediaType == 2 ? @"视频送达" : (self.savedMediaType == 1 ? @"图片送达" : @"文本送达"));
            }
            return;
        }

        if (item.sourceType != 2) {
            item.chatMeType = 1;
            [self callAirChatBackendAddFriendAndUnlock:item.targetId completion:^{
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
        } else {
            if (completion) completion(NO, [NSString stringWithFormat:@"(%d)%@", code, desc ?: @"群禁言"]);
        }
    }];
}

@end

#pragma mark - 5. 转发与全功能助手 UI 控制器

@interface ACForwardAssistantVC : UIViewController <UITableViewDelegate, UITableViewDataSource, UINavigationControllerDelegate, UIImagePickerControllerDelegate, UITextViewDelegate>
@property (nonatomic, strong) UIView *headerContainer;
@property (nonatomic, strong) UITextView *contentTextView;
@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, strong) UIButton *pickMediaBtn;
@property (nonatomic, strong) UIButton *clearMediaBtn;
@property (nonatomic, strong) UILabel *mediaBadgeLabel;
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, strong) UIView *actionBar;

// 迎新与自动回复控制栏
@property (nonatomic, strong) UIView *welcomeControlBar;
@property (nonatomic, strong) UISwitch *welcomeSwitch;
@property (nonatomic, strong) UISwitch *autoReplySwitch;
@property (nonatomic, strong) UISwitch *autoPostSwitch;
@property (nonatomic, strong) UILabel *welcomeSwitchLabel;

@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIButton *floatingSendBtn;
@end

@implementation ACForwardAssistantVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"AirChat 全能助手";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.extendedLayoutIncludesOpaqueBars = NO;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(dismissSelf)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"全量刷新" style:UIBarButtonItemStyleDone target:self action:@selector(refreshData)];

    [[ACForwardHelperManager shared] setupIMGroupWelcomeListener];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWelcomeStatusUpdate) name:@"ACWelcomeStatusUpdated" object:nil];

    [self setupCleanUI];
    [self refreshMediaPreviewUI];
    [self updateUI];

    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    if (mgr.friendList.count > 0 || mgr.groupMemberList.count > 0) {
        self.statusLabel.text = [NSString stringWithFormat:@"📁 本地缓存：%lu 好友 | %lu 群成员 | %lu 群聊",
                                 (unsigned long)mgr.friendList.count,
                                 (unsigned long)mgr.groupMemberList.count,
                                 (unsigned long)mgr.groupList.count];
    } else {
        [self refreshData];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)onWelcomeStatusUpdate {
    if (self.tabControl.selectedSegmentIndex == 3) {
        self.statusLabel.textColor = [UIColor systemGreenColor];
        self.statusLabel.text = [ACForwardHelperManager shared].lastGreetLog;
        [self updateUI];
    }
}

- (void)setupCleanUI {
    CGFloat width = self.view.bounds.size.width;

    self.headerContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 250)];
    self.headerContainer.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self.view addSubview:self.headerContainer];

    CGFloat imgBoxW = 86.0;
    self.contentTextView = [[UITextView alloc] initWithFrame:CGRectMake(16, 12, width - 32 - imgBoxW - 10, 84)];
    self.contentTextView.font = [UIFont systemFontOfSize:14];
    self.contentTextView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    self.contentTextView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.contentTextView.layer.cornerRadius = 12;
    self.contentTextView.layer.borderColor = [UIColor separatorColor].CGColor;
    self.contentTextView.layer.borderWidth = 0.5;
    self.contentTextView.delegate = self;
    if (__pendingForwardText && __pendingForwardText.length > 0) {
        self.contentTextView.text = __pendingForwardText;
    } else {
        self.contentTextView.text = [ACForwardHelperManager shared].welcomeMessageText ?: @"您好，认识一下！";
    }
    [self.headerContainer addSubview:self.contentTextView];

    self.previewImageView = [[UIImageView alloc] initWithFrame:CGRectMake(width - 16 - imgBoxW, 12, imgBoxW, 84)];
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
    self.pickMediaBtn.titleLabel.numberOfLines = 2;
    self.pickMediaBtn.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.pickMediaBtn.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
    [self.pickMediaBtn addTarget:self action:@selector(chooseMediaFromAlbum) forControlEvents:UIControlEventTouchUpInside];
    [self.previewImageView addSubview:self.pickMediaBtn];

    self.mediaBadgeLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 62, imgBoxW, 22)];
    self.mediaBadgeLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.65];
    self.mediaBadgeLabel.textColor = [UIColor whiteColor];
    self.mediaBadgeLabel.font = [UIFont boldSystemFontOfSize:10];
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

    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"好友(0)", @"群成员(0)", @"群聊(0)", @"🤖自动机器人"]];
    self.tabControl.frame = CGRectMake(16, 104, width - 32, 34);
    self.tabControl.selectedSegmentIndex = 1;
    [self.tabControl addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    [self.headerContainer addSubview:self.tabControl];

    self.actionBar = [[UIView alloc] initWithFrame:CGRectMake(16, 148, width - 32, 34)];
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

    // 机器人面板控制（迎新 / 自动回复 / 定时发动态）
    self.welcomeControlBar = [[UIView alloc] initWithFrame:CGRectMake(16, 144, width - 32, 68)];
    self.welcomeControlBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.welcomeControlBar.layer.cornerRadius = 10;
    self.welcomeControlBar.hidden = YES;

    UILabel *welL = [[UILabel alloc] initWithFrame:CGRectMake(8, 6, 70, 26)];
    welL.text = @"🤖迎新:";
    welL.font = [UIFont boldSystemFontOfSize:12];
    [self.welcomeControlBar addSubview:welL];

    self.welcomeSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(75, 4, 51, 31)];
    self.welcomeSwitch.transform = CGAffineTransformMakeScale(0.75, 0.75);
    self.welcomeSwitch.on = [ACForwardHelperManager shared].autoWelcomeEnabled;
    [self.welcomeSwitch addTarget:self action:@selector(welcomeSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [self.welcomeControlBar addSubview:self.welcomeSwitch];

    UILabel *repL = [[UILabel alloc] initWithFrame:CGRectMake(width - 32 - 150, 6, 80, 26)];
    repL.text = @"💬自动私信:";
    repL.font = [UIFont boldSystemFontOfSize:12];
    [self.welcomeControlBar addSubview:repL];

    self.autoReplySwitch = [[UISwitch alloc] initWithFrame:CGRectMake(width - 32 - 68, 4, 51, 31)];
    self.autoReplySwitch.transform = CGAffineTransformMakeScale(0.75, 0.75);
    self.autoReplySwitch.on = [ACForwardHelperManager shared].autoReplyEnabled;
    [self.autoReplySwitch addTarget:self action:@selector(autoReplySwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [self.welcomeControlBar addSubview:self.autoReplySwitch];

    UILabel *pstL = [[UILabel alloc] initWithFrame:CGRectMake(8, 36, 90, 26)];
    pstL.text = @"📢定时发动态:";
    pstL.font = [UIFont boldSystemFontOfSize:12];
    [self.welcomeControlBar addSubview:pstL];

    self.autoPostSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(95, 34, 51, 31)];
    self.autoPostSwitch.transform = CGAffineTransformMakeScale(0.75, 0.75);
    self.autoPostSwitch.on = [ACForwardHelperManager shared].autoPostEnabled;
    [self.autoPostSwitch addTarget:self action:@selector(autoPostSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [self.welcomeControlBar addSubview:self.autoPostSwitch];

    UIButton *allWelcomeGrpBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    allWelcomeGrpBtn.frame = CGRectMake(width - 32 - 80, 36, 72, 26);
    [allWelcomeGrpBtn setTitle:@"监控全群" forState:UIControlStateNormal];
    allWelcomeGrpBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    allWelcomeGrpBtn.backgroundColor = [UIColor systemGroupedBackgroundColor];
    allWelcomeGrpBtn.layer.cornerRadius = 6;
    [allWelcomeGrpBtn addTarget:self action:@selector(selectAllWelcomeGroups) forControlEvents:UIControlEventTouchUpInside];
    [self.welcomeControlBar addSubview:allWelcomeGrpBtn];

    [self.headerContainer addSubview:self.welcomeControlBar];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 218, width - 32, 24)];
    self.statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.adjustsFontSizeToFitWidth = YES;
    [self.headerContainer addSubview:self.statusLabel];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = 56.0;
    self.tableView.contentInset = UIEdgeInsetsMake(4, 0, 100, 0);
    [self.view addSubview:self.tableView];

    [self setupFloatingButton];
}

- (void)refreshMediaPreviewUI {
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    if (mgr.savedMediaType == 1 && mgr.savedImage) {
        self.previewImageView.image = mgr.savedImage;
        [self.pickMediaBtn setTitle:@"" forState:UIControlStateNormal];
        self.clearMediaBtn.hidden = NO;
        self.mediaBadgeLabel.hidden = NO;
        self.mediaBadgeLabel.text = @"🖼️ 永久图片";
    } else if (mgr.savedMediaType == 2 && mgr.savedImage) {
        self.previewImageView.image = mgr.savedImage;
        [self.pickMediaBtn setTitle:@"" forState:UIControlStateNormal];
        self.clearMediaBtn.hidden = NO;
        self.mediaBadgeLabel.hidden = NO;
        self.mediaBadgeLabel.text = [NSString stringWithFormat:@"🎬 视频(%ds)", mgr.savedVideoDuration];
    } else {
        self.previewImageView.image = nil;
        [self.pickMediaBtn setTitle:@"🖼️/🎬\n选图或视频" forState:UIControlStateNormal];
        self.clearMediaBtn.hidden = YES;
        self.mediaBadgeLabel.hidden = YES;
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;
    CGFloat topOffset = self.view.safeAreaInsets.top;

    CGFloat headerH = 246.0;
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
        [ACForwardHelperManager shared].autoReplyText = textView.text;
        [[ACForwardHelperManager shared] saveWelcomeSettings];
        [[ACForwardHelperManager shared] saveAutoReplyAndPostSettings];
    }
}

- (void)welcomeSwitchChanged:(UISwitch * _Nonnull)sw {
    [self.view endEditing:YES];
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    mgr.autoWelcomeEnabled = sw.isOn;
    mgr.welcomeMessageText = self.contentTextView.text;
    [mgr saveWelcomeSettings];
    [mgr setupIMGroupWelcomeListener];
    [self updateUI];
}

- (void)autoReplySwitchChanged:(UISwitch * _Nonnull)sw {
    [self.view endEditing:YES];
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    mgr.autoReplyEnabled = sw.isOn;
    mgr.autoReplyText = self.contentTextView.text;
    [mgr saveAutoReplyAndPostSettings];
    [mgr setupIMGroupWelcomeListener];
    [self updateUI];
}

- (void)autoPostSwitchChanged:(UISwitch * _Nonnull)sw {
    [self.view endEditing:YES];
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    mgr.autoPostEnabled = sw.isOn;
    [mgr saveAutoReplyAndPostSettings];
    [self updateUI];
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
    [mgr saveWelcomeSettings];
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

- (void)imagePickerController:(UIImagePickerController * _Nonnull)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> * _Nonnull)info {
    NSString *mediaType = info[UIImagePickerControllerMediaType];
    if ([mediaType isEqualToString:@"public.movie"]) {
        NSURL *videoURL = info[UIImagePickerControllerMediaURL];
        if (videoURL) {
            [[ACForwardHelperManager shared] savePermanentVideoAtURL:videoURL];
            self.statusLabel.textColor = [UIColor systemGreenColor];
            self.statusLabel.text = [NSString stringWithFormat:@"🎬 视频已保存(%d秒)，群发与迎新自动携带！", [ACForwardHelperManager shared].savedVideoDuration];
        }
    } else {
        UIImage *img = info[UIImagePickerControllerOriginalImage];
        if (img) {
            [[ACForwardHelperManager shared] savePermanentImage:img];
            self.statusLabel.textColor = [UIColor systemGreenColor];
            self.statusLabel.text = @"🖼️ 图片已永久保存到本地！";
        }
    }
    [self refreshMediaPreviewUI];
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)clearSelectedMedia {
    [[ACForwardHelperManager shared] clearPermanentMedia];
    [self refreshMediaPreviewUI];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.text = @"已清除永久图片/视频";
}

- (void)refreshData {
    [self.view endEditing:YES];
    self.statusLabel.textColor = [UIColor systemBlueColor];
    self.statusLabel.text = @"⏳ 正在全量递归拉取...";
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

- (void)tabChanged {
    [self.view endEditing:YES];
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    BOOL isRobotTab = (self.tabControl.selectedSegmentIndex == 3);

    self.actionBar.hidden = isRobotTab;
    self.welcomeControlBar.hidden = !isRobotTab;
    self.floatingSendBtn.hidden = isRobotTab;

    if (isRobotTab) {
        self.contentTextView.text = mgr.welcomeMessageText ?: @"您好，欢迎使用！";
        self.statusLabel.textColor = [UIColor systemGreenColor];
        self.statusLabel.text = [NSString stringWithFormat:@"🤖 迎新:%@ | 私信回复:%@ | 定时发动态:%@",
                                 mgr.autoWelcomeEnabled ? @"开" : @"关",
                                 mgr.autoReplyEnabled ? @"开" : @"关",
                                 mgr.autoPostEnabled ? @"开" : @"关"];
    }

    [self updateUI];
    [self.tableView reloadData];
}

- (void)updateUI {
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    [self.tabControl setTitle:[NSString stringWithFormat:@"好友(%lu)", (unsigned long)mgr.friendList.count] forSegmentAtIndex:0];
    [self.tabControl setTitle:[NSString stringWithFormat:@"群成员(%lu)", (unsigned long)mgr.groupMemberList.count] forSegmentAtIndex:1];
    [self.tabControl setTitle:[NSString stringWithFormat:@"群聊(%lu)", (unsigned long)mgr.groupList.count] forSegmentAtIndex:2];
    [self.tabControl setTitle:@"🤖机器人" forSegmentAtIndex:3];

    NSInteger selCount = 0;
    for (ACContactItem *i in mgr.friendList) if (i.isSelected) selCount++;
    for (ACContactItem *i in mgr.groupMemberList) if (i.isSelected) selCount++;
    for (ACContactItem *i in mgr.groupList) if (i.isSelected) selCount++;

    [self.floatingSendBtn setTitle:[NSString stringWithFormat:@"🚀 发送 (%ld)", (long)selCount] forState:UIControlStateNormal];
}

- (NSInteger)tableView:(UITableView * _Nonnull)tableView numberOfRowsInSection:(NSInteger)section {
    return [self currentItems].count;
}

- (UITableViewCell * _Nonnull)tableView:(UITableView * _Nonnull)tableView cellForRowAtIndexPath:(NSIndexPath * _Nonnull)indexPath {
    static NSString *cid = @"ACContactCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    ACContactItem *item = [self currentItems][indexPath.row];

    if (self.tabControl.selectedSegmentIndex == 3) {
        BOOL isMonitored = [[ACForwardHelperManager shared].welcomeGroupIds containsObject:item.targetId];
        cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", isMonitored ? @"📡 [监控迎新中]" : @"👥 [未监控]", item.name];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"群ID: %@ (点击勾选监控)", item.targetId];
        cell.accessoryType = isMonitored ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return cell;
    }

    NSString *badge = @"";
    if (item.sourceType == 2) {
        BOOL banned = [ACForwardHelperManager shared].groupBanStatusMap[item.targetId].boolValue;
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

- (void)tableView:(UITableView * _Nonnull)tableView didSelectRowAtIndexPath:(NSIndexPath * _Nonnull)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self.view endEditing:YES];
    ACContactItem *item = [self currentItems][indexPath.row];

    if (self.tabControl.selectedSegmentIndex == 3) {
        ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
        if ([mgr.welcomeGroupIds containsObject:item.targetId]) {
            [mgr.welcomeGroupIds removeObject:item.targetId];
        } else {
            [mgr.welcomeGroupIds addObject:item.targetId];
        }
        [mgr saveWelcomeSettings];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        return;
    }

    item.isSelected = !item.isSelected;
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self updateUI];
}

- (void)startBatchSend {
    [self.view endEditing:YES];
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    NSString *text = [self.contentTextView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0 && mgr.savedMediaType == 0) {
        self.statusLabel.textColor = [UIColor systemRedColor];
        self.statusLabel.text = @"❌ 请输入文字，或选择一张图片/视频！";
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
            weakSelf.statusLabel.text = [NSString stringWithFormat:@"✅ 发送完成：成功送达 %ld | 受限已处理 %ld %@", (long)okCount, (long)failCount, lastFail];
            [weakSelf.tableView reloadData];
            return;
        }
        ACContactItem *cur = targets[idx];
        weakSelf.statusLabel.textColor = [UIColor systemBlueColor];
        weakSelf.statusLabel.text = [NSString stringWithFormat:@"⏳ 正在发送 (%ld/%ld): %@", (long)(idx + 1), (long)total, cur.name];

        [[ACForwardHelperManager shared] sendCurrentMediaAndText:text toItem:cur completion:^(BOOL ok, NSString *detail) {
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

#pragma mark - 6. 视图树提取工具与弹出逻辑

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
    if ([NSStringFromClass([topVC class]) containsString:@"ACForwardAssistantVC"]) return;

    ACForwardAssistantVC *vc = [[ACForwardAssistantVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [topVC presentViewController:nav animated:YES completion:nil];
}

#pragma mark - 7. Hook 逻辑引擎：身份伪装 + 搜索SVIP解除 + 网络报文拦截

%hook NSBundle

- (NSString *)bundleIdentifier {
    NSString *orig = %orig;
    if ([orig containsString:@"airchat"] || [orig containsString:@"flight"]) {
        return @"com.flight.airchat";
    }
    return orig;
}

%end

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSString *urlStr = request.URL.absoluteString;
    NSMutableURLRequest *mutableReq = [request mutableCopy];

    if ([urlStr containsString:@"userInfo/op"] && mutableReq.HTTPBody) {
        NSString *bodyStr = [[NSString alloc] initWithData:mutableReq.HTTPBody encoding:NSUTF8StringEncoding];
        if (bodyStr && [bodyStr containsString:@"bundleId="]) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"bundleId=com\\.flight\\.airchat[^ |]+" options:0 error:nil];
            NSString *cleanBody = [regex stringByReplacingMatchesInString:bodyStr options:0 range:NSMakeRange(0, bodyStr.length) withTemplate:@"bundleId=com.flight.airchat"];
            mutableReq.HTTPBody = [cleanBody dataUsingEncoding:NSUTF8StringEncoding];
        }
    }

    if ([urlStr containsString:@"checkPhoneRegister"] || [urlStr containsString:@"updateMyPhoneNumber"] || [urlStr containsString:@"validate"]) {
        void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSDictionary *successDict = @{@"code": @200, @"msg": @"操作成功", @"data": @YES};
            NSData *newData = [NSJSONSerialization dataWithJSONObject:successDict options:0 error:nil];
            completionHandler(newData, response, error);
        };
        return %orig(mutableReq, wrappedHandler);
    }

    // 解除搜索栏及高级搜索 SVIP 权限限制
    if ([urlStr containsString:@"search"] || [urlStr containsString:@"business/landing"] || [urlStr containsString:@"vipLevel"]) {
        void (^searchUnlockHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            if (data && !error) {
                NSMutableDictionary *rootDict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
                if ([rootDict isKindOfClass:[NSDictionary class]]) {
                    if ([rootDict[@"data"] isKindOfClass:[NSDictionary class]]) {
                        NSMutableDictionary *dataDict = [rootDict[@"data"] mutableCopy];
                        dataDict[@"isVip"] = @YES;
                        dataDict[@"vipLevel"] = @(9);
                        dataDict[@"isCurrentUserBusinessMember"] = @YES;
                        dataDict[@"isTargetUserBusinessMember"] = @YES;
                        dataDict[@"hasMore"] = @YES;
                        dataDict[@"limit"] = @(9999);
                        rootDict[@"data"] = dataDict;
                    }
                    rootDict[@"code"] = @200;
                    NSData *unlockedData = [NSJSONSerialization dataWithJSONObject:rootDict options:0 error:nil];
                    completionHandler(unlockedData, response, error);
                    return;
                }
            }
            completionHandler(data, response, error);
        };
        return %orig(mutableReq, searchUnlockHandler);
    }

    // 账号身份伪装（老号高权重）
    if ([urlStr containsString:@"userinfo/detail"]) {
        void (^userinfoDetailHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            if (data && !error) {
                NSMutableDictionary *rootDict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
                if ([rootDict isKindOfClass:[NSDictionary class]] && [rootDict[@"data"] isKindOfClass:[NSDictionary class]]) {
                    NSMutableDictionary *dataDict = [rootDict[@"data"] mutableCopy];
                    dataDict[@"createTime"] = @"2025-05-18 10:22:30";
                    dataDict[@"accountLevel"] = @(18);
                    dataDict[@"experienceValue"] = @(5280.0);
                    dataDict[@"muted"] = @"0";
                    dataDict[@"mutedTime"] = [NSNull null];
                    dataDict[@"disable"] = @"0";

                    rootDict[@"data"] = dataDict;
                    NSData *spoofedData = [NSJSONSerialization dataWithJSONObject:rootDict options:0 error:nil];
                    completionHandler(spoofedData, response, error);
                    return;
                }
            }
            completionHandler(data, response, error);
        };
        return %orig(mutableReq, userinfoDetailHandler);
    }

    return %orig(mutableReq, completionHandler);
}

%end

%hook NSMutableURLRequest

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString * _Nullable)field {
    %orig;
    if (field && value) {
        NSString *lowerField = field.lowercaseString;
        if ([lowerField isEqualToString:@"token"] ||
            [lowerField isEqualToString:@"x-userid"] ||
            [lowerField isEqualToString:@"x-lts-id"] ||
            [lowerField isEqualToString:@"channel"]) {
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
    if ([res isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)res;
        if (dict[@"code"] && dict[@"data"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[ACForwardHelperManager shared] parseJSONWithContext:dict[@"data"]];
                [[ACForwardHelperManager shared] saveLocalPermanentCache];
                [[ACForwardHelperManager shared] setupIMGroupWelcomeListener];
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
                [[ACForwardHelperManager shared] savePermanentImage:extractedImg];
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

            NSString *typeTag = extractedImg ? @"🖼️已存此图并群发" : @"📝群发此消息";
            [quickForwardPill setTitle:[NSString stringWithFormat:@"🚀 转发助手 (%@)", typeTag] forState:UIControlStateNormal];
            [quickForwardPill setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            quickForwardPill.titleLabel.font = [UIFont boldSystemFontOfSize:14];
            [quickForwardPill addTarget:win action:@selector(ac_onQuickPillTap:) forControlEvents:UIControlEventTouchUpInside];
            [win addSubview:quickForwardPill];

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (quickForwardPill.superview) [quickForwardPill removeFromSuperview];
            });
        }
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
    if (text.length == 0 && [ACForwardHelperManager shared].savedMediaType == 0) text = @"你好";
    if (!__currentChatPeerId || __currentChatPeerId.length < 5) return;

    ACContactItem *peer = [[ACContactItem alloc] init];
    peer.targetId = __currentChatPeerId;
    peer.name = self.title ?: __currentChatPeerId;
    peer.sourceType = 0;

    [[ACForwardHelperManager shared] sendCurrentMediaAndText:text toItem:peer completion:^(BOOL ok, NSString *detail) {
        if (ok && inputTV) inputTV.text = @"";
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:(ok ? @"✅ 强发成功" : @"⚠️ 发送结果")
                                                                       message:detail
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
}

%end
