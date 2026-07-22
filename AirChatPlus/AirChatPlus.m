// ============================================================
// AirChatPlus v7 - 诊断版（含文件日志 + 广泛类匹配 + 全功能 Hook）
// 功能：
//   1. 启动弹窗（证明加载成功）
//   2. 文件日志（Documents/AirChatPlus.log）
//   3. 遍历所有类，自动匹配 Moment/Cell 并 Hook setModel:/setPostModel:
//   4. Hook viewDidAppear: 在详情页添加访客标签
//   5. Hook NSURLSession 修改排行榜 pageSize
// ============================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================
// 辅助类：承载 ObjC 方法实现（供 runtime 查找）
// ============================================================
@interface AirChatPlusHook : NSObject
- (void)acp_viewDidAppear:(BOOL)animated;
- (void)acp_setPostModel:(id)model;
- (void)acp_setModel:(id)model;
- (NSURLSessionDataTask *)acp_dataTaskWithRequest:(NSURLRequest *)req
                                completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
@end

@implementation AirChatPlusHook
- (void)acp_viewDidAppear:(BOOL)animated {}
- (void)acp_setPostModel:(id)model {}
- (void)acp_setModel:(id)model {}
- (NSURLSessionDataTask *)acp_dataTaskWithRequest:(NSURLRequest *)req
                                completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    return nil;
}
@end

// ============================================================
// 日志工具：写入文件 + NSLog
// ============================================================
static NSString *logFilePath = nil;

static void LogToFile(NSString *msg) {
    NSLog(@"AirChatPlus: %@", msg);
    if (!logFilePath) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        logFilePath = [paths.firstObject stringByAppendingPathComponent:@"AirChatPlus.log"];
    }
    NSString *timestamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                         dateStyle:NSDateFormatterShortStyle
                                                         timeStyle:NSDateFormatterMediumStyle];
    NSString *logMsg = [NSString stringWithFormat:@"[%@] %@\n", timestamp, msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logFilePath];
    if (!fh) {
        [logMsg writeToFile:logFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[logMsg dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// ============================================================
// 1. 自动寻找并 Hook 帖子 Cell 的数据绑定方法 (setModel:)
// ============================================================
static void (*orig_setModel)(id, SEL, id);
static void new_setModel(id self, SEL _cmd, id model) {
    orig_setModel(self, _cmd, model);
    // 强制显示访客标签（如果 Cell 中有 viewCountLabel 等）
    NSArray *keys = @[@"viewCountLabel", @"visitorCountLabel", @"exposureCountLabel"];
    for (NSString *key in keys) {
        @try {
            UILabel *label = [self valueForKey:key];
            if (label) {
                label.hidden = NO;
                NSNumber *count = [model valueForKey:key];
                if (!count) count = [model valueForKey:@"viewCount"];
                if (!count) count = [model valueForKey:@"visitorCount"];
                if (count) {
                    label.text = [NSString stringWithFormat:@"%@", count];
                    LogToFile([NSString stringWithFormat:@"Cell显示访客数: %@", count]);
                }
                break;
            }
        } @catch (NSException *e) {}
    }
}

// ============================================================
// 2. 通用的 setter Hook (setPostModel:) - 延迟更新 UI
// ============================================================
static void (*orig_setPostModel)(id, SEL, id);
static void new_setPostModel(id self, SEL _cmd, id model) {
    orig_setPostModel(self, _cmd, model);
    // 延迟尝试更新访客 UI
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            NSArray *keys = @[@"viewCountLabel", @"visitorCountLabel", @"exposureCountLabel"];
            for (NSString *key in keys) {
                UILabel *label = [self valueForKey:key];
                if (label) {
                    label.hidden = NO;
                    NSNumber *count = [model valueForKey:key];
                    if (!count) count = [model valueForKey:@"viewCount"];
                    if (!count) count = [model valueForKey:@"visitorCount"];
                    if (count) {
                        label.text = [NSString stringWithFormat:@"%@", count];
                        LogToFile([NSString stringWithFormat:@"setPostModel延迟更新: %@ = %@", key, count]);
                    }
                    break;
                }
            }
        } @catch (NSException *e) {}
    });
}

// ============================================================
// 3. 在详情页添加访客标签（Hook viewDidAppear:）
// ============================================================
static void (*orig_viewDidAppear)(id, SEL, BOOL);
static void new_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);
    NSString *className = NSStringFromClass([self class]);
    LogToFile([NSString stringWithFormat:@"页面出现: %@", className]);

    // 判断是否为详情页（匹配多种关键词）
    BOOL isDetail = ([className rangeOfString:@"Detail" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                     [className rangeOfString:@"Moment" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                     [className rangeOfString:@"Post" options:NSCaseInsensitiveSearch].location != NSNotFound);
    if (!isDetail) return;

    // 尝试获取 postModel
    id postModel = nil;
    @try { postModel = [self valueForKey:@"postModel"]; } @catch (NSException *e) {}
    if (!postModel) {
        @try { postModel = [self valueForKey:@"model"]; } @catch (NSException *e) {}
    }
    if (!postModel) {
        LogToFile(@"详情页未找到 postModel");
        return;
    }

    NSNumber *count = nil;
    @try { count = [postModel valueForKey:@"visitorCount"]; } @catch (NSException *e) {}
    if (!count) @try { count = [postModel valueForKey:@"viewCount"]; } @catch (NSException *e) {}
    if (!count || [count integerValue] <= 0) {
        LogToFile(@"postModel 中无访客数量字段");
        return;
    }

    // 检查是否已添加标签（防止重复添加）
    static const char kLabelKey;
    if (objc_getAssociatedObject(self, &kLabelKey)) return;
    objc_setAssociatedObject(self, &kLabelKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UILabel *label = [[UILabel alloc] init];
    label.text = [NSString stringWithFormat:@"\U0001F440 访客人数: %@", count];
    label.textColor = [UIColor systemBlueColor];
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    label.backgroundColor = [[UIColor systemGray6Color] colorWithAlphaComponent:0.9];
    label.layer.cornerRadius = 6;
    label.clipsToBounds = YES;
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [((UIViewController *)self).view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:((UIViewController *)self).view.safeAreaLayoutGuide.topAnchor constant:8],
        [label.centerXAnchor constraintEqualToAnchor:((UIViewController *)self).view.centerXAnchor],
        [label.widthAnchor constraintGreaterThanOrEqualToConstant:130],
        [label.heightAnchor constraintEqualToConstant:28]
    ]];
    LogToFile([NSString stringWithFormat:@"已添加访客标签: %@", count]);
}

// ============================================================
// 4. 排行榜 pageSize 修改（针对 GET 和 POST）
// ============================================================
typedef void (^DataTaskCompletion)(NSData *, NSURLResponse *, NSError *);
static NSURLSessionDataTask *(*orig_dataTaskWithRequestCompletion)(id, SEL, NSURLRequest *, DataTaskCompletion);

static NSURLSessionDataTask *new_dataTaskWithRequestCompletion(id self, SEL _cmd, NSURLRequest *request, DataTaskCompletion completion) {
    NSMutableURLRequest *mReq = [request mutableCopy];
    NSString *urlString = request.URL.absoluteString;

    if ([urlString rangeOfString:@"rank" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        LogToFile([NSString stringWithFormat:@"拦截排行榜请求: %@", urlString]);
        if ([request.HTTPMethod isEqualToString:@"GET"]) {
            NSURLComponents *components = [NSURLComponents componentsWithURL:mReq.URL resolvingAgainstBaseURL:NO];
            NSMutableArray *queryItems = [components.queryItems mutableCopy] ?: [NSMutableArray array];
            NSMutableArray *newItems = [NSMutableArray array];
            BOOL hasPageSize = NO;
            for (NSURLQueryItem *item in queryItems) {
                if ([item.name isEqualToString:@"pageSize"]) {
                    [newItems addObject:[NSURLQueryItem queryItemWithName:@"pageSize" value:@"500"]];
                    hasPageSize = YES;
                } else {
                    [newItems addObject:item];
                }
            }
            if (!hasPageSize) {
                [newItems addObject:[NSURLQueryItem queryItemWithName:@"pageSize" value:@"500"]];
            }
            components.queryItems = newItems;
            mReq.URL = components.URL;
            LogToFile([NSString stringWithFormat:@"修改 GET pageSize=500, 新URL: %@", mReq.URL]);
        } else if ([request.HTTPMethod isEqualToString:@"POST"]) {
            if (request.HTTPBody) {
                NSError *err = nil;
                NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:NSJSONReadingMutableContainers error:&err];
                if (json && !err) {
                    json[@"pageSize"] = @(500);
                    NSData *newBody = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
                    if (newBody) mReq.HTTPBody = newBody;
                    LogToFile(@"修改 POST body pageSize=500");
                }
            }
        }
    }
    return orig_dataTaskWithRequestCompletion(self, _cmd, mReq, completion);
}

// ============================================================
// 5. 初始化入口
// ============================================================
__attribute__((constructor))
static void initialize(void) {
    @autoreleasepool {
        LogToFile(@"====== AirChatPlus v7 开始加载 ======");
        Class hookClass = [AirChatPlusHook class];

        // ---- Hook UIViewController viewDidAppear: ----
        Class vcClass = [UIViewController class];
        SEL viewDidAppearSel = @selector(viewDidAppear:);
        Method origMethod = class_getInstanceMethod(vcClass, viewDidAppearSel);
        Method newMethod = class_getInstanceMethod(hookClass, @selector(acp_viewDidAppear:));
        if (origMethod && newMethod) {
            orig_viewDidAppear = (void *)method_getImplementation(origMethod);
            method_setImplementation(origMethod, method_getImplementation(newMethod));
            LogToFile(@"\u2713 Hook viewDidAppear 成功");
        } else {
            LogToFile(@"\u2717 Hook viewDidAppear 失败");
        }

        // ---- 遍历所有类，寻找可能的 Cell 类并尝试 Hook ----
        int numClasses = objc_getClassList(NULL, 0);
        Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
        numClasses = objc_getClassList(classes, numClasses);
        int hookedCells = 0;
        for (int i = 0; i < numClasses; i++) {
            NSString *name = NSStringFromClass(classes[i]);
            if ([name containsString:@"Moment"] && [name containsString:@"Cell"]) {
                LogToFile([NSString stringWithFormat:@"发现候选 Cell 类: %@", name]);
                // 尝试多个 setter
                NSArray *setters = @[@"setPostModel:", @"setModel:", @"setData:", @"setItem:"];
                BOOL hooked = NO;
                for (NSString *selName in setters) {
                    SEL sel = NSSelectorFromString(selName);
                    if ([classes[i] instancesRespondToSelector:sel]) {
                        Method orig = class_getInstanceMethod(classes[i], sel);
                        if (!orig) continue;

                        // 根据方法名选择对应 hook 实现
                        if ([selName isEqualToString:@"setPostModel:"]) {
                            Method newImpl = class_getInstanceMethod(hookClass, @selector(acp_setPostModel:));
                            if (newImpl) {
                                orig_setPostModel = (void *)method_getImplementation(orig);
                                method_setImplementation(orig, method_getImplementation(newImpl));
                                LogToFile([NSString stringWithFormat:@"\u2713 Hook %@:%@ 成功", name, selName]);
                                hookedCells++;
                                hooked = YES;
                                break;
                            }
                        } else {
                            Method newImpl = class_getInstanceMethod(hookClass, @selector(acp_setModel:));
                            if (newImpl) {
                                orig_setModel = (void *)method_getImplementation(orig);
                                method_setImplementation(orig, method_getImplementation(newImpl));
                                LogToFile([NSString stringWithFormat:@"\u2713 Hook %@:%@ 成功", name, selName]);
                                hookedCells++;
                                hooked = YES;
                                break;
                            }
                        }
                    }
                }
                if (!hooked) {
                    LogToFile([NSString stringWithFormat:@"  %@ 无匹配 setter", name]);
                }
            }
        }
        free(classes);
        LogToFile([NSString stringWithFormat:@"共 Hook 了 %d 个 Cell 类", hookedCells]);

        // ---- 遍历并输出所有包含 Detail/Moment/Post 的类名（诊断用） ----
        int numClasses2 = objc_getClassList(NULL, 0);
        Class *cls2 = (Class *)malloc(sizeof(Class) * numClasses2);
        numClasses2 = objc_getClassList(cls2, numClasses2);
        NSMutableString *detailClasses = [NSMutableString string];
        for (int i = 0; i < numClasses2; i++) {
            NSString *n = NSStringFromClass(cls2[i]);
            if ([n containsString:@"Detail"] || ([n containsString:@"Moment"] && [n containsString:@"Controller"])) {
                [detailClasses appendFormat:@"  - %@\n", n];
            }
        }
        free(cls2);
        LogToFile([NSString stringWithFormat:@"详情页相关类:\n%@", detailClasses]);

        // ---- Hook NSURLSession ----
        Class sessionClass = [NSURLSession class];
        SEL dataSel = @selector(dataTaskWithRequest:completionHandler:);
        Method origData = class_getInstanceMethod(sessionClass, dataSel);
        Method newData = class_getInstanceMethod(hookClass, @selector(acp_dataTaskWithRequest:completionHandler:));
        if (origData && newData) {
            orig_dataTaskWithRequestCompletion = (void *)method_getImplementation(origData);
            method_setImplementation(origData, method_getImplementation(newData));
            LogToFile(@"\u2713 Hook NSURLSession 成功");
        } else {
            LogToFile(@"\u2717 Hook NSURLSession 失败");
        }

        LogToFile(@"====== AirChatPlus v7 加载完成 ======");

        // ---- 启动弹窗（延迟1.5秒确保主窗口存在） ----
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSString *logHint = [NSString stringWithFormat:@"\U0001F4CB 日志已写入 Documents/AirChatPlus.log\n共 Hook %d 个 Cell 类\n请查看详情页顶部是否显示访客人数", hookedCells];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AirChatPlus 已注入"
                                                                           message:logHint
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好的"
                                                     style:UIAlertActionStyleDefault
                                                   handler:nil]];
            UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
            if (rootVC) {
                [rootVC presentViewController:alert animated:YES completion:nil];
                LogToFile(@"\u2713 启动弹窗已显示");
            } else {
                LogToFile(@"\u2717 无法显示弹窗，可能注入失败或主窗口未就绪");
            }
        });
    }
}
