//
//  HFUserSelectViewController.m
//  HideFriends
//
//  v1.3.2 从已捕获用户中选择加入黑名单
//  数据源：HFBlacklist knownUsers（UID↔抖音号注册表）
//  点击行 → 将该用户的抖音号（uniqueID 优先 / shortID 次之）加入黑名单
//

#import "HFUserSelectViewController.h"
#import "HFBlacklist.h"
#import "HFConstants.h"

static NSString *const kUserCellId = @"HFUserSelectCell";

// v1.3.47 统一深灰主题（与设置页一致）
#define HF_BG_COLOR        [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0]
#define HF_CELL_COLOR      [UIColor colorWithRed:0.17 green:0.17 blue:0.18 alpha:1.0]
#define HF_TEXT_COLOR      [UIColor whiteColor]
#define HF_SUBTEXT_COLOR   [UIColor colorWithWhite:0.78 alpha:1.0]

@implementation HFUserSelectViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"选择互关好友";
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

    // 提示条：只展示互关好友（在「朋友-互关」列表里看到过的用户）
    UILabel *hint = [[UILabel alloc] init];
    hint.text = @"以下仅展示你的互关好友（在「朋友-互关」列表里浏览过的用户）。\n"
                @"点击即可加入隐藏列表，无需手动输入抖音号。";
    hint.numberOfLines = 0;
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = HF_SUBTEXT_COLOR;
    hint.frame = CGRectMake(16, 12, self.view.bounds.size.width - 32, 60);
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 84)];
    [header addSubview:hint];
    self.tableView.tableHeaderView = header;

    // v1.3.59：打开选择页时立即安装 hook + 扫描标记互关好友（兜底）。
    // 抖音的互关列表在插件页底层，扫描能遍历到底层可见 cell 并即时标记，
    // 避免「刚打开互关列表、hook 还没装上/还没滚动」导致列表为 0。
    dispatch_async(dispatch_get_main_queue(), ^{
        [HFBlacklist setupUserRegistry];
        [HFBlacklist scanAndHideVisibleCells];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self.tableView reloadData];
        });
    });
}

#pragma mark - 数据源

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [HFBlacklist mutualFollowUsers].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"互关好友 %lu 位", (unsigned long)[HFBlacklist mutualFollowUsers].count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kUserCellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:kUserCellId];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.textLabel.textColor = HF_TEXT_COLOR;
    cell.detailTextLabel.textColor = HF_SUBTEXT_COLOR;
    cell.backgroundColor = HF_CELL_COLOR;
    NSArray *users = [HFBlacklist mutualFollowUsers];
    if (indexPath.row >= (NSInteger)users.count) return cell;
    NSDictionary *u = users[indexPath.row];
    NSString *nick = u[@"nickname"] ?: @"";
    NSString *uniqueID = u[@"uniqueID"] ?: @"";
    NSString *shortID = u[@"shortID"] ?: @"";
    NSString *uid = u[@"uid"] ?: @"";
    cell.textLabel.text = nick.length > 0 ? nick : uid;
    NSString *dyId = uniqueID.length > 0 ? uniqueID : shortID;
    NSMutableString *sub = [NSMutableString stringWithFormat:@"UID: %@", uid];
    if (dyId.length > 0) {
        [sub appendFormat:@"  抖音号: %@", dyId];
    }
    // 已添加则标记
    if ([HFBlacklist blockedIDs].count > 0) {
        for (NSString *bid in [HFBlacklist blockedIDs]) {
            if ([bid isEqualToString:dyId]) {
                cell.textLabel.textColor = [UIColor systemGreenColor];
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@（已添加）", sub];
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
                return cell;
            }
        }
    }
    cell.detailTextLabel.text = sub;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

#pragma mark - 选择

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *users = [HFBlacklist mutualFollowUsers];
    if (indexPath.row >= (NSInteger)users.count) return;
    NSDictionary *u = users[indexPath.row];
    NSString *uniqueID = u[@"uniqueID"] ?: @"";
    NSString *shortID = u[@"shortID"] ?: @"";
    NSString *dyId = uniqueID.length > 0 ? uniqueID : shortID;
    if (dyId.length == 0) {
        // 无抖音号时用 UID 加入
        dyId = u[@"uid"] ?: @"";
    }
    [HFBlacklist addBlockedID:dyId];
    [HFBlacklist postBlacklistChangedNotification];
    [self.tableView reloadData];

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"已添加"
                         message:[NSString stringWithFormat:@"%@（%@）", u[@"nickname"], dyId]
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"继续选择" style:UIAlertActionStyleDefault handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"完成" style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction *_Nonnull action) {
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
