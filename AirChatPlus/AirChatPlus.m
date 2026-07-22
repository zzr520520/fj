// ============================================================
// AirChatPlus v6 - 最终稳定版
// 仅 Hook UIViewController.viewDidAppear，通过通知触发 UI 更新
// 不触碰 UIButton、NSURLSession，确保不卡死不闪退
// ============================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================
// 通知回调：在详情页顶部添加访客人数标签
// ============================================================
static void handleViewDidAppear(NSNotification *note) {
    UIViewController *vc = (UIViewController *)note.object;
    if (!vc) return;
    NSString *className = NSStringFromClass([vc class]);

    if (![className containsString:@"MomentDetail"] && ![className containsString:@"DetailViewController"]) {
        return;
    }

    static NSString *const kTagKey = @"AirChatPlus_VisitorLabelAdded";
    if (objc_getAssociatedObject(vc, (__bridge const void *)kTagKey)) {
        return;
    }
    objc_setAssociatedObject(vc, (__bridge const void *)kTagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    id postModel = nil;
    @try { postModel = [vc valueForKey:@"postModel"]; } @catch (NSException *e) { return; }
    if (!postModel) return;

    NSNumber *count = nil;
    @try { count = [postModel valueForKey:@"visitorCount"]; } @catch (NSException *e) {}
    if (!count) @try { count = [postModel valueForKey:@"viewCount"]; } @catch (NSException *e) {}
    if (!count || [count integerValue] <= 0) return;

    UILabel *label = [[UILabel alloc] init];
    label.text = [NSString stringWithFormat:@"\U0001F440 访客人数: %@", count];
    label.textColor = [UIColor systemBlueColor];
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    label.backgroundColor = [[UIColor systemGray6Color] colorWithAlphaComponent:0.9];
    label.layer.cornerRadius = 6;
    label.clipsToBounds = YES;
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:8],
        [label.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [label.widthAnchor constraintGreaterThanOrEqualToConstant:130],
        [label.heightAnchor constraintEqualToConstant:28]
    ]];
}

// ============================================================
// 启动：轻量 Swizzle viewDidAppear + 注册通知 + 弹窗
// ============================================================
__attribute__((constructor))
static void initialize(void) {
    @autoreleasepool {
        // 轻量 Swizzle：只替换 viewDidAppear 实现，在其中发送通知
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            Class cls = [UIViewController class];
            Method origMethod = class_getInstanceMethod(cls, @selector(viewDidAppear:));
            if (!origMethod) return;

            void (*origIMP)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))method_getImplementation(origMethod);

            IMP newIMP = imp_implementationWithBlock(^(id self, BOOL animated) {
                origIMP(self, @selector(viewDidAppear:), animated);
                [[NSNotificationCenter defaultCenter] postNotificationName:@"AirChatPlusViewDidAppear" object:self];
            });
            method_setImplementation(origMethod, newIMP);
        });

        // 注册通知监听
        [[NSNotificationCenter defaultCenter] addObserverForName:@"AirChatPlusViewDidAppear"
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            handleViewDidAppear(note);
        }];

        // 启动弹窗
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AirChatPlus 已加载"
                                                                           message:@"访客人数显示功能已启用"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
            if (rootVC) [rootVC presentViewController:alert animated:YES completion:nil];
        });
    }
}
