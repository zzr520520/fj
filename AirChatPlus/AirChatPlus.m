#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// =====================================================
// 辅助类：承载新方法实现（供 runtime 查找）
// =====================================================
@interface AirChatPlusHook : NSObject
- (void)new_setPostModel:(id)postModel;
- (void)new_viewDidLoad;
- (void)new_showVisitorList;
- (NSURLSessionDataTask *)new_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
@end

@implementation AirChatPlusHook

- (void)new_setPostModel:(id)postModel {
    // 占位，实际逻辑在 C 函数中
}

- (void)new_viewDidLoad {
    // 占位
}

- (void)new_showVisitorList {
    // 占位
}

- (NSURLSessionDataTask *)new_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    return nil;
}

@end

// =====================================================
// 1. 强制显示访客数量（浏览数、曝光数）
// 目标类：AirMomentCell（飞行圈帖子 Cell）
// 方法：setPostModel:
// =====================================================
static void (*orig_setPostModel)(id, SEL, id);
static void new_setPostModel(id self, SEL _cmd, id postModel) {
    orig_setPostModel(self, _cmd, postModel);
    UILabel *viewLabel = [self valueForKey:@"viewCountLabel"];
    if (viewLabel) {
        viewLabel.hidden = NO;
        NSNumber *count = [postModel valueForKey:@"viewCount"];
        viewLabel.text = count ? [NSString stringWithFormat:@"浏览 %@", count] : @"浏览 ?";
    }
    UILabel *expLabel = [self valueForKey:@"exposureCountLabel"];
    if (expLabel) {
        expLabel.hidden = NO;
        NSNumber *exp = [postModel valueForKey:@"exposureCount"];
        expLabel.text = exp ? [NSString stringWithFormat:@"曝光 %@", exp] : @"曝光 ?";
    }
}

// =====================================================
// 2. 强制显示访客入口（AirMomentVisitorsView）
// 目标类：AirMomentDetailViewController
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
        [(UIViewController *)self presentViewController:alert animated:YES completion:nil];
        return;
    }
    orig_showVisitorList(self, _cmd);
}

// =====================================================
// 4. 突破排行榜限制：修改网络请求的 pageSize
// =====================================================
typedef void (^DataTaskCompletion)(NSData *, NSURLResponse *, NSError *);

static NSURLSessionDataTask *(*orig_dataTaskWithRequestCompletion)(id, SEL, NSURLRequest *, DataTaskCompletion);
static NSURLSessionDataTask *new_dataTaskWithRequestCompletion(id self, SEL _cmd, NSURLRequest *request, DataTaskCompletion completion) {
    NSMutableURLRequest *mReq = [request mutableCopy];
    if ([request.URL.absoluteString containsString:@"/rank/list"]) {
        if ([request.HTTPMethod isEqualToString:@"GET"]) {
            NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
            NSMutableArray *queryItems = [components.queryItems mutableCopy] ?: [NSMutableArray array];
            BOOL replaced = NO;
            for (NSUInteger i = 0; i < queryItems.count; i++) {
                NSURLQueryItem *item = queryItems[i];
                if ([item.name isEqualToString:@"pageSize"]) {
                    queryItems[i] = [NSURLQueryItem queryItemWithName:@"pageSize" value:@"200"];
                    replaced = YES;
                    break;
                }
            }
            if (!replaced) {
                [queryItems addObject:[NSURLQueryItem queryItemWithName:@"pageSize" value:@"200"]];
            }
            components.queryItems = queryItems;
            mReq.URL = components.URL;
        } else if ([request.HTTPMethod isEqualToString:@"POST"] && request.HTTPBody) {
            NSError *err = nil;
            NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:NSJSONReadingMutableContainers error:&err];
            if (json && !err) {
                json[@"pageSize"] = @(200);
                NSData *newBody = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
                if (newBody) mReq.HTTPBody = newBody;
            }
        }
    }
    return orig_dataTaskWithRequestCompletion(self, _cmd, mReq, completion);
}

// =====================================================
// 5. 入口：__attribute__((constructor)) 中执行所有 swizzle
// =====================================================
__attribute__((constructor))
static void initialize(void) {
    @autoreleasepool {
        Class hookClass = [AirChatPlusHook class];

        // 5.1 AirMomentCell - setPostModel:
        Class AirMomentCell = NSClassFromString(@"AirMomentCell");
        if (AirMomentCell) {
            SEL origSEL = @selector(setPostModel:);
            SEL newSEL = @selector(new_setPostModel:);
            Method origM = class_getInstanceMethod(AirMomentCell, origSEL);
            Method newM = class_getInstanceMethod(hookClass, newSEL);
            if (origM && newM) {
                orig_setPostModel = (void *)method_getImplementation(origM);
                method_setImplementation(origM, method_getImplementation(newM));
            }
        }
        
        // 5.2 AirMomentDetailViewController - viewDidLoad
        Class AirMomentDetailVC = NSClassFromString(@"AirMomentDetailViewController");
        if (AirMomentDetailVC) {
            SEL origSEL = @selector(viewDidLoad);
            SEL newSEL = @selector(new_viewDidLoad);
            Method origM = class_getInstanceMethod(AirMomentDetailVC, origSEL);
            Method newM = class_getInstanceMethod(hookClass, newSEL);
            if (origM && newM) {
                orig_viewDidLoad = (void *)method_getImplementation(origM);
                method_setImplementation(origM, method_getImplementation(newM));
            }
            
            // showVisitorList
            SEL showSEL = sel_registerName("showVisitorList");
            if ([AirMomentDetailVC instancesRespondToSelector:showSEL]) {
                Method origShow = class_getInstanceMethod(AirMomentDetailVC, showSEL);
                Method newShow = class_getInstanceMethod(hookClass, @selector(new_showVisitorList));
                if (origShow && newShow) {
                    orig_showVisitorList = (void *)method_getImplementation(origShow);
                    method_setImplementation(origShow, method_getImplementation(newShow));
                }
            }
        }
        
        // 5.3 NSURLSession - dataTaskWithRequest:completionHandler:
        Class NSURLSessionClass = [NSURLSession class];
        SEL dataSEL = @selector(dataTaskWithRequest:completionHandler:);
        Method origData = class_getInstanceMethod(NSURLSessionClass, dataSEL);
        Method newData = class_getInstanceMethod(hookClass, @selector(new_dataTaskWithRequest:completionHandler:));
        if (origData && newData) {
            orig_dataTaskWithRequestCompletion = (void *)method_getImplementation(origData);
            method_setImplementation(origData, method_getImplementation(newData));
        }
    }
}
