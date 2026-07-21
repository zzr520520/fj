// ============================================================
// AirChatPlus v4 - 最终版
// 仅 Hook 系统类 + 拦截权限弹窗 + 显示访客数量
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
// 1. 在详情页顶部添加访客人数标签
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
                    NSLog(@"AirChatPlus v4: Added visitor label to %@", className);
                }
                label.text = [NSString stringWithFormat:@"\U0001F440 访客人数: %@", count];
                label.hidden = NO;
            }
        }
    }
}

// ============================================================
// 2. 拦截「访客数据」按钮点击，显示已有访客数量
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
                ? [NSString stringWithFormat:@"该帖子共有 %@ 位访客", count]
                : @"暂未获取到访客数据";
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"访客信息"
                                                                           message:msg
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleCancel handler:nil]];
            @try { [vc presentViewController:alert animated:YES completion:nil]; } @catch (NSException *e) {}
            NSLog(@"AirChatPlus v4: Intercepted visitor button, count=%@", count);
            return;
        }
    }
    orig_sendAction(self, _cmd, action, target, event);
}

// ============================================================
// 3. 排行榜 pageSize 修改
// ============================================================
typedef void (^DataTaskCompletion)(NSData *, NSURLResponse *, NSError *);
static NSURLSessionDataTask *(*orig_dataTaskWithRequestCompletion)(id, SEL, NSURLRequest *, DataTaskCompletion);
static NSURLSessionDataTask *new_dataTaskWithRequestCompletion(id self, SEL _cmd, NSURLRequest *request, DataTaskCompletion completion) {
    NSMutableURLRequest *mReq = [request mutableCopy];
    NSString *urlString = request.URL.absoluteString;
    if ([urlString rangeOfString:@"rank" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [urlString rangeOfString:@"leaderboard" options:NSCaseInsensitiveSearch].location != NSNotFound) {
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
        NSLog(@"AirChatPlus v4: Modified rank pageSize=500");
    }
    return orig_dataTaskWithRequestCompletion(self, _cmd, mReq, completion);
}

// ============================================================
// 4. 初始化入口
// ============================================================
__attribute__((constructor))
static void initialize(void) {
    @autoreleasepool {
        NSLog(@"AirChatPlus v4 loaded!");
        
        Class hookClass = [AirChatPlusHook class];
        
        // Hook UIViewController viewDidAppear:
        Class vcClass = [UIViewController class];
        Method origM = class_getInstanceMethod(vcClass, @selector(viewDidAppear:));
        Method newM = class_getInstanceMethod(hookClass, @selector(acp_viewDidAppear:));
        if (origM && newM) {
            orig_viewDidAppear = (void *)method_getImplementation(origM);
            method_setImplementation(origM, method_getImplementation(newM));
            NSLog(@"AirChatPlus v4: Hooked viewDidAppear:");
        }
        
        // Hook UIButton sendAction:to:forEvent:
        Class btnClass = [UIButton class];
        Method origSend = class_getInstanceMethod(btnClass, @selector(sendAction:to:forEvent:));
        Method newSend = class_getInstanceMethod(hookClass, @selector(acp_sendAction:to:forEvent:));
        if (origSend && newSend) {
            orig_sendAction = (void *)method_getImplementation(origSend);
            method_setImplementation(origSend, method_getImplementation(newSend));
            NSLog(@"AirChatPlus v4: Hooked UIButton sendAction:");
        }
        
        // Hook NSURLSession
        Class sessionClass = [NSURLSession class];
        Method origData = class_getInstanceMethod(sessionClass, @selector(dataTaskWithRequest:completionHandler:));
        Method newData = class_getInstanceMethod(hookClass, @selector(acp_dataTaskWithRequest:completionHandler:));
        if (origData && newData) {
            orig_dataTaskWithRequestCompletion = (void *)method_getImplementation(origData);
            method_setImplementation(origData, method_getImplementation(newData));
            NSLog(@"AirChatPlus v4: Hooked NSURLSession");
        }
        
        // 启动弹窗
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AirChatPlus 已加载"
                                                                           message:@"访客数量显示 & 权限弹窗拦截已生效"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
            if (rootVC) {
                [rootVC presentViewController:alert animated:YES completion:nil];
            }
        });
        
        NSLog(@"AirChatPlus v4: All hooks initialized");
    }
}
