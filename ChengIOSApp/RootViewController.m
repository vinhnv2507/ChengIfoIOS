#import "RootViewController.h"
#import "../ChengIOSPrefs/ChengIOSProfiles.h"

@interface RootViewController ()
@property (nonatomic, copy) NSString *summary;
@end

@implementation RootViewController

- (NSArray<NSString *> *)schemeExamples {
    return @[
        @"chengios://random-identity",
        @"chengios://random-all",
        @"chengios://profile",
        @"chengios://copy",
        @"chengios://settings",
        @"chengios://random-all?silent=1"
    ];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ChengIOS";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Refresh" style:UIBarButtonItemStylePlain target:self action:@selector(reloadProfile)];
    [self reloadProfile];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadProfile];
}

- (void)reloadProfile {
    self.summary = ChengIOSProfileSummary(ChengIOSLoadSavedProfile());
    if (self.summary.length == 0) {
        self.summary = @"Ch\u01b0a c\u00f3 h\u1ed3 s\u01a1. B\u1ea5m Random tr\u01b0\u1edbc.";
    }
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return 2;
    if (section == 1) return 2;
    if (section == 2) return (NSInteger)self.schemeExamples.count;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"Random";
    if (section == 1) return @"H\u1ed3 s\u01a1 hi\u1ec7n t\u1ea1i";
    if (section == 2) return @"Deeplink / Shortcuts";
    return @"Kh\u00e1c";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return @"Info M\u00e1y: ch\u1ec9 model, t\u00ean, hostname, iOS, build (kh\u1edbp 1 m\u00e1y th\u1eadt).\nTo\u00e0n B\u1ed9: th\u00eam locale, nh\u00e0 m\u1ea1ng, GPS, LAN, Wi-Fi SSID/BSSID/gateway v\u00e0 version app c\u00f9ng v\u00f9ng.";
    }
    if (section == 1) {
        return self.summary;
    }
    if (section == 2) {
        return @"Shortcuts: th\u00eam thao t\u00e1c M\u1edf URL. V\u00ed d\u1ee5 chengios://random-all?silent=1\nC\u0169ng d\u00f9ng chengios://x-callback-url/random-all?x-success=shortcuts://";
    }
    return @"Force-quit app \u0111\u00edch sau khi random. Kh\u00f4ng c\u1ea7n respring.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.textLabel.numberOfLines = 2;
        cell.detailTextLabel.numberOfLines = 2;
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.detailTextLabel.text = nil;
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Random Info M\u00e1y";
            cell.detailTextLabel.text = @"Ch\u1ec9 \u0111\u1ecbnh danh m\u00e1y";
        } else {
            cell.textLabel.text = @"Random To\u00e0n B\u1ed9";
            cell.detailTextLabel.text = @"M\u00e1y + locale + GPS + Wi-Fi";
        }
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Xem h\u1ed3 s\u01a1";
        } else {
            cell.textLabel.text = @"Sao ch\u00e9p h\u1ed3 s\u01a1";
        }
    } else if (indexPath.section == 2) {
        cell.textLabel.text = @"Sao ch\u00e9p URL";
        cell.detailTextLabel.text = self.schemeExamples[indexPath.row];
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        cell.textLabel.text = @"M\u1edf C\u00e0i \u0111\u1eb7t ChengIOS";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        [self runRandom:indexPath.row == 1 silent:NO];
        return;
    }
    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            [self showSummaryTitle:@"H\u1ed3 s\u01a1 hi\u1ec7n t\u1ea1i" profile:ChengIOSLoadSavedProfile()];
        } else {
            [self copySummary];
        }
        return;
    }
    if (indexPath.section == 2) {
        [UIPasteboard generalPasteboard].string = self.schemeExamples[indexPath.row];
        [self toast:@"\u0110\u00e3 sao ch\u00e9p URL"];
        return;
    }
    [self openSettings];
}

- (void)runRandom:(BOOL)full silent:(BOOL)silent {
    NSDictionary *profile = full ? ChengIOSRandomFullProfile() : ChengIOSRandomIdentity();
    ChengIOSApplyProfile(profile);
    [self reloadProfile];
    if (silent) {
        return;
    }
    [self showSummaryTitle:(full ? @"Random To\u00e0n B\u1ed9" : @"Random Info M\u00e1y") profile:profile];
}

- (void)showSummaryTitle:(NSString *)title profile:(NSDictionary *)profile {
    NSString *text = ChengIOSProfileSummary(profile);
    if (text.length == 0) {
        text = @"Ch\u01b0a c\u00f3 h\u1ed3 s\u01a1.";
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Sao ch\u00e9p" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        [UIPasteboard generalPasteboard].string = text;
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)copySummary {
    NSString *text = ChengIOSProfileSummary(ChengIOSLoadSavedProfile());
    if (text.length == 0) {
        [self toast:@"Ch\u01b0a c\u00f3 h\u1ed3 s\u01a1"];
        return;
    }
    [UIPasteboard generalPasteboard].string = text;
    [self toast:@"\u0110\u00e3 sao ch\u00e9p h\u1ed3 s\u01a1"];
}

- (void)toast:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

- (void)openSettings {
    NSArray<NSString *> *candidates = @[
        @"prefs:root=ChengIOS",
        @"App-prefs:root=ChengIOS",
        @"App-prefs:ChengIOS"
    ];
    for (NSString *raw in candidates) {
        NSURL *url = [NSURL URLWithString:raw];
        if (!url) {
            continue;
        }
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            return;
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if ([[UIApplication sharedApplication] openURL:url]) {
            return;
        }
#pragma clang diagnostic pop
    }
}

- (NSString *)tokenFromURL:(NSURL *)url {
    if (!url) {
        return @"";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (url.host.length > 0) {
        [parts addObject:url.host.lowercaseString];
    }
    for (NSString *piece in [url.path componentsSeparatedByString:@"/"]) {
        if (piece.length == 0) {
            continue;
        }
        [parts addObject:piece.lowercaseString];
    }
    NSMutableArray<NSString *> *filtered = [NSMutableArray array];
    for (NSString *part in parts) {
        if ([part isEqualToString:@"x-callback-url"] || [part isEqualToString:@"x-callback"]) {
            continue;
        }
        [filtered addObject:part];
    }
    return [[filtered componentsJoinedByString:@"-"] stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
}

- (BOOL)queryFlag:(NSURL *)url names:(NSArray<NSString *> *)names {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        for (NSString *name in names) {
            if ([item.name caseInsensitiveCompare:name] != NSOrderedSame) {
                continue;
            }
            if (item.value.length == 0 ||
                [item.value isEqualToString:@"1"] ||
                [item.value caseInsensitiveCompare:@"true"] == NSOrderedSame ||
                [item.value caseInsensitiveCompare:@"yes"] == NSOrderedSame) {
                return YES;
            }
        }
    }
    return NO;
}

- (NSString *)queryValue:(NSURL *)url name:(NSString *)name {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name caseInsensitiveCompare:name] == NSOrderedSame) {
            return item.value;
        }
    }
    return nil;
}

- (void)openCallback:(NSString *)raw {
    if (raw.length == 0) {
        return;
    }
    NSURL *url = [NSURL URLWithString:raw];
    if (!url) {
        return;
    }
    if (@available(iOS 10.0, *)) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [[UIApplication sharedApplication] openURL:url];
#pragma clang diagnostic pop
    }
}

- (BOOL)token:(NSString *)token hasAny:(NSArray<NSString *> *)names {
    for (NSString *name in names) {
        if ([token isEqualToString:name] || [token containsString:name]) {
            return YES;
        }
    }
    return NO;
}

- (void)handleURL:(NSURL *)url {
    if (!url) {
        return;
    }
    NSString *token = [self tokenFromURL:url];
    NSString *mode = [self queryValue:url name:@"mode"];
    BOOL silent = [self queryFlag:url names:@[@"silent", @"quiet", @"x-silent"]];
    BOOL did = NO;

    BOOL modeAll = [mode caseInsensitiveCompare:@"all"] == NSOrderedSame ||
                   [mode caseInsensitiveCompare:@"full"] == NSOrderedSame;
    BOOL modeIdentity = [mode caseInsensitiveCompare:@"identity"] == NSOrderedSame ||
                        [mode caseInsensitiveCompare:@"machine"] == NSOrderedSame ||
                        [mode caseInsensitiveCompare:@"info"] == NSOrderedSame;

    if (modeAll || [self token:token hasAny:@[@"random-all", @"randomall", @"toan-bo", @"toanbo", @"full"]]) {
        [self runRandom:YES silent:silent];
        did = YES;
    } else if ([token isEqualToString:@"random"] && !modeIdentity) {
        [self runRandom:YES silent:silent];
        did = YES;
    } else if (modeIdentity || [self token:token hasAny:@[@"random-identity", @"random-info", @"identity", @"info-may", @"infomay", @"machine"]]) {
        [self runRandom:NO silent:silent];
        did = YES;
    } else if ([self token:token hasAny:@[@"copy"]]) {
        [self copySummary];
        did = YES;
    } else if ([self token:token hasAny:@[@"profile", @"current", @"hoso", @"ho-so", @"info"]]) {
        [self showSummaryTitle:@"H\u1ed3 s\u01a1 hi\u1ec7n t\u1ea1i" profile:ChengIOSLoadSavedProfile()];
        did = YES;
    } else if ([self token:token hasAny:@[@"setting", @"prefs"]]) {
        [self openSettings];
        did = YES;
    }

    NSString *success = [self queryValue:url name:@"x-success"];
    if (did && success.length > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self openCallback:success];
        });
    }
}

@end
