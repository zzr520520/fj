#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// 小蚕惠生活 开屏广告拦截 + 秒进
// 替换原包内 @executable_path/XCNoAdJump.dylib（保持同名、同加载路径）
// 思路：
//  1) 广告域名网络层直接返回 404，阻断开屏素材（沿用原包的拦截清单）
//  2) 拦截所有类名含 Splash/LaunchAd 的控制器：出现后 0.1 秒立即调用跳过/关闭
//  3) 常见聚合广告 SDK 的 show/present 方法置空，避免任何开屏/插屏被展示

static BOOL XCIsSplashClass(NSString *name) {
    if (name.length == 0) return NO;
    NSString *lower = [name lowercaseString];
    return [lower containsString:@"splash"] || [lower containsString:@"launchad"];
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
    // 兜底：模态的直接关掉；作为子控制器的移除
    if (vc.presentingViewController) {
        [vc dismissViewControllerAnimated:NO completion:nil];
    } else if (vc.parentViewController) {
        [vc willMoveToParentViewController:nil];
        [vc.view removeFromSuperview];
        [vc removeFromParentViewController];
    }
}

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *cls = NSStringFromClass([self class]);
    if (XCIsSplashClass(cls)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XCSkipSplashViewController(self);
        });
    }
}

%end

#pragma mark - 聚合广告 SDK 展示方法置空

static void XCNoopIMP(id self, SEL _cmd) {}

static void XCNoopShowMethods(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return;
    for (unsigned int i = 0; i < count; i++) {
        Method m = methods[i];
        const char *types = method_getTypeEncoding(m);
        if (!types || types[0] != 'v') continue; // 只清空 void 方法，避免返回值错乱
        NSString *selName = NSStringFromSelector(method_getName(m));
        NSString *lower = selName.lowercaseString;
        if ([lower hasPrefix:@"show"] || [lower hasPrefix:@"present"]) {
            method_setImplementation(m, (IMP)XCNoopIMP);
        }
    }
    free(methods);
}

static void XCApplySDKHooks(void) {
    NSArray<NSString *> *classes = @[
        @"AdScopeADNSplashAd", @"CXHAdSDKSplashAd", @"CXHChannelSplashAd",
        @"AdbidSplashAd", @"ABUSplashAd", @"ABUSplashAdLoader",
        @"BTPSplashAdHelper", @"AdSplash", @"AdSplashBU", @"AdSplashMS", @"AdSplashWM",
        @"MSSplashAdViewController", @"CSJSplashAd", @"GDTSplashAd",
        @"KSAdSplashManager", @"QMSplashAd", @"OctSplashAd", @"MSAdSplash",
        @"BeiZiSplash", @"WindSplashAdManager", @"WindMillSplashAdManager",
        @"YTSplashViewController", @"SCCSJSplashViewController",
        @"WindMillSDK.WindMillSplashAdManager", @"WindMillSDK.TB1WithSplashAdManager",
        @"_TtC11WindMillSDK22WindMillSplashAdManager",
        @"_TtC11WindMillSDK22TB1WithSplashAdManager",
        @"_TtC7LynxAds15SplashAdManager"
    ];
    for (NSString *cls in classes) {
        XCNoopShowMethods(cls);
    }
}

%hook NSURLSessionConfiguration

+ (instancetype)defaultSessionConfiguration {
    id cfg = %orig;
    [cfg setProtocolClasses:[XCAdURLProtocol ac_injectIntoProtocols:[cfg protocolClasses]]];
    return cfg;
}

+ (instancetype)ephemeralSessionConfiguration {
    id cfg = %orig;
    [cfg setProtocolClasses:[XCAdURLProtocol ac_injectIntoProtocols:[cfg protocolClasses]]];
    return cfg;
}

%end

%ctor {
    @autoreleasepool {
        XCApplySDKHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XCApplySDKHooks();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XCApplySDKHooks();
        });
    }
}
