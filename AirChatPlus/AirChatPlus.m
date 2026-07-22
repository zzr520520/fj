// ============================================================
// AirChatPlus v5 - 完整增强版
// 启动弹窗 + 访客人数显示 + 权限弹窗拦截 + 排行榜自动翻页拼接
// ============================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================
// 辅助类：承载新方法的 ObjC 实现
// ============================================================
@interface AirChatPlusHook : NSObject
- (void)acp_viewDidAppear:(BOOL)animated;
- (void)acp_sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event;
- (NSURLSessionDataTask *)acp_dataTaskWithRequest:(NSURLRequest *)req completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
@end

@implementation AirChatPlusHook
- (void)acp_viewDidAppear:(BOOL)animated {}
- (void)acp_sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {}
- (NSURLSessionDataTask *)acp_dataTaskWithRequest:(NSURLRequest *)req completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler { return nil; }
@end

// ============================================================
// 功能1：在详情页顶部显示访客人数标签
// ============================================================
static void (*orig_viewDidAppear)(id, SEL, BOOL);
static void new_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);
    NSString *className = NSStringFromClass([self class]);
    if ([className containsString:@"MomentDetail"] || [className containsString:@"DetailViewController"]) {
        id postModel = nil;
        @try { postModel = [self valueForKey:@"postModel"]; } @catch (NSException *e) {}
        if (postModel) {
            NSNumber *count = nil;
            @try { count = [postModel valueForKey:@"visitorCount"]; } @catch (NSException *e) {}
            if (!count) @try { count = [postModel valueForKey:@"viewCount"]; } @catch (NSException *e) {}
            if (count && [count integerValue] > 0) {
                static const char visitorLabelKey;
                UILabel *label = objc_getAssociatedObject(self, &visitorLabelKey);
                if (!label) {
                    label = [[UILabel alloc] init];
                    label.textColor = [UIColor systemBlueColor];
                    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
                    label.translatesAutoresizingMaskIntoConstraints = NO;
                    label.backgroundColor = [[UIColor systemGray6Color] colorWithAlphaComponent:0.9];
                    label.layer.cornerRadius = 6;
                    label.clipsToBounds = YES;
                    label.textAlignment = NSTextAlignmentCenter;
                    [((UIViewController *)self).view addSubview:label];
                    [NSLayoutConstraint activateConstraints:@[
                        [label.topAnchor constraintEqualToAnchor:((UIViewController *)self).view.safeAreaLayoutGuide.topAnchor constant:8],
                        [label.centerXAnchor constraintEqualToAnchor:((UIViewController *)self).view.centerXAnchor],
                        [label.widthAnchor constraintGreaterThanOrEqualToConstant:130],
                        [label.heightAnchor constraintEqualToConstant:28]
                    ]];
                    objc_setAssociatedObject(self, &visitorLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                label.text = [NSString stringWithFormat:@"\U0001F440 访客人数: %@", count];
                label.hidden = NO;
            }
        }
    }
}

// ============================================================
// 功能2：拦截「访客数据」按钮，显示已有访客数量
// ============================================================
static void (*orig_sendAction)(id, SEL, SEL, id, UIEvent *);
static void new_sendAction(id self, SEL _cmd, SEL action, id target, UIEvent *event) {
    NSString *title = nil;
    @try {
        if ([self isKindOfClass:[UIButton class]]) {
            title = [(UIButton *)self titleForState:UIControlStateNormal];
        }
    } @catch (NSException *e) {}
    if (title && [title containsString:@"访客数据"]) {
        UIViewController *vc = nil;
        UIResponder *responder = self;
        while ((responder = [responder nextResponder])) {
            if ([responder isKindOfClass:[UIViewController class]]) {
                vc = (UIViewController *)responder;
                break;
            }
        }
        if (vc) {
            id postModel = nil;
            @try { postModel = [vc valueForKey:@"postModel"]; } @catch (NSException *e) {}
            NSNumber *count = nil;
            if (postModel) {
                @try { count = [postModel valueForKey:@"visitorCount"]; } @catch (NSException *e) {}
                if (!count) @try { count = [postModel valueForKey:@"viewCount"]; } @catch (NSException *e) {}
            }
            NSString *msg = count
                ? [NSString stringWithFormat:@"该帖子共有 %@ 位访客（详情仅作者可见）", count]
                : @"暂未获取到访客数据";
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"访客信息"
                                                                           message:msg
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleCancel handler:nil]];
            @try { [vc presentViewController:alert animated:YES completion:nil]; } @catch (NSException *e) {}
            return;
        }
    }
    orig_sendAction(self, _cmd, action, target, event);
}

// ============================================================
// 功能3：排行榜自动翻页拼接（突破100限制）
// ============================================================
typedef void (^DataTaskCompletion)(NSData *, NSURLResponse *, NSError *);

static NSURLSessionDataTask *(*orig_dataTaskWithRequestCompletion)(id, SEL, NSURLRequest *, DataTaskCompletion);

static NSURLSessionDataTask *new_dataTaskWithRequestCompletion(id self, SEL _cmd, NSURLRequest *request, DataTaskCompletion completion) {
    NSMutableURLRequest *mReq = [request mutableCopy];
    NSString *urlString = request.URL.absoluteString;
    BOOL isRank = ([urlString rangeOfString:@"rank" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                   [urlString rangeOfString:@"leaderboard" options:NSCaseInsensitiveSearch].location != NSNotFound);
    if (!isRank) {
        return orig_dataTaskWithRequestCompletion(self, _cmd, mReq, completion);
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:mReq.URL resolvingAgainstBaseURL:NO];
    NSMutableArray *queryItems = [components.queryItems mutableCopy] ?: [NSMutableArray array];
    NSMutableArray *filteredItems = [NSMutableArray array];
    for (NSURLQueryItem *item in queryItems) {
        if (![item.name isEqualToString:@"pageSize"]) {
            [filteredItems addObject:item];
        }
    }
    [filteredItems addObject:[NSURLQueryItem queryItemWithName:@"pageSize" value:@"100"]];
    components.queryItems = filteredItems;
    mReq.URL = components.URL;
    NSLog(@"AirChatPlus: 拦截排行榜，开始拼接多页数据");

    DataTaskCompletion newCompletion = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            if (completion) completion(data, response, error);
            return;
        }
        NSError *jsonError;
        NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&jsonError];
        if (jsonError || !json) {
            if (completion) completion(data, response, error);
            return;
        }
        NSMutableArray *currentList = [json valueForKeyPath:@"data.list"];
        if (!currentList) currentList = [json valueForKeyPath:@"data.records"];
        if (!currentList) currentList = [json valueForKeyPath:@"list"];
        if (!currentList) currentList = [json valueForKeyPath:@"records"];
        if (!currentList) {
            if (completion) completion(data, response, error);
            return;
        }
        NSNumber *total = [json valueForKeyPath:@"data.total"] ?: [json valueForKeyPath:@"total"];
        NSInteger totalCount = [total integerValue];
        NSInteger currentCount = currentList.count;
        if (totalCount <= 100 || currentCount >= totalCount) {
            if (completion) completion(data, response, error);
            return;
        }
        NSInteger totalPages = (totalCount + 99) / 100;
        NSLog(@"AirChatPlus: 总条数 %ld，需要合并 %ld 页", (long)totalCount, (long)totalPages);

        dispatch_group_t group = dispatch_group_create();
        __block NSMutableArray *allData = [currentList mutableCopy];
        __block BOOL hasError = NO;

        for (NSInteger page = 2; page <= totalPages; page++) {
            dispatch_group_enter(group);
            NSURLComponents *pageComponents = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
            NSMutableArray *pageItems = [pageComponents.queryItems mutableCopy] ?: [NSMutableArray array];
            NSMutableArray *pageFiltered = [NSMutableArray array];
            for (NSURLQueryItem *item in pageItems) {
                if (![item.name isEqualToString:@"page"] && ![item.name isEqualToString:@"pageSize"]) {
                    [pageFiltered addObject:item];
                }
            }
            [pageFiltered addObject:[NSURLQueryItem queryItemWithName:@"page" value:[NSString stringWithFormat:@"%ld", (long)page]]];
            [pageFiltered addObject:[NSURLQueryItem queryItemWithName:@"pageSize" value:@"100"]];
            pageComponents.queryItems = pageFiltered;
            NSURL *pageURL = pageComponents.URL;

            NSURLRequest *pageRequest = [NSURLRequest requestWithURL:pageURL];
            NSURLSessionDataTask *task = orig_dataTaskWithRequestCompletion(self, @selector(dataTaskWithRequest:completionHandler:), pageRequest, ^(NSData *pageData, NSURLResponse *pageResponse, NSError *pageError) {
                if (!pageError && pageData) {
                    NSError *err;
                    NSDictionary *pageJson = [NSJSONSerialization JSONObjectWithData:pageData options:0 error:&err];
                    if (!err && pageJson) {
                        NSArray *pageList = [pageJson valueForKeyPath:@"data.list"] ?: [pageJson valueForKeyPath:@"data.records"];
                        if (!pageList) pageList = [pageJson valueForKeyPath:@"list"] ?: [pageJson valueForKeyPath:@"records"];
                        if (pageList) [allData addObjectsFromArray:pageList];
                    }
                } else {
                    hasError = YES;
                }
                dispatch_group_leave(group);
            });
            if (task) [task resume];
            else dispatch_group_leave(group);
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            if (hasError) {
                if (completion) completion(data, response, error);
            } else {
                id dataObj = [json valueForKey:@"data"];
                if ([dataObj isKindOfClass:[NSMutableDictionary class]]) {
                    [dataObj setObject:allData forKey:@"list"];
                } else {
                    [json setObject:@{@"list": allData} forKey:@"data"];
                }
                [json setObject:@(allData.count) forKey:@"total"];
                NSData *mergedData = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
                if (mergedData && completion) {
                    NSLog(@"AirChatPlus: 排行榜合并完成，总条数 %ld", (long)allData.count);
                    completion(mergedData, response, error);
                } else {
                    completion(data, response, error);
                }
            }
        });
    };

    return orig_dataTaskWithRequestCompletion(self, _cmd, mReq, newCompletion);
}

// ============================================================
// 入口：Hook 系统方法 + 显示启动弹窗
// ============================================================
__attribute__((constructor))
static void initialize(void) {
    @autoreleasepool {
        NSLog(@"AirChatPlus v5 loaded!");
        Class hookClass = [AirChatPlusHook class];

        Class vcClass = [UIViewController class];
        Method origM = class_getInstanceMethod(vcClass, @selector(viewDidAppear:));
        Method newM = class_getInstanceMethod(hookClass, @selector(acp_viewDidAppear:));
        if (origM && newM) {
            orig_viewDidAppear = (void *)method_getImplementation(origM);
            method_setImplementation(origM, method_getImplementation(newM));
            NSLog(@"AirChatPlus: viewDidAppear hooked");
        }

        Class btnClass = [UIButton class];
        Method origSend = class_getInstanceMethod(btnClass, @selector(sendAction:to:forEvent:));
        Method newSend = class_getInstanceMethod(hookClass, @selector(acp_sendAction:to:forEvent:));
        if (origSend && newSend) {
            orig_sendAction = (void *)method_getImplementation(origSend);
            method_setImplementation(origSend, method_getImplementation(newSend));
            NSLog(@"AirChatPlus: UIButton sendAction hooked");
        }

        Class sessionClass = [NSURLSession class];
        Method origData = class_getInstanceMethod(sessionClass, @selector(dataTaskWithRequest:completionHandler:));
        Method newData = class_getInstanceMethod(hookClass, @selector(acp_dataTaskWithRequest:completionHandler:));
        if (origData && newData) {
            orig_dataTaskWithRequestCompletion = (void *)method_getImplementation(origData);
            method_setImplementation(origData, method_getImplementation(newData));
            NSLog(@"AirChatPlus: NSURLSession hooked");
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AirChatPlus 已加载"
                                                                           message:@"访客数量显示 & 权限弹窗拦截 & 排行榜突破"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
            if (rootVC) [rootVC presentViewController:alert animated:YES completion:nil];
        });
    }
}
