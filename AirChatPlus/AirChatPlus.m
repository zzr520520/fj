// ============================================================
// AirChatPlus v2 - 飞行圈增强插件（通用版）
// 动态类查找 + 多方法尝试 + 启动弹窗 + 详细日志
// ============================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
// 辅助类：承载新方法的 ObjC 实现（供 runtime 查找）
// ============================================================
@interface AirChatPlusHook : NSObject
- (void)acp_setPostModel:(id)model;
- (void)acp_viewDidLoad;
- (void)acp_showVisitorList;
- (NSURLSessionDataTask *)acp_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
@end

@implementation AirChatPlusHook
- (void)acp_setPostModel:(id)model {}
- (void)acp_viewDidLoad {}
- (void)acp_showVisitorList {}
- (NSURLSessionDataTask *)acp_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler { return nil; }
@end

// ============================================================
// 工具：遍历所有类，查找匹配关键词的类
// ============================================================
static Class findClassContaining(NSString *keyword1, NSString *keyword2) {
    int numClasses = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    numClasses = objc_getClassList(classes, numClasses);
    Class result = Nil;
    for (int i = 0; i < numClasses; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if (keyword2) {
            if ([name containsString:keyword1] && [name containsString:keyword2]) {
                result = classes[i];
                break;
            }
        } else {
            if ([name containsString:keyword1]) {
                result = classes[i];
                break;
            }
        }
    }
    free(classes);
    return result;
}

static Class findClassContaining3(NSString *k1, NSString *k2, NSString *k3) {
    int numClasses = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    numClasses = objc_getClassList(classes, numClasses);
    Class result = Nil;
    for (int i = 0; i < numClasses; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if ([name containsString:k1] && [name containsString:k2] && [name containsString:k3]) {
            result = classes[i];
            break;
        }
    }
    free(classes);
    return result;
}

// ============================================================
// 1. 通用 Cell 数据绑定 Hook
// ============================================================
static void (*orig_setPostModel)(id, SEL, id);
static void new_setPostModel(id self, SEL _cmd, id model) {
    orig_setPostModel(self, _cmd, model);
    NSArray *possibleLabels = @[@"viewCountLabel", @"visitorCountLabel", @"exposureCountLabel"];
    for (NSString *key in possibleLabels) {
        @try {
            UILabel *label = [self valueForKey:key];
            if (label) {
                label.hidden = NO;
                NSNumber *count = [model valueForKey:key];
                if (count) {
                    label.text = [NSString stringWithFormat:@"%@", count];
                } else {
                    NSNumber *alt = [model valueForKey:@"visitorCount"] ?: [model valueForKey:@"viewCount"];
                    if (alt) label.text = [NSString stringWithFormat:@"%@", alt];
                    else label.text = @"?";
                }
                NSLog(@"AirChatPlus: Force-show label %@ = %@", key, label.text);
            }
        } @catch (NSException *e) {
            NSLog(@"AirChatPlus: Error reading %@: %@", key, e.reason);
        }
    }
}

// ============================================================
// 2. 详情页强制显示访客视图
// ============================================================
static void (*orig_viewDidLoad)(id, SEL);
static void new_viewDidLoad(id self, SEL _cmd) {
    orig_viewDidLoad(self, _cmd);
    @try {
        UIView *visitorsView = [self valueForKey:@"visitorsView"];
        if (visitorsView) {
            visitorsView.hidden = NO;
            visitorsView.userInteractionEnabled = YES;
            NSLog(@"AirChatPlus: Forced visitorsView visible");
        }
        id model = [self valueForKey:@"postModel"];
        NSNumber *visitorCount = [model valueForKey:@"visitorCount"];
        if (visitorCount) {
            UILabel *hintLabel = [self valueForKey:@"hintLabel"];
            if (hintLabel) {
                hintLabel.text = [NSString stringWithFormat:@"访客人数：%@（仅作者可查看详情）", visitorCount];
            }
        }
    } @catch (NSException *e) {
        NSLog(@"AirChatPlus: Error in viewDidLoad hook: %@", e.reason);
    }
}

// ============================================================
// 3. 拦截访客入口点击
// ============================================================
static void (*orig_showVisitorList)(id, SEL);
static void new_showVisitorList(id self, SEL _cmd) {
    @try {
        id model = [self valueForKey:@"postModel"];
        BOOL isMyPost = [[model valueForKey:@"isMyPost"] boolValue];
        if (!isMyPost) {
            NSNumber *count = [model valueForKey:@"visitorCount"] ?: [model valueForKey:@"viewCount"];
            NSString *msg = count
                ? [NSString stringWithFormat:@"本帖子共有 %@ 位访客（详情仅作者可见）", count]
                : @"访客详情仅作者可查看";
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示"
                                                                           message:msg
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleCancel handler:nil]];
            UIViewController *vc = (UIViewController *)self;
            [vc presentViewController:alert animated:YES completion:nil];
            NSLog(@"AirChatPlus: Blocked visitor list for non-author, count=%@", count);
            return;
        }
        orig_showVisitorList(self, _cmd);
    } @catch (NSException *e) {
        NSLog(@"AirChatPlus: Error in showVisitorList hook: %@", e.reason);
    }
}

// ============================================================
// 4. 突破排行榜：修改 pageSize
// ============================================================
typedef void (^DataTaskCompletion)(NSData *, NSURLResponse *, NSError *);

static NSURLSessionDataTask *(*orig_dataTaskWithRequestCompletion)(id, SEL, NSURLRequest *, DataTaskCompletion);
static NSURLSessionDataTask *new_dataTaskWithRequestCompletion(id self, SEL _cmd, NSURLRequest *request, DataTaskCompletion completion) {
    NSMutableURLRequest *mReq = [request mutableCopy];
    NSString *urlString = request.URL.absoluteString;
    BOOL isRank = [urlString rangeOfString:@"rank" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                  [urlString rangeOfString:@"leaderboard" options:NSCaseInsensitiveSearch].location != NSNotFound;
    if (isRank && [request.HTTPMethod isEqualToString:@"GET"]) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
        NSMutableArray *queryItems = [components.queryItems mutableCopy] ?: [NSMutableArray array];
        NSMutableArray *newItems = [NSMutableArray array];
        BOOL replaced = NO;
        for (NSURLQueryItem *item in queryItems) {
            if ([item.name isEqualToString:@"pageSize"]) {
                [newItems addObject:[NSURLQueryItem queryItemWithName:@"pageSize" value:@"500"]];
                replaced = YES;
            } else {
                [newItems addObject:item];
            }
        }
        if (!replaced) {
            [newItems addObject:[NSURLQueryItem queryItemWithName:@"pageSize" value:@"500"]];
        }
        components.queryItems = newItems;
        mReq.URL = components.URL;
        NSLog(@"AirChatPlus: Modified rank URL -> %@", mReq.URL);
    } else if (isRank && [request.HTTPMethod isEqualToString:@"POST"] && request.HTTPBody) {
        NSError *err = nil;
        NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:NSJSONReadingMutableContainers error:&err];
        if (json && !err) {
            json[@"pageSize"] = @(500);
            NSData *newBody = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
            if (newBody) mReq.HTTPBody = newBody;
            NSLog(@"AirChatPlus: Modified rank POST body pageSize=500");
        }
    }
    return orig_dataTaskWithRequestCompletion(self, _cmd, mReq, completion);
}

// ============================================================
// 5. 入口：加载弹窗 + 执行所有 Hook
// ============================================================
__attribute__((constructor))
static void initialize(void) {
    @autoreleasepool {
        NSLog(@"AirChatPlus v2 loaded!");
        
        // 启动弹窗确认注入
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AirChatPlus 已注入"
                                                                           message:@"飞行圈增强插件已生效！"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
            if (rootVC) {
                [rootVC presentViewController:alert animated:YES completion:nil];
            }
        });
        
        Class hookClass = [AirChatPlusHook class];
        
        // ---- 1. 飞行圈 Cell 类 ----
        Class momentCell = findClassContaining(@"Moment", @"Cell");
        if (momentCell) {
            NSLog(@"AirChatPlus: Found MomentCell: %@", NSStringFromClass(momentCell));
            NSArray *selNames = @[@"setPostModel:", @"setModel:", @"setData:", @"setItem:"];
            for (NSString *selName in selNames) {
                SEL sel = NSSelectorFromString(selName);
                if ([momentCell instancesRespondToSelector:sel]) {
                    Method orig = class_getInstanceMethod(momentCell, sel);
                    Method newM = class_getInstanceMethod(hookClass, @selector(acp_setPostModel:));
                    if (orig && newM) {
                        orig_setPostModel = (void *)method_getImplementation(orig);
                        method_setImplementation(orig, method_getImplementation(newM));
                        NSLog(@"AirChatPlus: Hooked %@ on %@", selName, NSStringFromClass(momentCell));
                        break;
                    }
                }
            }
        } else {
            NSLog(@"AirChatPlus: Could not find MomentCell class");
        }
        
        // ---- 2. 详情页控制器 ----
        Class detailVC = findClassContaining3(@"Moment", @"Detail", @"Controller");
        if (detailVC) {
            NSLog(@"AirChatPlus: Found DetailVC: %@", NSStringFromClass(detailVC));
            SEL vdSel = @selector(viewDidLoad);
            if ([detailVC instancesRespondToSelector:vdSel]) {
                Method orig = class_getInstanceMethod(detailVC, vdSel);
                Method newM = class_getInstanceMethod(hookClass, @selector(acp_viewDidLoad));
                if (orig && newM) {
                    orig_viewDidLoad = (void *)method_getImplementation(orig);
                    method_setImplementation(orig, method_getImplementation(newM));
                    NSLog(@"AirChatPlus: Hooked viewDidLoad on %@", NSStringFromClass(detailVC));
                }
            }
            NSArray *visitorSels = @[@"showVisitorList", @"showVisitors", @"visitorButtonTapped", @"onVisitorClick"];
            for (NSString *selName in visitorSels) {
                SEL sel = NSSelectorFromString(selName);
                if ([detailVC instancesRespondToSelector:sel]) {
                    Method orig = class_getInstanceMethod(detailVC, sel);
                    Method newM = class_getInstanceMethod(hookClass, @selector(acp_showVisitorList));
                    if (orig && newM) {
                        orig_showVisitorList = (void *)method_getImplementation(orig);
                        method_setImplementation(orig, method_getImplementation(newM));
                        NSLog(@"AirChatPlus: Hooked %@ on %@", selName, NSStringFromClass(detailVC));
                        break;
                    }
                }
            }
        } else {
            NSLog(@"AirChatPlus: Could not find DetailVC class");
        }
        
        // ---- 3. NSURLSession 网络拦截 ----
        Class sessionClass = [NSURLSession class];
        SEL dataSel = @selector(dataTaskWithRequest:completionHandler:);
        Method origData = class_getInstanceMethod(sessionClass, dataSel);
        Method newData = class_getInstanceMethod(hookClass, @selector(acp_dataTaskWithRequest:completionHandler:));
        if (origData && newData) {
            orig_dataTaskWithRequestCompletion = (void *)method_getImplementation(origData);
            method_setImplementation(origData, method_getImplementation(newData));
            NSLog(@"AirChatPlus: Hooked NSURLSession dataTaskWithRequest:completionHandler:");
        } else {
            NSLog(@"AirChatPlus: Failed to hook NSURLSession");
        }
        
        NSLog(@"AirChatPlus: All hooks initialized");
    }
}
