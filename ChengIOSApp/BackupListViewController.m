#import "BackupListViewController.h"
#import "../ChengIOSPrefs/ChengIOSBackup.h"
#import "../ChengIOSPrefs/ChengIOSProfiles.h"

@interface BackupListViewController ()
@property (nonatomic, copy) NSArray<NSDictionary *> *backups;
@property (nonatomic, strong) UIAlertController *busyAlert;
@end

@implementation BackupListViewController

static NSString *CIQuery(NSURL *url, NSString *name) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name caseInsensitiveCompare:name] == NSOrderedSame) {
            return item.value;
        }
    }
    return nil;
}

static BOOL CIFlag(NSURL *url, NSArray<NSString *> *names) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        for (NSString *name in names) {
            if ([item.name caseInsensitiveCompare:name] != NSOrderedSame) {
                continue;
            }
            if (item.value.length == 0 || [item.value isEqualToString:@"1"] ||
                [item.value caseInsensitiveCompare:@"true"] == NSOrderedSame ||
                [item.value caseInsensitiveCompare:@"yes"] == NSOrderedSame) {
                return YES;
            }
        }
    }
    return NO;
}

static NSString *CIToken(NSURL *url) {
    if (!url) {
        return @"";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (url.host.length > 0) {
        [parts addObject:url.host.lowercaseString];
    }
    for (NSString *piece in [url.path componentsSeparatedByString:@"/"]) {
        if (piece.length == 0 || [piece isEqualToString:@"x-callback-url"] || [piece isEqualToString:@"x-callback"]) {
            continue;
        }
        [parts addObject:piece.lowercaseString];
    }
    return [[parts componentsJoinedByString:@"-"] stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
}

static NSArray<NSString *> *CIBundlesFromQuery(NSURL *url) {
    NSString *raw = CIQuery(url, @"bundle") ?: CIQuery(url, @"app") ?: CIQuery(url, @"apps") ?: @"";
    if (raw.length == 0) {
        return @[];
    }
    NSArray *parts = [raw componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",+ "]];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) {
            [out addObject:part];
        }
    }
    return out;
}

static void CIPresent(UIViewController *host, NSString *title, NSString *message) {
    if (!host) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

static NSString *CIBytesString(unsigned long long bytes) {
    if (bytes < 1024) {
        return [NSString stringWithFormat:@"%llu B", bytes];
    }
    if (bytes < 1024ull * 1024ull) {
        return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
    }
    return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
}

static NSString *CIResultText(NSDictionary *meta, NSError *error, NSString *fallbackOK) {
    if (error) {
        return ChengIOSBackupErrorMessage(error);
    }
    NSMutableString *text = [NSMutableString string];
    [text appendString:fallbackOK];
    if ([meta[@"name"] length]) {
        [text appendFormat:@"\nTen: %@", meta[@"name"]];
    }
    if ([meta[@"id"] length]) {
        [text appendFormat:@"\nID: %@", meta[@"id"]];
    }
    if (meta[@"bytes"]) {
        [text appendFormat:@"\nData: %@", CIBytesString([meta[@"bytes"] unsignedLongLongValue])];
    }
    NSArray *bundles = meta[@"bundles"];
    if ([bundles isKindOfClass:[NSArray class]] && bundles.count > 0) {
        [text appendFormat:@"\nApp: %@", [bundles componentsJoinedByString:@", "]];
    }
    NSArray *failed = meta[@"failedBundles"];
    if ([failed isKindOfClass:[NSArray class]] && failed.count > 0) {
        [text appendFormat:@"\nBo qua: %@", [failed componentsJoinedByString:@", "]];
    }
    [text appendFormat:@"\nThu muc: %@", ChengIOSBackupRoot()];
    return text;
}

static void CIRunBusy(UIViewController *host, NSString *title, void (^work)(void (^done)(NSString *resultTitle, NSString *message))) {
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:title
                                                                  message:@"Giu app ChengIOS mo. Co the mat vai giay."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [host presentViewController:busy animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            work(^(NSString *resultTitle, NSString *message) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [busy dismissViewControllerAnimated:YES completion:^{
                        CIPresent(host, resultTitle, message);
                    }];
                });
            });
        });
    }];
}

void ChengIOSRunCreateBackup(UIViewController *host, NSString *name, BOOL includeAppData, BOOL silent) {
    void (^go)(void) = ^{
        CIRunBusy(host, includeAppData ? @"Dang backup ho so + data" : @"Dang backup ho so", ^(void (^done)(NSString *, NSString *)) {
            NSError *error = nil;
            NSArray *bundles = includeAppData ? ChengIOSUserSelectedBundleIDs() : @[];
            NSDictionary *meta = ChengIOSCreateBackup(name, bundles, includeAppData, &error);
            NSString *title = error ? @"Backup loi" : @"Da backup";
            done(title, CIResultText(meta, error, includeAppData ? @"Da luu ho so va data app (bo Caches/tmp)." : @"Da luu ho so ChengIOS."));
        });
    };
    if (silent) {
        go();
        return;
    }
    NSString *message = includeAppData
        ? @"Luu ho so hien tai va data app da chon (Documents, Preferences, Cookies; bo Caches). App se bi kill trong luc copy."
        : @"Luu ho so gia lap hien tai (model/iOS/GPS/Wi-Fi...).";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:includeAppData ? @"Backup ho so + data" : @"Backup ho so"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = name.length ? name : ChengIOSSuggestedBackupName();
        field.placeholder = @"Ten backup";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Backup" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSString *typed = alert.textFields.firstObject.text;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ChengIOSRunCreateBackup(host, typed, includeAppData, YES);
        });
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

void ChengIOSRunRestore(UIViewController *host, NSString *backupID, BOOL restoreProfile, BOOL restoreAppData, BOOL silent) {
    if (backupID.length == 0) {
        CIPresent(host, @"Restore loi", @"Thieu backup id.");
        return;
    }
    void (^go)(void) = ^{
        CIRunBusy(host, @"Dang restore", ^(void (^done)(NSString *, NSString *)) {
            NSError *error = nil;
            BOOL ok = ChengIOSRestoreBackup(backupID, restoreProfile, restoreAppData, &error);
            NSDictionary *meta = ChengIOSBackupInfo(backupID);
            NSString *msg = error ? ChengIOSBackupErrorMessage(error) : (ok ? @"Da restore. Force-quit app dich roi mo lai." : @"Restore that bai.");
            if (!error && [meta[@"name"] length]) {
                msg = [NSString stringWithFormat:@"%@\n%@", meta[@"name"], msg];
            }
            done(ok ? @"Da restore" : @"Restore loi", msg);
        });
    };
    if (silent) {
        go();
        return;
    }
    NSDictionary *meta = ChengIOSBackupInfo(backupID);
    NSString *message = [NSString stringWithFormat:@"%@\nProfile: %@\nData app: %@",
                         meta[@"name"] ?: backupID,
                         restoreProfile ? @"CO" : @"khong",
                         restoreAppData ? @"CO (ghi de sandbox)" : @"khong"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restore backup"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            go();
        });
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

void ChengIOSRunErase(UIViewController *host, NSArray<NSString *> *bundleIDs, BOOL silent) {
    NSArray *targets = bundleIDs.count ? bundleIDs : ChengIOSUserSelectedBundleIDs();
    void (^go)(void) = ^{
        CIRunBusy(host, @"Dang xoa data app", ^(void (^done)(NSString *, NSString *)) {
            NSError *error = nil;
            NSDictionary *result = ChengIOSEraseBundles(targets, &error);
            NSMutableString *msg = [NSMutableString string];
            NSArray *ok = result[@"ok"];
            NSArray *failed = result[@"failed"];
            NSArray *skipped = result[@"skipped"];
            if (ok.count) {
                [msg appendFormat:@"Da xoa: %@\n", [ok componentsJoinedByString:@", "]];
            }
            if (failed.count) {
                [msg appendFormat:@"Loi: %@\n", [failed componentsJoinedByString:@", "]];
            }
            if (skipped.count) {
                [msg appendFormat:@"Bo qua (Safari/he thong): %@\n", [skipped componentsJoinedByString:@", "]];
            }
            if (error && msg.length == 0) {
                [msg appendString:ChengIOSBackupErrorMessage(error)];
            }
            if (msg.length == 0) {
                [msg appendString:@"Khong xoa duoc app nao."];
            }
            [msg appendString:@"\nKhong xoa keychain iCloud. Mo lai app se nhu cai moi."];
            done(ok.count ? @"Da xoa data" : @"Xoa data", msg);
        });
    };
    if (silent) {
        go();
        return;
    }
    NSString *list = targets.count ? [targets componentsJoinedByString:@"\n"] : @"(khong co app user nao duoc chon)";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Xoa sach data app"
                                                                   message:[NSString stringWithFormat:@"Kill app roi xoa sandbox:\n%@\n\nKhong undo neu chua backup.", list]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Xoa" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            go();
        });
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

BOOL ChengIOSHandleBackupURL(NSURL *url, UIViewController *host) {
    if (!url || !host) {
        return NO;
    }
    NSString *token = CIToken(url);
    BOOL silent = CIFlag(url, @[@"silent", @"quiet", @"x-silent"]);
    NSString *name = CIQuery(url, @"name") ?: CIQuery(url, @"title") ?: CIQuery(url, @"label");
    BOOL wantData = CIFlag(url, @[@"data", @"appdata", @"apps", @"full"]);
    NSString *backupID = CIQuery(url, @"id") ?: CIQuery(url, @"backup") ?: CIQuery(url, @"backup-id");

    if ([token containsString:@"backup-apps"] || [token containsString:@"backup-data"] || [token containsString:@"backup-all"] || [token containsString:@"backup-now"]) {
        ChengIOSRunCreateBackup(host, name, YES, silent);
        return YES;
    }
    if ([token containsString:@"backup-profile"] || [token containsString:@"backup-info"] || [token containsString:@"backup-hoso"]) {
        ChengIOSRunCreateBackup(host, name, NO, silent);
        return YES;
    }
    if ([token isEqualToString:@"backup"] || [token isEqualToString:@"backups"] || [token containsString:@"backup-manager"] || [token containsString:@"quan-ly-backup"]) {
        if (![host isKindOfClass:[BackupListViewController class]]) {
            BackupListViewController *list = [[BackupListViewController alloc] initWithStyle:UITableViewStyleGrouped];
            [host.navigationController pushViewController:list animated:YES];
        }
        return YES;
    }
    if ([token containsString:@"restore-latest"] || [token isEqualToString:@"restorelatest"]) {
        NSString *latest = ChengIOSLatestBackupID();
        if (latest.length == 0) {
            CIPresent(host, @"Restore", @"Chua co backup.");
            return YES;
        }
        ChengIOSRunRestore(host, latest, YES, wantData, silent);
        return YES;
    }
    if ([token isEqualToString:@"restore"] || [token hasPrefix:@"restore-"]) {
        if (backupID.length == 0) {
            backupID = ChengIOSLatestBackupID();
        }
        BOOL noProfile = CIFlag(url, @[@"noprofile", @"profile-off"]);
        NSString *profileValue = CIQuery(url, @"profile");
        BOOL restoreProfile = !noProfile;
        if (profileValue.length && ([profileValue isEqualToString:@"0"] || [profileValue caseInsensitiveCompare:@"no"] == NSOrderedSame)) {
            restoreProfile = NO;
        }
        ChengIOSRunRestore(host, backupID, restoreProfile, wantData, silent);
        return YES;
    }
    if ([token containsString:@"erase-apps"] || [token containsString:@"wipe-apps"] || [token isEqualToString:@"wipe"] || [token isEqualToString:@"erase-all"] || [token isEqualToString:@"eraseall"]) {
        ChengIOSRunErase(host, CIBundlesFromQuery(url), silent);
        return YES;
    }
    if ([token isEqualToString:@"erase"] || [token isEqualToString:@"wipe-app"] || [token hasPrefix:@"erase-"]) {
        NSArray *bundles = CIBundlesFromQuery(url);
        ChengIOSRunErase(host, bundles, silent);
        return YES;
    }
    return NO;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Backup / Data";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                           target:self
                                                                                           action:@selector(reloadBackups)];
    [self reloadBackups];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadBackups];
}

- (void)reloadBackups {
    self.backups = ChengIOSListBackups();
    [self.tableView reloadData];
}

- (void)promptBackupIncludingAppData:(BOOL)includeAppData suggestedName:(NSString *)name silent:(BOOL)silent {
    ChengIOSRunCreateBackup(self, name, includeAppData, silent);
}

- (void)promptEraseBundles:(NSArray<NSString *> *)bundleIDs silent:(BOOL)silent {
    ChengIOSRunErase(self, bundleIDs, silent);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return 3;
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
        NSArray *apps = ChengIOSUserSelectedBundleIDs();
        NSString *list = apps.count ? [apps componentsJoinedByString:@", "] : @"chua chon app user nao";
        return [NSString stringWithFormat:@"App da chon (khong tinh Safari): %@.\nBackup data bo Caches/tmp. Xoa data khong dong keychain iCloud. Deeplink: chengios://backup-profile , chengios://backup-apps , chengios://restore-latest , chengios://erase-apps", list];
    }
    return [NSString stringWithFormat:@"Thu muc: %@", ChengIOSBackupRoot()];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"a"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"a"];
            cell.detailTextLabel.numberOfLines = 2;
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Backup ho so";
            cell.detailTextLabel.text = @"Chi identity ChengIOS (nho, nhanh)";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Backup ho so + data app";
            cell.detailTextLabel.text = @"Kem sandbox app da chon";
        } else {
            cell.textLabel.text = @"Xoa sach data app da chon";
            cell.detailTextLabel.text = @"Kill + xoa Documents/Library/group";
        }
        return cell;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"b"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"b"];
        cell.detailTextLabel.numberOfLines = 3;
        cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    }
    if (self.backups.count == 0) {
        cell.textLabel.text = @"Chua co backup";
        cell.detailTextLabel.text = @"Bam Backup ho so de tao.";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *item = self.backups[indexPath.row];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.text = item[@"name"] ?: item[@"id"];
    NSMutableString *detail = [NSMutableString string];
    if ([item[@"created"] length]) {
        [detail appendString:item[@"created"]];
    }
    NSArray *bundles = item[@"bundles"];
    if ([item[@"includeAppData"] boolValue] && [bundles isKindOfClass:[NSArray class]]) {
        [detail appendFormat:@"  ·  %lu app  ·  %@", (unsigned long)bundles.count, CIBytesString([item[@"bytes"] unsignedLongLongValue])];
    } else {
        [detail appendString:@"  ·  ho so"];
    }
    NSString *summary = item[@"profileSummary"];
    if ([summary isKindOfClass:[NSString class]] && summary.length > 0) {
        NSArray *lines = [summary componentsSeparatedByString:@"\n"];
        [detail appendFormat:@"\n%@", lines.firstObject];
    }
    cell.detailTextLabel.text = detail;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            ChengIOSRunCreateBackup(self, nil, NO, NO);
        } else if (indexPath.row == 1) {
            ChengIOSRunCreateBackup(self, nil, YES, NO);
        } else {
            ChengIOSRunErase(self, nil, NO);
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
        ChengIOSRunRestore(self, backupID, YES, NO, NO);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Restore ho so + data app" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        ChengIOSRunRestore(self, backupID, YES, YES, NO);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Chi restore data app" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        ChengIOSRunRestore(self, backupID, NO, YES, NO);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Doi ten" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        [self renameBackup:item];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Sao chep ID / path" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSString *text = [NSString stringWithFormat:@"%@\nchengios://restore?id=%@\n%@", item[@"name"], backupID, item[@"path"]];
        [UIPasteboard generalPasteboard].string = text;
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Xoa backup nay" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        NSError *error = nil;
        if (ChengIOSDeleteBackup(backupID, &error)) {
            [self reloadBackups];
        } else {
            CIPresent(self, @"Xoa backup loi", ChengIOSBackupErrorMessage(error));
        }
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Huy" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = tableView;
        pop.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    }
    [self presentViewController:sheet animated:YES completion:nil];
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
            CIPresent(self, @"Doi ten loi", ChengIOSBackupErrorMessage(error));
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    return indexPath.section == 1 && self.backups.count > 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (editingStyle != UITableViewCellEditingStyleDelete || self.backups.count == 0) {
        return;
    }
    NSString *backupID = self.backups[indexPath.row][@"id"];
    ChengIOSDeleteBackup(backupID, nil);
    [self reloadBackups];
}

@end
