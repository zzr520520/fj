#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 小蚕惠生活 开屏页处理 v5（诊断版）
// - 继续自动跳过 splash / launch / ad 类控制器
// - 继续拦截广告域名
// - 新增：启动后屏幕下方显示「诊断浮层」，列出出现的控制器类名、窗口类名、
//   可疑图片名与网络请求路径。请安装后打开 App 等待约 10 秒，截图该浮层发回。

static NSTimeInterval XCLaunchTime = 0;
static NSMutableArray<NSString *> *XCLogLines = nil;
static UITextView *XCOverlay = nil;
static NSLock *XCLock = nil;

static void XCRefreshOverlay(void) {
    if (!XCOverlay) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *lines = [XCLogLines copy];
        NSMutableString *text = [NSMutableString stringWithString:@"【诊断】请截图此区域发回\n"];
        NSInteger start = MAX(0, (NSInteger)lines.count - 26);
        for (NSInteger i = start; i < (NSInteger)lines.count; i++) {
            [text appendFormat:@"%@\n", lines[(NSUInteger)i]];
        }
        XCOverlay.text = text;
    });
}

static void XCLog(NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        if (!XCLogLines) {
            XCLogLines = [NSMutableArray array];
            XCLock = [[NSLock alloc] init];
        }
        NSString *line = [NSString stringWithFormat:@"%.1fs %@", [[NSDate date] timeIntervalSince1970] - XCLaunchTime, msg];
        [XCLock lock];
        [XCLogLines addObject:line];
        if (XCLogLines.count > 200) [XCLogLines removeObjectAtIndex:0];
        [XCLock unlock];
        NSLog(@"[XCAd] %@", line);
        XCRefreshOverlay();
    }
}

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
            @"windmill", @"msad", @"octopus", @"youtui",
            @"csjprotocol.com", @"ksad", @"gdtimg.com",
            @"pangolin-sdk", @"gromore", @"pangolin", @"pangle",
            @"admaster.com.cn", @"miaozhen.com",
            @"applovin.com", @"unityads", @"vungle.com", @"chartboost.com"
        ];
    });
    return domains;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *host = request.URL.host.lowercaseString;
    NSString *path = request.URL.path.lowercaseString;
    if (host.length == 0) return NO;
    if ([NSURLProtocol propertyForKey:@"XCAdBlocked" inRequest:request]) return NO;
    // 路径命中开屏广告素材 / 配置（不动普通业务接口）
    if ([path containsString:@"splash"] || [path containsString:@"openscreen"] ||
        [path containsString:@"launchad"] || [path containsString:@"boot_ad"]) {
        return YES;
    }
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

#pragma mark - 配置 JSON 重写（剥掉 Kuikly/KMP 开屏字段）

static BOOL XCIsConfigHost(NSString *host) {
    NSString *h = host.lowercaseString;
    return ([h containsString:@"realtech-inc.com"] || [h containsString:@"xinyifm.cn"]);
}

static BOOL XCIsConfigPath(NSString *path) {
    NSString *p = path.lowercaseString;
    return ([p containsString:@"/configs/"] || [p hasSuffix:@".json"] || [p hasSuffix:@".jso"]);
}

static BOOL XCIsSplashKey(NSString *key) {
    NSString *k = key.lowercaseString;
    return ([k containsString:@"splash"] || [k containsString:@"openscreen"] ||
            [k containsString:@"open_screen"] || [k containsString:@"launchad"] ||
            [k containsString:@"launch_ad"] || [k containsString:@"ad_screen"] ||
            [k containsString:@"boot_ad"] || [k containsString:@"bootad"] ||
            [k containsString:@"start_ad"] || [k containsString:@"startad"] ||
            [k containsString:@"new_user"] || [k containsString:@"newuser"] ||
            [k containsString:@"popup"] || [k containsString:@"first_head"] ||
            [k containsString:@"newcomer"] || [k containsString:@"redpacket"] ||
            [k containsString:@"red_packet"] || [k containsString:@"activity_pop"]);
}

static NSInteger XCStripSplashFromObject(id obj, NSInteger depth) {
    if (depth > 12 || !obj) return 0;
    NSInteger removed = 0;
    if ([obj isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *dict = (NSMutableDictionary *)obj;
        for (NSString *key in [dict allKeys]) {
            if ([key isKindOfClass:[NSString class]] && XCIsSplashKey(key)) {
                [dict removeObjectForKey:key];
                removed++;
            } else {
                removed += XCStripSplashFromObject(dict[key], depth + 1);
            }
        }
        return removed;
    }
    if ([obj isKindOfClass:[NSMutableArray class]]) {
        for (id sub in (NSArray *)obj) removed += XCStripSplashFromObject(sub, depth + 1);
        return removed;
    }
    return 0;
}

@interface XCConfigRewriteProtocol : NSURLProtocol
@end

@implementation XCConfigRewriteProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:@"XCRewriteMark" inRequest:request]) return NO;
    if (!XCIsConfigHost(request.URL.host)) return NO;
    if (!XCIsConfigPath(request.URL.path ?: @"") && !XCIsConfigPath(request.URL.absoluteString ?: @"")) return NO;
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:self.request.URL];
    req.HTTPMethod = self.request.HTTPMethod;
    req.timeoutInterval = 10.0;
    [NSURLProtocol setProperty:@YES forKey:@"XCRewriteMark" inRequest:req];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            [weakSelf.client URLProtocol:weakSelf didFailWithError:error ?: [NSError errorWithDomain:@"XC" code:-1 userInfo:nil]];
            return;
        }
        NSData *outData = data;
        @try {
            id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
            if (json) {
                if ([json isKindOfClass:[NSDictionary class]]) {
                    NSArray *keys = [(NSDictionary *)json allKeys];
                    NSString *preview = [keys count] > 12 ? [[keys subarrayWithRange:NSMakeRange(0, 12)] componentsJoinedByString:@","] : [keys componentsJoinedByString:@","];
                    XCLog(@"cfg %@ keys: %@", self.request.URL.lastPathComponent, preview);
                }
                NSInteger removed = XCStripSplashFromObject(json, 0);
                if (removed > 0) {
                    NSData *newData = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
                    if (newData) {
                        outData = newData;
                        XCLog(@"cfg %@ 剥除字段 %ld 个", self.request.URL.lastPathComponent, (long)removed);
                    }
                }
            }
        } @catch (NSException *e) {}
        NSHTTPURLResponse *httpResp = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSDictionary *headers = httpResp.allHeaderFields ?: @{};
        NSHTTPURLResponse *newResp = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                                statusCode:httpResp ? httpResp.statusCode : 200
                                                               HTTPVersion:@"HTTP/1.1"
                                                              headerFields:headers];
        [weakSelf.client URLProtocol:weakSelf didReceiveResponse:newResp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [weakSelf.client URLProtocol:weakSelf didLoadData:outData];
        [weakSelf.client URLProtocolDidFinishLoading:weakSelf];
    }] resume];
}

- (void)stopLoading {}

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
            XCLog(@"skip %@ via %@", NSStringFromClass([vc class]), sel);
            XCInvokeVoidSelector(vc, sel, NO);
            return;
        }
    }
    if (vc.presentingViewController) {
        XCLog(@"dismiss presented %@", NSStringFromClass([vc class]));
        [vc dismissViewControllerAnimated:NO completion:nil];
    } else if (vc.parentViewController) {
        XCLog(@"remove child %@", NSStringFromClass([vc class]));
        [vc willMoveToParentViewController:nil];
        [vc.view removeFromSuperview];
        [vc removeFromParentViewController];
    }
}

static BOOL XCTapSkipButtonInView(UIView *view, NSInteger depth) {
    if (!view || depth > 24) return NO;
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        NSString *title = [btn titleForState:UIControlStateNormal];
        if (!title.length) title = btn.currentTitle;
        if (!title.length) title = btn.titleLabel.text;
        NSString *lower = title.lowercaseString;
        if (title.length > 0 && ([title containsString:@"跳过"] || [lower containsString:@"skip"])) {
            XCLog(@"tap skip button '%@'", title);
            [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
    }
    for (UIView *sub in view.subviews) {
        if (XCTapSkipButtonInView(sub, depth + 1)) return YES;
    }
    return NO;
}

static NSArray<UIWindow *> *XCAllWindows(void) {
    NSMutableArray *arr = [NSMutableArray array];
    @try {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w) [arr addObject:w];
            }
        }
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (![arr containsObject:w]) [arr addObject:w];
        }
    } @catch (NSException *e) {}
    return arr;
}

static void XCTapSkipButtonsInWindows(void) {
    for (UIWindow *win in XCAllWindows()) {
        if (!win.hidden && win.alpha > 0.01) {
            XCTapSkipButtonInView(win, 0);
        }
    }
}

// 启动阶段强制隐藏全屏图片 / SVGA 播放视图（新人红包开屏由原生图片+SVGA 构成）
static void XCHideSplashLayersInView(UIView *view, CGFloat sw, CGFloat sh, NSInteger depth) {
    if (!view || depth > 12) return;
    for (UIView *sub in view.subviews) {
        CGRect f = sub.frame;
        NSString *lower = NSStringFromClass([sub class]).lowercaseString;
        BOOL bigImage = [sub isKindOfClass:[UIImageView class]] && f.size.width >= sw * 0.85 && f.size.height >= sh * 0.5;
        BOOL svgaLike = ([lower containsString:@"svga"] || [lower containsString:@"yyanimated"] || [lower containsString:@"lottie"]);
        if (bigImage || svgaLike) {
            if (!sub.hidden || sub.alpha > 0.01) {
                XCLog(@"hide layer %@ %.0fx%.0f", NSStringFromClass([sub class]), f.size.width, f.size.height);
            }
            sub.hidden = YES;
            sub.alpha = 0;
        }
        XCHideSplashLayersInView(sub, sw, sh, depth + 1);
    }
}

static void XCHideSplashLayersInWindows(void) {
    UIWindow *key = nil;
    for (UIWindow *w in XCAllWindows()) if (w.isKeyWindow) { key = w; break; }
    CGFloat sw = key ? key.bounds.size.width : 430, sh = key ? key.bounds.size.height : 932;
    for (UIWindow *w in XCAllWindows()) {
        XCHideSplashLayersInView(w, sw, sh, 0);
    }
}

// 移除原生开屏广告视图（GroMore/穿山甲 BUSplashAdView 等，它们是 UIView 而非 VC）
static BOOL XCRemoveSplashViewsInView(UIView *view, NSInteger depth) {
    if (!view || depth > 18) return NO;
    BOOL removed = NO;
    for (UIView *sub in [view.subviews copy]) {
        NSString *lower = NSStringFromClass([sub class]).lowercaseString;
        BOOL splashLike = ([lower containsString:@"splash"] || [lower containsString:@"busplash"] ||
                           [lower containsString:@"csjsplash"] || [lower containsString:@"gmsplash"]);
        if (splashLike) {
            XCLog(@"remove splash view %@", NSStringFromClass([sub class]));
            [sub removeFromSuperview];
            removed = YES;
            continue;
        }
        if (XCRemoveSplashViewsInView(sub, depth + 1)) removed = YES;
    }
    return removed;
}

static void XCRemoveSplashViewsInWindows(void) {
    for (UIWindow *win in XCAllWindows()) {
        if (win.hidden || win.alpha < 0.01) continue;
        XCRemoveSplashViewsInView(win, 0);
    }
}

#pragma mark - Runtime 挂载

static void XCHideFullScreenImagesInView(UIView *view, NSInteger depth, CGFloat sw, CGFloat sh) {
    if (!view) return;
    for (UIView *sub in view.subviews) {
        CGRect f = sub.frame;
        if ([sub isKindOfClass:[UIImageView class]] && f.size.width >= sw * 0.6 && f.size.height >= sh * 0.25) {
            sub.hidden = YES;
            sub.alpha = 0;
            XCLog(@"hide img %@ %.0fx%.0f", NSStringFromClass([sub class]), f.size.width, f.size.height);
        }
        if (depth < 2) XCHideFullScreenImagesInView(sub, depth + 1, sw, sh);
    }
}

static void XCDumpHomeSceneTree(UIViewController *vc) {
    CGFloat sw = vc.view.bounds.size.width;
    CGFloat sh = vc.view.bounds.size.height;
    NSMutableString *sb = [NSMutableString string];
    for (UIView *sub in vc.view.subviews) {
        [sb appendFormat:@"%@(%.0fx%.0f) ", NSStringFromClass([sub class]), sub.frame.size.width, sub.frame.size.height];
    }
    if (sb.length > 0) XCLog(@"homescene sub: %@", sb);
    XCHideFullScreenImagesInView(vc.view, 0, sw, sh);
}

static void (*XC_orig_viewDidAppear)(id, SEL, BOOL) = NULL;
static void (*XC_orig_viewWillAppear)(id, SEL, BOOL) = NULL;
static void (*XC_orig_presentVC)(id, SEL, UIViewController *, BOOL, void (^)(void)) = NULL;

static void XC_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (XC_orig_viewDidAppear) XC_orig_viewDidAppear(self, _cmd, animated);
    NSString *cls = NSStringFromClass([self class]);
    if ([[NSDate date] timeIntervalSince1970] - XCLaunchTime < 20.0) {
        XCLog(@"didAppear %@", cls);
    }
    if (XCIsSplashClass(cls)) {
        UIViewController *vc = (UIViewController *)self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XCSkipSplashViewController(vc);
        });
    }
    if ([cls containsString:@"HomeScene"]) {
        UIViewController *vc = (UIViewController *)self;
        for (NSInteger i = 0; i <= 10; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.1 + 0.2 * i) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                XCDumpHomeSceneTree(vc);
            });
        }
    }
}

static void XC_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (XC_orig_viewWillAppear) XC_orig_viewWillAppear(self, _cmd, animated);
    NSString *cls = NSStringFromClass([self class]);
    if ([[NSDate date] timeIntervalSince1970] - XCLaunchTime < 20.0) {
        XCLog(@"willAppear %@", cls);
    }
    if (XCIsSplashClass(cls)) {
        UIViewController *vc = (UIViewController *)self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XCSkipSplashViewController(vc);
        });
    }
}

static void XC_presentViewController(id self, SEL _cmd, UIViewController *vcToPresent, BOOL animated, void (^completion)(void)) {
    if ([[NSDate date] timeIntervalSince1970] - XCLaunchTime < 20.0) {
        XCLog(@"present %@ (from %@)", NSStringFromClass([vcToPresent class]), NSStringFromClass([self class]));
    }
    if (vcToPresent && ([[NSDate date] timeIntervalSince1970] - XCLaunchTime < 10.0) &&
        XCIsSplashClass(NSStringFromClass([vcToPresent class]))) {
        XCLog(@"block present %@", NSStringFromClass([vcToPresent class]));
        if (completion) completion();
        return;
    }
    if (XC_orig_presentVC) {
        XC_orig_presentVC(self, _cmd, vcToPresent, animated, completion);
    }
}

static id (*XC_orig_imageNamed)(id, SEL, NSString *) = NULL;
static id XC_imageNamed(id self, SEL _cmd, NSString *name) {
    NSString *lower = name.lowercaseString;
    if ([lower containsString:@"splash"] || [lower containsString:@"launch"] ||
        [lower containsString:@"start"] || [lower containsString:@"ad_"] ||
        [lower containsString:@"open"]) {
        XCLog(@"img %@", name);
    }
    return XC_orig_imageNamed ? XC_orig_imageNamed(self, _cmd, name) : nil;
}

static id (*XC_orig_dataTask)(id, SEL, NSURLRequest *) = NULL;
static id XC_dataTask(id self, SEL _cmd, NSURLRequest *request) {
    NSString *urlStr = request.URL.absoluteString;
    NSString *lower = urlStr.lowercaseString;
    if ([lower containsString:@"splash"] || [lower containsString:@"launch"] ||
        [lower containsString:@"start"] || [lower containsString:@"advert"] ||
        [lower containsString:@"openscreen"] || [lower containsString:@"boot"] ||
        [lower containsString:@"qiping"] || [lower containsString:@"config"]) {
        NSString *path = request.URL.path ?: @"";
        if (path.length > 60) path = [path substringToIndex:60];
        XCLog(@"net %@%@", request.URL.host ?: @"", path);
    }
    return XC_orig_dataTask ? XC_orig_dataTask(self, _cmd, request) : nil;
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

static void (*XC_orig_setProtocols)(id, SEL, NSArray *) = NULL;
static void XC_setProtocols(id self, SEL _cmd, NSArray *classes) {
    NSMutableArray *arr = classes ? [classes mutableCopy] : [NSMutableArray array];
    if (![arr containsObject:[XCAdURLProtocol class]]) [arr insertObject:[XCAdURLProtocol class] atIndex:0];
    if (![arr containsObject:[XCConfigRewriteProtocol class]]) [arr insertObject:[XCConfigRewriteProtocol class] atIndex:0];
    if (XC_orig_setProtocols) XC_orig_setProtocols(self, _cmd, arr);
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
    Method mImg = class_getClassMethod([UIImage class], @selector(imageNamed:));
    if (mImg) {
        XC_orig_imageNamed = (id (*)(id, SEL, NSString *))method_getImplementation(mImg);
        method_setImplementation(mImg, (IMP)XC_imageNamed);
    }
    Method mTask = class_getInstanceMethod([NSURLSession class], @selector(dataTaskWithRequest:));
    if (mTask) {
        XC_orig_dataTask = (id (*)(id, SEL, NSURLRequest *))method_getImplementation(mTask);
        method_setImplementation(mTask, (IMP)XC_dataTask);
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
    Method m4 = class_getInstanceMethod(cfgCls, @selector(setProtocolClasses:));
    if (m4) {
        XC_orig_setProtocols = (void (*)(id, SEL, NSArray *))method_getImplementation(m4);
        method_setImplementation(m4, (IMP)XC_setProtocols);
    }
}

static UIWindow *XCOverlayWindow = nil;

static void XCCreateOverlay(void) {
    if (XCOverlay) return;
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *keyWin = nil;
    for (UIWindow *w in app.windows) {
        if (!w.hidden) { keyWin = w; break; }
    }
    if (!keyWin) return;
    if (!XCOverlayWindow) {
        XCOverlayWindow = [[UIWindow alloc] initWithFrame:keyWin.bounds];
        XCOverlayWindow.windowLevel = 5000;
        if (@available(iOS 13.0, *)) {
            XCOverlayWindow.windowScene = keyWin.windowScene;
        }
        XCOverlayWindow.backgroundColor = [UIColor clearColor];
        XCOverlayWindow.hidden = NO;
    }
    CGFloat h = keyWin.bounds.size.height * 0.32;
    CGRect frame = CGRectMake(0, keyWin.bounds.size.height - h, keyWin.bounds.size.width, h);
    XCOverlay = [[UITextView alloc] initWithFrame:frame];
    XCOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
    XCOverlay.textColor = [UIColor greenColor];
    XCOverlay.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    XCOverlay.editable = NO;
    XCOverlay.scrollEnabled = YES;
    XCOverlay.userInteractionEnabled = NO;
    XCOverlay.text = @"【诊断】请截图此区域发回\n";
    [XCOverlayWindow addSubview:XCOverlay];
    XCRefreshOverlay();
}

static void XCScanWindows(void) {
    static NSString *lastWindowDesc = nil;
    static NSString *lastRootDesc = nil;
    NSMutableString *desc = [NSMutableString string];
    for (UIWindow *win in [UIApplication sharedApplication].windows) {
        if (win.hidden) continue;
        NSString *rootCls = NSStringFromClass([win.rootViewController class]);
        [desc appendFormat:@"%@(%@) ", NSStringFromClass([win class]), rootCls];
        UIViewController *vc = win.rootViewController;
        while (vc) {
            if (XCIsSplashClass(NSStringFromClass([vc class]))) {
                XCSkipSplashViewController(vc);
                break;
            }
            vc = vc.presentedViewController;
        }
    }
    if (desc.length && ![desc isEqualToString:lastWindowDesc]) {
        XCLog(@"windows: %@", desc);
        lastWindowDesc = [desc copy];
    }
}

static void XCInjectProtocols(NSURLSessionConfiguration *cfg) {
    if (!cfg) return;
    NSMutableArray *arr = [[cfg protocolClasses] mutableCopy] ?: [NSMutableArray array];
    if (![arr containsObject:[XCAdURLProtocol class]]) [arr insertObject:[XCAdURLProtocol class] atIndex:0];
    if (![arr containsObject:[XCConfigRewriteProtocol class]]) [arr insertObject:[XCConfigRewriteProtocol class] atIndex:0];
    cfg.protocolClasses = arr;
}

static NSURLSessionConfiguration *(*XC_orig_defaultConf)(id, SEL) = NULL;
static NSURLSessionConfiguration *(*XC_orig_ephemeralConf)(id, SEL) = NULL;

static NSURLSessionConfiguration *XC_conf_default(id self, SEL _cmd) {
    NSURLSessionConfiguration *cfg = XC_orig_defaultConf ? XC_orig_defaultConf(self, _cmd) : nil;
    XCInjectProtocols(cfg);
    return cfg;
}

static NSURLSessionConfiguration *XC_conf_ephemeral(id self, SEL _cmd) {
    NSURLSessionConfiguration *cfg = XC_orig_ephemeralConf ? XC_orig_ephemeralConf(self, _cmd) : nil;
    XCInjectProtocols(cfg);
    return cfg;
}

static NSMutableSet *XCSeenFSClasses = nil;

static void XCDumpFSInView(UIView *v, CGFloat sw, CGFloat sh, NSInteger depth) {
    if (!v || depth > 5) return;
    for (UIView *sub in v.subviews) {
        CGRect f = sub.frame;
        NSString *cn = NSStringFromClass([sub class]);
        if (f.size.width >= sw * 0.9 && f.size.height >= sh * 0.5 &&
            ![cn containsString:@"XCNoAd"] && ![cn containsString:@"UIWindow"]) {
            if (!XCSeenFSClasses) XCSeenFSClasses = [NSMutableSet set];
            if (![XCSeenFSClasses containsObject:cn]) {
                [XCSeenFSClasses addObject:cn];
                XCLog(@"fs: %@ %.0fx%.0f", cn, f.size.width, f.size.height);
            }
        }
        XCDumpFSInView(sub, sw, sh, depth + 1);
    }
}

static void XCDumpFullScreenViewClasses(void) {
    UIWindow *mainWin = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { mainWin = w; break; }
    }
    if (!mainWin) mainWin = [UIApplication sharedApplication].windows.firstObject;
    CGFloat sw = mainWin.bounds.size.width, sh = mainWin.bounds.size.height;
    for (UIWindow *w in XCAllWindows()) {
        XCDumpFSInView(w, sw, sh, 0);
    }
}

static void XCInstallSessionConfHooks(void) {
    Class cls = NSClassFromString(@"NSURLSessionConfiguration");
    if (!cls) return;
    Method m1 = class_getClassMethod(cls, @selector(defaultSessionConfiguration));
    if (m1 && !XC_orig_defaultConf) {
        XC_orig_defaultConf = (void *)method_getImplementation(m1);
        method_setImplementation(m1, (IMP)XC_conf_default);
    }
    Method m2 = class_getClassMethod(cls, @selector(ephemeralSessionConfiguration));
    if (m2 && !XC_orig_ephemeralConf) {
        XC_orig_ephemeralConf = (void *)method_getImplementation(m2);
        method_setImplementation(m2, (IMP)XC_conf_ephemeral);
    }
    XCLog(@"conf hooks installed");
}

__attribute__((constructor)) static void XCInitialize(void) {
    @autoreleasepool {
        XCLaunchTime = [[NSDate date] timeIntervalSince1970];
        XCInstallHooks();
        // 全局注册协议，任何 SDK 自建 Session 也会走拦截（gromore/pangolin 等）
        [NSURLProtocol registerClass:[XCAdURLProtocol class]];
        [NSURLProtocol registerClass:[XCConfigRewriteProtocol class]];
        XCInstallSessionConfHooks();
        XCLog(@"init dylib");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XCCreateOverlay();
            XCScanWindows();
        });
        for (NSInteger i = 1; i <= 160; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!XCOverlay) XCCreateOverlay();
                XCTapSkipButtonsInWindows();
                XCRemoveSplashViewsInWindows();
                XCScanWindows();
                if (i <= 30) {
                    XCHideSplashLayersInWindows();
                    XCDumpFullScreenViewClasses();
                }
                if (i == 155) {
                    if (XCOverlay) XCOverlay.hidden = YES;
                }
            });
        }
    }
}
