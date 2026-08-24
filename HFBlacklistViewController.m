//
//  HFBlacklistViewController.m
//  HideFriends
//
//  黑名单管理：增删对方抖音号
//  - 第 0 行：启用/停用黑名单总开关
//  - 第 1 节：已添加的抖音号列表（左滑删除，右上角"+"添加）
//

#import "HFBlacklistViewController.h"
#import "HFBlacklist.h"
#import "HFConstants.h"
#import "HFUserSelectViewController.h"

static NSString *const kCellId = @"HFBlacklistCell";

// v1.3.47 统一深灰主题（与设置页一致）
#define HF_BG_COLOR        [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0]
#define HF_CELL_COLOR      [UIColor colorWithRed:0.17 green:0.17 blue:0.18 alpha:1.0]
#define HF_TEXT_COLOR      [UIColor whiteColor]
#define HF_SUBTEXT_COLOR   [UIColor colorWithWhite:0.78 alpha:1.0]

@interface HFBlacklistViewController ()
@property(nonatomic, strong) NSMutableArray<NSString *> *items;
@end

@implementation HFBlacklistViewController

#pragma mark - 生命周期

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"添加好友";
        _items = [[HFBlacklist blockedIDs] mutableCopy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // v1.3.47 统一深灰主题
    self.view.backgroundColor = HF_BG_COLOR;
    self.tableView.backgroundColor = HF_BG_COLOR;
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = HF_BG_COLOR;
    appearance.titleTextAttributes = @{ NSForegroundColorAttributeName: HF_TEXT_COLOR };
    self.navigationController.navigationBar.standardAppearance = appearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
    self.navigationController.navigationBar.tintColor = HF_TEXT_COLOR;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(hf_addTapped)];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(hf_blacklistChanged)
                                                 name:HF_BLACKLIST_CHANGED_NOTIFICATION
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)hf_blacklistChanged {
    self.items = [[HFBlacklist blockedIDs] mutableCopy];
    [self.tableView reloadData];
}

#pragma mark - 添加

- (void)hf_addTapped {
    // v1.3.47：两种添加方式——从互关好友选择 / 手动输入
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"添加好友"
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"从互关好友选择" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_Nonnull action) {
        HFUserSelectViewController *vc = [[HFUserSelectViewController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"手动输入" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_Nonnull action) {
        [self hf_promptManualInput];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)hf_promptManualInput {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"添加好友"
                         message:@"输入对方的抖音号（短码）。支持抖音号、UID、昵称任一匹配。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"如：douyin123 或昵称";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_Nonnull action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        UITextField *tf = alert.textFields.firstObject;
        NSString *text = [tf.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length == 0) {
            [self hf_showAlert:@"不能为空"];
            return;
        }
        [HFBlacklist addBlockedID:text];
        [HFBlacklist postBlacklistChangedNotification];
        [self hf_showAlert:[NSString stringWithFormat:@"已添加：%@", text]];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)hf_showAlert:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:msg
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX((NSInteger)self.items.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.items.count == 0) return @"好友（空）";
    return [NSString stringWithFormat:@"已添加（%lu 人）", (unsigned long)self.items.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"匹配规则：依次对比对方的抖音号、UID、昵称包含。\n"
               @"在推荐流、关注列表、私信会话等任意位置匹配到即自动隐藏。\n"
               @"左滑可删除；右上角 ➕ 可添加。";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:kCellId];
    }
    cell.textLabel.textColor = HF_TEXT_COLOR;
    cell.detailTextLabel.textColor = HF_SUBTEXT_COLOR;
    cell.backgroundColor = HF_CELL_COLOR;
    if (self.items.count == 0) {
        cell.textLabel.text = @"点击右上角 ➕ 添加第一个";
        cell.detailTextLabel.text = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    cell.textLabel.text = self.items[indexPath.row];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"匹配维度：抖音号 / UID / 昵称"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

#pragma mark - 左滑删除

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.items.count > 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    return @"移除";
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.row >= (NSInteger)self.items.count) return;

    NSString *removed = self.items[indexPath.row];
    [HFBlacklist removeBlockedID:removed];
    [HFBlacklist postBlacklistChangedNotification];
    // 通知会自动 reload（监听器中实现）
}

@end
