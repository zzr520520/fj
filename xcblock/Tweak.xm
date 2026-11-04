#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 小蚕惠生活 开屏/插屏广告跳过（纯净 dylib：不依赖 CydiaSubstrate）
// v4：除了「类名识别」外，增加
//   1) viewWillAppear / viewDidAppear 双钩子（覆盖只实现 willAppear 或未调用 super 的页面）
//   2) 启动后 10 秒内遍历所有窗口，自动点击「跳过 / Skip」按钮
//   3) 递归检查 rootViewController 与 presentedViewController 链
//   4) 扩充广告域名拦截

static NSTimeInterval XCLaunchTime = 0;

static BOOL XCIsSplashClass(NSString *name) {
    if (name.length == 0) return NO;
    NSString *lower = name.lowercaseString;
    if ([lower containsString:@"splash"]) return YES;
    if ([lower containsString:@"launchad"]) return YES;
    if ([lower containsString:@"launch"] && ![lower containsString:@"launchutil"]) return YES;
    if ([lower containsString:@"advert"]) return YES;
    if ([lower containsString:@"adviewcontroller"] || [lower containsString:@"adpage"]) return YES;
    if ([lower containsString:@"interstitial"]) return YES;
    return NO;
}

#pragma mark - 广告域名拦截

@interface XCAdURLProtocol : NSURLProtocol
@end

@implementation XCAdURLProtocol

+ (NSArray<NSString *> *)blockedDomains {
    static NSArray<NSString *> *domains = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        domains = @[
            @"leadmoad.com", @"adbiding.com", @"tobidad.cn", @"sigmob.cn",
            @"pglstatp-toutiao.com", @"ctobsnssdk.com", @"oceanengine.com",
            @"bdurl.net", @"gdt.qq.com", @"e.qq.com", @"ugdtimg.com",
            @"tdid.m.qq.com", @"mobads.baidu.com", @"als.baidu.com",
            @"wn.pos.baidu.com", @"bcebos.com", @"mentamob.com", @"advlion.com",
            @"vlion.cn", @"beizi.biz", @"adn-plus.com.cn", @"ad-scope.com.cn",
            @"zhangyuyidong.cn", @"hubcloud.com.cn", @"adintl.cn", @"1rtb.net",
            @"1rtb.com", @"fancydsp.com", @"fancyapi.com", @"yunxish.com",
            @"58iclick.com", @"iggrowth.cn", @"innotechx.com", @"dmrtb.com",
            @"richmob.cn", @"shunchangzhixing.com", @"ubixioe.com", @"xwpbj.com",
            @"baihemob.com", @"etoolads.cn", @"tanx.com", @"fibo.cn",
            @"windmill", @"windmill-sdk", @"msad", @"octopus", @"youtui",
            @"csjprotocol.com", @"ksad", @"kuaishou.com/ad", @"gdtimg.com",
            @"pangolin-sdk", @"admaster.com.cn", @"miaozhen.com", @"sensortower",
            @"applovin.com", @"unityads", @"vungle.com", @"chartboost.com"
        ];
    });
    return domains;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *host = request.URL.host.lowercaseString;
    if (host.length == 0) return NO;
    if ([NSURLProtocol propertyForKey:@"XCAdBlocked" inRequest:request]) return NO;
    for (NSString *domain in [self blockedDomains]) {
        if ([host containsString:domain]) return YES;
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *req = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"XCAdBlocked" inRequest:req];
    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                          statusCode:404
                                                         HTTPVersion:@"HTTP/1.1"
                                                        headerFields:@{ @"Content-Length": @"0" }];
    [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[NSData data]];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}

+ (NSArray *)ac_injectIntoProtocols:(NSArray *)protocols {
    NSMutableArray *arr = protocols ? [protocols mutableCopy] : [NSMutableArray array];
    if (![arr containsObject:[self class]]) {
        [arr insertObject:[self class] atIndex:0];
    }
    return arr;
}

@end

#pragma mark - 跳过 / 自动点击

static void XCInvokeVoidSelector(id obj, NSString *selName, BOOL withNilArg) {
    if (!obj || selName.length == 0) return;
    SEL sel = NSSelectorFromString(selName);
    if (![obj respondsToSelector:sel]) return;
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    if (!sig) return;
    NSUInteger want = withNilArg ? 3 : 2;
    if (sig.numberOfArguments != want) return;
    IMP imp = [obj methodForSelector:sel];
    @try {
        if (withNilArg) {
            ((void (*)(id, SEL, id))imp)(obj, sel, nil);
        } else {
            ((void (*)(id, SEL))imp)(obj, sel);
        }
    } @catch (NSException *e) {}
}

static void XCSkipSplashViewController(UIViewController *vc) {
    if (!vc) return;
    NSArray<NSString *> *noArgSelectors = @[
        @"splashSkipClick", @"skipSplash", @"skipAd", @"skip",
        @"closeAd", @"closeSplash", @"dismissSplash", @"finishSplash", @"hide"
    ];
    for (NSString *sel in noArgSelectors) {
        if ([vc respondsToSelector:NSSelectorFromString(sel)]) {
            XCInvokeVoidSelector(vc, sel, NO);
            return;
        }
    }
    NSArray<NSString *> *oneArgSelectors = @[
        @"splashSkipClick:", @"skipAd:", @"dismissSplash:", @"closeAd:"
    ];
    for (NSString *sel in oneArgSelectors) {
        if ([vc respondsToSelector:NSSelectorFromString(sel)]) {
            XCInvokeVoidSelector(vc, sel, YES);
            return;
        }
    }
    if (vc.presentingViewController) {
        [vc dismissViewControllerAnimated:NO completion:nil];
    } else if (vc.parentViewController) {
        [vc willMoveToParentViewController:nil];
        [vc.view removeFromSuperview];
        [vc removeFromParentViewController];
    }
}

// 递归点击「跳过 / Skip」按钮（广告 SDK 自绘页面通常都有）
static BOOL XCTapSkipButtonInView(UIView *view, NSInteger depth) {
    if (!view || depth > 24) return NO;
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        NSString *title = [btn titleForState:UIControlStateNormal];
        if (!title.length) title = btn.currentTitle;
        if (!title.length) title = btn.titleLabel.text;
        NSString *lower = title.lowercaseString;
        if (title.length > 0 && ([title containsString:@"跳过"] || [lower containsString:@"skip"])) {
            [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
    }
    for (UIView *sub in view.subviews) {
        if (XCTapSkipButtonInView(sub, depth + 1)) return YES;
    }
    return NO;
}

static void XCTapSkipButtonsInWindows(void) {
    for (UIWindow *win in [UIApplication sharedApplication].windows) {
        if (!win.hidden && win.alpha > 0.01) {
            XCTapSkipButtonInView(win, 0);
        }
    }
}

static void XCHandleViewController(UIViewController *vc) {
    if (!vc) return;
    if (XCIsSplashClass(NSStringFromClass([vc class]))) {
        XCSkipSplashViewController(vc);
    }
    UIViewController *presented = vc.presentedViewController;
    while (presented) {
        if (XCIsSplashClass(NSStringFromClass([presented class]))) {
            XCSkipSplashViewController(presented);
        }
        presented = presented.presentedViewController;
    }
}

#pragma mark - Runtime 挂载

static void (*XC_orig_viewDidAppear)(id, SEL, BOOL) = NULL;
static void (*XC_orig_viewWillAppear)(id, SEL, BOOL) = NULL;
static void (*XC_orig_presentVC)(id, SEL, UIViewController *, BOOL, void (^)(void)) = NULL;

static void XC_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (XC_orig_viewDidAppear) XC_orig_viewDidAppear(self, _cmd, animated);
    NSString *cls = NSStringFromClass([self class]);
    if (XCIsSplashClass(cls)) {
        UIViewController *vc = (UIViewController *)self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XCSkipSplashViewController(vc);
        });
    }
}

static void XC_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (XC_orig_viewWillAppear) XC_orig_viewWillAppear(self, _cmd, animated);
    if (XCIsSplashClass(NSStringFromClass([self class]))) {
        UIViewController *vc = (UIViewController *)self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XCSkipSplashViewController(vc);
        });
    }
}

static void XC_presentViewController(id self, SEL _cmd, UIViewController *vcToPresent, BOOL animated, void (^completion)(void)) {
    // 启动 10 秒内，广告 / 开屏类控制器直接不呈现
    if (vcToPresent && ([[NSDate date] timeIntervalSince1970] - XCLaunchTime < 10.0) &&
        XCIsSplashClass(NSStringFromClass([vcToPresent class]))) {
        if (completion) completion();
        return;
    }
    if (XC_orig_presentVC) {
        XC_orig_presentVC(self, _cmd, vcToPresent, animated, completion);
    }
}

static id (*XC_orig_defaultConfig)(id, SEL) = NULL;
static id XC_defaultConfig(id self, SEL _cmd) {
    id cfg = XC_orig_defaultConfig ? XC_orig_defaultConfig(self, _cmd) : nil;
    if (cfg) {
        [cfg setProtocolClasses:[XCAdURLProtocol ac_injectIntoProtocols:[cfg protocolClasses]]];
    }
    return cfg;
}

static id (*XC_orig_ephemeralConfig)(id, SEL) = NULL;
static id XC_ephemeralConfig(id self, SEL _cmd) {
    id cfg = XC_orig_ephemeralConfig ? XC_orig_ephemeralConfig(self, _cmd) : nil;
    if (cfg) {
        [cfg setProtocolClasses:[XCAdURLProtocol ac_injectIntoProtocols:[cfg protocolClasses]]];
    }
    return cfg;
}

static void XCInstallHooks(void) {
    Class vcCls = [UIViewController class];
    Method mDid = class_getInstanceMethod(vcCls, @selector(viewDidAppear:));
    if (mDid) {
        XC_orig_viewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(mDid);
        method_setImplementation(mDid, (IMP)XC_viewDidAppear);
    }
    Method mWill = class_getInstanceMethod(vcCls, @selector(viewWillAppear:));
    if (mWill) {
        XC_orig_viewWillAppear = (void (*)(id, SEL, BOOL))method_getImplementation(mWill);
        method_setImplementation(mWill, (IMP)XC_viewWillAppear);
    }
    Method mPresent = class_getInstanceMethod(vcCls, @selector(presentViewController:animated:completion:));
    if (mPresent) {
        XC_orig_presentVC = (void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))method_getImplementation(mPresent);
        method_setImplementation(mPresent, (IMP)XC_presentViewController);
    }
    Class cfgCls = [NSURLSessionConfiguration class];
    Method m2 = class_getClassMethod(cfgCls, @selector(defaultSessionConfiguration));
    if (m2) {
        XC_orig_defaultConfig = (id (*)(id, SEL))method_getImplementation(m2);
        method_setImplementation(m2, (IMP)XC_defaultConfig);
    }
    Method m3 = class_getClassMethod(cfgCls, @selector(ephemeralSessionConfiguration));
    if (m3) {
        XC_orig_ephemeralConfig = (id (*)(id, SEL))method_getImplementation(m3);
        method_setImplementation(m3, (IMP)XC_ephemeralConfig);
    }
}

__attribute__((constructor)) static void XCInitialize(void) {
    @autoreleasepool {
        XCLaunchTime = [[NSDate date] timeIntervalSince1970];
        XCInstallHooks();
        // 启动后 10 秒内：每 0.2 秒巡检窗口，跳过开屏控制器 + 自动点「跳过」
        for (NSInteger i = 1; i <= 50; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                XCTapSkipButtonsInWindows();
                for (UIWindow *win in [UIApplication sharedApplication].windows) {
                    if (!win.hidden) XCHandleViewController(win.rootViewController);
                }
            });
        }
    }
}
