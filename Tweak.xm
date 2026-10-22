#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

#pragma mark - 1. 数据模型与全量联系人引擎

typedef NS_ENUM(NSInteger, ACContactSourceType) {
    ACContactSourceFriend = 0,
    ACContactSourceGroupMember = 1,
    ACContactSourceGroupChat = 2
};

@interface ACContactItem : NSObject
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *fromGroupId;
@property (nonatomic, copy) NSString *roleDesc;
@property (nonatomic, assign) ACContactSourceType sourceType;
@property (nonatomic, assign) BOOL chatAllowed;
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

@property (nonatomic, strong) UIImage *sharedImage; // 长按捕获的图片
@property (nonatomic, copy) NSString *sharedText;   // 长按捕获的文本

+ (instancetype)shared;
- (void)parseJSONWithContext:(id)jsonObj;
- (void)reloadAllDataWithCompletion:(void(^)(NSString *statusMsg))completion;
- (void)sendContentWithBypass:(NSString *)text toItem:(ACContactItem *)item completion:(void(^)(BOOL ok, NSString *detail))completion;
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

- (void)addFriendWithId:(NSString *)uid name:(NSString *)name tag:(NSString *)tag chatAllowed:(BOOL)chatAllowed {
    if (!uid) return;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", uid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 5 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"<null>"]) return;
    if ([cleanId isEqualToString:self.selfUserId] || [cleanId hasSuffix:@"_collection"] || [cleanId hasPrefix:@"@TGS#"]) return;

    NSString *cleanName = (name && ![name isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", name] : @"";
    if ([cleanName isEqualToString:@"柠檬008"] || [cleanName isEqualToString:@"收藏夹"]) return;

    ACContactItem *existing = self.friendMap[cleanId];
    if (existing) {
        if (cleanName.length > 0 && ![cleanName isEqualToString:cleanId] && ([existing.name isEqualToString:cleanId] || [existing.name hasPrefix:@"用户_"])) {
            existing.name = cleanName;
        }
        return;
    }

    ACContactItem *item = [[ACContactItem alloc] init];
    item.targetId = cleanId;
    item.name = cleanName.length > 0 ? cleanName : [NSString stringWithFormat:@"用户_%@", [cleanId substringFromIndex:MAX(0, (int)cleanId.length - 4)]];
    item.roleDesc = tag ?: @"好友";
    item.sourceType = ACContactSourceFriend;
    item.chatAllowed = chatAllowed;
    item.isSelected = NO;

    self.friendMap[cleanId] = item;
    if (chatAllowed) [self.friendList insertObject:item atIndex:0];
    else [self.friendList addObject:item];
}

- (void)addGroupMemberWithId:(NSString *)uid name:(NSString *)name groupId:(NSString *)gid role:(NSString *)role chatAllowed:(BOOL)chatAllowed {
    if (!uid) return;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", uid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 5 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"<null>"] || [cleanId isEqualToString:@"-1"]) return;
    if ([cleanId isEqualToString:self.selfUserId] || [cleanId hasPrefix:@"@TGS#"]) return;

    NSString *cleanName = (name && ![name isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", name] : @"";
    ACContactItem *existing = self.groupMemberMap[cleanId];
    if (existing) {
        if (cleanName.length > 0 && ![cleanName isEqualToString:cleanId]) existing.name = cleanName;
        return;
    }

    ACContactItem *item = [[ACContactItem alloc] init];
    item.targetId = cleanId;
    item.name = cleanName.length > 0 ? cleanName : [NSString stringWithFormat:@"群友_%@", [cleanId substringFromIndex:MAX(0, (int)cleanId.length - 4)]];
    item.fromGroupId = gid ?: @"";
    item.roleDesc = role ?: @"群成员";
    item.sourceType = ACContactSourceGroupMember;
    item.chatAllowed = chatAllowed;
    item.isSelected = NO;

    self.groupMemberMap[cleanId] = item;
    [self.groupMemberList addObject:item];
}

- (void)addGroupWithId:(NSString *)gid name:(NSString *)name {
    if (!gid) return;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", gid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 3 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"<null>"] || [cleanId isEqualToString:@"0"]) return;
    if (![cleanId hasPrefix:@"@TGS#"] && cleanId.length > 15) return;

    NSString *cleanName = (name && ![name isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", name] : @"";
    ACContactItem *existing = self.groupMap[cleanId];
    if (existing) {
        if (cleanName.length > 0 && [existing.name hasPrefix:@"群聊"]) existing.name = cleanName;
        return;
    }

    ACContactItem *item = [[ACContactItem alloc] init];
    item.targetId = cleanId;
    item.name = cleanName.length > 0 ? cleanName : [NSString stringWithFormat:@"群聊 (%@)", cleanId];
    item.sourceType = ACContactSourceGroupChat;
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
                NSString *uid = [NSString stringWithFormat:@"%@", dict[@"userId"]];
                NSString *nick = uInfo[@"clientUserNickName"] ?: dict[@"customName"];
                BOOL allow = [[NSString stringWithFormat:@"%@", uInfo[@"chatMeType"] ?: @"0"] isEqualToString:@"0"];
                [self addGroupMemberWithId:uid name:nick groupId:groupId role:@"群成员" chatAllowed:allow];
            }
        }

        id friendId = dict[@"friendId"];
        if (friendId && ![friendId isKindOfClass:[NSNull class]]) {
            NSString *remark = dict[@"remark"];
            NSString *nick = dict[@"nickname"];
            NSDictionary *appU = [dict[@"appUserInfo"] isKindOfClass:[NSDictionary class]] ? dict[@"appUserInfo"] : nil;
            if ((!nick || [nick isKindOfClass:[NSNull class]]) && appU) nick = appU[@"clientUserNickName"];
            BOOL allow = YES;
            if (appU && appU[@"chatMeType"]) allow = [[NSString stringWithFormat:@"%@", appU[@"chatMeType"]] isEqualToString:@"0"];
            NSString *finalName = (remark && [remark description].length > 0) ? [NSString stringWithFormat:@"%@ (%@)", remark, nick ?: @""] : nick;
            [self addFriendWithId:[NSString stringWithFormat:@"%@", friendId] name:finalName tag:@"好友" chatAllowed:allow];
        }

        for (id key in dict) {
            id val = dict[key];
            if ([val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSArray class]]) [self parseJSONWithContext:val];
        }
    } else if ([jsonObj isKindOfClass:[NSArray class]]) {
        for (id sub in (NSArray *)jsonObj) [self parseJSONWithContext:sub];
    }
}

- (void)fetchGroupMembersFromIMSDKWithGroup:(dispatch_group_t)group {
    Class v2Cls = NSClassFromString(@"V2TIMManager");
    if (!v2Cls || ![v2Cls respondsToSelector:@selector(sharedInstance)]) return;
    id mgr = ((id (*)(id, SEL))objc_msgSend)(v2Cls, @selector(sharedInstance));

    for (ACContactItem *grp in [self.groupList copy]) {
        NSString *gid = grp.targetId;
        if (![gid hasPrefix:@"@TGS#"]) continue;
        SEL getMemSel = NSSelectorFromString(@"getGroupMemberList:filter:nextSeq:succ:fail:");
        if ([mgr respondsToSelector:getMemSel]) {
            dispatch_group_enter(group);
            void (^succBlock)(uint64_t, NSArray *) = ^(uint64_t nextSeq, NSArray *memberList) {
                for (id mem in memberList) {
                    @try {
                        [self addGroupMemberWithId:[mem valueForKey:@"userID"] name:[mem valueForKey:@"nickName"] ?: [mem valueForKey:@"nameCard"] groupId:gid role:@"群成员" chatAllowed:YES];
                    } @catch (NSException *e) {}
                }
                dispatch_group_leave(group);
            };
            void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) { dispatch_group_leave(group); };

            NSMethodSignature *sig = [mgr methodSignatureForSelector:getMemSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:mgr]; [inv setSelector:getMemSel];
            uint32_t filter = 0; uint64_t seq = 0;
            [inv setArgument:&gid atIndex:2]; [inv setArgument:&filter atIndex:3]; [inv setArgument:&seq atIndex:4];
            [inv setArgument:&succBlock atIndex:5]; [inv setArgument:&failBlock atIndex:6];
            [inv invoke];
        }
    }
}

- (void)scanLocalDatabases {
    NSString *home = NSHomeDirectory();
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:home];
    NSString *relPath;
    while ((relPath = [enumerator nextObject])) {
        NSString *lower = relPath.lowercaseString;
        if ([lower containsString:@"ranking"]) continue;
        NSString *fullPath = [home stringByAppendingPathComponent:relPath];
        if ([lower hasSuffix:@".db"] || [lower hasSuffix:@".sqlite"] || [lower hasSuffix:@".sqlite3"]) {
            sqlite3 *db = NULL;
            if (sqlite3_open_v2([fullPath UTF8String], &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
                sqlite3_stmt *tStmt = NULL;
                if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table';", -1, &tStmt, NULL) == SQLITE_OK) {
                    while (sqlite3_step(tStmt) == SQLITE_ROW) {
                        const char *tName = (const char *)sqlite3_column_text(tStmt, 0);
                        if (!tName) continue;
                        NSString *sql = [NSString stringWithFormat:@"SELECT * FROM \"%@\" LIMIT 300;", [NSString stringWithUTF8String:tName]];
                        sqlite3_stmt *rStmt = NULL;
                        if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &rStmt, NULL) == SQLITE_OK) {
                            int cols = sqlite3_column_count(rStmt);
                            while (sqlite3_step(rStmt) == SQLITE_ROW) {
                                for (int c = 0; c < cols; c++) {
                                    const char *txt = (const char *)sqlite3_column_text(rStmt, c);
                                    if (!txt) continue;
                                    NSString *v = [NSString stringWithUTF8String:txt];
                                    if ([v hasPrefix:@"{"] || [v hasPrefix:@"["]) {
                                        id j = [NSJSONSerialization JSONObjectWithData:[v dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                                        if (j) [self parseJSONWithContext:j];
                                    }
                                }
                            }
                            sqlite3_finalize(rStmt);
                        }
                    }
                    sqlite3_finalize(tStmt);
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

        SEL getGroupsSel = NSSelectorFromString(@"getJoinedGroupList:fail:");
        if ([mgr respondsToSelector:getGroupsSel]) {
            dispatch_group_enter(group);
            void (^succBlock)(NSArray *) = ^(NSArray *groupInfos) {
                for (id gInfo in groupInfos) {
                    @try { [self addGroupWithId:[gInfo valueForKey:@"groupID"] name:[gInfo valueForKey:@"groupName"]]; } @catch (NSException *e) {}
                }
                [self fetchGroupMembersFromIMSDKWithGroup:group];
                dispatch_group_leave(group);
            };
            void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) { dispatch_group_leave(group); };
            ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, getGroupsSel, succBlock, failBlock);
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            NSString *msg = [NSString stringWithFormat:@"已就绪：%lu 好友 | %lu 群友 | %lu 群聊",
                             (unsigned long)self.friendList.count,
                             (unsigned long)self.groupMemberList.count,
                             (unsigned long)self.groupList.count];
            if (completion) completion(msg);
        });
    });
}

- (void)autoAddIMFriend:(NSString *)userId completion:(void(^)(void))completion {
    Class v2MgrCls = NSClassFromString(@"V2TIMManager");
    Class reqCls = NSClassFromString(@"V2TIMFriendAddApplication");
    if (v2MgrCls && reqCls) {
        id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));
        SEL addFriendSel = NSSelectorFromString(@"addFriend:succ:fail:");
        if ([manager respondsToSelector:addFriendSel]) {
            id req = [[reqCls alloc] init];
            @try { [req setValue:userId forKey:@"userID"]; [req setValue:@(1) forKey:@"addType"]; } @catch (NSException *e) {}
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(manager, addFriendSel, req, ^(id r){ if(completion)completion(); }, ^(int c, NSString*d){ if(completion)completion(); });
            return;
        }
    }
    if (completion) completion();
}

- (void)rawSendContentToItem:(ACContactItem *)item completion:(void(^)(BOOL ok, int code, NSString *desc))completion {
    Class v2MgrCls = NSClassFromString(@"V2TIMManager");
    if (!v2MgrCls) { if (completion) completion(NO, -1, @"IM不可用"); return; }
    id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));

    if (self.sharedImage) {
        NSData *imgData = UIImageJPEGRepresentation(self.sharedImage, 0.85);
        NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"forward_share_img.jpg"];
        [imgData writeToFile:tmpPath atomically:YES];
        SEL createImgSel = NSSelectorFromString(@"createImageMessage:");
        SEL sendMsgSel = NSSelectorFromString(@"sendMessage:receiver:groupID:priority:onlineUserOnly:offlinePushInfo:progress:succ:fail:");
        if ([manager respondsToSelector:createImgSel] && [manager respondsToSelector:sendMsgSel]) {
            id msgObj = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createImgSel, tmpPath);
            NSString *rcv = item.isGroup ? nil : item.targetId;
            NSString *grp = item.isGroup ? item.targetId : nil;
            void (^succ)(void) = ^{ if (completion) completion(YES, 0, nil); };
            void (^fail)(int, NSString *) = ^(int c, NSString *d){ if (completion) completion(NO, c, d); };

            NSMethodSignature *sig = [manager methodSignatureForSelector:sendMsgSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:manager]; [inv setSelector:sendMsgSel];
            [inv setArgument:&msgObj atIndex:2]; [inv setArgument:&rcv atIndex:3]; [inv setArgument:&grp atIndex:4];
            NSInteger pri = 1; BOOL online = NO; id nilObj = nil;
            [inv setArgument:&pri atIndex:5]; [inv setArgument:&online atIndex:6]; [inv setArgument:&nilObj atIndex:7]; [inv setArgument:&nilObj atIndex:8];
            [inv setArgument:&succ atIndex:9]; [inv setArgument:&fail atIndex:10];
            [inv invoke];
            return;
        }
    }

    NSString *txt = self.sharedText.length > 0 ? self.sharedText : @"[转发消息]";
    SEL createTxtSel = NSSelectorFromString(@"createTextMessage:");
    SEL sendMsgSel = NSSelectorFromString(@"sendMessage:receiver:groupID:priority:onlineUserOnly:offlinePushInfo:progress:succ:fail:");
    if ([manager respondsToSelector:createTxtSel] && [manager respondsToSelector:sendMsgSel]) {
        id msgObj = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createTxtSel, txt);
        NSString *rcv = item.isGroup ? nil : item.targetId;
        NSString *grp = item.isGroup ? item.targetId : nil;
        void (^succ)(void) = ^{ if (completion) completion(YES, 0, nil); };
        void (^fail)(int, NSString *) = ^(int c, NSString *d){ if (completion) completion(NO, c, d); };

        NSMethodSignature *sig = [manager methodSignatureForSelector:sendMsgSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:manager]; [inv setSelector:sendMsgSel];
        [inv setArgument:&msgObj atIndex:2]; [inv setArgument:&rcv atIndex:3]; [inv setArgument:&grp atIndex:4];
        NSInteger pri = 1; BOOL online = NO; id nilObj = nil;
        [inv setArgument:&pri atIndex:5]; [inv setArgument:&online atIndex:6]; [inv setArgument:&nilObj atIndex:7]; [inv setArgument:&nilObj atIndex:8];
        [inv setArgument:&succ atIndex:9]; [inv setArgument:&fail atIndex:10];
        [inv invoke];
        return;
    }
    if (completion) completion(NO, -2, @"发送失败");
}

- (void)sendContentWithBypass:(NSString *)text toItem:(ACContactItem *)item completion:(void(^)(BOOL ok, NSString *detail))completion {
    if (text.length > 0) self.sharedText = text;
    [self rawSendContentToItem:item completion:^(BOOL ok, int code, NSString *desc) {
        if (ok) {
            if (completion) completion(YES, @"成功");
            return;
        }
        if (item.sourceType != ACContactSourceGroupChat) {
            [self autoAddIMFriend:item.targetId completion:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self rawSendContentToItem:item completion:^(BOOL ok2, int code2, NSString *desc2) {
                        if (ok2) {
                            if (completion) completion(YES, @"破盾成功");
                        } else {
                            if (completion) completion(NO, [NSString stringWithFormat:@"(%d)%@", code2, desc2 ?: @"受限"]);
                        }
                    }];
                });
            }];
        } else {
            if (completion) completion(NO, [NSString stringWithFormat:@"(%d)%@", code, desc ?: @"群受限"]);
        }
    }];
}

@end

#pragma mark - 2. 全局 JSON 拦截器

%hook NSJSONSerialization
+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError * _Nullable *)error {
    id res = %orig;
    if ([res isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)res;
        if (dict[@"code"] && dict[@"data"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[ACForwardHelperManager shared] parseJSONWithContext:dict[@"data"]];
            });
        }
    }
    return res;
}
%end

#pragma mark - 3. 转发助手完整 UI 面板

@interface ACForwardAssistantVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UIView *headerContainer;
@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, strong) UITextView *contentTextView;
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, strong) UIView *actionBar;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIButton *floatingSendBtn;
@end

@implementation ACForwardAssistantVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"转发助手";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.edgesForExtendedLayout = UIRectEdgeNone;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(dismissSelf)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain target:self action:@selector(loadData)];

    [self setupUI];
    [self loadData];
}

- (void)setupUI {
    CGFloat width = self.view.bounds.size.width;
    BOOL hasImg = ([ACForwardHelperManager shared].sharedImage != nil);
    CGFloat headerH = hasImg ? 260.0 : 232.0;

    self.headerContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, headerH)];
    self.headerContainer.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self.view addSubview:self.headerContainer];

    if (hasImg) {
        self.previewImageView = [[UIImageView alloc] initWithFrame:CGRectMake(16, 12, 48, 48)];
        self.previewImageView.image = [ACForwardHelperManager shared].sharedImage;
        self.previewImageView.contentMode = UIViewContentModeScaleAspectFill;
        self.previewImageView.layer.cornerRadius = 6;
        self.previewImageView.clipsToBounds = YES;
        [self.headerContainer addSubview:self.previewImageView];

        self.contentTextView = [[UITextView alloc] initWithFrame:CGRectMake(74, 12, width - 90, 68)];
    } else {
        self.contentTextView = [[UITextView alloc] initWithFrame:CGRectMake(16, 14, width - 32, 82)];
    }

    self.contentTextView.font = [UIFont systemFontOfSize:14];
    self.contentTextView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.contentTextView.layer.cornerRadius = 10;
    self.contentTextView.layer.borderColor = [UIColor separatorColor].CGColor;
    self.contentTextView.layer.borderWidth = 0.5;
    self.contentTextView.text = [ACForwardHelperManager shared].sharedText.length > 0 ? [ACForwardHelperManager shared].sharedText : @"您好，这是一条转发消息！";
    [self.headerContainer addSubview:self.contentTextView];

    CGFloat segY = hasImg ? 92 : 108;
    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"好友 (0)", @"群成员 (0)", @"群聊 (0)"]];
    self.tabControl.frame = CGRectMake(16, segY, width - 32, 34);
    self.tabControl.selectedSegmentIndex = 0;
    [self.tabControl addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    [self.headerContainer addSubview:self.tabControl];

    CGFloat actY = segY + 44;
    self.actionBar = [[UIView alloc] initWithFrame:CGRectMake(16, actY, width - 32, 34)];
    NSArray *btnTitles = @[@"全选当前", @"全选群友", @"全选所有", @"清空已选"];
    CGFloat btnW = (width - 32 - 24) / 4.0;
    for (int i = 0; i < 4; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(i * (btnW + 8), 0, btnW, 34);
        [btn setTitle:btnTitles[i] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        btn.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        btn.layer.cornerRadius = 8;
        btn.tag = 700 + i;
        [btn addTarget:self action:@selector(quickSelectAction:) forControlEvents:UIControlEventTouchUpInside];
        [self.actionBar addSubview:btn];
    }
    [self.headerContainer addSubview:self.actionBar];

    CGFloat statusY = actY + 42;
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, statusY, width - 32, 20)];
    self.statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.text = @"正在读取联系人...";
    [self.headerContainer addSubview:self.statusLabel];

    CGFloat tableTop = statusY + 28;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, tableTop, width, self.view.bounds.size.height - tableTop) style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = 56.0;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 100, 0);
    [self.view addSubview:self.tableView];

    self.floatingSendBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingSendBtn.backgroundColor = [UIColor systemBlueColor];
    [self.floatingSendBtn setTitle:@"🚀 发送 (0)" forState:UIControlStateNormal];
    [self.floatingSendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.floatingSendBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.floatingSendBtn.layer.cornerRadius = 25;
    self.floatingSendBtn.layer.shadowColor = [UIColor blackColor].CGColor;
    self.floatingSendBtn.layer.shadowOffset = CGSizeMake(0, 4);
    self.floatingSendBtn.layer.shadowOpacity = 0.3;
    self.floatingSendBtn.layer.shadowRadius = 8;
    [self.floatingSendBtn addTarget:self action:@selector(startBatchSend) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.floatingSendBtn];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;
    CGFloat topOffset = self.view.safeAreaInsets.top;
    if (topOffset < 10 && self.navigationController && !self.navigationController.navigationBarHidden) {
        topOffset = CGRectGetMaxY(self.navigationController.navigationBar.frame);
        if (topOffset > 70) topOffset = 0;
    }

    BOOL hasImg = ([ACForwardHelperManager shared].sharedImage != nil);
    CGFloat headerH = hasImg ? 260.0 : 232.0;
    self.headerContainer.frame = CGRectMake(0, topOffset, width, headerH);
    CGFloat tableY = topOffset + headerH;
    self.tableView.frame = CGRectMake(0, tableY, width, height - tableY);

    if (self.floatingSendBtn && self.floatingSendBtn.tag != 999) {
        CGFloat x = width - 156.0;
        CGFloat y = height - 76.0 - MAX(20.0, self.view.safeAreaInsets.bottom);
        self.floatingSendBtn.frame = CGRectMake(x, y, 136, 50);
    }
    [self.view bringSubviewToFront:self.headerContainer];
    [self.view bringSubviewToFront:self.floatingSendBtn];
}

- (void)loadData {
    [[ACForwardHelperManager shared] reloadAllDataWithCompletion:^(NSString *msg) {
        self.statusLabel.text = msg;
        [self updateUI];
        [self.tableView reloadData];
    }];
}

- (NSArray<ACContactItem *> *)currentItems {
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    if (self.tabControl.selectedSegmentIndex == 0) return mgr.friendList;
    if (self.tabControl.selectedSegmentIndex == 1) return mgr.groupMemberList;
    return mgr.groupList;
}

- (void)quickSelectAction:(UIButton *)sender {
    [self.view endEditing:YES];
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    if (sender.tag == 700) {
        for (ACContactItem *i in [self currentItems]) i.isSelected = YES;
    } else if (sender.tag == 701) {
        for (ACContactItem *i in mgr.groupMemberList) i.isSelected = YES;
        self.tabControl.selectedSegmentIndex = 1;
    } else if (sender.tag == 702) {
        for (ACContactItem *i in mgr.friendList) i.isSelected = YES;
        for (ACContactItem *i in mgr.groupMemberList) i.isSelected = YES;
        for (ACContactItem *i in mgr.groupList) i.isSelected = YES;
    } else if (sender.tag == 703) {
        for (ACContactItem *i in mgr.friendList) i.isSelected = NO;
        for (ACContactItem *i in mgr.groupMemberList) i.isSelected = NO;
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
    [self.tabControl setTitle:[NSString stringWithFormat:@"群成员 (%lu)", (unsigned long)mgr.groupMemberList.count] forSegmentAtIndex:1];
    [self.tabControl setTitle:[NSString stringWithFormat:@"群聊 (%lu)", (unsigned long)mgr.groupList.count] forSegmentAtIndex:2];

    NSInteger selCount = 0;
    for (ACContactItem *i in mgr.friendList) if (i.isSelected) selCount++;
    for (ACContactItem *i in mgr.groupMemberList) if (i.isSelected) selCount++;
    for (ACContactItem *i in mgr.groupList) if (i.isSelected) selCount++;
    [self.floatingSendBtn setTitle:[NSString stringWithFormat:@"🚀 发送 (%ld)", (long)selCount] forState:UIControlStateNormal];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self currentItems].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"Cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    ACContactItem *item = [self currentItems][indexPath.row];
    NSString *badge = item.isGroup ? @"👥 [群聊]" : @"👤";
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", badge, item.name];
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

- (void)startBatchSend {
    [self.view endEditing:YES];
    NSString *text = [self.contentTextView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];

    NSMutableArray *targets = [NSMutableArray array];
    for (ACContactItem *i in mgr.friendList) if (i.isSelected) [targets addObject:i];
    for (ACContactItem *i in mgr.groupMemberList) if (i.isSelected) [targets addObject:i];
    for (ACContactItem *i in mgr.groupList) if (i.isSelected) [targets addObject:i];

    if (targets.count == 0) {
        self.statusLabel.text = @"❌ 请先勾选转发目标！";
        return;
    }

    self.floatingSendBtn.enabled = NO;
    __block NSInteger ok = 0, fail = 0, idx = 0;
    NSInteger total = targets.count;

    __block void (^sendNext)(void) = ^{
        if (idx >= total) {
            self.floatingSendBtn.enabled = YES;
            self.statusLabel.text = [NSString stringWithFormat:@"✅ 发送完毕：成功 %ld / 失败 %ld", (long)ok, (long)fail];
            return;
        }
        ACContactItem *target = targets[idx];
        self.statusLabel.text = [NSString stringWithFormat:@"⏳ 发送中 (%ld/%ld): %@", (long)(idx + 1), (long)total, target.name];
        [mgr sendContentWithBypass:text toItem:target completion:^(BOOL success, NSString *detail) {
            if (success) ok++; else fail++;
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

#pragma mark - 5. 劫持 AirChat 自定义聊天气泡长按菜单（在“回复”上方无缝添加转发助手）

%hook UIMenuController

// 强行向 AirChat 的气泡菜单动态注入“转发助手”
- (void)setMenuItems:(NSArray<UIMenuItem *> *)menuItems {
    NSMutableArray *arr = menuItems ? [menuItems mutableCopy] : [NSMutableArray array];
    BOOL hasCustom = NO;
    for (UIMenuItem *i in arr) {
        if ([i.title isEqualToString:@"🚀 转发助手"]) { hasCustom = YES; break; }
    }
    if (!hasCustom) {
        // 直接插在最顶部（即“回复”上方）
        UIMenuItem *item = [[UIMenuItem alloc] initWithTitle:@"🚀 转发助手" action:@selector(ac_handleCustomForwardAction:)];
        [arr insertObject:item atIndex:0];
    }
    %orig(arr);
}

%end

// 针对 AirChat 自定义长按菜单事件的响应绑定
%hook UIResponder

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (action == @selector(ac_handleCustomForwardAction:)) return YES;
    return %orig;
}

%new
- (void)ac_handleCustomForwardAction:(id)sender {
    UIImage *capturedImg = nil;
    NSString *capturedTxt = nil;

    // 尝试在当前长按的消息气泡视图中自动提取图片或文本
    if ([self isKindOfClass:[UIImageView class]]) {
        capturedImg = ((UIImageView *)self).image;
    } else if ([self isKindOfClass:[UILabel class]]) {
        capturedTxt = ((UILabel *)self).text;
    } else if ([self isKindOfClass:[UIView class]]) {
        for (UIView *sub in ((UIView *)self).subviews) {
            if ([sub isKindOfClass:[UIImageView class]] && ((UIImageView *)sub).image) {
                capturedImg = ((UIImageView *)sub).image;
            } else if ([sub isKindOfClass:[UILabel class]] && ((UILabel *)sub).text) {
                capturedTxt = ((UILabel *)sub).text;
            }
        }
    }

    [ACForwardHelperManager shared].sharedImage = capturedImg;
    [ACForwardHelperManager shared].sharedText = capturedTxt;

    UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
    UIViewController *rootVC = keyWin.rootViewController;
    ACForwardAssistantVC *vc = [[ACForwardAssistantVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [rootVC presentViewController:nav animated:YES completion:nil];
}

%end

#pragma mark - 6. 设置页「关于飞机」右上角挂载入口

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *clsName = NSStringFromClass([self class]);
    if ([clsName containsString:@"HelpAboutViewController"]) {
        if (self.navigationItem) {
            UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"🚀 转发助手" style:UIBarButtonItemStyleDone target:self action:@selector(ac_openFromAbout)];
            btn.tintColor = [UIColor systemBlueColor];
            self.navigationItem.rightBarButtonItem = btn;
        }
    }
}

%new
- (void)ac_openFromAbout {
    [ACForwardHelperManager shared].sharedImage = nil;
    [ACForwardHelperManager shared].sharedText = nil;
    ACForwardAssistantVC *vc = [[ACForwardAssistantVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}
%end
