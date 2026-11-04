#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 小蚕惠生活 开屏页跳过（纯净 dylib 版：不依赖 CydiaSubstrate，可随 IPA 重签）
// 说明：上一版用 Theos 构建，会自动链接 CydiaSubstrate，在未越狱设备上 dyld 直接
// 报 "Library not loaded: /Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate" 闪退。
// 本版全部改用 Objective-C Runtime 动态挂载，仅依赖 UIKit/Foundation。

static BOOL XCIsSplashClass(NSString *name) {
    if (name.length == 0) return NO;
    NSString *lower = [name lowercaseString];
    if ([lower containsString:@"splash"] || [lower containsString:@"launchad"]) return YES;
    if ([lower containsString:@"launch"] && ![lower containsString:@"launchutil"]) return YES;
    return NO;
}

#pragma mark - 广告域名拦截（返回 404，避免开屏素材与二次跳转）

@interface XCAdURLProtocol : NSURLProtocol
@end

@implementation XCAdURLProtocol

+ (NSArray<NSString *> *)blockedDomains {
    static NSArray<NSString *> *domains = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        domains = @[
            @"leadmoad.com", @"adbiding.com", @"tobidad.cn", @"sigmob.cn",
            @"pangolin-sdk-toutiao", @"pglstatp-toutiao.com", @"ctobsnssdk.com",
            @"oceanengine.com", @"bdurl.net", @"gdt.qq.com", @"e.qq.com",
            @"ugdtimg.com", @"tdid.m.qq.com", @"mobads.baidu.com",
            @"mobads-logs.baidu.com", @"als.baidu.com", @"wn.pos.baidu.com",
            @"bcebos.com", @"mentamob.com", @"advlion.com", @"vlion.cn",
            @"beizi.biz", @"adn-plus.com.cn", @"ad-scope.com.cn",
            @"zhangyuyidong.cn", @"hubcloud.com.cn", @"adintl.cn", @"1rtb.net",
            @"1rtb.com", @"fancydsp.com", @"fancyapi.com", @"yunxish.com",
            @"58iclick.com", @"iggrowth.cn", @"innotechx.com", @"dmrtb.com",
            @"richmob.cn", @"shunchangzhixing.com", @"ubixioe.com", @"xwpbj.com",
            @"baihemob.com", @"etoolads.cn", @"tanx.com", @"fibo.cn"
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

#pragma mark - 跳过开屏控制器

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

#pragma mark - Runtime 挂载

static void (*XC_orig_viewDidAppear)(id, SEL, BOOL) = NULL;

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
    Method m1 = class_getInstanceMethod(vcCls, @selector(viewDidAppear:));
    if (m1) {
        XC_orig_viewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(m1);
        method_setImplementation(m1, (IMP)XC_viewDidAppear);
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
        XCInstallHooks();
        // 启动后 3 秒内持续巡检窗口根控制器，兜底跳过延迟出现的开屏
        for (NSInteger i = 1; i <= 6; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                for (UIWindow *win in [UIApplication sharedApplication].windows) {
                    UIViewController *vc = win.rootViewController;
                    if (XCIsSplashClass(NSStringFromClass([vc class]))) {
                        XCSkipSplashViewController(vc);
                    }
                }
            });
        }
    }
}
