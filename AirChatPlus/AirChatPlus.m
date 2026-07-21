// ============================================================
// AirChatPlus v3 - 稳定版
// 仅 Hook 系统类，添加新 UI 显示访客人数，修改排行榜 pageSize
// ============================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================
// 辅助类：承载新方法实现
// ============================================================
@interface AirChatPlusHook : NSObject
- (void)acp_viewDidAppear:(BOOL)animated;
- (NSURLSessionDataTask *)acp_dataTaskWithRequest:(NSURLRequest *)req completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
@end

@implementation AirChatPlusHook
- (void)acp_viewDidAppear:(BOOL)animated {}
- (NSURLSessionDataTask *)acp_dataTaskWithRequest:(NSURLRequest *)req completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler { return nil; }
@end

// ============================================================
// 1. Hook UIViewController viewDidAppear:
//    在详情页添加访客人数标签
// ============================================================
static void (*orig_viewDidAppear)(id, SEL, BOOL);
static void new_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);
    
    NSString *className = NSStringFromClass([self class]);
    if ([className containsString:@"MomentDetail"] || [className containsString:@"DetailViewController"]) {
        id postModel = nil;
        @try { postModel = [self valueForKey:@"postModel"]; } @catch (NSException *e) {}
        
        if (postModel) {
            NSNumber *visitorCount = nil;
            @try {
                visitorCount = [postModel valueForKey:@"visitorCount"];
                if (!visitorCount) visitorCount = [postModel valueForKey:@"viewCount"];
            } @catch (NSException *e) {}
            
            if (visitorCount && [visitorCount integerValue] > 0) {
                static const char visitorLabelKey;
                UILabel *label = objc_getAssociatedObject(self, &visitorLabelKey);
                if (!label) {
                    label = [[UILabel alloc] init];
                    label.textColor = [UIColor systemBlueColor];
                    label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
                    label.translatesAutoresizingMaskIntoConstraints = NO;
                    label.backgroundColor = [[UIColor systemGray6Color] colorWithAlphaComponent:0.8];
                    label.layer.cornerRadius = 8;
                    label.clipsToBounds = YES;
                    label.textAlignment = NSTextAlignmentCenter;
                    label.numberOfLines = 1;
                    [((UIViewController *)self).view addSubview:label];
                    
                    [NSLayoutConstraint activateConstraints:@[
                        [label.topAnchor constraintEqualToAnchor:((UIViewController *)self).view.safeAreaLayoutGuide.topAnchor constant:10],
                        [label.centerXAnchor constraintEqualToAnchor:((UIViewController *)self).view.centerXAnchor],
                        [label.widthAnchor constraintGreaterThanOrEqualToConstant:120],
                        [label.heightAnchor constraintEqualToConstant:30]
                    ]];
                    
                    objc_setAssociatedObject(self, &visitorLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    NSLog(@"AirChatPlus v3: Added visitor label to %@", className);
                }
                label.text = [NSString stringWithFormat:@"\U0001F440 访客人数: %@", visitorCount];
                label.hidden = NO;
            }
        }
    }
}

// ============================================================
// 2. Hook NSURLSession dataTaskWithRequest:completionHandler:
// ============================================================
typedef void (^DataTaskCompletion)(NSData *, NSURLResponse *, NSError *);

static NSURLSessionDataTask *(*orig_dataTaskWithRequestCompletion)(id, SEL, NSURLRequest *, DataTaskCompletion);
static NSURLSessionDataTask *new_dataTaskWithRequestCompletion(id self, SEL _cmd, NSURLRequest *request, DataTaskCompletion completion) {
    NSMutableURLRequest *mReq = [request mutableCopy];
    NSString *urlString = request.URL.absoluteString;
    
    if ([urlString rangeOfString:@"rank" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:mReq.URL resolvingAgainstBaseURL:NO];
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
        NSLog(@"AirChatPlus v3: Modified rank pageSize=500, URL=%@", mReq.URL);
    }
    
    return orig_dataTaskWithRequestCompletion(self, _cmd, mReq, completion);
}

// ============================================================
// 3. 入口
// ============================================================
__attribute__((constructor))
static void initialize(void) {
    @autoreleasepool {
        NSLog(@"AirChatPlus v3 loaded!");
        
        Class hookClass = [AirChatPlusHook class];
        
        // Hook UIViewController viewDidAppear:
        Class vcClass = [UIViewController class];
        SEL vdSel = @selector(viewDidAppear:);
        Method origM = class_getInstanceMethod(vcClass, vdSel);
        Method newM = class_getInstanceMethod(hookClass, @selector(acp_viewDidAppear:));
        if (origM && newM) {
            orig_viewDidAppear = (void *)method_getImplementation(origM);
            method_setImplementation(origM, method_getImplementation(newM));
            NSLog(@"AirChatPlus v3: Hooked UIViewController viewDidAppear:");
        } else {
            NSLog(@"AirChatPlus v3: Failed to hook viewDidAppear:");
        }
        
        // Hook NSURLSession
        Class sessionClass = [NSURLSession class];
        SEL dataSel = @selector(dataTaskWithRequest:completionHandler:);
        Method origData = class_getInstanceMethod(sessionClass, dataSel);
        Method newData = class_getInstanceMethod(hookClass, @selector(acp_dataTaskWithRequest:completionHandler:));
        if (origData && newData) {
            orig_dataTaskWithRequestCompletion = (void *)method_getImplementation(origData);
            method_setImplementation(origData, method_getImplementation(newData));
            NSLog(@"AirChatPlus v3: Hooked NSURLSession");
        } else {
            NSLog(@"AirChatPlus v3: Failed to hook NSURLSession");
        }
        
        // 启动弹窗
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AirChatPlus 已注入"
                                                                           message:@"访客人数显示 & 排行榜突破已启用"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
            if (rootVC) {
                [rootVC presentViewController:alert animated:YES completion:nil];
            }
        });
        
        NSLog(@"AirChatPlus v3: All hooks initialized");
    }
}
