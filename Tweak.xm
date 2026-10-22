#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

#pragma mark - 1. 数据模型与群成员/好友全量引擎

typedef NS_ENUM(NSInteger, ACContactSourceType) {
    ACContactSourceFriend = 0,      // 我的好友 / 已建立会话
    ACContactSourceGroupMember = 1, // 群内提取的联系人 (群成员)
    ACContactSourceGroupChat = 2    // 群聊本身
};

@interface ACContactItem : NSObject
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *fromGroupId; // 所属群ID（用于群临时会话穿透）
@property (nonatomic, copy) NSString *roleDesc;    // 角色或标签 (好友 / 群主 / 管理员 / 群友)
@property (nonatomic, assign) ACContactSourceType sourceType;
@property (nonatomic, assign) BOOL chatAllowed;    // chatMeType == 0
@property (nonatomic, assign) BOOL isSelected;
@end

@implementation ACContactItem
@end

// 动态加好友请求对象（用于自动破除 120001 隐私拦截）
@interface ACForwardHelperManager : NSObject
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *friendList;
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *groupMemberList;
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *groupList;

@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *friendMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *groupMemberMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *groupMap;
@property (nonatomic, copy) NSString *selfUserId;

+ (instancetype)shared;
- (void)parseJSONWithContext:(id)jsonObj isFromRank:(BOOL)isFromRank;
- (void)reloadAllDataWithCompletion:(void(^)(NSString *statusMsg))completion;
- (void)sendTextWithBypass:(NSString *)text toItem:(ACContactItem *)item completion:(void(^)(BOOL ok, NSString *detail))completion;
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

// 添加到「我的好友」
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
        if (tag && tag.length > 0) existing.roleDesc = tag;
        if (chatAllowed) existing.chatAllowed = YES;
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
    if (chatAllowed) {
        [self.friendList insertObject:item atIndex:0];
    } else {
        [self.friendList addObject:item];
    }
}

// 添加到「群内成员」
- (void)addGroupMemberWithId:(NSString *)uid name:(NSString *)name groupId:(NSString *)gid role:(NSString *)role chatAllowed:(BOOL)chatAllowed {
    if (!uid) return;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", uid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 5 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"<null>"] || [cleanId isEqualToString:@"-1"]) return;
    if ([cleanId isEqualToString:self.selfUserId] || [cleanId hasPrefix:@"@TGS#"]) return;

    NSString *cleanName = (name && ![name isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", name] : @"";

    ACContactItem *existing = self.groupMemberMap[cleanId];
    if (existing) {
        if (cleanName.length > 0 && ![cleanName isEqualToString:cleanId] && ([existing.name isEqualToString:cleanId] || [existing.name hasPrefix:@"群友_"])) {
            existing.name = cleanName;
        }
        if (gid && gid.length > 0) existing.fromGroupId = gid;
        if (role && role.length > 0) existing.roleDesc = role;
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

// 添加到「群聊列表」
- (void)addGroupWithId:(NSString *)gid name:(NSString *)name {
    if (!gid) return;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", gid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 3 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"<null>"] || [cleanId isEqualToString:@"0"]) return;
    // 只收录真实的腾讯 IM 群 ID (@TGS# 开头) 或有效群号
    if (![cleanId hasPrefix:@"@TGS#"] && cleanId.length > 15) return;

    NSString *cleanName = (name && ![name isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", name] : @"";

    ACContactItem *existing = self.groupMap[cleanId];
    if (existing) {
        if (cleanName.length > 0 && ![cleanName isEqualToString:cleanId] && [existing.name hasPrefix:@"群聊"]) {
            existing.name = cleanName;
        }
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

// 智能解析 JSON（精准区分：通讯录好友 vs 群成员/群发言人 vs 排行榜）
- (void)parseJSONWithContext:(id)jsonObj isFromRank:(BOOL)isFromRank {
    if (!jsonObj) return;
    if ([jsonObj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)jsonObj;

        // 过滤排行榜 pagerank 数据，防止把全服几百个开了隐私锁的排行榜陌生人塞进你的好友列表！
        if (dict[@"appUserExperienceList"] || dict[@"realityValue"]) {
            return;
        }

        // 1. 识别群详情 (/client/biz/group/detail -> id: "@TGS#_7374342892571", name: "悦悦...")
        NSString *directId = [NSString stringWithFormat:@"%@", dict[@"id"] ?: @""];
        if ([directId hasPrefix:@"@TGS#"] && dict[@"name"]) {
            [self addGroupWithId:directId name:[NSString stringWithFormat:@"%@", dict[@"name"]]];
            if (dict[@"owner"]) {
                [self addGroupMemberWithId:[NSString stringWithFormat:@"%@", dict[@"owner"]] name:@"群主" groupId:directId role:@"群主" chatAllowed:YES];
            }
        }

        // 2. 识别群成员接口 (/client/biz/v2/group/urs -> groupId + userId + role + userInfo)
        NSString *groupId = [NSString stringWithFormat:@"%@", dict[@"groupId"] ?: @""];
        if ([groupId hasPrefix:@"@TGS#"]) {
            [self addGroupWithId:groupId name:dict[@"groupName"]];

            // 2.1 群成员记录 (含 userInfo)
            if (dict[@"userId"] && [dict[@"userInfo"] isKindOfClass:[NSDictionary class]]) {
                NSDictionary *uInfo = dict[@"userInfo"];
                NSString *uid = [NSString stringWithFormat:@"%@", dict[@"userId"]];
                NSString *nick = uInfo[@"clientUserNickName"] ?: dict[@"customName"];
                NSString *role = dict[@"customName"] ?: dict[@"role"] ?: @"群成员";
                BOOL allow = [[NSString stringWithFormat:@"%@", uInfo[@"chatMeType"] ?: @"0"] isEqualToString:@"0"];
                [self addGroupMemberWithId:uid name:nick groupId:groupId role:role chatAllowed:allow];
            }

            // 2.2 群历史消息记录 (/client/biz/groupmessage/page -> createUser + appUserInfo)
            if (dict[@"createUser"] && [dict[@"appUserInfo"] isKindOfClass:[NSDictionary class]]) {
                NSDictionary *uInfo = dict[@"appUserInfo"];
                NSString *uid = [NSString stringWithFormat:@"%@", uInfo[@"id"] ?: dict[@"createUser"]];
                NSString *nick = uInfo[@"clientUserNickName"];
                BOOL allow = [[NSString stringWithFormat:@"%@", uInfo[@"chatMeType"] ?: @"0"] isEqualToString:@"0"];
                [self addGroupMemberWithId:uid name:nick groupId:groupId role:@"群活跃成员" chatAllowed:allow];
            }
        }

        // 3. 识别通讯录好友 (/client/biz/userfriends/page -> friendId + nickname)
        id friendId = dict[@"friendId"];
        if (friendId && ![friendId isKindOfClass:[NSNull class]]) {
            NSString *remark = dict[@"remark"];
            NSString *nick = dict[@"nickname"];
            NSDictionary *appU = [dict[@"appUserInfo"] isKindOfClass:[NSDictionary class]] ? dict[@"appUserInfo"] : nil;
            if ((!nick || [nick isKindOfClass:[NSNull class]]) && appU) {
                nick = appU[@"clientUserNickName"];
            }
            BOOL allow = YES;
            if (appU && appU[@"chatMeType"] && ![appU[@"chatMeType"] isKindOfClass:[NSNull class]]) {
                allow = [[NSString stringWithFormat:@"%@", appU[@"chatMeType"]] isEqualToString:@"0"];
            }
            NSString *finalName = (remark && ![remark isKindOfClass:[NSNull class]] && [remark description].length > 0) ? [NSString stringWithFormat:@"%@ (%@)", remark, nick ?: @""] : nick;
            [self addFriendWithId:[NSString stringWithFormat:@"%@", friendId] name:finalName tag:@"通讯录好友" chatAllowed:allow];
        }

        // 4. 识别动态/附近可聊天的联系人 (/post/app/getFriendUnreadPosts -> userInfo)
        if (dict[@"contentText"] && [dict[@"userInfo"] isKindOfClass:[NSDictionary class]]) {
            NSDictionary *uInfo = dict[@"userInfo"];
            NSString *uid = [NSString stringWithFormat:@"%@", uInfo[@"id"] ?: dict[@"userId"]];
            NSString *nick = uInfo[@"clientUserNickName"];
            NSString *chatMeType = [NSString stringWithFormat:@"%@", uInfo[@"chatMeType"] ?: @"0"];
            BOOL allow = [chatMeType isEqualToString:@"0"];
            [self addFriendWithId:uid name:nick tag:(allow ? @"可直聊" : @"需加好友") chatAllowed:allow];
        }

        for (id key in dict) {
            id val = dict[key];
            if ([val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSArray class]]) {
                [self parseJSONWithContext:val isFromRank:isFromRank];
            }
        }
    } else if ([jsonObj isKindOfClass:[NSArray class]]) {
        for (id sub in (NSArray *)jsonObj) {
            [self parseJSONWithContext:sub isFromRank:isFromRank];
        }
    }
}

// 从腾讯云 IM SDK 底层直接拉取所有群的群成员 + 群历史消息发言人
- (void)fetchGroupMembersFromIMSDKWithGroup:(dispatch_group_t)group {
    Class v2Cls = NSClassFromString(@"V2TIMManager");
    if (!v2Cls || ![v2Cls respondsToSelector:@selector(sharedInstance)]) return;
    id mgr = ((id (*)(id, SEL))objc_msgSend)(v2Cls, @selector(sharedInstance));

    // 遍历已知的所有群组，调用腾讯 IM 原生 getGroupMemberList 和 getGroupHistoryMessageList
    NSArray<ACContactItem *> *currentGroups = [self.groupList copy];
    for (ACContactItem *grp in currentGroups) {
        NSString *gid = grp.targetId;
        if (![gid hasPrefix:@"@TGS#"]) continue;

        // A. 调用 V2TIMManager -> getGroupMemberList:filter:nextSeq:succ:fail:
        SEL getMemSel = NSSelectorFromString(@"getGroupMemberList:filter:nextSeq:succ:fail:");
        if ([mgr respondsToSelector:getMemSel]) {
            dispatch_group_enter(group);
            void (^succBlock)(uint64_t, NSArray *) = ^(uint64_t nextSeq, NSArray *memberList) {
                for (id mem in memberList) {
                    @try {
                        NSString *uid = [mem valueForKey:@"userID"];
                        NSString *nick = [mem valueForKey:@"nickName"] ?: [mem valueForKey:@"nameCard"] ?: [mem valueForKey:@"friendRemark"];
                        [self addGroupMemberWithId:uid name:nick groupId:gid role:@"群成员" chatAllowed:YES];
                    } @catch (NSException *e) {}
                }
                dispatch_group_leave(group);
            };
            void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) {
                dispatch_group_leave(group);
            };

            NSMethodSignature *sig = [mgr methodSignatureForSelector:getMemSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:mgr];
            [inv setSelector:getMemSel];
            uint32_t filter = 0; // V2TIM_GROUP_MEMBER_FILTER_ALL
            uint64_t nextSeq = 0;
            [inv setArgument:&gid atIndex:2];
            [inv setArgument:&filter atIndex:3];
            [inv setArgument:&nextSeq atIndex:4];
            [inv setArgument:&succBlock atIndex:5];
            [inv setArgument:&failBlock atIndex:6];
            [inv invoke];
        }

        // B. 调用 V2TIMManager -> getGroupHistoryMessageList:count:lastMsg:succ:fail: 提取群内所有发言人
        SEL getHistSel = NSSelectorFromString(@"getGroupHistoryMessageList:count:lastMsg:succ:fail:");
        if ([mgr respondsToSelector:getHistSel]) {
            dispatch_group_enter(group);
            void (^succBlock)(NSArray *) = ^(NSArray *msgs) {
                for (id msg in msgs) {
                    @try {
                        NSString *sender = [msg valueForKey:@"sender"];
                        NSString *nick = [msg valueForKey:@"nickName"];
                        [self addGroupMemberWithId:sender name:nick groupId:gid role:@"群内发言人" chatAllowed:YES];
                    } @catch (NSException *e) {}
                }
                dispatch_group_leave(group);
            };
            void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) {
                dispatch_group_leave(group);
            };

            NSMethodSignature *sig = [mgr methodSignatureForSelector:getHistSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:mgr];
            [inv setSelector:getHistSel];
            int count = 100;
            id lastMsg = nil;
            [inv setArgument:&gid atIndex:2];
            [inv setArgument:&count atIndex:3];
            [inv setArgument:&lastMsg atIndex:4];
            [inv setArgument:&succBlock atIndex:5];
            [inv setArgument:&failBlock atIndex:6];
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
        // 排除 ranking_list.realm，防止把排行榜陌生人扫进来
        if ([lower containsString:@"ranking"]) continue;

        NSString *fullPath = [home stringByAppendingPathComponent:relPath];
        if ([lower hasSuffix:@".db"] || [lower hasSuffix:@".sqlite"] || [lower hasSuffix:@".sqlite3"]) {
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
                                for (int c = 0; c < colCount; c++) {
                                    const char *colText = (const char *)sqlite3_column_text(rowStmt, c);
                                    if (!colText) continue;
                                    NSString *v = [NSString stringWithUTF8String:colText];
                                    if ([v hasPrefix:@"{"] || [v hasPrefix:@"["]) {
                                        NSData *d = [v dataUsingEncoding:NSUTF8StringEncoding];
                                        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                                        if (j) [self parseJSONWithContext:j isFromRank:NO];
                                    }
                                }
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

        // 1. 获取 IM 会话列表
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
                            [self addFriendWithId:uid name:showName tag:@"已建会话" chatAllowed:YES];
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

        // 2. 获取已加入的群聊列表，并在拿到群后自动拉取群成员
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
                // 紧接着拉取所有群内的成员与历史消息发言人
                [self fetchGroupMembersFromIMSDKWithGroup:group];
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
            NSString *msg = [NSString stringWithFormat:@"已加载：%lu 好友 | %lu 群成员 | %lu 群聊",
                             (unsigned long)self.friendList.count,
                             (unsigned long)self.groupMemberList.count,
                             (unsigned long)self.groupList.count];
            if (completion) completion(msg);
        });
    });
}

#pragma mark - 2. 核心：自动破除 120001 拦截（先自动加IM好友 + 注入穿透字段 + 重发）

// 调用腾讯 IM 底层自动添加单向/双向好友，解除非好友会话锁
- (void)autoAddIMFriend:(NSString *)userId completion:(void(^)(void))completion {
    Class v2MgrCls = NSClassFromString(@"V2TIMManager");
    Class reqCls = NSClassFromString(@"V2TIMFriendAddApplication");
    if (v2MgrCls && reqCls) {
        id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));
        SEL addFriendSel = NSSelectorFromString(@"addFriend:succ:fail:");
        if ([manager respondsToSelector:addFriendSel]) {
            id req = [[reqCls alloc] init];
            @try {
                [req setValue:userId forKey:@"userID"];
                [req setValue:@"你好" forKey:@"addWording"];
                [req setValue:@(1) forKey:@"addType"]; // 1: 单向加好友, 2: 双向加好友
            } @catch (NSException *e) {}

            void (^succ)(id) = ^(id res) {
                if (completion) dispatch_async(dispatch_get_main_queue(), completion);
            };
            void (^fail)(int, NSString *) = ^(int code, NSString *desc) {
                if (completion) dispatch_async(dispatch_get_main_queue(), completion);
            };
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(manager, addFriendSel, req, succ, fail);
            return;
        }
    }
    if (completion) completion();
}

// 底层发送单次执行
- (void)rawSendIMText:(NSString *)text toItem:(ACContactItem *)item attachBypassData:(BOOL)attachBypass completion:(void(^)(BOOL ok, int errCode, NSString *errDesc))completion {
    Class v2MgrCls = NSClassFromString(@"V2TIMManager");
    if (v2MgrCls && [v2MgrCls respondsToSelector:@selector(sharedInstance)]) {
        id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));
        SEL createTextSel = NSSelectorFromString(@"createTextMessage:");
        SEL sendMsgSel = NSSelectorFromString(@"sendMessage:receiver:groupID:priority:onlineUserOnly:offlinePushInfo:progress:succ:fail:");

        if ([manager respondsToSelector:createTextSel] && [manager respondsToSelector:sendMsgSel]) {
            id v2Msg = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createTextSel, text);

            // 注入自定义会话穿透数据 (模拟群临时会话与已校验好友状态)
            if (attachBypass && v2Msg) {
                @try {
                    NSDictionary *customDict = @{
                        @"chatType": @"C2C",
                        @"isFriend": @(YES),
                        @"mutual": @"true",
                        @"chatMeType": @"0",
                        @"groupId": item.fromGroupId ?: @"@TGS#_7374342892571",
                        @"source": @"GROUP_MEMBER"
                    };
                    NSData *customData = [NSJSONSerialization dataWithJSONObject:customDict options:0 error:nil];
                    if (customData) {
                        [v2Msg setValue:customData forKey:@"cloudCustomData"];
                    }
                } @catch (NSException *e) {}
            }

            BOOL isTargetGroup = (item.sourceType == ACContactSourceGroupChat);
            NSString *receiver = isTargetGroup ? nil : item.targetId;
            NSString *groupID = isTargetGroup ? item.targetId : nil;

            void (^succBlock)(void) = ^{
                if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, 0, nil); });
            };
            void (^failBlock)(int, NSString *) = ^(int code, NSString *desc){
                if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, code, desc); });
            };

            NSMethodSignature *sig = [manager methodSignatureForSelector:sendMsgSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:manager];
            [inv setSelector:sendMsgSel];
            [inv setArgument:&v2Msg atIndex:2];
            [inv setArgument:&receiver atIndex:3];
            [inv setArgument:&groupID atIndex:4];
            NSInteger priority = 1; // V2TIM_PRIORITY_HIGH
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
    if (completion) completion(NO, -1, @"IM通道未就绪");
}

// 带破盾重发的发送主入口（遇到 120001 自动加好友并携带穿透标记重发）
- (void)sendTextWithBypass:(NSString *)text toItem:(ACContactItem *)item completion:(void(^)(BOOL ok, NSString *detail))completion {
    // 第一次直接附带穿透标记发送
    [self rawSendIMText:text toItem:item attachBypassData:YES completion:^(BOOL ok, int errCode, NSString *errDesc) {
        if (ok) {
            if (completion) completion(YES, @"成功");
            return;
        }

        // 如果返回 120001 等限制，绝不直接放弃：先调 IM 自动加好友接口破除陌生人限制，再重试发送！
        if (item.sourceType != ACContactSourceGroupChat) {
            [self autoAddIMFriend:item.targetId completion:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self rawSendIMText:text toItem:item attachBypassData:YES completion:^(BOOL ok2, int errCode2, NSString *errDesc2) {
                        if (ok2) {
                            if (completion) completion(YES, @"破盾重发成功");
                        } else {
                            NSString *reason = [NSString stringWithFormat:@"(%d)%@", errCode2, errDesc2 ?: @"对方锁死仅好友私聊"];
                            if (completion) completion(NO, reason);
                        }
                    }];
                });
            }];
        } else {
            NSString *reason = [NSString stringWithFormat:@"(%d)%@", errCode, errDesc ?: @"群禁言"];
            if (completion) completion(NO, reason);
        }
    }];
}

@end

#pragma mark - 3. 全局 JSON 拦截器（自动把你点过的群聊、群成员、好友收进列表）

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError * _Nullable *)error {
    id res = %orig;
    if ([res isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)res;
        if (dict[@"code"] && dict[@"data"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[ACForwardHelperManager shared] parseJSONWithContext:dict[@"data"] isFromRank:NO];
            });
        }
    }
    return res;
}

%end

#pragma mark - 4. 转发助手 UI 控制器（三栏切换：我的好友 | 群内成员 | 群聊）

@interface ACForwardAssistantVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UIView *headerContainer;
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
    self.extendedLayoutIncludesOpaqueBars = NO;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(dismissSelf)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain target:self action:@selector(refreshData)];

    [self setupCleanUI];
    [self refreshData];
}

- (void)setupCleanUI {
    CGFloat width = self.view.bounds.size.width;

    // 顶部面板容器
    self.headerContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 232)];
    self.headerContainer.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self.view addSubview:self.headerContainer];

    // 1. 发消息输入框（进一步下移到 Y=18，留足顶部空间）
    self.contentTextView = [[UITextView alloc] initWithFrame:CGRectMake(16, 18, width - 32, 84)];
    self.contentTextView.font = [UIFont systemFontOfSize:15];
    self.contentTextView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    self.contentTextView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.contentTextView.layer.cornerRadius = 12;
    self.contentTextView.layer.borderColor = [UIColor separatorColor].CGColor;
    self.contentTextView.layer.borderWidth = 0.5;
    self.contentTextView.text = @"您好，这是一条群发消息！";
    [self.headerContainer addSubview:self.contentTextView];

    // 2. 三栏切换器：我的好友 | 群内成员 | 群聊列表
    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"好友 (0)", @"群成员 (0)", @"群聊 (0)"]];
    self.tabControl.frame = CGRectMake(16, 114, width - 32, 34);
    self.tabControl.selectedSegmentIndex = 0;
    [self.tabControl addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    [self.headerContainer addSubview:self.tabControl];

    // 3. 快捷全选栏
    self.actionBar = [[UIView alloc] initWithFrame:CGRectMake(16, 158, width - 32, 34)];
    NSArray *btnTitles = @[@"全选当前页", @"全选群成员", @"全选所有", @"清空已选"];
    CGFloat btnW = (width - 32 - 24) / 4.0;
    for (int i = 0; i < 4; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(i * (btnW + 8), 0, btnW, 34);
        [btn setTitle:btnTitles[i] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        btn.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        btn.layer.cornerRadius = 8;
        btn.tag = 600 + i;
        [btn addTarget:self action:@selector(quickSelectAction:) forControlEvents:UIControlEventTouchUpInside];
        [self.actionBar addSubview:btn];
    }
    [self.headerContainer addSubview:self.actionBar];

    // 4. 状态栏
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 200, width - 32, 24)];
    self.statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.adjustsFontSizeToFitWidth = YES;
    self.statusLabel.text = @"正在读取好友与群成员...";
    [self.headerContainer addSubview:self.statusLabel];

    // 5. 表格视图
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = 58.0;
    self.tableView.contentInset = UIEdgeInsetsMake(6, 0, 100, 0);
    [self.view addSubview:self.tableView];

    // 6. 右下角唯一悬浮发送球
    [self setupFloatingButton];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;
    // 强制加上导航栏安全偏移，保证输入框绝对不会被标题栏盖住
    CGFloat topOffset = self.view.safeAreaInsets.top;
    if (topOffset < 10 && self.navigationController && !self.navigationController.navigationBarHidden) {
        topOffset = CGRectGetMaxY(self.navigationController.navigationBar.frame);
        if (topOffset > 70) topOffset = 0; // 如果 edgesForExtendedLayout 已生效则为 0
    }

    CGFloat headerH = 232.0;
    self.headerContainer.frame = CGRectMake(0, topOffset, width, headerH);

    CGFloat tableY = topOffset + headerH;
    self.tableView.frame = CGRectMake(0, tableY, width, height - tableY);

    if (self.floatingSendBtn && self.floatingSendBtn.tag != 999) {
        CGFloat btnW = 136.0;
        CGFloat btnH = 50.0;
        CGFloat x = width - btnW - 20.0;
        CGFloat y = height - btnH - MAX(28.0, self.view.safeAreaInsets.bottom + 12.0);
        self.floatingSendBtn.frame = CGRectMake(x, y, btnW, btnH);
    }
    [self.view bringSubviewToFront:self.headerContainer];
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
    btn.tag = 999;
    CGPoint translation = [pan translationInView:self.view];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.view];
}

- (void)refreshData {
    [self.view endEditing:YES];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.text = @"正在同步好友、群内成员与群聊数据...";
    [[ACForwardHelperManager shared] reloadAllDataWithCompletion:^(NSString *statusMsg) {
        self.statusLabel.text = statusMsg;
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
    if (sender.tag == 600) { // 全选当前页
        for (ACContactItem *i in [self currentItems]) i.isSelected = YES;
    } else if (sender.tag == 601) { // 全选群成员
        for (ACContactItem *i in mgr.groupMemberList) i.isSelected = YES;
        self.tabControl.selectedSegmentIndex = 1;
    } else if (sender.tag == 602) { // 全选所有
        for (ACContactItem *i in mgr.friendList) i.isSelected = YES;
        for (ACContactItem *i in mgr.groupMemberList) i.isSelected = YES;
        for (ACContactItem *i in mgr.groupList) i.isSelected = YES;
    } else if (sender.tag == 603) { // 清空已选
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
    static NSString *cid = @"ACContactCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    ACContactItem *item = [self currentItems][indexPath.row];
    NSString *badge = @"👤";
    if (item.sourceType == ACContactSourceGroupChat) {
        badge = @"👥 [群聊]";
    } else if (item.sourceType == ACContactSourceGroupMember) {
        badge = [NSString stringWithFormat:@"🟢 [%@]", item.roleDesc ?: @"群成员"];
    } else {
        badge = item.chatAllowed ? @"🟢 [可直聊]" : @"🔒 [需破盾]";
    }
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", badge, item.name];
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
        self.statusLabel.textColor = [UIColor systemRedColor];
        self.statusLabel.text = @"❌ 请输入要转发的消息内容！";
        return;
    }

    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    NSMutableArray<ACContactItem *> *targets = [NSMutableArray array];
    for (ACContactItem *i in mgr.friendList) if (i.isSelected) [targets addObject:i];
    for (ACContactItem *i in mgr.groupMemberList) if (i.isSelected) [targets addObject:i];
    for (ACContactItem *i in mgr.groupList) if (i.isSelected) [targets addObject:i];

    if (targets.count == 0) {
        self.statusLabel.textColor = [UIColor systemRedColor];
        self.statusLabel.text = @"❌ 请先勾选好友、群成员或群聊！";
        return;
    }

    self.floatingSendBtn.enabled = NO;
    __block NSInteger okCount = 0;
    __block NSInteger failCount = 0;
    __block NSString *lastFailReason = @"";
    __block NSInteger idx = 0;
    NSInteger total = targets.count;
    __weak typeof(self) weakSelf = self;

    __block void (^nextStep)(void) = ^{
        if (idx >= total) {
            weakSelf.floatingSendBtn.enabled = YES;
            if (okCount > 0) {
                weakSelf.statusLabel.textColor = [UIColor systemGreenColor];
                weakSelf.statusLabel.text = [NSString stringWithFormat:@"✅ 完成：成功 %ld 个 | 失败 %ld 个 %@", (long)okCount, (long)failCount, failCount > 0 ? lastFailReason : @""];
            } else {
                weakSelf.statusLabel.textColor = [UIColor systemRedColor];
                weakSelf.statusLabel.text = [NSString stringWithFormat:@"❌ 全部失败(%ld个): %@", (long)failCount, lastFailReason];
            }
            return;
        }
        ACContactItem *cur = targets[idx];
        weakSelf.statusLabel.textColor = [UIColor systemBlueColor];
        weakSelf.statusLabel.text = [NSString stringWithFormat:@"⏳ 正在发送 (%ld/%ld): %@", (long)(idx + 1), (long)total, cur.name];

        [[ACForwardHelperManager shared] sendTextWithBypass:text toItem:cur completion:^(BOOL ok, NSString *detail) {
            if (ok) {
                okCount++;
            } else {
                failCount++;
                lastFailReason = detail ?: @"";
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
