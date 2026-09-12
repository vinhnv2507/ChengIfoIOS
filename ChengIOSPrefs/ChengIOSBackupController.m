#import "ChengIOSBackupController.h"
#import "ChengIOSBackup.h"
#import "ChengIOSProfiles.h"

#import <UIKit/UIKit.h>

@interface ChengIOSBackupController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy) NSArray<NSDictionary *> *backups;
@end

@implementation ChengIOSBackupController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Backup / Data";
    self.backups = @[];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = (id)self;
    self.tableView.delegate = (id)self;
    [self.view addSubview:self.tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadBackups];
}

- (void)reloadBackups {
    self.backups = ChengIOSListBackups();
    [self.tableView reloadData];
}

- (void)openURLString:(NSString *)string {
    NSURL *url = [NSURL URLWithString:string];
    if (!url) {
        return;
    }
    if (@available(iOS 10.0, *)) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)alertTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return 7;
    }
    return (NSInteger)MAX(self.backups.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? @"Thao tac" : @"Danh sach backup";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return @"Backup ho so chay trong Settings. Backup/xoa data, Safari, factory-like va xoa+random mo app ChengIOS.";
    }
    return ChengIOSBackupRoot();
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
        cell.detailTextLabel.numberOfLines = 3;
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    if (indexPath.section == 0) {
        NSArray *titles = @[
            @"Backup ho so hien tai",
            @"Backup ho so + data app (mo app)",
            @"Xoa sach data app da chon (mo app)",
            @"Xoa Safari (mo app)",
            @"Xoa toan bo app + Safari (mo app)",
            @"Xoa app + Random Toan Bo (mo app)",
            @"Mo Quan ly Backup (app)"
        ];
        NSArray *details = @[
            @"Luu identity vao Media/ChengIOS/Backups",
            @"chengios://backup-apps",
            @"chengios://erase-apps",
            @"chengios://erase-safari",
            @"chengios://erase-device",
            @"chengios://erase-random-all",
            @"chengios://backup"
        ];
        cell.textLabel.text = titles[indexPath.row];
        cell.detailTextLabel.text = details[indexPath.row];
        return cell;
    }
    if (self.backups.count == 0) {
        cell.textLabel.text = @"Chua co backup";
        cell.detailTextLabel.text = @"Tao backup ho so o tren.";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *item = self.backups[indexPath.row];
    cell.textLabel.text = item[@"name"] ?: item[@"id"];
    NSArray *bundles = item[@"bundles"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  ·  %@", item[@"created"] ?: @"", [item[@"includeAppData"] boolValue] ? [NSString stringWithFormat:@"%lu app", (unsigned long)[bundles count]] : @"ho so"];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            [self backupProfile];
        } else if (indexPath.row == 1) {
            [self openURLString:@"chengios://backup-apps"];
        } else if (indexPath.row == 2) {
            [self openURLString:@"chengios://erase-apps"];
        } else if (indexPath.row == 3) {
            [self openURLString:@"chengios://erase-safari"];
        } else if (indexPath.row == 4) {
            [self openURLString:@"chengios://erase-device"];
        } else if (indexPath.row == 5) {
            [self openURLString:@"chengios://erase-random-all"];
        } else {
            [self openURLString:@"chengios://backup"];
        }
        return;
    }
    if (self.backups.count == 0) {
        return;
    }
    NSDictionary *item = self.backups[indexPath.row];
    NSString *backupID = item[@"id"];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:item[@"name"] ?: backupID
                                                                   message:item[@"created"]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Restore ho so" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSError *error = nil;
        if (ChengIOSRestoreBackup(backupID, YES, NO, &error)) {
            [self alertTitle:@"Da restore ho so" message:@"Force-quit app dich roi mo lai."];
        } else {
            [self alertTitle:@"Restore loi" message:ChengIOSBackupErrorMessage(error)];
        }
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Restore ho so + data (mo app)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        [self openURLString:[NSString stringWithFormat:@"chengios://restore?id=%@&data=1", backupID]];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Xoa backup nay" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        ChengIOSDeleteBackup(backupID, nil);
        [self reloadBackups];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = tableView;
        pop.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)backupProfile {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Backup ho so"
                                                                   message:@"Luu identity ChengIOS hien tai."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = ChengIOSSuggestedBackupName();
        field.placeholder = @"Ten backup";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Backup" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSError *error = nil;
        NSDictionary *meta = ChengIOSCreateBackup(alert.textFields.firstObject.text, @[], NO, &error);
        if (meta && !error) {
            [self reloadBackups];
            [self alertTitle:@"Da backup" message:[NSString stringWithFormat:@"%@\nID: %@", meta[@"name"], meta[@"id"]]];
        } else {
            [self alertTitle:@"Backup loi" message:ChengIOSBackupErrorMessage(error)];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
