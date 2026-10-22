#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

#pragma mark - 1. 本地持久化与联系人管理引擎

@interface ACContactItem : NSObject <NSCoding>
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *fromGroupId;
@property (nonatomic, copy) NSString *roleDesc;
@property (nonatomic, assign) NSInteger sourceType; // 0: 好友, 1: 群成员, 2: 群聊
@property (nonatomic, assign) BOOL isSelected;
@end

@implementation ACContactItem
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.targetId forKey:@"targetId"];
    [coder encodeObject:self.name forKey:@"name"];
    [coder encodeObject:self.fromGroupId forKey:@"fromGroupId"];
    [coder encodeObject:self.roleDesc forKey:@"roleDesc"];
    [coder encodeInteger:self.sourceType forKey:@"sourceType"];
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        self.targetId = [coder decodeObjectForKey:@"targetId"];
        self.name = [coder decodeObjectForKey:@"name"];
        self.fromGroupId = [coder decodeObjectForKey:@"fromGroupId"];
        self.roleDesc = [coder decodeObjectForKey:@"roleDesc"];
        self.sourceType = [coder decodeIntegerForKey:@"sourceType"];
        self.isSelected = NO;
    }
    return self;
}
@end

static NSString *__sharedForwardText = nil;
static UIImage *__sharedForwardImage = nil;

@interface ACForwardHelperManager : NSObject
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *friendList;
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *groupMemberList;
@property (nonatomic, strong) NSMutableArray<ACContactItem *> *groupList;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *friendMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *groupMemberMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACContactItem *> *groupMap;
@property (nonatomic, copy) NSString *selfUserId;

+ (instancetype)shared;
- (void)loadLocalPermanentCache;
- (void)saveLocalPermanentCache;
- (void)addFriendWithId:(NSString *)uid name:(NSString *)name tag:(NSString *)tag;
- (void)addGroupMemberWithId:(NSString *)uid name:(NSString *)name groupId:(NSString *)gid role:(NSString *)role;
- (void)addGroupWithId:(NSString *)gid name:(NSString *)name;
- (void)parseJSONWithContext:(id)jsonObj;
- (void)reloadAllDataWithCompletion:(void(^)(NSString *statusMsg))completion;
- (void)sendContentToItem:(ACContactItem *)item completion:(void(^)(BOOL ok, NSString *detail))completion;
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
        // 启动时自动从本地加载永久保存的数据
        [instance loadLocalPermanentCache];
    });
    return instance;
}

// 本地文件持久化路径
- (NSString *)cacheFilePath:(NSString *)fileName {
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [docDir stringByAppendingPathComponent:[NSString stringWithFormat:@"AC_%@.plist", fileName]];
}

// 永久保存到本地
- (void)saveLocalPermanentCache {
    @try {
        NSData *fData = [NSKeyedArchiver archivedDataWithRootObject:self.friendList requiringSecureCoding:NO error:nil];
        NSData *mData = [NSKeyedArchiver archivedDataWithRootObject:self.groupMemberList requiringSecureCoding:NO error:nil];
        NSData *gData = [NSKeyedArchiver archivedDataWithRootObject:self.groupList requiringSecureCoding:NO error:nil];
        
        [fData writeToFile:[self cacheFilePath:@"friends"] atomically:YES];
        [mData writeToFile:[self cacheFilePath:@"members"] atomically:YES];
        [gData writeToFile:[self cacheFilePath:@"groups"] atomically:YES];
    } @catch (NSException *e) {}
}

// 从本地加载永久保存的数据
- (void)loadLocalPermanentCache {
    @try {
        NSData *fData = [NSData dataWithContentsOfFile:[self cacheFilePath:@"friends"]];
        if (fData) {
            NSArray *arr = [NSKeyedUnarchiver unarchivedObjectOfClasses:[NSSet setWithObjects:[NSArray class], [ACContactItem class], nil] fromData:fData error:nil];
            if (arr) {
                [self.friendList setArray:arr];
                for (ACContactItem *item in arr) self.friendMap[item.targetId] = item;
            }
        }
        
        NSData *mData = [NSData dataWithContentsOfFile:[self cacheFilePath:@"members"]];
        if (mData) {
            NSArray *arr = [NSKeyedUnarchiver unarchivedObjectOfClasses:[NSSet setWithObjects:[NSArray class], [ACContactItem class], nil] fromData:mData error:nil];
            if (arr) {
                [self.groupMemberList setArray:arr];
                for (ACContactItem *item in arr) self.groupMemberMap[item.targetId] = item;
            }
        }
        
        NSData *gData = [NSData dataWithContentsOfFile:[self cacheFilePath:@"groups"]];
        if (gData) {
            NSArray *arr = [NSKeyedUnarchiver unarchivedObjectOfClasses:[NSSet setWithObjects:[NSArray class], [ACContactItem class], nil] fromData:gData error:nil];
            if (arr) {
                [self.groupList setArray:arr];
                for (ACContactItem *item in arr) self.groupMap[item.targetId] = item;
            }
        }
    } @catch (NSException *e) {}
}

- (void)addFriendWithId:(NSString *)uid name:(NSString *)name tag:(NSString *)tag {
    if (!uid) return;
    NSString *cleanId = [[NSString stringWithFormat:@"%@", uid] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanId.length < 5 || [cleanId isEqualToString:@"(null)"] || [cleanId isEqualToString:self.selfUserId] || [cleanId hasSuffix:@"_collection"] || [cleanId hasPrefix:@"@TGS#"]) return;
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

    ACContactItem *existing = self.groupMemberMap[cleanId];
    if (existing) {
        if (cleanName.length > 0 && ![cleanName isEqualToString:cleanId] && ([existing.name isEqualToString:cleanId] || [existing.name hasPrefix:@"群友_"])) {
            existing.name = cleanName;
        }
        return;
    }

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

// 点击刷新时：拉取最新数据，与本地已有数据合并更新，并写入永久缓存
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
            // 合并完毕后保存到本地永久存储
            [self saveLocalPermanentCache];
            NSString *msg = [NSString stringWithFormat:@"已更新：(本地永久) %lu 好友 | %lu 群成员 | %lu 群聊",
                             (unsigned long)self.friendList.count,
                             (unsigned long)self.groupMemberList.count,
                             (unsigned long)self.groupList.count];
            if (completion) completion(msg);
        });
    });
}

- (void)sendContentToItem:(ACContactItem *)item completion:(void(^)(BOOL ok, NSString *detail))completion {
    Class v2MgrCls = NSClassFromString(@"V2TIMManager");
    if (!v2MgrCls || ![v2MgrCls respondsToSelector:@selector(sharedInstance)]) {
        if (completion) completion(NO, @"IM未就绪");
        return;
    }
    id manager = ((id (*)(id, SEL))objc_msgSend)(v2MgrCls, @selector(sharedInstance));
    NSString *textToSend = __sharedForwardText ?: @"[转发内容]";

    SEL createTextSel = NSSelectorFromString(@"createTextMessage:");
    SEL sendMsgSel = NSSelectorFromString(@"sendMessage:receiver:groupID:priority:onlineUserOnly:offlinePushInfo:progress:succ:fail:");

    if ([manager respondsToSelector:createTextSel] && [manager respondsToSelector:sendMsgSel]) {
        id v2Msg = ((id (*)(id, SEL, NSString *))objc_msgSend)(manager, createTextSel, textToSend);
        BOOL isGroup = (item.sourceType == 2);
        NSString *receiver = isGroup ? nil : item.targetId;
        NSString *groupID = isGroup ? item.targetId : nil;

        void (^succBlock)(void) = ^{
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, @"成功"); });
        };
        void (^failBlock)(int, NSString *) = ^(int code, NSString *desc){
            if (code == 120001) {
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
                        // ARC 下 block 捕获的 __strong 变量取地址会得到 const __strong *，
                        // 无法作为 void * 传给 setArgument:，这里用 __unsafe_unretained 局部变量中转
                        __unsafe_unretained id aMsg = v2Msg;
                        __unsafe_unretained NSString *aRcv = receiver;
                        __unsafe_unretained NSString *aGrp = groupID;
                        __unsafe_unretained id aNil = nil;
                        __unsafe_unretained id aSucc = succBlock;
                        __unsafe_unretained id aFail = failBlock;
                        NSInteger pri = 1; BOOL online = NO;
                        [inv2 setArgument:&aMsg atIndex:2];
                        [inv2 setArgument:&aRcv atIndex:3];
                        [inv2 setArgument:&aGrp atIndex:4];
                        [inv2 setArgument:&pri atIndex:5];
                        [inv2 setArgument:&online atIndex:6];
                        [inv2 setArgument:&aNil atIndex:7];
                        [inv2 setArgument:&aNil atIndex:8];
                        [inv2 setArgument:&aSucc atIndex:9];
                        [inv2 setArgument:&aFail atIndex:10];
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
    if (completion) completion(NO, @"无发送实例");
}

@end

#pragma mark - 2. 转发助手 UI 控制器

@interface ACForwardAssistantVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *floatingSendBtn;
@end

@implementation ACForwardAssistantVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择转发目标 (本地永久缓存)";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.edgesForExtendedLayout = UIRectEdgeNone;
    
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(dismissSelf)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"刷新获取新数据" style:UIBarButtonItemStyleDone target:self action:@selector(refreshData)];
    
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
    self.statusLabel.text = @"已加载本地永久存储的好友与群组";
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
    self.floatingSendBtn.layer.cornerRadius = 24;
    [self.floatingSendBtn addTarget:self action:@selector(startSend) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.floatingSendBtn];
}

- (void)refreshData {
    self.statusLabel.text = @"正在联网获取最新数据并与本地合并...";
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
        [[ACForwardHelperManager shared] sendContentToItem:target completion:^(BOOL success, NSString *detail) {
            if (success) ok++;
            idx++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                loop();
            });
        }];
    };
    loop();
}

- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

#pragma mark - 3. 聊天气泡长按菜单 Hook

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
    __sharedForwardText = nil;
    __sharedForwardImage = nil;
    
    UIPasteboard *board = [UIPasteboard generalPasteboard];
    if (board.string && board.string.length > 0) {
        __sharedForwardText = board.string;
    } else {
        __sharedForwardText = @"[转发消息]";
    }
    
    UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
    UIViewController *rootVC = keyWin.rootViewController;
    while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
    
    ACForwardAssistantVC *vc = [[ACForwardAssistantVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [rootVC presentViewController:nav animated:YES completion:nil];
}
%end
