#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

#pragma mark - 1. 联系人与群组数据管理引擎

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
- (void)sendText:(NSString *)text toItem:(ACContactItem *)item completion:(void(^)(BOOL ok, NSString *errInfo))completion;
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
        instance.selfUserId = @"1958179249315647489";
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
                if ([item.targetId isEqualToString:cleanId] && ([item.name isEqualToString:cleanId] || [item.name hasPrefix:@"好友_"])) {
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

- (void)parseAnyJSON:(id)jsonObj {
    if (!jsonObj) return;
    if ([jsonObj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)jsonObj;

        // 提取埋点里的会话对象 (如 "objectId": "会话：2112860989417381890")
        id objId = dict[@"objectId"];
        if ([objId isKindOfClass:[NSString class]] && [objId hasPrefix:@"会话："]) {
            NSString * extractedId = [objId substringFromIndex:3];
            [self addFriendWithId:extractedId name:nil];
        }

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

        id clientNick = dict[@"clientUserNickName"];
        id uid = dict[@"id"] ?: dict[@"userId"] ?: dict[@"clientUserId"];
        if (clientNick && ![clientNick isKindOfClass:[NSNull class]] && uid && ![uid isKindOfClass:[NSNull class]]) {
            [self addFriendWithId:[NSString stringWithFormat:@"%@", uid] name:[NSString stringWithFormat:@"%@", clientNick]];
        }

        id groupId = dict[@"groupId"] ?: dict[@"groupNo"] ?: dict[@"imGroupId"];
        id groupName = dict[@"groupName"] ?: dict[@"groupTitle"];
        if (groupId && ![groupId isKindOfClass:[NSNull class]]) {
            NSString *gName = (groupName && ![groupName isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", groupName] : [NSString stringWithFormat:@"%@", dict[@"name"] ?: @"群聊"];
            [self addGroupWithId:[NSString stringWithFormat:@"%@", groupId] name:gName];
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

- (void)scanLocalDatabases {
    NSString *home = NSHomeDirectory();
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:home];
    NSString *relPath;
    while ((relPath = [enumerator nextObject])) {
        NSString *lower = relPath.lowercaseString;
        NSString *fullPath = [home stringByAppendingPathComponent:relPath];

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
    }
}

- (void)reloadAllDataWithCompletion:(void(^)(NSString *statusMsg))completion {
    [self scanLocalDatabases];

    dispatch_group_t group = dispatch_group_create();

    // 1. 读取 TIMManager 会话列表 (逆向报告明确存在的符号)
    Class timCls = NSClassFromString(@"TIMManager");
    if (timCls && [timCls respondsToSelector:@selector(sharedInstance)]) {
        id timMgr = ((id (*)(id, SEL))objc_msgSend)(timCls, @selector(sharedInstance));
        SEL getConvsSel = NSSelectorFromString(@"getConversationList");
        if ([timMgr respondsToSelector:getConvsSel]) {
            NSArray *convs = ((id (*)(id, SEL))objc_msgSend)(timMgr, getConvsSel);
            if ([convs isKindOfClass:[NSArray class]]) {
                for (id conv in convs) {
                    @try {
                        SEL rcvSel = NSSelectorFromString(@"getReceiver");
                        SEL typeSel = NSSelectorFromString(@"getType");
                        if ([conv respondsToSelector:rcvSel] && [conv respondsToSelector:typeSel]) {
                            NSString *rcv = ((id (*)(id, SEL))objc_msgSend)(conv, rcvSel);
                            NSInteger type = ((NSInteger (*)(id, SEL))objc_msgSend)(conv, typeSel);
                            if (type == 2) [self addGroupWithId:rcv name:nil];
                            else if (type == 1) [self addFriendWithId:rcv name:nil];
                        }
                    } @catch (NSException *e) {}
                }
            }
        }
    }

    // 2. 读取 V2TIMManager 会话与群聊
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

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            NSString *msg = [NSString stringWithFormat:@"已就绪：%lu 位好友 | %lu 个群聊", (unsigned long)self.friendList.count, (unsigned long)self.groupList.count];
            if (self.friendList.count == 0 && self.groupList.count == 0) {
                msg = @"请先在 App 点一下【联系人】页加载数据后再刷新";
            }
            if (completion) completion(msg);
        });
    });
}

#pragma mark - 2. 双引擎底层直发（绕过 UI 限制 + 返回精准错误码）

- (void)sendText:(NSString *)text toItem:(ACContactItem *)item completion:(void(^)(BOOL ok, NSString *errInfo))completion {
    if (text.length == 0 || item.targetId.length == 0) {
        if (completion) completion(NO, @"参数为空");
        return;
    }

    // 引擎 1：优先使用逆向报告实测存在的 TIMManager / TIMConversation / TIMMessage / TIMTextElem
    Class timMgrCls = NSClassFromString(@"TIMManager");
    Class timMsgCls = NSClassFromString(@"TIMMessage");
    Class timTextCls = NSClassFromString(@"TIMTextElem");
    if (timMgrCls && timMsgCls && timTextCls) {
        id manager = ((id (*)(id, SEL))objc_msgSend)(timMgrCls, @selector(sharedInstance));
        SEL getConvSel = NSSelectorFromString(@"getConversation:receiver:");
        if (manager && [manager respondsToSelector:getConvSel]) {
            NSInteger convType = item.isGroup ? 2 : 1; // 1: C2C单聊, 2: Group群聊
            id conv = ((id (*)(id, SEL, NSInteger, NSString *))objc_msgSend)(manager, getConvSel, convType, item.targetId);
            if (conv) {
                id msg = [[timMsgCls alloc] init];
                id elem = [[timTextCls alloc] init];
                @try {
                    [elem setValue:text forKey:@"text"];
                } @catch (NSException *e) {}

                SEL addElemSel = NSSelectorFromString(@"addElem:");
                if ([msg respondsToSelector:addElemSel]) {
                    ((int (*)(id, SEL, id))objc_msgSend)(msg, addElemSel, elem);
                }

                SEL sendSel = NSSelectorFromString(@"sendMessage:succ:fail:");
                if ([conv respondsToSelector:sendSel]) {
                    void (^succBlock)(void) = ^{
                        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, nil); });
                    };
                    void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) {
                        NSString *err = [NSString stringWithFormat:@"TIM错误(%d): %@", code, desc ?: @"发送受限"];
                        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, err); });
                    };
                    ((void (*)(id, SEL, id, id, id))objc_msgSend)(conv, sendSel, msg, succBlock, failBlock);
                    return;
                }
            }
        }
    }

    // 引擎 2：V2TIMManager 发送通道
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
                if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, nil); });
            };
            void (^failBlock)(int, NSString *) = ^(int code, NSString *desc){
                NSString *err = [NSString stringWithFormat:@"V2错误(%d): %@", code, desc ?: @"发送被拒"];
                if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, err); });
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

    if (completion) completion(NO, @"未找到IM发送实例");
}

@end

#pragma mark - 3. 全局 JSON 拦截入库

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

#pragma mark - 4. 转发助手清爽版界面（仅保留右下角悬浮发送球）

@interface ACForwardAssistantVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITextView *contentTextView;
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *floatingSendBtn;
@end

@implementation ACForwardAssistantVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"转发助手";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    // 顶部仅保留左“关闭”、右“刷新”，删除固定的发送按钮
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(dismissSelf)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain target:self action:@selector(refreshData)];

    [self setupSpaciousUI];
    [self refreshData];
}

- (void)setupSpaciousUI {
    CGFloat width = self.view.bounds.size.width;

    // 1. 宽敞清爽的内容编辑框（带内边距）
    self.contentTextView = [[UITextView alloc] initWithFrame:CGRectMake(16, 16, width - 32, 96)];
    self.contentTextView.font = [UIFont systemFontOfSize:15];
    self.contentTextView.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    self.contentTextView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.contentTextView.layer.cornerRadius = 12;
    self.contentTextView.text = @"您好，这是一条群发消息！";
    [self.view addSubview:self.contentTextView];

    // 2. 好友 / 群聊 切换分段器（拉大上下呼吸间距）
    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"好友列表 (0)", @"群聊列表 (0)"]];
    self.tabControl.frame = CGRectMake(16, 126, width - 32, 34);
    self.tabControl.selectedSegmentIndex = 0;
    [self.tabControl addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.tabControl];

    // 3. 快捷选择按钮栏
    UIView *actionBar = [[UIView alloc] initWithFrame:CGRectMake(16, 172, width - 32, 34)];
    NSArray *btnTitles = @[@"全选好友", @"全选群聊", @"全选所有", @"清空已选"];
    CGFloat btnW = (width - 32 - 24) / 4.0;
    for (int i = 0; i < 4; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(i * (btnW + 8), 0, btnW, 34);
        [btn setTitle:btnTitles[i] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        btn.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        btn.layer.cornerRadius = 8;
        btn.tag = 500 + i;
        [btn addTarget:self action:@selector(quickSelectAction:) forControlEvents:UIControlEventTouchUpInside];
        [actionBar addSubview:btn];
    }
    [self.view addSubview:actionBar];

    // 4. 状态与错误诊断栏
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 214, width - 32, 20)];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.adjustsFontSizeToFitWidth = YES;
    self.statusLabel.text = @"正在读取数据...";
    [self.view addSubview:self.statusLabel];

    // 5. 列表（行高设为 56pt，告别拥挤）
    CGFloat tableTop = 240.0;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, tableTop, width, self.view.bounds.size.height - tableTop) style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = 56.0;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 100, 0);
    [self.view addSubview:self.tableView];

    // 6. 右下角唯一悬浮发送球
    [self setupFloatingButton];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.floatingSendBtn && self.floatingSendBtn.tag != 999) {
        CGFloat btnW = 132.0;
        CGFloat btnH = 50.0;
        CGFloat x = self.view.bounds.size.width - btnW - 20.0;
        CGFloat y = self.view.bounds.size.height - btnH - 36.0;
        self.floatingSendBtn.frame = CGRectMake(x, y, btnW, btnH);
    }
    [self.view bringSubviewToFront:self.floatingSendBtn];
}

- (void)setupFloatingButton {
    self.floatingSendBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingSendBtn.backgroundColor = [UIColor systemBlueColor];
    [self.floatingSendBtn setTitle:@"🚀 发送 (0)" forState:UIControlStateNormal];
    [self.floatingSendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.floatingSendBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.floatingSendBtn.layer.cornerRadius = 25.0;

    self.floatingSendBtn.layer.shadowColor = [UIColor blackColor].CGColor;
    self.floatingSendBtn.layer.shadowOffset = CGSizeMake(0, 4);
    self.floatingSendBtn.layer.shadowOpacity = 0.3;
    self.floatingSendBtn.layer.shadowRadius = 8.0;

    [self.floatingSendBtn addTarget:self action:@selector(startBatchSend) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.floatingSendBtn addGestureRecognizer:pan];

    [self.view addSubview:self.floatingSendBtn];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    btn.tag = 999; // 标记用户已手动拖拽位置
    CGPoint translation = [pan translationInView:self.view];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.view];
}

- (void)refreshData {
    [self.view endEditing:YES];
    self.statusLabel.text = @"正在同步好友与群聊数据...";
    [[ACForwardHelperManager shared] reloadAllDataWithCompletion:^(NSString *statusMsg) {
        self.statusLabel.text = statusMsg;
        [self updateUI];
        [self.tableView reloadData];
    }];
}

- (void)quickSelectAction:(UIButton *)sender {
    [self.view endEditing:YES];
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    if (sender.tag == 500) {
        for (ACContactItem *i in mgr.friendList) i.isSelected = YES;
    } else if (sender.tag == 501) {
        for (ACContactItem *i in mgr.groupList) i.isSelected = YES;
    } else if (sender.tag == 502) {
        for (ACContactItem *i in mgr.friendList) i.isSelected = YES;
        for (ACContactItem *i in mgr.groupList) i.isSelected = YES;
    } else if (sender.tag == 503) {
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
    [self.tabControl setTitle:[NSString stringWithFormat:@"好友列表 (%lu)", (unsigned long)mgr.friendList.count] forSegmentAtIndex:0];
    [self.tabControl setTitle:[NSString stringWithFormat:@"群聊列表 (%lu)", (unsigned long)mgr.groupList.count] forSegmentAtIndex:1];

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
    static NSString *cid = @"ACContactCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    ACContactItem *item = [self currentItems][indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@  %@", item.isGroup ? @"👥" : @"👤", item.name];
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

    self.floatingSendBtn.enabled = NO;
    __block NSInteger okCount = 0;
    __block NSInteger idx = 0;
    __block NSString *lastErr = nil;
    NSInteger total = targets.count;
    __weak typeof(self) weakSelf = self;

    __block void (^nextStep)(void) = ^{
        if (idx >= total) {
            weakSelf.floatingSendBtn.enabled = YES;
            if (okCount == 0 && lastErr) {
                weakSelf.statusLabel.text = [NSString stringWithFormat:@"❌ 失败: %@", lastErr];
            } else {
                weakSelf.statusLabel.text = [NSString stringWithFormat:@"✅ 发送完毕！成功 %ld / 共 %ld %@", (long)okCount, (long)total, lastErr ? [NSString stringWithFormat:@"(%@)", lastErr] : @""];
            }
            return;
        }
        ACContactItem *cur = targets[idx];
        weakSelf.statusLabel.text = [NSString stringWithFormat:@"⏳ 正在发送 (%ld/%ld): %@", (long)(idx + 1), (long)total, cur.name];
        [[ACForwardHelperManager shared] sendText:text toItem:cur completion:^(BOOL ok, NSString *errInfo) {
            if (ok) {
                okCount++;
            } else if (errInfo) {
                lastErr = errInfo;
            }
            idx++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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

#pragma mark - 5. 挂载到「关于飞机」页面的右上角

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
