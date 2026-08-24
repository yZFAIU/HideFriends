//
//  HFSettingViewController.m
//  HideFriends
//
//  v1.3.31 重排版：深灰主题（黑色主/白色辅，不要太黑）
//  结构：总开关 / 隐藏好友管理 / 关于（作者·邮箱·测试版）
//  移除：悬浮窗入口、分项开关、界面诊断
//

#import "HFSettingViewController.h"
#import "HFConstants.h"
#import "HFBlacklist.h"
#import "HFBlacklistViewController.h"

static NSString *const kHFCellReuseId = @"HFCellReuseId";

// 深灰主题色（黑色主 / 白色辅，柔和不过黑）
#define HF_BG_COLOR        [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0]  // #1C1C1E
#define HF_CELL_COLOR      [UIColor colorWithRed:0.17 green:0.17 blue:0.18 alpha:1.0]  // #2C2C2E
#define HF_TEXT_COLOR      [UIColor whiteColor]
#define HF_SUBTEXT_COLOR   [UIColor colorWithWhite:0.78 alpha:1.0]

@interface HFSettingViewController ()
@property(nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *sections;
@end

@implementation HFSettingViewController

#pragma mark - 生命周期

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"隐藏好友设置";
        [self buildSections];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // 深灰主题
    self.view.backgroundColor = HF_BG_COLOR;
    self.tableView.backgroundColor = HF_BG_COLOR;
    // v1.3.32：移除 @available(iOS 15.0, *)——它生成的 ___isOSVersionAtLeast 符号
    // 在越狱 arm64e 环境 DYLD 加载阶段崩溃（symbol not found）
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = HF_BG_COLOR;
    appearance.titleTextAttributes = @{ NSForegroundColorAttributeName: HF_TEXT_COLOR };
    self.navigationController.navigationBar.standardAppearance = appearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
    self.navigationController.navigationBar.tintColor = HF_TEXT_COLOR;

    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                                                  style:UIBarButtonItemStyleDone
                                                                 target:self
                                                                 action:@selector(hf_closeTapped)];
    self.navigationItem.leftBarButtonItem = closeItem;
}

#pragma mark - 数据构建

- (void)buildSections {
    self.sections = @[
        // 分组 0：功能开关
        @[
            @{
                @"key" : HF_KEY_HIDE_ALL_FRIENDS,
                @"title" : @"总开关",
                @"sub" : @"开启后隐藏黑名单好友相关内容",
                @"switch" : @YES,
            },
        ],
        // 分组 1：添加好友
        @[
            @{
                @"title" : @"添加好友",
                @"sub" : @"添加或移除要隐藏的好友",
                @"switch" : @NO,
                @"action" : @"openBlacklist",
            },
        ],
        // 分组 2：关于
        @[
            @{
                @"title" : @"作者",
                @"sub" : @"yZFAIU",
                @"switch" : @NO,
            },
            @{
                @"title" : @"反馈邮箱",
                @"sub" : @"yzfaiu.nd@foxmail.com",
                @"switch" : @NO,
            },
            @{
                @"title" : @"版本说明",
                @"sub" : @"当前为测试版 v1.3.31",
                @"switch" : @NO,
            },
        ],
    ];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0:
            return @"功能开关";
        case 1:
            return @"添加好友";
        case 2:
            return @"关于";
        default:
            return nil;
    }
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        header.textLabel.textColor = HF_SUBTEXT_COLOR;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kHFCellReuseId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:kHFCellReuseId];
    }

    NSDictionary *item = self.sections[indexPath.section][indexPath.row];
    cell.textLabel.text = item[@"title"];
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.textColor = HF_TEXT_COLOR;
    cell.detailTextLabel.text = item[@"sub"];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = HF_SUBTEXT_COLOR;
    cell.backgroundColor = HF_CELL_COLOR;

    if ([item[@"switch"] boolValue]) {
        UISwitch *sw = [[UISwitch alloc] init];
        NSString *key = item[@"key"];
        sw.on = HFGetBool(key);
        sw.tag = indexPath.section * 100 + indexPath.row;
        [sw addTarget:self action:@selector(hf_switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (item[@"action"]) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = self.sections[indexPath.section][indexPath.row];
    NSString *action = item[@"action"];
    if ([action isEqualToString:@"openBlacklist"]) {
        HFBlacklistViewController *vc = [[HFBlacklistViewController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

#pragma mark - 交互

- (void)hf_switchChanged:(UISwitch *)sender {
    NSInteger row = sender.tag % 100;
    NSInteger section = sender.tag / 100;

    NSDictionary *item = self.sections[section][row];
    NSString *key = item[@"key"];
    if (!key) {
        return;
    }

    HFSetBool(key, sender.on);
    // 总开关联动黑名单开关（v1.3.31：只保留总开关，一并控制黑名单隐藏）
    if ([key isEqualToString:HF_KEY_HIDE_ALL_FRIENDS]) {
        HFSetBool(HF_KEY_BLACKLIST_ENABLED, sender.on);
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:HF_SETTINGS_DID_CHANGE_NOTIFICATION
                                                        object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:HF_BLACKLIST_CHANGED_NOTIFICATION
                                                        object:nil];
}

- (void)hf_closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
