#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

#pragma mark - 1. 数据模型与管理中心

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
@property (nonatomic, strong) NSMutableSet<NSString *> *friendIdSet;
@property (nonatomic, strong) NSMutableSet<NSString *> *groupIdSet;

+ (instancetype)shared;
- (void)addFriendWithId:(NSString *)uid name:(NSString *)name;
- (void)addGroupWithId:(NSString *)gid name:(NSString *)name;
- (void)reloadAllContacts:(void(^)(NSString *summary))completion;
- (void)sendText:(NSString *)text toItem:(ACContactItem *)item completion:(void(^)(BOOL ok))completion;
@end

@implementation ACForwardHelperManager

+ (instancetype)shared {
    static ACForwardHelperManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ACForwardHelperManager alloc] init];
        instance.friendList = [NSMutableArray array];
        instance.groupList = [NSMutableArray array];
        instance.friendIdSet = [NSMutableSet set];
        instance.groupIdSet = [NSMutableSet set];
    });
    return instance;
}

- (void)addFriendWithId:(NSString *)uid name:(NSString *)name {
    if (!uid || ![uid isKindOfClass:[NSString class]]) return;
    NSString *cleanId = [uid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 过滤自己和系统收藏夹
    if (cleanId.length == 0 || [cleanId hasSuffix:@"_collection"] || [cleanId isEqualToString:@"0"] || [cleanId isEqualToString:@"-1"]) return;
    if ([self.friendIdSet containsObject:cleanId]) {
        // 如果之前只有 ID，现在有了昵称，则更新昵称
        if (name && name.length > 0 && ![name isEqualToString:cleanId]) {
            for (ACContactItem *item in self.friendList) {
                if ([item.targetId isEqualToString:cleanId] && [item.name isEqualToString:cleanId]) {
                    item.name = name;
                    break;
                }
            }
        }
        return;
    }
    [self.friendIdSet addObject:cleanId];
    ACContactItem *item = [[ACContactItem alloc] init];
    item.targetId = cleanId;
    item.name = (name && name.length > 0) ? name : cleanId;
    item.isGroup = NO;
    item.isSelected = NO;
    [self.friendList addObject:item];
}

- (void)addGroupWithId:(NSString *)gid name:(NSString *)name {
    if (!gid || ![gid isKindOfClass:[NSString class]]) return;
    NSString *cleanId = [gid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length == 0 || [cleanId isEqualToString:@"0"]) return;
    if ([self.groupIdSet containsObject:cleanId]) {
        if (name && name.length > 0 && ![name isEqualToString:cleanId]) {
            for (ACContactItem *item in self.groupList) {
                if ([item.targetId isEqualToString:cleanId] && [item.name isEqualToString:cleanId]) {
                    item.name = name;
                    break;
                }
            }
        }
        return;
    }
    [self.groupIdSet addObject:cleanId];
    ACContactItem *item = [[ACContactItem alloc] init];
    item.targetId = cleanId;
    item.name = (name && name.length > 0) ? name : [NSString stringWithFormat:@"群聊 (%@)", cleanId];
    item.isGroup = YES;
    item.isSelected = NO;
    [self.groupList addObject:item];
}

// 核心：四通道全量加载（腾讯IM好友 + 腾讯IM群组 + 腾讯IM会话列表 + 沙盒SQLite全表扫描）
- (void)reloadAllContacts:(void(^)(NSString *summary))completion {
    dispatch_group_t group = dispatch_group_create();

    // 通道 1: 先扫描沙盒内所有 SQLite 数据库 (cache.db / ua.db / uc.db / 腾讯IM内置db)
    [self scanAllSQLiteDatabases];

    // 通道 2: 调用腾讯云 V2TIMManager 获取好友列表、群组列表、会话列表
    Class v2Cls = NSClassFromString(@"V2TIMManager");
    if (v2Cls && [v2Cls respondsToSelector:@selector(sharedInstance)]) {
        id mgr = ((id (*)(id, SEL))objc_msgSend)(v2Cls, @selector(sharedInstance));

        // 2.1 获取 IM 好友列表 (getFriendList:fail:)
        SEL getFriendsSel = NSSelectorFromString(@"getFriendList:fail:");
        if ([mgr respondsToSelector:getFriendsSel]) {
            dispatch_group_enter(group);
            void (^succBlock)(NSArray *) = ^(NSArray *infoList) {
                for (id info in infoList) {
                    @try {
                        NSString *uid = [info valueForKey:@"userID"];
                        NSString *remark = [info valueForKey:@"friendRemark"];
                        id profile = [info valueForKey:@"userFullInfo"];
                        NSString *nick = profile ? [profile valueForKey:@"nickName"] : nil;
                        NSString *displayName = (remark && remark.length > 0) ? [NSString stringWithFormat:@"%@ (%@)", remark, nick ?: uid] : (nick ?: uid);
                        [self addFriendWithId:[NSString stringWithFormat:@"%@", uid] name:displayName];
                    } @catch (NSException *e) {}
                }
                dispatch_group_leave(group);
            };
            void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) {
                dispatch_group_leave(group);
            };
            ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, getFriendsSel, succBlock, failBlock);
        }

        // 2.2 获取 IM 已加入的群聊列表 (getJoinedGroupList:fail:)
        SEL getGroupsSel = NSSelectorFromString(@"getJoinedGroupList:fail:");
        if ([mgr respondsToSelector:getGroupsSel]) {
            dispatch_group_enter(group);
            void (^succBlock)(NSArray *) = ^(NSArray *groupInfos) {
                for (id gInfo in groupInfos) {
                    @try {
                        NSString *gid = [gInfo valueForKey:@"groupID"];
                        NSString *gName = [gInfo valueForKey:@"groupName"];
                        [self addGroupWithId:[NSString stringWithFormat:@"%@", gid] name:gName];
                    } @catch (NSException *e) {}
                }
                dispatch_group_leave(group);
            };
            void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) {
                dispatch_group_leave(group);
            };
            ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, getGroupsSel, succBlock, failBlock);
        }

        // 2.3 获取 IM 最近会话列表 (getConversationList:count:succ:fail:) 把单聊和群聊全部兜底捞出来
        SEL getConvSel = NSSelectorFromString(@"getConversationList:count:succ:fail:");
        if ([mgr respondsToSelector:getConvSel]) {
            dispatch_group_enter(group);
            void (^succBlock)(NSArray *, uint64_t, BOOL) = ^(NSArray *list, uint64_t nextSeq, BOOL isFinished) {
                for (id conv in list) {
                    @try {
                        NSString *showName = [conv valueForKey:@"showName"];
                        NSString *uid = [conv valueForKey:@"userID"];
                        NSString *gid = [conv valueForKey:@"groupID"];
                        if (gid && [gid isKindOfClass:[NSString class]] && gid.length > 0) {
                            [self addGroupWithId:gid name:showName];
                        } else if (uid && [uid isKindOfClass:[NSString class]] && uid.length > 0) {
                            [self addFriendWithId:uid name:showName];
                        }
                    } @catch (NSException *e) {}
                }
                dispatch_group_leave(group);
            };
            void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) {
                dispatch_group_leave(group);
            };
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

    // 通道 3: 兼容旧版 TIMManager getConversationList
    Class timCls = NSClassFromString(@"TIMManager");
    if (timCls && [timCls respondsToSelector:@selector(sharedInstance)]) {
        id timMgr = ((id (*)(id, SEL))objc_msgSend)(timCls, @selector(sharedInstance));
        SEL getConvsSel = NSSelectorFromString(@"getConversationList");
        if ([timMgr respondsToSelector:getConvsSel]) {
            NSArray *convs = ((id (*)(id, SEL))objc_msgSend)(timMgr, getConvsSel);
            if ([convs isKindOfClass:[NSArray class]]) {
                for (id conv in convs) {
                    @try {
                        SEL receiverSel = NSSelectorFromString(@"getReceiver");
                        SEL typeSel = NSSelectorFromString(@"getType");
                        if ([conv respondsToSelector:receiverSel] && [conv respondsToSelector:typeSel]) {
                            NSString *rcv = ((id (*)(id, SEL))objc_msgSend)(conv, receiverSel);
                            NSInteger type = ((NSInteger (*)(id, SEL))objc_msgSend)(conv, typeSel);
                            if (type == 2) {
                                [self addGroupWithId:rcv name:rcv];
                            } else if (type == 1) {
                                [self addFriendWithId:rcv name:rcv];
                            }
                        }
                    } @catch (NSException *e) {}
                }
            }
        }
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSString *msg = [NSString stringWithFormat:@"已同步：%lu 位好友 | %lu 个群聊", (unsigned long)self.friendList.count, (unsigned long)self.groupList.count];
        if (completion) completion(msg);
    });
}

// 深度解析字典中的好友/群信息
- (void)parseJSONObjectForContacts:(id)obj {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        // 识别好友结构 (来自抓包: friendId + nickname / appUserInfo / userInfo)
        NSString *friendId = dict[@"friendId"];
        if (friendId) {
            NSString *nick = dict[@"nickname"] ?: dict[@"remark"] ?: dict[@"appUserInfo"][@"clientUserNickName"] ?: dict[@"clientUserNickName"];
            [self addFriendWithId:[NSString stringWithFormat:@"%@", friendId] name:nick];
        }
        // 识别 userInfo 结构
        if (dict[@"clientUserNickName"] && dict[@"id"]) {
            NSString *uid = [NSString stringWithFormat:@"%@", dict[@"id"]];
            NSString *nick = [NSString stringWithFormat:@"%@", dict[@"clientUserNickName"]];
            // 排除当前登录号自己 (柠檬008 / 1958179249315647489)
            if (![nick isEqualToString:@"柠檬008"]) {
                [self addFriendWithId:uid name:nick];
            }
        }
        // 识别群组结构
        if (dict[@"groupId"] || dict[@"groupName"] || dict[@"groupNo"]) {
            NSString *gid = [NSString stringWithFormat:@"%@", dict[@"groupId"] ?: dict[@"id"] ?: dict[@"groupNo"] ?: @""];
            NSString *gName = [NSString stringWithFormat:@"%@", dict[@"groupName"] ?: dict[@"name"] ?: @"群聊"];
            if (gid.length > 0) [self addGroupWithId:gid name:gName];
        }
        // 递归遍历子字段 (如 data -> records)
        for (id key in dict) {
            id sub = dict[key];
            if ([sub isKindOfClass:[NSDictionary class]] || [sub isKindOfClass:[NSArray class]]) {
                [self parseJSONObjectForContacts:sub];
            }
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            [self parseJSONObjectForContacts:item];
        }
    }
}

// 扫描沙盒所有 SQLite 表 (MyFriendTable, MyGroupTable, userInfo, groupInfo)
- (void)scanAllSQLiteDatabases {
    NSString *home = NSHomeDirectory();
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:home];
    NSString *relPath;
    while ((relPath = [enumerator nextObject])) {
        if ([relPath hasSuffix:@".db"] || [relPath hasSuffix:@".sqlite"] || [relPath hasSuffix:@".sqlite3"]) {
            NSString *fullPath = [home stringByAppendingPathComponent:relPath];
            sqlite3 *db = NULL;
            if (sqlite3_open_v2([fullPath UTF8String], &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
                // 1. MyFriendTable (注意: userId 是当前登录用户，dataStr 里才是好友详情或数组!)
                sqlite3_stmt *stmt = NULL;
                if (sqlite3_prepare_v2(db, "SELECT userId, dataStr FROM MyFriendTable;", -1, &stmt, NULL) == SQLITE_OK) {
                    while (sqlite3_step(stmt) == SQLITE_ROW) {
                        const char *dStr = (const char *)sqlite3_column_text(stmt, 1);
                        if (dStr) {
                            NSData *data = [[NSString stringWithUTF8String:dStr] dataUsingEncoding:NSUTF8StringEncoding];
                            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                            if (json) [self parseJSONObjectForContacts:json];
                        }
                    }
                    sqlite3_finalize(stmt);
                }
                // 2. MyGroupTable
                if (sqlite3_prepare_v2(db, "SELECT userId, dataStr FROM MyGroupTable;", -1, &stmt, NULL) == SQLITE_OK) {
                    while (sqlite3_step(stmt) == SQLITE_ROW) {
                        const char *dStr = (const char *)sqlite3_column_text(stmt, 1);
                        if (dStr) {
                            NSData *data = [[NSString stringWithUTF8String:dStr] dataUsingEncoding:NSUTF8StringEncoding];
                            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                            if (json) [self parseJSONObjectForContacts:json];
                        }
                    }
                    sqlite3_finalize(stmt);
                }
                // 3. 通用扫描表名含 friend / group / userInfo 的表
                const char *sqlTables = "SELECT name FROM sqlite_master WHERE type='table';";
                sqlite3_stmt *tableStmt = NULL;
                if (sqlite3_prepare_v2(db, sqlTables, -1, &tableStmt, NULL) == SQLITE_OK) {
                    while (sqlite3_step(tableStmt) == SQLITE_ROW) {
                        const char *tName = (const char *)sqlite3_column_text(tableStmt, 0);
                        if (!tName) continue;
                        NSString *tableName = [NSString stringWithUTF8String:tName];
                        if ([tableName.lowercaseString containsString:@"friend"] ||
                            [tableName.lowercaseString containsString:@"group"] ||
                            [tableName.lowercaseString containsString:@"userinfo"]) {
                            NSString *query = [NSString stringWithFormat:@"SELECT * FROM %@ LIMIT 500;", tableName];
                            sqlite3_stmt *rowStmt = NULL;
                            if (sqlite3_prepare_v2(db, [query UTF8String], -1, &rowStmt, NULL) == SQLITE_OK) {
                                int colCount = sqlite3_column_count(rowStmt);
                                while (sqlite3_step(rowStmt) == SQLITE_ROW) {
                                    for (int c = 0; c < colCount; c++) {
                                        const char *val = (const char *)sqlite3_column_text(rowStmt, c);
                                        if (val && (val[0] == '{' || val[0] == '[')) {
                                            NSData *d = [[NSString stringWithUTF8String:val] dataUsingEncoding:NSUTF8StringEncoding];
                                            id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                                            if (j) [self parseJSONObjectForContacts:j];
                                        }
                                    }
                                }
                                sqlite3_finalize(rowStmt);
                            }
                        }
                    }
                    sqlite3_finalize(tableStmt);
                }
                sqlite3_close(db);
            }
        }
    }
}

#pragma mark - 2. 腾讯云 IM 消息发送实现

- (void)sendText:(NSString *)text toItem:(ACContactItem *)item completion:(void(^)(BOOL ok))completion {
    if (text.length == 0 || item.targetId.length == 0) {
        if (completion) completion(NO);
        return;
    }

    Class v2MgrCls = NSClassFromString(@"V2TIMManager");
    if (v2MgrCls && [v2MgrCls respondsToSelector:@selector(sharedInstance)]) {
        id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));
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

            NSMethodSignature *sig = [manager methodSignatureForSelector:sendMsgSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:manager];
            [inv setSelector:sendMsgSel];
            [inv setArgument:&v2Msg atIndex:2];
            [inv setArgument:&receiver atIndex:3];
            [inv setArgument:&groupID atIndex:4];
            NSInteger priority = 0;
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
    }

    // 备用 TIMManager 通道
    Class timMgrCls = NSClassFromString(@"TIMManager");
    Class timMsgCls = NSClassFromString(@"TIMMessage");
    Class timTextCls = NSClassFromString(@"TIMTextElem");
    if (timMgrCls && timMsgCls && timTextCls) {
        id manager = ((id (*)(id, SEL))objc_msgSend)(timMgrCls, @selector(sharedInstance));
        SEL getConvSel = NSSelectorFromString(@"getConversation:receiver:");
        if ([manager respondsToSelector:getConvSel]) {
            NSInteger convType = item.isGroup ? 2 : 1;
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

#pragma mark - 3. 被动旁路监听所有 JSON 响应 (自动抓取好友和群)

// 只要 App 自身加载过动态、好友页或群页，NSJSONSerialization 就会自动把里面的好友/群收进列表
%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError * _Nullable *)error {
    id res = %orig;
    if ([res isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)res;
        if (dict[@"code"] && dict[@"data"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[ACForwardHelperManager shared] parseJSONObjectForContacts:dict[@"data"]];
            });
        }
    }
    return res;
}

%end

#pragma mark - 4. 转发助手弹窗界面 (ACForwardAssistantVC)

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

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(dismissSelf)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"刷新数据" style:UIBarButtonItemStyleDone target:self action:@selector(refreshContacts)];

    [self setupUI];
    [self refreshContacts];
}

- (void)setupUI {
    CGFloat width = self.view.bounds.size.width;

    UILabel *tipLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 60, width - 32, 22)];
    tipLabel.text = @"📝 编辑需要群发/转发的消息内容：";
    tipLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.view addSubview:tipLabel];

    self.contentTextView = [[UITextView alloc] initWithFrame:CGRectMake(16, 86, width - 32, 95)];
    self.contentTextView.font = [UIFont systemFontOfSize:15];
    self.contentTextView.layer.cornerRadius = 8;
    self.contentTextView.layer.borderColor = [UIColor separatorColor].CGColor;
    self.contentTextView.layer.borderWidth = 1.0;
    self.contentTextView.text = @"您好，这是一条群发消息！";
    [self.view addSubview:self.contentTextView];

    UIView *actionBar = [[UIView alloc] initWithFrame:CGRectMake(16, 190, width - 32, 34)];
    NSArray *btnTitles = @[@"全选好友", @"全选群聊", @"全选所有", @"取消全选"];
    CGFloat btnW = (width - 32 - 18) / 4.0;
    for (int i = 0; i < 4; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(i * (btnW + 6), 0, btnW, 32);
        [btn setTitle:btnTitles[i] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        btn.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        btn.layer.cornerRadius = 6;
        btn.tag = 200 + i;
        [btn addTarget:self action:@selector(quickSelectAction:) forControlEvents:UIControlEventTouchUpInside];
        [actionBar addSubview:btn];
    }
    [self.view addSubview:actionBar];

    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"好友 (0)", @"群聊 (0)"]];
    self.tabControl.frame = CGRectMake(16, 234, width - 32, 32);
    self.tabControl.selectedSegmentIndex = 0;
    [self.tabControl addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.tabControl];

    CGFloat tableTop = 274;
    CGFloat bottomH = 100;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, tableTop, width, self.view.bounds.size.height - tableTop - bottomH) style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    [self.view addSubview:self.tableView];

    UIView *bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - bottomH, width, bottomH)];
    bottomBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 6, width - 32, 20)];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.text = @"正在从 IM 核心与数据库读取好友和群...";
    [bottomBar addSubview:self.statusLabel];

    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sendButton.frame = CGRectMake(16, 32, width - 32, 46);
    self.sendButton.backgroundColor = [UIColor systemBlueColor];
    [self.sendButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.sendButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.sendButton.layer.cornerRadius = 10;
    [self.sendButton setTitle:@"🚀 立即群发 (已选 0)" forState:UIControlStateNormal];
    [self.sendButton addTarget:self action:@selector(startBatchSend) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:self.sendButton];

    [self.view addSubview:bottomBar];
}

- (void)refreshContacts {
    [self.view endEditing:YES];
    self.statusLabel.text = @"正在同步 IM 好友与群组数据...";
    [[ACForwardHelperManager shared] reloadAllContacts:^(NSString *summary) {
        self.statusLabel.text = summary;
        [self updateTabAndButtonCounts];
        [self.tableView reloadData];
    }];
}

- (void)quickSelectAction:(UIButton *)sender {
    [self.view endEditing:YES];
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    if (sender.tag == 200) {
        for (ACContactItem *i in mgr.friendList) i.isSelected = YES;
    } else if (sender.tag == 201) {
        for (ACContactItem *i in mgr.groupList) i.isSelected = YES;
    } else if (sender.tag == 202) {
        for (ACContactItem *i in mgr.friendList) i.isSelected = YES;
        for (ACContactItem *i in mgr.groupList) i.isSelected = YES;
    } else if (sender.tag == 203) {
        for (ACContactItem *i in mgr.friendList) i.isSelected = NO;
        for (ACContactItem *i in mgr.groupList) i.isSelected = NO;
    }
    [self updateTabAndButtonCounts];
    [self.tableView reloadData];
}

- (void)tabChanged {
    [self.view endEditing:YES];
    [self.tableView reloadData];
}

- (void)updateTabAndButtonCounts {
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    [self.tabControl setTitle:[NSString stringWithFormat:@"好友 (%lu)", (unsigned long)mgr.friendList.count] forSegmentAtIndex:0];
    [self.tabControl setTitle:[NSString stringWithFormat:@"群聊 (%lu)", (unsigned long)mgr.groupList.count] forSegmentAtIndex:1];

    NSInteger selCount = 0;
    for (ACContactItem *i in mgr.friendList) if (i.isSelected) selCount++;
    for (ACContactItem *i in mgr.groupList) if (i.isSelected) selCount++;
    [self.sendButton setTitle:[NSString stringWithFormat:@"🚀 立即群发 (已选 %ld)", (long)selCount] forState:UIControlStateNormal];
}

- (NSArray<ACContactItem *> *)currentItems {
    return self.tabControl.selectedSegmentIndex == 0 ? [ACForwardHelperManager shared].friendList : [ACForwardHelperManager shared].groupList;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self currentItems].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"ACCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    }
    ACContactItem *item = [self currentItems][indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", item.isGroup ? @"👥" : @"👤", item.name];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"ID: %@", item.targetId];
    cell.accessoryType = item.isSelected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self.view endEditing:YES];
    ACContactItem *item = [self currentItems][indexPath.row];
    item.isSelected = !item.isSelected;
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self updateTabAndButtonCounts];
}

- (void)startBatchSend {
    [self.view endEditing:YES];
    NSString *text = [self.contentTextView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) {
        self.statusLabel.text = @"❌ 发送内容不能为空！";
        return;
    }

    NSMutableArray<ACContactItem *> *targets = [NSMutableArray array];
    for (ACContactItem *i in [ACForwardHelperManager shared].friendList) if (i.isSelected) [targets addObject:i];
    for (ACContactItem *i in [ACForwardHelperManager shared].groupList) if (i.isSelected) [targets addObject:i];

    if (targets.count == 0) {
        self.statusLabel.text = @"❌ 请先勾选需要转发的好友或群聊！";
        return;
    }

    self.sendButton.enabled = NO;
    __block NSInteger okCount = 0;
    __block NSInteger idx = 0;
    NSInteger total = targets.count;
    __weak typeof(self) weakSelf = self;

    __block void (^nextStep)(void) = ^{
        if (idx >= total) {
            weakSelf.sendButton.enabled = YES;
            weakSelf.statusLabel.text = [NSString stringWithFormat:@"✅ 群发完毕！成功 %ld / 共 %ld", (long)okCount, (long)total];
            return;
        }
        ACContactItem *cur = targets[idx];
        weakSelf.statusLabel.text = [NSString stringWithFormat:@"⏳ 正在发送 (%ld/%ld): %@", (long)(idx + 1), (long)total, cur.name];
        [[ACForwardHelperManager shared] sendText:text toItem:cur completion:^(BOOL ok) {
            if (ok) okCount++;
            idx++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                nextStep();
            });
        }];
    };
    nextStep();
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - 5. 精准定位「关于飞机」并在其下一行插入「转发助手」

@interface UIView (ACForwardFindHelper)
- (UILabel *)ac_findLabelWithText:(NSString *)targetText;
- (UIViewController *)ac_viewController;
@end

@implementation UIView (ACForwardFindHelper)

- (UILabel *)ac_findLabelWithText:(NSString *)targetText {
    if ([self isKindOfClass:[UILabel class]]) {
        UILabel *lb = (UILabel *)self;
        if (lb.text && [lb.text containsString:targetText]) {
            return lb;
        }
    }
    for (UIView *sub in self.subviews) {
        UILabel *found = [sub ac_findLabelWithText:targetText];
        if (found) return found;
    }
    return nil;
}

- (UIViewController *)ac_viewController {
    UIResponder *responder = self.nextResponder;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

@end

// 当“关于飞机”所在页面的视图布局完成时，自动在“关于飞机”正下方一行挂载“转发助手”
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [self ac_tryInjectBelowAboutRow];
}

- (void)viewDidLayoutSubviews {
    %orig;
    [self ac_tryInjectBelowAboutRow];
}

%new
- (void)ac_tryInjectBelowAboutRow {
    NSString *clsName = NSStringFromClass([self class]);
    // 明确排除“关于飞机”子页面本身 (HelpAboutViewController) 和我们自己的弹窗
    if ([clsName containsString:@"HelpAboutViewController"] || [clsName containsString:@"ACForwardAssistantVC"]) {
        return;
    }

    // 在当前页面的视图树中寻找写着“关于飞机”的文本标签
    UILabel *aboutLabel = [self.view ac_findLabelWithText:@"关于飞机"];
    if (!aboutLabel) return;

    // 向上找到“关于飞机”这一整行的容器行视图 (UITableViewCell 或 AirMenuListView 的单行 itemView)
    UIView *rowView = aboutLabel;
    UIView *containerView = nil;
    while (rowView.superview && rowView.superview != self.view) {
        if ([rowView isKindOfClass:[UITableViewCell class]]) {
            containerView = rowView.superview;
            break;
        }
        // 如果是自定义菜单行（高度在 40~75 之间，宽度超过屏幕一半）
        CGFloat h = rowView.frame.size.height;
        CGFloat w = rowView.frame.size.width;
        if (h >= 40 && h <= 75 && w > self.view.bounds.size.width * 0.6) {
            containerView = rowView.superview;
            break;
        }
        rowView = rowView.superview;
    }

    if (!containerView || !rowView) return;

    // 检查是否已经在“关于飞机”下方创建过“转发助手”行
    UIView *helperRow = [containerView viewWithTag:889966];
    CGRect aboutFrame = [containerView convertRect:rowView.bounds fromView:rowView];
    CGFloat rowHeight = aboutFrame.size.height > 36 ? aboutFrame.size.height : 52.0;
    // 紧贴在“关于飞机”的下一行
    CGRect targetFrame = CGRectMake(aboutFrame.origin.x, CGRectGetMaxY(aboutFrame) + 1.0, aboutFrame.size.width, rowHeight);

    if (!helperRow) {
        helperRow = [[UIView alloc] initWithFrame:targetFrame];
        helperRow.tag = 889966;
        helperRow.backgroundColor = rowView.backgroundColor ?: [UIColor secondarySystemGroupedBackgroundColor];
        helperRow.layer.cornerRadius = rowView.layer.cornerRadius;
        helperRow.clipsToBounds = YES;

        // 顶部分割线
        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(16, 0, targetFrame.size.width - 16, 0.5)];
        line.backgroundColor = [UIColor separatorColor];
        [helperRow addSubview:line];

        // 左侧标题（对齐“关于飞机”的字体与左边距）
        CGRect labelInRow = [rowView convertRect:aboutLabel.bounds fromView:aboutLabel];
        CGFloat leftX = (labelInRow.origin.x > 10 && labelInRow.origin.x < 80) ? labelInRow.origin.x : 16.0;

        UILabel *titleLb = [[UILabel alloc] initWithFrame:CGRectMake(leftX, 0, 200, rowHeight)];
        titleLb.text = @"转发助手";
        titleLb.font = aboutLabel.font ?: [UIFont systemFontOfSize:16];
        titleLb.textColor = aboutLabel.textColor ?: [UIColor labelColor];
        [helperRow addSubview:titleLb];

        // 右侧副标题与箭头
        UILabel *arrowLb = [[UILabel alloc] initWithFrame:CGRectMake(targetFrame.size.width - 135, 0, 120, rowHeight)];
        arrowLb.text = @"群发好友/群  ＞";
        arrowLb.font = [UIFont systemFontOfSize:13];
        arrowLb.textColor = [UIColor secondaryLabelColor];
        arrowLb.textAlignment = NSTextAlignmentRight;
        arrowLb.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [helperRow addSubview:arrowLb];

        // 整行点击按钮
        UIButton *tapBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        tapBtn.frame = helperRow.bounds;
        tapBtn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [tapBtn addTarget:self action:@selector(ac_openForwardHelperModal) forControlEvents:UIControlEventTouchUpInside];
        [helperRow addSubview:tapBtn];

        [containerView addSubview:helperRow];

        // 如果父容器是 UIScrollView / UITableView，自动增加底部可滚动区域或 TableFooter，确保下一行可点击不被截断
        if ([containerView isKindOfClass:[UIScrollView class]]) {
            UIScrollView *sc = (UIScrollView *)containerView;
            UIEdgeInsets inset = sc.contentInset;
            if (inset.bottom < rowHeight + 20) {
                inset.bottom += (rowHeight + 20);
                sc.contentInset = inset;
            }
        }
    } else {
        // 动态跟随“关于飞机”的位置保持在其下一行
        helperRow.frame = targetFrame;
        [containerView bringSubviewToFront:helperRow];
    }
}

%new
- (void)ac_openForwardHelperModal {
    ACForwardAssistantVC *vc = [[ACForwardAssistantVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

%end
