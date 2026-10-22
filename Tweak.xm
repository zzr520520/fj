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

- (void)parseAnyJSON:(id)jsonObj {
    if (!jsonObj) return;
    if ([jsonObj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)jsonObj;
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

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            NSString *msg = [NSString stringWithFormat:@"已加载 %lu 位好友 | %lu 个群聊", (unsigned long)self.friendList.count, (unsigned long)self.groupList.count];
            if (self.friendList.count == 0 && self.groupList.count == 0) {
                msg = @"提示：请先在 App 内点一下【联系人】或任意聊天加载过数据，即可秒读！";
            }
            if (completion) completion(msg);
        });
    });
}

#pragma mark - 2. 腾讯云 IM 发送消息

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
    if (completion) completion(NO);
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
    CGFloat height = self.view.bounds.size.height;

    CGFloat bottomH = 110.0;
    UIView *bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, height - bottomH, width, bottomH)];
    bottomBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    bottomBar.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, width - 24, 18)];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.text = @"正在读取好友与群聊...";
    [bottomBar addSubview:self.statusLabel];

    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sendButton.frame = CGRectMake(16, 34, width - 32, 50);
    self.sendButton.backgroundColor = [UIColor systemBlueColor];
    [self.sendButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.sendButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.sendButton.layer.cornerRadius = 10;
    [self.sendButton setTitle:@"🚀 一键转发 / 群发 (已选 0)" forState:UIControlStateNormal];
    [self.sendButton addTarget:self action:@selector(startBatchSend) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:self.sendButton];
    [self.view addSubview:bottomBar];

    CGFloat tableTop = 270.0;
    CGFloat tableH = height - tableTop - bottomH;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, tableTop, width, tableH) style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];

    UILabel *tipLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 64, width - 32, 20)];
    tipLabel.text = @"📝 编辑群发/转发内容：";
    tipLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.view addSubview:tipLabel];

    self.contentTextView = [[UITextView alloc] initWithFrame:CGRectMake(16, 88, width - 32, 85)];
    self.contentTextView.font = [UIFont systemFontOfSize:15];
    self.contentTextView.layer.cornerRadius = 8;
    self.contentTextView.layer.borderColor = [UIColor separatorColor].CGColor;
    self.contentTextView.layer.borderWidth = 1.0;
    self.contentTextView.text = @"您好，这是一条群发消息！";
    [self.view addSubview:self.contentTextView];

    UIView *actionBar = [[UIView alloc] initWithFrame:CGRectMake(16, 181, width - 32, 32)];
    NSArray *btnTitles = @[@"全选好友", @"全选群聊", @"全选所有", @"取消全选"];
    CGFloat btnW = (width - 32 - 18) / 4.0;
    for (int i = 0; i < 4; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(i * (btnW + 6), 0, btnW, 30);
        [btn setTitle:btnTitles[i] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        btn.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        btn.layer.cornerRadius = 6;
        btn.tag = 400 + i;
        [btn addTarget:self action:@selector(quickSelectAction:) forControlEvents:UIControlEventTouchUpInside];
        [actionBar addSubview:btn];
    }
    [self.view addSubview:actionBar];

    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"好友 (0)", @"群聊 (0)"]];
    self.tabControl.frame = CGRectMake(16, 225, width - 32, 32);
    self.tabControl.selectedSegmentIndex = 0;
    [self.tabControl addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.tabControl];
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
    if (sender.tag == 400) {
        for (ACContactItem *i in mgr.friendList) i.isSelected = YES;
    } else if (sender.tag == 401) {
        for (ACContactItem *i in mgr.groupList) i.isSelected = YES;
    } else if (sender.tag == 402) {
        for (ACContactItem *i in mgr.friendList) i.isSelected = YES;
        for (ACContactItem *i in mgr.groupList) i.isSelected = YES;
    } else if (sender.tag == 403) {
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
