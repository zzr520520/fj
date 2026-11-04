#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <stdatomic.h>

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

    // ====== 广告奖励弹窗自动关闭 ======
    if (!vcToPresent) return;
    NSString *cls = NSStringFromClass([vcToPresent class]);
    NSString *c = cls.lowercaseString;
    BOOL isRewardAd = (([c containsString:@"reward"] || [c containsString:@"detective"]) &&
                       ([c containsString:@"dialog"] || [c containsString:@"view"] || [c containsString:@"task"])) ||
                      [c containsString:@"rewarddialog"];
    if (isRewardAd) {
        XCLog(@"[Task] 🎯 广告/奖励弹窗: %@ — 3 秒后自动处理", cls);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // 触发奖励回调（字符串里见过 rewardVideoAdTaskRewardDidSucceed）
            SEL rewardSel = NSSelectorFromString(@"rewardVideoAdTaskRewardDidSucceed");
            if ([vcToPresent respondsToSelector:rewardSel]) {
                XCLog(@"[Task] 触发 rewardVideoAdTaskRewardDidSucceed");
                @try { [vcToPresent performSelector:rewardSel]; } @catch (NSException *e) {}
            }
            // 尝试多种关闭方式
            for (NSString *selName in @[@"close", @"dismiss", @"finish", @"completeReward", @"claimReward"]) {
                SEL s = NSSelectorFromString(selName);
                if ([vcToPresent respondsToSelector:s]) {
                    XCLog(@"[Task] 调 %@ 关闭弹窗", selName);
                    @try { [vcToPresent performSelector:s]; } @catch (NSException *e) {}
                    break;
                }
            }
            if (vcToPresent.presentingViewController) {
                XCLog(@"[Task] 强制 dismiss 弹窗");
                [vcToPresent dismissViewControllerAnimated:NO completion:nil];
            }
        });
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

static UIWindow *XCWhiteCoverWindow = nil;

static void XCCreateWhiteCover(void) {
    if (XCWhiteCoverWindow) return;
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *keyWin = nil;
    for (UIWindow *w in app.windows) {
        if (!w.hidden) { keyWin = w; break; }
    }
    if (!keyWin) keyWin = app.windows.firstObject;
    if (!keyWin) return;
    XCWhiteCoverWindow = [[UIWindow alloc] initWithFrame:keyWin.bounds];
    XCWhiteCoverWindow.windowLevel = 6000;
    if (@available(iOS 13.0, *)) {
        XCWhiteCoverWindow.windowScene = keyWin.windowScene;
    }
    XCWhiteCoverWindow.backgroundColor = [UIColor whiteColor];
    XCWhiteCoverWindow.hidden = NO;
    UIView *white = [[UIView alloc] initWithFrame:XCWhiteCoverWindow.bounds];
    white.backgroundColor = [UIColor whiteColor];
    white.userInteractionEnabled = YES;
    [XCWhiteCoverWindow addSubview:white];
}

static void XCRemoveWhiteCover(void) {
    if (!XCWhiteCoverWindow) return;
    UIWindow *w = XCWhiteCoverWindow;
    XCWhiteCoverWindow = nil;
    [UIView animateWithDuration:0.12 animations:^{
        w.alpha = 0;
    } completion:^(BOOL finished) {
        w.hidden = YES;
    }];
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

static IMP XC_orig_kPageName = NULL;
static IMP XC_orig_kOpenPage = NULL;
static IMP XC_orig_kFramePage = NULL;
static NSInteger XCKuiklyHooksCount = -1;

static id XC_kPageName(id self, SEL _cmd, NSString *name, id data) {
    XCLog(@"kuikly page: %@", name);
    return ((id (*)(id, SEL, id, id))XC_orig_kPageName)(self, _cmd, name, data);
}

static void XC_kOpenPage(id self, SEL _cmd, NSString *name, id data, id ctrl) {
    XCLog(@"kuikly open: %@", name);
    if (XC_orig_kOpenPage) ((void (*)(id, SEL, id, id, id))XC_orig_kOpenPage)(self, _cmd, name, data, ctrl);
}

static id XC_kFramePage(id self, SEL _cmd, CGRect frame, NSString *name, id data, id delegate, id framework) {
    XCLog(@"kuikly frame page: %@", name);
    return ((id (*)(id, SEL, CGRect, id, id, id, id))XC_orig_kFramePage)(self, _cmd, frame, name, data, delegate, framework);
}

static void XCInstallKuiklyHooks(void) {
    NSInteger foundCls = 0;
    @try {
        int count = objc_getClassList(NULL, 0);
        if (count <= 0) return;
        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
        if (!classes) return;
        count = objc_getClassList(classes, count);
        for (int i = 0; i < count; i++) {
            Class c = classes[i];
            SEL s1 = NSSelectorFromString(@"initWithPageName:pageData:");
            SEL s2 = NSSelectorFromString(@"openPageWithName:pageData:controller:");
            SEL s3 = NSSelectorFromString(@"initWithFrame:pageName:pageData:delegate:frameworkName:");
            if (class_getInstanceMethod(c, s1) && !XC_orig_kPageName) {
                XC_orig_kPageName = method_getImplementation(class_getInstanceMethod(c, s1));
                class_replaceMethod(c, s1, (IMP)XC_kPageName, method_getTypeEncoding(class_getInstanceMethod(c, s1)));
                foundCls++;
            }
            if (class_getInstanceMethod(c, s2) && !XC_orig_kOpenPage) {
                XC_orig_kOpenPage = method_getImplementation(class_getInstanceMethod(c, s2));
                class_replaceMethod(c, s2, (IMP)XC_kOpenPage, method_getTypeEncoding(class_getInstanceMethod(c, s2)));
                foundCls++;
            }
            if (class_getInstanceMethod(c, s3) && !XC_orig_kFramePage) {
                XC_orig_kFramePage = method_getImplementation(class_getInstanceMethod(c, s3));
                class_replaceMethod(c, s3, (IMP)XC_kFramePage, method_getTypeEncoding(class_getInstanceMethod(c, s3)));
                foundCls++;
            }
        }
        free(classes);
    } @catch (NSException *e) {}
    XCKuiklyHooksCount = foundCls;
    XCLog(@"kuikly hooks: %ld", (long)foundCls);
}

static BOOL XCIsSuspectNewUserClass(NSString *name) {
    NSString *lower = [name lowercaseString];
    NSArray *keys = @[@"newuser", @"new_user", @"receive", @"redpack", @"red_pack", @"invite", @"firsttask", @"welcome", @"newbie", @"rookie"];
    for (NSString *k in keys) if ([lower containsString:k]) return YES;
    return NO;
}

static void XCHideSuspectViewsInView(UIView *view, NSInteger depth) {
    if (!view || depth > 14) return;
    for (UIView *sub in view.subviews) {
        if (XCIsSuspectNewUserClass(NSStringFromClass([sub class]))) {
            if (!sub.hidden || sub.alpha > 0.01) {
                XCLog(@"hide cls %@ %.0fx%.0f", NSStringFromClass([sub class]), sub.frame.size.width, sub.frame.size.height);
            }
            sub.hidden = YES;
            sub.alpha = 0;
        }
        XCHideSuspectViewsInView(sub, depth + 1);
    }
}

static void XCHideSuspectViewsInWindows(void) {
    for (UIWindow *w in XCAllWindows()) {
        XCHideSuspectViewsInView(w, 0);
    }
}

static void XCDumpSuspectClassNames(void) {
    NSInteger shown = 0;
    @try {
        int count = objc_getClassList(NULL, 0);
        if (count <= 0) return;
        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
        if (!classes) return;
        count = objc_getClassList(classes, count);
        NSMutableArray *names = [NSMutableArray array];
        for (int i = 0; i < count; i++) {
            NSString *n = NSStringFromClass(classes[i]);
            if (n.length < 8) continue;
            if (XCIsSuspectNewUserClass(n)) [names addObject:n];
        }
        free(classes);
        for (NSString *n in names) {
            if (shown++ >= 25) break;
            XCLog(@"cls: %@", n);
        }
    } @catch (NSException *e) {}
}

#pragma mark - 元宝乐园 一键领取引擎 v19

/*
 * v19 方案（UI 级自动化）：
 *  - 会员 Tab 的「轻松赚元宝」弹层由 Lynx 渲染，不是独立 VC，之前按类名触发的方案全部落空
 *  - 任务按钮（去完成/去浏览/去关注/去邀请/领取…）是原生 UILabel + 手势/Control 实现的
 *  - 引擎：递归扫描窗口树，找到这些文字对应的视图，模拟触发 UIControl action /
 *    UITapGestureRecognizer target-action / accessibilityActivate
 *  - 「一键领取」悬浮按钮：点按立即跑一轮；长按切换自动模式（每 6 秒自动点一个）
 *  - 浏览类任务点击后停留 32 秒再返回（满足 30s 时长），其它 5 秒返回继续下一个
 *  - 同时 swizzle getUserTaskV2PagerId: 等方法记录真实服务类名（为下一版直调做准备）
 */

static NSMutableDictionary *XCTappedLog = nil;      // 已点按钮去重 {key: timestamp}
static NSLock *XCEngineLock = nil;
static BOOL XCEngineBusy = NO;
static BOOL XCAutoClickEnabled = YES;
static dispatch_source_t XCEngineTimer = nil;
static UIWindow *XCFloatWin = nil;
static UIButton *XCFloatBtn = nil;
static UILabel *XCFloatState = nil;
static NSMutableDictionary *XCOrigTaskIMPs = nil;
static NSLock *XCTaskSwizzleLock = nil;
static NSInteger XCTapCount = 0;

static void XCFileLog(NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        @try {
            static NSString *path = nil;
            static dispatch_once_t onceT;
            dispatch_once(&onceT, ^{
                path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"xc_dylib_log.txt"];
            });
            NSString *line = [NSString stringWithFormat:@"[%ld] %@\n",
                              (long)[[NSDate date] timeIntervalSince1970], msg];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!fh) {
                [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            } else {
                [fh seekToEndOfFile];
                [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
        } @catch (NSException *e) {}
    }
}

static UIViewController *XCTopViewController(void) {
    UIViewController *root = nil;
    for (UIWindow *w in XCAllWindows()) {
        if (w.isKeyWindow && w.rootViewController) { root = w.rootViewController; break; }
    }
    if (!root) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.rootViewController) { root = w.rootViewController; break; }
        }
    }
    UIViewController *top = root;
    int guard = 0;
    while (top.presentedViewController && guard++ < 12) top = top.presentedViewController;
    return top;
}

static NSString *XCTextOfView(UIView *v) {
    @try {
        if ([v isKindOfClass:[UILabel class]]) return [(UILabel *)v text];
        if ([v isKindOfClass:[UIButton class]]) return [(UIButton *)v titleForState:UIControlStateNormal];
        if ([v isKindOfClass:[UITextView class]]) return [(UITextView *)v text];
        if ([v isKindOfClass:[UITextField class]]) return [(UITextField *)v text];
        NSString *al = v.accessibilityLabel;
        if (al.length > 0 && al.length <= 24) return al;
    } @catch (NSException *e) {}
    return nil;
}

static BOOL XCIsTaskActionText(NSString *text) {
    if (text.length == 0 || text.length > 24) return NO;
    if ([text containsString:@"已领取"] || [text containsString:@"已完成"]) return NO;
    NSArray *pats = @[@"去完成", @"去浏览", @"去关注", @"去邀请", @"去下单", @"去参与",
                      @"去抽奖", @"去签到", @"立即签到", @"立即领取", @"去领取", @"领取"];
    for (NSString *p in pats) {
        if ([text containsString:p]) return YES;
    }
    return NO;
}

#pragma mark 模拟点击

static BOOL XCInvokeGestureTargets(UITapGestureRecognizer *g) {
    NSArray *targets = nil;
    @try { targets = [g valueForKey:@"targets"]; } @catch (NSException *e) {}
    if (![targets isKindOfClass:[NSArray class]] || targets.count == 0) return NO;
    BOOL fired = NO;
    for (id t in targets) {
        @try {
            id target = nil;
            id actionRaw = nil;
            @try { target = [t valueForKey:@"_target"]; } @catch (NSException *e) {}
            @try { actionRaw = [t valueForKey:@"_action"]; } @catch (NSException *e) {}
            if (!target) { @try { target = [t valueForKey:@"target"]; } @catch (NSException *e) {} }
            if (!actionRaw) { @try { actionRaw = [t valueForKey:@"action"]; } @catch (NSException *e) {} }
            SEL action = NULL;
            if ([actionRaw isKindOfClass:[NSString class]]) {
                action = NSSelectorFromString(actionRaw);
            } else if ([actionRaw isKindOfClass:[NSValue class]]) {
                action = (SEL)[(NSValue *)actionRaw pointerValue];
            }
            if (!target || !action) continue;
            if (![target respondsToSelector:action]) continue;
            void (*imp)(id, SEL, id) = (void (*)(id, SEL, id))[target methodForSelector:action];
            imp(target, action, g);
            fired = YES;
            XCLog(@"[tap] gesture -> %@ (%@)", NSStringFromClass([target class]), NSStringFromSelector(action));
        } @catch (NSException *e) {}
    }
    return fired;
}

static BOOL XCSmartTap(UIView *view, NSString *text) {
    if (!view) return NO;
    // 1) UIControl（含 UIButton）：直接发 action
    UIView *v = view;
    for (int up = 0; v && up < 4; up++, v = v.superview) {
        if ([v isKindOfClass:[UIControl class]]) {
            UIControl *c = (UIControl *)v;
            if (c.enabled && !c.hidden) {
                [c sendActionsForControlEvents:UIControlEventTouchUpInside];
                XCLog(@"[tap] control %@ text=%@", NSStringFromClass([c class]), text);
                return YES;
            }
        }
    }
    // 2) UITapGestureRecognizer target-action（沿父视图向上找 5 层）
    v = view;
    for (int up = 0; v && up < 5; up++, v = v.superview) {
        NSArray *ges = v.gestureRecognizers;
        for (UIGestureRecognizer *g in ges) {
            if ([g isKindOfClass:[UITapGestureRecognizer class]] && g.enabled) {
                if (XCInvokeGestureTargets((UITapGestureRecognizer *)g)) {
                    XCLog(@"[tap] gesture on %@ text=%@", NSStringFromClass([v class]), text);
                    return YES;
                }
            }
        }
    }
    // 3) 无障碍激活
    @try {
        if ([view respondsToSelector:@selector(accessibilityActivate)]) {
            BOOL r = [view accessibilityActivate];
            if (r) {
                XCLog(@"[tap] a11y %@ text=%@", NSStringFromClass([view class]), text);
                return YES;
            }
        }
    } @catch (NSException *e) {}
    // 4) 再试 view 自身的 touchesBegan/Ended 无法构造 UITouch，跳过
    XCLog(@"[tap] FAILED 没有可触发方式 text=%@ cls=%@", text, NSStringFromClass([view class]));
    return NO;
}

#pragma mark 页面判定

static BOOL XCIsPointsParkClass(NSString *cls) {
    NSString *c = cls.lowercaseString;
    return ([c containsString:@"pointspark"] || [c containsString:@"points_park"] ||
            [c containsString:@"taskcenter"] || [c containsString:@"earningtask"]);
}

static BOOL XCVisibleTextContains(NSArray<NSString *> *keys) {
    for (UIWindow *w in XCAllWindows()) {
        if (w.hidden || w.alpha < 0.05) continue;
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
        int visited = 0;
        while (stack.count > 0 && visited < 2500) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            visited++;
            if (v.hidden || v.alpha < 0.05) continue;
            NSString *t = XCTextOfView(v);
            if (t.length) {
                for (NSString *k in keys) {
                    if ([t containsString:k]) return YES;
                }
            }
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
    }
    return NO;
}

static BOOL XCOnTaskPage(void) {
    UIViewController *top = XCTopViewController();
    if (top && XCIsPointsParkClass(NSStringFromClass([top class]))) return YES;
    return XCVisibleTextContains(@[@"轻松赚元宝", @"元宝乐园", @"元宝余额"]);
}

#pragma mark 一轮点击

static void XCUpdateFloatState(NSString *s) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (XCFloatState) XCFloatState.text = s;
    });
}

static void XCGoBack(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = XCTopViewController();
        if (!top) return;
        @try {
            if (top.presentingViewController && ![top isKindOfClass:[UINavigationController class]]) {
                [top dismissViewControllerAnimated:YES completion:nil];
                XCLog(@"[nav] dismiss %@", NSStringFromClass([top class]));
                return;
            }
            UINavigationController *nav = top.navigationController;
            if (nav && nav.viewControllers.count > 1) {
                [nav popViewControllerAnimated:YES];
                XCLog(@"[nav] pop from %@", NSStringFromClass([top class]));
                return;
            }
            UIBarButtonItem *bb = top.navigationItem.leftBarButtonItem;
            if (bb && bb.enabled && bb.target && bb.action) {
                void (*imp)(id, SEL, id) = (void (*)(id, SEL, id))[bb.target methodForSelector:bb.action];
                imp(bb.target, bb.action, bb);
                XCLog(@"[nav] tap back bar");
            }
        } @catch (NSException *e) {}
    });
}

static void XCDoOneClickPass(BOOL force) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (XCEngineBusy && !force) return;
        if (!XCOnTaskPage()) {
            if (force) XCUpdateFloatState(@"请先进元宝乐园页");
            return;
        }
        if (!XCTappedLog) { XCTappedLog = [NSMutableDictionary dictionary]; XCEngineLock = [[NSLock alloc] init]; }

        // 收集候选按钮
        NSMutableArray *cands = [NSMutableArray array]; // @(YES)=claim优先, dict{view,text}
        for (UIWindow *w in XCAllWindows()) {
            if (w.hidden || w.alpha < 0.05) continue;
            NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
            int visited = 0;
            while (stack.count > 0 && visited < 3000) {
                UIView *v = stack.lastObject;
                [stack removeLastObject];
                visited++;
                if (v.hidden || v.alpha < 0.05 || v.frame.size.width < 12 || v.frame.size.height < 10) continue;
                NSString *t = XCTextOfView(v);
                if (XCIsTaskActionText(t)) {
                    BOOL isClaim = [t containsString:@"领取"];
                    [cands addObject:@[@(isClaim), @{@"v": v, @"t": t}]];
                }
                for (UIView *sub in v.subviews) [stack addObject:sub];
            }
        }
        if (cands.count == 0) {
            if (force) XCUpdateFloatState(@"没有可点的任务按钮");
            XCLog(@"[一键领取] 无候选按钮");
            return;
        }

        // 领取类优先，取第一个未被 45 秒冷却拦住的
        NSString *pickedText = nil;
        UIView *pickedView = nil;
        for (int pass = 0; pass < 2 && !pickedView; pass++) {
            for (NSArray *c in cands) {
                BOOL isClaim = [c[0] boolValue];
                if ((pass == 0) != isClaim) continue;
                NSDictionary *info = c[1];
                UIView *v = info[@"v"];
                NSString *t = info[@"t"];
                NSString *key = [NSString stringWithFormat:@"%@|%.0f|%.0f", t, v.center.x / 8.0, v.center.y / 8.0];
                NSNumber *last = XCTappedLog[key];
                if (last && ([[NSDate date] timeIntervalSince1970] - last.doubleValue) < 45.0) continue;
                pickedView = v;
                pickedText = t;
                break;
            }
        }
        if (!pickedView) {
            if (force) XCUpdateFloatState(@"任务都在冷却中");
            XCLog(@"[一键领取] 全部冷却中");
            return;
        }

        NSString *key = [NSString stringWithFormat:@"%@|%.0f|%.0f", pickedText, pickedView.center.x / 8.0, pickedView.center.y / 8.0];
        XCTappedLog[key] = @([[NSDate date] timeIntervalSince1970]);
        XCLog(@"[一键领取] 点击 #%ld 「%@」", (long)++XCTapCount, pickedText);
        XCFileLog(@"tap #%ld text=%@", (long)XCTapCount, pickedText);
        XCUpdateFloatState([NSString stringWithFormat:@"已点: %@", pickedText]);

        BOOL ok = XCSmartTap(pickedView, pickedText);
        XCEngineBusy = YES;

        // 停留时长：浏览/视频 32 秒，签到 8 秒，其它 5 秒
        NSTimeInterval wait = 5.0;
        if ([pickedText containsString:@"浏览"] || [pickedText containsString:@"视频"] || [pickedText containsString:@"看"]) wait = 32.0;
        else if ([pickedText containsString:@"签到"]) wait = 8.0;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!ok) {
                XCLog(@"[一键领取] 点击失败，不返回继续尝试其它按钮");
            } else {
                XCGoBack();
            }
            XCEngineBusy = NO;
            XCUpdateFloatState(@"待命 · 点我继续");
        });
    });
}

#pragma mark 服务调用观测（swizzle 记录真实类名，为直调做准备）

static void XC_taskLogIMP4(id self, SEL _cmd, id a1, id a2) {
    NSString *key = nil;
    @try {
        key = [NSStringFromClass([self class]) stringByAppendingString:NSStringFromSelector(_cmd)];
        XCLog(@"[Task] 观测到调用 %@", key);
        XCFileLog(@"svc call %@", key);
    } @catch (NSException *e) {}
    void (*orig)(id, SEL, id, id) = NULL;
    @try {
        [XCTaskSwizzleLock lock];
        NSValue *v = XCOrigTaskIMPs[key];
        [XCTaskSwizzleLock unlock];
        if (v) orig = (void (*)(id, SEL, id, id))[v pointerValue];
    } @catch (NSException *e) {}
    if (orig) orig(self, _cmd, a1, a2);
}

static void XCSwizzlePagerMethods(void) {
    if (!XCOrigTaskIMPs) {
        XCOrigTaskIMPs = [NSMutableDictionary dictionary];
        XCTaskSwizzleLock = [[NSLock alloc] init];
    }
    NSArray<NSString *> *sels = @[
        @"getUserTaskV2PagerId:completionHandler:",
        @"signInNodePagerId:completionHandler:",
        @"userSignInDaysPagerId:completionHandler:",
        @"getUnReceivedPointRecordsPagerId:completionHandler:",
        @"pointsParkTask:callback:"
    ];
    NSInteger hooked = 0;
    @try {
        int count = objc_getClassList(NULL, 0);
        if (count <= 0) return;
        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
        if (!classes) return;
        count = objc_getClassList(classes, count);
        for (int i = 0; i < count; i++) {
            Class c = classes[i];
            if (!c) continue;
            NSString *cn = NSStringFromClass(c);
            if ([cn hasPrefix:@"XC"] || [cn hasPrefix:@"UI"]) continue;
            for (NSString *selName in sels) {
                SEL sel = NSSelectorFromString(selName);
                Method m = class_getInstanceMethod(c, sel);
                if (!m) continue;
                NSString *key = [cn stringByAppendingString:selName];
                if (XCOrigTaskIMPs[key]) continue;
                IMP orig = method_getImplementation(m);
                [XCTaskSwizzleLock lock];
                XCOrigTaskIMPs[key] = [NSValue valueWithPointer:(void *)orig];
                [XCTaskSwizzleLock unlock];
                method_setImplementation(m, (IMP)XC_taskLogIMP4);
                hooked++;
                XCLog(@"[Task] swizzle hook %@ -> %@", cn, selName);
                XCFileLog(@"hook %@ %@", cn, selName);
            }
        }
        free(classes);
    } @catch (NSException *e) {}
    XCLog(@"[Task] 观测 hook 安装 %ld 个", (long)hooked);
}

#pragma mark 悬浮「一键领取」按钮

static void XCFloatButtonAction(void) {
    XCLog(@"[一键领取] ===== 手动触发 =====");
    XCDoOneClickPass(YES);
}

static void XCCreateFloatButton(void) {
    if (XCFloatWin) return;
    UIWindow *key = nil;
    for (UIWindow *w in XCAllWindows()) {
        if (w.isKeyWindow) { key = w; break; }
    }
    if (!key) return;
    XCFloatWin = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 108, 56)];
    XCFloatWin.windowLevel = 6100;
    if (@available(iOS 13.0, *)) {
        XCFloatWin.windowScene = key.windowScene;
    }
    XCFloatWin.backgroundColor = [UIColor clearColor];
    XCFloatWin.hidden = NO;

    XCFloatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    XCFloatBtn.frame = CGRectMake(4, 6, 100, 30);
    XCFloatBtn.backgroundColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.1 alpha:0.92];
    XCFloatBtn.layer.cornerRadius = 15;
    XCFloatBtn.layer.masksToBounds = YES;
    XCFloatBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [XCFloatBtn setTitle:@"一键领取" forState:UIControlStateNormal];
    [XCFloatBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [XCFloatBtn addTarget:[NSBlockOperation blockOperationWithBlock:^{ XCFloatButtonAction(); }]
                   action:@selector(main)
         forControlEvents:UIControlEventTouchUpInside];
    [XCFloatWin addSubview:XCFloatBtn];

    XCFloatState = [[UILabel alloc] initWithFrame:CGRectMake(0, 38, 108, 14)];
    XCFloatState.text = @"待命 · 点我继续";
    XCFloatState.font = [UIFont systemFontOfSize:9];
    XCFloatState.textColor = [UIColor whiteColor];
    XCFloatState.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    XCFloatState.textAlignment = NSTextAlignmentCenter;
    XCFloatState.layer.cornerRadius = 4;
    XCFloatState.layer.masksToBounds = YES;
    [XCFloatWin addSubview:XCFloatState];

    // 长按 = 切换自动模式
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[NSBlockOperation blockOperationWithBlock:^{
            XCAutoClickEnabled = !XCAutoClickEnabled;
            XCLog(@"[一键领取] 自动模式切换为 %@", XCAutoClickEnabled ? @"开" : @"关");
            XCUpdateFloatState(XCAutoClickEnabled ? @"自动模式:开" : @"自动模式:关");
        }]
        action:@selector(main)];
    lp.minimumPressDuration = 0.8;
    [XCFloatBtn addGestureRecognizer:lp];

    // 默认位置：屏幕右侧 40% 高度（固定位置，不影响功能）
    CGFloat sw = key.bounds.size.width, sh = key.bounds.size.height;
    XCFloatWin.center = CGPointMake(sw - 62, sh * 0.42);
    XCLog(@"[一键领取] 悬浮按钮已创建");
}

#pragma mark 引擎定时器

static void XCStartEngineTimer(void) {
    if (XCEngineTimer) return;
    XCLog(@"[Task] 一键领取引擎定时器启动 (6s 轮询)");
    XCEngineTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    uint64_t interval = 6 * NSEC_PER_SEC;
    dispatch_source_set_timer(XCEngineTimer, DISPATCH_TIME_NOW, interval, interval);
    dispatch_source_set_event_handler(XCEngineTimer, ^{
        @try {
            if (XCAutoClickEnabled) XCDoOneClickPass(NO);
        } @catch (NSException *e) {
            XCLog(@"[Task] 引擎异常: %@", e);
        }
    });
    dispatch_resume(XCEngineTimer);
}

__attribute__((constructor)) static void XCInitialize(void) {
    @autoreleasepool {
        XCLaunchTime = [[NSDate date] timeIntervalSince1970];
        XCInstallHooks();
        // 全局注册协议，任何 SDK 自建 Session 也会走拦截（gromore/pangolin 等）
        [NSURLProtocol registerClass:[XCAdURLProtocol class]];
        [NSURLProtocol registerClass:[XCConfigRewriteProtocol class]];
        XCInstallSessionConfHooks();
        XCInstallKuiklyHooks();
        XCLog(@"init dylib");

        // v19: 一键领取引擎（悬浮按钮 + UI 自动点击 + 服务调用观测）
        XCSwizzlePagerMethods();
        XCStartEngineTimer();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XCCreateFloatButton();
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XCCreateWhiteCover();
        });
        for (NSInteger i = 1; i <= 160; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (i <= 4 && !XCWhiteCoverWindow) XCCreateWhiteCover();
                XCTapSkipButtonsInWindows();
                XCRemoveSplashViewsInWindows();
                XCScanWindows();
                if (i <= 40) {
                    XCHideSplashLayersInWindows();
                }
                if (i == 10) {
                    XCRemoveWhiteCover();
                }
            });
        }
    }
}
