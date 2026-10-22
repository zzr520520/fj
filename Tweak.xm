#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

#pragma mark - 1. 全局转发助手核心状态（支持图片与文本）

@interface ACContactItem : NSObject
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL isGroup;
@property (nonatomic, assign) BOOL isSelected;
@end

@implementation ACContactItem
@end

@interface ACForwardHelperManager : NSObject
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *friendList;
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *groupList;
@property (nonatomic, strong) UIImage *sharedImage; // 当前捕获待转发的图片
@property (nonatomic, copy) NSString *sharedText;   // 当前待转发的文本

+ (instancetype)shared;
- (void)reloadAllDataWithCompletion:(void(^)(NSString *msg))completion;
- (void)sendContentToItem:(ACContactItem *)item completion:(void(^)(BOOL ok, NSString *err))completion;
@end

@implementation ACForwardHelperManager

+ (instancetype)shared {
    static ACForwardHelperManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ACForwardHelperManager instancetype] init];
        instance.friendList = [NSMutableArray array];
        instance.groupList = [NSMutableArray array];
    });
    return instance;
}

- (void)reloadAllDataWithCompletion:(void(^)(NSString *msg))completion {
    // 复用之前的数据库与 IM 列表扫描逻辑
    [self.friendList removeAllObjects];
    [self.groupList removeAllObjects];
    
    Class v2Cls = NSClassFromString(@"V2TIMManager");
    if (v2Cls && [v2Cls respondsToSelector:@selector(sharedInstance)]) {
        id mgr = ((id (*)(id, SEL))objc_msgSend)(v2Cls, @selector(sharedInstance));
        SEL getConvSel = NSSelectorFromString(@"getConversationList:count:succ:fail:");
        if ([mgr respondsToSelector:getConvSel]) {
            void (^succBlock)(NSArray *, uint64_t, BOOL) = ^(NSArray *list, uint64_t nextSeq, BOOL isFinished) {
                for (id conv in list) {
                    @try {
                        NSString *showName = [conv valueForKey:@"showName"];
                        NSString *uid = [conv valueForKey:@"userID"];
                        NSString *gid = [conv valueForKey:@"groupID"];
                        ACContactItem *item = [[ACContactItem alloc] init];
                        if (gid && gid.length > 0) {
                            item.targetId = gid;
                            item.name = showName ?: @"群聊";
                            item.isGroup = YES;
                            [self.groupList addObject:item];
                        } else if (uid && uid.length > 0) {
                            item.targetId = uid;
                            item.name = showName ?: uid;
                            item.isGroup = NO;
                            [self.friendList addObject:item];
                        }
                    } @catch (NSException *e) {}
                }
                if (completion) completion([NSString stringWithFormat:@"已加载 %lu 好友 | %lu 群聊", (unsigned long)self.friendList.count, (unsigned long)self.groupList.count]);
            };
            void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) {
                if (completion) completion(@"加载完成");
            };
            NSMethodSignature *sig = [mgr methodSignatureForSelector:getConvSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:mgr];
            [inv setSelector:getConvSel];
            uint64_t seq = 0; int cnt = 300;
            [inv setArgument:&seq atIndex:2];
            [inv setArgument:&cnt atIndex:3];
            [inv setArgument:&succBlock atIndex:4];
            [inv setArgument:&failBlock atIndex:5];
            [inv invoke];
            return;
        }
    }
    if (completion) completion(@"就绪");
}

// 发送文本或图片到指定目标
- (void)sendContentToItem:(ACContactItem *)item completion:(void(^)(BOOL ok, NSString *err))completion {
    Class v2MgrCls = NSClassFromString(@"V2TIMManager");
    if (!v2MgrCls) {
        if (completion) completion(NO, @"IM未初始化");
        return;
    }
    id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));

    // 如果有图片，优先发送图片消息
    if (self.sharedImage) {
        NSData *imgData = UIImageJPEGRepresentation(self.sharedImage, 0.8);
        // 将图片写入沙盒临时文件
        NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"forward_share_img.jpg"];
        [imgData writeToFile:tmpPath atomically:YES];

        SEL createImageMsgSel = NSSelectorFromString(@"createImageMessage:");
        SEL sendMsgSel = NSSelectorFromString(@"sendMessage:receiver:groupID:priority:onlineUserOnly:offlinePushInfo:progress:succ:fail:");

        if ([manager respondsToSelector:createImageMsgSel] && [manager respondsToSelector:sendMsgSel]) {
            id imgMsg = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createImageMsgSel, tmpPath);
            NSString *receiver = item.isGroup ? nil : item.targetId;
            NSString *groupID = item.isGroup ? item.targetId : nil;

            void (^succ)(void) = ^{ if (completion) completion(YES, nil); };
            void (^fail)(int, NSString *) = ^(int code, NSString *desc){ if (completion) completion(NO, desc); };

            NSMethodSignature *sig = [manager methodSignatureForSelector:sendMsgSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:manager];
            [inv setSelector:sendMsgSel];
            [inv setArgument:&imgMsg atIndex:2];
            [inv setArgument:&receiver atIndex:3];
            [inv setArgument:&groupID atIndex:4];
            NSInteger pri = 0; BOOL online = NO; id nilObj = nil;
            [inv setArgument:&pri atIndex:5];
            [inv setArgument:&online atIndex:6];
            [inv setArgument:&nilObj atIndex:7];
            [inv setArgument:&nilObj atIndex:8];
            [inv setArgument:&succ atIndex:9];
            [inv setArgument:&fail atIndex:10];
            [inv invoke];
            return;
        }
    }

    // 默认发送文本
    NSString *txt = self.sharedText.length > 0 ? self.sharedText : @"[转发图片]";
    SEL createTextSel = NSSelectorFromString(@"createTextMessage:");
    SEL sendMsgSel = NSSelectorFromString(@"sendMessage:receiver:groupID:priority:onlineUserOnly:offlinePushInfo:progress:succ:fail:");
    if ([manager respondsToSelector:createTextSel] && [manager respondsToSelector:sendMsgSel]) {
        id txtMsg = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createTextSel, txt);
        NSString *receiver = item.isGroup ? nil : item.targetId;
        NSString *groupID = item.isGroup ? item.targetId : nil;

        void (^succ)(void) = ^{ if (completion) completion(YES, nil); };
        void (^fail)(int, NSString *) = ^(int code, NSString *desc){ if (completion) completion(NO, desc); };

        NSMethodSignature *sig = [manager methodSignatureForSelector:sendMsgSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:manager];
        [inv setSelector:sendMsgSel];
        [inv setArgument:&txtMsg atIndex:2];
        [inv setArgument:&receiver atIndex:3];
        [inv setArgument:&groupID atIndex:4];
        NSInteger pri = 0; BOOL online = NO; id nilObj = nil;
        [inv setArgument:&pri atIndex:5];
        [inv setArgument:&online atIndex:6];
        [inv setArgument:&nilObj atIndex:7];
        [inv setArgument:&nilObj atIndex:8];
        [inv setArgument:&succ atIndex:9];
        [inv setArgument:&fail atIndex:10];
        [inv invoke];
        return;
    }

    if (completion) completion(NO, @"发送失败");
}

@end

#pragma mark - 2. 转发助手交互面板控制器

@interface ACForwardAssistantVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *floatingSendBtn;
@end

@implementation ACForwardAssistantVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"转发助手 - 选择目标";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.edgesForExtendedLayout = UIRectEdgeNone;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(dismissSelf)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain target:self action:@selector(loadData)];

    [self setupUI];
    [self loadData];
}

- (void)setupUI {
    CGFloat width = self.view.bounds.size.width;

    // 如果捕获到了图片，在顶部显示一个小缩略图预览
    if ([ACForwardHelperManager shared].sharedImage) {
        self.previewImageView = [[UIImageView alloc] initWithFrame:CGRectMake(16, 12, 60, 60)];
        self.previewImageView.image = [ACForwardHelperManager shared].sharedImage;
        self.previewImageView.contentMode = UIViewContentModeScaleAspectFill;
        self.previewImageView.layer.cornerRadius = 8;
        self.previewImageView.clipsToBounds = YES;
        [self.view addSubview:self.previewImageView];

        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(86, 20, width - 102, 44)];
        hint.text = @"[已捕获聊天图片] 勾选下方好友或群聊后点击右下角发送";
        hint.font = [UIFont systemFontOfSize:13];
        hint.numberOfLines = 2;
        hint.textColor = [UIColor secondaryLabelColor];
        [self.view addSubview:hint];
    }

    CGFloat topY = [ACForwardHelperManager shared].sharedImage ? 84 : 16;
    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"好友 (0)", @"群聊 (0)"]];
    self.tabControl.frame = CGRectMake(16, topY, width - 32, 32);
    self.tabControl.selectedSegmentIndex = 0;
    [self.tabControl addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.tabControl];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, topY + 40, width - 32, 20)];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.text = @"正在读取联系人...";
    [self.view addSubview:self.statusLabel];

    CGFloat tableTop = topY + 68;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, tableTop, width, self.view.bounds.size.height - tableTop) style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = 54.0;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 90, 0);
    [self.view addSubview:self.tableView];

    // 右下角悬浮发送按钮
    self.floatingSendBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingSendBtn.frame = CGRectMake(width - 146, self.view.bounds.size.height - 76, 130, 48);
    self.floatingSendBtn.backgroundColor = [UIColor systemBlueColor];
    [self.floatingSendBtn setTitle:@"🚀 发送 (0)" forState:UIControlStateNormal];
    [self.floatingSendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.floatingSendBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    self.floatingSendBtn.layer.cornerRadius = 24;
    [self.floatingSendBtn addTarget:self action:@selector(startSend) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.floatingSendBtn];
}

- (void)loadData {
    [[ACForwardHelperManager shared] reloadAllDataWithCompletion:^(NSString *msg) {
        self.statusLabel.text = msg;
        [self updateUI];
        [self.tableView reloadData];
    }];
}

- (void)tabChanged {
    [self.view endEditing:YES];
    [self.tableView reloadData];
}

- (void)updateUI {
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    [self.tabControl setTitle:[NSString stringWithFormat:@"好友 (%lu)", (unsigned long)mgr.friendList.count] forSegmentAtIndex:0];
    [self.tabControl setTitle:[NSString stringWithFormat:@"群聊 (%lu)", (unsigned long)mgr.groupList.count] forSegmentAtIndex:1];

    NSInteger selCount = 0;
    for (ACContactItem *i in mgr.friendList) if (i.isSelected) selCount++;
    for (ACContactItem *i in mgr.groupList) if (i.isSelected) selCount++;
    [self.floatingSendBtn setTitle:[NSString stringWithFormat:@"🚀 发送 (%ld)", (long)selCount] forState:UIControlStateNormal];
}

- (NSArray<ACContactItem *> *)currentItems {
    return self.tabControl.selectedSegmentIndex == 0 ? [ACForwardHelperManager shared].friendList : [ACForwardHelperManager shared].groupList;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self currentItems].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"Cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    ACContactItem *item = [self currentItems][indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", item.isGroup ? @"👥" : @"👤", item.name];
    cell.detailTextLabel.text = item.targetId;
    cell.accessoryType = item.isSelected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ACContactItem *item = [self currentItems][indexPath.row];
    item.isSelected = !item.isSelected;
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self updateUI];
}

- (void)startSend {
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    NSMutableArray *targets = [NSMutableArray array];
    for (ACContactItem *i in mgr.friendList) if (i.isSelected) [targets addObject:i];
    for (ACContactItem *i in mgr.groupList) if (i.isSelected) [targets addObject:i];

    if (targets.count == 0) {
        self.statusLabel.text = @"❌ 请勾选转发目标！";
        return;
    }

    self.floatingSendBtn.enabled = NO;
    __block NSInteger idx = 0;
    __block NSInteger ok = 0;
    NSInteger total = targets.count;

    __block void (^sendNext)(void) = ^{
        if (idx >= total) {
            self.floatingSendBtn.enabled = YES;
            self.statusLabel.text = [NSString stringWithFormat:@"✅ 发送完毕！成功 %ld / 共 %ld", (long)ok, (long)total];
            return;
        }
        ACContactItem *target = targets[idx];
        self.statusLabel.text = [NSString stringWithFormat:@"⏳ 发送中 (%ld/%ld): %@", (long)(idx + 1), (long)total, target.name];
        [mgr sendContentToItem:target completion:^(BOOL success, NSString *err) {
            if (success) ok++;
            idx++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                sendNext();
            });
        }];
    };
    sendNext();
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - 3. 聊天页面长按图片唤醒「转发助手」菜单劫持

%hook UIResponder

// 拦截系统菜单，在长按图片/消息时注入“转发助手”选项
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (action == @selector(ac_handleForwardMenuAction:)) {
        return YES;
    }
    return %orig;
}

%new
- (void)ac_handleForwardMenuAction:(id)sender {
    // 尝试在当前响应链中寻找图片对象
    UIImage *capturedImg = nil;
    if ([self isKindOfClass:[UIImageView class]]) {
        capturedImg = ((UIImageView *)self).image;
    } else if ([self isKindOfClass:[UIView class]]) {
        // 遍历子视图寻找图片
        for (UIView *sub in ((UIView *)self).subviews) {
            if ([sub isKindOfClass:[UIImageView class]] && ((UIImageView *)sub).image) {
                capturedImg = ((UIImageView *)sub).image;
                break;
            }
        }
    }
    
    [ACForwardHelperManager shared].sharedImage = capturedImg;

    // 弹出转发助手窗口
    UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
    UIViewController *rootVC = keyWin.rootViewController;
    ACForwardAssistantVC *vc = [[ACForwardAssistantVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [rootVC presentViewController:nav animated:YES completion:nil];
}

%end

// 动态向聊天界面的 UIMenuController 菜单项中追加「🚀 转发助手」
%hook UIMenuController

- (void)setMenuItems:(NSArray<UIMenuItem *> *)menuItems {
    NSMutableArray *mutableItems = menuItems ? [menuItems mutableCopy] : [NSMutableArray array];
    BOOL hasCustom = NO;
    for (UIMenuItem *item in mutableItems) {
        if ([item.title isEqualToString:@"🚀 转发助手"]) { hasCustom = YES; break; }
    }
    if (!hasCustom) {
        UIMenuItem *customItem = [[UIMenuItem alloc] initWithTitle:@"🚀 转发助手" action:@selector(ac_handleForwardMenuAction:)];
        [mutableItems addObject:customItem];
    }
    %orig(mutableItems);
}

%end
