#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

#pragma mark - 1. 全局状态与数据模型

@interface ACContactItem : NSObject
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL isGroup;
@property (nonatomic, assign) BOOL isSelected;
@end

@implementation ACContactItem
@end

@interface ACForwardHelperManager : NSObject
@property (nonatomic, strong) NSMutableDictionary *capturedHeaders;
@property (nonatomic, copy) NSString *currentHost;
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *friendList;
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *groupList;

+ (instancetype)shared;
- (void)fetchAllContactsWithCompletion:(void(^)(BOOL success, NSString *msg))completion;
- (void)sendText:(NSString *)text toItem:(ACContactItem *)item completion:(void(^)(BOOL ok))completion;
@end

@implementation ACForwardHelperManager

+ (instancetype)shared {
    static ACForwardHelperManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ACForwardHelperManager alloc] init];
        instance.capturedHeaders = [NSMutableDictionary dictionary];
        instance.currentHost = @"https://apiv1.airchat.cc";
        instance.friendList = [NSMutableArray array];
        instance.groupList = [NSMutableArray array];
    });
    return instance;
}

// 从接口 + 本地数据库双通道拉取全部好友和群聊
- (void)fetchAllContactsWithCompletion:(void(^)(BOOL success, NSString *msg))completion {
    if (!self.capturedHeaders[@"token"]) {
        // 如果还未抓到网络包，尝试直接从本地 SQLite 读取缓存
        [self loadFromLocalSQLite];
        if (self.friendList.count > 0 || self.groupList.count > 0) {
            if (completion) completion(YES, @"已从本地数据库加载缓存");
            return;
        }
        if (completion) completion(NO, @"尚未捕获到鉴权 Token，请先在 App 内随便点一下切换页面再试");
        return;
    }

    dispatch_group_t group = dispatch_group_create();
    __block BOOL friendOK = NO;
    __block BOOL groupOK = NO;

    // 1. 拉取全部好友 (利用 size=9999 一次性拉取，与 userface/page 逻辑一致)
    dispatch_group_enter(group);
    NSString *friendURL = [NSString stringWithFormat:@"%@/client/biz/userfriends/page?current=1&searchKey=&size=9999", self.currentHost];
    [self requestGET:friendURL completion:^(NSDictionary *json) {
        NSArray *records = json[@"data"][@"records"];
        if ([records isKindOfClass:[NSArray class]]) {
            [self.friendList removeAllObjects];
            for (NSDictionary *dict in records) {
                ACContactItem *item = [[ACContactItem alloc] init];
                item.targetId = [NSString stringWithFormat:@"%@", dict[@"friendId"] ?: dict[@"id"] ?: @""];
                NSString *remark = dict[@"remark"];
                NSString *nick = dict[@"nickname"] ?: dict[@"appUserInfo"][@"clientUserNickName"] ?: @"未知好友";
                item.name = (remark && ![remark isKindOfClass:[NSNull class]] && remark.length > 0) ? [NSString stringWithFormat:@"%@ (%@)", remark, nick] : nick;
                item.isGroup = NO;
                item.isSelected = NO;
                if (item.targetId.length > 0) {
                    [self.friendList addObject:item];
                }
            }
            friendOK = YES;
        }
        dispatch_group_leave(group);
    }];

    // 2. 拉取全部群组
    dispatch_group_enter(group);
    NSString *groupURL = [NSString stringWithFormat:@"%@/client/biz/group/myJoinGroupPage?current=1&searchKey=&size=9999", self.currentHost];
    [self requestGET:groupURL completion:^(NSDictionary *json) {
        NSArray *records = json[@"data"][@"records"];
        if ([records isKindOfClass:[NSArray class]]) {
            [self.groupList removeAllObjects];
            for (NSDictionary *dict in records) {
                ACContactItem *item = [[ACContactItem alloc] init];
                item.targetId = [NSString stringWithFormat:@"%@", dict[@"groupId"] ?: dict[@"groupNo"] ?: dict[@"id"] ?: @""];
                item.name = [NSString stringWithFormat:@"%@", dict[@"groupName"] ?: dict[@"name"] ?: @"群聊"];
                item.isGroup = YES;
                item.isSelected = NO;
                if (item.targetId.length > 0) {
                    [self.groupList addObject:item];
                }
            }
            groupOK = YES;
        }
        dispatch_group_leave(group);
    }];

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        // 如果接口拉取为空，补充扫描本地 SQLite 表
        if (self.friendList.count == 0 && self.groupList.count == 0) {
            [self loadFromLocalSQLite];
        }
        NSString *status = [NSString stringWithFormat:@"已加载 %lu 位好友，%lu 个群聊", (unsigned long)self.friendList.count, (unsigned long)self.groupList.count];
        if (completion) completion(friendOK || groupOK || self.friendList.count > 0, status);
    });
}

- (void)requestGET:(NSString *)urlStr completion:(void(^)(NSDictionary *json))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"GET";
    [self.capturedHeaders enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        [req setValue:obj forHTTPHeaderField:key];
    }];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && !error) {
            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([dict isKindOfClass:[NSDictionary class]]) {
                completion(dict);
                return;
            }
        }
        completion(nil);
    }] resume];
}

// 兜底：从沙盒 SQLite (MyFriendTable / MyGroupTable) 提取数据
- (void)loadFromLocalSQLite {
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *libDir = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    NSArray *searchDirs = @[docDir, libDir];

    for (NSString *dir in searchDirs) {
        NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:dir];
        NSString *relPath;
        while ((relPath = [enumerator nextObject])) {
            if ([relPath hasSuffix:@".db"] || [relPath hasSuffix:@".sqlite"]) {
                NSString *fullPath = [dir stringByAppendingPathComponent:relPath];
                sqlite3 *db = NULL;
                if (sqlite3_open_v2([fullPath UTF8String], &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
                    // 读取好友缓存表 MyFriendTable(userId, dataStr)
                    sqlite3_stmt *stmt = NULL;
                    if (sqlite3_prepare_v2(db, "SELECT userId, dataStr FROM MyFriendTable;", -1, &stmt, NULL) == SQLITE_OK) {
                        while (sqlite3_step(stmt) == SQLITE_ROW) {
                            const char *uId = (const char *)sqlite3_column_text(stmt, 0);
                            const char *dStr = (const char *)sqlite3_column_text(stmt, 1);
                            if (uId && dStr) {
                                NSData *jsonData = [[NSString stringWithUTF8String:dStr] dataUsingEncoding:NSUTF8StringEncoding];
                                NSDictionary *info = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
                                ACContactItem *item = [[ACContactItem alloc] init];
                                item.targetId = [NSString stringWithUTF8String:uId];
                                item.name = info[@"nickname"] ?: info[@"clientUserNickName"] ?: item.targetId;
                                item.isGroup = NO;
                                [self.friendList addObject:item];
                            }
                        }
                        sqlite3_finalize(stmt);
                    }
                    // 读取群组缓存表 MyGroupTable(userId, type, dataStr)
                    if (sqlite3_prepare_v2(db, "SELECT userId, dataStr FROM MyGroupTable;", -1, &stmt, NULL) == SQLITE_OK) {
                        while (sqlite3_step(stmt) == SQLITE_ROW) {
                            const char *dStr = (const char *)sqlite3_column_text(stmt, 1);
                            if (dStr) {
                                NSData *jsonData = [[NSString stringWithUTF8String:dStr] dataUsingEncoding:NSUTF8StringEncoding];
                                NSDictionary *info = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
                                ACContactItem *item = [[ACContactItem alloc] init];
                                item.targetId = [NSString stringWithFormat:@"%@", info[@"groupId"] ?: info[@"id"] ?: @""];
                                item.name = info[@"groupName"] ?: info[@"name"] ?: @"群聊";
                                item.isGroup = YES;
                                if (item.targetId.length > 0) [self.groupList addObject:item];
                            }
                        }
                        sqlite3_finalize(stmt);
                    }
                    sqlite3_close(db);
                }
            }
        }
    }
}

#pragma mark - 2. 腾讯云 IM SDK 消息发送核心实现

- (void)sendText:(NSString *)text toItem:(ACContactItem *)item completion:(void(^)(BOOL ok))completion {
    if (text.length == 0 || item.targetId.length == 0) {
        if (completion) completion(NO);
        return;
    }

    // 方案 A: 优先调用 V2TIMManager (ImSDK_Plus 8.x 主流接口)
    Class v2MgrCls = NSClassFromString(@"V2TIMManager");
    if (v2MgrCls && [v2MgrCls respondsToSelector:@selector(sharedInstance)]) {
        id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));
        SEL sendSimpleSel = NSSelectorFromString(@"sendSimpleTextMessage:to:groupID:priority:onlineUserOnly:offlinePushInfo:succ:fail:");
        SEL createTextSel = NSSelectorFromString(@"createTextMessage:");
        SEL sendMsgSel = NSSelectorFromString(@"sendMessage:receiver:groupID:priority:onlineUserOnly:offlinePushInfo:progress:succ:fail:");

        if ([manager respondsToSelector:createTextSel] && [manager respondsToSelector:sendMsgSel]) {
            id v2Msg = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createTextSel, text);
            NSString *receiver = item.isGroup ? nil : item.targetId;
            NSString *groupID = item.isGroup ? item.targetId : nil;

            void (^succBlock)(void) = ^{
                if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
            };
            void (^failBlock)(int, NSString *) = ^(int code, NSString *desc){
                if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            };

            // 使用 NSInvocation 安全传递多参数与基本数据类型
            NSMethodSignature *sig = [manager methodSignatureForSelector:sendMsgSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:manager];
            [inv setSelector:sendMsgSel];
            [inv setArgument:&v2Msg atIndex:2];
            [inv setArgument:&receiver atIndex:3];
            [inv setArgument:&groupID atIndex:4];
            NSInteger priority = 0; // V2TIM_PRIORITY_DEFAULT
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
        } else if ([manager respondsToSelector:sendSimpleSel]) {
            // 兼容旧版简易发送
            NSString *receiver = item.isGroup ? nil : item.targetId;
            NSString *groupID = item.isGroup ? item.targetId : nil;
            void (^succBlock)(void) = ^{ if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); }); };
            void (^failBlock)(int, NSString *) = ^(int code, NSString *desc){ if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); }); };

            NSMethodSignature *sig = [manager methodSignatureForSelector:sendSimpleSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:manager];
            [inv setSelector:sendSimpleSel];
            [inv setArgument:&text atIndex:2];
            [inv setArgument:&receiver atIndex:3];
            [inv setArgument:&groupID atIndex:4];
            NSInteger priority = 0;
            BOOL onlineOnly = NO;
            id nilObj = nil;
            [inv setArgument:&priority atIndex:5];
            [inv setArgument:&onlineOnly atIndex:6];
            [inv setArgument:&nilObj atIndex:7];
            [inv setArgument:&succBlock atIndex:8];
            [inv setArgument:&failBlock atIndex:9];
            [inv invoke];
            return;
        }
    }

    // 方案 B: 兼容报告中提取出的 TIMManager / TIMConversation / TIMMessage 符号
    Class timMgrCls = NSClassFromString(@"TIMManager");
    Class timMsgCls = NSClassFromString(@"TIMMessage");
    Class timTextCls = NSClassFromString(@"TIMTextElem");
    if (timMgrCls && timMsgCls && timTextCls) {
        id manager = ((id (*)(id, SEL))objc_msgSend)(timMgrCls, @selector(sharedInstance));
        SEL getConvSel = NSSelectorFromString(@"getConversation:receiver:");
        if ([manager respondsToSelector:getConvSel]) {
            NSInteger convType = item.isGroup ? 2 : 1; // 1 = C2C, 2 = GROUP
            id conv = ((id (*)(id, SEL, NSInteger, NSString *))objc_msgSend)(manager, getConvSel, convType, item.targetId);
            id msg = [[timMsgCls alloc] init];
            id elem = [[timTextCls alloc] init];
            [elem setValue:text forKey:@"text"];
            ((int (*)(id, SEL, id))objc_msgSend)(msg, NSSelectorFromString(@"addElem:"), elem);

            SEL sendSel = NSSelectorFromString(@"sendMessage:succ:fail:");
            if ([conv respondsToSelector:sendSel]) {
                void (^succBlock)(void) = ^{ if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); }); };
                void (^failBlock)(int, NSString *) = ^(int code, NSString *desc){ if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); }); };
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(conv, sendSel, msg, succBlock, failBlock);
                return;
            }
        }
    }

    if (completion) completion(NO);
}

@end

#pragma mark - 3. 转发助手 UI 面板 (ACForwardAssistantVC)

@interface ACForwardAssistantVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITextView *contentTextView;
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *sendButton;
@end

@implementation ACForwardAssistantVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"转发助手";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(dismissSelf)];
    self.navigationItem.leftBarButtonItem = closeItem;

    UIBarButtonItem *refreshItem = [[UIBarButtonItem alloc] initWithTitle:@"刷新列表" style:UIBarButtonItemStylePlain target:self action:@selector(reloadDataFromServer)];
    self.navigationItem.rightBarButtonItem = refreshItem;

    [self setupUI];
    [self reloadDataFromServer];
}

- (void)setupUI {
    CGFloat width = self.view.bounds.size.width;

    // 1. 消息内容编辑框
    UILabel *tipLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 60, width - 32, 24)];
    tipLabel.text = @"📝 编辑群发/转发内容：";
    tipLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.view addSubview:tipLabel];

    self.contentTextView = [[UITextView alloc] initWithFrame:CGRectMake(16, 88, width - 32, 100)];
    self.contentTextView.font = [UIFont systemFontOfSize:15];
    self.contentTextView.layer.cornerRadius = 8;
    self.contentTextView.layer.borderColor = [UIColor separatorColor].CGColor;
    self.contentTextView.layer.borderWidth = 1.0;
    self.contentTextView.text = @"您好，这是一条来自【转发助手】的群发消息！";
    [self.view addSubview:self.contentTextView];

    // 2. 快捷勾选操作栏
    UIView *actionBar = [[UIView alloc] initWithFrame:CGRectMake(16, 198, width - 32, 36)];
    NSArray *btnTitles = @[@"全选好友", @"全选群聊", @"全选所有", @"清空选择"];
    CGFloat btnW = (width - 32 - 18) / 4.0;
    for (int i = 0; i < 4; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(i * (btnW + 6), 0, btnW, 34);
        [btn setTitle:btnTitles[i] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        btn.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        btn.layer.cornerRadius = 6;
        btn.tag = 100 + i;
        [btn addTarget:self action:@selector(quickSelectAction:) forControlEvents:UIControlEventTouchUpInside];
        [actionBar addSubview:btn];
    }
    [self.view addSubview:actionBar];

    // 3. 好友 / 群聊 切换栏
    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"好友列表 (0)", @"群聊列表 (0)"]];
    self.tabControl.frame = CGRectMake(16, 244, width - 32, 32);
    self.tabControl.selectedSegmentIndex = 0;
    [self.tabControl addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.tabControl];

    // 4. 列表视图
    CGFloat tableTop = 286;
    CGFloat bottomBarH = 100;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, tableTop, width, self.view.bounds.size.height - tableTop - bottomBarH) style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.allowsMultipleSelection = YES;
    [self.view addSubview:self.tableView];

    // 5. 底部状态与一键群发按钮
    UIView *bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - bottomBarH, width, bottomBarH)];
    bottomBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, width - 32, 20)];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.text = @"正在读取账号好友与群聊数据...";
    [bottomBar addSubview:self.statusLabel];

    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sendButton.frame = CGRectMake(16, 34, width - 32, 46);
    self.sendButton.backgroundColor = [UIColor systemBlueColor];
    [self.sendButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.sendButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.sendButton.layer.cornerRadius = 10;
    [self.sendButton setTitle:@"🚀 一键转发 / 群发 (已选 0)" forState:UIControlStateNormal];
    [self.sendButton addTarget:self action:@selector(startBatchForward) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:self.sendButton];

    [self.view addSubview:bottomBar];
}

- (void)reloadDataFromServer {
    [self.view endEditing:YES];
    self.statusLabel.text = @"正在同步最新好友与群聊列表...";
    [[ACForwardHelperManager shared] fetchAllContactsWithCompletion:^(BOOL success, NSString *msg) {
        self.statusLabel.text = msg;
        [self updateCountsUI];
        [self.tableView reloadData];
    }];
}

- (void)quickSelectAction:(UIButton *)sender {
    [self.view endEditing:YES];
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    if (sender.tag == 100) { // 全选好友
        for (ACContactItem *item in mgr.friendList) item.isSelected = YES;
    } else if (sender.tag == 101) { // 全选群聊
        for (ACContactItem *item in mgr.groupList) item.isSelected = YES;
    } else if (sender.tag == 102) { // 全选所有
        for (ACContactItem *item in mgr.friendList) item.isSelected = YES;
        for (ACContactItem *item in mgr.groupList) item.isSelected = YES;
    } else if (sender.tag == 103) { // 清空
        for (ACContactItem *item in mgr.friendList) item.isSelected = NO;
        for (ACContactItem *item in mgr.groupList) item.isSelected = NO;
    }
    [self updateCountsUI];
    [self.tableView reloadData];
}

- (void)tabChanged {
    [self.view endEditing:YES];
    [self.tableView reloadData];
}

- (void)updateCountsUI {
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    [self.tabControl setTitle:[NSString stringWithFormat:@"好友 (%lu)", (unsigned long)mgr.friendList.count] forSegmentAtIndex:0];
    [self.tabControl setTitle:[NSString stringWithFormat:@"群聊 (%lu)", (unsigned long)mgr.groupList.count] forSegmentAtIndex:1];

    NSInteger selectedCount = 0;
    for (ACContactItem *i in mgr.friendList) if (i.isSelected) selectedCount++;
    for (ACContactItem *i in mgr.groupList) if (i.isSelected) selectedCount++;

    [self.sendButton setTitle:[NSString stringWithFormat:@"🚀 一键转发 / 群发 (已选 %ld)", (long)selectedCount] forState:UIControlStateNormal];
}

- (NSArray<ACContactItem *> *)currentDataSource {
    return self.tabControl.selectedSegmentIndex == 0 ? [ACForwardHelperManager shared].friendList : [ACForwardHelperManager shared].groupList;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self currentDataSource].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"ACContactCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    }
    ACContactItem *item = [self currentDataSource][indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", item.isGroup ? @"👥" : @"👤", item.name];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"ID: %@", item.targetId];
    cell.accessoryType = item.isSelected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self.view endEditing:YES];
    ACContactItem *item = [self currentDataSource][indexPath.row];
    item.isSelected = !item.isSelected;
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self updateCountsUI];
}

// 队列依次群发（自带 350ms 间隔防腾讯 IM 频率限制）
- (void)startBatchForward {
    [self.view endEditing:YES];
    NSString *content = [self.contentTextView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (content.length == 0) {
        self.statusLabel.text = @"❌ 请输入要转发的文本内容！";
        return;
    }

    NSMutableArray<ACContactItem *> *targets = [NSMutableArray array];
    for (ACContactItem *i in [ACForwardHelperManager shared].friendList) if (i.isSelected) [targets addObject:i];
    for (ACContactItem *i in [ACForwardHelperManager shared].groupList) if (i.isSelected) [targets addObject:i];

    if (targets.count == 0) {
        self.statusLabel.text = @"❌ 请至少勾选一个好友或群聊！";
        return;
    }

    self.sendButton.enabled = NO;
    __block NSInteger successCount = 0;
    __block NSInteger currentIndex = 0;
    NSInteger total = targets.count;

    __weak typeof(self) weakSelf = self;
    __block void (^sendNext)(void) = ^{
        if (currentIndex >= total) {
            weakSelf.sendButton.enabled = YES;
            weakSelf.statusLabel.text = [NSString stringWithFormat:@"✅ 群发完成！成功: %ld / 总计: %ld", (long)successCount, (long)total];
            return;
        }
        ACContactItem *currentItem = targets[currentIndex];
        weakSelf.statusLabel.text = [NSString stringWithFormat:@"⏳ 正在发送 (%ld/%ld): %@", (long)(currentIndex + 1), (long)total, currentItem.name];

        [[ACForwardHelperManager shared] sendText:content toItem:currentItem completion:^(BOOL ok) {
            if (ok) successCount++;
            currentIndex++;
            // 间隔 0.35 秒发送下一条，防止触发 /client/biz/v2/violation/banStatus 风控
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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

#pragma mark - 4. 自动嗅探抓包 Header 与 设置栏固定入口 Hook

// 拦截 NSURLSession 请求，自动提取 token / x-userid / X-Lts-Id
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSString *host = request.URL.host;
    if (host && [host containsString:@"airchat"]) {
        NSDictionary *headers = request.allHTTPHeaderFields;
        if (headers[@"token"] && headers[@"x-userid"]) {
            [[ACForwardHelperManager shared].capturedHeaders addEntriesFromDictionary:headers];
            [ACForwardHelperManager shared].currentHost = [NSString stringWithFormat:@"%@://%@", request.URL.scheme, host];
        }
    }
    return %orig;
}

%end

// 在设置栏与“我的”页面固定挂载【转发助手】
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *clsName = NSStringFromClass([self class]);

    // 匹配 pages/me/ 下的“我的”主页与设置相关控制器
    BOOL isSettingOrMePage = [clsName containsString:@"AccountSecurityViewController"] ||
                             [clsName containsString:@"LoginSetupViewController"] ||
                             [clsName containsString:@"HelpAboutViewController"] ||
                             [clsName containsString:@"AppearanceSetupViewController"] ||
                             [clsName containsString:@"MeViewController"] ||
                             [clsName containsString:@"MineViewController"] ||
                             [clsName containsString:@"Setting"];

    if (isSettingOrMePage) {
        // 1. 在导航栏右侧固定挂载【转发助手】按钮
        if (self.navigationItem) {
            UIBarButtonItem *helperBtn = [[UIBarButtonItem alloc] initWithTitle:@"🚀转发助手"
                                                                          style:UIBarButtonItemStyleDone
                                                                         target:self
                                                                         action:@selector(ac_openForwardHelper)];
            helperBtn.tintColor = [UIColor systemBlueColor];
            self.navigationItem.rightBarButtonItem = helperBtn;
        }

        // 2. 同时在设置页底部或顶部固定挂载一个嵌入式入口条，防止自定义导航栏遮挡
        UIView *existingBar = [self.view viewWithTag:998877];
        if (!existingBar) {
            CGFloat w = self.view.bounds.size.width;
            UIButton *entryCellBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            entryCellBtn.tag = 998877;
            entryCellBtn.frame = CGRectMake(16, 100, w - 32, 48);
            entryCellBtn.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
            entryCellBtn.layer.cornerRadius = 10;
            entryCellBtn.layer.shadowColor = [UIColor blackColor].CGColor;
            entryCellBtn.layer.shadowOpacity = 0.08;
            entryCellBtn.layer.shadowOffset = CGSizeMake(0, 2);
            [entryCellBtn setTitle:@"⚙️ 转发助手（点击打开全选好友/群聊群发）   ＞" forState:UIControlStateNormal];
            [entryCellBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
            entryCellBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            [entryCellBtn addTarget:self action:@selector(ac_openForwardHelper) forControlEvents:UIControlEventTouchUpInside];
            [self.view addSubview:entryCellBtn];
        }
    }
}

%new
- (void)ac_openForwardHelper {
    ACForwardAssistantVC *vc = [[ACForwardAssistantVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

%end
