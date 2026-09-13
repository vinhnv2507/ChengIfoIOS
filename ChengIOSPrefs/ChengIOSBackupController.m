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
    self.title = @"Danh sach backup";
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
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)MAX(self.backups.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return @"Danh sach backup";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return [NSString stringWithFormat:@"%@\nThao tac Backup/Xoa/Random o app ChengIOS. An 1 dong de restore/doi ten/xoa.", ChengIOSBackupRoot()];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
        cell.detailTextLabel.numberOfLines = 3;
    }
    if (self.backups.count == 0) {
        cell.textLabel.text = @"Chua co backup";
        cell.detailTextLabel.text = @"Tao backup tu app ChengIOS khi dang login.";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *item = self.backups[indexPath.row];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.text = item[@"name"] ?: item[@"id"];
    NSArray *bundles = item[@"bundles"];
    NSMutableString *detail = [NSMutableString string];
    [detail appendString:item[@"created"] ?: @""];
    if ([item[@"includeAppData"] boolValue]) {
        [detail appendFormat:@"  ·  %lu app", (unsigned long)[bundles count]];
        if (item[@"keychainItems"]) {
            [detail appendFormat:@"  ·  KC %@", item[@"keychainItems"]];
        }
        if (item[@"kcUid"]) {
            [detail appendFormat:@"  ·  kcUid %@", item[@"kcUid"]];
        }
    } else {
        [detail appendString:@"  ·  ho so"];
    }
    cell.detailTextLabel.text = detail;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
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
    [sheet addAction:[UIAlertAction actionWithTitle:@"Doi ten" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        [self renameBackup:item];
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

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return self.backups.count > 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (editingStyle != UITableViewCellEditingStyleDelete || self.backups.count == 0) {
        return;
    }
    ChengIOSDeleteBackup(self.backups[indexPath.row][@"id"], nil);
    [self reloadBackups];
}

- (void)renameBackup:(NSDictionary *)item {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Doi ten backup"
                                                                   message:item[@"id"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = item[@"name"];
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Luu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSError *error = nil;
        if (ChengIOSRenameBackup(item[@"id"], alert.textFields.firstObject.text, &error)) {
            [self reloadBackups];
        } else {
            [self alertTitle:@"Doi ten loi" message:ChengIOSBackupErrorMessage(error)];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
