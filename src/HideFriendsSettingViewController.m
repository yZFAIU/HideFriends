//
//  HideFriendsSettingViewController.m
//
//  作者: yZFAIU
//  功能：
//   ① 隐藏好友开关
//   ② 是否隐藏插件（入口隐身）
//   ③ 需隐藏的好友（按 UID 增删）
//   ④ 修改密码
//

#import "HideFriends.h"
#import "HideFriendsSettingViewController.h"

@interface HideFriendsSettingViewController () <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tv;
@end

@implementation HideFriendsSettingViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"隐藏好友设置 · yZFAIU";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tv.delegate = self;
    self.tv.dataSource = self;
    [self.view addSubview:self.tv];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone
                                         target:self action:@selector(done)];
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return @"功能开关";
    if (s == 1) return @"需隐藏的好友（按 UID）";
    return @"安全";
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    HideFriendsManager *m = [HideFriendsManager shared];
    if (s == 0) return 2;
    if (s == 1) return m.hiddenUIDs.count + 1;   // +1 为“添加”行
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    HideFriendsManager *m = [HideFriendsManager shared];
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    c.textLabel.text = nil; c.detailTextLabel.text = nil;
    c.accessoryView = nil; c.accessoryType = UITableViewCellAccessoryNone;
    c.selectionStyle = UITableViewCellSelectionStyleDefault;

    if (ip.section == 0) {
        c.textLabel.text = (ip.row == 0) ? @"隐藏好友" : @"隐藏插件（入口隐身）";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = (ip.row == 0) ? m.hideEnabled : m.pluginHidden;
        sw.tag = ip.row;
        [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (ip.section == 1) {
        if (ip.row < m.hiddenUIDs.count) {
            c.textLabel.text = m.hiddenUIDs.allObjects[ip.row];
            c.detailTextLabel.text = @"左滑可删除";
        } else {
            c.textLabel.text = @"+ 添加好友 UID";
            c.textLabel.textColor = [UIColor systemBlueColor];
        }
    } else {
        c.textLabel.text = @"修改密码";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}

- (void)toggle:(UISwitch *)sw {
    HideFriendsManager *m = [HideFriendsManager shared];
    if (sw.tag == 0) {
        [m setHideEnabled:sw.on];
        HFShowToast(sw.on ? @"已开启隐藏" : @"已关闭隐藏");
    } else {
        [m setPluginHidden:sw.on];
        HFShowToast(sw.on ? @"插件已隐身（三指入口关闭，搜索栏输密码可恢复）" : @"插件已显示");
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    HideFriendsManager *m = [HideFriendsManager shared];
    if (ip.section == 1) {
        if (ip.row < m.hiddenUIDs.count) {
            [m removeHiddenUID:m.hiddenUIDs.allObjects[ip.row]];
            [tv reloadData];
        } else {
            [self showAddAlert];
        }
    } else if (ip.section == 2) {
        [self showChangePassword];
    }
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 1 && ip.row < [HideFriendsManager shared].hiddenUIDs.count;
}
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)ed forRowAtIndexPath:(NSIndexPath *)ip {
    if (ed == UITableViewCellEditingStyleDelete) {
        [[HideFriendsManager shared] removeHiddenUID:[[HideFriendsManager shared].hiddenUIDs.allObjects objectAtIndex:ip.row]];
        [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

#pragma mark - 添加 / 改密

- (void)showAddAlert {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"添加隐藏好友"
                                                             message:@"输入该好友的 UID（数字 UID 或 sec_uid 均可）"
                                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){ t.placeholder = @"UID"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *ac){
        NSString *uid = a.textFields.firstObject.text ?: @"";
        if (uid.length) {
            [[HideFriendsManager shared] addHiddenUID:uid];
            [self.tv reloadData];
            HFShowToast(@"已添加");
        }
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)showChangePassword {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"修改密码" message:nil
                                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){ t.secureTextEntry = YES; t.placeholder = @"原密码"; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){ t.secureTextEntry = YES; t.placeholder = @"新密码"; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){ t.secureTextEntry = YES; t.placeholder = @"再次输入"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *ac){
        HideFriendsManager *m = [HideFriendsManager shared];
        NSString *old = a.textFields[0].text ?: @"";
        NSString *n1 = a.textFields[1].text ?: @"";
        NSString *n2 = a.textFields[2].text ?: @"";
        if (![m verifyPassword:old]) { HFShowToast(@"原密码错误"); return; }
        if (n1.length < 1 || ![n1 isEqualToString:n2]) { HFShowToast(@"新密码无效或不一致"); return; }
        [m setPassword:n1];
        HFShowToast(@"密码已修改");
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
