#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

#pragma mark - 1. 数据模型（支持 NSCoding 永久本地序列化）

@interface ACContactItem : NSObject <NSCoding>
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *fromGroupId;
@property (nonatomic, copy) NSString *roleDesc;
@property (nonatomic, assign) NSInteger sourceType; // 0: 好友, 1: 群成员, 2: 群聊
@property (nonatomic, assign) BOOL chatAllowed;
@property (nonatomic, assign) BOOL isSelected;
@end

@implementation ACContactItem

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.targetId ?: @"" forKey:@"targetId"];
    [coder encodeObject:self.name ?: @"" forKey:@"name"];
    [coder encodeObject:self.fromGroupId ?: @"" forKey:@"fromGroupId"];
    [coder encodeObject:self.roleDesc ?: @"" forKey:@"roleDesc"];
    [coder encodeInteger:self.sourceType forKey:@"sourceType"];
    [coder encodeBool:self.chatAllowed forKey:@"chatAllowed"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        self.targetId = [coder decodeObjectForKey:@"targetId"];
        self.name = [coder decodeObjectForKey:@"name"];
        self.fromGroupId = [coder decodeObjectForKey:@"fromGroupId"];
        self.roleDesc = [coder decodeObjectForKey:@"roleDesc"];
        self.sourceType = [coder decodeIntegerForKey:@"sourceType"];
        self.chatAllowed = [coder decodeBoolForKey:@"chatAllowed"];
        self.isSelected = NO;
    }
    return self;
}

@end

// 全局记录当前在聊天界面被长按的视图、文本、图片
static __weak UIView *__lastLongPressedView = nil;
static NSString *__pendingForwardText = nil;
static UIImage *__pendingForwardImage = nil;

#pragma mark - 2. 核心管理器（无限分页拉取群成员 + 永久存储 + 图文群发）

@interface ACForwardHelperManager : NSObject
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *friendList;
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *groupMemberList;
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *groupList;

@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *friendMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *groupMemberMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *groupMap;

@property (nonatomic, copy) NSString *selfUserId;
@property (nonatomic, assign) BOOL isCrawlingMembers;

+ (instancetype)shared;
- (void)loadLocalPermanentCache;
- (void)saveLocalPermanentCache;
- (void)parseJSONWithContext:(id)jsonObj;
- (void)reloadAllDataWithProgress:(void(^)(NSString *progressMsg))progressBlock
                       completion:(void(^)(NSString *finalMsg))completion;
- (void)sendMessageWithText:(NSString *)text
                      image:(UIImage *)image
                     toItem:(ACContactItem *)item
                 completion:(void(^)(BOOL ok, NSString *detail))completion;
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
        [instance loadLocalPermanentCache];
    });
    return instance;
}

- (NSString *)cacheFilePath:(NSString *)type {
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [docDir stringByAppendingPathComponent:[NSString stringWithFormat:@"AC_Permanent_%@.archive", type]];
}

- (void)saveLocalPermanentCache {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @synchronized (self) {
            @try {
                NSData *fData = [NSKeyedArchiver archivedDataWithRootObject:[self.friendList copy] requiringSecureCoding:NO error:nil];
                NSData *mData = [NSKeyedArchiver archivedDataWithRootObject:[self.groupMemberList copy] requiringSecureCoding:NO error:nil];
                NSData *gData = [NSKeyedArchiver archivedDataWithRootObject:[self.groupList copy] requiringSecureCoding:NO error:nil];
                if (fData) [fData writeToFile:[self cacheFilePath:@"friends"] atomically:YES];
                if (mData) [mData writeToFile:[self cacheFilePath:@"members"] atomically:YES];
                if (gData) [gData writeToFile:[self cacheFilePath:@"groups"] atomically:YES];
            } @catch (NSException *e) {}
        }
    });
}

- (void)loadLocalPermanentCache {
    @synchronized (self) {
        @try {
            NSArray *fArr = [NSKeyedUnarchiver unarchiveObjectWithFile:[self cacheFilePath:@"friends"]];
            if ([fArr isKindOfClass:[NSArray class]]) {
                for (ACContactItem *item in fArr) {
                    if (item.targetId.length > 0 && !self.friendMap[item.targetId]) {
                        self.friendMap[item.targetId] = item;
                        [self.friendList addObject:item];
                    }
                }
            }
            NSArray *mArr = [NSKeyedUnarchiver unarchiveObjectWithFile:[self cacheFilePath:@"members"]];
            if ([mArr isKindOfClass:[NSArray class]]) {
                for (ACContactItem *item in mArr) {
                    if (item.targetId.length > 0 && !self.groupMemberMap[item.targetId]) {
                        self.groupMemberMap[item.targetId] = item;
                        [self.groupMemberList addObject:item];
                    }
                }
            }
            NSArray *gArr = [NSKeyedUnarchiver unarchiveObjectWithFile:[self cacheFilePath:@"groups"]];
            if ([gArr isKindOfClass:[NSArray class]]) {
                for (ACContactItem *item in gArr) {
                    if (item.targetId.length > 0 && !self.groupMap[item.targetId]) {
                        self.groupMap[item.targetId] = item;
                        [self.groupList addObject:item];
                    }
                }
            }
        } @catch (NSException *e) {}
    }
}

- (void)addFriendWithId:(NSString *)uid name:(NSString *)name tag:(NSString *)tag chatAllowed:(BOOL)chatAllowed {
    if (!uid) return;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", uid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 5 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"<null>"] || [cleanId isEqualToString:@"-1"]) return;
    if ([cleanId isEqualToString:self.selfUserId] || [cleanId hasSuffix:@"_collection"] || [cleanId hasPrefix:@"@TGS#"]) return;

    NSString *cleanName = (name && ![name isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", name] : @"";
    if ([cleanName isEqualToString:@"柠檬008"] || [cleanName isEqualToString:@"收藏夹"]) return;

    @synchronized (self) {
        ACContactItem *existing = self.friendMap[cleanId];
        if (existing) {
            if (cleanName.length > 0 && ![cleanName isEqualToString:cleanId] && ([existing.name isEqualToString:cleanId] || [existing.name hasPrefix:@"用户_"])) {
                existing.name = cleanName;
            }
            if (chatAllowed) existing.chatAllowed = YES;
            return;
        }

        ACContactItem *item = [[ACContactItem alloc] init];
        item.targetId = cleanId;
        item.name = cleanName.length > 0 ? cleanName : [NSString stringWithFormat:@"用户_%@", [cleanId substringFromIndex:MAX(0, (int)cleanId.length - 4)]];
        item.roleDesc = tag ?: @"好友";
        item.sourceType = 0;
        item.chatAllowed = chatAllowed;
        item.isSelected = NO;

        self.friendMap[cleanId] = item;
        if (chatAllowed) {
            [self.friendList insertObject:item atIndex:0];
        } else {
            [self.friendList addObject:item];
        }
    }
}

- (BOOL)addGroupMemberWithId:(NSString *)uid name:(NSString *)name groupId:(NSString *)gid role:(NSString *)role {
    if (!uid) return NO;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", uid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 5 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"<null>"] || [cleanId isEqualToString:@"-1"] || [cleanId isEqualToString:@"0"]) return NO;
    if ([cleanId isEqualToString:self.selfUserId] || [cleanId hasPrefix:@"@TGS#"]) return NO;

    NSString *cleanName = (name && ![name isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", name] : @"";

    @synchronized (self) {
        ACContactItem *existing = self.groupMemberMap[cleanId];
        if (existing) {
            if (cleanName.length > 0 && ![cleanName isEqualToString:cleanId] && ([existing.name isEqualToString:cleanId] || [existing.name hasPrefix:@"群友_"])) {
                existing.name = cleanName;
            }
            if (gid && gid.length > 0) existing.fromGroupId = gid;
            if (role && role.length > 0) existing.roleDesc = role;
            return NO;
        }

        ACContactItem *item = [[ACContactItem alloc] init];
        item.targetId = cleanId;
        item.name = cleanName.length > 0 ? cleanName : [NSString stringWithFormat:@"群友_%@", [cleanId substringFromIndex:MAX(0, (int)cleanId.length - 4)]];
        item.fromGroupId = gid ?: @"";
        item.roleDesc = role ?: @"群成员";
        item.sourceType = 1;
        item.chatAllowed = YES;
        item.isSelected = NO;

        self.groupMemberMap[cleanId] = item;
        [self.groupMemberList addObject:item];
        return YES;
    }
}

- (void)addGroupWithId:(NSString *)gid name:(NSString *)name {
    if (!gid) return;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", gid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 3 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:@"<null>"] || [cleanId isEqualToString:@"0"]) return;
    if (![cleanId hasPrefix:@"@TGS#"] && cleanId.length > 15) return;

    NSString *cleanName = (name && ![name isKindOfClass:[NSNull class]]) ? [NSString stringWithFormat:@"%@", name] : @"";

    @synchronized (self) {
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
        item.sourceType = 2;
        item.roleDesc = @"群组";
        item.chatAllowed = YES;
        item.isSelected = NO;

        self.groupMap[cleanId] = item;
        [self.groupList addObject:item];
    }
}

- (void)parseJSONWithContext:(id)jsonObj {
    if (!jsonObj) return;
    if ([jsonObj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)jsonObj;
        if (dict[@"appUserExperienceList"] || dict[@"realityValue"]) return;

        NSString *directId = [NSString stringWithFormat:@"%@", dict[@"id"] ?: @""];
        if ([directId hasPrefix:@"@TGS#"] && dict[@"name"]) {
            [self addGroupWithId:directId name:[NSString stringWithFormat:@"%@", dict[@"name"]]];
            if (dict[@"owner"]) {
                [self addGroupMemberWithId:[NSString stringWithFormat:@"%@", dict[@"owner"]] name:@"群主" groupId:directId role:@"群主"];
            }
        }

        NSString *groupId = [NSString stringWithFormat:@"%@", dict[@"groupId"] ?: @""];
        if ([groupId hasPrefix:@"@TGS#"]) {
            [self addGroupWithId:groupId name:dict[@"groupName"]];
            if (dict[@"userId"] && [dict[@"userInfo"] isKindOfClass:[NSDictionary class]]) {
                NSDictionary *uInfo = dict[@"userInfo"];
                [self addGroupMemberWithId:[NSString stringWithFormat:@"%@", dict[@"userId"]]
                                      name:uInfo[@"clientUserNickName"] ?: dict[@"customName"]
                                   groupId:groupId
                                      role:dict[@"customName"] ?: dict[@"role"] ?: @"群管"];
            }
            if (dict[@"createUser"] && [dict[@"appUserInfo"] isKindOfClass:[NSDictionary class]]) {
                NSDictionary *uInfo = dict[@"appUserInfo"];
                [self addGroupMemberWithId:[NSString stringWithFormat:@"%@", uInfo[@"id"] ?: dict[@"createUser"]]
                                      name:uInfo[@"clientUserNickName"]
                                   groupId:groupId
                                      role:@"群活跃"];
            }
        }

        id friendId = dict[@"friendId"];
        if (friendId && ![friendId isKindOfClass:[NSNull class]]) {
            NSString *remark = dict[@"remark"];
            NSString *nick = dict[@"nickname"] ?: dict[@"appUserInfo"][@"clientUserNickName"];
            NSString *finalName = (remark && ![remark isKindOfClass:[NSNull class]] && [remark description].length > 0) ? [NSString stringWithFormat:@"%@ (%@)", remark, nick ?: @""] : nick;
            [self addFriendWithId:[NSString stringWithFormat:@"%@", friendId] name:finalName tag:@"好友" chatAllowed:YES];
        }

        if (dict[@"contentText"] && [dict[@"userInfo"] isKindOfClass:[NSDictionary class]]) {
            NSDictionary *uInfo = dict[@"userInfo"];
            NSString *uid = [NSString stringWithFormat:@"%@", uInfo[@"id"] ?: dict[@"userId"]];
            NSString *nick = uInfo[@"clientUserNickName"];
            BOOL allow = [[NSString stringWithFormat:@"%@", uInfo[@"chatMeType"] ?: @"0"] isEqualToString:@"0"];
            [self addFriendWithId:uid name:nick tag:(allow ? @"动态可聊" : @"动态用户") chatAllowed:allow];
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

#pragma mark - 核心突破：针对 7 万人大群的 nextSeq 无限游标翻页引擎 + 历史消息深度回溯

// 递归拉取单个群的所有分页成员（突破单页 100 人限制）
- (void)crawlGroupMembersPageForGroup:(NSString *)gid
                              nextSeq:(uint64_t)seq
                            pageIndex:(NSInteger)pageIdx
                             progress:(void(^)(NSString *msg))progressBlock
                           completion:(void(^)(void))completion {
    Class v2Cls = NSClassFromString(@"V2TIMManager");
    if (!v2Cls || ![v2Cls respondsToSelector:@selector(sharedInstance)]) {
        if (completion) completion();
        return;
    }
    id mgr = ((id (*)(id, SEL))objc_msgSend)(v2Cls, @selector(sharedInstance));
    SEL getMemSel = NSSelectorFromString(@"getGroupMemberList:filter:nextSeq:succ:fail:");
    if (![mgr respondsToSelector:getMemSel]) {
        if (completion) completion();
        return;
    }

    __weak typeof(self) weakSelf = self;
    void (^succBlock)(uint64_t, NSArray *) = ^(uint64_t nextSeq, NSArray *memberList) {
        NSInteger newlyAdded = 0;
        if ([memberList isKindOfClass:[NSArray class]]) {
            for (id mem in memberList) {
                @try {
                    NSString *uid = [mem valueForKey:@"userID"];
                    NSString *nick = [mem valueForKey:@"nickName"];
                    if (!nick || nick.length == 0) nick = [mem valueForKey:@"nameCard"];
                    if (!nick || nick.length == 0) nick = [mem valueForKey:@"friendRemark"];
                    if ([weakSelf addGroupMemberWithId:uid name:nick groupId:gid role:@"群成员"]) {
                        newlyAdded++;
                    }
                } @catch (NSException *e) {}
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (progressBlock) {
                progressBlock([NSString stringWithFormat:@"⏳ 正在深度拉取群成员(第%ld页)：累计已获 %lu 人...",
                               (long)(pageIdx + 1), (unsigned long)weakSelf.groupMemberList.count]);
            }
        });

        // 每满 5 页自动保存一次本地缓存，防止中途退出丢失
        if (pageIdx % 5 == 0) {
            [weakSelf saveLocalPermanentCache];
        }

        // 只要 nextSeq != 0 且本页有返回成员，继续递归拉取下一页（最高支持连拉 800 页 = 80,000 人）
        if (nextSeq != 0 && nextSeq != seq && memberList.count > 0 && pageIdx < 800) {
            // 间隔 120ms 拉下一页，既快又不会触发腾讯 IM SDK 频率限制
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf crawlGroupMembersPageForGroup:gid
                                                nextSeq:nextSeq
                                              pageIndex:pageIdx + 1
                                               progress:progressBlock
                                             completion:completion];
            });
        } else {
            if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        }
    };

    void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) {
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    };

    NSMethodSignature *sig = [mgr methodSignatureForSelector:getMemSel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:mgr];
    [inv setSelector:getMemSel];
    uint32_t filter = 0; // V2TIM_GROUP_MEMBER_FILTER_ALL (0 = 全部成员)
    uint64_t currentSeq = seq;
    [inv setArgument:&gid atIndex:2];
    [inv setArgument:&filter atIndex:3];
    [inv setArgument:&currentSeq atIndex:4];
    [inv setArgument:&succBlock atIndex:5];
    [inv setArgument:&failBlock atIndex:6];
    [inv invoke];
}

// 递归回溯群历史消息中的发言人与进群成员（针对开启了成员保护的超级大群补充提取）
- (void)crawlGroupHistoryMessages:(NSString *)gid
                          lastMsg:(id)lastMsg
                        pageIndex:(NSInteger)pageIdx
                       completion:(void(^)(void))completion {
    Class v2Cls = NSClassFromString(@"V2TIMManager");
    if (!v2Cls || ![v2Cls respondsToSelector:@selector(sharedInstance)]) {
        if (completion) completion();
        return;
    }
    id mgr = ((id (*)(id, SEL))objc_msgSend)(v2Cls, @selector(sharedInstance));
    SEL getHistSel = NSSelectorFromString(@"getGroupHistoryMessageList:count:lastMsg:succ:fail:");
    if (![mgr respondsToSelector:getHistSel]) {
        if (completion) completion();
        return;
    }

    __weak typeof(self) weakSelf = self;
    void (^succBlock)(NSArray *) = ^(NSArray *msgs) {
        if (![msgs isKindOfClass:[NSArray class]] || msgs.count == 0) {
            if (completion) dispatch_async(dispatch_get_main_queue(), completion);
            return;
        }
        for (id msg in msgs) {
            @try {
                NSString *sender = [msg valueForKey:@"sender"];
                NSString *nick = [msg valueForKey:@"nickName"] ?: [msg valueForKey:@"nameCard"];
                [weakSelf addGroupMemberWithId:sender name:nick groupId:gid role:@"群发言"];
            } @catch (NSException *e) {}
        }
        // 连续向前翻取最多 25 页历史消息（约 2500 条消息中的所有群成员）
        if (msgs.count >= 50 && pageIdx < 25) {
            id oldestMsg = [msgs lastObject];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf crawlGroupHistoryMessages:gid lastMsg:oldestMsg pageIndex:pageIdx + 1 completion:completion];
            });
        } else {
            if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        }
    };

    void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) {
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    };

    NSMethodSignature *sig = [mgr methodSignatureForSelector:getHistSel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:mgr];
    [inv setSelector:getHistSel];
    int count = 100;
    id lastM = lastMsg;
    [inv setArgument:&gid atIndex:2];
    [inv setArgument:&count atIndex:3];
    [inv setArgument:&lastM atIndex:4];
    [inv setArgument:&succBlock atIndex:5];
    [inv setArgument:&failBlock atIndex:6];
    [inv invoke];
}

// 兼容旧版 TIMGroupManager getGroupMembers 全量接口
- (void)crawlLegacyTIMGroupMembers:(NSString *)gid {
    Class timGrpCls = NSClassFromString(@"TIMGroupManager");
    if (timGrpCls && [timGrpCls respondsToSelector:@selector(sharedInstance)]) {
        id gMgr = ((id (*)(id, SEL))objc_msgSend)(timGrpCls, @selector(sharedInstance));
        SEL getMemSel = NSSelectorFromString(@"getGroupMembers:succ:fail:");
        if ([gMgr respondsToSelector:getMemSel]) {
            void (^succ)(NSArray *) = ^(NSArray *list) {
                for (id info in list) {
                    @try {
                        NSString *uid = [info valueForKey:@"member"];
                        NSString *nameCard = [info valueForKey:@"nameCard"];
                        [self addGroupMemberWithId:uid name:nameCard groupId:gid role:@"群成员"];
                    } @catch (NSException *e) {}
                }
            };
            void (^fail)(int, NSString *) = ^(int c, NSString *d) {};
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(gMgr, getMemSel, gid, succ, fail);
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
        if ([lower hasSuffix:@".db"] || [lower hasSuffix:@".sqlite"] || [lower hasSuffix:@".sqlite3"]) {
            NSString *fullPath = [home stringByAppendingPathComponent:relPath];
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
                        // 扫描最大行数提升到 50000，确保腾讯 IM 本地缓存数据库里的群成员全部被捞出
                        NSString *sql = [NSString stringWithFormat:@"SELECT * FROM \"%@\" LIMIT 50000;", t];
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
                                        if (j) [self parseJSONWithContext:j];
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

- (void)reloadAllDataWithProgress:(void(^)(NSString *progressMsg))progressBlock
                       completion:(void(^)(NSString *finalMsg))completion {
    [self scanLocalDatabases];

    Class v2Cls = NSClassFromString(@"V2TIMManager");
    if (!v2Cls || ![v2Cls respondsToSelector:@selector(sharedInstance)]) {
        [self saveLocalPermanentCache];
        if (completion) completion(@"IM未就绪，已显示本地永久缓存");
        return;
    }

    id mgr = ((id (*)(id, SEL))objc_msgSend)(v2Cls, @selector(sharedInstance));
    dispatch_group_t baseGroup = dispatch_group_create();

    // 1. 拉取会话列表
    SEL getConvSel = NSSelectorFromString(@"getConversationList:count:succ:fail:");
    if ([mgr respondsToSelector:getConvSel]) {
        dispatch_group_enter(baseGroup);
        void (^succBlock)(NSArray *, uint64_t, BOOL) = ^(NSArray *list, uint64_t nextSeq, BOOL isFinished) {
            for (id conv in list) {
                @try {
                    NSString *showName = [conv valueForKey:@"showName"];
                    NSString *uid = [conv valueForKey:@"userID"];
                    NSString *gid = [conv valueForKey:@"groupID"];
                    if (gid && [gid isKindOfClass:[NSString class]] && gid.length > 0) {
                        [self addGroupWithId:gid name:showName];
                    } else if (uid && [uid isKindOfClass:[NSString class]] && uid.length > 0) {
                        [self addFriendWithId:uid name:showName tag:@"会话" chatAllowed:YES];
                    }
                } @catch (NSException *e) {}
            }
            dispatch_group_leave(baseGroup);
        };
        void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) { dispatch_group_leave(baseGroup); };
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

    // 2. 拉取已加入群列表
    SEL getGroupsSel = NSSelectorFromString(@"getJoinedGroupList:fail:");
    if ([mgr respondsToSelector:getGroupsSel]) {
        dispatch_group_enter(baseGroup);
        void (^succBlock)(NSArray *) = ^(NSArray *groupInfos) {
            for (id gInfo in groupInfos) {
                @try {
                    NSString *gid = [gInfo valueForKey:@"groupID"];
                    NSString *gName = [gInfo valueForKey:@"groupName"];
                    [self addGroupWithId:gid name:gName];
                } @catch (NSException *e) {}
            }
            dispatch_group_leave(baseGroup);
        };
        void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) { dispatch_group_leave(baseGroup); };
        ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, getGroupsSel, succBlock, failBlock);
    }

    // 3. 拿到所有群 ID 后，依次对每个群启动「无限游标翻页拉取群成员」+「历史消息发言人回溯」
    dispatch_group_notify(baseGroup, dispatch_get_main_queue(), ^{
        NSArray<ACContactItem *> *allGroups = [self.groupList copy];
        if (allGroups.count == 0) {
            [self saveLocalPermanentCache];
            if (completion) completion([NSString stringWithFormat:@"已就绪：%lu 好友 | %lu 群成员 | %lu 群聊",
                                        (unsigned long)self.friendList.count,
                                        (unsigned long)self.groupMemberList.count,
                                        (unsigned long)self.groupList.count]);
            return;
        }

        dispatch_group_t memberCrawlGroup = dispatch_group_create();
        for (ACContactItem *grp in allGroups) {
            NSString *gid = grp.targetId;
            if (![gid hasPrefix:@"@TGS#"]) continue;

            // 3.1 旧版 TIMGroupManager 补充
            [self crawlLegacyTIMGroupMembers:gid];

            // 3.2 V2TIMManager 无限分页拉取群成员
            dispatch_group_enter(memberCrawlGroup);
            [self crawlGroupMembersPageForGroup:gid nextSeq:0 pageIndex:0 progress:progressBlock completion:^{
                dispatch_group_leave(memberCrawlGroup);
            }];

            // 3.3 群历史消息回溯提取发言人
            dispatch_group_enter(memberCrawlGroup);
            [self crawlGroupHistoryMessages:gid lastMsg:nil pageIndex:0 completion:^{
                dispatch_group_leave(memberCrawlGroup);
            }];
        }

        dispatch_group_notify(memberCrawlGroup, dispatch_get_main_queue(), ^{
            [self saveLocalPermanentCache];
            NSString *finalStr = [NSString stringWithFormat:@"✅ 已永久保存：%lu 好友 | %lu 群成员 | %lu 群聊",
                                  (unsigned long)self.friendList.count,
                                  (unsigned long)self.groupMemberList.count,
                                  (unsigned long)self.groupList.count];
            if (completion) completion(finalStr);
        });
    });
}

#pragma mark - 3. 支持「图片原图 + 文本」双模式群发与 120001 自动破盾

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
                [req setValue:@(1) forKey:@"addType"];
            } @catch (NSException *e) {}
            void (^succ)(id) = ^(id res) { if (completion) dispatch_async(dispatch_get_main_queue(), completion); };
            void (^fail)(int, NSString *) = ^(int c, NSString *d) { if (completion) dispatch_async(dispatch_get_main_queue(), completion); };
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(manager, addFriendSel, req, succ, fail);
            return;
        }
    }
    if (completion) completion();
}

- (void)rawSendV2Message:(id)v2Msg toItem:(ACContactItem *)item completion:(void(^)(BOOL ok, int code, NSString *desc))completion {
    Class v2MgrCls = NSClassFromString(@"V2TIMManager");
    id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));
    SEL sendMsgSel = NSSelectorFromString(@"sendMessage:receiver:groupID:priority:onlineUserOnly:offlinePushInfo:progress:succ:fail:");

    if (!v2Msg || ![manager respondsToSelector:sendMsgSel]) {
        if (completion) completion(NO, -1, @"无法构造IM消息");
        return;
    }

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
        if (customData) [v2Msg setValue:customData forKey:@"cloudCustomData"];
    } @catch (NSException *e) {}

    BOOL isGroup = (item.sourceType == 2);
    NSString *receiver = isGroup ? nil : item.targetId;
    NSString *groupID = isGroup ? item.targetId : nil;

    void (^succBlock)(void) = ^{
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, 0, nil); });
    };
    void (^failBlock)(int, NSString *) = ^(int code, NSString *desc) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, code, desc); });
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
}

- (void)sendMessageWithText:(NSString *)text
                      image:(UIImage *)image
                     toItem:(ACContactItem *)item
                 completion:(void(^)(BOOL ok, NSString *detail))completion {
    Class v2MgrCls = NSClassFromString(@"V2TIMManager");
    if (!v2MgrCls || ![v2MgrCls respondsToSelector:@selector(sharedInstance)]) {
        if (completion) completion(NO, @"IM未初始化");
        return;
    }
    id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));

    // A. 如果有选中的图片，优先使用 V2TIMManager -> createImageMessage: 发送真实图片气泡
    id v2ImageMsg = nil;
    if (image) {
        NSData *jpgData = UIImageJPEGRepresentation(image, 0.85);
        if (jpgData) {
            NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ac_forward_temp.jpg"];
            [jpgData writeToFile:tmpPath atomically:YES];
            SEL createImgSel = NSSelectorFromString(@"createImageMessage:");
            if ([manager respondsToSelector:createImgSel]) {
                v2ImageMsg = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createImgSel, tmpPath);
            }
        }
    }

    // B. 构造文本消息
    id v2TextMsg = nil;
    NSString *cleanText = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanText.length > 0) {
        SEL createTextSel = NSSelectorFromString(@"createTextMessage:");
        if ([manager respondsToSelector:createTextSel]) {
            v2TextMsg = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createTextSel, cleanText);
        }
    }

    id primaryMsg = v2ImageMsg ?: v2TextMsg;
    if (!primaryMsg) {
        if (completion) completion(NO, @"消息内容为空");
        return;
    }

    [self rawSendV2Message:primaryMsg toItem:item completion:^(BOOL ok, int code, NSString *desc) {
        if (ok) {
            // 如果同时有图片和附加文字，顺带把文字也发出去
            if (v2ImageMsg && v2TextMsg) {
                [self rawSendV2Message:v2TextMsg toItem:item completion:^(BOOL okT, int cT, NSString *dT) {
                    if (completion) completion(YES, @"图文成功");
                }];
            } else {
                if (completion) completion(YES, @"成功");
            }
            return;
        }

        // 遇到 120001 等非好友隐私拦截，自动调用加好友破盾并重发
        if (item.sourceType != 2) {
            [self autoAddIMFriend:item.targetId completion:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self rawSendV2Message:primaryMsg toItem:item completion:^(BOOL ok2, int code2, NSString *desc2) {
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

#pragma mark - 4. 转发助手弹窗控制器 (ACForwardAssistantVC)

@interface ACForwardAssistantVC : UIViewController <UITableViewDelegate, UITableViewDataSource, UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@property (nonatomic, strong) UIView *headerContainer;
@property (nonatomic, strong) UITextView *contentTextView;
@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, strong) UIButton *pickImageBtn;
@property (nonatomic, strong) UIButton *clearImageBtn;
@property (nonatomic, strong) UIImage *selectedImage;
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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"全量刷新" style:UIBarButtonItemStyleDone target:self action:@selector(refreshData)];

    if (__pendingForwardImage) {
        self.selectedImage = __pendingForwardImage;
    }

    [self setupCleanUI];
    [self updateUI];

    // 打开时先展示本地永久保存的数据，同时后台自动增量拉取最新数据
    ACForwardHelperManager *mgr = [ACForwardHelperManager shared];
    if (mgr.friendList.count > 0 || mgr.groupMemberList.count > 0) {
        self.statusLabel.text = [NSString stringWithFormat:@"📁 已加载本地永久缓存：%lu 好友 | %lu 群成员 | %lu 群聊",
                                 (unsigned long)mgr.friendList.count,
                                 (unsigned long)mgr.groupMemberList.count,
                                 (unsigned long)mgr.groupList.count];
    } else {
        [self refreshData];
    }
}

- (void)setupCleanUI {
    CGFloat width = self.view.bounds.size.width;

    self.headerContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 236)];
    self.headerContainer.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self.view addSubview:self.headerContainer];

    // 1. 左侧文本编辑框 + 右侧图片预览/选择区（支持图文同发）
    CGFloat imgBoxW = 84.0;
    self.contentTextView = [[UITextView alloc] initWithFrame:CGRectMake(16, 18, width - 32 - imgBoxW - 10, 84)];
    self.contentTextView.font = [UIFont systemFontOfSize:15];
    self.contentTextView.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    self.contentTextView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.contentTextView.layer.cornerRadius = 12;
    self.contentTextView.layer.borderColor = [UIColor separatorColor].CGColor;
    self.contentTextView.layer.borderWidth = 0.5;
    if (__pendingForwardText && __pendingForwardText.length > 0) {
        self.contentTextView.text = __pendingForwardText;
    } else if (self.selectedImage) {
        self.contentTextView.text = @"";
    } else {
        self.contentTextView.text = @"您好，这是一条群发消息！";
    }
    [self.headerContainer addSubview:self.contentTextView];

    // 右侧图片框
    self.previewImageView = [[UIImageView alloc] initWithFrame:CGRectMake(width - 16 - imgBoxW, 18, imgBoxW, 84)];
    self.previewImageView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.previewImageView.layer.cornerRadius = 12;
    self.previewImageView.layer.borderColor = [UIColor separatorColor].CGColor;
    self.previewImageView.layer.borderWidth = 0.5;
    self.previewImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.previewImageView.clipsToBounds = YES;
    self.previewImageView.userInteractionEnabled = YES;
    self.previewImageView.image = self.selectedImage;
    [self.headerContainer addSubview:self.previewImageView];

    self.pickImageBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.pickImageBtn.frame = self.previewImageView.bounds;
    self.pickImageBtn.titleLabel.numberOfLines = 2;
    self.pickImageBtn.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.pickImageBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [self.pickImageBtn setTitle:self.selectedImage ? @"" : @"🖼️\n选图/长按图" forState:UIControlStateNormal];
    [self.pickImageBtn addTarget:self action:@selector(chooseImageFromAlbum) forControlEvents:UIControlEventTouchUpInside];
    [self.previewImageView addSubview:self.pickImageBtn];

    self.clearImageBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.clearImageBtn.frame = CGRectMake(imgBoxW - 24, 2, 22, 22);
    self.clearImageBtn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
    self.clearImageBtn.layer.cornerRadius = 11;
    [self.clearImageBtn setTitle:@"✕" forState:UIControlStateNormal];
    self.clearImageBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    self.clearImageBtn.hidden = (self.selectedImage == nil);
    [self.clearImageBtn addTarget:self action:@selector(clearSelectedImage) forControlEvents:UIControlEventTouchUpInside];
    [self.previewImageView addSubview:self.clearImageBtn];

    // 2. 三栏分段器
    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"好友 (0)", @"群成员 (0)", @"群聊 (0)"]];
    self.tabControl.frame = CGRectMake(16, 114, width - 32, 34);
    self.tabControl.selectedSegmentIndex = 1; // 默认切到群成员方便查看
    [self.tabControl addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    [self.headerContainer addSubview:self.tabControl];

    // 3. 快捷选择按钮栏
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

    // 4. 状态与进度栏
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 200, width - 32, 24)];
    self.statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.adjustsFontSizeToFitWidth = YES;
    [self.headerContainer addSubview:self.statusLabel];

    // 5. 列表
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = 56.0;
    self.tableView.contentInset = UIEdgeInsetsMake(4, 0, 100, 0);
    [self.view addSubview:self.tableView];

    // 6. 右下角唯一悬浮发送球
    [self setupFloatingButton];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;
    CGFloat topOffset = self.view.safeAreaInsets.top;

    CGFloat headerH = 232.0;
    self.headerContainer.frame = CGRectMake(0, topOffset, width, headerH);

    CGFloat tableY = topOffset + headerH;
    self.tableView.frame = CGRectMake(0, tableY, width, height - tableY);

    if (self.floatingSendBtn && self.floatingSendBtn.tag != 999) {
        CGFloat btnW = 138.0;
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

- (void)chooseImageFromAlbum {
    [self.view endEditing:YES];
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    if (img) {
        self.selectedImage = img;
        self.previewImageView.image = img;
        [self.pickImageBtn setTitle:@"" forState:UIControlStateNormal];
        self.clearImageBtn.hidden = NO;
    }
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)clearSelectedImage {
    self.selectedImage = nil;
    __pendingForwardImage = nil;
    self.previewImageView.image = nil;
    [self.pickImageBtn setTitle:@"🖼️\n选图/长按图" forState:UIControlStateNormal];
    self.clearImageBtn.hidden = YES;
}

- (void)refreshData {
    [self.view endEditing:YES];
    self.statusLabel.textColor = [UIColor systemBlueColor];
    self.statusLabel.text = @"⏳ 正在启动多页游标递归拉取全量群成员...";
    __weak typeof(self) weakSelf = self;
    [[ACForwardHelperManager shared] reloadAllDataWithProgress:^(NSString *progressMsg) {
        weakSelf.statusLabel.text = progressMsg;
        [weakSelf updateUI];
        [weakSelf.tableView reloadData];
    } completion:^(NSString *finalMsg) {
        weakSelf.statusLabel.textColor = [UIColor secondaryLabelColor];
        weakSelf.statusLabel.text = finalMsg;
        [weakSelf updateUI];
        [weakSelf.tableView reloadData];
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
    if (sender.tag == 600) {
        for (ACContactItem *i in [self currentItems]) i.isSelected = YES;
    } else if (sender.tag == 601) {
        for (ACContactItem *i in mgr.groupMemberList) i.isSelected = YES;
        self.tabControl.selectedSegmentIndex = 1;
    } else if (sender.tag == 602) {
        for (ACContactItem *i in mgr.friendList) i.isSelected = YES;
        for (ACContactItem *i in mgr.groupMemberList) i.isSelected = YES;
        for (ACContactItem *i in mgr.groupList) i.isSelected = YES;
    } else if (sender.tag == 603) {
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
    NSString *badge = (item.sourceType == 2) ? @"👥 [群聊]" : ((item.sourceType == 1) ? [NSString stringWithFormat:@"🟢 [%@]", item.roleDesc ?: @"群成员"] : @"👤 [好友]");
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", badge, item.name];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"ID: %@ %@", item.targetId, item.fromGroupId.length > 0 ? [NSString stringWithFormat:@"| 群:%@", item.fromGroupId] : @""];
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
    if (text.length == 0 && !self.selectedImage) {
        self.statusLabel.textColor = [UIColor systemRedColor];
        self.statusLabel.text = @"❌ 请输入文字或选择一张图片！";
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
    __block NSString *lastFail = @"";
    __block NSInteger idx = 0;
    NSInteger total = targets.count;
    UIImage *imgToSend = self.selectedImage;
    __weak typeof(self) weakSelf = self;

    __block void (^nextStep)(void) = ^{
        if (idx >= total) {
            weakSelf.floatingSendBtn.enabled = YES;
            weakSelf.statusLabel.textColor = okCount > 0 ? [UIColor systemGreenColor] : [UIColor systemRedColor];
            weakSelf.statusLabel.text = [NSString stringWithFormat:@"✅ 发送完成：成功 %ld | 失败 %ld %@", (long)okCount, (long)failCount, lastFail];
            return;
        }
        ACContactItem *cur = targets[idx];
        weakSelf.statusLabel.textColor = [UIColor systemBlueColor];
        weakSelf.statusLabel.text = [NSString stringWithFormat:@"⏳ 正在发送 (%ld/%ld): %@", (long)(idx + 1), (long)total, cur.name];

        [[ACForwardHelperManager shared] sendMessageWithText:text image:imgToSend toItem:cur completion:^(BOOL ok, NSString *detail) {
            if (ok) okCount++;
            else { failCount++; lastFail = detail ?: @""; }
            idx++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.42 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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

#pragma mark - 5. 视图树图片/文本提取工具（用于聊天气泡长按）

static UIImage *ACFindLargestImageInView(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.05) return nil;
    UIImage *bestImg = nil;
    CGFloat maxArea = 0;

    if ([view isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)view;
        if (iv.image && iv.bounds.size.width > 45 && iv.bounds.size.height > 45) {
            bestImg = iv.image;
            maxArea = iv.bounds.size.width * iv.bounds.size.height;
        }
    }
    for (UIView *sub in view.subviews) {
        UIImage *subImg = ACFindLargestImageInView(sub);
        if (subImg && (sub.bounds.size.width * sub.bounds.size.height >= maxArea)) {
            bestImg = subImg;
            maxArea = sub.bounds.size.width * sub.bounds.size.height;
        }
    }
    return bestImg;
}

static NSString *ACFindChatTextInView(UIView *view) {
    if (!view || view.hidden) return nil;
    if ([view isKindOfClass:[UITextView class]]) {
        NSString *t = ((UITextView *)view).text;
        if (t.length > 0) return t;
    }
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)view).text;
        // 排除时间戳（如 "15:03✓"）
        if (t.length > 0 && ![t hasSuffix:@"✓"] && t.length > 2) {
            return t;
        }
    }
    for (UIView *sub in view.subviews) {
        NSString *subText = ACFindChatTextInView(sub);
        if (subText.length > 0) return subText;
    }
    return nil;
}

static void ACPresentForwardAssistantFromTopVC(void) {
    UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
    if (!keyWin) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { keyWin = w; break; }
        }
    }
    UIViewController *topVC = keyWin.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    if ([NSStringFromClass([topVC class]) containsString:@"ACForwardAssistantVC"]) return;

    ACForwardAssistantVC *vc = [[ACForwardAssistantVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [topVC presentViewController:nav animated:YES completion:nil];
}

#pragma mark - 6. 全局 JSON 拦截入库 + 聊天气泡长按联动 + 关于飞机右上角入口

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError * _Nullable *)error {
    id res = %orig;
    if ([res isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)res;
        if (dict[@"code"] && dict[@"data"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[ACForwardHelperManager shared] parseJSONWithContext:dict[@"data"]];
                [[ACForwardHelperManager shared] saveLocalPermanentCache];
            });
        }
    }
    return res;
}

%end

// 捕获用户在聊天气泡上的长按手势，自动提取当前气泡里的图片或文字，并在弹出菜单旁显示「🚀 转发助手」悬浮快贴
%hook UILongPressGestureRecognizer

- (void)setState:(UIGestureRecognizerState)state {
    %orig;
    if (state == UIGestureRecognizerStateBegan) {
        UIView *v = self.view;
        if (!v) return;

        // 向上找到当前聊天气泡所在的 UITableViewCell
        UIView *cellView = v;
        while (cellView && ![cellView isKindOfClass:[UITableViewCell class]] && cellView.superview) {
            cellView = cellView.superview;
        }
        NSString *cellCls = NSStringFromClass([cellView class]);
        if ([cellCls containsString:@"Chat"] || [cellCls containsString:@"Bubble"] || [cellCls containsString:@"Message"]) {
            __lastLongPressedView = cellView;
            __pendingForwardImage = ACFindLargestImageInView(cellView);
            __pendingForwardText = ACFindChatTextInView(cellView);

            // 在官方长按菜单（回复/保存图片/转发/删除）顶部自动弹出一个蓝色的【🚀 用转发助手群发】快捷胶囊条
            UIWindow *win = v.window ?: [UIApplication sharedApplication].keyWindow;
            UIView *oldBar = [win viewWithTag:778899];
            [oldBar removeFromSuperview];

            UIButton *quickForwardPill = [UIButton buttonWithType:UIButtonTypeCustom];
            quickForwardPill.tag = 778899;
            CGFloat pillW = 210.0;
            CGFloat pillH = 42.0;
            CGPoint touchPt = [self locationInView:win];
            CGFloat pillX = MIN(MAX(16.0, touchPt.x - pillW / 2.0), win.bounds.size.width - pillW - 16.0);
            CGFloat pillY = MAX(64.0, touchPt.y - 95.0);
            quickForwardPill.frame = CGRectMake(pillX, pillY, pillW, pillH);
            quickForwardPill.backgroundColor = [UIColor systemBlueColor];
            quickForwardPill.layer.cornerRadius = 21.0;
            quickForwardPill.layer.shadowColor = [UIColor blackColor].CGColor;
            quickForwardPill.layer.shadowOpacity = 0.35;
            quickForwardPill.layer.shadowOffset = CGSizeMake(0, 4);
            quickForwardPill.layer.shadowRadius = 6.0;

            NSString *typeTag = __pendingForwardImage ? @"🖼️群发此图片" : @"📝群发此消息";
            [quickForwardPill setTitle:[NSString stringWithFormat:@"🚀 转发助手 (%@)", typeTag] forState:UIControlStateNormal];
            [quickForwardPill setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            quickForwardPill.titleLabel.font = [UIFont boldSystemFontOfSize:14];
            [quickForwardPill addTarget:win action:@selector(ac_onQuickPillTap:) forControlEvents:UIControlEventTouchUpInside];
            [win addSubview:quickForwardPill];

            // 4.5 秒后若未点击则自动消失
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (quickForwardPill.superview) [quickForwardPill removeFromSuperview];
            });
        }
    }
}

%end

%hook UIWindow

%new
- (void)ac_onQuickPillTap:(UIButton *)sender {
    [sender removeFromSuperview];
    ACPresentForwardAssistantFromTopVC();
}

%end

// 同时拦截官方长按菜单里的“转发”动作以及“关于飞机”右上角按钮
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
    __pendingForwardImage = nil;
    __pendingForwardText = nil;
    ACPresentForwardAssistantFromTopVC();
}

%end
