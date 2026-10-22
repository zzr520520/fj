#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

#pragma mark - 1. 全局消息捕获与联系人引擎

// 全局捕获当前长按选中的消息模型
static id __gCurrentMessageModel = nil;
static NSString *__gCapturedForwardText = nil;
static UIImage *__gCapturedForwardImage = nil;

@interface ACContactItem : NSObject
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *fromGroupId;
@property (nonatomic, copy) NSString *roleDesc;
@property (nonatomic, assign) NSInteger sourceType; // 0: 好友, 1: 群成员, 2: 群聊
@property (nonatomic, assign) BOOL isSelected;
@end

@implementation ACContactItem
@end

@interface ACForwardHelperManager : NSObject
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *friendList;
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *groupMemberList;
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *groupList;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *friendMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *groupMemberMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *groupMap;
@property (nonatomic, copy) NSString *selfUserId;

+ (instancetype)shared;
- (void)parseJSONWithContext:(id)jsonObj;
- (void)reloadAllDataWithCompletion:(void(^)(NSString *statusMsg))completion;
- (void)sendCapturedContentToItem:(ACContactItem *)item completion:(void(^)(BOOL ok, NSString *detail))completion;
@end

@implementation ACForwardHelperManager

+ (instancetype)shared {
    static ACForwardHelperManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ACForwardHelperManager alloc] init];
        instance.friendList = [NSMutableArray array];
        instance.groupMemberList = [NSMutableArray array];
        instance.groupList = [NSMutableArray array];
        instance.friendMap = [NSMutableDictionary dictionary];
        instance.groupMemberMap = [NSMutableDictionary dictionary];
        instance.groupMap = [NSMutableDictionary dictionary];
        instance.selfUserId = @"1958179249315647489";
    });
    return instance;
}

- (void)addFriendWithId:(NSString *)uid name:(NSString *)name tag:(NSString *)tag {
    if (!uid) return;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", uid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 5 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:self.selfUserId] || [cleanId hasSuffix:@"_collection"] || [cleanId hasPrefix:@"@TGS#"]) return;
    NSString *cleanName = (name && ![name isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", name] : @"";
    if ([cleanName isEqualToString:@"柠檬008"] || [cleanName isEqualToString:@"收藏夹"]) return;

    if (self.friendMap[cleanId]) return;
    ACContactItem *item = [[ACContactItem alloc] init];
    item.targetId = cleanId;
    item.name = cleanName.length > 0 ? cleanName : [NSString stringWithFormat:@"用户_%@", [cleanId substringFromIndex:MAX(0, (int)cleanId.length - 4)]];
    item.roleDesc = tag ?: @"好友";
    item.sourceType = 0;
    item.isSelected = NO;
    self.friendMap[cleanId] = item;
    [self.friendList addObject:item];
}

- (void)addGroupMemberWithId:(NSString *)uid name:(NSString *)name groupId:(NSString *)gid role:(NSString *)role {
    if (!uid) return;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", uid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 5 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:self.selfUserId] || [cleanId hasPrefix:@"@TGS#"]) return;
    NSString *cleanName = (name && ![name isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", name] : @"";

    if (self.groupMemberMap[cleanId]) return;
    ACContactItem *item = [[ACContactItem alloc] init];
    item.targetId = cleanId;
    item.name = cleanName.length > 0 ? cleanName : [NSString stringWithFormat:@"群友_%@", [cleanId substringFromIndex:MAX(0, (int)cleanId.length - 4)]];
    item.fromGroupId = gid ?: @"";
    item.roleDesc = role ?: @"群成员";
    item.sourceType = 1;
    item.isSelected = NO;
    self.groupMemberMap[cleanId] = item;
    [self.groupMemberList addObject:item];
}

- (void)addGroupWithId:(NSString *)gid name:(NSString *)name {
    if (!gid) return;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", gid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 3 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"0"]) return;
    NSString *cleanName = (name && ![name isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", name] : @"";

    if (self.groupMap[cleanId]) return;
    ACContactItem *item = [[ACContactItem alloc] init];
    item.targetId = cleanId;
    item.name = cleanName.length > 0 ? cleanName : [NSString stringWithFormat:@"群聊 (%@)", cleanId];
    item.sourceType = 2;
    item.roleDesc = @"群组";
    item.isSelected = NO;
    self.groupMap[cleanId] = item;
    [self.groupList addObject:item];
}

- (void)parseJSONWithContext:(id)jsonObj {
    if (!jsonObj) return;
    if ([jsonObj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)jsonObj;
        if (dict[@"appUserExperienceList"] || dict[@"realityValue"]) return;

        NSString *directId = [NSString stringWithFormat:@"%@", dict[@"id"] ?: @""];
        if ([directId hasPrefix:@"@TGS#"] && dict[@"name"]) {
            [self addGroupWithId:directId name:[NSString stringWithFormat:@"%@", dict[@"name"]]];
        }

        NSString *groupId = [NSString stringWithFormat:@"%@", dict[@"groupId"] ?: @""];
        if ([groupId hasPrefix:@"@TGS#"]) {
            [self addGroupWithId:groupId name:dict[@"groupName"]];
            if (dict[@"userId"] && [dict[@"userInfo"] isKindOfClass:[NSDictionary class]]) {
                NSDictionary *uInfo = dict[@"userInfo"];
                [self addGroupMemberWithId:[NSString stringWithFormat:@"%@", dict[@"userId"]] name:uInfo[@"clientUserNickName"] groupId:groupId role:dict[@"role"] ?: @"群成员"];
            }
        }

        id friendId = dict[@"friendId"];
        if (friendId && ![friendId isKindOfClass:[NSNull class]]) {
            NSString *nick = dict[@"nickname"] ?: dict[@"appUserInfo"][@"clientUserNickName"];
            [self addFriendWithId:[NSString stringWithFormat:@"%@", friendId] name:nick tag:@"好友"];
        }

        for (id key in dict) {
            id val = dict[key];
            if ([val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSArray class]]) {
                [self parseJSONWithContext:val];
            }
        }
    } else if ([jsonObj isKindOfClass:[NSArray class]]) {
        for (id sub in (NSArray *)jsonObj) {
            [self parseJSONWithContext:sub];
        }
    }
}

- (void)reloadAllDataWithCompletion:(void(^)(NSString *statusMsg))completion {
    dispatch_group_t group = dispatch_group_create();
    Class v2Cls = NSClassFromString(@"V2TIMManager");
    if (v2Cls && [v2Cls respondsToSelector:@selector(sharedInstance)]) {
        id mgr = ((id (*)(id, SEL))objc_msgSend)(v2Cls, @selector(sharedInstance));
        SEL getConvSel = NSSelectorFromString(@"getConversationList:count:succ:fail:");
        if ([mgr respondsToSelector:getConvSel]) {
            dispatch_group_enter(group);
            void (^succBlock)(NSArray *, uint64_t, BOOL) = ^(NSArray *list, uint64_t nextSeq, BOOL isFinished) {
                for (id conv in list) {
                    @try {
                        NSString *showName = [conv valueForKey:@"showName"];
                        NSString *uid = [conv valueForKey:@"userID"];
                        NSString *gid = [conv valueForKey:@"groupID"];
                        if (gid && gid.length > 0) [self addGroupWithId:gid name:showName];
                        else if (uid && uid.length > 0) [self addFriendWithId:uid name:showName tag:@"会话"];
                    } @catch (NSException *e) {}
                }
                dispatch_group_leave(group);
            };
            void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) { dispatch_group_leave(group); };
            NSMethodSignature *sig = [mgr methodSignatureForSelector:getConvSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:mgr];
            [inv setSelector:getConvSel];
            uint64_t nextSeq = 0;
            int count = 500;
            [inv setArgument:&nextSeq atIndex:2];
            [inv setArgument:&count atIndex:3];
            [inv setArgument:&succBlock atIndex:4];
            [inv setArgument:&failBlock atIndex:5];
            [inv invoke];
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            NSString *msg = [NSString stringWithFormat:@"已加载：%lu 好友 | %lu 群成员 | %lu 群聊",
                             (unsigned long)self.friendList.count,
                             (unsigned long)self.groupMemberList.count,
                             (unsigned long)self.groupList.count];
            if (completion) completion(msg);
        });
    });
}

// 核心转发：完美支持长按捕获到的文本和图片
- (void)sendCapturedContentToItem:(ACContactItem *)item completion:(void(^)(BOOL ok, NSString *detail))completion {
    Class v2MgrCls = NSClassFromString(@"V2TIMManager");
    if (!v2MgrCls || ![v2MgrCls respondsToSelector:@selector(sharedInstance)]) {
        if (completion) completion(NO, @"IM未就绪");
        return;
    }
    id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));

    BOOL isGroup = (item.sourceType == 2);
    NSString *receiver = isGroup ? nil : item.targetId;
    NSString *groupID = isGroup ? item.targetId : nil;

    // 如果捕获到的是图片
    if (__gCapturedForwardImage) {
        NSData *imgData = UIImageJPEGRepresentation(__gCapturedForwardImage, 0.85);
        NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"forward_share.jpg"];
        [imgData writeToFile:tmpPath atomically:YES];

        SEL createImageMsgSel = NSSelectorFromString(@"createImageMessage:");
        if ([manager respondsToSelector:createImageMsgSel]) {
            id imgMsg = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createImageMsgSel, tmpPath);
            if (imgMsg) {
                SEL sendMsgSel = NSSelectorFromString(@"sendMessage:receiver:groupID:priority:onlineUserOnly:offlinePushInfo:progress:succ:fail:");
                void (^succ)(void) = ^{ if (completion) completion(YES, @"图片发送成功"); };
                void (^fail)(int, NSString *) = ^(int c, NSString *d){ if (completion) completion(NO, [NSString stringWithFormat:@"图片发送失败(%d)", c]); };

                NSMethodSignature *sig = [manager methodSignatureForSelector:sendMsgSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:manager];
                [inv setSelector:sendMsgSel];
                [inv setArgument:&imgMsg atIndex:2];
                [inv setArgument:&receiver atIndex:3];
                [inv setArgument:&groupID atIndex:4];
                NSInteger pri = 1; BOOL online = NO; id nilObj = nil;
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
    }

    // 默认转发文本消息
    NSString *textToSend = __gCapturedForwardText ?: (__gCapturedForwardImage ? @"[图片]" : @"[转发助手]");
    SEL createTextSel = NSSelectorFromString(@"createTextMessage:");
    SEL sendMsgSel = NSSelectorFromString(@"sendMessage:receiver:groupID:priority:onlineUserOnly:offlinePushInfo:progress:succ:fail:");

    if ([manager respondsToSelector:createTextSel] && [manager respondsToSelector:sendMsgSel]) {
        id v2Msg = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createTextSel, textToSend);

        void (^succBlock)(void) = ^{
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, @"成功"); });
        };
        void (^failBlock)(int, NSString *) = ^(int code, NSString *desc){
            if (code == 120001 && !isGroup) {
                // 自动加好友破盾重试
                SEL addFriendSel = NSSelectorFromString(@"addFriend:succ:fail:");
                Class reqCls = NSClassFromString(@"V2TIMFriendAddApplication");
                if ([manager respondsToSelector:addFriendSel] && reqCls) {
                    id req = [[reqCls alloc] init];
                    [req setValue:item.targetId forKey:@"userID"];
                    [req setValue:@"你好" forKey:@"addWording"];
                    [req setValue:@(1) forKey:@"addType"];
                    ((void (*)(id, SEL, id, id, id))objc_msgSend)(manager, addFriendSel, req, ^(id r){
                        NSMethodSignature *sig2 = [manager methodSignatureForSelector:sendMsgSel];
                        NSInvocation *inv2 = [NSInvocation invocationWithMethodSignature:sig2];
                        [inv2 setTarget:manager];
                        [inv2 setSelector:sendMsgSel];
                        [inv2 setArgument:&v2Msg atIndex:2];
                        [inv2 setArgument:&receiver atIndex:3];
                        [inv2 setArgument:&groupID atIndex:4];
                        NSInteger pri = 1; BOOL online = NO; id nilObj = nil;
                        [inv2 setArgument:&pri atIndex:5];
                        [inv2 setArgument:&online atIndex:6];
                        [inv2 setArgument:&nilObj atIndex:7];
                        [inv2 setArgument:&nilObj atIndex:8];
                        [inv2 setArgument:&succBlock atIndex:9];
                        [inv2 setArgument:&failBlock atIndex:10];
                        [inv2 invoke];
                    }, ^(int c2, NSString *d2){
                        if (completion) completion(NO, @"(120001)对方开启隐私保护");
                    });
                    return;
                }
            }
            if (completion) completion(NO, [NSString stringWithFormat:@"(%d)%@", code, desc ?: @"失败"]);
        };

        NSMethodSignature *sig = [manager methodSignatureForSelector:sendMsgSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:manager];
        [inv setSelector:sendMsgSel];
        [inv setArgument:&v2Msg atIndex:2];
        [inv setArgument:&receiver atIndex:3];
        [inv setArgument:&groupID atIndex:4];
        NSInteger priority = 1;
        BOOL onlineOnly = NO;
        id nilObj = nil;
        [inv setArgument:&priority atIndex:5];
        [inv setArgument:&onlineOnly atIndex:6];
        [inv setArgument:&nilObj atIndex:7];
        [inv setArgument:&nilObj atIndex:8];
        [inv setArgument:&succBlock atIndex:9];
        [inv setArgument:&failBlock atIndex:10];
        [inv invoke];
        return;
    }
    if (completion) completion(NO, @"发送实例未找到");
}

@end

#pragma mark - 2. 转发助手选择面板 UI

@interface ACForwardAssistantVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *floatingSendBtn;
@end

@implementation ACForwardAssistantVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择转发目标";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.edgesForExtendedLayout = UIRectEdgeNone;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(dismissSelf)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain target:self action:@selector(refreshData)];

    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;

    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"好友", @"群成员", @"群聊"]];
    self.tabControl.frame = CGRectMake(16, 12, width - 32, 32);
    self.tabControl.selectedSegmentIndex = 0;
    [self.tabControl addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.tabControl];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 52, width - 32, 20)];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.text = [NSString stringWithFormat:@"准备转发: %@", __gCapturedForwardImage ? @"[图片]" : (__gCapturedForwardText ?: @"[文本]")];
    [self.view addSubview:self.statusLabel];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 80, width, height - 180) style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = 54.0;
    [self.view addSubview:self.tableView];

    self.floatingSendBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingSendBtn.frame = CGRectMake(width - 140, height - 110, 120, 48);
    self.floatingSendBtn.backgroundColor = [UIColor systemBlueColor];
    [self.floatingSendBtn setTitle:@"🚀 发送 (0)" forState:UIControlStateNormal];
    [self.floatingSendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.floatingSendBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    self.floatingSendBtn.layer.cornerRadius = 24;
    [self.floatingSendBtn addTarget:self action:@selector(startSend) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.floatingSendBtn];

    [self refreshData];
}

- (void)refreshData {
    [[ACForwardHelperManager shared] reloadAllDataWithCompletion:^(NSString *statusMsg) {
        self.statusLabel.text = statusMsg;
        [self.tableView reloadData];
    }];
}

- (void)tabChanged { [self.tableView reloadData]; }

- (NSArray<ACContactItem *> *)currentItems {
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    if (self.tabControl.selectedSegmentIndex == 0) return mgr.friendList;
    if (self.tabControl.selectedSegmentIndex == 1) return mgr.groupMemberList;
    return mgr.groupList;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self currentItems].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell"];
    ACContactItem *item = [self currentItems][indexPath.row];
    cell.textLabel.text = item.name;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"ID: %@", item.targetId];
    cell.accessoryType = item.isSelected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ACContactItem *item = [self currentItems][indexPath.row];
    item.isSelected = !item.isSelected;
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];

    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    NSInteger totalSel = 0;
    for (ACContactItem *i in mgr.friendList) if (i.isSelected) totalSel++;
    for (ACContactItem *i in mgr.groupMemberList) if (i.isSelected) totalSel++;
    for (ACContactItem *i in mgr.groupList) if (i.isSelected) totalSel++;
    [self.floatingSendBtn setTitle:[NSString stringWithFormat:@"🚀 发送 (%ld)", (long)totalSel] forState:UIControlStateNormal];
}

- (void)startSend {
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    NSMutableArray *targets = [NSMutableArray array];
    for (ACContactItem *i in mgr.friendList) if (i.isSelected) [targets addObject:i];
    for (ACContactItem *i in mgr.groupMemberList) if (i.isSelected) [targets addObject:i];
    for (ACContactItem *i in mgr.groupList) if (i.isSelected) [targets addObject:i];

    if (targets.count == 0) return;

    __block NSInteger idx = 0;
    __block NSInteger ok = 0;
    __block void (^loop)(void) = ^{
        if (idx >= targets.count) {
            self.statusLabel.text = [NSString stringWithFormat:@"✅ 转发完成！成功 %ld 个", (long)ok];
            return;
        }
        ACContactItem *target = targets[idx];
        [[ACForwardHelperManager shared] sendCapturedContentToItem:target completion:^(BOOL success, NSString *detail) {
            if (success) ok++;
            idx++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                loop();
            });
        }];
    };
    loop();
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

#pragma mark - 3. 气泡 Cell 拦截 Hook（精准捕获长按消息的文字或图片）

%hook ChatLeftTextCell
- (void)setModel:(id)model {
    %orig;
    __gCurrentMessageModel = model;
}
- (void)setMessage:(id)message {
    %orig;
    __gCurrentMessageModel = message;
}
%end

%hook ChatRightTextCell
- (void)setModel:(id)model {
    %orig;
    __gCurrentMessageModel = model;
}
- (void)setMessage:(id)message {
    %orig;
    __gCurrentMessageModel = message;
}
%end

%hook ChatLeftImageCell
- (void)setModel:(id)model {
    %orig;
    __gCurrentMessageModel = model;
}
%end

%hook ChatRightImageCell
- (void)setModel:(id)model {
    %orig;
    __gCurrentMessageModel = model;
}
%end

#pragma mark - 4. 气泡右键/长按菜单 Hook（完美注入“转发助手”）

%hook UIMenuController

- (void)setMenuItems:(NSArray<UIMenuItem *> *)menuItems {
    NSMutableArray *newItems = [menuItems mutableCopy] ?: [NSMutableArray array];
    BOOL hasMyItem = NO;
    for (UIMenuItem *item in newItems) {
        if ([item.title isEqualToString:@"转发助手"]) { hasMyItem = YES; break; }
    }
    if (!hasMyItem) {
        UIMenuItem *myItem = [[UIMenuItem alloc] initWithTitle:@"🚀 转发助手" action:@selector(ac_handleBubbleForward:)];
        [newItems addObject:myItem];
    }
    %orig(newItems);
}

%end

%hook UIResponder

%new
- (void)ac_handleBubbleForward:(id)sender {
    __gCapturedForwardText = nil;
    __gCapturedForwardImage = nil;

    // 从全局捕获到的消息模型中智能解析文本或图片
    if (__gCurrentMessageModel) {
        @try {
            // 尝试提取文本
            NSString *txt = [__gCurrentMessageModel valueForKey:@"text"] ?: [__gCurrentMessageModel valueForKey:@"content"] ?: [__gCurrentMessageModel valueForKey:@"textMessage"];
            if (txt && [txt isKindOfClass:[NSString class]]) {
                __gCapturedForwardText = txt;
            }
            // 尝试提取图片
            UIImage *img = [__gCurrentMessageModel valueForKey:@"image"] ?: [__gCurrentMessageModel valueForKey:@"thumbImage"];
            if (img && [img isKindOfClass:[UIImage class]]) {
                __gCapturedForwardImage = img;
            }
        } @catch (NSException *e) {}
    }

    // 兜底：如果模型未直接拿到，从通用剪贴板读取
    if (!__gCapturedForwardText && !__gCapturedForwardImage) {
        UIPasteboard *board = [UIPasteboard generalPasteboard];
        if (board.string && board.string.length > 0) {
            __gCapturedForwardText = board.string;
        } else if (board.image) {
            __gCapturedForwardImage = board.image;
        } else {
            __gCapturedForwardText = @"[转发自聊天气泡]";
        }
    }

    // 弹出我们的转发助手控制器
    UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
    UIViewController *rootVC = keyWin.rootViewController;
    while (rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }

    ACForwardAssistantVC *vc = [[ACForwardAssistantVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [rootVC presentViewController:nav animated:YES completion:nil];
}

%end

#pragma mark - 5. 设置页挂载入口

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *clsName = NSStringFromClass([self class]);
    if ([clsName containsString:@"HelpAboutViewController"]) {
        if (self.navigationItem) {
            UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"🚀 转发助手"
                                                                    style:UIBarButtonItemStyleDone
                                                                   target:self
                                                                   action:@selector(ac_openFromAbout)];
            btn.tintColor = [UIColor systemBlueColor];
            self.navigationItem.rightBarButtonItem = btn;
        }
    }
}

%new
- (void)ac_openFromAbout {
    ACForwardAssistantVC *vc = [[ACForwardAssistantVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

%end
