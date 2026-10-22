#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

#pragma mark - 1. 联系人模型与全量数据引擎

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
@property (nonatomic, copy) NSString *selfUserId;

+ (instancetype)shared;
- (void)addFriendWithId:(NSString *)uid name:(NSString *)name;
- (void)addGroupWithId:(NSString *)gid name:(NSString *)name;
- (void)parseAnyJSON:(id)jsonObj;
- (void)reloadAllDataWithCompletion:(void(^)(NSString *statusMsg))completion;
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
        instance.selfUserId = @"1958179249315647489"; // 默认排除自己，也会从请求头动态更新
    });
    return instance;
}

- (void)addFriendWithId:(NSString *)uid name:(NSString *)name {
    if (!uid) return;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", uid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 5 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"<null>"]) return;
    if ([cleanId isEqualToString:self.selfUserId] || [cleanId hasSuffix:@"_collection"]) return;

    NSString *cleanName = (name && ![name isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", name] : @"";
    if ([cleanName isEqualToString:@"柠檬008"] || [cleanName isEqualToString:@"收藏夹"]) return;

    if ([self.friendIdSet containsObject:cleanId]) {
        if (cleanName.length > 0 && ![cleanName isEqualToString:cleanId]) {
            for (ACContactItem *item in self.friendList) {
                if ([item.targetId isEqualToString:cleanId] && [item.name isEqualToString:cleanId]) {
                    item.name = cleanName;
                    break;
                }
            }
        }
        return;
    }

    [self.friendIdSet addObject:cleanId];
    ACContactItem *item = [[ACContactItem alloc] init];
    item.targetId = cleanId;
    item.name = cleanName.length > 0 ? cleanName : [NSString stringWithFormat:@"好友_%@", [cleanId substringFromIndex:MAX(0, (int)cleanId.length - 4)]];
    item.isGroup = NO;
    item.isSelected = NO;
    [self.friendList addObject:item];
}

- (void)addGroupWithId:(NSString *)gid name:(NSString *)name {
    if (!gid) return;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", gid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 3 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"<null>"] || [cleanId isEqualToString:@"0"]) return;

    NSString *cleanName = (name && ![name isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", name] : @"";

    if ([self.groupIdSet containsObject:cleanId]) {
        if (cleanName.length > 0 && ![cleanName isEqualToString:cleanId]) {
            for (ACContactItem *item in self.groupList) {
                if ([item.targetId isEqualToString:cleanId] && [item.name hasPrefix:@"群聊"]) {
                    item.name = cleanName;
                    break;
                }
            }
        }
        return;
    }

    [self.groupIdSet addObject:cleanId];
    ACContactItem *item = [[ACContactItem alloc] init];
    item.targetId = cleanId;
    item.name = cleanName.length > 0 ? cleanName : [NSString stringWithFormat:@"群聊 (%@)", cleanId];
    item.isGroup = YES;
    item.isSelected = NO;
    [self.groupList addObject:item];
}

// 递归提取任何 JSON 字典/数组中的好友与群聊数据
- (void)parseAnyJSON:(id)jsonObj {
    if (!jsonObj) return;
    if ([jsonObj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)jsonObj;

        // 1. 匹配 /client/biz/userfriends/page 结构 (friendId + nickname / appUserInfo)
        id friendId = dict[@"friendId"];
        if (friendId && ![friendId isKindOfClass:[NSNull class]]) {
            NSString *remark = dict[@"remark"];
            NSString *nick = dict[@"nickname"];
            if ((!nick || [nick isKindOfClass:[NSNull class]]) && [dict[@"appUserInfo"] isKindOfClass:[NSDictionary class]]) {
                nick = dict[@"appUserInfo"][@"clientUserNickName"];
            }
            NSString *finalName = (remark && ![remark isKindOfClass:[NSNull class]] && [remark description].length > 0) ? [NSString stringWithFormat:@"%@ (%@)", remark, nick ?: @""] : nick;
            [self addFriendWithId:[NSString stringWithFormat:@"%@", friendId] name:finalName];
        }

        // 2. 匹配 userInfo / appUserInfo 结构
        id clientNick = dict[@"clientUserNickName"];
        id uid = dict[@"id"] ?: dict[@"userId"] ?: dict[@"clientUserId"];
        if (clientNick && ![clientNick isKindOfClass:[NSNull class]] && uid && ![uid isKindOfClass:[NSNull class]]) {
            [self addFriendWithId:[NSString stringWithFormat:@"%@", uid] name:[NSString stringWithFormat:@"%@", clientNick]];
        }

        // 3. 匹配 /client/biz/group/myJoinGroupPage 或群结构
        id groupId = dict[@"groupId"] ?: dict[@"groupNo"] ?: dict[@"imGroupId"];
        id groupName = dict[@"groupName"] ?: dict[@"groupTitle"];
        if (groupId && ![groupId isKindOfClass:[NSNull class]]) {
            NSString *gName = (groupName && ![groupName isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", groupName] : [NSString stringWithFormat:@"%@", dict[@"name"] ?: @"群聊"];
            [self addGroupWithId:[NSString stringWithFormat:@"%@", groupId] name:gName];
        } else if (groupName && ![groupName isKindOfClass:[NSNull class]] && dict[@"id"]) {
            [self addGroupWithId:[NSString stringWithFormat:@"%@", dict[@"id"]] name:[NSString stringWithFormat:@"%@", groupName]];
        }

        for (id key in dict) {
            id val = dict[key];
            if ([val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSArray class]]) {
                [self parseAnyJSON:val];
            } else if ([val isKindOfClass:[NSString class]]) {
                NSString *strVal = (NSString *)val;
                if ([strVal hasPrefix:@"{"] || [strVal hasPrefix:@"["]) {
                    NSData *subData = [strVal dataUsingEncoding:NSUTF8StringEncoding];
                    id subJson = [NSJSONSerialization JSONObjectWithData:subData options:0 error:nil];
                    if (subJson) [self parseAnyJSON:subJson];
                }
            }
        }
    } else if ([jsonObj isKindOfClass:[NSArray class]]) {
        for (id sub in (NSArray *)jsonObj) {
            [self parseAnyJSON:sub];
        }
    }
}

// 扫描沙盒内全部 SQLite (.db / .sqlite) + Realm (contact_friends.realm)
- (void)scanLocalDatabases {
    NSString *home = NSHomeDirectory();
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:home];
    NSString *relPath;
    while ((relPath = [enumerator nextObject])) {
        NSString *lower = relPath.lowercaseString;
        NSString *fullPath = [home stringByAppendingPathComponent:relPath];

        // A. 扫描所有 SQLite 数据库文件 (不限后缀，检测 SQLite 魔数或 .db/.sqlite)
        if ([lower hasSuffix:@".db"] || [lower hasSuffix:@".sqlite"] || [lower hasSuffix:@".sqlite3"] || [lower containsString:@"cache"] || [lower containsString:@"imsdk"]) {
            sqlite3 *db = NULL;
            if (sqlite3_open_v2([fullPath UTF8String], &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
                sqlite3_stmt *tableStmt = NULL;
                if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table';", -1, &tableStmt, NULL) == SQLITE_OK) {
                    NSMutableArray<NSString *> *tables = [NSMutableArray array];
                    while (sqlite3_step(tableStmt) == SQLITE_ROW) {
                        const char *tName = (const char *)sqlite3_column_text(tableStmt, 0);
                        if (tName) [tables addObject:[NSString stringWithUTF8String:tName]];
                    }
                    sqlite3_finalize(tableStmt);

                    for (NSString *t in tables) {
                        NSString *sql = [NSString stringWithFormat:@"SELECT * FROM \"%@\" LIMIT 1000;", t];
                        sqlite3_stmt *rowStmt = NULL;
                        if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &rowStmt, NULL) == SQLITE_OK) {
                            int colCount = sqlite3_column_count(rowStmt);
                            while (sqlite3_step(rowStmt) == SQLITE_ROW) {
                                NSMutableDictionary *rowDict = [NSMutableDictionary dictionary];
                                for (int c = 0; c < colCount; c++) {
                                    const char *colName = sqlite3_column_name(rowStmt, c);
                                    const char *colText = (const char *)sqlite3_column_text(rowStmt, c);
                                    if (!colName || !colText) continue;
                                    NSString *k = [NSString stringWithUTF8String:colName];
                                    NSString *v = [NSString stringWithUTF8String:colText];
                                    rowDict[k] = v;
                                    // 如果单元格本身是 JSON 字符串 (例如 MyFriendTable.dataStr / MyGroupTable.dataStr)
                                    if ([v hasPrefix:@"{"] || [v hasPrefix:@"["]) {
                                        NSData *d = [v dataUsingEncoding:NSUTF8StringEncoding];
                                        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                                        if (j) [self parseAnyJSON:j];
                                    }
                                }
                                [self parseAnyJSON:rowDict];
                            }
                            sqlite3_finalize(rowStmt);
                        }
                    }
                }
                sqlite3_close(db);
            }
        }

        // B. 扫描 contact_friends.realm (通过 RLMRealm 动态读取或直接提取里面的明文 UTF-8 块)
        if ([lower hasSuffix:@".realm"] && [lower containsString:@"friend"]) {
            Class rlmCls = NSClassFromString(@"RLMRealm");
            SEL realmWithURLSel = NSSelectorFromString(@"realmWithURL:error:");
            if (rlmCls && [rlmCls respondsToSelector:realmWithURLSel]) {
                @try {
                    NSURL *url = [NSURL fileURLWithPath:fullPath];
                    id realm = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(rlmCls, realmWithURLSel, url, NULL);
                    id schema = [realm valueForKey:@"schema"];
                    NSArray *objSchemas = [schema valueForKey:@"objectSchema"];
                    for (id os in objSchemas) {
                        NSString *className = [os valueForKey:@"className"];
                        SEL allObjSel = NSSelectorFromString(@"allObjectsInRealm:");
                        Class modelCls = NSClassFromString(className);
                        if (modelCls && [modelCls respondsToSelector:allObjSel]) {
                            id results = ((id (*)(id, SEL, id))objc_msgSend)(modelCls, allObjSel, realm);
                            NSUInteger count = [[results valueForKey:@"count"] unsignedIntegerValue];
                            for (NSUInteger i = 0; i < count; i++) {
                                id obj = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(results, @selector(objectAtIndex:), i);
                                NSArray *props = [os valueForKey:@"properties"];
                                NSMutableDictionary *md = [NSMutableDictionary dictionary];
                                for (id p in props) {
                                    NSString *pName = [p valueForKey:@"name"];
                                    id pVal = [obj valueForKey:pName];
                                    if (pName && pVal) md[pName] = pVal;
                                }
                                [self parseAnyJSON:md];
                            }
                        }
                    }
                } @catch (NSException *e) {}
            }
        }
    }
}

// 自动触发 TabBar 中“联系人”页面的加载（如果用户还没点过“联系人”Tab，让 App 自动去请求一次好友与群列表）
- (void)triggerAppContactTabLoadIfNeeded {
    UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
    if (!keyWin) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { keyWin = w; break; }
        }
    }
    UIViewController *rootVC = keyWin.rootViewController;
    if ([rootVC isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tabVC = (UITabBarController *)rootVC;
        for (UIViewController *child in tabVC.viewControllers) {
            if ([child isKindOfClass:[UINavigationController class]]) {
                UINavigationController *nav = (UINavigationController *)child;
                UIViewController *top = nav.viewControllers.firstObject;
                if (top) {
                    // 触发 view 加载，让联系人 VC 自动发出 userfriends/page 和 group/myJoinGroupPage 请求
                    (void)top.view;
                }
            } else {
                (void)child.view;
            }
        }
    }
}

- (void)reloadAllDataWithCompletion:(void(^)(NSString *statusMsg))completion {
    // 1. 触发联系人 Tab 预加载
    [self triggerAppContactTabLoadIfNeeded];

    // 2. 扫描本地 SQLite + Realm
    [self scanLocalDatabases];

    // 3. 读取腾讯云 V2TIMManager 会话列表与群列表
    dispatch_group_t group = dispatch_group_create();
    Class v2Cls = NSClassFromString(@"V2TIMManager");
    if (v2Cls && [v2Cls respondsToSelector:@selector(sharedInstance)]) {
        id mgr = ((id (*)(id, SEL))objc_msgSend)(v2Cls, @selector(sharedInstance));

        // 3.1 获取腾讯云 IM 会话列表 (单聊 + 群聊)
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

        // 3.2 获取腾讯云 IM 已加入群列表
        SEL getGroupsSel = NSSelectorFromString(@"getJoinedGroupList:fail:");
        if ([mgr respondsToSelector:getGroupsSel]) {
            dispatch_group_enter(group);
            void (^succBlock)(NSArray *) = ^(NSArray *groupInfos) {
                for (id gInfo in groupInfos) {
                    @try {
                        NSString *gid = [gInfo valueForKey:@"groupID"];
                        NSString *gName = [gInfo valueForKey:@"groupName"];
                        [self addGroupWithId:gid name:gName];
                    } @catch (NSException *e) {}
                }
                dispatch_group_leave(group);
            };
            void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) {
                dispatch_group_leave(group);
            };
            ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, getGroupsSel, succBlock, failBlock);
        }
    }

    // 延迟 0.6 秒等待异步网络/数据库汇总
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            NSString *msg = [NSString stringWithFormat:@"已加载 %lu 位好友 | %lu 个群聊", (unsigned long)self.friendList.count, (unsigned long)self.groupList.count];
            if (self.friendList.count == 0 && self.groupList.count == 0) {
                msg = @"提示：请先点一下底部【联系人】页面加载列表，再回来打开即可全量读取！";
            }
            if (completion) completion(msg);
        });
    });
}

#pragma mark - 2. 腾讯 IM 发送消息实现

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

#pragma mark - 3. 全局拦截 JSON 解析 (App 任何地方收到的好友/群数据自动入库)

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError * _Nullable *)error {
    id res = %orig;
    if ([res isKindOfClass:[NSDictionary class]] || [res isKindOfClass:[NSArray class]]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[ACForwardHelperManager shared] parseAnyJSON:res];
        });
    }
    return res;
}

%end

#pragma mark - 4. 转发助手弹窗控制器 (ACForwardAssistantVC)

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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"刷新列表" style:UIBarButtonItemStyleDone target:self action:@selector(refreshData)];

    [self setupUI];
    [self refreshData];
}

- (void)setupUI {
    CGFloat width = self.view.bounds.size.width;

    UILabel *tipLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 60, width - 32, 22)];
    tipLabel.text = @"📝 编辑群发/转发内容：";
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
        btn.tag = 300 + i;
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

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 6, width - 24, 20)];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.adjustsFontSizeToFitWidth = YES;
    self.statusLabel.text = @"正在读取好友与群聊...";
    [bottomBar addSubview:self.statusLabel];

    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sendButton.frame = CGRectMake(16, 32, width - 32, 46);
    self.sendButton.backgroundColor = [UIColor systemBlueColor];
    [self.sendButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.sendButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.sendButton.layer.cornerRadius = 10;
    [self.sendButton setTitle:@"🚀 一键转发 / 群发 (已选 0)" forState:UIControlStateNormal];
    [self.sendButton addTarget:self action:@selector(startBatchSend) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:self.sendButton];

    [self.view addSubview:bottomBar];
}

- (void)refreshData {
    [self.view endEditing:YES];
    self.statusLabel.text = @"正在同步账号好友与群聊数据...";
    [[ACForwardHelperManager shared] reloadAllDataWithCompletion:^(NSString *statusMsg) {
        self.statusLabel.text = statusMsg;
        [self updateUI];
        [self.tableView reloadData];
    }];
}

- (void)quickSelectAction:(UIButton *)sender {
    [self.view endEditing:YES];
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    if (sender.tag == 300) {
        for (ACContactItem *i in mgr.friendList) i.isSelected = YES;
    } else if (sender.tag == 301) {
        for (ACContactItem *i in mgr.groupList) i.isSelected = YES;
    } else if (sender.tag == 302) {
        for (ACContactItem *i in mgr.friendList) i.isSelected = YES;
        for (ACContactItem *i in mgr.groupList) i.isSelected = YES;
    } else if (sender.tag == 303) {
        for (ACContactItem *i in mgr.friendList) i.isSelected = NO;
        for (ACContactItem *i in mgr.groupList) i.isSelected = NO;
    }
    [self updateUI];
    [self.tableView reloadData];
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
    [self.sendButton setTitle:[NSString stringWithFormat:@"🚀 一键转发 / 群发 (已选 %ld)", (long)selCount] forState:UIControlStateNormal];
}

- (NSArray<ACContactItem *> *)currentItems {
    return self.tabControl.selectedSegmentIndex == 0 ? [ACForwardHelperManager shared].friendList : [ACForwardHelperManager shared].groupList;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self currentItems].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"ACContactCell";
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
    [self updateUI];
}

- (void)startBatchSend {
    [self.view endEditing:YES];
    NSString *text = [self.contentTextView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) {
        self.statusLabel.text = @"❌ 请输入要转发的消息内容！";
        return;
    }

    NSMutableArray<ACContactItem *> *targets = [NSMutableArray array];
    for (ACContactItem *i in [ACForwardHelperManager shared].friendList) if (i.isSelected) [targets addObject:i];
    for (ACContactItem *i in [ACForwardHelperManager shared].groupList) if (i.isSelected) [targets addObject:i];

    if (targets.count == 0) {
        self.statusLabel.text = @"❌ 请先勾选需要接收消息的好友或群聊！";
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
            weakSelf.statusLabel.text = [NSString stringWithFormat:@"✅ 群发完成！成功 %ld / 共 %ld", (long)okCount, (long)total];
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

#pragma mark - 5. 精准挂在「设置」页 ->「帮助与反馈」正上方

@interface UIView (ACFindHelpFeedback)
- (UILabel *)ac_findExactLabel:(NSString *)text;
@end

@implementation UIView (ACFindHelpFeedback)

- (UILabel *)ac_findExactLabel:(NSString *)text {
    if ([self isKindOfClass:[UILabel class]]) {
        UILabel *lb = (UILabel *)self;
        if (lb.text && [lb.text isEqualToString:text]) {
            return lb;
        }
    }
    for (UIView *sub in self.subviews) {
        UILabel *found = [sub ac_findExactLabel:text];
        if (found) return found;
    }
    return nil;
}

@end

// 下面两个方法在 %hook 内用 %new 实现，调用点在前，必须先声明
@interface UIViewController (ACForwardInjectDecl)
- (void)ac_injectAboveHelpAndFeedback;
- (void)ac_presentForwardAssistant;
@end

%hook UIViewController

- (void)viewDidLayoutSubviews {
    %orig;
    [self ac_injectAboveHelpAndFeedback];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [self ac_injectAboveHelpAndFeedback];
}

%new
- (void)ac_injectAboveHelpAndFeedback {
    // 只在包含“帮助与反馈”精确文字的【设置】主页生效，彻底杜绝进到“关于飞机”子页面！
    UILabel *helpLabel = [self.view ac_findExactLabel:@"帮助与反馈"];
    if (!helpLabel) return;

    // 向上寻找“帮助与反馈”所在的单行视图 (rowView) 以及外层的滚动容器/父容器
    UIView *helpRowView = helpLabel;
    while (helpRowView.superview && helpRowView.superview != self.view) {
        CGFloat h = helpRowView.frame.size.height;
        CGFloat w = helpRowView.frame.size.width;
        if (h >= 42 && h <= 68 && w > self.view.bounds.size.width * 0.7) {
            break;
        }
        helpRowView = helpRowView.superview;
    }

    UIView *cardOrScrollContainer = helpRowView.superview;
    if (!cardOrScrollContainer) return;

    // 如果“帮助与反馈”装在一个白色圆角分组卡片容器里 (如图3底部的白底卡片，里面装着“帮助与反馈”和“关于飞机”两行)
    // 我们直接在“帮助与反馈”正上方插入一行同款样式的【转发助手】
    UIView *existingRow = [cardOrScrollContainer viewWithTag:996688];
    CGRect helpRowFrame = helpRowView.frame;
    CGFloat rowH = helpRowFrame.size.height > 40 ? helpRowFrame.size.height : 52.0;

    if (!existingRow) {
        // 创建与“帮助与反馈”完全同宽、同高的原生行视图
        UIView *forwardRow = [[UIView alloc] initWithFrame:CGRectMake(helpRowFrame.origin.x,
                                                                      helpRowFrame.origin.y - rowH,
                                                                      helpRowFrame.size.width,
                                                                      rowH)];
        forwardRow.tag = 996688;
        forwardRow.backgroundColor = [UIColor whiteColor];
        forwardRow.layer.cornerRadius = 10.0;
        forwardRow.clipsToBounds = YES;

        // 1. 左侧圆角彩色图标（与图3中黄色“帮助与反馈”、蓝色“关于飞机”完全同尺寸对齐）
        UIView *iconBg = [[UIView alloc] initWithFrame:CGRectMake(16, (rowH - 29) / 2.0, 29, 29)];
        iconBg.backgroundColor = [UIColor colorWithRed:0.05 green:0.53 blue:1.0 alpha:1.0];
        iconBg.layer.cornerRadius = 7.0;
        iconBg.clipsToBounds = YES;

        UILabel *iconSymbol = [[UILabel alloc] initWithFrame:iconBg.bounds];
        iconSymbol.text = @"🚀";
        iconSymbol.font = [UIFont systemFontOfSize:16];
        iconSymbol.textAlignment = NSTextAlignmentCenter;
        [iconBg addSubview:iconSymbol];
        [forwardRow addSubview:iconBg];

        // 2. 标题 “转发助手”（对齐“帮助与反馈”的 X 坐标与字体）
        CGRect helpLabelInRow = [helpRowView convertRect:helpLabel.bounds fromView:helpLabel];
        CGFloat titleX = (helpLabelInRow.origin.x > 40 && helpLabelInRow.origin.x < 90) ? helpLabelInRow.origin.x : 58.0;

        UILabel *titleLb = [[UILabel alloc] initWithFrame:CGRectMake(titleX, 0, 180, rowH)];
        titleLb.text = @"转发助手";
        titleLb.font = helpLabel.font ?: [UIFont systemFontOfSize:16];
        titleLb.textColor = helpLabel.textColor ?: [UIColor blackColor];
        [forwardRow addSubview:titleLb];

        // 3. 右侧灰色箭头 “>”
        UILabel *arrowLb = [[UILabel alloc] initWithFrame:CGRectMake(helpRowFrame.size.width - 34, 0, 20, rowH)];
        arrowLb.text = @"›";
        arrowLb.font = [UIFont systemFontOfSize:22 weight:UIFontWeightLight];
        arrowLb.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
        arrowLb.textAlignment = NSTextAlignmentCenter;
        arrowLb.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [forwardRow addSubview:arrowLb];

        // 4. 底部分割线（与原生列表分割线一致）
        UIView *sepLine = [[UIView alloc] initWithFrame:CGRectMake(titleX, rowH - 0.5, helpRowFrame.size.width - titleX, 0.5)];
        sepLine.backgroundColor = [UIColor colorWithWhite:0.90 alpha:1.0];
        [forwardRow addSubview:sepLine];

        // 5. 整行点击事件
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = forwardRow.bounds;
        btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [btn addTarget:self action:@selector(ac_presentForwardAssistant) forControlEvents:UIControlEventTouchUpInside];
        [forwardRow addSubview:btn];

        // 如果 cardOrScrollContainer 是白色卡片且 helpRowFrame.origin.y == 0（即帮助与反馈是卡片的第1行）
        // 则把卡片内原有的“帮助与反馈”和“关于飞机”往下推 rowH 高度，把【转发助手】放在卡片第1行（帮助与反馈正上方）！
        if (helpRowFrame.origin.y < 10) {
            cardOrScrollContainer.clipsToBounds = NO;
            forwardRow.frame = CGRectMake(helpRowFrame.origin.x, -rowH, helpRowFrame.size.width, rowH);
            // 调整父级白色卡片的上边距，或者如果在 ScrollView 里，直接放到白色卡片正上方
            if (cardOrScrollContainer.superview) {
                CGRect cardFrameInSuper = cardOrScrollContainer.frame;
                // 把“帮助与反馈 + 关于飞机”整个白色卡片往下挪 44pt，给“帮助与反馈”正上方腾出原生位置
                if (cardOrScrollContainer.tag != 775533) {
                    cardOrScrollContainer.tag = 775533;
                    CGRect newCardFrame = cardFrameInSuper;
                    newCardFrame.origin.y += (rowH - 8);
                    cardOrScrollContainer.frame = newCardFrame;

                    // 如果外层是 UIScrollView，同步增加 contentSize
                    if ([cardOrScrollContainer.superview isKindOfClass:[UIScrollView class]]) {
                        UIScrollView *sc = (UIScrollView *)cardOrScrollContainer.superview;
                        CGSize cs = sc.contentSize;
                        cs.height += rowH;
                        sc.contentSize = cs;
                    }
                }
                forwardRow.frame = CGRectMake(cardFrameInSuper.origin.x, cardFrameInSuper.origin.y, cardFrameInSuper.size.width, rowH);
                [cardOrScrollContainer.superview addSubview:forwardRow];
                return;
            }
        }

        [cardOrScrollContainer addSubview:forwardRow];
    }
}

%new
- (void)ac_presentForwardAssistant {
    ACForwardAssistantVC *vc = [[ACForwardAssistantVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

%end
