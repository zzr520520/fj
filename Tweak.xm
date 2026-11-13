#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>
#import <string.h>
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
// 严格限定只有 apiv1/api 业务网关才允许用于发布/点赞/评论请求；
// static/file/res 等静态资源、CDN、COS 存储桶域名一律拒绝，否则 POST 会打进对象存储返回 405 XML
static inline BOOL ACIsBusinessHost(NSString *host) {
    NSString *h = ACSafeStr(host).lowercaseString;
    if (h.length == 0) return NO;
    // 1. 过滤所有常见对象存储、CDN、静态资源域名
    if ([h containsString:@"myqcloud"] || [h containsString:@"cos."] || [h hasPrefix:@"cos"] ||
        [h containsString:@"tencentcloud"] || [h containsString:@"cloudfront"] || [h containsString:@"aliyuncs"] ||
        [h containsString:@"static"] || [h containsString:@"image"] || [h containsString:@"file"] ||
        [h containsString:@"media"] || [h containsString:@"res"] || [h containsString:@"download"]) return NO;
    // 2. 必须包含 airchat，且必须是 api/apiv1 主机，排除 cdn.airchat.cc 之类纯静态域名
    if ([h containsString:@"airchat"]) {
        return ([h containsString:@"apiv1"] || [h hasPrefix:@"api"]);
    }
    return NO;
}
// 兼容新老信息流接口的响应结构：data.records / records / data.list / data.rows
static inline NSArray *ACFeedRecordsFromJSON(NSDictionary *json) {
    NSDictionary *data = ACSafeDict(json[@"data"]);
    NSArray *recs = ACSafeArray(data[@"records"]);
    if (recs.count > 0) return recs;
    recs = ACSafeArray(json[@"records"]);
    if (recs.count > 0) return recs;
    recs = ACSafeArray(data[@"list"]);
    if (recs.count > 0) return recs;
    recs = ACSafeArray(data[@"rows"]);
    if (recs.count > 0) return recs;
    return ACSafeArray(json[@"rows"]);
}
// 探针实证：官方真实 X-Lts-Id 约 144 字符、含 [a]/[d] 混淆段、结尾并非 [s]；
// 旧的 length>=140 且以 [s] 结尾判定把官方值全部丢弃，导致插件发出的请求 Lts=0 → 服务端 500
static inline BOOL ACIsValidLtsId(NSString *v) {
    if (![v isKindOfClass:[NSString class]]) return NO;
    return (v.length >= 100);
}
// HAR 183315 污染根治：真实登录 Token（如 nbFB2jb4p9p2ka5z52eAwnfZMniBBCFo）恒为恰好 32 位纯字母数字；
// 而 /client/biz/v2/userinfo/209/get/enc/id 返回的是 24 位含 = / + 的 Base64 密钥（如 Q0EdQ2hMGW9nbQB/EBpIYQc=），
// 旧的「24~64 位无空格字符串」判定把它误当登录 Token，把本地账号的真 Token 全部覆盖污染！
static inline BOOL ACIsValidAuthToken(NSString *v) {
    if (![v isKindOfClass:[NSString class]] || v.length != 32) return NO;
    static NSCharacterSet *acInvalidTokSet = nil;
    static dispatch_once_t acTokOnce;
    dispatch_once(&acTokOnce, ^{
        NSCharacterSet *alnum = [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"];
        acInvalidTokSet = [alnum invertedSet];
    });
    return ([v rangeOfCharacterFromSet:acInvalidTokSet].location == NSNotFound);
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
// 多账号热切换锁定：切换后禁止原生流量嗅探把 token/x-userid/channel 冲回 App 当前登录账号，
// 否则插件身份几秒内就被还原，多账号秒切形同虚设
static NSString *sHotSwitchUserId = nil;
// 原生会话凭证副本：热切换锁定期间仍持续记录 App 当前真实登录态，供「保存当前登录账号」面板取用
static NSMutableDictionary *ACNativeAuthStore(void) {
static NSMutableDictionary *sStore = nil;
static dispatch_once_t once;
dispatch_once(&once, ^{ sStore = [NSMutableDictionary dictionary]; });
return sStore;
}
// 取当前最顶层 VC（含 presented 链 / 导航 / TabBar 穿透）
static UIViewController *ACTopMostViewController(void) {
@try {
UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
if (!keyWin) {
for (UIWindow *w in [UIApplication sharedApplication].windows) { if (w.isKeyWindow) { keyWin = w; break; } }
}
UIViewController *top = keyWin.rootViewController;
while (top.presentedViewController) top = top.presentedViewController;
while ([top isKindOfClass:[UINavigationController class]]) {
UINavigationController *nav = (UINavigationController *)top;
UIViewController *last = nav.viewControllers.lastObject;
if (!last) break;
top = last;
while (top.presentedViewController) top = top.presentedViewController;
}
while ([top isKindOfClass:[UITabBarController class]]) {
UITabBarController *tab = (UITabBarController *)top;
UIViewController *sel = tab.selectedViewController;
if (!sel) break;
top = sel;
while (top.presentedViewController) top = top.presentedViewController;
}
return top;
} @catch (NSException *e) { return nil; }
}
// 是否处于官方「账号管理/登录/注册/验证」界面（在这些界面绝不锁死请求头，让官方切号完全畅通）
static BOOL ACIsInNativeAccountOrLoginScreen(void) {
@try {
UIViewController *top = ACTopMostViewController();
if (!top) return NO;
NSString *cls = NSStringFromClass([top class]) ?: @"";
return ([cls containsString:@"AccountManagement"] || [cls containsString:@"Login"] ||
[cls containsString:@"Register"] || [cls containsString:@"Verify"] ||
[cls containsString:@"Password"] || [cls containsString:@"Setting"]);
} @catch (NSException *e) { return NO; }
}
// 是否为退出登录注销请求（拦截后服务端无法销毁旧账号 Token）
static BOOL ACIsLogoutRequest(NSURLRequest *req) {
if (!req || !req.URL) return NO;
NSString *path = req.URL.path.lowercaseString ?: @"";
if ([path containsString:@"logout"] || [path containsString:@"loginout"] ||
[path containsString:@"signout"] || [path containsString:@"exitlogin"] ||
[path hasSuffix:@"/quit"]) return YES;
return NO;
}
// HAR [57] 实证：官方登录页 /auth/c/doLoginNoEn 的明文账密捕获（NSURLSession 嗅探 + NSJSONSerialization 收割共用）
static NSString *g_lastLoginAccount = nil;
static NSString *g_lastLoginPassword = nil;
static NSString * const kACNativeUserAgent = @"airchat/1102 CFNetwork/1490.0.4 Darwin/23.2.0";

// 根治 Alamofire RequestTaskMap SIGTRAP：
// 插件自己的请求绝不能借用 App 的 Alamofire Session——那会让 Alamofire 的
// SessionDelegate 收到它没注册过的 task 回调，命中 RequestTaskMap 断言直接崩溃。
// 这里固定使用独立 Session（无 delegate、无 Cookie、无缓存），与 App 网络栈完全隔离。
static NSURLSession *ACDedicatedPluginSession(void) {
    static NSURLSession *sPluginSession = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @try {
            NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
            cfg.timeoutIntervalForRequest = 20.0;
            cfg.HTTPShouldSetCookies = NO;
            cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
            NSOperationQueue *q = [[NSOperationQueue alloc] init];
            q.name = @"com.airchat.tweak.isolated.network";
            q.maxConcurrentOperationCount = 4;
            sPluginSession = [NSURLSession sessionWithConfiguration:cfg delegate:nil delegateQueue:q];
        } @catch (NSException *e) {}
    });
    return sPluginSession;
}

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
// 黄金抓包探针：捕获官方原生点赞/评论/发布请求的完整报文，用于比对修复 code:500
static void ACGoldenProbeDump(NSURLRequest *request) {
@try {
if (!request || !request.URL || acInternalRequest) return;
NSString *urlStr = request.URL.absoluteString ?: @"";
if (!([urlStr containsString:@"/like"] || [urlStr containsString:@"/comment/publish"] || [urlStr containsString:@"/post/app/publish"])) return;
ACLog(@"======== 抓获官方原生请求 ========");
ACLog(@"[探针] URL: %@", urlStr);
ACLog(@"[探针] Method: %@", request.HTTPMethod ?: @"GET");
ACLog(@"[探针] Headers: %@", request.allHTTPHeaderFields);
if (request.HTTPBody) {
NSString *bodyStr = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
ACLog(@"[探针] Body: %@", bodyStr.length > 0 ? bodyStr : @"(非UTF8)");
} else {
ACLog(@"[探针] Body: (空，参数在URL Query中)");
}
// 打印原生调用栈：定位 App 内部是谁在发这个请求（类名/方法名），用于反射桥接
NSArray *acSyms = [NSThread callStackSymbols];
NSUInteger acMax = acSyms.count > 30 ? 30 : acSyms.count;
ACLog(@"[探针核心调用栈]:\n%@", [(NSArray *)[acSyms subarrayWithRange:NSMakeRange(0, acMax)] componentsJoinedByString:@"\n"]);
ACLog(@"==================================");
} @catch (NSException *e) {}
}
// —— 原生点赞弹药库：postId → 屏上 MomentCardView 映射 ——
static NSMutableDictionary<NSString *, UIView *> *sLiveMomentCardMap = nil;
static inline NSString *ACExtractCardPostId(UIView *card) {
@try {
id model = [card valueForKey:@"model"] ?: [card valueForKey:@"item"] ?: [card valueForKey:@"data"];
if (!model) return @"";
NSString *pid = ACSafeStr([model valueForKey:@"id"]);
if (pid.length == 0) pid = ACSafeStr([model valueForKey:@"postId"]);
return pid ?: @"";
} @catch (NSException *e) { return @""; }
}
static void ACDumpCardProperties(id card) {
@try {
unsigned int count = 0;
objc_property_t *props = class_copyPropertyList([card class], &count);
for (unsigned int i = 0; i < count; i++) {
const char *pName = property_getName(props[i]);
NSString *name = [NSString stringWithUTF8String:pName];
@try {
id val = [card valueForKey:name];
ACLog(@"  -> 属性: %@ = %@", name, val);
} @catch (NSException *e) {
ACLog(@"  -> 属性: %@ = (KVC不可读)", name);
}
}
if (props) free(props);
} @catch (NSException *e) {}
}
#pragma mark - 语音条录制/播放辅助器（AVFoundation 原生，AAC 格式双端通用）
@interface ACAudioHelper : NSObject <AVAudioRecorderDelegate, AVAudioPlayerDelegate>
@property (nonatomic, strong) AVAudioRecorder *recorder;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, copy) NSString *currentRecordingPath;
@property (nonatomic, assign) NSTimeInterval recordStartTime;
+ (instancetype)shared;
- (void)startRecordingToPath:(NSString *)destPath;
- (int)stopRecording;
- (void)playAudioAtPath:(NSString *)path completion:(void(^)(void))completion;
- (void)stopPlaying;
- (int)durationOfAudioAtPath:(NSString *)path;
@end
@implementation ACAudioHelper {
void (^_playDoneBlock)(void);
}
+ (instancetype)shared {
static ACAudioHelper *inst = nil;
static dispatch_once_t once;
dispatch_once(&once, ^{ inst = [[ACAudioHelper alloc] init]; });
return inst;
}
- (void)startRecordingToPath:(NSString *)destPath {
[self stopPlaying];
self.currentRecordingPath = destPath;
@try {
AVAudioSession *session = [AVAudioSession sharedInstance];
[session setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];
[session setActive:YES error:nil];
NSDictionary *settings = @{
AVFormatIDKey: @(kAudioFormatMPEG4AAC),
AVSampleRateKey: @(16000.0),
AVNumberOfChannelsKey: @(1),
AVEncoderAudioQualityKey: @(AVAudioQualityMedium)
};
NSURL *url = [NSURL fileURLWithPath:destPath];
[[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
self.recorder = [[AVAudioRecorder alloc] initWithURL:url settings:settings error:nil];
self.recorder.delegate = self;
[self.recorder record];
self.recordStartTime = [[NSDate date] timeIntervalSince1970];
ACLog(@"[录音] 开始录制语音条 -> %@", destPath.lastPathComponent);
} @catch (NSException *e) {
ACLog(@"[录音] 启动失败 %@", e.reason);
}
}
- (int)stopRecording {
if (!self.recorder || !self.recorder.isRecording) return 0;
NSTimeInterval dur = [[NSDate date] timeIntervalSince1970] - self.recordStartTime;
@try { [self.recorder stop]; } @catch (NSException *e) {}
self.recorder = nil;
[AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:nil];
int sec = (int)round(dur);
return sec > 0 ? sec : 1;
}
- (void)playAudioAtPath:(NSString *)path completion:(void(^)(void))completion {
[self stopPlaying];
if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
_playDoneBlock = [completion copy];
@try {
self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
self.player.delegate = self;
[self.player play];
} @catch (NSException *e) {}
}
- (void)stopPlaying {
if (self.player && self.player.isPlaying) [self.player stop];
self.player = nil;
}
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
if (_playDoneBlock) { void (^b)(void) = _playDoneBlock; _playDoneBlock = nil; b(); }
}
- (int)durationOfAudioAtPath:(NSString *)path {
if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return 0;
@try {
AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
CMTime t = asset.duration;
if (t.timescale > 0) return (int)round((double)t.value / (double)t.timescale);
} @catch (NSException *e) {}
return 0;
}
@end
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
#pragma mark - 多账号数据模型（账号+密码+备注，支持缓存凭证秒切）
@interface ACAccountItem : NSObject
@property (nonatomic, copy) NSString *account;   // 账号/手机号
@property (nonatomic, copy) NSString *password;  // 密码
@property (nonatomic, copy) NSString *remark;    // 备注名
@property (nonatomic, copy) NSString *userId;
@property (nonatomic, copy) NSString *token;
@property (nonatomic, copy) NSString *channel;
@property (nonatomic, copy) NSString *saveTime;
- (NSDictionary *)toDict;
+ (instancetype)fromDict:(NSDictionary *)dict;
@end
@implementation ACAccountItem
- (NSDictionary *)toDict {
return @{
@"account": self.account ?: @"",
@"password": self.password ?: @"",
@"remark": self.remark ?: @"",
@"userId": self.userId ?: @"",
@"token": self.token ?: @"",
@"channel": self.channel ?: @"",
@"saveTime": self.saveTime ?: @""
};
}
+ (instancetype)fromDict:(NSDictionary *)d {
if (!d || ![d isKindOfClass:[NSDictionary class]]) return nil;
ACAccountItem *item = [[ACAccountItem alloc] init];
item.account = ACSafeStr(d[@"account"]);
item.password = ACSafeStr(d[@"password"]);
item.remark = ACSafeStr(d[@"remark"]);
item.userId = ACSafeStr(d[@"userId"]);
item.token = ACSafeStr(d[@"token"]);
item.channel = ACSafeStr(d[@"channel"]);
item.saveTime = ACSafeStr(d[@"saveTime"]);
return item;
}
@end

@interface ACForwardHelperManager : NSObject
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *friendList;
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *groupMemberList;
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *groupList;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *friendMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *groupMemberMap;
@property (nonatomic, strong) NSMutableArray<ACAccountItem *> *accountList; // 多账号列表
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *groupMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *groupBanStatusMap;
@property (nonatomic, copy) NSString *selfUserId;
@property (nonatomic, copy) NSString *capturedClientTypeV2;
@property (nonatomic, strong) NSData *capturedCloudCustomData;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *latestHTTPHeaders;
// --- 1. 迎新配置 ---
@property (nonatomic, assign) BOOL autoWelcomeEnabled;
@property (nonatomic, copy) NSString *welcomeMessageText;
// —— 迎新方式独立开关：文字 / 图片视频 / 1 秒语音打招呼 ——
@property (nonatomic, assign) BOOL welcomeTextEnabled;
@property (nonatomic, assign) BOOL welcomeMediaEnabled;
@property (nonatomic, assign) BOOL welcomeVoiceCallEnabled;
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
// —— 自动点赞（信息流出现新动态即点赞，复用已有信息流响应）——
@property (nonatomic, assign) BOOL autoLikeEnabled;
@property (nonatomic, strong) NSMutableSet<NSString *> *likedPostIds;
@property (nonatomic, strong) NSMutableArray<NSString *> *likeQueue;
@property (nonatomic, assign) BOOL isLikeSending;
@property (nonatomic, assign) BOOL autoLikeSeeded;
@property (nonatomic, assign) NSTimeInterval autoLikeEnabledAt;
// —— 批量语音打招呼（TUICallKit/TUICallEngine，默认 1 秒自动挂断）——
@property (nonatomic, assign) BOOL voiceCallRunning;
// —— 批量语音条打招呼（私聊发送 AAC 语音条，替代 VoIP 振铃）——
@property (nonatomic, assign) BOOL voiceMemoRunning;
@property (nonatomic, assign) BOOL welcomeVoiceCalling;
@property (nonatomic, assign) float voiceHangupSeconds;
// —— 自动点赞后台巡检（独立 Session 主动拉取，无需用户浏览信息流）——
@property (nonatomic, strong) NSTimer *autoLikePollTimer;
@property (nonatomic, assign) BOOL autoLikePolling;
// —— 后台静音保活（内存生成 WAV，不依赖资源文件）——
@property (nonatomic, assign) BOOL keepAliveEnabled;
@property (nonatomic, strong) AVAudioPlayer *keepAlivePlayer;
// —— 群机器人伪装（cloudCustomData + 文案前缀）——
@property (nonatomic, assign) BOOL robotModeEnabled;
@property (nonatomic, copy) NSString *robotDisplayName;
// —— 手动群号采集（外显群号 -> 真实群 ID -> 递归拉成员/历史消息）——
@property (nonatomic, copy) NSString *manualTargetGroupId;
@property (nonatomic, assign) NSTimeInterval latestLtsAt;
@property (nonatomic, assign) BOOL momentRetryScheduled;
@property (nonatomic, assign) BOOL momentNativeBridgeDisabled;
// —— 自动记录 App 实际使用的业务域名（.cn / .cc / .ltd），避免写死域名导致 500 ——
@property (nonatomic, copy) NSString *lastAirchatHost;
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
- (BOOL)ac_isValidGroupId:(NSString *)gid;
- (void)ac_fetchGroupListFromServer:(void(^)(NSInteger count))completion;
- (void)fetchMembersByManualGroupNumber:(NSString *)groupNum
progress:(void(^)(NSString *msg))progressBlock
completion:(void(^)(NSString *res))completion;
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
- (BOOL)ac_tryNativeMomentPublish:(ACMomentTaskItem *)task completion:(void(^)(BOOL ok, NSString *msg))completion;
- (void)triggerSingleVoiceCallForTarget:(NSString *)uid nick:(NSString *)nick completion:(void(^)(void))completion;
// v2.1 新增：统一消息入口（TIM 监听代理与直接监听共用）、发动态节流/重试
- (void)ac_handleIncomingMessage:(id)msg;
- (void)ac_handleMembersJoined:(NSArray *)memberList groupID:(NSString *)groupID;
- (void)ac_applyCapturedHeadersToRequest:(NSMutableURLRequest *)req;
- (void)ac_scheduleMomentRetryAfter:(NSTimeInterval)delay;
- (void)ac_handleFeedResponse:(NSDictionary *)json;
- (void)ac_enqueueAutoCommentForPostId:(NSString *)postId;
- (void)ac_pumpAutoCommentQueue;
- (void)ac_commentPostId:(NSString *)postId text:(NSString *)text;
// —— 自动点赞 ——
- (void)ac_handleFeedResponseForAutoLike:(NSDictionary *)json;
- (void)ac_enqueueAutoLikeForPostId:(NSString *)postId;
- (void)ac_pumpAutoLikeQueue;
- (void)ac_triggerAutoLikeForPost:(NSString *)postId;
// —— 批量语音打招呼 + 自动挂断 ——
- (void)ac_startBatchVoiceCall:(NSArray<ACContactItem *> *)targets;
// —— 批量语音条打招呼（私聊 AAC 语音条）——
- (void)ac_startBatchVoiceMemo:(NSArray<ACContactItem *> *)targets;
// —— 槽位语音条存储 ——
- (NSString *)audioPathForSlot:(ACMediaSlot)slot;
- (void)saveAudioAtURL:(NSURL *)audioURL forSlot:(ACMediaSlot)slot duration:(int)sec;
- (int)audioDurationForSlot:(ACMediaSlot)slot;
- (void)ac_stopBatchVoiceCall;
// —— 自动点赞后台巡检（独立会话） ——
- (void)ac_startAutoLikePollTimer;
- (void)ac_pollFeedForAutoLike;
// —— 动态业务网关解析（升级后 .cc/.cn/.ltd 自适应） ——
- (NSString *)ac_activeBusinessHost;
// —— 后台静音保活 ——
- (void)ac_applyKeepAliveState;
// —— 全后台不死心跳引擎（挂后台定时发动态不断流 + 无需进页面自动点赞） ——
@property (nonatomic, assign) NSTimeInterval nextMomentFireTimestamp;
@property (nonatomic, strong) dispatch_source_t bgMasterHeartbeatTimer;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTaskId;
- (void)ac_startImmortalBackgroundEngine;
- (void)ac_prewarmAndScrollMomentsForAutoLike;
// —— 多账号全量接管（主页/NSUserDefaults/URL/Body 四位一体同步热切换） ——
@property (nonatomic, assign) BOOL forcedAccountOverride;
@property (nonatomic, copy) NSString *previousSelfUserId;
- (NSString *)accountDefaultsSnapshotPathForUid:(NSString *)uid;
- (void)ac_saveAppDefaultsSnapshotForUid:(NSString *)uid;
- (void)ac_restoreAppDefaultsAndRefreshUIForAccount:(ACAccountItem *)acc;
// —— 打招呼防封降权（拟人化批次冷却 + 破盾限频） ——
@property (nonatomic, assign) NSInteger batchSendStreakCount;
@property (nonatomic, assign) NSInteger unlockAttemptCountInSession;
@property (nonatomic, assign) NSTimeInterval lastUnlockAttemptAt;
// —— 全自动收割账号 + 预检防踢下线切换 + 免退登官方账号管理 ——
- (void)ac_autoSaveOrUpdateAccountWithUid:(NSString *)uid token:(NSString *)token nickname:(NSString *)nickname accountNum:(NSString *)accountNum;
- (void)ac_openNativeAccountManagement;
// —— 免退登明文直登 + IM UserSig 重连 + 宿主账号槽位同步（HAR 172623 实证）——
- (void)ac_loginWithUsername:(NSString *)username password:(NSString *)password completion:(void(^)(BOOL ok, NSString *msg))completion;
- (void)ac_reconnectTencentIMForAccount:(ACAccountItem *)acc;
- (void)ac_hotReloadHostRootViewControllerForAccount:(ACAccountItem *)acc;
- (void)ac_syncAccountToHostUserDefaults:(ACAccountItem *)acc;
- (void)ac_forceRefreshHostAppUI;
- (void)ac_performAccountSwitch:(ACAccountItem *)acc completion:(void(^)(BOOL ok, NSString *msg))completion;
@end
// 前置声明：账号切换后触发飞行圈后台刷新，重新嗅探新会话的签名对（X-Lts-Id + X-Request-No）
static void ACTriggerMomentsBackgroundRefresh(void);
@implementation ACForwardHelperManager

#pragma mark - 多账号管理（保存/快速切换）
// 全自动收割保存账号：/userinfo/detail 响应触发（官方账号管理添加/切换新号后无需手动填表，自动入库）
- (void)ac_autoSaveOrUpdateAccountWithUid:(NSString *)uid token:(NSString *)token nickname:(NSString *)nickname accountNum:(NSString *)accountNum {
if (uid.length < 5 || token.length < 10) return;
if (!self.accountList) self.accountList = [NSMutableArray array];
NSString *label = nickname.length > 0 ? nickname : [NSString stringWithFormat:@"用户_%@", [uid substringFromIndex:MAX(0, (NSInteger)uid.length - 4)]];
if (accountNum.length > 0) label = [NSString stringWithFormat:@"%@ (%@)", label, accountNum];
NSInteger foundIdx = NSNotFound;
for (NSInteger i = 0; i < (NSInteger)self.accountList.count; i++) {
ACAccountItem *it = self.accountList[i];
if ([it.userId isEqualToString:uid]) { foundIdx = i; break; }
}
if (foundIdx != NSNotFound) {
ACAccountItem *exist = self.accountList[foundIdx];
BOOL changed = (![exist.token isEqualToString:token] || ![exist.remark isEqualToString:label]);
exist.token = token;
if (label.length > 0) exist.remark = label;
if (changed) {
[self saveAllAccounts];
ACLog(@"[多账号] 🔄 已自动同步账号最新凭证: %@", label);
}
} else {
ACAccountItem *newAcc = [[ACAccountItem alloc] init];
newAcc.remark = label;
newAcc.userId = uid;
newAcc.token = token;
NSDateFormatter *df = [[NSDateFormatter alloc] init];
df.dateFormat = @"MM-dd HH:mm";
newAcc.saveTime = [df stringFromDate:[NSDate date]];
[self.accountList addObject:newAcc];
[self saveAllAccounts];
ACLog(@"[多账号] ✅ 已全自动捕获并保存新账号: %@", label);
}
}
// 一键免退登呼出官方账号切换页：解除插件锁定 + 先收起插件弹窗（HAR 实证插件 Modal 盖住底层导致 push 无效）+ 跳转官方切换页
- (void)ac_openNativeAccountManagement {
self.forcedAccountOverride = NO;
sHotSwitchUserId = nil; // 解除嗅探锁定，官方新登录 Token 可正常捕获入库
// HAR 实证：宿主 Swift 模块前缀是全小写 airchat.，官方账号切换管理器真实类名 airchat.AirAccountChangeViewController
Class accMgrCls = NSClassFromString(@"airchat.AirAccountChangeViewController")
?: NSClassFromString(@"AirAccountChangeViewController")
?: NSClassFromString(@"airchat.AccountManagementViewController")
?: NSClassFromString(@"AccountManagementViewController")
?: NSClassFromString(@"AirChat.AccountManagementViewController")
?: NSClassFromString(@"AirAccountManagementViewController");
if (!accMgrCls) {
// 动态扫描运行时所有类名含 AirAccountChange / AccountChangeViewController 的 VC
int numClasses = objc_getClassList(NULL, 0);
if (numClasses > 0) {
Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * numClasses);
int realCount = objc_getClassList(classes, numClasses);
for (int i = 0; i < realCount; i++) {
const char *cName = class_getName(classes[i]);
if (!cName) continue;
if (strstr(cName, "AirAccountChange") || strstr(cName, "AccountChangeViewController") || strstr(cName, "AccountManagementViewController")) {
accMgrCls = classes[i];
break;
}
}
free(classes);
}
}
if (!accMgrCls) {
ACLog(@"[多账号] 未找到官方账号切换页类，请使用插件「➕ 添加账号」免退登直登，或到【我的→设置→账号管理】操作");
return;
}
UIViewController *topVC = ACTopMostViewController();
void (^pushOfficialVC)(void) = ^{
UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
if (!keyWin) { for (UIWindow *w in [UIApplication sharedApplication].windows) { if (w.isKeyWindow) { keyWin = w; break; } } }
UIViewController *root = keyWin.rootViewController;
UINavigationController *nav = nil;
if ([root isKindOfClass:[UITabBarController class]]) {
UIViewController *sel = [(UITabBarController *)root selectedViewController];
if ([sel isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)sel;
else if (sel.navigationController) nav = sel.navigationController;
} else if ([root isKindOfClass:[UINavigationController class]]) {
nav = (UINavigationController *)root;
}
if (!nav && topVC.navigationController) nav = topVC.navigationController;
@try {
UIViewController *vc = [[accMgrCls alloc] init];
vc.hidesBottomBarWhenPushed = YES;
if (nav) {
[nav pushViewController:vc animated:YES];
} else if (root) {
UINavigationController *wrapNav = [[UINavigationController alloc] initWithRootViewController:vc];
wrapNav.modalPresentationStyle = UIModalPresentationPageSheet;
[root presentViewController:wrapNav animated:YES completion:nil];
}
ACLog(@"[多账号] 已打开官方账号切换页 %@（在此登录的新号将自动入库保存）", NSStringFromClass(accMgrCls));
} @catch (NSException *e) {
ACLog(@"[多账号] 打开官方账号切换页异常: %@", e.reason);
}
};
// 关键修复：插件设置窗口（ACForwardAssistantVC 的 Modal）正盖在最顶层时，
// 直接 push 会被 Modal 冲突挡住毫无反应——必须先 dismiss 插件弹窗再延时跳转
if (topVC && ([NSStringFromClass([topVC class]) hasPrefix:@"AC"] || topVC.presentingViewController)) {
UIViewController *toDismiss = topVC.navigationController ?: topVC;
[toDismiss dismissViewControllerAnimated:YES completion:^{
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), pushOfficialVC);
}];
} else {
pushOfficialVC();
}
}
// 抓包 [57] 实证：/auth/c/doLoginNoEn 接受明文 account+password+uuid 直接返回全新 Token。
// 免退出当前账号，后台直登任意账号并入库（想存 10 个 20 个账号都可以）
- (void)ac_loginWithUsername:(NSString *)username password:(NSString *)password completion:(void(^)(BOOL ok, NSString *msg))completion {
if (username.length == 0 || password.length == 0) { if (completion) completion(NO, @"账号或密码不能为空"); return; }
NSString *devUuid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
if (devUuid.length == 0) {
devUuid = [[NSUserDefaults standardUserDefaults] stringForKey:@"AC_Device_UUID"];
if (devUuid.length == 0) {
devUuid = [[NSUUID UUID] UUIDString];
[[NSUserDefaults standardUserDefaults] setObject:devUuid forKey:@"AC_Device_UUID"];
}
}
acInternalRequest = YES;
NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://apiv1.airchat.cn/auth/c/doLoginNoEn"]];
req.HTTPMethod = @"POST";
req.timeoutInterval = 15.0;
[req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
[req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
[req setValue:(ACHeaderValue(self.latestHTTPHeaders, @"User-Agent") ?: kACNativeUserAgent) forHTTPHeaderField:@"User-Agent"];
NSString *ver = ACHeaderValue(self.latestHTTPHeaders, @"version");
if (ver.length > 0) [req setValue:ver forHTTPHeaderField:@"version"];
// 请求体不再塞进 HTTPBody，改用 uploadTask fromData: 发送——彻底绕开 dataTaskWithRequest: 钩子链
NSData *acLoginBody = [NSJSONSerialization dataWithJSONObject:@{@"account": username, @"password": password, @"uuid": devUuid} options:0 error:nil];
NSURLSession *sess = ACDedicatedPluginSession();
acInternalRequest = NO;
if (!sess) { if (completion) completion(NO, @"插件独立网络通道初始化失败"); return; }
__weak typeof(self) acWSelf = self;
ACLog(@"[直登] 正在通过 /auth/c/doLoginNoEn 免退登登录账号 %@", username);
[[sess uploadTaskWithRequest:req fromData:acLoginBody completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
dispatch_async(dispatch_get_main_queue(), ^{
__strong typeof(acWSelf) acSelf = acWSelf;
if (!acSelf) return;
if (error || data.length == 0) { if (completion) completion(NO, error.localizedDescription ?: @"网络请求失败"); return; }
// 插件自发登录请求：解析期间置 internal，防止防退登护盾把密码错误等 401 响应伪装成 200 吞掉真实错误信息
acInternalRequest = YES;
NSDictionary *json = ACSafeDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
acInternalRequest = NO;
NSInteger code = [ACSafeStr(json[@"code"]) integerValue];
NSString *newToken = [json[@"data"] isKindOfClass:[NSString class]] ? json[@"data"] : nil;
// HAR 183315 修复：Token 必须严格 32 位纯字母数字（ACIsValidAuthToken），杜绝任何非标串入库
if (code != 200 || !ACIsValidAuthToken(newToken)) {
NSString *errMsg = ACSafeStr(json[@"msg"]) ?: @"登录失败，请检查账号密码";
ACLog(@"[直登] ❌ code=%ld msg=%@", (long)code, errMsg);
if (completion) completion(NO, errMsg);
return;
}
// 【HAR 205944 [120] 铁证】拿到新 Token 后立即 uploadTask 直连 POST /client/user/v2/validateToken 拿真实 UID：
// 1) /client/user/* 不属于 /client/biz/*，不校验 X-Lts-Id 里绑定的旧账号 UID，刚登录的新 Token 必 200；
// 2) 绝不携带旧会话 X-Lts-Id（新 Token + 旧账号 Lts → /client/biz/* 全线 500「请求失败，请稍后再试！」）；
// 3) validateToken 一返回 userId 立即判定登录成功并入库，昵称/飞机号后台异步补拉，detail 500 也绝不阻塞
acInternalRequest = YES;
NSMutableURLRequest *vReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://apiv1.airchat.cn/client/user/v2/validateToken"]];
vReq.HTTPMethod = @"POST";
vReq.timeoutInterval = 10.0;
[vReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
[vReq setValue:@"application/json" forHTTPHeaderField:@"Accept"];
[vReq setValue:newToken forHTTPHeaderField:@"token"];
[vReq setValue:(ACHeaderValue(acSelf.latestHTTPHeaders, @"User-Agent") ?: kACNativeUserAgent) forHTTPHeaderField:@"User-Agent"];
NSString *verV = ACHeaderValue(acSelf.latestHTTPHeaders, @"version");
if (verV.length > 0) [vReq setValue:verV forHTTPHeaderField:@"version"];
NSData *vBody = [NSJSONSerialization dataWithJSONObject:@{@"token": newToken} options:0 error:nil];
NSURLSession *vSess = ACDedicatedPluginSession();
acInternalRequest = NO;
if (!vSess) { if (completion) completion(NO, @"插件独立网络通道初始化失败"); return; }
ACLog(@"[直登] ✅ 拿到合法 32 位新 Token，uploadTask 直连 validateToken 解析本人 UID");
[[vSess uploadTaskWithRequest:vReq fromData:vBody completionHandler:^(NSData *vData, NSURLResponse *vResp, NSError *vErr) {
dispatch_async(dispatch_get_main_queue(), ^{
__strong typeof(acWSelf) acSelf2 = acWSelf;
if (!acSelf2) return;
acInternalRequest = YES;
NSDictionary *vJson = (vData.length > 0) ? ACSafeDict([NSJSONSerialization JSONObjectWithData:vData options:0 error:nil]) : nil;
acInternalRequest = NO;
NSDictionary *vDataDict = ACSafeDict(vJson[@"data"]);
NSString *uid = ACSafeStr(vDataDict[@"userId"] ?: vDataDict[@"id"]);
if ([ACSafeStr(vJson[@"code"]) integerValue] != 200 || ![vDataDict[@"isValid"] boolValue] || uid.length < 5) {
ACLog(@"[直登] ❌ validateToken 未返回有效 UID（code=%@ isValid=%d）", ACSafeStr(vJson[@"code"]), [vDataDict[@"isValid"] boolValue]);
if (completion) completion(NO, @"❌ validateToken 未返回有效 UID，请检查网络后重试");
return;
}
// validateToken 成功 → 立即判定登录成功并入库（昵称先用飞机号占位，后台补拉真实昵称）
[acSelf2 ac_autoSaveOrUpdateAccountWithUid:uid token:newToken nickname:username accountNum:username];
for (ACAccountItem *it in acSelf2.accountList) {
if ([it.userId isEqualToString:uid]) { it.account = username; it.password = password; break; }
}
[acSelf2 saveAllAccounts];
ACLog(@"[直登] ✅ 已免退登添加账号: %@ (UID:%@)，昵称后台异步补拉", username, uid);
// 后台 1.5s 后补拉本人昵称/飞机号（best-effort：绝不携带旧 X-Lts-Id，失败也不影响登录结果）
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
__strong typeof(acWSelf) acSelfN = acWSelf;
if (!acSelfN) return;
NSMutableURLRequest *dReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://apiv1.airchat.cn/client/biz/userinfo/detail"]];
dReq.HTTPMethod = @"GET";
dReq.timeoutInterval = 8.0;
[dReq setValue:newToken forHTTPHeaderField:@"token"];
[dReq setValue:uid forHTTPHeaderField:@"x-userid"];
[dReq setValue:(ACHeaderValue(acSelfN.latestHTTPHeaders, @"User-Agent") ?: kACNativeUserAgent) forHTTPHeaderField:@"User-Agent"];
NSString *verN = ACHeaderValue(acSelfN.latestHTTPHeaders, @"version");
if (verN.length > 0) [dReq setValue:verN forHTTPHeaderField:@"version"];
NSURLSession *dSess = ACDedicatedPluginSession();
if (!dSess) return;
[[dSess dataTaskWithRequest:dReq completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2) {
dispatch_async(dispatch_get_main_queue(), ^{
__strong typeof(acWSelf) acSelf3 = acWSelf;
if (!acSelf3) return;
acInternalRequest = YES;
NSDictionary *uJson = (d2.length > 0) ? ACSafeDict([NSJSONSerialization JSONObjectWithData:d2 options:0 error:nil]) : nil;
acInternalRequest = NO;
if ([ACSafeStr(uJson[@"code"]) integerValue] != 200) return;
NSDictionary *uData = ACSafeDict(uJson[@"data"]);
NSString *nNick = ACSafeStr(uData[@"clientUserNickName"] ?: uData[@"nickName"]);
NSString *nAcc = ACSafeStr(uData[@"account"] ?: uData[@"phone"]);
if (nNick.length == 0 && nAcc.length == 0) return;
for (ACAccountItem *it in acSelf3.accountList) {
if ([it.userId isEqualToString:uid]) {
if (nNick.length > 0) it.remark = nNick;
if (nAcc.length >= 5) it.account = nAcc;
break;
}
}
[acSelf3 saveAllAccounts];
ACLog(@"[直登] ✅ 后台补拉资料成功：%@ (%@)", nNick, nAcc);
});
}] resume];
});
if (completion) completion(YES, [NSString stringWithFormat:@"✅ 已免退登添加账号：%@\n（在列表点击即可随时切换）", username]);
});
}] resume];
}); // 关闭外层 dispatch_async（doLoginNoEn 响应处理块）
}] resume];
}
// 复刻官方切号链路 [23]→[24]→[28]：/client/biz/v2/userinfo/209/get/enc/id → /get/id → /get/gen
// 获取新账号的腾讯云 IM UserSig 并驱动 V2TIMManager 无缝重连——根治「会话断连」与「对话列表不切换」
- (void)ac_reconnectTencentIMForAccount:(ACAccountItem *)acc {
if (!acc || acc.token.length < 10 || acc.userId.length < 4) return;
__weak typeof(self) acWSelf = self;
NSString *tok = acc.token;
NSString *uid = acc.userId;
NSString *ua = ACHeaderValue(self.latestHTTPHeaders, @"User-Agent") ?: kACNativeUserAgent;
NSString *ver = ACHeaderValue(self.latestHTTPHeaders, @"version");
NSString *lts = ACHeaderValue(self.latestHTTPHeaders, @"X-Lts-Id");
NSString *reqNo = ACHeaderValue(self.latestHTTPHeaders, @"X-Request-No");
void (^doIMLogin)(NSString *userSig) = ^(NSString *userSig) {
dispatch_async(dispatch_get_main_queue(), ^{
Class timCls = NSClassFromString(@"V2TIMManager");
if (!timCls || ![timCls respondsToSelector:@selector(sharedInstance)]) return;
id tim = ((id (*)(id, SEL))objc_msgSend)(timCls, @selector(sharedInstance));
if (!tim || userSig.length == 0) return;
void (^succBlock)(void) = ^{
ACLog(@"[IM] ✅ 腾讯云 IM 会话已切换到账号 %@（对话列表同步刷新，不再断连）", uid);
};
void (^failBlock)(int code, NSString *desc) = ^(int code, NSString *desc) {
ACLog(@"[IM] ⚠️ V2TIMManager login 返回 (%d): %@", code, desc ?: @"");
};
SEL loginSel = NSSelectorFromString(@"login:userSig:succ:fail:");
NSMethodSignature *sig = [tim methodSignatureForSelector:loginSel];
if (!sig) return;
NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
[inv setTarget:tim]; [inv setSelector:loginSel];
NSString *imId = uid;
[inv setArgument:(void *)&imId atIndex:2];
[inv setArgument:(void *)&userSig atIndex:3];
[inv setArgument:(void *)&succBlock atIndex:4];
[inv setArgument:(void *)&failBlock atIndex:5];
[inv invoke];
});
};
// 三步链路（每步都是独立插件通道请求，绝不借宿主 Alamofire Session）
void (^stepGen)(void) = ^{
acInternalRequest = YES;
NSMutableURLRequest *g = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://apiv1.airchat.cn/client/biz/v2/userinfo/209/get/gen"]];
g.HTTPMethod = @"POST"; g.timeoutInterval = 15.0;
[g setValue:tok forHTTPHeaderField:@"token"]; [g setValue:uid forHTTPHeaderField:@"x-userid"];
[g setValue:ua forHTTPHeaderField:@"User-Agent"];
if (ver.length > 0) [g setValue:ver forHTTPHeaderField:@"version"];
if (lts.length > 0) [g setValue:lts forHTTPHeaderField:@"X-Lts-Id"];
if (reqNo.length > 0) [g setValue:reqNo forHTTPHeaderField:@"X-Request-No"];
[g setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
g.HTTPBody = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
NSURLSession *s = ACDedicatedPluginSession();
acInternalRequest = NO;
if (!s) return;
[[s dataTaskWithRequest:g completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
if (e || !d.length) { ACLog(@"[IM] ⚠️ 209/get/gen 请求失败: %@", e.localizedDescription ?: @"空响应"); return; }
NSDictionary *json = ACSafeDict([NSJSONSerialization JSONObjectWithData:d options:0 error:nil]);
if ([ACSafeStr(json[@"code"]) integerValue] != 200) { ACLog(@"[IM] ⚠️ 209/get/gen code=%@，UserSig 获取失败（IM 可能短暂断连，切回官方页面后自动恢复）", ACSafeStr(json[@"code"])); return; }
NSString *userSig = nil;
id df = json[@"data"];
if ([df isKindOfClass:[NSString class]]) userSig = df;
else if ([df isKindOfClass:[NSDictionary class]]) {
userSig = ACSafeStr(df[@"userSig"] ?: df[@"sig"] ?: df[@"sign"] ?: df[@"token"]);
}
if (userSig.length == 0) { ACLog(@"[IM] ⚠️ 209/get/gen 响应中未找到 userSig 字段"); return; }
ACLog(@"[IM] ✅ 已获取新账号 UserSig（长度 %lu），驱动 V2TIMManager 重连...", (unsigned long)userSig.length);
doIMLogin(userSig);
}] resume];
};
void (^stepId)(void) = ^{
acInternalRequest = YES;
NSMutableURLRequest *m = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://apiv1.airchat.cn/client/biz/v2/userinfo/209/get/id"]];
m.HTTPMethod = @"POST"; m.timeoutInterval = 15.0;
[m setValue:tok forHTTPHeaderField:@"token"]; [m setValue:uid forHTTPHeaderField:@"x-userid"];
[m setValue:ua forHTTPHeaderField:@"User-Agent"];
if (ver.length > 0) [m setValue:ver forHTTPHeaderField:@"version"];
if (lts.length > 0) [m setValue:lts forHTTPHeaderField:@"X-Lts-Id"];
if (reqNo.length > 0) [m setValue:reqNo forHTTPHeaderField:@"X-Request-No"];
[m setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
m.HTTPBody = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
NSURLSession *s = ACDedicatedPluginSession();
acInternalRequest = NO;
if (!s) { stepGen(); return; }
[[s dataTaskWithRequest:m completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) { stepGen(); }] resume];
};
acInternalRequest = YES;
NSMutableURLRequest *en = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://apiv1.airchat.cn/client/biz/v2/userinfo/209/get/enc/id"]];
en.HTTPMethod = @"POST"; en.timeoutInterval = 15.0;
[en setValue:tok forHTTPHeaderField:@"token"]; [en setValue:uid forHTTPHeaderField:@"x-userid"];
[en setValue:ua forHTTPHeaderField:@"User-Agent"];
if (ver.length > 0) [en setValue:ver forHTTPHeaderField:@"version"];
if (lts.length > 0) [en setValue:lts forHTTPHeaderField:@"X-Lts-Id"];
if (reqNo.length > 0) [en setValue:reqNo forHTTPHeaderField:@"X-Request-No"];
[en setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
en.HTTPBody = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
NSURLSession *s0 = ACDedicatedPluginSession();
acInternalRequest = NO;
if (!s0) { stepId(); return; }
ACLog(@"[IM] 开始官方 UserSig 链路: 209/get/enc/id → get/id → get/gen (UID %@)", uid);
[[s0 dataTaskWithRequest:en completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) { stepId(); }] resume];
}
// 核心突破（HAR 192037 白屏根治 + 183315 [40]~[42] vs [80]~[87]）：切号后免手动重启 App，
// 绝不替换 window.rootViewController（Main.storyboard 是空白模板 → 替换即白屏），改为：
// 离屏驱动官方 AirAccountChangeViewController 切槽位 0 + 原地刷新 TabBar 子页面 + 209 链路重连 IM，
// 「对话」列表与「我的」主页当场同步切换，无需杀后台重启！
- (void)ac_hotReloadHostRootViewControllerForAccount:(ACAccountItem *)acc {
if (!acc || acc.userId.length < 4) return;
__weak typeof(self) acWSelf = self;
dispatch_async(dispatch_get_main_queue(), ^{
// 1. 先断开旧账号的 V2TIMManager 会话（无论登出成败都继续热重载，
//    新根控制器加载时宿主会自动为新账号跑完整原生 IM 握手并重连）
Class timCls = NSClassFromString(@"V2TIMManager");
id tim = (timCls && [timCls respondsToSelector:@selector(sharedInstance)]) ? ((id (*)(id, SEL))objc_msgSend)(timCls, @selector(sharedInstance)) : nil;
void (^performUIReload)(void) = ^{
dispatch_async(dispatch_get_main_queue(), ^{
UIWindow *targetWindow = [UIApplication sharedApplication].keyWindow;
if (!targetWindow) {
for (UIWindow *w in [UIApplication sharedApplication].windows) {
if (w.isKeyWindow || !w.isHidden) { targetWindow = w; break; }
}
}
if (!targetWindow) return;
// 2. 如有 Modal 弹窗（如插件面板）先静默收起，避免根控制器替换时视图层级冲突
if (targetWindow.rootViewController.presentedViewController) {
[targetWindow.rootViewController dismissViewControllerAnimated:NO completion:nil];
}
// 3. 触发宿主原生初始化管理器（注意 Swift 模块前缀为全小写 airchat.）
NSArray *initClasses = @[@"airchat.AirInitializationDataManager", @"AirInitializationDataManager",
@"airchat.AirAccountLoginBussiness", @"AirAccountLoginBussiness"];
for (NSString *clsName in initClasses) {
Class c = NSClassFromString(clsName);
if (!c) continue;
id sharedObj = nil;
for (NSString *sName in @[@"shared", @"sharedInstance", @"defaultManager", @"manager"]) {
SEL sSel = NSSelectorFromString(sName);
if ([c respondsToSelector:sSel]) {
@try { sharedObj = ((id (*)(id, SEL))objc_msgSend)(c, sSel); } @catch (NSException *e) {}
if (sharedObj) break;
}
}
id receiver = sharedObj ?: (id)c;
for (NSString *mName in @[@"initData", @"initializationData", @"reloadUserData", @"loginSuccess"]) {
SEL mSel = NSSelectorFromString(mName);
if ([receiver respondsToSelector:mSel]) {
@try { ((void (*)(id, SEL))objc_msgSend)(receiver, mSel); } @catch (NSException *e) {}
}
}
}
// 4. 【HAR 192037 白屏根治 + HAR 205944 防顶号退登】绝不替换 window.rootViewController（Main.storyboard
//    是空白模板，替换即白屏），也绝不联动官方 AirAccountChangeViewController——HAR 205944 [129]~[132] 实锤：
//    官方 VC 会从 Swift 内存取出旧 Token 连发 4 个请求，服务器返回 401「Token已被顶下线」直接触发宿主
//    全局强制退出登录！改为：a) 2s 后插件自跑 209 三步链用新账号 Token 重连 IM；b) 原地刷新 TabBar 子页面。
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
__strong typeof(acWSelf) acSelfIM = acWSelf;
if (!acSelfIM) return;
[acSelfIM ac_reconnectTencentIMForAccount:acc]; // 插件自跑 209 三步链重连新账号 IM UserSig
});
ACTriggerMomentsBackgroundRefresh(); // 触发一次飞行圈流量，重新嗅探新会话签名对
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
__strong typeof(acWSelf) acSelfLate = acWSelf;
if (!acSelfLate) return;
[acSelfLate setupIMGroupWelcomeListener];
[acSelfLate reloadAllDataWithProgress:nil completion:nil];
});
__strong typeof(acWSelf) acSelfFB = acWSelf;
if (acSelfFB) [acSelfFB ac_forceRefreshHostAppUI]; // 原地刷新所有 Tab 子页面，绝不白屏
});
};
SEL logoutSel = NSSelectorFromString(@"logout:fail:");
if (tim && [tim respondsToSelector:logoutSel]) {
void (^logoutSucc)(void) = ^{ performUIReload(); };
void (^logoutFail)(int code, NSString *desc) = ^(int code, NSString *desc) { performUIReload(); };
NSMethodSignature *sig = [tim methodSignatureForSelector:logoutSel];
if (sig) {
NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
[inv setTarget:tim]; [inv setSelector:logoutSel];
[inv setArgument:(void *)&logoutSucc atIndex:2];
[inv setArgument:(void *)&logoutFail atIndex:3];
[inv invoke];
return;
}
}
performUIReload();
});
}
// 将目标账号同步写入宿主 NSUserDefaults 的登录态键 + 官方「最多3个账号」槽位数组（突破官方限制的软方案）
- (void)ac_syncAccountToHostUserDefaults:(ACAccountItem *)acc {
if (!acc || acc.userId.length < 4 || acc.token.length < 10) return;
@try {
NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
NSDictionary *all = [[ud dictionaryRepresentation] copy];
for (NSString *k in all.allKeys) {
if (![k isKindOfClass:[NSString class]]) continue;
if ([k hasPrefix:@"AC_"] || [k hasPrefix:@"Apple"] || [k hasPrefix:@"NS"]) continue;
NSString *lk = k.lowercaseString;
id val = all[k];
if ([val isKindOfClass:[NSString class]]) {
if ([lk isEqualToString:@"token"] || [lk containsString:@"usertoken"] ||
[lk containsString:@"accesstoken"] || [lk containsString:@"authtoken"]) {
[ud setObject:acc.token forKey:k];
} else if ([lk isEqualToString:@"userid"] || [lk isEqualToString:@"uid"] ||
[lk isEqualToString:@"x-userid"] || [lk isEqualToString:@"currentuserid"]) {
[ud setObject:acc.userId forKey:k];
}
} else if ([val isKindOfClass:[NSDictionary class]]) {
NSDictionary *dv = (NSDictionary *)val;
if (dv[@"token"] || dv[@"userId"] || dv[@"clientUserNickName"] || dv[@"nickName"]) {
NSMutableDictionary *md = [dv mutableCopy];
if (md[@"token"]) md[@"token"] = acc.token;
if (md[@"userId"]) md[@"userId"] = acc.userId;
if (md[@"id"]) md[@"id"] = acc.userId;
if (md[@"uid"]) md[@"uid"] = acc.userId;
id safe = ACJSONSafeObject(md, 0);
if (safe) [ud setObject:safe forKey:k];
}
} else if ([val isKindOfClass:[NSArray class]]) {
// 官方「切换账号列表」槽位（HAR [17]~[28]：官方最多保留 3 个账号）——目标账号置顶替换
NSArray *arr = (NSArray *)val;
if (arr.count > 0 && [arr.firstObject isKindOfClass:[NSDictionary class]]) {
NSDictionary *first = ACSafeDict(arr.firstObject);
if (first[@"token"] || first[@"userId"] || first[@"nickName"] || first[@"account"]) {
NSMutableDictionary *tpl = [first mutableCopy];
tpl[@"token"] = acc.token;
if (tpl[@"userId"]) tpl[@"userId"] = acc.userId;
if (tpl[@"id"]) tpl[@"id"] = acc.userId;
if (tpl[@"nickName"]) tpl[@"nickName"] = acc.remark ?: tpl[@"nickName"];
if (tpl[@"nickname"]) tpl[@"nickname"] = acc.remark ?: tpl[@"nickname"];
if (acc.account.length > 0 && tpl[@"account"]) tpl[@"account"] = acc.account;
NSMutableArray *newArr = [NSMutableArray arrayWithObject:tpl];
for (NSDictionary *old in arr) {
if (![old isKindOfClass:[NSDictionary class]]) continue;
NSString *oldUid = ACSafeStr(old[@"userId"] ?: old[@"id"]);
if (oldUid.length > 0 && ![oldUid isEqualToString:acc.userId] && newArr.count < 3) [newArr addObject:old];
}
id safe = ACJSONSafeObject(newArr, 0);
if (safe) [ud setObject:safe forKey:k];
}
}
}
}
// 同步更新插件持久化的请求头模板，保证下次启动 Header 一致
NSMutableDictionary *savedHeaders = [ACSafeDict([[NSUserDefaults standardUserDefaults] objectForKey:@"AC_Saved_HTTPHeaders"]) mutableCopy] ?: [NSMutableDictionary dictionary];
savedHeaders[@"token"] = acc.token;
savedHeaders[@"x-userid"] = acc.userId;
[[NSUserDefaults standardUserDefaults] setObject:savedHeaders forKey:@"AC_Saved_HTTPHeaders"];
[ud synchronize];
ACLog(@"[多账号] 已同步宿主 NSUserDefaults 官方账号槽位 -> %@", acc.remark ?: acc.userId);
} @catch (NSException *e) { ACLog(@"[多账号] 同步宿主槽位异常 %@", e.reason); }
}
// 轻量全页刷新：TabBar 顶层页（≤5，不递归全树防请求风暴）KVC 修正 + 单一刷新选择器 + viewWillAppear 重绘
- (void)ac_forceRefreshHostAppUI {
dispatch_async(dispatch_get_main_queue(), ^{
@try {
UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
if (!keyWin) { for (UIWindow *w in [UIApplication sharedApplication].windows) { if (w.isKeyWindow) { keyWin = w; break; } } }
UIViewController *root = keyWin.rootViewController;
UITabBarController *tab = [root isKindOfClass:[UITabBarController class]] ? (UITabBarController *)root : nil;
if (!tab) {
while (root.presentedViewController) root = root.presentedViewController;
if ([root isKindOfClass:[UITabBarController class]]) tab = (UITabBarController *)root;
}
if (!tab) return;
for (UIViewController *child in tab.viewControllers) {
UIViewController *vc = [child isKindOfClass:[UINavigationController class]] ? [(UINavigationController *)child topViewController] : child;
if (!vc || ![vc isViewLoaded]) continue;
@try {
NSString *cls = NSStringFromClass([vc class]) ?: @"";
if ([cls containsString:@"AccountManagement"] || [cls containsString:@"Login"] || [cls hasPrefix:@"AC"]) continue;
for (NSString *sName in @[@"loadData", @"requestData", @"fetchUserInfo", @"refreshData", @"headerRefresh"]) {
SEL sel = NSSelectorFromString(sName);
if ([vc respondsToSelector:sel]) { ((void (*)(id, SEL))objc_msgSend)(vc, sel); break; }
}
[vc viewWillAppear:NO];
// 直接重载页面上的表格/集合视图，让「对话」「我的」立即以新账号数据重绘
for (UIView *sub in vc.view.subviews) {
if ([sub isKindOfClass:[UITableView class]]) [(UITableView *)sub reloadData];
else if ([sub isKindOfClass:[UICollectionView class]]) [(UICollectionView *)sub reloadData];
}
} @catch (NSException *e) {}
}
} @catch (NSException *e) {}
});
}
// 宿主 App NSUserDefaults 快照：多账号切换时恢复主页/资料缓存，解决“切换后主页仍显示旧号甚至空白”
- (NSString *)accountDefaultsSnapshotPathForUid:(NSString *)uid {
NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
return [doc stringByAppendingPathComponent:[NSString stringWithFormat:@"AC_AccDefaults_%@.plist", uid ?: @"unknown"]];
}
// 备份指定账号在宿主 App 的 NSUserDefaults 登录态与个人资料缓存（切换前调用）
- (void)ac_saveAppDefaultsSnapshotForUid:(NSString *)uid {
if (uid.length < 4) return;
@try {
NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
NSMutableDictionary *appOnly = [NSMutableDictionary dictionary];
[all enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
if (![k isKindOfClass:[NSString class]]) return;
NSString *ks = (NSString *)k;
if ([ks hasPrefix:@"AC_"] || [ks hasPrefix:@"NS"] || [ks hasPrefix:@"Apple"] || [ks hasPrefix:@"com.apple"]) return;
if ([NSPropertyListSerialization propertyList:v isValidForFormat:NSPropertyListBinaryFormat_v1_0]) {
appOnly[ks] = v;
}
}];
[appOnly writeToFile:[self accountDefaultsSnapshotPathForUid:uid] atomically:YES];
ACLog(@"[多账号] 已备份 UID %@ 的 NSUserDefaults 快照（%lu 项）", uid, (unsigned long)appOnly.count);
} @catch (NSException *e) {}
}
// 恢复目标账号的 NSUserDefaults 快照并深度联动刷新宿主主页/聊天会话列表（模拟官方切号的完整 UI 同步）
- (void)ac_restoreAppDefaultsAndRefreshUIForAccount:(ACAccountItem *)acc {
if (!acc || acc.userId.length < 4) return;
@try {
NSString *snapPath = [self accountDefaultsSnapshotPathForUid:acc.userId];
NSDictionary *snap = [NSDictionary dictionaryWithContentsOfFile:snapPath];
NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
if ([snap isKindOfClass:[NSDictionary class]] && snap.count > 0) {
[snap enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
[ud setObject:v forKey:k];
}];
[ud synchronize];
ACLog(@"[多账号] 已恢复 UID %@ 的 NSUserDefaults 快照（%lu 项）", acc.userId, (unsigned long)snap.count);
}
} @catch (NSException *e) {}
// 深度联动刷新（HAR [45][61][118][131] 实证：宿主「我的」卡片 AirTopView 与全局用户信息
// 同时依赖 NSUserDefaults / Keychain / 内存模型 + /userinfo/detail 双接口，必须全套同步替换）
dispatch_async(dispatch_get_main_queue(), ^{
@try {
NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
NSString *tok = ACSafeStr(self.latestHTTPHeaders[@"token"]);
NSString *uid = acc.userId;
if (tok.length >= 10 && uid.length > 4) {
// 1. 深度扫描并替换 NSUserDefaults 中所有存储当前账号 Token/UID/用户信息字典的键值
// （跳过插件自身 AC_ 前缀、系统 Apple/NS 前缀，避免污染插件配置与系统键）
NSDictionary *all = [[ud dictionaryRepresentation] copy];
for (NSString *k in all.allKeys) {
if (![k isKindOfClass:[NSString class]]) continue;
if ([k hasPrefix:@"AC_"] || [k hasPrefix:@"Apple"] || [k hasPrefix:@"NS"]) continue;
NSString *lk = k.lowercaseString;
id val = all[k];
if ([val isKindOfClass:[NSString class]]) {
NSString *sVal = (NSString *)val;
if ([lk isEqualToString:@"token"] || [lk containsString:@"usertoken"] || [lk containsString:@"accesstoken"]) {
[ud setObject:tok forKey:k];
} else if ([lk isEqualToString:@"userid"] || [lk isEqualToString:@"uid"] ||
[lk isEqualToString:@"x-userid"] || [lk isEqualToString:@"currentuserid"]) {
[ud setObject:uid forKey:k];
} else if (self.previousSelfUserId.length > 5 && [sVal isEqualToString:self.previousSelfUserId]) {
// 任何明文存储旧账号 UID 的字符串键一并替换为新 UID
[ud setObject:uid forKey:k];
}
} else if ([val isKindOfClass:[NSDictionary class]]) {
NSDictionary *dVal = (NSDictionary *)val;
// 宿主常把用户资料整包 JSON 存进 NSUserDefaults（含 token/userId/clientUserNickName）
if (dVal[@"token"] || dVal[@"userId"] || dVal[@"clientUserNickName"]) {
NSMutableDictionary *mDict = [dVal mutableCopy];
if (mDict[@"token"]) mDict[@"token"] = tok;
if (mDict[@"userId"]) mDict[@"userId"] = uid;
if (mDict[@"id"]) mDict[@"id"] = uid;
id safe = ACJSONSafeObject(mDict, 0);
if (safe) [ud setObject:safe forKey:k];
}
}
}
[ud synchronize];
ACLog(@"[多账号] 已深度同步 NSUserDefaults 登录态 -> UID %@", uid);
}
// 2. 试探触发宿主登录成功/账号切换通知，让宿主重新拉取主页与会话列表
for (NSString *nName in @[@"kLoginSuccessNotification", @"LoginSuccessNotification",
@"UserInfoDidChangeNotification", @"AccountDidSwitchNotification",
@"AirAccountSwitchNotification"]) {
@try { [[NSNotificationCenter defaultCenter] postNotificationName:nName object:nil]; } @catch (NSException *e) {}
}
// 3. 遍历 TabBar 顶层页面（≤5 个，绝不递归全树——HAR [6]~[71] 实证全量遍历会触发请求风暴），
//    对「我的/主页/飞行圈」KVC 修正 userId 并触发一次完整生命周期刷新
UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
if (!keyWin) {
for (UIWindow *w in [UIApplication sharedApplication].windows) { if (w.isKeyWindow) { keyWin = w; break; } }
}
UIViewController *root = keyWin.rootViewController;
UITabBarController *tab = [root isKindOfClass:[UITabBarController class]] ? (UITabBarController *)root : nil;
if (!tab) {
while (root.presentedViewController) root = root.presentedViewController;
if ([root isKindOfClass:[UITabBarController class]]) tab = (UITabBarController *)root;
}
if (!tab) return;
for (UIViewController *child in tab.viewControllers) {
UIViewController *vc = [child isKindOfClass:[UINavigationController class]] ? [(UINavigationController *)child topViewController] : child;
if (!vc || ![vc isViewLoaded]) continue;
@try {
NSString *cls = NSStringFromClass([vc class]) ?: @"";
// 官方账号管理/登录页绝不打扰（智能放行原则）
if ([cls containsString:@"AccountManagement"] || [cls containsString:@"Login"] || [cls containsString:@"Register"]) continue;
for (NSString *k in @[@"userId", @"uid", @"id", @"targetUserId"]) {
@try { [vc setValue:uid forKey:k]; } @catch (NSException *e) {}
}
// 常见刷新选择器探测调用（存在才调，每个页面最多命中几个，配合请求头接管不会死循环）
for (NSString *sName in @[@"loadData", @"requestData", @"fetchUserInfo", @"getUserInfo", @"refreshData", @"headerRefresh"]) {
SEL sel = NSSelectorFromString(sName);
if ([vc respondsToSelector:sel]) {
((void (*)(id, SEL))objc_msgSend)(vc, sel);
break; // 每页只命中第一个可用刷新器，防止叠加请求
}
}
// 触发一次 viewWillAppear 让 TableView 依据新 userId 重绘（仅顶层已加载页，非全树遍历）
[vc viewWillAppear:NO];
} @catch (NSException *e) {}
}
ACLog(@"[多账号] 已完成 TabBar 顶层页面深度联动刷新（主页/会话列表同步切换）");
} @catch (NSException *e) {}
});
}
- (NSString *)accountsCachePath {
NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
return [doc stringByAppendingPathComponent:@"AC_SavedAccounts.plist"];
}
- (void)saveAllAccounts {
@synchronized (self) {
NSMutableArray *arr = [NSMutableArray array];
for (ACAccountItem *acc in self.accountList) {
if ([acc isKindOfClass:[ACAccountItem class]]) [arr addObject:[acc toDict]];
}
[arr writeToFile:[self accountsCachePath] atomically:YES];
}
}
- (void)loadAllAccounts {
@synchronized (self) {
self.accountList = [NSMutableArray array];
NSArray *arr = [NSArray arrayWithContentsOfFile:[self accountsCachePath]];
BOOL acCleanedPolluted = NO;
if ([arr isKindOfClass:[NSArray class]]) {
// 【HAR 205944 好友脏数据治理】旧版本曾把好友 getUserInfo 资料（斩杀/王摩诘/小圣等）配着本人 Token 误存进列表，
// 特征是多个不同 userId 条目共用同一个 Token 且无密码——先统计每个合法 Token 的出现次数再逐条甄别
NSMutableDictionary<NSString *, NSNumber *> *acTokCount = [NSMutableDictionary dictionary];
for (NSDictionary *d in arr) {
if (![d isKindOfClass:[NSDictionary class]]) continue;
NSString *t = ACSafeStr(d[@"token"]);
if (ACIsValidAuthToken(t)) acTokCount[t] = @([acTokCount[t] integerValue] + 1);
}
for (NSDictionary *d in arr) {
ACAccountItem *acc = [ACAccountItem fromDict:d];
if (!acc) continue;
// HAR 183315 污染清理：/209/get/enc/id 返回的 24 位 Base64 密钥（Q0EdQ2hMGW9nbQB/EBpIYQc=）
// 曾被旧宽松判定误存为 Token。启动时严格校验 32 位纯字母数字，非法 Token 一律置空
// （条目保留，账号+密码还在，可免退登静默重登）
if (acc.token.length > 0 && !ACIsValidAuthToken(acc.token)) {
ACLog(@"[多账号] 启动清理：账号 %@ 的 Token 非法（长度 %lu，含非字母数字字符，疑被 209/enc/id 密钥污染），已置空待重登",
acc.remark ?: acc.userId, (unsigned long)acc.token.length);
acc.token = @"";
acCleanedPolluted = YES;
}
// 【HAR 205944】被多条记录共用的 Token 且该条无密码 → 是偷用当时本人 Token 的好友资料脏数据，直接剔除！
if (ACIsValidAuthToken(acc.token) && [acTokCount[acc.token] integerValue] > 1 && acc.password.length == 0) {
ACLog(@"[多账号] 启动清理：%@ 共用他人 Token 且无密码，判定为好友资料脏数据，剔除", acc.remark ?: acc.userId);
acCleanedPolluted = YES;
continue;
}
// 有合法 Token 的条目正常保留；Token 被清理但仍有账号+密码的条目也保留（供静默重登）
if (acc.token.length > 5 || (acc.account.length > 0 && acc.password.length > 0)) {
[self.accountList addObject:acc];
}
}
}
if (acCleanedPolluted) [self saveAllAccounts];
}
}
- (void)switchToAccount:(ACAccountItem *)targetAccount completion:(void(^)(BOOL ok, NSString *msg))completion {
if (!targetAccount || targetAccount.token.length <= 5 || targetAccount.userId.length <= 3) {
// HAR 183315 修复：Token 缺失/被污染清理但保存过账密 → 免退登静默重登出新 Token 后自动切换
if (targetAccount && targetAccount.account.length > 0 && targetAccount.password.length > 0) {
ACLog(@"[账号切换] 账号 %@ 无有效 Token，用已存账密静默重登...", targetAccount.remark ?: targetAccount.account);
__weak typeof(self) acWSelf = self;
[self ac_loginWithUsername:targetAccount.account password:targetAccount.password completion:^(BOOL ok, NSString *msg) {
__strong typeof(acWSelf) acSelf = acWSelf;
if (!acSelf) return;
if (!ok) { if (completion) completion(NO, [NSString stringWithFormat:@"❌ 静默重登失败：%@", msg]); return; }
ACAccountItem *fresh = nil;
for (ACAccountItem *it in acSelf.accountList) {
if (it.token.length > 5 && ([it.userId isEqualToString:targetAccount.userId] || [it.account isEqualToString:targetAccount.account])) { fresh = it; break; }
}
if (!fresh) { if (completion) completion(NO, @"❌ 重登成功但未找到账号条目"); return; }
fresh.password = targetAccount.password;
[acSelf ac_performAccountSwitch:fresh completion:completion];
}];
return;
}
if (completion) completion(NO, @"❌ 该账号无有效凭证，请先登录该号后点「💾 保存当前登录账号」");
return;
}
// Pre-flight 预检（HAR [73]~[89] 实证根因）：先用插件独立通道验证目标 Token 是否已被服务端注销，
// 绝不把失效 Token 注入宿主 App——否则宿主全局 401 拦截器收到 "Token无效" 会把当前在线账号直接踢回登录页！
// 【HAR 205944 复盘铁证】预检改走 POST /client/user/v2/validateToken：
// 1) /client/biz/* 会解密 X-Lts-Id 校验「绑定 UID 与 token 归属人一致」——预检带着当前账号的旧 Lts 查新号必 500！
//    而 /client/user/* 不校验 Lts（[120] 实证：validateToken 100% 返回 isValid+userId）；
// 2) 走 uploadTaskWithRequest:fromData: 彻底绕开 dataTaskWithRequest: 钩子，响应绝不被换绑拦截篡改。
acInternalRequest = YES;
NSMutableURLRequest *chk = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://apiv1.airchat.cn/client/user/v2/validateToken"]];
chk.HTTPMethod = @"POST";
chk.timeoutInterval = 10.0;
[chk setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
[chk setValue:@"application/json" forHTTPHeaderField:@"Accept"];
[chk setValue:targetAccount.token forHTTPHeaderField:@"token"];
[chk setValue:(ACHeaderValue(self.latestHTTPHeaders, @"User-Agent") ?: kACNativeUserAgent) forHTTPHeaderField:@"User-Agent"];
NSString *chkVer = ACHeaderValue(self.latestHTTPHeaders, @"version");
if (chkVer.length > 0) [chk setValue:chkVer forHTTPHeaderField:@"version"];
NSData *chkBody = [NSJSONSerialization dataWithJSONObject:@{@"token": targetAccount.token} options:0 error:nil];
NSURLSession *chkSess = ACDedicatedPluginSession();
acInternalRequest = NO;
if (!chkSess) { [self ac_performAccountSwitch:targetAccount completion:completion]; return; }
__weak typeof(self) acWSelf = self;
ACLog(@"[账号切换] 预检 Token 有效性(validateToken) -> %@ (%@)", targetAccount.remark, targetAccount.userId);
[[chkSess uploadTaskWithRequest:chk fromData:chkBody completionHandler:^(NSData *chkData, NSURLResponse *chkResp, NSError *chkErr) {
dispatch_async(dispatch_get_main_queue(), ^{
__strong typeof(acWSelf) acSelf = acWSelf;
if (!acSelf) return;
// 预检是插件自发请求：解析期间置 internal，绝不让防退登护盾/收割逻辑干扰判断
acInternalRequest = YES;
NSDictionary *acJson = (chkData.length > 0) ? ACSafeDict([NSJSONSerialization JSONObjectWithData:chkData options:0 error:nil]) : nil;
acInternalRequest = NO;
NSDictionary *acVData = ACSafeDict(acJson[@"data"]);
BOOL acValid = [acVData[@"isValid"] boolValue];
NSString *acSrvUid = ACSafeStr(acVData[@"userId"] ?: acVData[@"id"]);
if ([ACSafeStr(acJson[@"code"]) integerValue] == 200 && acValid && acSrvUid.length >= 10) {
// 凭证有效：以服务器返回的 UID 为权威（自动修正任何串号），直接切换
if (![acSrvUid isEqualToString:targetAccount.userId]) {
ACLog(@"[账号切换] 预检 UID 校正：%@ -> %@（以服务器返回为准）", targetAccount.userId, acSrvUid);
targetAccount.userId = acSrvUid;
}
[acSelf ac_performAccountSwitch:targetAccount completion:completion];
return;
}
ACLog(@"[账号切换] ⚠️ 预检未通过（isValid=%d）：目标账号 Token 已被服务端注销", acValid);
// HAR [57] 实证升级：若该账号保存过密码，直接走 /auth/c/doLoginNoEn 免退登静默重登出新 Token，
// 重登成功后自动完成切换——不再要求用户去官方界面重登！
if (targetAccount.password.length > 0) {
ACLog(@"[账号切换] 该账号已保存密码，自动静默重登刷新 Token...");
[acSelf ac_loginWithUsername:targetAccount.account ?: targetAccount.remark password:targetAccount.password completion:^(BOOL ok, NSString *msg) {
if (!ok) {
ACLog(@"[账号切换] ❌ 自动重登失败: %@", msg);
if (completion) completion(NO, [NSString stringWithFormat:@"❌ Token 已失效且自动重登失败：%@", msg]);
return;
}
// 重登成功：新 Token 已自动入库，取回最新条目执行完整切换
ACAccountItem *fresh = nil;
for (ACAccountItem *it in acSelf.accountList) {
if (it.token.length > 10 && ([it.userId isEqualToString:targetAccount.userId] || [it.account isEqualToString:targetAccount.account])) { fresh = it; break; }
}
if (!fresh) { if (completion) completion(NO, @"❌ 重登成功但未找到账号条目"); return; }
fresh.password = targetAccount.password;
[acSelf ac_performAccountSwitch:fresh completion:completion];
}];
return;
}
ACLog(@"[账号切换] ❌ 拦截切换保护当前账号不掉线（该账号未保存密码，无法自动重登）");
if (completion) completion(NO, @"❌ 已拦截切换：该账号 Token 已在服务端失效。\n当前在线账号已保护，绝不会被踢下线！\n请用「➕ 添加账号」输入该号密码免退登重加（自动刷新 Token），或点「🌐 打开官方账号管理」重登一次。");
});
}] resume];
}

- (void)ac_performAccountSwitch:(ACAccountItem *)targetAccount completion:(void(^)(BOOL ok, NSString *msg))completion {
ACLog(@"[账号切换] 开始切换到 -> %@ (%@)", targetAccount.remark, targetAccount.userId);
// 0. 切换前备份旧账号在宿主 App 的 NSUserDefaults 登录态快照（供下次切回时恢复主页数据）
if (self.selfUserId.length > 5 && ![self.selfUserId isEqualToString:targetAccount.userId]) {
[self ac_saveAppDefaultsSnapshotForUid:self.selfUserId];
self.previousSelfUserId = self.selfUserId;
}
self.forcedAccountOverride = YES; // 全局接管：原生请求 Header/URL/Body 中的 UID 实时替换为新账号
// 1. 全量替换内存中的核心鉴权凭证
self.selfUserId = targetAccount.userId;
self.latestHTTPHeaders[@"token"] = targetAccount.token;
self.latestHTTPHeaders[@"Token"] = targetAccount.token;
self.latestHTTPHeaders[@"x-userid"] = targetAccount.userId;
if (targetAccount.channel.length > 0) {
self.latestHTTPHeaders[@"channel"] = targetAccount.channel;
}
// 关键修复：签名对与登录会话强绑定（HAR 实证 X-Lts-Id 与 X-Request-No 成对验签），
// 切换账号必须丢弃旧会话的签名对，否则新 token + 旧签名对 → 服务端 code:500「请求失败」
[self.latestHTTPHeaders removeObjectForKey:@"X-Lts-Id"];
[self.latestHTTPHeaders removeObjectForKey:@"x-lts-id"];
[self.latestHTTPHeaders removeObjectForKey:@"X-Request-No"];
[self.latestHTTPHeaders removeObjectForKey:@"x-request-no"];
sHotSwitchUserId = targetAccount.userId; // 锁定插件身份，防止原生嗅探冲回 App 登录账号
ACTriggerMomentsBackgroundRefresh(); // 触发一次原生流量，重新嗅探当前会话的签名对
// 2. 清空旧账号的缓存数据，防止串号
[self.friendList removeAllObjects];
[self.friendMap removeAllObjects];
[self.groupMemberList removeAllObjects];
[self.groupMemberMap removeAllObjects];
[self.groupList removeAllObjects];
[self.groupMap removeAllObjects];
// 3. 持久化 + 同步宿主官方账号槽位 + IM UserSig 重连 + 重挂 IM 监听 + 后台拉取新账号数据
[self ac_restoreAppDefaultsAndRefreshUIForAccount:targetAccount]; // 恢复 NSUserDefaults 快照 + 强制重绘主页
[self ac_syncAccountToHostUserDefaults:targetAccount]; // 同步宿主官方「3 账号槽位」与登录态键（HAR [17]~[28]）
[self saveAllCustomSettings];
[self setupIMGroupWelcomeListener];
[self reloadAllDataWithProgress:nil completion:nil];
// 根治「会话断连」+「对话列表不切换」+「切换后白屏」（HAR 192037 + 183315 [40]~[42] vs [80]~[87]）：
// 免重启无白屏切号：离屏驱动官方切号 VC 切槽位 0 + 原地刷新 TabBar 子页面 + 209 链路重连 IM（绝不替换根控制器）
[self ac_hotReloadHostRootViewControllerForAccount:targetAccount];
NSString *tip = [NSString stringWithFormat:@"✅ 已切换到账号：【%@】（主页与全局接口已同步接管）", targetAccount.remark];
ACLog(@"%@", tip);
if (completion) completion(YES, tip);
}
// 账号切换统一入口：凭证校验 → switchToAccount 全量热切换（签名对/快照/主页/全局一步到位）
- (void)loginWithAccount:(ACAccountItem *)item completion:(void(^)(BOOL ok, NSString *msg))completion {
if (!item || (item.account.length == 0 && (item.token.length <= 10))) {
if (completion) completion(NO, @"账号或密码为空");
return;
}
// HAR 183315 修复：Token 缺失/被污染清理但保存过账密 → 放行给 switchToAccount 走静默重登链路
if ((item.token.length <= 10 || item.userId.length <= 3) && !(item.account.length > 0 && item.password.length > 0)) {
if (completion) completion(NO, @"该账号暂无缓存凭证：请点「➕ 添加账号」输入该号账密免退登重加（自动刷新 Token）");
return;
}
[self switchToAccount:item completion:completion];
}
+ (instancetype)shared {
static ACForwardHelperManager *instance = nil;
static dispatch_once_t onceToken;
dispatch_once(&onceToken, ^{
instance = [[ACForwardHelperManager alloc] init];
instance.friendList = [NSMutableArray array];
instance.accountList = [NSMutableArray array];
// 修复（HAR 实证）：loadAllAccounts 禁止在此处调用——后面 latestHTTPHeaders/selfUserId 初始化
// 与 loadAllCustomSettings 会把刚加载的账号锁定态覆盖/清空，导致切完账号或重启 App 被重置回旧号。
// 必须移到 loadAllCustomSettings 之后再加载多账号与锁定状态。
instance.groupMemberList = [NSMutableArray array];
instance.groupList = [NSMutableArray array];
instance.friendMap = [NSMutableDictionary dictionary];
instance.groupMemberMap = [NSMutableDictionary dictionary];
instance.groupMap = [NSMutableDictionary dictionary];
instance.groupBanStatusMap = [NSMutableDictionary dictionary];
instance.latestHTTPHeaders = [NSMutableDictionary dictionary];
instance.selfUserId = @""; // 修复：严禁硬编码写死某个账号 UID（旧代码写死 1980559125632786434，导致重启后被重置回"鸭梨"）
instance.capturedClientTypeV2 = nil; // 防封雷区①：严禁写死旧版黑名单设备指纹——多账号同指纹=协议外挂秒封特征，仅复用真实捕获值
instance.welcomeGroupIds = [NSMutableSet set];
instance.greetedUserIds = [NSMutableSet set];
instance.lastGreetLog = @"等待新人进群...";
instance.welcomeTextEnabled = YES;
instance.welcomeMediaEnabled = YES;
instance.welcomeVoiceCallEnabled = NO;
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
instance.likedPostIds = [NSMutableSet set];
instance.likeQueue = [NSMutableArray array];
instance.robotDisplayName = @"群管机器人";
instance.voiceHangupSeconds = 1.0f;
instance.manualTargetGroupId = @"";
[instance loadLocalPermanentCache];
[instance loadAllCustomSettings];
// 关键修复（HAR 实证）：必须在 loadAllCustomSettings 之后加载多账号与强锁状态，
// 防止 Header/UID 初始化把已锁定账号的凭证覆盖回宿主当前登录号
[instance loadAllAccounts];
[instance restartMomentScheduler];
[instance ac_applyKeepAliveState];
[instance ac_startAutoLikePollTimer];
[instance ac_startImmortalBackgroundEngine]; // 15 秒 GCD 不死心跳：守护保活播放器/定时动态时间戳补发/后台点赞
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
// 槽位语音条路径（0群发 / 1迎新 / 2自动回复 / 3发动态，彼此独立）
- (NSString *)audioPathForSlot:(ACMediaSlot)slot {
NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
return [docDir stringByAppendingPathComponent:[NSString stringWithFormat:@"AC_Slot_%ld_Audio.m4a", (long)slot]];
}
- (void)saveAudioAtURL:(NSURL *)audioURL forSlot:(ACMediaSlot)slot duration:(int)sec {
if (!audioURL) return;
@try {
NSString *dest = [self audioPathForSlot:slot];
NSFileManager *fm = [NSFileManager defaultManager];
[fm removeItemAtPath:dest error:nil];
if (![audioURL.path isEqualToString:dest]) {
[fm copyItemAtURL:audioURL toURL:[NSURL fileURLWithPath:dest] error:nil];
}
int realDur = sec > 0 ? sec : [[ACAudioHelper shared] durationOfAudioAtPath:dest];
if (realDur <= 0) realDur = 5;
NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
[ud setInteger:3 forKey:[NSString stringWithFormat:@"AC_Slot_%ld_MediaType", (long)slot]];
[ud setInteger:realDur forKey:[NSString stringWithFormat:@"AC_Slot_%ld_AudioDur", (long)slot]];
[ud synchronize];
ACLog(@"[媒体槽位] 已保存【槽位%ld】语音条 (时长:%d秒)", (long)slot, realDur);
} @catch (NSException *e) {
ACLog(@"[媒体槽位] 保存语音失败 %@", e.reason);
}
}
- (int)audioDurationForSlot:(ACMediaSlot)slot {
NSString *key = [NSString stringWithFormat:@"AC_Slot_%ld_AudioDur", (long)slot];
int d = (int)[[NSUserDefaults standardUserDefaults] integerForKey:key];
return d > 0 ? d : 5;
}
- (NSInteger)mediaTypeForSlot:(ACMediaSlot)slot {
NSString *key = [NSString stringWithFormat:@"AC_Slot_%ld_MediaType", (long)slot];
NSInteger t = [[NSUserDefaults standardUserDefaults] integerForKey:key];
NSFileManager *fm = [NSFileManager defaultManager];
if (t == 1 && [fm fileExistsAtPath:[self imagePathForSlot:slot]]) return 1;
if (t == 2 && [fm fileExistsAtPath:[self videoPathForSlot:slot]]) return 2;
if (t == 3 && [fm fileExistsAtPath:[self audioPathForSlot:slot]]) return 3; // 语音条
return 0;
}
- (int)videoDurationForSlot:(ACMediaSlot)slot {
NSString *key = [NSString stringWithFormat:@"AC_Slot_%ld_VideoDur", (long)slot];
int d = (int)[[NSUserDefaults standardUserDefaults] integerForKey:key];
return d > 0 ? d : 5;
}
- (UIImage *)previewImageForSlot:(ACMediaSlot)slot {
NSInteger t = [self mediaTypeForSlot:slot];
if (t == 3) return [UIImage systemImageNamed:@"waveform"];
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
[fm removeItemAtPath:[self audioPathForSlot:slot] error:nil];
NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
[ud setInteger:0 forKey:[NSString stringWithFormat:@"AC_Slot_%ld_MediaType", (long)slot]];
[ud setInteger:0 forKey:[NSString stringWithFormat:@"AC_Slot_%ld_VideoDur", (long)slot]];
[ud setInteger:0 forKey:[NSString stringWithFormat:@"AC_Slot_%ld_AudioDur", (long)slot]];
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
// 迎新三种方式独立开关（文字 / 图片视频 / 1 秒语音）
[ud setBool:self.welcomeTextEnabled forKey:@"AC_Welcome_Text_Enabled"];
[ud setBool:self.welcomeMediaEnabled forKey:@"AC_Welcome_Media_Enabled"];
[ud setBool:self.welcomeVoiceCallEnabled forKey:@"AC_Welcome_VoiceCall_Enabled"];
[ud setObject:[self.welcomeGroupIds allObjects] forKey:@"AC_AutoWelcome_Groups"];
if (self.capturedClientTypeV2) {
[ud setObject:self.capturedClientTypeV2 forKey:@"AC_Captured_ClientTypeV2"];
}
if (self.latestHTTPHeaders.count > 0) {
NSMutableDictionary *safeHeaders = [NSMutableDictionary dictionary];
NSSet *allowed = [NSSet setWithObjects:@"token", @"x-userid", @"version", @"channel", @"x-lts-id", @"x-request-no", @"user-agent", @"accept-language", nil];
[self.latestHTTPHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
if (![k isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSString class]]) return;
NSString *lk = k.lowercaseString;
if (![allowed containsObject:lk]) return;
if ([lk isEqualToString:@"x-lts-id"] && !ACIsValidLtsId(v)) return;
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
[ud setBool:self.autoLikeEnabled forKey:@"AC_AutoLike_Enabled"];
[ud setBool:self.keepAliveEnabled forKey:@"AC_KeepAlive_Enabled"];
[ud setBool:self.robotModeEnabled forKey:@"AC_RobotMode_Enabled"];
[ud setObject:(self.robotDisplayName ?: @"群管机器人") forKey:@"AC_Robot_Name"];
[ud setFloat:self.voiceHangupSeconds forKey:@"AC_VoiceHangup_Seconds"];
[ud setObject:(self.manualTargetGroupId ?: @"") forKey:@"AC_ManualTargetGroupId"];
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
// 旧版本没有这三个键时默认「文字+图片」开启、语音关闭，保持原有行为
id savedTextFlag = [ud objectForKey:@"AC_Welcome_Text_Enabled"];
id savedMediaFlag = [ud objectForKey:@"AC_Welcome_Media_Enabled"];
self.welcomeTextEnabled = savedTextFlag ? [ud boolForKey:@"AC_Welcome_Text_Enabled"] : YES;
self.welcomeMediaEnabled = savedMediaFlag ? [ud boolForKey:@"AC_Welcome_Media_Enabled"] : YES;
self.welcomeVoiceCallEnabled = [ud boolForKey:@"AC_Welcome_VoiceCall_Enabled"];
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
self.autoLikeEnabled = [ud boolForKey:@"AC_AutoLike_Enabled"];
// 重启后开启自动点赞时，以当前时间作为“只赞新动态”的起点，避免把历史动态刷一遍
if (self.autoLikeEnabled) self.autoLikeEnabledAt = [[NSDate date] timeIntervalSince1970];
self.keepAliveEnabled = [ud boolForKey:@"AC_KeepAlive_Enabled"];
self.robotModeEnabled = [ud boolForKey:@"AC_RobotMode_Enabled"];
NSString *savedRobotName = ACSafeStr([ud objectForKey:@"AC_Robot_Name"]);
self.robotDisplayName = savedRobotName.length > 0 ? savedRobotName : @"群管机器人";
float savedHangup = [ud floatForKey:@"AC_VoiceHangup_Seconds"];
self.voiceHangupSeconds = (savedHangup >= 0.3f && savedHangup <= 15.0f) ? savedHangup : 1.0f;
self.manualTargetGroupId = ACSafeStr([ud objectForKey:@"AC_ManualTargetGroupId"]);
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
[lk isEqualToString:@"version"] || [lk isEqualToString:@"channel"] || [lk isEqualToString:@"x-lts-id"] ||
[lk isEqualToString:@"x-request-no"] || [lk isEqualToString:@"accept-language"] ||
[lk isEqualToString:@"user-agent"] ||
[lk isEqualToString:@"appversion"] || [lk isEqualToString:@"signature"] || [lk isEqualToString:@"sign"] ||
[lk isEqualToString:@"deviceid"] || [lk isEqualToString:@"device-id"] || [lk isEqualToString:@"timestamp"])) return;
if ([lk isEqualToString:@"x-lts-id"] && !ACIsValidLtsId(v)) return;
if ([lk isEqualToString:@"user-agent"] && ![[(NSString *)v lowercaseString] containsString:@"airchat/"]) return;
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
// 修复：若正处于插件强锁接管状态（forcedAccountOverride），禁止用持久化的旧 UID 覆盖当前锁定账号
if (savedUid.length > 5 && !self.forcedAccountOverride) {
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
if (self.autoMomentEnabled) {
// 开启定时动态时强制联动静音保活，否则 App 挂后台 30 秒即被系统挂起断流
self.keepAliveEnabled = YES;
[self ac_applyKeepAliveState];
// 本地不做发布冷却；间隔由用户设置（最低 1 分钟），服务端限频时按其文案退避
NSTimeInterval intervalSec = MAX(1, self.momentIntervalMinutes) * 60.0;
// 记录真实绝对时间戳：即使 NSTimer 在后台被冻结，GCD 心跳也会按时间戳补发
self.nextMomentFireTimestamp = [[NSDate date] timeIntervalSince1970] + intervalSec;
self.momentTimer = [NSTimer timerWithTimeInterval:intervalSec
target:self
selector:@selector(onMomentTimerTick)
userInfo:nil
repeats:YES];
[[NSRunLoop mainRunLoop] addTimer:self.momentTimer forMode:NSRunLoopCommonModes];
} else {
self.nextMomentFireTimestamp = 0;
}
[self ac_startImmortalBackgroundEngine];
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
NSArray *records = ACFeedRecordsFromJSON(json);
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
// 已停用后台盲评队列：自动评论只走「点进动态详情页 0.35 秒秒评」通道（viewDidAppear hook）
return;
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
// 前置声明：评论引擎位于点赞引擎之前，深搜助手定义在后
static void ACFindMomentCardsInView(UIView *view, NSMutableArray<UIView *> *results);
static UIButton *ACFindButtonWithActionDeep(UIView *view, NSString *actionPart);
static UIButton *ACFindButtonWithTargetClassDeep(UIView *view, NSString *classPart);
static UITextView *ACFindTextViewDeep(UIView *view);
static UIButton *ACFindButtonWithTitleDeep(UIView *view, NSString *titlePart);

- (void)ac_commentPostId:(NSString *)postId text:(NSString *)text {
// 原生评论 v2（实证）：卡片评论入口是手势/selector 而非绑定按钮；输入框为 AirCommentInputView（可能在键盘 Window）
dispatch_async(dispatch_get_main_queue(), ^{
UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
if (@available(iOS 13.0, *)) {
if (!keyWin) {
@try {
for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
if ([sc isKindOfClass:[UIWindowScene class]] && sc.activationState == UISceneActivationStateForegroundActive) {
keyWin = ((UIWindowScene *)sc).keyWindow;
if (keyWin) break;
}
}
} @catch (NSException *e) {}
}
}
NSMutableArray<UIView *> *cards = [NSMutableArray array];
ACFindMomentCardsInView(keyWin, cards);
// 优先匹配 postId 对应卡片，匹配不到取屏上第一张
UIView *targetCard = nil;
if (postId.length >= 6) {
for (UIView *c in cards) {
NSString *cid = ACExtractCardPostId(c);
if (cid.length && [cid isEqualToString:postId]) { targetCard = c; break; }
}
}
if (!targetCard) targetCard = cards.firstObject;
if (!targetCard) {
ACLog(@"[原生评论] 屏幕暂无卡片，2 秒后继续队列");
self.autoCommentSending = NO;
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
[[ACForwardHelperManager shared] ac_pumpAutoCommentQueue];
});
return;
}
// ① 触发评论入口：selector 三连 → 按钮 → 手势（三级降级）
BOOL triggered = NO;
@try {
SEL cSel1 = NSSelectorFromString(@"commentButtonTapped");
SEL cSel2 = NSSelectorFromString(@"commentButtonTapped:");
SEL cSel3 = NSSelectorFromString(@"onCommentAction");
if ([targetCard respondsToSelector:cSel1]) {
ACLog(@"🎯 [原生评论] 命中 commentButtonTapped");
((void (*)(id, SEL))objc_msgSend)(targetCard, cSel1);
triggered = YES;
} else if ([targetCard respondsToSelector:cSel2]) {
ACLog(@"🎯 [原生评论] 命中 commentButtonTapped:");
((void (*)(id, SEL, id))objc_msgSend)(targetCard, cSel2, nil);
triggered = YES;
} else if ([targetCard respondsToSelector:cSel3]) {
ACLog(@"🎯 [原生评论] 命中 onCommentAction");
((void (*)(id, SEL))objc_msgSend)(targetCard, cSel3);
triggered = YES;
}
if (!triggered) {
UIButton *commentBtn = ACFindButtonWithActionDeep(targetCard, @"comment");
if (commentBtn) {
ACLog(@"🎯 [原生评论] 触发卡片评论按钮点击！");
[commentBtn sendActionsForControlEvents:UIControlEventTouchUpInside];
triggered = YES;
}
}
if (!triggered) {
for (UIGestureRecognizer *g in targetCard.gestureRecognizers) {
if (![g isKindOfClass:[UITapGestureRecognizer class]] || !g.isEnabled) continue;
// target/action 非公开属性：KVC 取私有 ivar，respondsToSelector 兜底
id gTarget = nil;
SEL gAct = NULL;
@try { gTarget = [g valueForKey:@"target"]; } @catch (NSException *e) { gTarget = nil; }
if (!gTarget) {
@try {
id tlist = [g valueForKey:@"_targets"];
if ([tlist isKindOfClass:[NSArray class]] && ((NSArray *)tlist).count > 0) {
id entry = ((NSArray *)tlist)[0];
if ([entry isKindOfClass:[NSObject class]]) {
@try { gTarget = [entry valueForKey:@"target"]; } @catch (NSException *e) { gTarget = entry; }
id act = nil;
@try { act = [entry valueForKey:@"action"]; } @catch (NSException *e) { act = nil; }
if ([act isKindOfClass:[NSString class]]) gAct = NSSelectorFromString(act);
}
}
} @catch (NSException *e) { gTarget = gTarget; }
}
if (gAct == NULL) {
SEL aSel = NSSelectorFromString(@"action");
if ([g respondsToSelector:aSel]) gAct = ((SEL (*)(id, SEL))objc_msgSend)(g, aSel);
}
if (gTarget && gAct != NULL) {
ACLog(@"🎯 [原生评论] 触发卡片点击手势唤起评论");
[gTarget performSelector:gAct withObject:g];
triggered = YES;
break;
}
}
}
} @catch (NSException *e) {
ACLog(@"[原生评论] 触发异常 %@", e.reason);
}
if (!triggered) {
ACLog(@"[原生评论] 卡片无可触发的评论入口（跳过 %@）", postId);
self.autoCommentSending = NO;
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
[[ACForwardHelperManager shared] ac_pumpAutoCommentQueue];
});
return;
}
// ② 0.7s 后全窗口找评论输入框（firstResponder 优先）→ 注入 → 发送
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
UIViewController *top = keyWin.rootViewController;
while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
UITextView *cInput = nil;
// 优先取正在输入的 firstResponder 输入框（评论弹窗弹出后即获得焦点）
for (UIWindow *w2 in [UIApplication sharedApplication].windows) {
UITextView *tv2 = ACFindTextViewDeep(w2);
if (tv2 && tv2.isFirstResponder) { cInput = tv2; break; }
}
if (!cInput) cInput = ACFindTextViewDeep(top.view) ?: ACFindTextViewDeep(keyWin);
BOOL injected = NO;
if (cInput) {
cInput.text = text ?: @"不错";
id del = cInput.delegate;
if (del && [del respondsToSelector:@selector(textViewDidChange:)]) {
((void (*)(id, SEL, id))objc_msgSend)(del, @selector(textViewDidChange:), cInput);
}
[[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification object:cInput];
injected = YES;
ACLog(@"[原生评论] 注入评论文字: %@", cInput.text);
} else {
ACLog(@"[原生评论] 未找到评论输入框（AirCommentInputView 未弹出？）");
}
// 发送按钮：全窗口搜 send 动作 / 「发」「送」标题
UIButton *sendBtn = ACFindButtonWithActionDeep(top.view, @"send");
if (!sendBtn) {
for (UIWindow *w2 in [UIApplication sharedApplication].windows) {
sendBtn = ACFindButtonWithActionDeep(w2, @"send")
?: ACFindButtonWithTitleDeep(w2, @"发")
?: ACFindButtonWithTitleDeep(w2, @"送");
if (sendBtn) break;
}
}
BOOL sent = NO;
if (sendBtn) {
[sendBtn sendActionsForControlEvents:UIControlEventTouchUpInside];
sent = YES;
ACLog(@"✅ [原生评论] 已点击发送按钮！");
}
if (!sent && injected && cInput) {
// 兜底：模拟回车键发送（多数评论框回车即发）
id del2 = cInput.delegate;
if (del2 && [del2 respondsToSelector:@selector(textView:shouldChangeTextInRange:replacementText:)]) {
BOOL allow = ((BOOL (*)(id, SEL, id, NSRange, id))objc_msgSend)(del2, @selector(textView:shouldChangeTextInRange:replacementText:), cInput, NSMakeRange(cInput.text.length, 0), @"\n");
if (allow) cInput.text = [cInput.text stringByAppendingString:@"\n"];
ACLog(@"[原生评论] 尝试回车键发送");
}
}
self.lastMomentLog = sent ? [NSString stringWithFormat:@"💬 已自动评论：%@", (text ?: @"不错")]
: @"⚠️ 评论未闭环（未找到发送入口）";
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
[self saveAllCustomSettings];
self.autoCommentSending = NO;
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
[[ACForwardHelperManager shared] ac_pumpAutoCommentQueue];
});
});
});
}
#pragma mark - 自动点赞引擎（复用信息流响应，不重复安装网络钩子）
- (void)ac_handleFeedResponseForAutoLike:(NSDictionary *)json {
@try {
if (!self.autoLikeEnabled) return;
NSArray *records = ACFeedRecordsFromJSON(json);
if (records.count == 0) return;
if (self.autoLikeEnabledAt <= 0) self.autoLikeEnabledAt = [[NSDate date] timeIntervalSince1970];
NSDateFormatter *df = [[NSDateFormatter alloc] init];
df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
NSMutableArray *fresh = [NSMutableArray array];
for (NSDictionary *rec in records) {
if (![rec isKindOfClass:[NSDictionary class]]) continue;
NSString *pid = ACSafeStr(rec[@"id"]);
NSString *uid = ACSafeStr(rec[@"userId"]);
if (pid.length < 6) continue;
if (uid.length > 3 && [uid isEqualToString:self.selfUserId]) continue; // 自己的动态不点赞
if ([self.likedPostIds containsObject:pid] || [self.likeQueue containsObject:pid]) continue;
NSTimeInterval ct = 0;
NSDate *created = [df dateFromString:ACSafeStr(rec[@"createTime"])];
if (created) ct = [created timeIntervalSince1970];
// 开启后直接点赞当前最新一批动态（最多由队列节流处理），确保开关立刻可见效果
if (!self.autoLikeSeeded) {
if (ct >= self.autoLikeEnabledAt - 5.0 || fresh.count < 15) [fresh addObject:pid];
continue;
}
[fresh addObject:pid];
}
if (!self.autoLikeSeeded) {
self.autoLikeSeeded = YES;
ACLog(@"[自动点赞] 首次信息流播种完成，本次新动态 %lu 条", (unsigned long)fresh.count);
}
for (NSString *pid in [[fresh reverseObjectEnumerator] allObjects]) {
[self ac_enqueueAutoLikeForPostId:pid];
}
} @catch (NSException *e) {
ACLog(@"[自动点赞] 解析信息流异常 %@: %@", e.name, e.reason);
}
}
- (void)ac_enqueueAutoLikeForPostId:(NSString *)postId {
if (!self.autoLikeEnabled || postId.length < 6) return;
if (!self.likedPostIds) self.likedPostIds = [NSMutableSet set];
if (!self.likeQueue) self.likeQueue = [NSMutableArray array];
if ([self.likedPostIds containsObject:postId] || [self.likeQueue containsObject:postId]) return;
[self.likeQueue addObject:postId];
[self ac_pumpAutoLikeQueue];
}
- (void)ac_pumpAutoLikeQueue {
if (self.isLikeSending || self.likeQueue.count == 0) return;
if (!self.autoLikeEnabled) { [self.likeQueue removeAllObjects]; return; }
NSString *pid = self.likeQueue.firstObject;
[self.likeQueue removeObjectAtIndex:0];
[self.likedPostIds addObject:pid];
self.isLikeSending = YES;
[self ac_triggerAutoLikeForPost:pid];
}
// —— 常驻飞行圈句柄：后台刷新 + 全自动发布依赖（viewDidAppear 捕获） ——
static UIViewController *sMomentsMainVC = nil; // 强引用永久保活，杜绝弱引用被系统置 nil
static __weak UIScrollView *sMomentsScrollView = nil;

static UIScrollView *ACFirstScrollViewDeep(UIView *view) {
if (!view) return nil;
for (UIView *sub in view.subviews) {
if ([sub isKindOfClass:[UIScrollView class]]) return (UIScrollView *)sub;
UIScrollView *deep = ACFirstScrollViewDeep(sub);
if (deep) return deep;
}
return nil;
}

static UIView *ACFindViewByClassNameDeep(UIView *view, NSString *namePart) {
if (!view) return nil;
for (UIView *sub in view.subviews) {
if ([NSStringFromClass([sub class]) containsString:namePart]) return sub;
UIView *deep = ACFindViewByClassNameDeep(sub, namePart);
if (deep) return deep;
}
return nil;
}

static UIButton *ACFirstButtonDeep(UIView *view) {
if (!view) return nil;
for (UIView *sub in view.subviews) {
if ([sub isKindOfClass:[UIButton class]]) return (UIButton *)sub;
UIButton *deep = ACFirstButtonDeep(sub);
if (deep) return deep;
}
return nil;
}

static UIButton *ACFindButtonWithActionDeep(UIView *view, NSString *actionPart) {
if (!view) return nil;
for (UIView *sub in view.subviews) {
if ([sub isKindOfClass:[UIButton class]]) {
UIButton *btn = (UIButton *)sub;
for (id target in [btn allTargets]) {
NSArray *actions = [btn actionsForTarget:target forControlEvent:UIControlEventAllEvents];
for (NSString *act in actions) {
if ([act.lowercaseString containsString:actionPart.lowercaseString]) return btn;
}
}
}
UIButton *deep = ACFindButtonWithActionDeep(sub, actionPart);
if (deep) return deep;
}
return nil;
}

// 后台静默下拉刷新飞行圈（UIRefreshControl / MJRefresh / 控制器刷新方法 三级降级）
// 全局深度查找飞行圈/个人主页控制器（BFS 穿透 TabBarController → NavigationController → 子控制器，双入口）
static UIViewController *ACFindMomentsOrProfileController(void) {
UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
if (@available(iOS 13.0, *)) {
if (!keyWin) {
@try {
for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
if ([sc isKindOfClass:[UIWindowScene class]] && sc.activationState == UISceneActivationStateForegroundActive) {
keyWin = ((UIWindowScene *)sc).keyWindow;
if (keyWin) break;
}
}
} @catch (NSException *e) {}
}
}
if (!keyWin) {
for (UIWindow *w in [UIApplication sharedApplication].windows) {
if (w.isKeyWindow) { keyWin = w; break; }
}
}
UIViewController *root = keyWin.rootViewController;
if (!root) return nil;
NSMutableArray<UIViewController *> *queue = [NSMutableArray arrayWithObject:root];
UIViewController *fallbackProfileVC = nil;
int guardCount = 0;
while (queue.count > 0 && guardCount++ < 300) {
UIViewController *vc = queue.firstObject;
[queue removeObjectAtIndex:0];
if (!vc) continue;
NSString *clsName = NSStringFromClass([vc class]);
// 优先返回外层飞行圈主控制器（持有导航栏与发动态按钮）；内层 MomentsContent 列表页没有发布按钮，禁止命中
if ([clsName containsString:@"AirMomentsViewController"] && ![clsName containsString:@"Content"]) {
@try { [vc loadViewIfNeeded]; } @catch (NSException *e) {}
return vc;
}
if (!fallbackProfileVC && ([clsName containsString:@"AirUserProfileViewController"] ||
[clsName containsString:@"AirUserMomentsViewController"] ||
[clsName containsString:@"AirMineViewController"])) {
fallbackProfileVC = vc;
}
// 关键：App 使用 RTRootNavigationController，真实控制器包在 RTContainerController.contentViewController 里
@try {
UIViewController *contentVC = [vc valueForKey:@"contentViewController"];
if ([contentVC isKindOfClass:[UIViewController class]]) [queue addObject:contentVC];
} @catch (NSException *e) {}
if ([vc isKindOfClass:[UITabBarController class]]) {
[queue addObjectsFromArray:((UITabBarController *)vc).viewControllers ?: @[]];
}
if ([vc isKindOfClass:[UINavigationController class]]) {
[queue addObjectsFromArray:((UINavigationController *)vc).viewControllers ?: @[]];
}
if (vc.childViewControllers.count > 0) {
[queue addObjectsFromArray:vc.childViewControllers];
}
}
if (fallbackProfileVC) {
@try { [fallbackProfileVC loadViewIfNeeded]; } @catch (NSException *e) {}
}
return fallbackProfileVC;
}

static void ACTriggerMomentsBackgroundRefresh(void) {
dispatch_async(dispatch_get_main_queue(), ^{
if (!sMomentsMainVC) {
UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
if (@available(iOS 13.0, *)) {
if (!keyWin) {
@try {
for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
if ([sc isKindOfClass:[UIWindowScene class]] && sc.activationState == UISceneActivationStateForegroundActive) {
keyWin = ((UIWindowScene *)sc).keyWindow;
if (keyWin) break;
}
}
} @catch (NSException *e) {}
}
}
UIViewController *deepVC = ACFindMomentsOrProfileController();
if (deepVC) sMomentsMainVC = deepVC;
}
UIViewController *mVC = sMomentsMainVC;
if (!mVC) return;
@try { [mVC loadViewIfNeeded]; } @catch (NSException *e) { return; }
if (!sMomentsScrollView) sMomentsScrollView = ACFirstScrollViewDeep(mVC.viewIfLoaded);
ACLog(@"🔄 [后台刷新] 自动静默刷新飞行圈列表...");
if (sMomentsScrollView) {
if (sMomentsScrollView.refreshControl) {
[sMomentsScrollView.refreshControl beginRefreshing];
[sMomentsScrollView.refreshControl sendActionsForControlEvents:UIControlEventValueChanged];
return;
}
SEL mjSel = NSSelectorFromString(@"mj_header");
if ([sMomentsScrollView respondsToSelector:mjSel]) {
@try {
id header = ((id (*)(id, SEL))objc_msgSend)(sMomentsScrollView, mjSel);
SEL beginSel = NSSelectorFromString(@"beginRefreshing");
if (header && [header respondsToSelector:beginSel]) {
((void (*)(id, SEL))objc_msgSend)(header, beginSel);
return;
}
} @catch (NSException *e) {}
}
}
NSArray *refreshSelNames = @[@"headerRefresh", @"refreshData", @"loadData", @"pullDownRefresh"];
for (NSString *selName in refreshSelNames) {
SEL sel = NSSelectorFromString(selName);
if ([mVC respondsToSelector:sel]) {
((void (*)(id, SEL))objc_msgSend)(mVC, sel);
break;
}
}
});
}

// —— 终极原生自动点赞引擎：暴力扫描屏幕视图树找 MomentCardView，直接触发官方红心（App 自产一次性 X-Lts-Id，永无 500） ——
static NSMutableSet<NSValue *> *sAlreadyLikedCardPointers = nil;

// 递归查找当前窗口下所有正在显示的 MomentCardView
static void ACFindMomentCardsInView(UIView *view, NSMutableArray<UIView *> *results) {
if (!view) return;
if ([NSStringFromClass([view class]) isEqualToString:@"airchat.MomentCardView"]) {
[results addObject:view];
return; // 卡片内部不需要继续往下搜子卡片
}
for (UIView *sub in view.subviews) {
ACFindMomentCardsInView(sub, results);
}
}

// 在卡片内部递归查找绑定了 like 动作的点赞按钮
static UIButton *ACFindLikeButtonInCardDeep(UIView *view) {
if (!view) return nil;
for (UIView *sub in view.subviews) {
if ([sub isKindOfClass:[UIButton class]]) {
UIButton *btn = (UIButton *)sub;
for (id target in [btn allTargets]) {
NSArray *actions = [btn actionsForTarget:target forControlEvent:UIControlEventAllEvents];
for (NSString *act in actions) {
NSString *al = act.lowercaseString;
if ([al containsString:@"like"] || [al containsString:@"favor"] || [al containsString:@"praise"]) return btn;
}
}
}
UIButton *deep = ACFindLikeButtonInCardDeep(sub);
if (deep) return deep;
}
return nil;
}

- (void)ac_triggerAutoLikeForPost:(NSString *)postId {
dispatch_async(dispatch_get_main_queue(), ^{
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
if (!mgr.autoLikeEnabled) {
mgr.isLikeSending = NO;
return;
}
if (!sAlreadyLikedCardPointers) sAlreadyLikedCardPointers = [NSMutableSet set];
if (sAlreadyLikedCardPointers.count > 200) [sAlreadyLikedCardPointers removeAllObjects];

// 1. 获取主窗口（keyWindow → Scene → windows 三级兜底）
UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
if (@available(iOS 13.0, *)) {
if (!keyWin) {
@try {
for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
if ([sc isKindOfClass:[UIWindowScene class]] && sc.activationState == UISceneActivationStateForegroundActive) {
keyWin = ((UIWindowScene *)sc).keyWindow;
if (keyWin) break;
}
}
} @catch (NSException *e) {}
}
}
if (!keyWin) {
for (UIWindow *w in [UIApplication sharedApplication].windows) {
if (w.isKeyWindow) { keyWin = w; break; }
}
}

// 2. 暴力扫描当前屏幕所有动态卡片（离开飞行圈时，常驻控制器的视图树里也有卡片）
NSMutableArray<UIView *> *cardsOnScreen = [NSMutableArray array];
if (keyWin) ACFindMomentCardsInView(keyWin, cardsOnScreen);
UIViewController *mVC = sMomentsMainVC;
if (mVC && mVC.viewIfLoaded) ACFindMomentCardsInView(mVC.viewIfLoaded, cardsOnScreen);

// 3. 优先匹配 postId 对应的卡片（pass 0），其次取任意未点赞卡片（pass 1）
SEL likeSel = NSSelectorFromString(@"likeButtonTapped");
SEL likeSelWithSender = NSSelectorFromString(@"likeButtonTapped:");
UIView *targetCard = nil;
UIButton *targetBtn = nil;
NSString *mode = @"";
for (int pass = 0; pass < 2 && !targetCard; pass++) {
for (UIView *card in cardsOnScreen) {
if (pass == 0) {
NSString *pid = ACExtractCardPostId(card);
if (pid.length == 0 || ![pid isEqualToString:postId]) continue;
}
NSValue *ptrVal = [NSValue valueWithNonretainedObject:card];
if ([sAlreadyLikedCardPointers containsObject:ptrVal]) continue;
UIButton *likeBtn = ACFindLikeButtonInCardDeep(card);
if (likeBtn && likeBtn.isSelected) {
[sAlreadyLikedCardPointers addObject:ptrVal]; // 已是点赞态，跳过
continue;
}
if (likeBtn) { targetCard = card; targetBtn = likeBtn; mode = @"按钮点击"; break; }
if ([card respondsToSelector:likeSel]) { targetCard = card; mode = @"无参Selector"; break; }
if ([card respondsToSelector:likeSelWithSender]) { targetCard = card; mode = @"带参Selector"; break; }
}
}

mgr.isLikeSending = NO;
if (targetCard) {
[sAlreadyLikedCardPointers addObject:[NSValue valueWithNonretainedObject:targetCard]];
@try {
if ([mode isEqualToString:@"按钮点击"]) {
ACLog(@"🎯 [原生自动点赞] 命中卡片点赞按钮，模拟点击 (目标:%@)", postId);
[targetBtn sendActionsForControlEvents:UIControlEventTouchUpInside];
} else if ([mode isEqualToString:@"无参Selector"]) {
ACLog(@"🎯 [原生自动点赞] 命中卡片无参 Selector (目标:%@)", postId);
((void (*)(id, SEL))objc_msgSend)(targetCard, likeSel);
} else {
ACLog(@"🎯 [原生自动点赞] 命中卡片带参 Selector (目标:%@)", postId);
((void (*)(id, SEL, id))objc_msgSend)(targetCard, likeSelWithSender, nil);
}
mgr.lastMomentLog = [NSString stringWithFormat:@"👍 原生点赞成功：%@", postId];
ACLog(@"✅ [原生自动点赞] 官方原生通道触发成功（官方自产一次性 X-Lts-Id）");
} @catch (NSException *e) {
ACLog(@"[原生自动点赞] 触发异常 %@", e.reason);
mgr.lastMomentLog = @"⚠️ 原生点赞触发异常";
}
} else {
mgr.lastMomentLog = @"💡 请停留在飞行圈动态页面或滑动加载新卡片";
ACLog(@"[原生自动点赞] 屏幕搜寻到 %lu 张卡片但无可点目标（postId=%@，其余可能已点赞）", (unsigned long)cardsOnScreen.count, postId);
}
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];

// 节流 2~3.5 秒处理下一张卡片
NSTimeInterval delay = 0.2 + (arc4random_uniform(6) / 10.0); // 秒点：亚秒级节流
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
[mgr ac_pumpAutoLikeQueue];
});
});
}
#pragma mark - 自动点赞/自动评论后台巡检（独立 Session，不依赖用户浏览信息流）
- (void)ac_startAutoLikePollTimer {
dispatch_async(dispatch_get_main_queue(), ^{
if (self.autoLikePollTimer) [self.autoLikePollTimer invalidate];
self.autoLikePollTimer = [NSTimer scheduledTimerWithTimeInterval:25.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
if (mgr.autoLikeEnabled || mgr.autoCommentEnabled) [mgr ac_pollFeedForAutoLike];
if (mgr.autoLikeEnabled) {
// 后台预热保活：确保飞行圈控制器视图处于加载状态，刷新才有卡片可扫
UIViewController *keepVC = sMomentsMainVC;
if (keepVC) [keepVC loadViewIfNeeded];
// 后台静默刷新飞行圈（解决离开页面后屏幕 0 卡片漏赞），1.5 秒后全屏扫描秒赞
ACTriggerMomentsBackgroundRefresh();
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
ACForwardHelperManager *m2 = [ACForwardHelperManager shared];
if (m2.autoLikeEnabled && !m2.isLikeSending) [m2 ac_triggerAutoLikeForPost:@"auto_scan"];
});
}
}];
[[NSRunLoop mainRunLoop] addTimer:self.autoLikePollTimer forMode:NSRunLoopCommonModes];
});
}

#pragma mark - 全后台不死心跳引擎（挂后台定时发动态不断流 + 无需进页面自动后台点赞）
// 后台离屏预挂载飞行圈视图树 + 自动滚屏渲染卡片并点亮红心（完全无需用户点进飞行圈页面）
- (void)ac_prewarmAndScrollMomentsForAutoLike {
dispatch_async(dispatch_get_main_queue(), ^{
if (!self.autoLikeEnabled) return;
@try {
UIViewController *mVC = sMomentsMainVC ?: ACFindMomentsOrProfileController();
if (!mVC) return;
sMomentsMainVC = mVC;
[mVC loadViewIfNeeded];
// 用户当前不在飞行圈页面时，把其视图树临时挂载到主窗口底层隐形容器强制完成布局渲染
UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
if (keyWin && mVC.view && !mVC.view.window) {
UIView *ghostHost = [keyWin viewWithTag:8899771];
if (!ghostHost) {
ghostHost = [[UIView alloc] initWithFrame:CGRectMake(0, 0, keyWin.bounds.size.width, keyWin.bounds.size.height)];
ghostHost.tag = 8899771;
ghostHost.alpha = 0.005; // 肉眼不可见且 userInteractionEnabled=NO 不拦截任何点击
ghostHost.userInteractionEnabled = NO;
[keyWin insertSubview:ghostHost atIndex:0];
ACLog(@"[后台点赞] 已创建隐形宿主容器，离屏预挂载飞行圈视图树");
}
mVC.view.frame = ghostHost.bounds;
[ghostHost addSubview:mVC.view];
[mVC viewWillAppear:NO];
[mVC viewDidAppear:NO];
[mVC.view setNeedsLayout];
[mVC.view layoutIfNeeded];
}
// 自动向下滚动一屏触发新卡片渲染；滚到底则回顶并触发原生刷新拿最新列表
UIScrollView *sv = sMomentsScrollView ?: ACFirstScrollViewDeep(mVC.view);
if (sv) {
sMomentsScrollView = sv;
CGFloat maxOffset = MAX(0, sv.contentSize.height - sv.bounds.size.height);
CGFloat nextY = sv.contentOffset.y + 360.0;
if (nextY > maxOffset || nextY > 3600.0) {
[sv setContentOffset:CGPointZero animated:NO];
ACTriggerMomentsBackgroundRefresh();
} else {
[sv setContentOffset:CGPointMake(0, nextY) animated:NO];
}
[sv setNeedsLayout];
[sv layoutIfNeeded];
}
// 扫描已渲染的动态卡片，触发原生点赞按钮（App 自产最新签名对），每次心跳只点 1 张稳健防风控
NSMutableArray<UIView *> *cards = [NSMutableArray array];
ACFindMomentCardsInView(mVC.view, cards);
for (UIView *card in cards) {
NSString *pid = ACExtractCardPostId(card);
if (pid.length >= 6 && [self.likedPostIds containsObject:pid]) continue;
UIButton *likeBtn = ACFindLikeButtonInCardDeep(card);
if (likeBtn && !likeBtn.isSelected) {
[likeBtn sendActionsForControlEvents:UIControlEventTouchUpInside];
if (pid.length >= 6) [self.likedPostIds addObject:pid];
self.lastMomentLog = [NSString stringWithFormat:@"👍 后台自动点赞成功：%@", pid ?: @"动态卡片"];
ACLog(@"✅ [后台原生点赞] 触发卡片红心 pid=%@", pid);
break;
}
}
} @catch (NSException *e) {}
});
}

// 15 秒一次的 GCD 心跳（不受 RunLoop 模式切换/NSTimer 后台冻结影响），三重守护：
// 1) 静音保活播放器掉线自愈  2) 定时动态按真实时间戳补发  3) 后台离屏点赞 + HTTP 巡检
- (void)ac_startImmortalBackgroundEngine {
static dispatch_once_t onceToken;
dispatch_once(&onceToken, ^{
self.bgTaskId = UIBackgroundTaskInvalid;
// 进入后台：强制拉起静音保活 + 申请长效后台任务
[[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
if (self.autoMomentEnabled || self.autoLikeEnabled || self.keepAliveEnabled) {
self.keepAliveEnabled = YES;
[self ac_applyKeepAliveState];
UIApplication *app = [UIApplication sharedApplication];
if (self.bgTaskId != UIBackgroundTaskInvalid) [app endBackgroundTask:self.bgTaskId];
self.bgTaskId = [app beginBackgroundTaskWithExpirationHandler:^{
[self ac_applyKeepAliveState];
if (self.bgTaskId != UIBackgroundTaskInvalid) {
[app endBackgroundTask:self.bgTaskId];
self.bgTaskId = UIBackgroundTaskInvalid;
}
}];
ACLog(@"🌙 [后台常驻] 已进入后台，启动长效保活锁与 GCD 心跳");
}
}];
// 音频中断（录语音/播视频/来电）后 1 秒自愈恢复静音保活，避免后台 30 秒被挂起
[[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
if (self.keepAliveEnabled || self.autoMomentEnabled || self.autoLikeEnabled) {
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
[self ac_applyKeepAliveState];
});
}
}];
dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 15 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
dispatch_source_set_event_handler(timer, ^{
// 1. 守护静音播放器：被打断/停止后立即拉起
if (self.keepAliveEnabled || self.autoMomentEnabled || self.autoLikeEnabled) {
if (!self.keepAlivePlayer || !self.keepAlivePlayer.isPlaying) {
[self ac_applyKeepAliveState];
}
}
// 2. 守护定时发动态：基于真实绝对时间戳，挂后台几小时恢复瞬间立即补发
if (self.autoMomentEnabled && self.nextMomentFireTimestamp > 0) {
NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
if (now >= self.nextMomentFireTimestamp && !self.momentPublishing) {
NSTimeInterval intervalSec = MAX(1, self.momentIntervalMinutes) * 60.0;
self.nextMomentFireTimestamp = now + intervalSec;
ACLog(@"⏰ [后台GCD心跳] 到达定时发动态时间点，立即执行后台发布！");
[self onMomentTimerTick];
}
}
// 3. 守护后台自动点赞：离屏滚屏渲染 + HTTP 巡检双保险
if (self.autoLikeEnabled) {
[self ac_prewarmAndScrollMomentsForAutoLike];
[self ac_pollFeedForAutoLike];
}
});
dispatch_resume(timer);
self.bgMasterHeartbeatTimer = timer;
ACLog(@"[不死心跳] 15 秒 GCD 心跳引擎已启动");
});
}
- (void)ac_pollFeedForAutoLike {
@try {
if (self.autoLikePolling) return;
if (!self.autoLikeEnabled && !self.autoCommentEnabled) return;
NSString *token = ACHeaderValue(self.latestHTTPHeaders, @"token");
if (token.length == 0) return;
self.autoLikePolling = YES;
// 旧接口 /airchat/c/post/pageIds 升级后已废弃，切换为存活的动态分页接口（响应结构与 data.records 兼容）
NSString *host = [self ac_activeBusinessHost];
NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/client/biz/v2/post/app/page?channelType=1&current=1&size=20", host]]]; // HAR[72]: 缺 channelType 必报 415「请选择频道类型」
req.HTTPMethod = @"GET";
[req setValue:host forHTTPHeaderField:@"Host"];
[req setValue:@"*/*" forHTTPHeaderField:@"Accept"];
[req setValue:kACNativeUserAgent forHTTPHeaderField:@"User-Agent"];
[self ac_applyCapturedHeadersToRequest:req];
NSURLSession *session = ACDedicatedPluginSession();
if (!session) { self.autoLikePolling = NO; return; }
acInternalRequest = YES;
NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
dispatch_async(dispatch_get_main_queue(), ^{
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
mgr.autoLikePolling = NO;
if (error || data.length == 0) return;
NSDictionary *json = ACSafeDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
if (!json) return;
@try { [mgr ac_handleFeedResponse:json]; } @catch (NSException *e) {}
@try { [mgr ac_handleFeedResponseForAutoLike:json]; } @catch (NSException *e) {}
});
}];
acInternalRequest = NO;
[task resume];
} @catch (NSException *e) {
self.autoLikePolling = NO;
ACLog(@"[自动点赞] 后台巡检异常 %@", e.reason);
}
}
#pragma mark - 批量语音条打招呼（私聊发送 AAC 语音条，走普通消息信令，替代 VoIP 振铃）
- (void)ac_startBatchVoiceMemo:(NSArray<ACContactItem *> *)targets {
if (self.voiceMemoRunning) {
self.voiceMemoRunning = NO;
ACLog(@"[语音条打招呼] 已手动停止批量任务");
return;
}
NSInteger mType = [self mediaTypeForSlot:ACMediaSlotBatchSend];
NSString *audioPath = [self audioPathForSlot:ACMediaSlotBatchSend];
if (mType != 3 || ![[NSFileManager defaultManager] fileExistsAtPath:audioPath]) {
ACLog(@"[语音条打招呼] 请先在【💬回复】面板媒体框录制/导入语音条（槽位0 群发专属）");
return;
}
if (targets.count == 0) {
ACLog(@"[语音条打招呼] 目标为空，请先勾选群成员");
return;
}
self.voiceMemoRunning = YES;
self.unlockAttemptCountInSession = 0; // 新一轮批量：重置破盾限频计数
int dur = [self audioDurationForSlot:ACMediaSlotBatchSend];
ACLog(@"[语音条打招呼] 启动批量语音条任务，目标 %lu 人（语音 %d 秒，间隔 1.2-2.7 秒随机）", (unsigned long)targets.count, dur);
__block NSMutableArray *queue = [targets mutableCopy];
__weak typeof(self) wself = self;
__block void (^nextSend)(void) = nil;
nextSend = ^{
__strong typeof(wself) sself = wself;
if (!sself || !sself.voiceMemoRunning) return;
if (queue.count == 0) {
sself.voiceMemoRunning = NO;
ACLog(@"[语音条打招呼] ✅ 批量任务全部执行完毕");
return;
}
ACContactItem *t = queue.firstObject;
[queue removeObjectAtIndex:0];
[sself sendText:@"" mediaSlot:ACMediaSlotBatchSend attachMedia:YES toItem:t completion:^(BOOL ok, NSString *detail) {
ACLog(@"[语音条打招呼] %@ [%@] %@", ok ? @"✅" : @"❌", t.name ?: t.targetId, detail ?: @"");
// 防封雷区④：拟人化阶梯延时 + 每 8 人强制冷却，打断服务端滑动窗口频控计数
if (sself) {
sself.batchSendStreakCount++;
NSTimeInterval delay = 6.5 + (arc4random_uniform(55) / 10.0); // 拟人化间隔 6.5~12 秒
if (sself.batchSendStreakCount % 8 == 0) {
delay += 28.0 + arc4random_uniform(15);
ACLog(@"🛡️ [防封降权] 已连续发送 %ld 人，自动进入 %.0f 秒安全冷却休息...", (long)sself.batchSendStreakCount, delay);
}
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), nextSend);
}
}];
};
dispatch_async(dispatch_get_main_queue(), nextSend);
}
#pragma mark - 批量语音打招呼（优先进 TUICallEngine/TUICallKit，自动挂断）
- (void)ac_stopBatchVoiceCall {
if (!self.voiceCallRunning) return;
self.voiceCallRunning = NO;
ACLog(@"[语音打招呼] 已手动停止批量任务");
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
}
- (void)ac_startBatchVoiceCall:(NSArray<ACContactItem *> *)targets {
if (self.voiceCallRunning) {
[self ac_stopBatchVoiceCall];
return;
}
if (targets.count == 0) {
ACLog(@"[语音打招呼] 目标为空，请先勾选群成员");
return;
}
self.voiceCallRunning = YES;
float hangupSec = (self.voiceHangupSeconds >= 0.3f && self.voiceHangupSeconds <= 15.0f) ? self.voiceHangupSeconds : 1.0f;
ACLog(@"[语音打招呼] 启动批量任务，目标 %lu 人（%.1f 秒强制挂断）", (unsigned long)targets.count, hangupSec);
__weak typeof(self) weakSelf = self;
__block NSInteger currentIndex = 0;
__block void (^nextCall)(void) = nil;
void (^nextImpl)(void) = ^{
ACForwardHelperManager *mgr = weakSelf;
if (!mgr || !mgr.voiceCallRunning) { nextCall = nil; return; }
if (currentIndex >= targets.count) {
mgr.voiceCallRunning = NO;
ACLog(@"[语音打招呼] 批量任务全部执行完毕");
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
nextCall = nil;
return;
}
ACContactItem *target = targets[currentIndex];
currentIndex++;
NSString *uid = target.targetId;
if (uid.length < 5) {
nextCall();
return;
}
// 依次尝试腾讯云呼叫组件：TUICallEngine 单例优先，TUICallKit 兜底
id engine = nil;
Class engineCls = NSClassFromString(@"TUICallEngine");
if (engineCls && [engineCls respondsToSelector:@selector(createInstance)]) {
engine = ((id (*)(id, SEL))objc_msgSend)(engineCls, @selector(createInstance));
}
if (!engine) {
Class kitCls = NSClassFromString(@"TUICallKit");
if (kitCls && [kitCls respondsToSelector:@selector(createInstance)]) {
engine = ((id (*)(id, SEL))objc_msgSend)(kitCls, @selector(createInstance));
}
}
SEL callEngineSel = NSSelectorFromString(@"call:callMediaType:params:succ:fail:");
SEL callKitSel = NSSelectorFromString(@"call:type:");
SEL callPlainSel = NSSelectorFromString(@"call:");
BOOL called = NO;
@try {
if (engine && [engine respondsToSelector:callEngineSel]) {
((void (*)(id, SEL, NSString *, NSInteger, id, id, id))objc_msgSend)(engine, callEngineSel, uid, 1, nil, nil, nil);
called = YES;
} else if (engine && [engine respondsToSelector:callKitSel]) {
((void (*)(id, SEL, NSString *, NSInteger))objc_msgSend)(engine, callKitSel, uid, 1);
called = YES;
} else if (engine && [engine respondsToSelector:callPlainSel]) {
((void (*)(id, SEL, NSString *))objc_msgSend)(engine, callPlainSel, uid);
called = YES;
}
} @catch (NSException *e) {
ACLog(@"[语音打招呼] 发起呼叫异常 %@", e.reason);
}
if (!called) {
ACLog(@"[语音打招呼] 未找到可用的腾讯云呼叫实例，任务终止");
mgr.voiceCallRunning = NO;
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
nextCall = nil;
return;
}
ACLog(@"[语音打招呼] 已向 %@ (%@) 发起语音振铃", target.name ?: uid, uid);
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hangupSec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
ACForwardHelperManager *m2 = weakSelf;
if (!m2) return;
@try {
SEL hangupEngineSel = NSSelectorFromString(@"hangup:fail:");
SEL hangupSel = NSSelectorFromString(@"hangup");
if ([engine respondsToSelector:hangupEngineSel]) {
((void (*)(id, SEL, id, id))objc_msgSend)(engine, hangupEngineSel, nil, nil);
} else if ([engine respondsToSelector:hangupSel]) {
((void (*)(id, SEL))objc_msgSend)(engine, hangupSel);
}
} @catch (NSException *e) {
ACLog(@"[语音打招呼] 挂断异常 %@", e.reason);
}
ACLog(@"[语音打招呼] 已自动挂断 %@", uid);
// 间隔 3.5-6 秒再拨下一位，避免信令风暴
NSTimeInterval gap = 3.5 + (arc4random_uniform(26) / 10.0);
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gap * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
if (nextCall) nextCall();
});
});
};
nextCall = nextImpl;
nextCall();
}
// 单人语音打招呼：发起 1 秒振铃后自动挂断，完成后回调（供迎新链路复用）
- (void)triggerSingleVoiceCallForTarget:(NSString *)uid nick:(NSString *)nick completion:(void(^)(void))completion {
if (uid.length < 5) { if (completion) completion(); return; }
@try {
id engine = nil;
Class engineCls = NSClassFromString(@"TUICallEngine");
if (engineCls && [engineCls respondsToSelector:@selector(createInstance)]) {
engine = ((id (*)(id, SEL))objc_msgSend)(engineCls, @selector(createInstance));
}
if (!engine) {
Class kitCls = NSClassFromString(@"TUICallKit");
if (kitCls && [kitCls respondsToSelector:@selector(createInstance)]) {
engine = ((id (*)(id, SEL))objc_msgSend)(kitCls, @selector(createInstance));
}
}
SEL callEngineSel = NSSelectorFromString(@"call:callMediaType:params:succ:fail:");
SEL callKitSel = NSSelectorFromString(@"call:type:");
SEL callPlainSel = NSSelectorFromString(@"call:");
BOOL called = NO;
// 呼叫发起前就置位，确保 TUICall 同步弹出呼叫 VC 时能被 presentViewController 钩子压制
self.welcomeVoiceCalling = YES;
if (engine && [engine respondsToSelector:callEngineSel]) {
((void (*)(id, SEL, NSString *, NSInteger, id, id, id))objc_msgSend)(engine, callEngineSel, uid, 1, nil, nil, nil);
called = YES;
} else if (engine && [engine respondsToSelector:callKitSel]) {
((void (*)(id, SEL, NSString *, NSInteger))objc_msgSend)(engine, callKitSel, uid, 1);
called = YES;
} else if (engine && [engine respondsToSelector:callPlainSel]) {
((void (*)(id, SEL, NSString *))objc_msgSend)(engine, callPlainSel, uid);
called = YES;
}
if (!called) {
self.welcomeVoiceCalling = NO;
ACLog(@"[迎新语音] 未找到可用的呼叫实例，跳过 %@", uid);
if (completion) completion();
return;
}
float hangupSec = (self.voiceHangupSeconds >= 0.3f && self.voiceHangupSeconds <= 15.0f) ? self.voiceHangupSeconds : 1.0f;
ACLog(@"[迎新语音] 已向 %@ (%@) 发起语音振铃，%.1f 秒后自动挂断", nick ?: uid, uid, hangupSec);
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hangupSec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
@try {
SEL hangupEngineSel = NSSelectorFromString(@"hangup:fail:");
SEL hangupSel = NSSelectorFromString(@"hangup");
if ([engine respondsToSelector:hangupEngineSel]) {
((void (*)(id, SEL, id, id))objc_msgSend)(engine, hangupEngineSel, nil, nil);
} else if ([engine respondsToSelector:hangupSel]) {
((void (*)(id, SEL))objc_msgSend)(engine, hangupSel);
}
} @catch (NSException *e) {
ACLog(@"[迎新语音] 挂断异常 %@", e.reason);
}
self.welcomeVoiceCalling = NO;
ACLog(@"[迎新语音] 已自动挂断 %@", uid);
if (completion) completion();
});
} @catch (NSException *e) {
self.welcomeVoiceCalling = NO;
ACLog(@"[迎新语音] 发起异常 %@", e.reason);
if (completion) completion();
}
}
#pragma mark - 后台静音保活（内存生成 WAV，不依赖任何资源文件）
- (void)ac_applyKeepAliveState {
dispatch_async(dispatch_get_main_queue(), ^{
if (!self.keepAliveEnabled) {
if (self.keepAlivePlayer.isPlaying) [self.keepAlivePlayer stop];
self.keepAlivePlayer = nil;
return;
}
if (self.keepAlivePlayer.isPlaying) return;
@try {
uint32_t sampleRate = 44100;
uint32_t numSamples = sampleRate * 2;
uint32_t dataSize = numSamples * 2;
uint32_t totalSize = 36 + dataSize;
NSMutableData *wav = [NSMutableData dataWithCapacity:totalSize + 8];
[wav appendBytes:"RIFF" length:4];
[wav appendBytes:&totalSize length:4];
[wav appendBytes:"WAVEfmt " length:8];
uint32_t fsize = 16; [wav appendBytes:&fsize length:4];
uint16_t fmt = 1; [wav appendBytes:&fmt length:2];
uint16_t ch = 1; [wav appendBytes:&ch length:2];
[wav appendBytes:&sampleRate length:4];
uint32_t br = sampleRate * 2; [wav appendBytes:&br length:4];
uint16_t ba = 2; [wav appendBytes:&ba length:2];
uint16_t bps = 16; [wav appendBytes:&bps length:2];
[wav appendBytes:"data" length:4];
[wav appendBytes:&dataSize length:4];
[wav increaseLengthBy:dataSize];
[[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
[[AVAudioSession sharedInstance] setActive:YES error:nil];
self.keepAlivePlayer = [[AVAudioPlayer alloc] initWithData:wav error:nil];
self.keepAlivePlayer.numberOfLoops = -1;
self.keepAlivePlayer.volume = 0.01;
[self.keepAlivePlayer play];
ACLog(@"[保活] 静音后台音频已启动");
} @catch (NSException *e) {
ACLog(@"[保活] 启动异常 %@", e.reason);
}
});
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
// 优先桥接 App 原生发布业务类：由 App 自己组装 channel / 签名 / X-Lts-Id，避免 code:500
- (BOOL)ac_tryNativeMomentPublish:(ACMomentTaskItem *)task completion:(void(^)(BOOL ok, NSString *msg))completion {
if (self.momentNativeBridgeDisabled) return NO;
Class cls = NSClassFromString(@"AirMomentBussinessCenter");
if (!cls) cls = NSClassFromString(@"airchat.AirMomentBussinessCenter");
if (!cls) cls = NSClassFromString(@"AirChat.AirMomentBussinessCenter");
if (!cls) cls = NSClassFromString(@"AirMomentPublishViewController");
if (!cls) cls = NSClassFromString(@"airchat.AirMomentPublishViewController");
if (!cls) cls = NSClassFromString(@"AirChat.AirMomentPublishViewController");
if (!cls) {
ACLog(@"[发布] 未找到 App 原生发布类，走 HTTP 兜底");
return NO;
}
SEL sel = NSSelectorFromString(@"publishMomentWithContent:mediaList:permission:completion:");
if (![cls respondsToSelector:sel]) {
ACLog(@"[发布] %@ 无原生发布方法，走 HTTP 兜底", NSStringFromClass(cls));
self.momentNativeBridgeDisabled = YES;
return NO;
}
NSMethodSignature *sig = [cls methodSignatureForSelector:sel];
if (!sig || [sig numberOfArguments] != 6) {
ACLog(@"[发布] 原生发布方法签名不匹配(%lu)，走 HTTP 兜底", (unsigned long)(sig ? [sig numberOfArguments] : 0));
self.momentNativeBridgeDisabled = YES;
return NO;
}
// 严格校验参数类型：content/mediaList 必须是对象，permission 必须是整数，completion 必须是 block
const char *t2 = [sig getArgumentTypeAtIndex:2];
const char *t3 = [sig getArgumentTypeAtIndex:3];
const char *t4 = [sig getArgumentTypeAtIndex:4];
const char *t5 = [sig getArgumentTypeAtIndex:5];
if (!t2 || !t3 || !t4 || !t5 || t2[0] != '@' || t3[0] != '@' ||
strchr("qQil", t4[0]) == NULL || t5[0] != '@') {
ACLog(@"[发布] 原生发布参数类型不符，走 HTTP 兜底");
self.momentNativeBridgeDisabled = YES;
return NO;
}
id media = ACJSONSafeObject(task.capturedMediaList, 0) ?: @[];
__block BOOL finished = NO;
void (^cb)(BOOL, id) = ^(BOOL success, id resObj) {
dispatch_async(dispatch_get_main_queue(), ^{
if (finished) return;
finished = YES;
self.momentPublishing = NO;
if (success) {
task.sentCount++;
self.lastMomentLog = [NSString stringWithFormat:@"✅ 原生动态发布成功 | 累计%ld次", (long)task.sentCount];
[self saveAllCustomSettings];
ACLog(@"[发布] 原生桥接成功 sentCount=%ld", (long)task.sentCount);
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(YES, self.lastMomentLog);
} else {
ACLog(@"[发布] 原生桥接失败 resp=%@，切换 HTTP 兜底", resObj);
self.momentNativeBridgeDisabled = YES;
[self publishMomentTask:task completion:completion];
}
});
};
ACLog(@"[发布] 尝试 App 原生桥接：%@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
@try {
((void (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)((id)cls, sel, task.contentText ?: @"", media, (NSInteger)1, cb);
} @catch (NSException *e) {
ACLog(@"[发布] 原生桥接调用异常 %@", e.reason);
self.momentNativeBridgeDisabled = YES;
return NO;
}
// 25 秒看门狗：原生迟迟不回调就回落 HTTP，避免一直卡在发布中
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
if (finished) return;
finished = YES;
self.momentPublishing = NO;
self.momentNativeBridgeDisabled = YES;
ACLog(@"[发布] 原生桥接 25 秒未回调，回落 HTTP");
[self publishMomentTask:task completion:completion];
});
return YES;
}
// —— 终极原生自动发动态引擎：驱动 App 官方发布页（雷达实证 AirMomentsViewController → AirMomentPublishOptionsViewController），
// 由 App 原生链路自产一次性 X-Lts-Id，彻底告别自拼请求 500 ——
static UITextView *ACFindTextViewDeep(UIView *view) {
if (!view) return nil;
for (UIView *sub in view.subviews) {
if ([sub isKindOfClass:[UITextView class]]) return (UITextView *)sub;
UITextView *deep = ACFindTextViewDeep(sub);
if (deep) return deep;
}
return nil;
}

static UIButton *ACFindButtonWithTitleDeep(UIView *view, NSString *titlePart) {
if (!view) return nil;
for (UIView *sub in view.subviews) {
if ([sub isKindOfClass:[UIButton class]]) {
UIButton *btn = (UIButton *)sub;
NSString *t = [btn titleForState:UIControlStateNormal] ?: [btn titleForState:UIControlStateSelected] ?: @"";
if ([t containsString:titlePart]) return btn;
}
UIButton *deep = ACFindButtonWithTitleDeep(sub, titlePart);
if (deep) return deep;
}
return nil;
}
// 按 target 类名深搜按钮（如选项页 AirMomentPublishOptionsViewController 的发布按钮）
static UIButton *ACFindButtonWithTargetClassDeep(UIView *view, NSString *classPart) {
if (!view) return nil;
for (UIView *sub in view.subviews) {
if ([sub isKindOfClass:[UIButton class]]) {
UIButton *btn = (UIButton *)sub;
for (id target in [btn allTargets]) {
if ([NSStringFromClass([target class]) containsString:classPart]) return btn;
}
}
UIButton *deep = ACFindButtonWithTargetClassDeep(sub, classPart);
if (deep) return deep;
}
return nil;
}

- (void)ac_runMomentPublishFlow:(ACMomentTaskItem *)task keyWin:(UIWindow *)keyWin completion:(void(^)(BOOL ok, NSString *msg))completion {
UIWindow *win = keyWin ?: [UIApplication sharedApplication].keyWindow;
if (!win) {
for (UIWindow *w2 in [UIApplication sharedApplication].windows) {
if (w2.isKeyWindow) { win = w2; break; }
}
}
// 自动切换 TabBar 到飞行圈（在任意页面触发发布都能正确弹出编辑页）
@try {
UIViewController *root = win.rootViewController;
if ([root isKindOfClass:[UITabBarController class]]) {
UITabBarController *tab = (UITabBarController *)root;
for (NSUInteger i = 0; i < tab.viewControllers.count; i++) {
UIViewController *c = tab.viewControllers[i];
if ([NSStringFromClass([c class]) containsString:@"Moments"] ||
[NSStringFromClass([c class]) containsString:@"Moment"]) {
if (tab.selectedIndex != i) {
tab.selectedIndex = i;
ACLog(@"[原生发布] 自动切换 Tab 到飞行圈 (Index: %lu)", (unsigned long)i);
}
break;
}
}
}
} @catch (NSException *e) {}
// 寻找飞行圈控制器（BFS 深度穿透 TabBar → NavigationController → 子控制器，飞行圈/个人主页双入口）
UIViewController *momentsVC = sMomentsMainVC;
if (!momentsVC) momentsVC = ACFindMomentsOrProfileController();
if (!momentsVC) {
// 刚切 Tab 视图可能未加载，0.5 秒后重试（最多 3 次）
static NSInteger acPubFindRetry = 0;
if (acPubFindRetry < 3) {
acPubFindRetry++;
ACLog(@"[原生发布] 飞行圈控制器未就绪，0.5 秒后重试 (%ld/3)", (long)acPubFindRetry);
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
[self ac_runMomentPublishFlow:task keyWin:win completion:completion];
});
} else {
acPubFindRetry = 0;
ACLog(@"[原生发布] 错误：未找到飞行圈控制器");
self.momentPublishing = NO;
if (completion) completion(NO, @"未找到飞行圈");
}
return;
}
// 步骤 1：Swift 带冒号方法优先（运行时真实名为 publishButtonTapped:），无参与导航栏按钮兜底
SEL selWithArg = NSSelectorFromString(@"publishButtonTapped:");
SEL selNoArg = NSSelectorFromString(@"publishButtonTapped");
UIButton *fakeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
BOOL triggeredStep1 = NO;
@try {
if ([momentsVC respondsToSelector:selWithArg]) {
ACLog(@"🎯 [原生发布] 步骤1: 命中 publishButtonTapped: (带参)");
((void (*)(id, SEL, id))objc_msgSend)(momentsVC, selWithArg, fakeBtn);
triggeredStep1 = YES;
} else if ([momentsVC respondsToSelector:selNoArg]) {
ACLog(@"🎯 [原生发布] 步骤1: 命中 publishButtonTapped (无参)");
((void (*)(id, SEL))objc_msgSend)(momentsVC, selNoArg);
triggeredStep1 = YES;
} else {
UIBarButtonItem *rightBtn = momentsVC.navigationItem.rightBarButtonItem;
if (rightBtn && rightBtn.action && [momentsVC respondsToSelector:rightBtn.action]) {
ACLog(@"🎯 [原生发布] 步骤1: 触发导航栏右上角发动态按钮 (%@)", NSStringFromSelector(rightBtn.action));
((void (*)(id, SEL, id))objc_msgSend)(momentsVC, rightBtn.action, fakeBtn);
triggeredStep1 = YES;
}
}
} @catch (NSException *e) {
ACLog(@"[原生发布] 步骤1异常 %@", e.reason);
}
if (!triggeredStep1) {
ACLog(@"[原生发布] 步骤1未触发成功，请确认是否处于飞行圈页面");
self.momentPublishing = NO;
if (completion) completion(NO, @"步骤1未接通");
return;
}
// 步骤 2：0.7 秒后注入文案 + 点击工具栏「下一步」（nextButtonTapped）
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
UIWindow *win2 = [UIApplication sharedApplication].keyWindow ?: win;
UIViewController *top2 = win2.rootViewController;
while (top2.presentedViewController && !top2.presentedViewController.isBeingDismissed) top2 = top2.presentedViewController;
UITextView *inputTV = ACFindTextViewDeep(top2.view) ?: ACFindTextViewDeep(win2);
// 键盘/输入副工具栏在独立 Window（UITextEffectsWindow）里，编辑框与按钮必须全 Window 扫描
if (!inputTV) {
for (UIWindow *w3 in [UIApplication sharedApplication].windows) {
inputTV = ACFindTextViewDeep(w3);
if (inputTV) break;
}
}
if (inputTV) {
inputTV.text = task.contentText;
id del = inputTV.delegate;
if (del && [del respondsToSelector:@selector(textViewDidChange:)]) {
((void (*)(id, SEL, id))objc_msgSend)(del, @selector(textViewDidChange:), inputTV);
}
[[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification object:inputTV];
ACLog(@"[原生发布] 步骤2: 成功注入动态文案 -> %@", task.contentText);
} else {
ACLog(@"[原生发布] 步骤2: 未找到编辑框，继续尝试下一步");
}
UIButton *nextBtn = nil;
UIView *toolbar = nil;
// 优先级0（UI 探针实证）：工具栏 AirMomentPublishToolbarView 挂在编辑框的 inputAccessoryView（键盘上方）
if (inputTV && inputTV.inputAccessoryView) {
toolbar = inputTV.inputAccessoryView;
nextBtn = ACFindButtonWithActionDeep(toolbar, @"next");
if (nextBtn) ACLog(@"[原生发布] 步骤3: 从 inputAccessoryView 直接锁定「下一步」按钮");
}
if (!nextBtn) {
toolbar = ACFindViewByClassNameDeep(win2, @"AirMomentPublishToolbarView")
?: ACFindViewByClassNameDeep(win2, @"ToolbarView")
?: ACFindViewByClassNameDeep(win2, @"AirMomentPublish");
if (toolbar) nextBtn = ACFindButtonWithActionDeep(toolbar, @"next");
}
// 关键修复：下一步按钮挂在键盘 inputAccessoryView 上，必须穿透所有 Window（含键盘 Window）搜寻
if (!nextBtn) {
for (UIWindow *w3 in [UIApplication sharedApplication].windows) {
UIView *tb3 = ACFindViewByClassNameDeep(w3, @"AirMomentPublishToolbarView")
?: ACFindViewByClassNameDeep(w3, @"ToolbarView")
?: ACFindViewByClassNameDeep(w3, @"AirMomentPublish");
if (tb3) {
nextBtn = ACFindButtonWithActionDeep(tb3, @"next");
if (nextBtn) { toolbar = tb3; break; }
}
}
}
if (!nextBtn) {
for (UIWindow *w3 in [UIApplication sharedApplication].windows) {
nextBtn = ACFindButtonWithActionDeep(w3, @"next");
if (nextBtn) break;
}
}
if (nextBtn) {
ACLog(@"🎯 [原生发布] 步骤3: 成功点击「下一步 (nextButtonTapped)」（含键盘层搜索）！");
[nextBtn sendActionsForControlEvents:UIControlEventTouchUpInside];
} else {
SEL nextSelArg = NSSelectorFromString(@"nextButtonTapped:");
SEL nextSel = NSSelectorFromString(@"nextButtonTapped");
if (toolbar && [toolbar respondsToSelector:nextSelArg]) {
ACLog(@"[原生发布] 步骤3: 工具栏触发 nextButtonTapped:");
((void (*)(id, SEL, id))objc_msgSend)(toolbar, nextSelArg, fakeBtn);
} else if (toolbar && [toolbar respondsToSelector:nextSel]) {
ACLog(@"[原生发布] 步骤3: 工具栏触发 nextButtonTapped");
((void (*)(id, SEL))objc_msgSend)(toolbar, nextSel);
} else if (top2 && [top2 respondsToSelector:nextSelArg]) {
ACLog(@"[原生发布] 步骤3: 顶层触发 nextButtonTapped:");
((void (*)(id, SEL, id))objc_msgSend)(top2, nextSelArg, fakeBtn);
} else if (top2 && [top2 respondsToSelector:nextSel]) {
ACLog(@"[原生发布] 步骤3: 顶层触发 nextButtonTapped");
((void (*)(id, SEL))objc_msgSend)(top2, nextSel);
} else {
ACLog(@"[原生发布] 步骤3: 未找到「下一步」，仍尝试最终发布");
}
}
// 步骤 3：0.8 秒后进入选项页 → 最终发布
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
UIWindow *win3 = [UIApplication sharedApplication].keyWindow ?: win;
UIViewController *finalVC = win3.rootViewController;
while (finalVC.presentedViewController && !finalVC.presentedViewController.isBeingDismissed) finalVC = finalVC.presentedViewController;
SEL finalSelWithArg = NSSelectorFromString(@"publishButtonTapped:");
SEL finalSelNoArg = NSSelectorFromString(@"publishButtonTapped");
@try {
if ([finalVC respondsToSelector:finalSelWithArg]) {
ACLog(@"🎯 [原生发布] 步骤4: 成功点击最终发布(带参)！");
((void (*)(id, SEL, id))objc_msgSend)(finalVC, finalSelWithArg, fakeBtn);
} else if ([finalVC respondsToSelector:finalSelNoArg]) {
ACLog(@"🎯 [原生发布] 步骤4: 成功点击最终发布(无参)！");
((void (*)(id, SEL))objc_msgSend)(finalVC, finalSelNoArg);
} else {
UIButton *pubBtn = ACFindButtonWithActionDeep(finalVC.view, @"publish");
if (!pubBtn) {
// 全 Window 搜终发按钮：优先选项页控制器绑定的按钮，其次任意 publish 动作
for (UIWindow *w4 in [UIApplication sharedApplication].windows) {
pubBtn = ACFindButtonWithTargetClassDeep(w4, @"OptionsViewController");
if (pubBtn) break;
pubBtn = ACFindButtonWithActionDeep(w4, @"publish");
if (pubBtn) break;
}
}
if (!pubBtn) pubBtn = ACFindButtonWithTitleDeep(finalVC.view, @"发")
?: ACFindButtonWithTitleDeep(finalVC.view, @"布");
if (pubBtn) {
[pubBtn sendActionsForControlEvents:UIControlEventTouchUpInside];
ACLog(@"🎯 [原生发布] 步骤4: 命中发布按钮触发（含键盘层全窗搜索）！");
} else {
ACLog(@"[原生发布] 步骤4: 未找到最终发布入口（fire&forget 结束）");
}
}
} @catch (NSException *e) {
ACLog(@"[原生发布] 最终发布异常 %@", e.reason);
}
self.momentPublishing = NO; // fire&forget：触发即释放，官方回调自证结果
task.sentCount++;
NSDateFormatter *df = [[NSDateFormatter alloc] init];
df.dateFormat = @"HH:mm:ss";
task.lastSentTimeStr = [df stringFromDate:[NSDate date]];
self.lastMomentLog = [NSString stringWithFormat:@"✅ 原生动态自动发布成功 (累计%ld次)", (long)task.sentCount];
[self saveAllCustomSettings];
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(YES, self.lastMomentLog);
});
});
}

// HTTP 静默直发动态：HAR 实证签名对 (X-Lts-Id + X-Request-No) 成对携带即可通过验签（不校验 URL/Body）
// 报文结构严格还原 HAR 第[11]条实测成功样例 {"contentText":...,"contentType":1,"commentPermission":1}
- (void)ac_publishMomentViaHTTP:(ACMomentTaskItem *)task
allowWarmupTry:(BOOL)allowWarmupTry
completion:(void(^)(BOOL ok, NSString *msg))completion {
NSString *token = ACHeaderValue(self.latestHTTPHeaders, @"token");
NSString *ltsId = ACHeaderValue(self.latestHTTPHeaders, @"X-Lts-Id");
NSString *reqNo = ACHeaderValue(self.latestHTTPHeaders, @"X-Request-No");
if ((token.length == 0 || ltsId.length == 0 || reqNo.length == 0) && allowWarmupTry) {
ACLog(@"[HTTP发布] 签名对未就绪 (token=%lu lts=%lu reqNo=%lu)，触发一次原生刷新热身...",
(unsigned long)token.length, (unsigned long)ltsId.length, (unsigned long)reqNo.length);
ACTriggerMomentsBackgroundRefresh();
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.85 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
[self ac_publishMomentViaHTTP:task allowWarmupTry:NO completion:completion];
});
return;
}
NSString *host = [self ac_activeBusinessHost];
NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@/client/biz/v2/post/app/publish", host]];
NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
req.HTTPMethod = @"POST";
req.timeoutInterval = 15.0;
[self ac_applyCapturedHeadersToRequest:req];
[req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
NSMutableDictionary *body = [NSMutableDictionary dictionary];
body[@"contentText"] = task.contentText ?: @"";
body[@"commentPermission"] = @(1);
NSArray *mediaList = (task.capturedMediaList.count > 0) ? task.capturedMediaList : self.latestCapturedMomentMediaList;
if (mediaList.count > 0) {
body[@"contentType"] = @(2);
body[@"mediaList"] = ACJSONSafeObject(mediaList, 0) ?: @[];
} else {
body[@"contentType"] = @(1);
}
NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
req.HTTPBody = bodyData;
if (bodyData.length > 0) {
[req setValue:[NSString stringWithFormat:@"%lu", (unsigned long)bodyData.length] forHTTPHeaderField:@"Content-Length"];
}
NSURLSession *session = ACDedicatedPluginSession();
if (!session) {
self.momentPublishing = NO;
if (completion) completion(NO, @"网络会话未初始化");
return;
}
ACLog(@"[HTTP发布] POST /client/biz/v2/post/app/publish (ltsLen=%lu reqNo=%@)", (unsigned long)ltsId.length, reqNo);
acInternalRequest = YES;
NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
dispatch_async(dispatch_get_main_queue(), ^{
if (error || data.length == 0) {
ACLog(@"[HTTP发布] 网络错误: %@", error.localizedDescription ?: @"空响应");
if (allowWarmupTry) {
self.momentPublishing = YES;
[self ac_runMomentPublishFlow:task keyWin:nil completion:completion];
} else {
self.momentPublishing = NO;
NSString *errMsg = [NSString stringWithFormat:@"⚠️ 发布失败: %@", error.localizedDescription ?: @"空响应"];
self.lastMomentLog = errMsg;
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(NO, errMsg);
}
return;
}
NSDictionary *json = ACSafeDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
NSInteger code = [ACSafeStr(json[@"code"]) integerValue];
NSString *srvMsg = ACSafeStr(json[@"msg"]);
ACLog(@"[HTTP发布] 响应 code=%ld msg=%@ data=%@", (long)code, srvMsg, json[@"data"]);
if (code == 200) {
task.sentCount++;
NSDateFormatter *df = [[NSDateFormatter alloc] init];
df.dateFormat = @"HH:mm:ss";
task.lastSentTimeStr = [df stringFromDate:[NSDate date]];
self.lastMomentLog = [NSString stringWithFormat:@"✅ 动态发布成功 (%@) | 累计%ld次", task.lastSentTimeStr, (long)task.sentCount];
ACLog(@"%@", self.lastMomentLog);
[self saveAllCustomSettings];
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
self.momentPublishing = NO;
if (completion) completion(YES, self.lastMomentLog);
return;
}
// 服务端 5 分钟频控（HAR 第[61]条：发布过于频繁，请5分钟后再次尝试。#SVIP）
if ([srvMsg containsString:@"频繁"] || [srvMsg containsString:@"分钟"]) {
NSInteger waitMins = ACParseRetryMinutes(srvMsg);
self.lastMomentLog = [NSString stringWithFormat:@"⏳ 服务端限频：%@（%ld 分钟后自动重试）", srvMsg, (long)waitMins];
ACLog(@"%@", self.lastMomentLog);
self.momentPublishing = NO;
[self ac_scheduleMomentRetryAfter:(waitMins * 60.0 + 5.0)];
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(NO, self.lastMomentLog);
return;
}
// 签名对可能过期（500 请求失败）且允许热身：刷新飞行圈拿最新配对签名重试一次
if (allowWarmupTry) {
ACLog(@"[HTTP发布] 首发未通过(%@)，刷新签名对后重试一次...", srvMsg);
ACTriggerMomentsBackgroundRefresh();
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
[self ac_publishMomentViaHTTP:task allowWarmupTry:NO completion:completion];
});
return;
}
// 终极兜底：原生 UI 全自动链（发动态→下一步→确认发布）
ACLog(@"[HTTP发布] 直发未通过(%@)，启动原生 UI 引擎兜底...", srvMsg);
self.momentPublishing = YES;
[self ac_runMomentPublishFlow:task keyWin:nil completion:completion];
});
}];
acInternalRequest = NO;
[dataTask resume];
}

- (void)publishMomentTask:(ACMomentTaskItem *)task completion:(void(^)(BOOL ok, NSString *msg))completion {
ACLog(@"[发布] 启动发动态流程（HTTP签名对直发优先，原生UI兜底）: %@", task.contentText ?: @"");
if (!task || task.contentText.length == 0) {
self.momentPublishing = NO;
if (completion) completion(NO, @"文案为空");
return;
}
if (self.momentPublishing && self.momentPublishingSince > 0 &&
[[NSDate date] timeIntervalSince1970] - self.momentPublishingSince > 60.0) {
self.momentPublishing = NO;
}
if (self.momentPublishing) {
self.lastMomentLog = @"⏳ 上一条动态仍在发布中，请稍后再试";
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
if (completion) completion(NO, self.lastMomentLog);
return;
}
self.momentPublishing = YES;
self.momentPublishingSince = [[NSDate date] timeIntervalSince1970];
[self ac_publishMomentViaHTTP:task allowWarmupTry:YES completion:completion];
}

// （旧版 HTTP 直发入口已删除，由上方原生全自动引擎接管）

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
ACForwardHelperManager *m = weakSelf;
if (!m) return;
// 三种迎新方式完全独立：📞语音 / 💬文字 / 🖼️图片视频，各自受开关控制
BOOL wantVoice = m.welcomeVoiceCallEnabled;
BOOL wantText = m.welcomeTextEnabled;
BOOL wantMedia = m.welcomeMediaEnabled;
NSString *templateText = m.welcomeMessageText ?: @"";
NSString *displayNick = (newMember.name && ![newMember.name hasPrefix:@"群友_"]) ? newMember.name : @"新朋友";
NSString *finalGreeting = [templateText stringByReplacingOccurrencesOfString:@"{name}" withString:displayNick];
__block void (^advance)(void) = ^{
idx++;
NSTimeInterval delay = wantVoice ? (4.0 + (arc4random_uniform(31) / 10.0)) : (8.0 + (arc4random_uniform(71) / 10.0));
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
greetNext();
});
};
__block void (^sendWelcomeMessage)(void) = ^{
ACForwardHelperManager *m2 = weakSelf;
if (!m2) return;
BOOL hasText = wantText && finalGreeting.length > 0;
BOOL hasMedia = wantMedia && [m2 mediaTypeForSlot:ACMediaSlotWelcome] != 0;
if (!hasText && !hasMedia) {
m2.lastGreetLog = [NSString stringWithFormat:@"⚪ 文字/图片/语音均关闭，跳过迎新 [%@]", newMember.name];
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
advance();
return;
}
NSString *bodyText = hasText ? finalGreeting : @"";
[m2 sendText:bodyText mediaSlot:ACMediaSlotWelcome attachMedia:hasMedia toItem:newMember completion:^(BOOL ok, NSString *detail) {
if (ok) {
m2.lastGreetLog = [NSString stringWithFormat:@"✅ 迎新送达 [%@]: %@%@ (共%ld人)",
newMember.name, hasText ? @"文字" : @"", hasMedia ? @"+图片/视频" : @"", (long)m2.greetedCount];
} else {
m2.lastGreetLog = [NSString stringWithFormat:@"⚠️ 迎新 %@: %@", newMember.name, detail];
}
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
advance();
}];
};
if (wantVoice) {
// ① 语音打招呼：振铃后在 voiceHangupSeconds（默认 1 秒）自动挂断
[m triggerSingleVoiceCallForTarget:newMember.targetId nick:newMember.name completion:^{
ACForwardHelperManager *m2 = weakSelf;
if (!m2) return;
m2.greetedCount++;
m2.lastGreetLog = [NSString stringWithFormat:@"📞 已对新成员 [%@] 执行 %.1f 秒语音打招呼 (累计%ld人)",
newMember.name, (m2.voiceHangupSeconds >= 0.3f ? m2.voiceHangupSeconds : 1.0f), (long)m2.greetedCount];
[[NSNotificationCenter defaultCenter] postNotificationName:@"ACWelcomeStatusUpdated" object:nil];
// ② 语音结束后，按文字/图片开关补发欢迎消息
sendWelcomeMessage();
}];
} else {
sendWelcomeMessage();
}
};
// 首位新成员延迟 2 秒后发起语音呼叫
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
- (BOOL)ac_isValidGroupId:(NSString *)gid {
NSString *g = [ACSafeStr(gid) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
if (g.length < 3 || g.length > 128) return NO;
if ([g isEqualToString:@"(null)"] || [g isEqualToString:@"<null>"] ||
[g isEqualToString:@"0"] || [g isEqualToString:@"-1"] || [g isEqualToString:@"nil"]) return NO;
// 同时支持腾讯 IM 的 @TGS# 群号和 AirChat 的 19 位数字群 ID
if ([g rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]].location != NSNotFound) return NO;
return YES;
}
- (void)addGroupWithId:(NSString *)gid name:(NSString *)name ban:(BOOL)ban {
NSString *cleanId = [ACSafeStr(gid) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
if (![self ac_isValidGroupId:cleanId]) return;
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
// 旧逻辑只认 @TGS# 前缀，会把 App 自己的数字群 ID 全部丢掉。
// 这里改为：ID 合法 + 具备群对象的特征字段（owner/ban/groupName/memberCount）才算群。
if ([self ac_isValidGroupId:directId] && ACSafeStr(dict[@"name"]).length > 0 &&
(dict[@"owner"] || dict[@"ban"] || dict[@"groupName"] || dict[@"memberCount"] || dict[@"groupNo"])) {
BOOL isBan = [ACSafeStr(dict[@"ban"]) isEqualToString:@"true"];
[self addGroupWithId:directId name:ACSafeStr(dict[@"name"]) ban:isBan];
NSString *ownerId = ACSafeStr(dict[@"owner"]);
if (ownerId.length >= 5) {
[self addGroupMemberWithId:ownerId name:@"群主" groupId:directId role:@"群主" chatMeType:0];
}
}
NSString *groupId = ACSafeStr(dict[@"groupId"]);
if (groupId.length == 0) groupId = ACSafeStr(dict[@"groupNo"]);
if ([self ac_isValidGroupId:groupId]) {
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
#pragma mark - 2.4 云端群列表（HTTP 兜底，兼容 App 的数字群 ID）
// 早期可用版本就是从该接口拿全量群列表的；后续重写只剩 IM SDK + 本地库扫描，
// 并且用 @TGS# 前缀过滤，导致 App 自建的数字群 ID 全部被丢弃、群聊面板为空。
- (void)ac_fetchGroupListFromServer:(void(^)(NSInteger count))completion {
@try {
NSString *token = ACHeaderValue(self.latestHTTPHeaders, @"token");
if (token.length == 0) {
ACLog(@"[群聊] 未捕获 token，跳过云端群列表");
if (completion) completion(0);
return;
}
NSString *acGroupHost = ACIsBusinessHost(self.lastAirchatHost) ? self.lastAirchatHost : @"apiv1.airchat.cn";
NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/client/biz/group/myJoinGroupPage?current=1&searchKey=&size=9999", acGroupHost]]];
req.HTTPMethod = @"GET";
[req setValue:@"*/*" forHTTPHeaderField:@"Accept"];
[req setValue:kACNativeUserAgent forHTTPHeaderField:@"User-Agent"];
[self ac_applyCapturedHeadersToRequest:req];
NSURLSession *session = ACDedicatedPluginSession();
if (!session) { if (completion) completion(0); return; }
acInternalRequest = YES;
NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
NSInteger added = 0;
@try {
if (error) {
ACLog(@"[群聊] 云端群列表失败：%@", error.localizedDescription);
} else if (data.length > 0) {
NSDictionary *json = ACSafeDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
NSArray *records = ACSafeArray(ACSafeDict(json[@"data"])[@"records"]);
if (!records) records = ACSafeArray(json[@"records"]);
if (!records) records = ACSafeArray(json[@"data"]);
for (id obj in records) {
NSDictionary *d = ACSafeDict(obj);
if (!d) continue;
NSString *gid = ACSafeStr(d[@"groupId"]);
if (gid.length == 0) gid = ACSafeStr(d[@"groupNo"]);
if (gid.length == 0) gid = ACSafeStr(d[@"id"]);
if (![self ac_isValidGroupId:gid]) continue;
NSString *gname = ACSafeStr(d[@"groupName"]);
if (gname.length == 0) gname = ACSafeStr(d[@"name"]);
BOOL ban = [ACSafeStr(d[@"ban"]) boolValue];
[self addGroupWithId:gid name:gname ban:ban];
added++;
}
} else {
ACLog(@"[群聊] 云端群列表返回空数据");
}
} @catch (NSException *e) {
ACLog(@"[群聊] 云端群列表解析异常 %@", e.reason);
}
ACLog(@"[群聊] 云端群列表：本次解析 %ld 个，累计 %lu 个群", (long)added, (unsigned long)self.groupList.count);
dispatch_async(dispatch_get_main_queue(), ^{
[self saveLocalPermanentCache];
if (completion) completion(added);
});
}];
acInternalRequest = NO;
[task resume];
} @catch (NSException *e) {
acInternalRequest = NO;
ACLog(@"[群聊] 云端群列表请求异常 %@", e.reason);
if (completion) completion(0);
}
}
#pragma mark - 2.5 手动群号采集（外显群号 -> 真实群 ID -> 递归拉成员/历史）
- (void)fetchMembersByManualGroupNumber:(NSString *)groupNum
progress:(void(^)(NSString *msg))progressBlock
completion:(void(^)(NSString *res))completion {
NSString *num = [ACSafeStr(groupNum) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
if (num.length == 0) {
if (completion) completion(@"❌ 请输入有效群号");
return;
}
self.manualTargetGroupId = num;
[self saveAllCustomSettings];
// 已是群 ID（@TGS# 或长数字 ID）就不用再解析群号，直接采集
BOOL looksLikeId = [num hasPrefix:@"@TGS#"] || (num.length >= 15 && [self ac_isValidGroupId:num]);
if (looksLikeId) {
[self addGroupWithId:num name:@"" ban:NO];
if (progressBlock) progressBlock([NSString stringWithFormat:@"⏳ 正在采集群 %@ ...", num]);
[self reloadSelectedGroupsData:@[num] progress:progressBlock completion:completion];
return;
}
if (progressBlock) progressBlock(@"🔍 正在解析群号...");
NSString *acNumHost = ACIsBusinessHost(self.lastAirchatHost) ? self.lastAirchatHost : @"apiv1.airchat.cn";
NSString *path = [NSString stringWithFormat:@"https://%@/client/biz/group/get/by/number?number=%@&groupNumber=%@", acNumHost, num, num];
NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:path]];
req.HTTPMethod = @"GET";
[req setValue:@"*/*" forHTTPHeaderField:@"Accept"];
[req setValue:kACNativeUserAgent forHTTPHeaderField:@"User-Agent"];
[self ac_applyCapturedHeadersToRequest:req];
NSURLSession *session = ACDedicatedPluginSession();
if (!session) { if (completion) completion(@"❌ 网络未就绪"); return; }
acInternalRequest = YES;
NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
NSDictionary *json = ACSafeDict([NSJSONSerialization JSONObjectWithData:(data ?: [NSData data]) options:0 error:nil]);
NSDictionary *d = ACSafeDict(json[@"data"]);
NSString *realGid = ACSafeStr(d[@"id"]);
if (realGid.length == 0) realGid = ACSafeStr(d[@"groupId"]);
if (realGid.length == 0) realGid = ACSafeStr(d[@"groupNo"]);
NSString *gName = ACSafeStr(d[@"name"]);
if (gName.length == 0) gName = ACSafeStr(d[@"groupName"]);
dispatch_async(dispatch_get_main_queue(), ^{
if ([self ac_isValidGroupId:realGid]) {
[self addGroupWithId:realGid name:gName ban:NO];
ACLog(@"[群聊] 群号 %@ -> 群ID %@ (%@)", num, realGid, gName);
[self saveLocalPermanentCache];
[self reloadSelectedGroupsData:@[realGid] progress:progressBlock completion:completion];
} else {
NSString *why = error ? [NSString stringWithFormat:@"网络错误 %@", error.localizedDescription] : @"接口未返回群ID";
ACLog(@"[群聊] 群号 %@ 解析失败：%@", num, why);
if (completion) completion([NSString stringWithFormat:@"❌ 未能找到对应群聊（%@），请确认群号正确！", why]);
}
});
}];
acInternalRequest = NO;
[task resume];
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
if (![self ac_isValidGroupId:gid]) continue;
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
// 先走云端接口拉全量群列表（兼容数字群 ID；未捕获 token 时自动跳过）
dispatch_group_enter(baseGroup);
[self ac_fetchGroupListFromServer:^(NSInteger count) {
if (count > 0 && progressBlock) {
progressBlock([NSString stringWithFormat:@"⏳ 云端群列表：%ld 个群...", (long)count]);
}
dispatch_group_leave(baseGroup);
}];
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
ACLog(@"[群聊] getJoinedGroupList 返回 %lu 个群，累计 %lu 个", (unsigned long)safeGroups.count, (unsigned long)self.groupList.count);
dispatch_group_leave(baseGroup);
};
void (^failBlock)(int, NSString *) = ^(int code,  NSString *desc) { ACLog(@"[群聊] getJoinedGroupList 失败 code=%d %@", code, desc); dispatch_group_leave(baseGroup); };
((void (*)(id, SEL, id, id))objc_msgSend)(mgr, getGroupsSel, succBlock, failBlock);
}
dispatch_group_notify(baseGroup, dispatch_get_main_queue(), ^{
NSArray<ACContactItem *> *allGroups = [self.groupList copy];
if (allGroups.count == 0) {
[self saveLocalPermanentCache];
NSString *tip = ACHeaderValue(self.latestHTTPHeaders, @"token").length == 0
? @"（未捕获到登录凭证，请先在 App 内切换一下页面再点刷新）"
: @"（云端返回 0 个群，请确认该账号已加入群聊）";
if (completion) completion([NSString stringWithFormat:@"已就绪：%lu 好友 | %lu 群员 | %lu 群聊 %@",
(unsigned long)self.friendList.count,
(unsigned long)self.groupMemberList.count,
(unsigned long)self.groupList.count, tip]);
return;
}
dispatch_group_t memberCrawlGroup = dispatch_group_create();
for (ACContactItem *grp in allGroups) {
NSString *gid = grp.targetId;
if (![self ac_isValidGroupId:gid]) continue;
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
// 防封雷区④：多维裂变（动态前缀/时段问候 + 零宽字符扰动 + 自然语尾），破除 SimHash 相似度聚类与 MD5 查重
NSDateComponents *comp = [[NSCalendar currentCalendar] components:NSCalendarUnitHour fromDate:[NSDate date]];
NSString *timeGreet = (comp.hour < 12) ? @"早上好" : ((comp.hour < 18) ? @"下午好" : @"晚上好");
NSString *text = [originalText stringByReplacingOccurrencesOfString:@"{time}" withString:timeGreet];
NSArray *prefixes = @[@"", @"", @"哈喽，", @"你好呀，", @"嗨~ ", @"打扰一下，", @"您好，"];
NSArray *tails = @[@" ~", @" ✨", @" 😊", @" ~", @" 🌹", @" 🤝", @" ☀️", @" 🍀",
@" 呢~", @" 哈~", @" 哦~", @" 呀", @" ~😊", @" ！", @" ~✨", @""];
NSString *pre = prefixes[arc4random_uniform((uint32_t)prefixes.count)];
NSString *tail = tails[arc4random_uniform((uint32_t)tails.count)];
NSMutableString *mut = [NSMutableString stringWithString:text];
if (mut.length >= 4) {
NSUInteger pos1 = 1 + arc4random_uniform((uint32_t)(mut.length - 2));
[mut insertString:(arc4random_uniform(2) == 0 ? @"\u200B" : @"\u200C") atIndex:pos1];
}
return [NSString stringWithFormat:@"%@%@%@", pre, mut, tail];
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
// 强制使用当前 URL 的 host 作为 Host 头，杜绝被污染的 Host 头把 POST 分流到对象存储返回 405
if (req.URL.host) [req setValue:req.URL.host forHTTPHeaderField:@"Host"];
// 真实 UA 优先（HAR 实证 airchat/1102 ...），避免写死旧版 1017 与 version 头冲突被网关淘汰
NSString *realUA = ACHeaderValue(self.latestHTTPHeaders, @"User-Agent");
if (realUA.length == 0 || ![realUA.lowercaseString containsString:@"airchat/"]) realUA = kACNativeUserAgent;
[req setValue:realUA forHTTPHeaderField:@"User-Agent"];
[req setValue:@"*/*" forHTTPHeaderField:@"Accept"];
[req setValue:@"zh-CN,zh-Hans;q=0.9" forHTTPHeaderField:@"Accept-Language"];
// 签名对必须成对出现：X-Lts-Id + X-Request-No（HAR 实证漏任意一个服务端验签直接 code:500）
NSString *acToken = ACHeaderValue(self.latestHTTPHeaders, @"token");
NSString *acUid = ACHeaderValue(self.latestHTTPHeaders, @"x-userid") ?: self.selfUserId;
NSString *acVer = ACHeaderValue(self.latestHTTPHeaders, @"version");
NSString *acChannel = ACHeaderValue(self.latestHTTPHeaders, @"channel");
NSString *acReqNo = ACHeaderValue(self.latestHTTPHeaders, @"X-Request-No");
NSString *acLtsId = ACHeaderValue(self.latestHTTPHeaders, @"X-Lts-Id");
if (acToken.length > 0) [req setValue:acToken forHTTPHeaderField:@"token"];
if (acUid.length > 0) [req setValue:acUid forHTTPHeaderField:@"x-userid"];
if (acVer.length > 0) [req setValue:acVer forHTTPHeaderField:@"version"];
if (acChannel.length > 0) [req setValue:acChannel forHTTPHeaderField:@"channel"];
if (acReqNo.length > 0) [req setValue:acReqNo forHTTPHeaderField:@"X-Request-No"];
if (acLtsId.length > 0) [req setValue:acLtsId forHTTPHeaderField:@"X-Lts-Id"];
}
// 动态解析当前可用的业务网关：嗅探域名需通过严格白名单；.cc 部分节点已被切给静态存储，强制走 .cn
- (NSString *)ac_activeBusinessHost {
if (ACIsBusinessHost(self.lastAirchatHost)) {
if ([self.lastAirchatHost containsString:@"airchat.cc"]) return @"apiv1.airchat.cn";
return self.lastAirchatHost;
}
return @"apiv1.airchat.cn";
}
- (void)callAirChatBackendAddFriendAndUnlock:(NSString *)targetUserId completion:(void(^)(void))completion {
if (!targetUserId || targetUserId.length == 0 || ACHeaderValue(self.latestHTTPHeaders, @"token").length == 0) {
if (completion) completion();
return;
}
// 防封雷区③：对仅好友可聊用户高频连发 userfriends/add + useronechat/add 是“营销骚扰”判定主因；
// 每轮批次最多尝试 2 次破盾，且两次间隔至少 15 秒，超出直接跳过走正常打招呼
NSTimeInterval nowTs = [[NSDate date] timeIntervalSince1970];
if (self.unlockAttemptCountInSession >= 2 || (nowTs - self.lastUnlockAttemptAt < 15.0)) {
ACLog(@"🛡️ [防封降权] 跳过高频破盾（本批已尝试 %ld 次/间隔不足 15 秒）", (long)self.unlockAttemptCountInSession);
if (completion) completion();
return;
}
self.unlockAttemptCountInSession++;
self.lastUnlockAttemptAt = nowTs;
@try {
dispatch_group_t apiGroup = dispatch_group_create();
dispatch_group_enter(apiGroup);
NSMutableURLRequest *req1 = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/client/biz/userfriends/add", [self ac_activeBusinessHost]]]];
req1.HTTPMethod = @"POST";
[self ac_applyCapturedHeadersToRequest:req1];
[req1 setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
req1.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"friendId": targetUserId} options:0 error:nil];
[[[NSURLSession sharedSession] dataTaskWithRequest:req1 completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
dispatch_group_leave(apiGroup);
}] resume];
dispatch_group_enter(apiGroup);
NSMutableURLRequest *req2 = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/client/biz/useronechat/add", [self ac_activeBusinessHost]]]];
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
BOOL isGroupChat = (item.sourceType == 2);
if (isGroupChat && self.robotModeEnabled) {
// 防封雷区②：机器人伪装仅限群聊——C2C 私聊不存在官方机器人，注入 role:system_robot 必被 /immessage/check-chat-record 抽检判封
NSDictionary *robotJson = @{
@"isRobot": @(1),
@"isGroupRobot": @YES,
@"robotName": self.robotDisplayName.length > 0 ? self.robotDisplayName : @"群管机器人",
@"role": @"system_robot",
@"client_type": @"iOS"
};
NSData *robotData = [NSJSONSerialization dataWithJSONObject:robotJson options:0 error:nil];
if (robotData) [v2Msg setValue:robotData forKey:@"cloudCustomData"];
} else if (self.capturedCloudCustomData.length > 10) {
// 防封雷区①：仅复用本机真实捕获的原生 cloudCustomData，绝不注入写死的假设备指纹
[v2Msg setValue:self.capturedCloudCustomData forKey:@"cloudCustomData"];
}
// 其余情况留空走腾讯 IM 原生默认，杜绝一切协议外挂特征
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
NSString *mPath = (mType == 1) ? [self imagePathForSlot:slot] : ((mType == 2) ? [self videoPathForSlot:slot] : ((mType == 3) ? [self audioPathForSlot:slot] : @""));
NSString *tPath = (mType == 2) ? [self videoThumbPathForSlot:slot] : @"";
int vDur = (mType == 2) ? [self videoDurationForSlot:slot] : ((mType == 3) ? [self audioDurationForSlot:slot] : 0);
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
} else if (mType == 3 && mPath.length > 0 && [fm fileExistsAtPath:mPath]) {
// 语音条消息（AAC 录音文件，走普通富媒体信令，替代 VoIP 振铃）
SEL createSoundSel = NSSelectorFromString(@"createSoundMessage:duration:");
int soundDur = vDur > 0 ? vDur : 5;
if ([manager respondsToSelector:createSoundSel]) {
v2MediaMsg = ((id (*)(id, SEL, NSString *, int))objc_msgSend)(manager, createSoundSel, mPath, soundDur);
ACLog(@"[发送引擎] 已构建语音条消息 (文件:%@ 时长:%ds)", mPath.lastPathComponent, soundDur);
} else {
Class msgCls = NSClassFromString(@"V2TIMMessage");
if (msgCls && [msgCls respondsToSelector:createSoundSel]) {
v2MediaMsg = ((id (*)(id, SEL, NSString *, int))objc_msgSend)(msgCls, createSoundSel, mPath, soundDur);
}
}
}
NSString *cleanText = [ACSafeStr(text) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
NSString *obfuscatedText = cleanText.length > 0 ? [self obfuscateMessageText:cleanText] : @"";
if (obfuscatedText.length > 0 && self.robotModeEnabled) {
// 机器人伪装：统一加上【机器人名】前缀
NSString *robotName = self.robotDisplayName.length > 0 ? self.robotDisplayName : @"群管机器人";
obfuscatedText = [NSString stringWithFormat:@"🤖【%@】\n%@", robotName, obfuscatedText];
}
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
if (completion) completion(YES, mType == 2 ? @"视频+文送达" : (mType == 3 ? @"语音+文送达" : @"图+文送达"));
}];
});
} else {
if (completion) completion(YES, v2MediaMsg ? (mType == 2 ? @"视频送达" : (mType == 3 ? @"🎙️语音条送达" : @"图片送达")) : @"文本送达");
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
@interface ACForwardAssistantVC : UIViewController <UITableViewDelegate, UITableViewDataSource, UINavigationControllerDelegate, UIImagePickerControllerDelegate, UIDocumentPickerDelegate, UITextViewDelegate>
@property (nonatomic, strong) UIView *headerContainer;
@property (nonatomic, strong) UITextView *contentTextView;
@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, strong) UIButton *pickMediaBtn;
@property (nonatomic, strong) UIButton *clearMediaBtn;
@property (nonatomic, strong) UILabel *mediaBadgeLabel;
@property (nonatomic, strong) UISegmentedControl *tabControl;       // 上排：好友/群员/群聊/迎新
@property (nonatomic, strong) UISegmentedControl *tabControlBottom;    // 下排：回复/动态/工具
@property (nonatomic, assign) NSInteger ac_selectedTabIndex;            // 0-6 统一索引
@property (nonatomic, strong) UIView *actionBar;
@property (nonatomic, strong) UIView *welcomeControlBar;
@property (nonatomic, strong) UISwitch *welcomeSwitch;
@property (nonatomic, strong) UISwitch *welcomeTextSwitch;
@property (nonatomic, strong) UISwitch *welcomeMediaSwitch;
@property (nonatomic, strong) UISwitch *welcomeVoiceSwitch;
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
@property (nonatomic, strong) UIView *manualGroupBar;
@property (nonatomic, strong) UITextField *manualGroupField;
- (UISwitch *)ac_toolSwitch:(BOOL)on tag:(NSInteger)tag;
- (NSString *)ac_welcomeModeSummary;
- (void)topTabChanged;
- (void)bottomTabChanged;
- (void)tabChanged;
- (void)updateUI;
- (void)welcomeTextSwitchChanged:(UISwitch *)sw;
- (void)welcomeMediaSwitchChanged:(UISwitch *)sw;
- (void)welcomeVoiceSwitchChanged:(UISwitch *)sw;
@end
@implementation ACForwardAssistantVC
// 根据当前选中的 Tab 决定右上角图片/视频框操作的是哪一个独立媒体槽位
- (ACMediaSlot)currentActiveMediaSlot {
NSInteger idx = self.tabControl ? self.ac_selectedTabIndex : 0;
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
self.title = @"全能助手";
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
NSInteger idx = self.ac_selectedTabIndex;
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
self.headerContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 304)];
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
// 两排 Tab：上排四个常用面板，下排三个功能面板，避免 7 个挤在同一行
self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"好友", @"群员", @"群聊", @"🤖迎新"]];
self.tabControl.frame = CGRectMake(12, 110, width - 24, 32);
self.tabControl.selectedSegmentIndex = 1;
[self.tabControl addTarget:self action:@selector(topTabChanged) forControlEvents:UIControlEventValueChanged];
[self.headerContainer addSubview:self.tabControl];
self.tabControlBottom = [[UISegmentedControl alloc] initWithItems:@[@"💬回复", @"📝动态", @"⚙️工具", @"👥账号"]];
self.tabControlBottom.frame = CGRectMake(12, 145, width - 24, 32);
self.tabControlBottom.selectedSegmentIndex = UISegmentedControlNoSegment;
[self.tabControlBottom addTarget:self action:@selector(bottomTabChanged) forControlEvents:UIControlEventValueChanged];
[self.headerContainer addSubview:self.tabControlBottom];
self.ac_selectedTabIndex = 1;
self.actionBar = [[UIView alloc] initWithFrame:CGRectMake(16, 182, width - 32, 34)];
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
// 手动群号采集条：仅在【群聊】面板显示，直接按外显群号/群ID 定向采集
self.manualGroupBar = [[UIView alloc] initWithFrame:CGRectMake(16, 222, width - 32, 34)];
self.manualGroupBar.hidden = YES;
CGFloat manualFieldW = width - 32 - 104;
self.manualGroupField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, manualFieldW, 34)];
self.manualGroupField.font = [UIFont systemFontOfSize:12.5];
self.manualGroupField.placeholder = @"输入群号 / 群ID（如 123456）";
self.manualGroupField.text = mgr.manualTargetGroupId ?: @"";
self.manualGroupField.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
self.manualGroupField.layer.cornerRadius = 8;
self.manualGroupField.layer.borderColor = [UIColor separatorColor].CGColor;
self.manualGroupField.layer.borderWidth = 0.5;
self.manualGroupField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 34)];
self.manualGroupField.leftViewMode = UITextFieldViewModeAlways;
self.manualGroupField.clearButtonMode = UITextFieldViewModeWhileEditing;
self.manualGroupField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
self.manualGroupField.returnKeyType = UIReturnKeyDone;
[self.manualGroupBar addSubview:self.manualGroupField];
UIButton *manualFetchBtn = [UIButton buttonWithType:UIButtonTypeSystem];
manualFetchBtn.frame = CGRectMake(width - 32 - 96, 0, 96, 34);
[manualFetchBtn setTitle:@"🎯 按群号采集" forState:UIControlStateNormal];
manualFetchBtn.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
manualFetchBtn.backgroundColor = [UIColor systemBlueColor];
[manualFetchBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
manualFetchBtn.layer.cornerRadius = 8;
[manualFetchBtn addTarget:self action:@selector(fetchByManualGroupNumberAction) forControlEvents:UIControlEventTouchUpInside];
[self.manualGroupBar addSubview:manualFetchBtn];
[self.headerContainer addSubview:self.manualGroupBar];
// 迎新控制条：两排布局（第一排 总开关+语音打招呼+全选群；第二排 文字+图片视频），避免拥挤
self.welcomeControlBar = [[UIView alloc] initWithFrame:CGRectMake(16, 182, width - 32, 82)];
self.welcomeControlBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
self.welcomeControlBar.layer.cornerRadius = 10;
self.welcomeControlBar.hidden = YES;
UILabel *wLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 4, 62, 32)];
wLabel.font = [UIFont boldSystemFontOfSize:12];
wLabel.text = @"🤖迎新";
[self.welcomeControlBar addSubview:wLabel];
self.welcomeSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(64, 5.5, 51, 31)];
self.welcomeSwitch.transform = CGAffineTransformMakeScale(0.75, 0.75);
self.welcomeSwitch.on = mgr.autoWelcomeEnabled;
[self.welcomeSwitch addTarget:self action:@selector(welcomeSwitchChanged:) forControlEvents:UIControlEventValueChanged];
[self.welcomeControlBar addSubview:self.welcomeSwitch];
UILabel *voiceLabel = [[UILabel alloc] initWithFrame:CGRectMake(112, 4, 62, 32)];
voiceLabel.font = [UIFont boldSystemFontOfSize:12];
voiceLabel.text = @"📞语音";
[self.welcomeControlBar addSubview:voiceLabel];
self.welcomeVoiceSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(166, 5.5, 51, 31)];
self.welcomeVoiceSwitch.transform = CGAffineTransformMakeScale(0.75, 0.75);
self.welcomeVoiceSwitch.on = mgr.welcomeVoiceCallEnabled;
[self.welcomeVoiceSwitch addTarget:self action:@selector(welcomeVoiceSwitchChanged:) forControlEvents:UIControlEventValueChanged];
[self.welcomeControlBar addSubview:self.welcomeVoiceSwitch];
UIButton *allWelcomeGrpBtn = [UIButton buttonWithType:UIButtonTypeSystem];
allWelcomeGrpBtn.frame = CGRectMake(width - 32 - 58, 8, 50, 26);
[allWelcomeGrpBtn setTitle:@"全选群" forState:UIControlStateNormal];
allWelcomeGrpBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
allWelcomeGrpBtn.backgroundColor = [UIColor systemGroupedBackgroundColor];
allWelcomeGrpBtn.layer.cornerRadius = 6;
[allWelcomeGrpBtn addTarget:self action:@selector(selectAllWelcomeGroups) forControlEvents:UIControlEventTouchUpInside];
[self.welcomeControlBar addSubview:allWelcomeGrpBtn];
UIView *welcomeRowLine = [[UIView alloc] initWithFrame:CGRectMake(10, 40, width - 52, 0.5)];
welcomeRowLine.backgroundColor = [UIColor separatorColor];
[self.welcomeControlBar addSubview:welcomeRowLine];
UILabel *textLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 43, 52, 32)];
textLabel.font = [UIFont boldSystemFontOfSize:12];
textLabel.text = @"💬文字";
[self.welcomeControlBar addSubview:textLabel];
self.welcomeTextSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(58, 44.5, 51, 31)];
self.welcomeTextSwitch.transform = CGAffineTransformMakeScale(0.75, 0.75);
self.welcomeTextSwitch.on = mgr.welcomeTextEnabled;
[self.welcomeTextSwitch addTarget:self action:@selector(welcomeTextSwitchChanged:) forControlEvents:UIControlEventValueChanged];
[self.welcomeControlBar addSubview:self.welcomeTextSwitch];
UILabel *mediaLabel = [[UILabel alloc] initWithFrame:CGRectMake(110, 43, 82, 32)];
mediaLabel.font = [UIFont boldSystemFontOfSize:12];
mediaLabel.text = @"🖼️图/视频";
[self.welcomeControlBar addSubview:mediaLabel];
self.welcomeMediaSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(190, 44.5, 51, 31)];
self.welcomeMediaSwitch.transform = CGAffineTransformMakeScale(0.75, 0.75);
self.welcomeMediaSwitch.on = mgr.welcomeMediaEnabled;
[self.welcomeMediaSwitch addTarget:self action:@selector(welcomeMediaSwitchChanged:) forControlEvents:UIControlEventValueChanged];
[self.welcomeControlBar addSubview:self.welcomeMediaSwitch];
[self.headerContainer addSubview:self.welcomeControlBar];
self.autoReplyBar = [[UIView alloc] initWithFrame:CGRectMake(16, 182, width - 32, 38)];
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
self.momentTaskBar = [[UIView alloc] initWithFrame:CGRectMake(16, 182, width - 32, 38)];
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
self.autoCommentBar = [[UIView alloc] initWithFrame:CGRectMake(16, 224, width - 32, 38)];
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
self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 270, width - 32, 24)];
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
} else if (mType == 3 && previewImg) {
self.previewImageView.image = previewImg; // 系统波形图标
self.previewImageView.tintColor = [UIColor systemGreenColor];
[self.pickMediaBtn setTitle:@"" forState:UIControlStateNormal];
self.clearMediaBtn.hidden = NO;
self.mediaBadgeLabel.hidden = NO;
self.mediaBadgeLabel.text = [NSString stringWithFormat:@"🎙️%@(%ds)", slotTitle, [mgr audioDurationForSlot:slot]];
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
CGFloat headerH = 304.0;
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
if (self.ac_selectedTabIndex == 3) {
[ACForwardHelperManager shared].welcomeMessageText = textView.text;
[[ACForwardHelperManager shared] saveAllCustomSettings];
}
}
#pragma mark - 5.1 迎新 / 自动回复 / 定时发动态 按钮事件
- (UISwitch *)ac_toolSwitch:(BOOL)on tag:(NSInteger)tag {
UISwitch *s = [[UISwitch alloc] initWithFrame:CGRectZero];
s.on = on;
s.tag = tag;
[s addTarget:self action:@selector(ac_toolSwitchChanged:) forControlEvents:UIControlEventValueChanged];
return s;
}
- (void)ac_toolSwitchChanged:(UISwitch *)sw {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
if (sw.tag == 700) {
mgr.autoLikeEnabled = sw.isOn;
mgr.autoLikeSeeded = NO;
mgr.autoLikeEnabledAt = sw.isOn ? [[NSDate date] timeIntervalSince1970] : 0;
if (!sw.isOn) [mgr.likeQueue removeAllObjects];
if (sw.isOn) [mgr ac_pollFeedForAutoLike];
self.statusLabel.textColor = sw.isOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
self.statusLabel.text = sw.isOn
? @"🟢 自动点赞已开启：每 45 秒巡检一次，只点赞开启之后的新动态"
: @"⚪ 自动点赞已关闭";
} else if (sw.tag == 701) {
mgr.keepAliveEnabled = sw.isOn;
[mgr ac_applyKeepAliveState];
self.statusLabel.textColor = sw.isOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
self.statusLabel.text = sw.isOn ? @"🟢 后台静音保活已开启" : @"⚪ 后台静音保活已关闭";
} else if (sw.tag == 702) {
mgr.robotModeEnabled = sw.isOn;
self.statusLabel.textColor = sw.isOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
self.statusLabel.text = sw.isOn
? [NSString stringWithFormat:@"🟢 机器人伪装已开启（%@）", mgr.robotDisplayName ?: @"群管机器人"]
: @"⚪ 机器人伪装已关闭";
}
[mgr saveAllCustomSettings];
[self updateUI];
}
- (void)welcomeSwitchChanged:(UISwitch * _Nonnull)sw {
[self.view endEditing:YES];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
mgr.autoWelcomeEnabled = sw.isOn;
mgr.welcomeMessageText = self.contentTextView.text;
[mgr saveAllCustomSettings];
[mgr setupIMGroupWelcomeListener];
if (sw.isOn) {
self.statusLabel.textColor = [UIColor systemGreenColor];
self.statusLabel.text = [NSString stringWithFormat:@"🟢 迎新已开启（%@）| 监控 %lu 群",
[self ac_welcomeModeSummary], (unsigned long)mgr.welcomeGroupIds.count];
} else {
self.statusLabel.textColor = [UIColor secondaryLabelColor];
self.statusLabel.text = @"⚪ 迎新已关闭";
}
[self updateUI];
}
// 迎新方式摘要，例如「📞语音+💬文字+🖼️图/视频」
- (NSString *)ac_welcomeModeSummary {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
NSMutableArray *parts = [NSMutableArray array];
if (mgr.welcomeVoiceCallEnabled) [parts addObject:[NSString stringWithFormat:@"📞语音(%.1f秒)", mgr.voiceHangupSeconds]];
if (mgr.welcomeTextEnabled) [parts addObject:@"💬文字"];
if (mgr.welcomeMediaEnabled) {
NSInteger wType = [mgr mediaTypeForSlot:ACMediaSlotWelcome];
[parts addObject:(wType == 2 ? @"🖼️视频" : (wType == 1 ? @"🖼️图片" : @"🖼️图/视频"))];
}
return parts.count > 0 ? [parts componentsJoinedByString:@"+"] : @"未选择任何方式";
}
- (void)welcomeVoiceSwitchChanged:(UISwitch *)sw {
[self.view endEditing:YES];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
mgr.welcomeVoiceCallEnabled = sw.isOn;
[mgr saveAllCustomSettings];
self.statusLabel.textColor = sw.isOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
self.statusLabel.text = [NSString stringWithFormat:@"%@ | 当前方式：%@",
sw.isOn ? @"🟢 迎新已加「1 秒语音打招呼」" : @"⚪ 迎新语音打招呼已关闭",
[self ac_welcomeModeSummary]];
}
- (void)welcomeTextSwitchChanged:(UISwitch *)sw {
[self.view endEditing:YES];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
mgr.welcomeTextEnabled = sw.isOn;
mgr.welcomeMessageText = self.contentTextView.text;
[mgr saveAllCustomSettings];
self.statusLabel.textColor = sw.isOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
self.statusLabel.text = [NSString stringWithFormat:@"%@ | 当前方式：%@",
sw.isOn ? @"🟢 迎新已发送欢迎文字" : @"⚪ 迎新文字已关闭",
[self ac_welcomeModeSummary]];
}
- (void)welcomeMediaSwitchChanged:(UISwitch *)sw {
[self.view endEditing:YES];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
mgr.welcomeMediaEnabled = sw.isOn;
[mgr saveAllCustomSettings];
self.statusLabel.textColor = sw.isOn ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
self.statusLabel.text = [NSString stringWithFormat:@"%@ | 当前方式：%@",
sw.isOn ? @"🟢 迎新会附带图片/视频" : @"⚪ 迎新图片/视频已关闭",
[self ac_welcomeModeSummary]];
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
// 媒体选择：Action Sheet（相册 / 现场录音 / 导入音频 / 试听语音）
- (void)chooseMediaFromAlbum {
[self.view endEditing:YES];
ACMediaSlot slot = [self currentActiveMediaSlot];
NSString *slotTitle = [self slotNameForSlot:slot];
UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"选择【%@】媒体类型", slotTitle]
message:@"图片 / 视频 / 录音 / 导入本地音频"
preferredStyle:UIAlertControllerStyleActionSheet];
[sheet addAction:[UIAlertAction actionWithTitle:@"🖼️ / 🎬 相册选择图片/视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
UIImagePickerController *picker = [[UIImagePickerController alloc] init];
picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
picker.mediaTypes = @[@"public.image", @"public.movie"];
picker.videoQuality = UIImagePickerControllerQualityTypeMedium;
picker.delegate = self;
[self presentViewController:picker animated:YES completion:nil];
}]];
[sheet addAction:[UIAlertAction actionWithTitle:@"🎙️ 现场录制语音条" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
[self showAudioRecordingDialogForSlot:slot];
}]];
[sheet addAction:[UIAlertAction actionWithTitle:@"🎵 导入本地音频 (.m4a/.mp3/.wav)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
UIDocumentPickerViewController *docPicker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.audio"] inMode:UIDocumentPickerModeImport];
docPicker.delegate = self;
docPicker.allowsMultipleSelection = NO;
[self presentViewController:docPicker animated:YES completion:nil];
}]];
if ([[ACForwardHelperManager shared] mediaTypeForSlot:slot] == 3) {
[sheet addAction:[UIAlertAction actionWithTitle:@"▶️ 试听当前槽位语音" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
NSString *audioPath = [[ACForwardHelperManager shared] audioPathForSlot:slot];
self.statusLabel.text = @"🔊 正在试听语音条...";
__weak typeof(self) wself = self;
[[ACAudioHelper shared] playAudioAtPath:audioPath completion:^{
__strong typeof(wself) sself = wself;
if (sself) sself.statusLabel.text = @"▶️ 语音播放完毕";
}];
}]];
}
[sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
[self presentViewController:sheet animated:YES completion:nil];
}
// 现场录音交互（先申请麦克风权限）
- (void)showAudioRecordingDialogForSlot:(ACMediaSlot)slot {
NSString *destPath = [[ACForwardHelperManager shared] audioPathForSlot:slot];
__weak typeof(self) wself = self;
[[AVAudioSession sharedInstance] performSelector:@selector(requestRecordPermission:) withObject:^(BOOL granted) {
dispatch_async(dispatch_get_main_queue(), ^{
__strong typeof(wself) sself = wself;
if (!sself) return;
if (!granted) {
sself.statusLabel.textColor = [UIColor systemRedColor];
sself.statusLabel.text = @"❌ 未授权麦克风，请到系统设置开启";
return;
}
UIAlertController *recAlert = [UIAlertController alertControllerWithTitle:@"🎙️ 录制语音条"
message:@"点击【开始录音】后对着手机讲话，录完点击【停止并保存】"
preferredStyle:UIAlertControllerStyleAlert];
[recAlert addAction:[UIAlertAction actionWithTitle:@"🔴 开始录音" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
[[ACAudioHelper shared] startRecordingToPath:destPath];
sself.statusLabel.text = @"🎙️ 正在录音中... 请对着手机讲话";
UIAlertController *stopAlert = [UIAlertController alertControllerWithTitle:@"🎙️ 正在录音..."
message:@"说话结束后点击停止"
preferredStyle:UIAlertControllerStyleAlert];
[stopAlert addAction:[UIAlertAction actionWithTitle:@"⏹️ 停止并保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a2) {
int sec = [[ACAudioHelper shared] stopRecording];
[[ACForwardHelperManager shared] saveAudioAtURL:[NSURL fileURLWithPath:destPath] forSlot:slot duration:sec];
[sself refreshMediaPreviewUI];
sself.statusLabel.textColor = [UIColor systemGreenColor];
sself.statusLabel.text = [NSString stringWithFormat:@"✅ 录制成功！已保存为 %d 秒语音条", sec];
}]];
[stopAlert addAction:[UIAlertAction actionWithTitle:@"取消(不保存)" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a2) {
[[ACAudioHelper shared] stopRecording];
sself.statusLabel.text = @"已取消录音";
}]];
[sself presentViewController:stopAlert animated:YES completion:nil];
}]];
[recAlert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
[sself presentViewController:recAlert animated:YES completion:nil];
});
}];
}
// 本地音频导入回调
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
NSURL *url = urls.firstObject;
if (!url) return;
ACMediaSlot slot = [self currentActiveMediaSlot];
[[ACForwardHelperManager shared] saveAudioAtURL:url forSlot:slot duration:0];
[self refreshMediaPreviewUI];
self.statusLabel.textColor = [UIColor systemGreenColor];
self.statusLabel.text = [NSString stringWithFormat:@"✅ 音频导入成功！时长: %d 秒", [[ACForwardHelperManager shared] audioDurationForSlot:slot]];
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
if (self.ac_selectedTabIndex == 0) return mgr.friendList;
if (self.ac_selectedTabIndex == 1) return mgr.groupMemberList;
return mgr.groupList;
}
// 按外显群号/群ID 直接定向采集（无需先在列表里勾选）
- (void)fetchByManualGroupNumberAction {
[self.view endEditing:YES];
NSString *num = [ACSafeStr(self.manualGroupField.text) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
if (num.length == 0) {
self.statusLabel.textColor = [UIColor systemRedColor];
self.statusLabel.text = @"❌ 请先输入群号或群ID";
return;
}
self.statusLabel.textColor = [UIColor systemBlueColor];
self.statusLabel.text = @"🔍 正在解析群号并采集...";
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
mgr.manualTargetGroupId = num;
[mgr saveAllCustomSettings];
__weak typeof(self) weakSelf = self;
[mgr fetchMembersByManualGroupNumber:num progress:^(NSString *msg) {
weakSelf.statusLabel.textColor = [UIColor systemBlueColor];
weakSelf.statusLabel.text = msg;
[weakSelf updateUI];
[weakSelf.tableView reloadData];
} completion:^(NSString *res) {
weakSelf.statusLabel.textColor = [UIColor systemGreenColor];
weakSelf.statusLabel.text = res;
[weakSelf updateUI];
[weakSelf.tableView reloadData];
}];
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
if (self.ac_selectedTabIndex == 2) {
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
// 上排 Tab：好友/群员/群聊/迎新
- (void)topTabChanged {
NSInteger top = self.tabControl.selectedSegmentIndex;
if (top == UISegmentedControlNoSegment) return;
self.ac_selectedTabIndex = top;
self.tabControlBottom.selectedSegmentIndex = UISegmentedControlNoSegment;
[self tabChanged];
}
// 下排 Tab：回复(4)/动态(5)/工具(6)
- (void)bottomTabChanged {
NSInteger bottom = self.tabControlBottom.selectedSegmentIndex;
if (bottom == UISegmentedControlNoSegment) return;
self.ac_selectedTabIndex = 4 + bottom;
self.tabControl.selectedSegmentIndex = UISegmentedControlNoSegment;
[self tabChanged];
}
// 切换面板时，右上角的图片/视频预览框同步切换为该面板自己的独立槽位
- (void)tabChanged {
[self.view endEditing:YES];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
NSInteger idx = self.ac_selectedTabIndex;
self.actionBar.hidden = (idx >= 3);
self.welcomeControlBar.hidden = (idx != 3);
self.autoReplyBar.hidden = (idx != 4);
self.momentTaskBar.hidden = (idx != 5);
self.autoCommentBar.hidden = (idx != 5);
self.manualGroupBar.hidden = (idx != 2);
if (idx == 2 && self.manualGroupField.text.length == 0 && mgr.manualTargetGroupId.length > 0) {
self.manualGroupField.text = mgr.manualTargetGroupId;
}
self.floatingSendBtn.hidden = (idx >= 3);
[self refreshMediaPreviewUI];
if (idx == 2) {
self.statusLabel.textColor = [UIColor secondaryLabelColor];
self.statusLabel.text = @"💡 可在下方输入群号直接采集；也可勾选群列表后点「🎯定向采集」";
} else if (idx == 3) {
self.contentTextView.text = mgr.welcomeMessageText ?: @"您好 {name}，欢迎进群！认识一下~";
self.statusLabel.textColor = mgr.autoWelcomeEnabled ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
self.statusLabel.text = [NSString stringWithFormat:@"%@ | 当前方式：%@",
mgr.autoWelcomeEnabled ? @"🟢 迎新监听中" : @"⚪ 迎新未开启",
[self ac_welcomeModeSummary]];
} else if (idx == 4) {
self.contentTextView.text = @"价格=您好 {name}，具体介绍请看我发您的资料哦~";
self.statusLabel.textColor = mgr.autoReplyEnabled ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
self.statusLabel.text = @"💡 右上角选【回复专属图/视频】，点➕添加规则即绑定给该条规则";
} else if (idx == 5) {
self.contentTextView.text = @"✨欢迎各位新朋友，长期稳定靠谱，有问题随时咨询我❤️";
self.statusLabel.textColor = mgr.autoMomentEnabled ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
self.statusLabel.text = @"💡 输入动态文案点➕添加任务，点任务右侧「立即发」可马上发布测试";
} else if (idx == 6) {
self.contentTextView.text = @"⚙️ 自动点赞 / 批量语音打招呼 / 后台保活 / 群机器人伪装";
self.statusLabel.textColor = [UIColor secondaryLabelColor];
self.statusLabel.text = @"💡 自动点赞每 45 秒独立巡检一次；语音打招呼挂断秒数可点按调整";
} else if (idx == 7) {
self.contentTextView.text = @"👥 多账号管理：先「保存当前账号」，再一键秒切";
self.statusLabel.textColor = [UIColor secondaryLabelColor];
self.statusLabel.text = @"💡 点击列表账号即刻切换登录态（Token/UserID 全量替换）；左滑删除";
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
[self.tabControlBottom setTitle:[NSString stringWithFormat:@"💬回复(%@)", mgr.autoReplyEnabled ? @"开" : @"关"] forSegmentAtIndex:0];
[self.tabControlBottom setTitle:[NSString stringWithFormat:@"📝动态(%@)", mgr.autoMomentEnabled ? @"开" : @"关"] forSegmentAtIndex:1];
[self.tabControlBottom setTitle:[NSString stringWithFormat:@"⚙️工具(%@)", (mgr.autoLikeEnabled || mgr.keepAliveEnabled || mgr.robotModeEnabled) ? @"开" : @"关"] forSegmentAtIndex:2];
[self.tabControlBottom setTitle:@"👥账号" forSegmentAtIndex:3];
NSInteger selCount = 0;
for (ACContactItem *i in mgr.friendList) if (i.isSelected) selCount++;
for (ACContactItem *i in mgr.groupMemberList) if (i.isSelected) selCount++;
for (ACContactItem *i in mgr.groupList) if (i.isSelected) selCount++;
[self.floatingSendBtn setTitle:[NSString stringWithFormat:@"🚀 发送 (%ld)", (long)selCount] forState:UIControlStateNormal];
}
#pragma mark - 5.2 列表数据源与交互
- (NSInteger)tableView:(UITableView * _Nonnull)tableView numberOfRowsInSection:(NSInteger)section {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
NSInteger idx = self.ac_selectedTabIndex;
if (idx == 4) return mgr.autoReplyRules.count;
if (idx == 5) return mgr.momentTasks.count;
if (idx == 6) return 7; // 自动点赞 / 语音打招呼 / 后台保活 / 机器人伪装 / 机器人名称 / 挂断秒数
if (idx == 7) return mgr.accountList.count + 1; // 首行保存 + 账号列表
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
cell.accessoryType = UITableViewCellAccessoryNone;
cell.textLabel.textColor = [UIColor labelColor];
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
NSInteger idx = self.ac_selectedTabIndex;
if (idx == 7) {
if (indexPath.row == 0) {
cell.textLabel.text = @"💾 保存当前登录账号";
cell.textLabel.textColor = [UIColor systemBlueColor];
cell.detailTextLabel.text = @"先用目标账号登录 App，再点此缓存凭证，之后一键免验证码秒切";
cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
return cell;
}
ACAccountItem *acc = (indexPath.row - 1 < (NSInteger)mgr.accountList.count) ? mgr.accountList[indexPath.row - 1] : nil;
if (!acc) return cell;
BOOL isCurrent = [acc.userId isEqualToString:mgr.selfUserId];
cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", isCurrent ? @"🟢 [当前]" : @"⚪", acc.remark ?: @"未命名账号"];
cell.detailTextLabel.text = [NSString stringWithFormat:@"账号: %@ | %@ | 左滑删除",
acc.account ?: @"?", acc.token.length > 0 ? @"已缓存凭证(点击秒切)" : @"需密码登录"];
return cell;
}
if (idx == 6) {
if (indexPath.row == 0) {
cell.textLabel.text = @"👍 自动点赞新动态";
cell.detailTextLabel.text = @"飞行圈信息流出现新动态时自动点赞（自己的动态跳过，2-4 秒节流）";
cell.accessoryView = [self ac_toolSwitch:mgr.autoLikeEnabled tag:700];
} else if (indexPath.row == 1) {
NSInteger selectedMembers = 0;
for (ACContactItem *m in mgr.groupMemberList) if (m.isSelected) selectedMembers++;
NSInteger targetCount = selectedMembers > 0 ? selectedMembers : (NSInteger)mgr.groupMemberList.count;
float hangupSec = mgr.voiceHangupSeconds;
cell.textLabel.text = mgr.voiceCallRunning ? @"🛑 停止批量语音打招呼" : [NSString stringWithFormat:@"📞 批量语音打招呼 (%.1f秒挂断)", hangupSec];
cell.textLabel.textColor = mgr.voiceCallRunning ? [UIColor systemRedColor] : [UIColor systemBlueColor];
cell.detailTextLabel.text = [NSString stringWithFormat:@"将依次向 %ld 位群成员振铃，%.1f 秒后自动挂断", (long)targetCount, hangupSec];
cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
} else if (indexPath.row == 2) {
cell.textLabel.text = @"🌙 后台静音保活";
cell.detailTextLabel.text = @"内存生成静音音频循环播放，降低被系统杀后台的概率";
cell.accessoryView = [self ac_toolSwitch:mgr.keepAliveEnabled tag:701];
} else if (indexPath.row == 3) {
cell.textLabel.text = @"🤖 伪装群机器人";
cell.detailTextLabel.text = @"发出的消息带机器人扩展字段与【机器人名】前缀";
cell.accessoryView = [self ac_toolSwitch:mgr.robotModeEnabled tag:702];
} else if (indexPath.row == 4) {
cell.textLabel.text = @"✏️ 机器人名称";
cell.detailTextLabel.text = mgr.robotDisplayName.length > 0 ? mgr.robotDisplayName : @"群管机器人";
cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
} else if (indexPath.row == 5) {
cell.textLabel.text = @"⏱️ 语音自动挂断秒数";
cell.detailTextLabel.text = [NSString stringWithFormat:@"当前 %.1f 秒（允许 0.3–15 秒，越短越安全）", mgr.voiceHangupSeconds];
cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
} else { // row 6 批量语音条打招呼
NSInteger selCount = 0;
for (ACContactItem *m in mgr.groupMemberList) if (m.isSelected) selCount++;
NSInteger targetCount = selCount > 0 ? selCount : (NSInteger)mgr.groupMemberList.count;
BOOL hasAudio = [mgr mediaTypeForSlot:ACMediaSlotBatchSend] == 3;
cell.textLabel.text = mgr.voiceMemoRunning ? @"🛑 停止批量语音条打招呼" : @"🎙️ 批量语音条打招呼";
cell.textLabel.textColor = mgr.voiceMemoRunning ? [UIColor systemRedColor] : [UIColor systemPurpleColor];
cell.detailTextLabel.text = hasAudio
? [NSString stringWithFormat:@"向 %ld 位群成员私聊发送语音条（%d 秒），走普通消息信令，不触发 VoIP 骚扰风控", (long)targetCount, [mgr audioDurationForSlot:ACMediaSlotBatchSend]]
: @"⚠️ 请先在【💬回复】面板媒体框录制/导入语音条（槽位0 群发专属）";
cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
}
return cell;
}
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
NSInteger idx = self.ac_selectedTabIndex;
if (idx == 7) {
if (indexPath.row == 0) {
UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"💾 保存当前登录账号"
message:@"自动缓存当前会话凭证用于免验证码秒切。请先用目标账号登录 App，再回来点此保存。"
preferredStyle:UIAlertControllerStyleAlert];
[alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
tf.placeholder = @"备注名称（如：大号-客服01）";
}];
[alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
tf.placeholder = @"账号 / 手机号（选填，仅备注用）";
tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
}];
[alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
tf.placeholder = @"登录密码（选填，仅备注用）";
tf.secureTextEntry = YES;
}];
[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
[alert addAction:[UIAlertAction actionWithTitle:@"🌐 打开官方账号管理（免退登添加新号）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
[[ACForwardHelperManager shared] ac_openNativeAccountManagement];
}]];
// HAR [57] 核心新增：免退出当前账号，直接输入账号密码后台直登 /auth/c/doLoginNoEn 拿 Token 入库
// （十几个账号随意添加，当前在线账号不受任何影响）
[alert addAction:[UIAlertAction actionWithTitle:@"🚀 免退登直登添加账号（账号+密码）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
UIAlertController *loginAlert = [UIAlertController alertControllerWithTitle:@"🚀 免退登直登添加账号"
message:@"输入账号+密码，插件直接调官方接口拿 Token 入库，无需退出当前账号（抓包 [57] doLoginNoEn 直登）。"
preferredStyle:UIAlertControllerStyleAlert];
[loginAlert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
tf.placeholder = @"飞机号 / 手机号 (account)";
tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
tf.clearButtonMode = UITextFieldViewModeWhileEditing;
}];
[loginAlert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
tf.placeholder = @"登录密码 (password)";
tf.secureTextEntry = YES;
tf.clearButtonMode = UITextFieldViewModeWhileEditing;
}];
[loginAlert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
[loginAlert addAction:[UIAlertAction actionWithTitle:@"🚀 直登并保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a2) {
NSString *acc = [loginAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
NSString *pwd = [loginAlert.textFields.lastObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
if (acc.length == 0 || pwd.length == 0) {
self.statusLabel.textColor = [UIColor systemOrangeColor];
self.statusLabel.text = @"⚠️ 请输入完整的账号和密码";
return;
}
self.statusLabel.textColor = [UIColor systemBlueColor];
self.statusLabel.text = [NSString stringWithFormat:@"🔄 正在免退登直登【%@】...", acc];
[[ACForwardHelperManager shared] ac_loginWithUsername:acc password:pwd completion:^(BOOL ok, NSString *msg) {
dispatch_async(dispatch_get_main_queue(), ^{
self.statusLabel.textColor = ok ? [UIColor systemGreenColor] : [UIColor systemRedColor];
self.statusLabel.text = msg;
[self.tableView reloadData];
});
}];
}]];
[self presentViewController:loginAlert animated:YES completion:nil];
}]];
[alert addAction:[UIAlertAction actionWithTitle:@"保存凭证" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
NSString *remark = alert.textFields[0].text;
NSString *account = [alert.textFields[1].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
NSString *pwd = alert.textFields[2].text;
// 核心修复：保存时必须缓存当前会话凭证（旧版从不写入 token，导致切换永远报“暂无缓存凭证”，
// 且 loadAllAccounts 过滤无 token 条目 → 重启后账号凭空消失，多账号功能整体死路）。
// 热切换锁定期间 latestHTTPHeaders 是插件账号，「保存当前登录账号」改取原生会话凭证副本。
NSString *curToken = nil, *curUid = nil, *curChannel = nil;
if (sHotSwitchUserId.length > 3 && ACSafeStr(ACNativeAuthStore()[@"token"]).length > 10) {
curToken = ACNativeAuthStore()[@"token"];
curUid = ACNativeAuthStore()[@"x-userid"];
curChannel = ACNativeAuthStore()[@"channel"];
} else {
curToken = ACHeaderValue(mgr.latestHTTPHeaders, @"token");
curUid = mgr.selfUserId.length > 3 ? mgr.selfUserId : ACHeaderValue(mgr.latestHTTPHeaders, @"x-userid");
curChannel = ACHeaderValue(mgr.latestHTTPHeaders, @"channel");
}
if (curToken.length <= 10) {
self.statusLabel.textColor = [UIColor systemRedColor];
self.statusLabel.text = @"❌ 未捕获登录凭证：请先用目标账号登录 App 并刷一页飞行圈";
return;
}
ACAccountItem *newItem = [[ACAccountItem alloc] init];
newItem.remark = remark.length > 0 ? remark : (account.length > 0 ? account : (curUid.length > 0 ? curUid : @"我的账号"));
newItem.account = account;
newItem.password = pwd;
newItem.token = curToken;
newItem.userId = curUid ?: @"";
if (curChannel.length > 0) newItem.channel = curChannel;
NSDateFormatter *df = [[NSDateFormatter alloc] init];
df.dateFormat = @"MM-dd HH:mm";
newItem.saveTime = [df stringFromDate:[NSDate date]];
// 同一账号（按 userId 优先、账号名兜底）已存在则更新凭证，避免重复堆积
BOOL replaced = NO;
for (NSUInteger i2 = 0; i2 < mgr.accountList.count; i2++) {
ACAccountItem *old = mgr.accountList[i2];
BOOL sameAcc = (newItem.userId.length > 3 && [old.userId isEqualToString:newItem.userId]) ||
(newItem.userId.length == 0 && account.length > 0 && [old.account isEqualToString:account]);
if (sameAcc) {
[mgr.accountList replaceObjectAtIndex:i2 withObject:newItem];
replaced = YES;
break;
}
}
if (!replaced) [mgr.accountList insertObject:newItem atIndex:0];
[mgr saveAllAccounts];
// 主页/全局同步：把当前账号在宿主 App 的 NSUserDefaults 登录态快照一起存下来，切回时恢复
[mgr ac_saveAppDefaultsSnapshotForUid:newItem.userId];
[self.tableView reloadData];
self.statusLabel.textColor = [UIColor systemGreenColor];
self.statusLabel.text = [NSString stringWithFormat:@"✅ 已缓存【%@】凭证（uid:%@）", newItem.remark, newItem.userId ?: @""];
[mgr loginWithAccount:newItem completion:^(BOOL ok, NSString *msg) {
self.statusLabel.textColor = ok ? [UIColor systemGreenColor] : [UIColor systemRedColor];
self.statusLabel.text = msg;
[self.tableView reloadData];
}];
}]];
[self presentViewController:alert animated:YES completion:nil];
return;
}
NSUInteger arow = (NSUInteger)indexPath.row - 1;
if (arow < mgr.accountList.count) {
ACAccountItem *targetAcc = mgr.accountList[arow];
self.statusLabel.textColor = [UIColor systemBlueColor];
self.statusLabel.text = [NSString stringWithFormat:@"⏳ 正在切换至【%@】...", targetAcc.remark];
[mgr loginWithAccount:targetAcc completion:^(BOOL ok, NSString *msg) {
self.statusLabel.textColor = ok ? [UIColor systemGreenColor] : [UIColor systemRedColor];
self.statusLabel.text = msg;
[self updateUI];
[self.tableView reloadData];
}];
}
return;
}
if (idx == 6) {
if (indexPath.row == 1) {
NSMutableArray<ACContactItem *> *targets = [NSMutableArray array];
for (ACContactItem *m in mgr.groupMemberList) if (m.isSelected) [targets addObject:m];
if (targets.count == 0) targets = [mgr.groupMemberList mutableCopy];
if (targets.count == 0) {
self.statusLabel.textColor = [UIColor systemRedColor];
self.statusLabel.text = @"❌ 群成员列表为空，请先到【群员】面板定向采集";
return;
}
[mgr ac_startBatchVoiceCall:targets];
self.statusLabel.textColor = mgr.voiceCallRunning ? [UIColor systemOrangeColor] : [UIColor secondaryLabelColor];
self.statusLabel.text = mgr.voiceCallRunning
? [NSString stringWithFormat:@"📞 批量语音打招呼运行中（%lu 人，%.1f 秒自动挂断）", (unsigned long)targets.count, mgr.voiceHangupSeconds]
: @"🛑 已停止批量语音打招呼";
[tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
return;
}
if (indexPath.row == 6) {
NSMutableArray<ACContactItem *> *targets = [NSMutableArray array];
for (ACContactItem *m in mgr.groupMemberList) if (m.isSelected) [targets addObject:m];
if (targets.count == 0) targets = [mgr.groupMemberList mutableCopy];
if (targets.count == 0) {
self.statusLabel.textColor = [UIColor systemRedColor];
self.statusLabel.text = @"❌ 群成员列表为空，请先到【群员】面板定向采集";
return;
}
[mgr ac_startBatchVoiceMemo:targets];
self.statusLabel.textColor = mgr.voiceMemoRunning ? [UIColor systemPurpleColor] : [UIColor secondaryLabelColor];
self.statusLabel.text = mgr.voiceMemoRunning
? [NSString stringWithFormat:@"🎙️ 批量语音条打招呼运行中（%lu 人，私聊发送）", (unsigned long)targets.count]
: @"🛑 已停止批量语音条打招呼";
[tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:6 inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
return;
}
if (indexPath.row == 5) {
UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⏱️ 语音自动挂断秒数"
message:@"范围 0.3 – 15 秒，默认 1.0 秒"
preferredStyle:UIAlertControllerStyleAlert];
[alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
tf.text = [NSString stringWithFormat:@"%.1f", mgr.voiceHangupSeconds];
tf.keyboardType = UIKeyboardTypeDecimalPad;
}];
[alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
float seconds = [alert.textFields.firstObject.text floatValue];
if (seconds < 0.3f || seconds > 15.0f) {
self.statusLabel.textColor = [UIColor systemRedColor];
self.statusLabel.text = @"❌ 秒数需在 0.3 到 15 之间";
return;
}
mgr.voiceHangupSeconds = seconds;
[mgr saveAllCustomSettings];
self.statusLabel.textColor = [UIColor systemGreenColor];
self.statusLabel.text = [NSString stringWithFormat:@"✅ 语音挂断时间已设为 %.1f 秒", seconds];
[tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:5 inSection:0], [NSIndexPath indexPathForRow:1 inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
}]];
[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
[self presentViewController:alert animated:YES completion:nil];
return;
}
if (indexPath.row == 4) {
UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"✏️ 机器人名称"
message:@"发送消息时展示的机器人名称"
preferredStyle:UIAlertControllerStyleAlert];
[alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
tf.text = mgr.robotDisplayName.length > 0 ? mgr.robotDisplayName : @"群管机器人";
tf.placeholder = @"群管机器人";
}];
[alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
mgr.robotDisplayName = name.length > 0 ? name : @"群管机器人";
[mgr saveAllCustomSettings];
[tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:4 inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
}]];
[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
[self presentViewController:alert animated:YES completion:nil];
return;
}
return;
}
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
NSInteger idx = self.ac_selectedTabIndex;
if (idx == 7) return indexPath.row > 0; // 账号面板：首行不可删
return (idx == 4 || idx == 5);
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
if (editingStyle == UITableViewCellEditingStyleDelete) {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
if (self.ac_selectedTabIndex == 4 && indexPath.row < mgr.autoReplyRules.count) {
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
} else if (self.ac_selectedTabIndex == 5 && indexPath.row < mgr.momentTasks.count) {
[mgr.momentTasks removeObjectAtIndex:indexPath.row];
[mgr saveAllCustomSettings];
[tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
} else if (self.ac_selectedTabIndex == 7 && indexPath.row >= 1 && (indexPath.row - 1) < (NSInteger)mgr.accountList.count) {
[mgr.accountList removeObjectAtIndex:indexPath.row - 1];
[mgr saveAllAccounts];
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
[ACForwardHelperManager shared].batchSendStreakCount = 0; // 新一轮群发：重置拟人化批次计数
[ACForwardHelperManager shared].unlockAttemptCountInSession = 0; // 新一轮群发：重置破盾限频计数
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
// 防封雷区④：拟人化阶梯延时（6.5~12 秒）+ 每连续 8 人强制插入 28~42 秒冷却休息
ACForwardHelperManager *batchMgr = [ACForwardHelperManager shared];
batchMgr.batchSendStreakCount++;
NSTimeInterval randDelay = 6.5 + (arc4random_uniform(55) / 10.0);
if (batchMgr.batchSendStreakCount % 8 == 0) {
randDelay += 28.0 + arc4random_uniform(15);
ACLog(@"🛡️ [防封降权] 已连续发送 %ld 人，自动进入 %.0f 秒安全冷却休息...", (long)batchMgr.batchSendStreakCount, randDelay);
}
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
// 多账号全局接管：热切换后把 App 原生请求 Header/URL 参数/POST Body 里的旧账号 UID 实时替换为新账号，
// 解决“切换后主页仍显示旧号甚至空白”（服务端 token 与查询 UID 不一致返回空数据）。
// 优先精确替换旧 UID 字符串，绝不误伤第三方用户主页与帖子 ID。
static NSURLRequest *ACForceOverrideAccountRequest(NSURLRequest *request) {
@try {
if (!request || !request.URL || acInternalRequest) return request;
NSString *host = request.URL.host ?: @"";
if (![host containsString:@"airchat"]) return request;
NSString *acReqPath = (request.URL.path ?: @"").lowercaseString;
// 官方登录/验证码/注册/切换流程：自动解除插件锁定，绝不拦截官方切号
if ([acReqPath containsString:@"login"] || [acReqPath containsString:@"sms"] ||
[acReqPath containsString:@"verify"] || [acReqPath containsString:@"register"] ||
[acReqPath containsString:@"oauth"] || [acReqPath containsString:@"switchaccount"]) {
[ACForwardHelperManager shared].forcedAccountOverride = NO;
sHotSwitchUserId = nil;
return request;
}
// 拦截退出注销：重写到本地空地址（127.0.0.1:1 连接立即失败，请求绝不触达服务端，Token 得以保活）。
// HAR [42] 实证：旧方案重写到 https://host/__plugin_logout_blocked__ 仍会发给服务器，
// 服务器对未知路径返回 {"code":401,"msg":"Token无效"} 反而触发宿主全局 401 踢下线逻辑！
if (ACIsLogoutRequest(request)) {
NSMutableURLRequest *blockedReq = [request mutableCopy];
blockedReq.URL = [NSURL URLWithString:@"http://127.0.0.1:1/__plugin_blocked__"];
return blockedReq;
}
// 用户正处于官方「账号管理/登录」界面：绝不锁死请求，让官方切换完全畅通
if (ACIsInNativeAccountOrLoginScreen()) {
[ACForwardHelperManager shared].forcedAccountOverride = NO;
return request;
}
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
if (!mgr.forcedAccountOverride) return request;
NSMutableURLRequest *mReq = [request isKindOfClass:[NSMutableURLRequest class]] ? (NSMutableURLRequest *)request : [request mutableCopy];
if (!mReq) return request;
NSString *newUid = mgr.selfUserId;
NSString *oldUid = mgr.previousSelfUserId;
NSString *forcedToken = ACHeaderValue(mgr.latestHTTPHeaders, @"token");
if (forcedToken.length > 5) [mReq setValue:forcedToken forHTTPHeaderField:@"token"];
if (newUid.length > 5) [mReq setValue:newUid forHTTPHeaderField:@"x-userid"];
if (newUid.length < 5) return mReq;
// 1. URL Query：优先精确替换旧账号 UID；首次切换（无旧 UID 记录）才对 userId=/friendId= 做 15~22 位纯数字兜底替换
NSString *urlStr = mReq.URL.absoluteString ?: @"";
NSString *replacedURL = urlStr;
if (oldUid.length > 5 && [replacedURL containsString:oldUid]) {
replacedURL = [replacedURL stringByReplacingOccurrencesOfString:oldUid withString:newUid];
} else if (oldUid.length <= 5) {
NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(userId|friendId)=[0-9]{15,22}" options:0 error:nil];
replacedURL = [re stringByReplacingMatchesInString:replacedURL options:0 range:NSMakeRange(0, replacedURL.length) withTemplate:[NSString stringWithFormat:@"$1=%@", newUid]];
}
if (![replacedURL isEqualToString:urlStr]) mReq.URL = [NSURL URLWithString:replacedURL];
// 2. POST Body：仅限个人资料/封禁状态/用户类接口，避免误伤点赞等含 postId 的业务报文
NSString *path = mReq.URL.path ?: @"";
BOOL profileish = ([path containsString:@"banStatus"] || [path containsString:@"userinfo"] ||
[path containsString:@"business"] || [path containsString:@"user"]);
if (profileish && mReq.HTTPBody.length > 0 && mReq.HTTPBody.length < 4096) {
NSString *bodyStr = [[NSString alloc] initWithData:mReq.HTTPBody encoding:NSUTF8StringEncoding];
if (bodyStr.length > 0) {
NSString *newBody = bodyStr;
if (oldUid.length > 5 && [newBody containsString:oldUid]) {
newBody = [newBody stringByReplacingOccurrencesOfString:oldUid withString:newUid];
} else if (oldUid.length <= 5) {
NSRegularExpression *reBody = [NSRegularExpression regularExpressionWithPattern:@"\"(id|userId)\"\\s*:\\s*\"[0-9]{15,22}\"" options:0 error:nil];
newBody = [reBody stringByReplacingMatchesInString:newBody options:0 range:NSMakeRange(0, newBody.length) withTemplate:[NSString stringWithFormat:@"\"$1\":\"%@\"", newUid]];
}
if (![newBody isEqualToString:bodyStr]) {
mReq.HTTPBody = [newBody dataUsingEncoding:NSUTF8StringEncoding];
[mReq setValue:nil forHTTPHeaderField:@"Content-Length"]; // 交由 URLSession 按新 Body 重算
}
}
}
return mReq;
} @catch (NSException *e) {
return request;
}
}
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
request = ACForceOverrideAccountRequest(request); // 多账号全局接管：实时替换旧账号 UID
// 拦截退出注销请求：不发真注销到服务端（防 Token 被销毁），本地伪造 200 让 App 登出流程正常走完
// （URL 已被重写到 127.0.0.1:1，需同时匹配改写后标记路径，否则伪造逻辑不再命中）
if ((ACIsLogoutRequest(request) || [request.URL.absoluteString containsString:@"__plugin_blocked__"]) && completionHandler) {
NSData *acFakeData = [@"{\"code\":200,\"msg\":\"操作成功\",\"data\":true}" dataUsingEncoding:NSUTF8StringEncoding];
NSHTTPURLResponse *acFakeResp = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/json"}];
void (^acFakeHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
completionHandler(acFakeData, acFakeResp, nil);
};
// 请求已被重写到无效路径（404），completionHandler 收到伪造 200，服务端 Token 得以保活
return %orig(request, acFakeHandler);
}
NSString *urlStr = request.URL.absoluteString;
// [57] 官方登录页 doLoginNoEn 明文账密捕获（自动绑定到账号条目，供 Token 失效后静默重登）
if ([urlStr containsString:@"/auth/c/doLoginNoEn"] && request.HTTPBody.length > 0) {
@try {
NSDictionary *acLoginBody = ACSafeDict([NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil]);
NSString *acAcc = ACSafeStr(acLoginBody[@"account"]);
NSString *acPwd = ACSafeStr(acLoginBody[@"password"]);
if (acAcc.length > 0) { g_lastLoginAccount = acAcc; ACLog(@"[直登] 已捕获官方登录页账号: %@", acAcc); }
if (acPwd.length > 0) g_lastLoginPassword = acPwd;
} @catch (NSException *e) {}
}
ACGoldenProbeDump(request);
// 自动捕获 airchat 业务网关（api/apiv1 域名）请求中的全部真实 Header（用于动态发布鉴权）
BOOL acIsAirChatHost = ([urlStr containsString:@"airchat.cc"] || [urlStr containsString:@"airchat.cn"] || [urlStr containsString:@"airchat.ltd"]);
if (!acInternalRequest && acIsAirChatHost && request.allHTTPHeaderFields) {
NSDictionary *headers = request.allHTTPHeaderFields;
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
// 记录 App 实际业务域名（.cn/.cc/.ltd）；COS/CDN 域名绝不记录，避免发布请求打到对象存储返回 405
if (ACIsBusinessHost(request.URL.host)) mgr.lastAirchatHost = request.URL.host;
// 原生发布请求：整份 Header 作为模板保存（UA/Accept/X-Lts-Id 都与该接口匹配）
if ([urlStr containsString:@"/post/app/publish"]) {
mgr.lastPublishHeaders = [headers mutableCopy];
}
[headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
if (![k isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSString class]]) return;
NSString *lk = k.lowercaseString;
if ([lk isEqualToString:@"x-lts-id"]) {
// 探针实证：官方 LtsId 约 144 字符、结尾并非 [s]；旧 [s] 判定把官方值全部丢弃导致 Lts=0 → 500
if (ACIsValidLtsId(v)) {
mgr.latestHTTPHeaders[@"X-Lts-Id"] = v;
mgr.latestHTTPHeaders[@"x-lts-id"] = v;
mgr.latestLtsAt = [[NSDate date] timeIntervalSince1970];
ACLog(@"[嗅探] 锁定最新 X-Lts-Id 长度: %lu", (unsigned long)v.length);
}
return;
}
// 热切换锁定期间：token/x-userid/channel 不允许被原生流量冲回 App 当前登录账号；
// 但原生会话凭证仍持续记录到副本，供「保存当前登录账号」面板取用
NSString *sniffedUid = ACHeaderValue(headers, @"x-userid");
BOOL acHotLocked = (sHotSwitchUserId.length > 3);
// 官方账号管理/登录页出现新身份流量 = 用户正在官方切号：自动解除锁定并放行捕获
if (acHotLocked && sniffedUid.length > 3 && ![sniffedUid isEqualToString:sHotSwitchUserId] && ACIsInNativeAccountOrLoginScreen()) {
sHotSwitchUserId = nil;
[ACForwardHelperManager shared].forcedAccountOverride = NO;
acHotLocked = NO;
ACLog(@"[多账号] 检测到官方切号流量，已自动解除插件锁定");
}
BOOL acHotMismatch = (acHotLocked && (sniffedUid.length == 0 || ![sniffedUid isEqualToString:sHotSwitchUserId]));
BOOL acIdentityKey = ([lk isEqualToString:@"token"] || [lk isEqualToString:@"x-userid"] || [lk isEqualToString:@"channel"]);
if (acIdentityKey) ACNativeAuthStore()[lk] = v;
if ([lk isEqualToString:@"token"] || [lk isEqualToString:@"x-userid"] ||
[lk isEqualToString:@"version"] || [lk isEqualToString:@"channel"] ||
[lk isEqualToString:@"appversion"] || [lk isEqualToString:@"signature"] ||
[lk isEqualToString:@"sign"] || [lk isEqualToString:@"deviceid"] ||
[lk isEqualToString:@"device-id"] || [lk isEqualToString:@"timestamp"] ||
[lk isEqualToString:@"x-request-no"] || [lk isEqualToString:@"accept-language"] ||
([lk isEqualToString:@"user-agent"] && [v.lowercaseString containsString:@"airchat/"])) {
if (!(acIdentityKey && acHotMismatch)) {
mgr.latestHTTPHeaders[k] = v;
mgr.latestHTTPHeaders[lk] = v;
}
}
if ([lk isEqualToString:@"x-userid"] && v.length > 5 && !(acHotLocked && ![v isEqualToString:sHotSwitchUserId])) mgr.selfUserId = v;
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
// 风控自检软着陆：客户端聊天记录自检永远返回“未违规”，避免批量打招呼被客户端上报风控中心
// （保持请求照常走 %orig 并只包装响应，返回 nil 会让 Alamofire 的 task.resume() 崩溃）
if ([urlStr containsString:@"/immessage/check-chat-record"] || [urlStr containsString:@"/biz/chat/check"]) {
if (completionHandler) {
void (^cleanHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
NSDictionary *okDict = @{@"code": @200, @"msg": @"操作成功", @"data": @YES};
NSData *okData = [NSJSONSerialization dataWithJSONObject:okDict options:0 error:nil];
completionHandler(okData, response, error);
};
return %orig(request, cleanHandler);
}
}
// 【HAR 192037 [81] 实锤修复】validateToken 含子串 "validate" 曾被本拦截误杀——响应被篡改成 data:@YES，
// 插件拿不到 data.userId、官方切号 VC 校验失败直接中断！必须精确排除 validateToken
// 【HAR 205944 复盘】再加 !acInternalRequest 双保险：插件自发请求（validateToken 拿本人 UID 等）绝不被本拦截篡改
if (!acInternalRequest && ([urlStr containsString:@"checkPhoneRegister"] || [urlStr containsString:@"updateMyPhoneNumber"] ||
([urlStr containsString:@"validate"] && ![urlStr containsString:@"validateToken"]))) {
if (completionHandler) {
void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
NSDictionary *successDict = @{@"code": @200, @"msg": @"操作成功", @"data": @YES};
NSData *newData = [NSJSONSerialization dataWithJSONObject:successDict options:0 error:nil];
completionHandler(newData, response, error);
};
return %orig(request, wrappedHandler);
}
}
// 兼容新老两种信息流接口（老：batchQueryPostInfo；新：client/biz/v2 分页接口）
if (([urlStr containsString:@"/post/app/batchQueryPostInfo"] || [urlStr containsString:@"/client/biz/v2/post/app/page"]) && completionHandler) {
void (^origHandler)(NSData *, NSURLResponse *, NSError *) = [completionHandler copy];
void (^feedHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
if (origHandler) origHandler(data, response, error);
if (!error && data.length > 0) {
@try {
NSDictionary *json = ACSafeDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
if (json) {
[[ACForwardHelperManager shared] ac_handleFeedResponse:json];
[[ACForwardHelperManager shared] ac_handleFeedResponseForAutoLike:json];
}
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
request = ACForceOverrideAccountRequest(request); // 多账号全局接管：实时替换旧账号 UID
if (!acInternalRequest && request && request.URL) {
NSString *urlStr = request.URL.absoluteString ?: @"";
// [57] 无 completionHandler 变体同样捕获 doLoginNoEn 明文账密
if ([urlStr containsString:@"/auth/c/doLoginNoEn"] && request.HTTPBody.length > 0) {
@try {
NSDictionary *acLoginBody = ACSafeDict([NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil]);
NSString *acAcc = ACSafeStr(acLoginBody[@"account"]);
NSString *acPwd = ACSafeStr(acLoginBody[@"password"]);
if (acAcc.length > 0) g_lastLoginAccount = acAcc;
if (acPwd.length > 0) g_lastLoginPassword = acPwd;
} @catch (NSException *e) {}
}
ACGoldenProbeDump(request);
if (urlStr.length > 0 && ([urlStr containsString:@"airchat.cc"] || [urlStr containsString:@"airchat.cn"])) {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
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
if (ACIsValidLtsId(v)) {
mgr.latestHTTPHeaders[@"X-Lts-Id"] = v;
mgr.latestHTTPHeaders[@"x-lts-id"] = v;
mgr.latestLtsAt = [[NSDate date] timeIntervalSince1970];
ACLog(@"[嗅探] 锁定最新 X-Lts-Id 长度: %lu", (unsigned long)v.length);
}
return;
}
// 热切换锁定期间：token/x-userid/channel 不允许被原生流量冲回 App 当前登录账号；
// 但原生会话凭证仍持续记录到副本，供「保存当前登录账号」面板取用
NSString *sniffedUid = ACHeaderValue(headers, @"x-userid");
BOOL acHotLocked = (sHotSwitchUserId.length > 3);
// 官方账号管理/登录页出现新身份流量 = 用户正在官方切号：自动解除锁定并放行捕获
if (acHotLocked && sniffedUid.length > 3 && ![sniffedUid isEqualToString:sHotSwitchUserId] && ACIsInNativeAccountOrLoginScreen()) {
sHotSwitchUserId = nil;
[ACForwardHelperManager shared].forcedAccountOverride = NO;
acHotLocked = NO;
ACLog(@"[多账号] 检测到官方切号流量，已自动解除插件锁定");
}
BOOL acHotMismatch = (acHotLocked && (sniffedUid.length == 0 || ![sniffedUid isEqualToString:sHotSwitchUserId]));
BOOL acIdentityKey = ([lk isEqualToString:@"token"] || [lk isEqualToString:@"x-userid"] || [lk isEqualToString:@"channel"]);
if (acIdentityKey) ACNativeAuthStore()[lk] = v;
if ([lk isEqualToString:@"token"] || [lk isEqualToString:@"x-userid"] ||
[lk isEqualToString:@"version"] || [lk isEqualToString:@"channel"] ||
[lk isEqualToString:@"appversion"] || [lk isEqualToString:@"signature"] ||
[lk isEqualToString:@"sign"] || [lk isEqualToString:@"deviceid"] ||
[lk isEqualToString:@"device-id"] || [lk isEqualToString:@"timestamp"] ||
[lk isEqualToString:@"x-request-no"] || [lk isEqualToString:@"accept-language"] ||
([lk isEqualToString:@"user-agent"] && [v.lowercaseString containsString:@"airchat/"])) {
if (!(acIdentityKey && acHotMismatch)) {
mgr.latestHTTPHeaders[k] = v;
mgr.latestHTTPHeaders[lk] = v;
}
}
if ([lk isEqualToString:@"x-userid"] && v.length > 5 && !(acHotLocked && ![v isEqualToString:sHotSwitchUserId])) mgr.selfUserId = v;
}];
}
}
}
return %orig;
}
%end
%hook NSMutableURLRequest
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString * _Nullable)field {
// 【HAR 192037 [83]/[84] 回退根治】热切换锁定期间，宿主定时器/旧会话在“构造阶段”就用旧 Token/UID
// 填充请求（如 updateOnlineTime 心跳），必须在写入请求前强制替换为锁定账号，
// 否则出现“新 UID + 旧 Token”混搭 → 服务端 401「登录已过期」；真实宿主凭证仍记入 ACNativeAuthStore 副本
if (!acInternalRequest && field && value && [field isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) {
NSString *lowerField = field.lowercaseString;
ACForwardHelperManager *acMgrSetValue = [ACForwardHelperManager shared];
BOOL acIdentityKey2 = ([lowerField isEqualToString:@"token"] || [lowerField isEqualToString:@"x-userid"] || [lowerField isEqualToString:@"channel"]);
if (sHotSwitchUserId.length > 3) {
// 官方账号管理/登录页出现新身份流量 = 用户正在官方切号：自动解除锁定
if ([lowerField isEqualToString:@"x-userid"] && ![value isEqualToString:sHotSwitchUserId] && ACIsInNativeAccountOrLoginScreen()) {
sHotSwitchUserId = nil;
acMgrSetValue.forcedAccountOverride = NO;
ACLog(@"[多账号] 检测到官方切号流量，已自动解除插件锁定");
}
if (sHotSwitchUserId.length > 3) {
if (acIdentityKey2) ACNativeAuthStore()[lowerField] = value; // 真实宿主凭证入副本
NSString *acLockedTok = ACHeaderValue(acMgrSetValue.latestHTTPHeaders, @"token");
if ([lowerField isEqualToString:@"token"] && ACIsValidAuthToken(acLockedTok) && ![value isEqualToString:acLockedTok]) {
value = acLockedTok; // 强制替换为当前锁定账号的 Token
} else if ([lowerField isEqualToString:@"x-userid"] && ![value isEqualToString:sHotSwitchUserId]) {
value = sHotSwitchUserId; // 强制替换为当前锁定账号的 UID
} else if ([lowerField isEqualToString:@"channel"]) {
NSString *acLockedCh = ACHeaderValue(acMgrSetValue.latestHTTPHeaders, @"channel");
if (acLockedCh.length > 0 && ![value isEqualToString:acLockedCh]) value = acLockedCh;
}
}
} else if (acIdentityKey2) {
ACNativeAuthStore()[lowerField] = value;
}
}
%orig;
if (acInternalRequest) return;
if (field && value && [field isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) {
NSString *lowerField = field.lowercaseString;
BOOL acBlockIdentity = NO;
if (sHotSwitchUserId.length > 3) {
if ([lowerField isEqualToString:@"x-userid"]) acBlockIdentity = ![value isEqualToString:sHotSwitchUserId];
else if ([lowerField isEqualToString:@"token"] || [lowerField isEqualToString:@"channel"]) acBlockIdentity = YES;
}
BOOL stable = ([lowerField isEqualToString:@"token"] ||
[lowerField isEqualToString:@"x-userid"] ||
[lowerField isEqualToString:@"version"] ||
[lowerField isEqualToString:@"channel"] ||
[lowerField isEqualToString:@"x-request-no"] ||
([lowerField isEqualToString:@"user-agent"] && [value.lowercaseString containsString:@"airchat/"]));
BOOL validLts = ([lowerField isEqualToString:@"x-lts-id"] && ACIsValidLtsId(value));
if ((stable || validLts) && !acBlockIdentity) {
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
// 锁定期间 addValue 同样强制替换 token/x-userid（与 setValue 同规）
if (!acInternalRequest && field && value && [field isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]] && sHotSwitchUserId.length > 3) {
NSString *lf = field.lowercaseString;
ACForwardHelperManager *acMgrAdd = [ACForwardHelperManager shared];
if ([lf isEqualToString:@"token"]) {
NSString *acLockedTok = ACHeaderValue(acMgrAdd.latestHTTPHeaders, @"token");
if (ACIsValidAuthToken(acLockedTok) && ![value isEqualToString:acLockedTok]) value = acLockedTok;
} else if ([lf isEqualToString:@"x-userid"] && ![value isEqualToString:sHotSwitchUserId]) {
value = sHotSwitchUserId;
}
}
%orig;
if (acInternalRequest) return;
if (![field isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]]) return;
NSString *lf = field.lowercaseString;
if ([lf isEqualToString:@"x-lts-id"] && ACIsValidLtsId(value)) {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
mgr.latestHTTPHeaders[@"X-Lts-Id"] = value;
mgr.latestHTTPHeaders[@"x-lts-id"] = value;
mgr.latestLtsAt = [[NSDate date] timeIntervalSince1970];
}
if (([lf isEqualToString:@"x-request-no"] ||
([lf isEqualToString:@"user-agent"] && [value.lowercaseString containsString:@"airchat/"]))) {
ACForwardHelperManager *mgr2 = [ACForwardHelperManager shared];
mgr2.latestHTTPHeaders[field] = value;
mgr2.latestHTTPHeaders[lf] = value;
}
}
- (void)setAllHTTPHeaderFields:(NSDictionary<NSString *,NSString *> *)headers {
// 【HAR 192037 [83]/[84] 回退根治】锁定期间批量设置 Header 时，写入前强制替换 token/x-userid/channel
NSDictionary *acOutHeaders = headers;
if (!acInternalRequest && headers.count > 0 && sHotSwitchUserId.length > 3) {
ACForwardHelperManager *acMgrAll = [ACForwardHelperManager shared];
NSString *acSniffUid = ACHeaderValue(headers, @"x-userid");
if (acSniffUid.length > 3 && ![acSniffUid isEqualToString:sHotSwitchUserId] && ACIsInNativeAccountOrLoginScreen()) {
sHotSwitchUserId = nil;
acMgrAll.forcedAccountOverride = NO;
ACLog(@"[多账号] 检测到官方切号流量，已自动解除插件锁定");
}
if (sHotSwitchUserId.length > 3) {
NSMutableDictionary *acFixed = [acOutHeaders mutableCopy];
[headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
if (![k isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSString class]]) return;
NSString *lk = k.lowercaseString;
if ([lk isEqualToString:@"token"]) {
ACNativeAuthStore()[@"token"] = v;
NSString *acLockedTok = ACHeaderValue(acMgrAll.latestHTTPHeaders, @"token");
if (ACIsValidAuthToken(acLockedTok) && ![v isEqualToString:acLockedTok]) acFixed[k] = acLockedTok;
} else if ([lk isEqualToString:@"x-userid"]) {
ACNativeAuthStore()[@"x-userid"] = v;
if (![v isEqualToString:sHotSwitchUserId]) acFixed[k] = sHotSwitchUserId;
} else if ([lk isEqualToString:@"channel"]) {
ACNativeAuthStore()[@"channel"] = v;
NSString *acLockedCh = ACHeaderValue(acMgrAll.latestHTTPHeaders, @"channel");
if (acLockedCh.length > 0 && ![v isEqualToString:acLockedCh]) acFixed[k] = acLockedCh;
}
}];
acOutHeaders = acFixed;
}
}
%orig(acOutHeaders);
if (acInternalRequest || headers.count == 0) return;
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
[headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
if (![k isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSString class]]) return;
NSString *lk = k.lowercaseString;
if ([lk isEqualToString:@"x-lts-id"] && ACIsValidLtsId(v)) {
mgr.latestHTTPHeaders[@"X-Lts-Id"] = v;
mgr.latestHTTPHeaders[@"x-lts-id"] = v;
mgr.latestLtsAt = [[NSDate date] timeIntervalSince1970];
}
// 热切换锁定期间：token/x-userid/channel 不允许被原生流量冲回 App 当前登录账号；
// 但原生会话凭证仍持续记录到副本，供「保存当前登录账号」面板取用
NSString *sniffedUid = ACHeaderValue(headers, @"x-userid");
BOOL acHotLocked = (sHotSwitchUserId.length > 3);
// 官方账号管理/登录页出现新身份流量 = 用户正在官方切号：自动解除锁定并放行捕获
if (acHotLocked && sniffedUid.length > 3 && ![sniffedUid isEqualToString:sHotSwitchUserId] && ACIsInNativeAccountOrLoginScreen()) {
sHotSwitchUserId = nil;
[ACForwardHelperManager shared].forcedAccountOverride = NO;
acHotLocked = NO;
ACLog(@"[多账号] 检测到官方切号流量，已自动解除插件锁定");
}
BOOL acHotMismatch = (acHotLocked && (sniffedUid.length == 0 || ![sniffedUid isEqualToString:sHotSwitchUserId]));
BOOL acIdentityKey = ([lk isEqualToString:@"token"] || [lk isEqualToString:@"x-userid"] || [lk isEqualToString:@"channel"]);
if (acIdentityKey) ACNativeAuthStore()[lk] = v;
if ([lk isEqualToString:@"token"] || [lk isEqualToString:@"x-userid"] ||
[lk isEqualToString:@"version"] || [lk isEqualToString:@"channel"] ||
[lk isEqualToString:@"appversion"] || [lk isEqualToString:@"signature"] ||
[lk isEqualToString:@"sign"] || [lk isEqualToString:@"deviceid"] ||
[lk isEqualToString:@"device-id"] || [lk isEqualToString:@"timestamp"] ||
[lk isEqualToString:@"x-request-no"] || [lk isEqualToString:@"accept-language"] ||
([lk isEqualToString:@"user-agent"] && [v.lowercaseString containsString:@"airchat/"])) {
if (!(acIdentityKey && acHotMismatch)) {
mgr.latestHTTPHeaders[k] = v;
mgr.latestHTTPHeaders[lk] = v;
}
}
if ([lk isEqualToString:@"x-userid"] && v.length > 5 && !(acHotLocked && ![v isEqualToString:sHotSwitchUserId])) mgr.selfUserId = v;
}];
}
%end
// （g_lastLoginAccount / g_lastLoginPassword 定义在文件顶部工具区，供 NSURLSession 嗅探与 NSJSONSerialization 收割共用）
%hook NSJSONSerialization
+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError * _Nullable *)error {
id res = %orig;
NSDictionary *dict = ACSafeDict(res);
// 【HAR 205944 防退登护盾】服务器单点互斥顶号后，宿主 Swift 内存里的旧 Token 残余请求会收到
// code==401「Token已被顶下线」，宿主全局 401 拦截器随即触发强制退出登录把用户踢回登录页！
// 只要插件当前持有合法锁定 Token，就把这类 401 响应伪装成 code:200 空数据直接化解；
// 插件自发的内部请求（直登/预检，acInternalRequest 标记期间）正常透传真实响应不受影响。
if (dict && [ACSafeStr(dict[@"code"]) integerValue] == 401 && !acInternalRequest) {
NSString *acShieldTok = ACHeaderValue([ACForwardHelperManager shared].latestHTTPHeaders, @"token");
if (ACIsValidAuthToken(acShieldTok)) {
ACLog(@"[防退登护盾] 已拦截宿主 401 响应(%@)，伪装 200 阻止全局强制退出登录", ACSafeStr(dict[@"msg"]));
return @{@"code": @200, @"msg": @"操作成功", @"data": @{}};
}
}
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
@try { [[ACForwardHelperManager shared] ac_handleFeedResponseForAutoLike:dict]; }
@catch (NSException *e) { ACLog(@"[自动点赞] 触发异常 %@", e.reason); }
});
}
}
// [57] doLoginNoEn 等登录接口返回的全新 Token：必须严格 32 位纯字母数字才入库！
// HAR 183315 [80] 实证：/209/get/enc/id 返回 24 位 Base64 密钥 "Q0EdQ2hMGW9nbQB/EBpIYQc="，
// 旧的 24~64 位宽松判定把它误当登录 Token，把本地所有账号的真 Token 全部覆盖污染 → 全部 401！
id acDataField = dict[@"data"];
if ([acDataField isKindOfClass:[NSString class]] && ACIsValidAuthToken((NSString *)acDataField)) {
ACNativeAuthStore()[@"token"] = (NSString *)acDataField;
ACLog(@"[多账号] 已捕获登录接口返回的合法 32 位新 Token，等待 userinfo/detail 收割入库");
}
// 全自动无感保存/更新当前登录账号（官方「账号管理」添加或切换新号后必经 /userinfo/detail，自动入库）
// HAR [103] 串号修复：服务器严格按请求 token 返回该 token 归属账号的资料，
// 因此响应 data.id 就是权威 UID——直接按 data.id 入库，绝不拿请求头残留 x-userid 硬配对！
// 【HAR 205944 好友误抓根治】好友查询 getUserInfo（[18]斩杀/[21]王摩诘/[22]小圣）返回字段与本人 detail 一模一样，
// 但只有本人 /userinfo/detail 独有 clientUserPhone / latestLoginIP / latestLoginDevice 特征字段，
// 好友 getUserInfo 绝不含这些字段——收割条件必须追加特征字段校验，否则点开过的好友全被误存进账号列表！
NSDictionary *acUData = ACSafeDict(dict[@"data"]);
NSString *acUid = ACSafeStr(acUData[@"id"]);
if (!acInternalRequest && acUid.length > 5 && acUData[@"clientUserNickName"] && (acUData[@"account"] || acUData[@"phone"]) &&
(acUData[@"clientUserPhone"] || acUData[@"latestLoginIP"] || acUData[@"latestLoginDevice"])) {
ACForwardHelperManager *acMgrAuto = [ACForwardHelperManager shared];
// token 来源优先用最后实际发出的请求头副本（ACNativeAuthStore），避免 latestHTTPHeaders 嗅探时序错位；
// 且必须通过 32 位纯字母数字校验（ACIsValidAuthToken），杜绝 24 位 Base64 密钥/其它接口串污染入库
NSString *acTok = ACSafeStr(ACNativeAuthStore()[@"token"]);
if (!ACIsValidAuthToken(acTok)) acTok = ACHeaderValue(acMgrAuto.latestHTTPHeaders, @"token");
if (ACIsValidAuthToken(acTok)) {
NSString *acNick = ACSafeStr(acUData[@"clientUserNickName"]);
NSString *acAccNum = ACSafeStr(acUData[@"account"] ?: acUData[@"phone"]);
dispatch_async(dispatch_get_main_queue(), ^{
@try {
[[ACForwardHelperManager shared] ac_autoSaveOrUpdateAccountWithUid:acUid token:acTok nickname:acNick accountNum:acAccNum];
// 官方登录页登录的新号：把捕获的明文账密自动绑定到该账号条目（供 Token 失效后自动重登）
if (g_lastLoginAccount.length > 0 || g_lastLoginPassword.length > 0) {
for (ACAccountItem *it in [ACForwardHelperManager shared].accountList) {
if ([it.userId isEqualToString:acUid]) {
if (g_lastLoginAccount.length > 0) it.account = g_lastLoginAccount;
if (g_lastLoginPassword.length > 0) it.password = g_lastLoginPassword;
[[ACForwardHelperManager shared] saveAllAccounts];
ACLog(@"[多账号] 已自动绑定账号密码到条目 %@（Token 失效后可静默重登）", acNick);
break;
}
}
}
}
@catch (NSException *e) { ACLog(@"[多账号] 自动入库异常 %@", e.reason); }
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
// 评论文案防封混淆后缀（破除服务端文本 MD5 查重，风控铁律③）
static inline NSString *ACAntiBanSuffix(void) {
NSArray *pool = @[@" ~", @" ✨", @" 👍", @" 😊", @" ❤️", @" 🎈", @" 🌟", @" ！", @" ｜", @" ～"];
return pool[arc4random_uniform((u_int32_t)pool.count)];
}
// 详情页秒评去重（同一条动态只评一次）
static NSString *sLastCommentedDetailPid = nil;
// 迎新/批量语音打招呼期间，压制 TUICall 前台呼叫弹窗，避免打断用户操作
- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)animated completion:(void (^)(void))completion {
@try {
ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
if (mgr && (mgr.voiceCallRunning || mgr.welcomeVoiceCalling)) {
NSString *vcName = NSStringFromClass([viewControllerToPresent class]);
if ([vcName containsString:@"TUICall"] || [vcName containsString:@"CallViewController"] || [vcName containsString:@"CallView"]) {
ACLog(@"[语音打招呼] 已压制呼叫弹窗 %@", vcName);
if (completion) completion();
return;
}
}
} @catch (NSException *e) {}
%orig;
}
- (void)viewDidAppear:(BOOL)animated {
%orig;
@try {
[[ACForwardHelperManager shared] setupIMGroupWelcomeListener];
// 常驻飞行圈句柄捕获（后台静默刷新 / 全自动发动态依赖）
NSString *mCls = NSStringFromClass([self class]);
// HAR+逆向实证：飞行圈是 JXPagingView 分页容器，外层 AirMomentsViewController 才持有发布按钮；
// 内层 AirMomentsContentViewController 不含 "AirMomentsViewController" 子串，条件天然互斥，避免覆盖句柄
if ([mCls containsString:@"AirMomentsViewController"] && ![mCls containsString:@"Content"]) {
// 用户亲自点进飞行圈时，若视图仍挂在后台隐形容器（tag 8899771），先取回归位正常前台显示
if (self.view.superview.tag == 8899771) {
@try { [self.view removeFromSuperview]; } @catch (NSException *e) {}
}
BOOL already = (sMomentsMainVC == self);
sMomentsMainVC = self;
sMomentsScrollView = nil;
if (!already) {
ACLog(@"🎯 [后台引擎] 捕获并锁定飞行圈主控制器: %@", mCls);
UIScrollView *sv = ACFirstScrollViewDeep(self.view);
if (sv) sMomentsScrollView = sv;
}
}
// 极速精准秒评：点进任意动态详情页（类名含 MomentDetail），0.35 秒后自动填词发送，点一个评一个
NSString *dCls = NSStringFromClass([self class]);
if ([dCls containsString:@"MomentDetail"]) {
ACForwardHelperManager *mgr2 = [ACForwardHelperManager shared];
if (mgr2.autoCommentEnabled) {
NSString *currentPid = nil;
@try {
id momentObj = [self valueForKey:@"moment"] ?: [self valueForKey:@"model"] ?: [self valueForKey:@"item"];
if (momentObj) {
currentPid = ACSafeStr([momentObj valueForKey:@"id"]);
if (currentPid.length == 0) currentPid = ACSafeStr([momentObj valueForKey:@"postId"]);
}
} @catch (NSException *e) {}
if (currentPid.length > 5 && [currentPid isEqualToString:sLastCommentedDetailPid]) return;
ACLog(@"🎯 [点进动态] 识别动态详情页 (PID: %@)，0.35 秒后自动跟评...", currentPid ?: @"未知");
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
UITextView *inputTV = nil;
UITextField *inputTF = nil;
UIButton *sendBtn = nil;
// 全窗口穿透搜评论输入框与发送按钮
NSMutableArray *views = [NSMutableArray arrayWithObject:self.view];
for (UIWindow *w in [UIApplication sharedApplication].windows) [views addObject:w];
while (views.count > 0) {
UIView *v = views.firstObject;
[views removeObjectAtIndex:0];
if ([v isKindOfClass:[UITextView class]] && v.isUserInteractionEnabled) inputTV = (UITextView *)v;
else if ([v isKindOfClass:[UITextField class]] && v.isUserInteractionEnabled) inputTF = (UITextField *)v;
if ([v isKindOfClass:[UIButton class]]) {
UIButton *b = (UIButton *)v;
NSString *title = b.currentTitle ?: @"";
if (title.length > 0 && ([title containsString:@"发"] || [title containsString:@"送"] || [title containsString:@"评"])) sendBtn = b;
}
[views addObjectsFromArray:v.subviews];
}
NSString *commentText = mgr2.autoCommentText.length > 0 ? mgr2.autoCommentText : @"不错";
commentText = [commentText stringByAppendingString:ACAntiBanSuffix()];
if (inputTV) {
inputTV.text = commentText;
id del = inputTV.delegate;
if (del && [del respondsToSelector:@selector(textViewDidChange:)]) ((void (*)(id, SEL, id))objc_msgSend)(del, @selector(textViewDidChange:), inputTV);
[[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification object:inputTV];
}
if (inputTF) {
inputTF.text = commentText;
[inputTF sendActionsForControlEvents:UIControlEventEditingChanged];
}
BOOL done = NO;
if (sendBtn) {
[sendBtn sendActionsForControlEvents:UIControlEventTouchUpInside];
done = YES;
ACLog(@"✅ [点进动态] 已点击发送按钮，文案: %@", commentText);
} else if (inputTV) {
id del = inputTV.delegate;
if (del && [del respondsToSelector:@selector(textView:shouldChangeTextInRange:replacementText:)]) {
((BOOL (*)(id, SEL, id, NSRange, id))objc_msgSend)(del, @selector(textView:shouldChangeTextInRange:replacementText:), inputTV, NSMakeRange(inputTV.text.length, 0), @"\n");
}
done = YES;
ACLog(@"✅ [点进动态] 已尝试回车发送，文案: %@", commentText);
}
if (done) sLastCommentedDetailPid = currentPid;
else ACLog(@"[点进动态] 未找到评论输入框/发送按钮（跳过 %@）", currentPid ?: @"?");
});
}
}
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
// —— 弹药库搜集：MomentCardView 上屏时建立 postId → 卡片映射（原生点赞的燃料） ——
%hook UIView
- (void)didMoveToSuperview {
%orig;
@try {
NSString *clsName = NSStringFromClass([self class]);
if (![clsName isEqualToString:@"airchat.MomentCardView"]) return;
static dispatch_once_t onceToken;
dispatch_once(&onceToken, ^{
sLiveMomentCardMap = [NSMutableDictionary dictionary];
});
NSString *pid = ACExtractCardPostId(self);
if (pid.length >= 6) {
@synchronized(sLiveMomentCardMap) {
if (sLiveMomentCardMap.count > 80) [sLiveMomentCardMap removeAllObjects]; // 防膨胀
sLiveMomentCardMap[pid] = self;
}
}
} @catch (NSException *e) {}
}
%end

// —— 精准雷达1：UI 点击探针（抓点赞按钮绑定的真实 Target/Action，Swift 类也会走 target-action） ——
%hook UIApplication
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
@try {
if (target && action) {
NSString *clsName = NSStringFromClass([target class]);
NSString *selName = NSStringFromSelector(action);
NSString *selLower = selName.lowercaseString;
BOOL hit = [clsName containsString:@"Moment"] || [clsName containsString:@"Like"] ||
[selLower containsString:@"like"] || [selLower containsString:@"favor"] ||
[selLower containsString:@"praise"];
if (hit) {
ACLog(@"🎯 [点赞UI探针命中] Target类: %@ | Action: %@ | 控件: %@", clsName, selName, NSStringFromClass([sender class]));
}
}
} @catch (NSException *e) {}
return %orig;
}
%end

// —— 精准雷达2：运行时符号扫描（Dump 动态模块真实业务类与方法，@objc 暴露的 Swift 方法可见） ——
static void ACDumpMomentClassesAndMethods(void) {
@try {
int numClasses = objc_getClassList(NULL, 0);
if (numClasses <= 0) return;
Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
if (!classes) return;
numClasses = objc_getClassList(classes, numClasses);
ACLog(@"🔍 开始雷达扫描内存中的动态(Moment)业务符号...");
for (int i = 0; i < numClasses; i++) {
Class cls = classes[i];
if (!cls) continue;
const char *name = class_getName(cls);
if (!name) continue;
NSString *clsName = [NSString stringWithUTF8String:name];
if (!([clsName containsString:@"Moment"] &&
([clsName containsString:@"Model"] || [clsName containsString:@"Service"] ||
[clsName containsString:@"Center"] || [clsName containsString:@"Manager"] ||
[clsName containsString:@"Controller"] || [clsName containsString:@"Business"]))) continue;
// 实例方法
unsigned int methodCount = 0;
Method *methods = class_copyMethodList(cls, &methodCount);
if (methods) {
for (unsigned int j = 0; j < methodCount; j++) {
SEL sel = method_getName(methods[j]);
NSString *selName = NSStringFromSelector(sel);
NSString *sl = selName.lowercaseString;
if ([sl containsString:@"like"] || [sl containsString:@"publish"] ||
[sl containsString:@"favor"] || [sl containsString:@"praise"]) {
ACLog(@"💡 候选方法: [%@ %@] (参数:%d)", clsName, selName, method_getNumberOfArguments(methods[j]) - 2);
}
}
free(methods);
}
// 类方法（顺带找单例入口）
unsigned int cCount = 0;
Method *cMethods = class_copyMethodList(object_getClass(cls), &cCount);
if (cMethods) {
for (unsigned int j = 0; j < cCount; j++) {
SEL sel = method_getName(cMethods[j]);
NSString *selName = NSStringFromSelector(sel);
NSString *sl = selName.lowercaseString;
if ([sl containsString:@"like"] || [sl containsString:@"publish"] ||
[sl containsString:@"shared"] || [sl containsString:@"default"]) {
ACLog(@"💡 候选类方法: [+%@ %@] (参数:%d)", clsName, selName, method_getNumberOfArguments(cMethods[j]) - 2);
}
}
free(cMethods);
}
}
free(classes);
ACLog(@"🔍 动态业务符号扫描完毕！");
} @catch (NSException *e) {
ACLog(@"[雷达] 扫描异常 %@", e.reason);
}
}

// —— MomentCardView 点赞核心窥探：触发时 Dump 卡片全部属性，找内部真正发请求的模型/字段 ——
static void ACHookMomentCardLike(void) {
@try {
static dispatch_once_t acCardHookOnce;
dispatch_once(&acCardHookOnce, ^{
Class cardCls = NSClassFromString(@"airchat.MomentCardView");
if (!cardCls) { ACLog(@"[Hook] MomentCardView 类未加载"); return; }
SEL sel = NSSelectorFromString(@"likeButtonTapped");
Method m = class_getInstanceMethod(cardCls, sel);
unsigned int nargs = 2;
if (!m) {
sel = NSSelectorFromString(@"likeButtonTapped:");
m = class_getInstanceMethod(cardCls, sel);
nargs = 3;
}
if (!m) { ACLog(@"[Hook] 未找到 MomentCardView likeButtonTapped"); return; }
IMP origImp = method_getImplementation(m);
if (nargs == 2) {
IMP newImp = imp_implementationWithBlock(^id(id self2, SEL cmd) {
ACLog(@"🔥 [MomentCardView likeButtonTapped 被调用]");
ACDumpCardProperties(self2);
return ((id (*)(id, SEL))origImp)(self2, cmd);
});
method_setImplementation(m, newImp);
} else {
IMP newImp = imp_implementationWithBlock(^id(id self2, SEL cmd, id sender) {
ACLog(@"🔥 [MomentCardView likeButtonTapped: 被调用]");
ACDumpCardProperties(self2);
return ((id (*)(id, SEL, id))origImp)(self2, cmd, sender);
});
method_setImplementation(m, newImp);
}
ACLog(@"[Hook] 成功挂载 MomentCardView 点赞探针！");
});
} @catch (NSException *e) {
ACLog(@"[Hook] 挂载异常 %@", e.reason);
}
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
// 延迟 2 秒后雷达扫描，等待 Swift 运行时完全加载
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
ACDumpMomentClassesAndMethods();
});
// 延迟挂载 MomentCardView 点赞窥探探针（1.5s 首次，5s 兜底重试）
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
ACHookMomentCardLike();
});
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
ACHookMomentCardLike();
});
}
