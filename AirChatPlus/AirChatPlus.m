#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// =====================================================
// 工具函数：安全地交换实例方法
// =====================================================
static void swizzleInstanceMethod(Class cls, SEL orig, SEL new) {
    Method origMethod = class_getInstanceMethod(cls, orig);
    Method newMethod = class_getInstanceMethod(cls, new);
    if (origMethod && newMethod) {
        method_exchangeImplementations(origMethod, newMethod);
    }
}

// =====================================================
// 1. 强制显示访客数量（浏览数、曝光数）
// 目标类：AirMomentCell（飞行圈帖子 Cell）
// 方法：setPostModel:
// =====================================================
static void (*orig_setPostModel)(id, SEL, id);
static void new_setPostModel(id self, SEL _cmd, id postModel) {
    // 调用原方法
    orig_setPostModel(self, _cmd, postModel);
    
    // 强制显示 viewCountLabel 和 exposureCountLabel
    UILabel *viewLabel = [self valueForKey:@"viewCountLabel"];
    if (viewLabel) {
        viewLabel.hidden = NO;
        NSNumber *count = [postModel valueForKey:@"viewCount"];
        if (count) {
            viewLabel.text = [NSString stringWithFormat:@"浏览 %@", count];
        } else {
            viewLabel.text = @"浏览 ?";
        }
    }
    UILabel *expLabel = [self valueForKey:@"exposureCountLabel"];
    if (expLabel) {
        expLabel.hidden = NO;
        NSNumber *exp = [postModel valueForKey:@"exposureCount"];
        if (exp) {
            expLabel.text = [NSString stringWithFormat:@"曝光 %@", exp];
        } else {
            expLabel.text = @"曝光 ?";
        }
    }
}

// =====================================================
// 2. 强制显示访客入口（AirMomentVisitorsView）
// 目标类：AirMomentDetailViewController
// 方法：viewDidLoad
// =====================================================
static void (*orig_viewDidLoad)(id, SEL);
static void new_viewDidLoad(id self, SEL _cmd) {
    orig_viewDidLoad(self, _cmd);
    UIView *visitorsView = [self valueForKey:@"visitorsView"];
    if (visitorsView) {
        visitorsView.hidden = NO;
        visitorsView.userInteractionEnabled = YES;
    }
}

// =====================================================
// 3. 拦截访客列表点击，非作者弹出提示
// 目标类：AirMomentDetailViewController
// 方法：showVisitorList（假设的点击方法）
// =====================================================
static void (*orig_showVisitorList)(id, SEL);
static void new_showVisitorList(id self, SEL _cmd) {
    id postModel = [self valueForKey:@"postModel"];
    BOOL isMyPost = [[postModel valueForKey:@"isMyPost"] boolValue];
    if (!isMyPost) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示"
                                                                       message:@"访客列表仅作者可查看"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *vc = (UIViewController *)self;
        [vc presentViewController:alert animated:YES completion:nil];
        return;
    }
    orig_showVisitorList(self, _cmd);
}

// =====================================================
// 4. 突破排行榜限制：修改网络请求的 pageSize
// 使用 NSURLSession 的 dataTaskWithRequest:completionHandler: 拦截
// =====================================================
typedef void (^DataTaskCompletion)(NSData *, NSURLResponse *, NSError *);

static NSURLSessionDataTask *(*orig_dataTaskWithRequestCompletion)(id, SEL, NSURLRequest *, DataTaskCompletion);
static NSURLSessionDataTask *new_dataTaskWithRequestCompletion(id self, SEL _cmd, NSURLRequest *request, DataTaskCompletion completion) {
    NSMutableURLRequest *mReq = [request mutableCopy];
    // 检测排行榜接口（假设 URL 包含 /rank/list）
    if ([request.URL.absoluteString containsString:@"/rank/list"]) {
        // 如果是 GET，修改 query 参数
        if ([request.HTTPMethod isEqualToString:@"GET"]) {
            NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
            NSMutableArray *queryItems = [components.queryItems mutableCopy] ?: [NSMutableArray array];
            BOOL hasPageSize = NO;
            for (NSURLQueryItem *item in queryItems) {
                if ([item.name isEqualToString:@"pageSize"]) {
                    hasPageSize = YES;
                    break;
                }
            }
            if (!hasPageSize) {
                [queryItems addObject:[NSURLQueryItem queryItemWithName:@"pageSize" value:@"200"]];
            } else {
                // 替换已有的 pageSize
                for (NSURLQueryItem *item in queryItems) {
                    if ([item.name isEqualToString:@"pageSize"]) {
                        [queryItems removeObject:item];
                        [queryItems addObject:[NSURLQueryItem queryItemWithName:@"pageSize" value:@"200"]];
                        break;
                    }
                }
            }
            components.queryItems = queryItems;
            mReq.URL = components.URL;
        }
        // 如果是 POST，修改 HTTP Body（假设是 JSON）
        else if ([request.HTTPMethod isEqualToString:@"POST"]) {
            if (request.HTTPBody) {
                NSError *err;
                NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:NSJSONReadingMutableContainers error:&err];
                if (json && !err) {
                    json[@"pageSize"] = @(200);
                    NSData *newBody = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
                    if (newBody) {
                        mReq.HTTPBody = newBody;
                    }
                }
            }
        }
    }
    return orig_dataTaskWithRequestCompletion(self, _cmd, mReq, completion);
}

// =====================================================
// 5. 入口：+load 中执行所有 swizzle
// =====================================================
__attribute__((constructor))
static void initialize(void) {
    @autoreleasepool {
        // 5.1 AirMomentCell
        Class AirMomentCell = NSClassFromString(@"AirMomentCell");
        if (AirMomentCell) {
            SEL origSEL = sel_registerName("setPostModel:");
            SEL newSEL = sel_registerName("new_setPostModel:");
            Method origMethod = class_getInstanceMethod(AirMomentCell, origSEL);
            Method newMethod = class_getInstanceMethod([self class], newSEL);
            if (origMethod && newMethod) {
                orig_setPostModel = (void *)method_getImplementation(origMethod);
                method_setImplementation(origMethod, method_getImplementation(newMethod));
            }
        }
        
        // 5.2 AirMomentDetailViewController viewDidLoad
        Class AirMomentDetailVC = NSClassFromString(@"AirMomentDetailViewController");
        if (AirMomentDetailVC) {
            SEL origSEL = @selector(viewDidLoad);
            SEL newSEL = sel_registerName("new_viewDidLoad");
            Method origMethod = class_getInstanceMethod(AirMomentDetailVC, origSEL);
            Method newMethod = class_getInstanceMethod([self class], newSEL);
            if (origMethod && newMethod) {
                orig_viewDidLoad = (void *)method_getImplementation(origMethod);
                method_setImplementation(origMethod, method_getImplementation(newMethod));
            }
            
            // 5.3 showVisitorList
            SEL showSEL = sel_registerName("showVisitorList");
            if ([AirMomentDetailVC instancesRespondToSelector:showSEL]) {
                Method origShow = class_getInstanceMethod(AirMomentDetailVC, showSEL);
                Method newShow = class_getInstanceMethod([self class], sel_registerName("new_showVisitorList"));
                if (origShow && newShow) {
                    orig_showVisitorList = (void *)method_getImplementation(origShow);
                    method_setImplementation(origShow, method_getImplementation(newShow));
                }
            }
        }
        
        // 5.4 NSURLSession dataTaskWithRequest:completionHandler:
        Class NSURLSessionClass = [NSURLSession class];
        SEL dataSEL = @selector(dataTaskWithRequest:completionHandler:);
        Method origData = class_getInstanceMethod(NSURLSessionClass, dataSEL);
        Method newData = class_getInstanceMethod([self class], sel_registerName("new_dataTaskWithRequest:completionHandler:"));
        if (origData && newData) {
            orig_dataTaskWithRequestCompletion = (void *)method_getImplementation(origData);
            method_setImplementation(origData, method_getImplementation(newData));
        }
    }
}

// 声明这些新方法（供 runtime 查找）
@interface NSObject (AirChatPlus)
- (void)new_setPostModel:(id)postModel;
- (void)new_viewDidLoad;
- (void)new_showVisitorList;
- (NSURLSessionDataTask *)new_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
@end
