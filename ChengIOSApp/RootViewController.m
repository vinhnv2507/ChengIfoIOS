#import "RootViewController.h"
#import "AppListViewController.h"
#import "DeeplinkListViewController.h"
#import "RegionListViewController.h"
#import "BackupListViewController.h"
#import "../ChengIOSPrefs/ChengIOSProfiles.h"

#import <spawn.h>
#import <unistd.h>
#import <string.h>

extern char **environ;

@interface RootViewController () <UITextFieldDelegate>
@property (nonatomic, copy) NSArray<NSArray<NSDictionary *> *> *schema;
@property (nonatomic, copy) NSString *summary;
@end

@implementation RootViewController

- (NSArray<NSString *> *)schemeExamples {
    return @[
        @"chengios://random-identity",
        @"chengios://random-all",
        @"chengios://apps",
        @"chengios://profile",
        @"chengios://copy",
        @"chengios://settings",
        @"chengios://random-all?silent=1",
        @"chengios://erase-safari",
        @"chengios://erase-device",
        @"chengios://erase-random-all",
        @"chengios://erase-device-random"
    ];
}

- (NSArray<NSArray<NSDictionary *> *> *)buildSchema {
    return @[
        @[
            @{@"kind": @"switch", @"title": @"B\u1eadt ChengIOS", @"key": @"masterEnabled", @"defaultOn": @YES},
            @{@"kind": @"switch", @"title": @"Spoof s\u00e2u (Gestalt / Darwin)", @"key": @"gestaltEnabled", @"defaultOn": @NO, @"detail": @"FB/Shopee b\u1ecf qua Gestalt; app th\u01b0\u1eddng m\u1edbi d\u00f9ng Darwin. Force-quit app \u0111\u00edch"}
        ],
        @[
            @{@"kind": @"nav", @"title": @"Change Apps", @"detail": @"C\u00f3 Safari \u1edf \u0111\u1ea7u danh s\u00e1ch"}
        ],
        @[
            @{@"kind": @"button", @"title": @"Random Info M\u00e1y", @"action": @"identity"},
            @{@"kind": @"button", @"title": @"Random To\u00e0n B\u1ed9", @"action": @"full"},
            @{@"kind": @"button", @"title": @"Xem h\u1ed3 s\u01a1", @"action": @"profile"},
            @{@"kind": @"button", @"title": @"Sao ch\u00e9p h\u1ed3 s\u01a1", @"action": @"copy"},
            @{@"kind": @"nav", @"title": @"Random theo vùng", @"page": @"region", @"detail": @"VN / US / KR / JP..."},
            @{@"kind": @"nav", @"title": @"Deeplink / Shortcuts", @"page": @"deeplink", @"detail": @"chengios://"}
        ],
        @[
            @{@"kind": @"nav", @"title": @"Quan ly Backup", @"page": @"backup", @"detail": @"Backup / Restore / Xoa data"},
            @{@"kind": @"button", @"title": @"Backup ho so", @"action": @"backupProfile"},
            @{@"kind": @"button", @"title": @"Backup ho so + data app", @"action": @"backupApps"},
            @{@"kind": @"button", @"title": @"Xoa sach data app da chon", @"action": @"eraseApps"},
            @{@"kind": @"button", @"title": @"Xoa sach Safari", @"action": @"eraseSafari"},
            @{@"kind": @"button", @"title": @"Xoa toan bo app + Safari", @"action": @"eraseDevice"},
            @{@"kind": @"button", @"title": @"Xoa app da chon + Random Toan Bo", @"action": @"eraseRandomAll"},
            @{@"kind": @"button", @"title": @"Xoa toan bo + Random Toan Bo", @"action": @"eraseDeviceRandom"}
        ],
        @[
            @{@"kind": @"text", @"title": @"Model", @"keys": @[@"spoofedModel", @"customDeviceModel"], @"placeholder": @"iPhone16,2"},
            @{@"kind": @"text", @"title": @"T\u00ean", @"keys": @[@"spoofedName", @"customDeviceName"], @"placeholder": @"iPhone"},
            @{@"kind": @"text", @"title": @"iOS", @"keys": @[@"spoofedSystemVersion", @"customOSVersion"], @"placeholder": @"18.6.1"},
            @{@"kind": @"text", @"title": @"Build", @"keys": @[@"spoofedBuild", @"customBuildNumber"], @"placeholder": @"22G100"},
            @{@"kind": @"text", @"title": @"Hostname", @"keys": @[@"spoofedHostname", @"customHostName"], @"placeholder": @"iPhone.local"},
            @{@"kind": @"info", @"title": @"User-Agent", @"keys": @[@"spoofedUserAgent"]},
        ],
        @[
            @{@"kind": @"switch", @"title": @"D\u00f9ng iOS t\u00f9y ch\u1ec9nh", @"key": @"useCustomOSVersion", @"defaultOn": @NO},
            @{@"kind": @"text", @"title": @"Custom Version", @"keys": @[@"customOSVersion", @"spoofedSystemVersion"], @"placeholder": @"18.6.1"},
            @{@"kind": @"text", @"title": @"Custom Build", @"keys": @[@"customBuildNumber", @"spoofedBuild"], @"placeholder": @"22G100"}
        ],
        @[
            @{@"kind": @"switch", @"title": @"Gi\u1ea3 l\u1eadp version App", @"key": @"appVersionEnabled", @"defaultOn": @NO},
            @{@"kind": @"text", @"title": @"App Version", @"keys": @[@"customAppVersion"], @"placeholder": @"3.2.1"}
        ],
        @[
            @{@"kind": @"switch", @"title": @"Gi\u1ea3 l\u1eadp t\u00ean / hostname / ID", @"key": @"deviceIdentityEnabled", @"defaultOn": @NO}
        ],
        @[
            @{@"kind": @"switch", @"title": @"Gi\u1ea3 l\u1eadp locale", @"key": @"localeEnabled", @"defaultOn": @NO},
            @{@"kind": @"text", @"title": @"Locale", @"keys": @[@"localeIdentifier"], @"placeholder": @"vi_VN"},
            @{@"kind": @"text", @"title": @"Time Zone", @"keys": @[@"timeZoneName"], @"placeholder": @"Asia/Ho_Chi_Minh"}
        ],
        @[
            @{@"kind": @"switch", @"title": @"Gi\u1ea3 l\u1eadp nh\u00e0 m\u1ea1ng", @"key": @"carrierEnabled", @"defaultOn": @NO},
            @{@"kind": @"text", @"title": @"Carrier", @"keys": @[@"carrierName"], @"placeholder": @"Viettel"},
            @{@"kind": @"text", @"title": @"MCC", @"keys": @[@"mobileCountryCode"], @"placeholder": @"452"},
            @{@"kind": @"text", @"title": @"MNC", @"keys": @[@"mobileNetworkCode"], @"placeholder": @"04"},
            @{@"kind": @"text", @"title": @"ISO", @"keys": @[@"isoCountryCode"], @"placeholder": @"vn"}
        ],
        @[
            @{@"kind": @"switch", @"title": @"Gi\u1ea3 l\u1eadp v\u1ecb tr\u00ed", @"key": @"locationEnabled", @"defaultOn": @NO},
            @{@"kind": @"text", @"title": @"Latitude", @"keys": @[@"latitude"], @"placeholder": @"10.762"},
            @{@"kind": @"text", @"title": @"Longitude", @"keys": @[@"longitude"], @"placeholder": @"106.660"},
            @{@"kind": @"text", @"title": @"Altitude", @"keys": @[@"altitude"], @"placeholder": @"10"},
            @{@"kind": @"text", @"title": @"Accuracy", @"keys": @[@"accuracy"], @"placeholder": @"12"},
            @{@"kind": @"text", @"title": @"GPX Path", @"keys": @[@"gpxPath"], @"placeholder": @"/var/mobile/Media/ChengIOS/route.gpx"}
        ],
        @[
            @{@"kind": @"switch", @"title": @"Gi\u1ea3 l\u1eadp m\u1ea1ng / Wi-Fi", @"key": @"networkEnabled", @"defaultOn": @NO},
            @{@"kind": @"text", @"title": @"Interface", @"keys": @[@"interfaceName"], @"placeholder": @"en0"},
            @{@"kind": @"text", @"title": @"IPv4", @"keys": @[@"ipv4Address"], @"placeholder": @"192.168.1.20"},
            @{@"kind": @"text", @"title": @"IPv6", @"keys": @[@"ipv6Address"], @"placeholder": @"2001:db8::1"},
            @{@"kind": @"text", @"title": @"MAC", @"keys": @[@"macAddress", @"wifiAddress"], @"placeholder": @"02:00:00:00:00:01"},
            @{@"kind": @"text", @"title": @"SSID", @"keys": @[@"wifiSSID"], @"placeholder": @"Viettel-5G"},
            @{@"kind": @"text", @"title": @"BSSID", @"keys": @[@"wifiBSSID"], @"placeholder": @"50:c7:bf:12:34:56"},
            @{@"kind": @"text", @"title": @"Gateway", @"keys": @[@"wifiGateway"], @"placeholder": @"192.168.1.1"},
            @{@"kind": @"text", @"title": @"RSSI", @"keys": @[@"wifiRSSI"], @"placeholder": @"-52"}
        ],
        @[
            @{@"kind": @"text", @"title": @"Board", @"keys": @[@"hwModelStr"], @"placeholder": @"D84AP"},
            @{@"kind": @"text", @"title": @"Chip", @"keys": @[@"hardwarePlatform"], @"placeholder": @"t8130"},
            @{@"kind": @"text", @"title": @"Serial", @"keys": @[@"spoofedSerialNumber"], @"placeholder": @"C02XXXXXX"},
            @{@"kind": @"text", @"title": @"UDID", @"keys": @[@"spoofedUniqueDeviceID"], @"placeholder": @"40-hex"},
            @{@"kind": @"text", @"title": @"IDFV", @"keys": @[@"spoofedVendorUUID"], @"placeholder": @"UUID"},
            @{@"kind": @"text", @"title": @"IMEI", @"keys": @[@"spoofedIMEI"], @"placeholder": @"15 digits"},
            @{@"kind": @"text", @"title": @"Wi-Fi MAC", @"keys": @[@"wifiAddress"], @"placeholder": @"02:00:00:00:00:01"},
            @{@"kind": @"text", @"title": @"BT MAC", @"keys": @[@"bluetoothAddress"], @"placeholder": @"02:00:00:00:00:02"}
        ],

        @[
            @{@"kind": @"button", @"title": @"M\u1edf C\u00e0i \u0111\u1eb7t ChengIOS", @"action": @"settings"},
        ]
    ];
}

- (void)viewDidLoad {
    self.schema = [self buildSchema];
    [super viewDidLoad];
    self.title = @"ChengIOS";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Respring" style:UIBarButtonItemStylePlain target:self action:@selector(respring)];
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

- (NSDictionary *)rowAt:(NSIndexPath *)indexPath {
    return self.schema[indexPath.section][indexPath.row];
}

- (NSString *)firstText:(NSArray *)keys {
    for (NSString *key in keys) {
        id value = ChengIOSPrefValue(key);
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return value;
        }
        if ([value isKindOfClass:[NSNumber class]]) {
            return [value stringValue];
        }
    }
    return @"";
}

- (BOOL)boolKey:(NSString *)key defaultOn:(BOOL)defaultOn {
    id value = ChengIOSPrefValue(key);
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) {
        return [value boolValue];
    }
    return defaultOn;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return (NSInteger)self.schema.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return (NSInteger)self.schema[section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    NSArray *titles = @[
        @"Chung", @"Apps", @"Random", @"Backup / Data", @"Change Info", @"Phi\u00ean b\u1ea3n iOS", @"Phi\u00ean b\u1ea3n App",
        @"\u0110\u1ecbnh danh", @"Locale", @"Nh\u00e0 m\u1ea1ng", @"V\u1ecb tr\u00ed", @"M\u1ea1ng / Wi-Fi",
        @"Gestalt / ID", @"Kh\u00e1c"
    ];
    return titles[section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return @"Safari: tick Safari, vuot tat han roi mo lai tab. Facebook/Shopee van che do an toan.";
    }
    if (section == 2) {
        return @"Info May: model/ten/iOS. Toan Bo + Random theo vung: locale/GPS/Wi-Fi/IPv6 theo US/KR/JP...";
    }
    if (section == 3) {
        return @"Backup data gom sandbox + keychain de restore con login. Xoa Facebook xoa SSO/keychain. Co nut xoa Safari va xoa toan bo app user.";
    }
    if (section == 10) {
        return @"deviceinfo.me Region/City/ISP la IP cong cong that (Viettel/Hung Yen). Bam nut Detect de dung GPS gia lap.";
    }
    if (section == 12) {
        return self.summary;
    }
    if (section == 13) {
        return @"Force-quit app dich sau Random. Respring o goc tren trai, Refresh o goc tren phai.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = [self rowAt:indexPath];
    NSString *kind = row[@"kind"];
    if ([kind isEqualToString:@"switch"]) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"sw"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"sw"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.detailTextLabel.numberOfLines = 2;
        }
        cell.textLabel.text = row[@"title"];
        cell.detailTextLabel.text = row[@"detail"];
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = [self boolKey:row[@"key"] defaultOn:[row[@"defaultOn"] boolValue]];
        toggle.tag = indexPath.section * 100 + indexPath.row;
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        return cell;
    }
    if ([kind isEqualToString:@"text"]) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"tx"];
        UITextField *field = nil;
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"tx"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            field = [[UITextField alloc] initWithFrame:CGRectZero];
            field.tag = 50;
            field.textAlignment = NSTextAlignmentRight;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
            field.delegate = self;
            [field addTarget:self action:@selector(textChanged:) forControlEvents:UIControlEventEditingDidEnd];
            [cell.contentView addSubview:field];
        } else {
            field = [cell.contentView viewWithTag:50];
        }
        cell.textLabel.text = row[@"title"];
        field.placeholder = row[@"placeholder"];
        field.text = [self firstText:row[@"keys"]];
        field.accessibilityIdentifier = [row[@"keys"] componentsJoinedByString:@","];
        field.frame = CGRectMake(140, 8, cell.contentView.bounds.size.width - 156, 28);
        field.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        cell.accessoryView = nil;
        return cell;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"bt"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"bt"];
        cell.textLabel.numberOfLines = 2;
        cell.detailTextLabel.numberOfLines = 2;
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = row[@"detail"] ?: row[@"url"];
    if ([kind isEqualToString:@"info"]) {
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.detailTextLabel.text = [self firstText:row[@"keys"]] ?: @"\u2014";
    } else if ([kind isEqualToString:@"copy"]) {
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)toggleChanged:(UISwitch *)toggle {
    NSInteger section = toggle.tag / 100;
    NSInteger row = toggle.tag % 100;
    NSDictionary *item = self.schema[section][row];
    ChengIOSSetPrefValue(item[@"key"], @(toggle.on));
}

- (void)textChanged:(UITextField *)field {
    NSArray *keys = [field.accessibilityIdentifier componentsSeparatedByString:@","];
    NSString *text = field.text ?: @"";
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    for (NSString *key in keys) {
        if (key.length > 0) {
            payload[key] = text;
        }
    }
    if (payload.count > 0) {
        ChengIOSApplyProfile(payload);
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = [self rowAt:indexPath];
    NSString *kind = row[@"kind"];
    if ([kind isEqualToString:@"nav"]) {
        NSString *page = row[@"page"];
        UIViewController *next = nil;
        if ([page isEqualToString:@"deeplink"]) {
            next = [[DeeplinkListViewController alloc] initWithStyle:UITableViewStyleGrouped];
        } else if ([page isEqualToString:@"region"]) {
            next = [[RegionListViewController alloc] initWithStyle:UITableViewStyleGrouped];
        } else if ([page isEqualToString:@"backup"]) {
            next = [[BackupListViewController alloc] initWithStyle:UITableViewStyleGrouped];
        } else {
            next = [[AppListViewController alloc] initWithStyle:UITableViewStyleGrouped];
        }
        [self.navigationController pushViewController:next animated:YES];
        return;
    }
    if ([kind isEqualToString:@"copy"]) {
        [UIPasteboard generalPasteboard].string = row[@"url"];
        [self toast:@"\u0110\u00e3 sao ch\u00e9p URL"];
        return;
    }
    if ([kind isEqualToString:@"info"]) {
        NSString *text = [self firstText:row[@"keys"]];
        if (text.length > 0) {
            [UIPasteboard generalPasteboard].string = text;
            [self toast:@"\u0110\u00e3 sao ch\u00e9p"];
        }
        return;
    }
    if (![kind isEqualToString:@"button"]) {
        return;
    }
    NSString *action = row[@"action"];
    if ([action isEqualToString:@"identity"]) {
        [self runRandom:NO silent:NO];
    } else if ([action isEqualToString:@"full"]) {
        [self runRandom:YES silent:NO];
    } else if ([action isEqualToString:@"profile"]) {
        [self showSummaryTitle:@"H\u1ed3 s\u01a1 hi\u1ec7n t\u1ea1i" profile:ChengIOSLoadSavedProfile()];
    } else if ([action isEqualToString:@"copy"]) {
        [self copySummary];
    } else if ([action isEqualToString:@"settings"]) {
        [self openSettings];
    } else if ([action isEqualToString:@"respring"]) {
        [self respring];
    } else if ([action isEqualToString:@"backupProfile"]) {
        ChengIOSHandleBackupURL([NSURL URLWithString:@"chengios://backup-profile"], self);
    } else if ([action isEqualToString:@"backupApps"]) {
        ChengIOSHandleBackupURL([NSURL URLWithString:@"chengios://backup-apps"], self);
    } else if ([action isEqualToString:@"eraseApps"]) {
        ChengIOSHandleBackupURL([NSURL URLWithString:@"chengios://erase-apps"], self);
    } else if ([action isEqualToString:@"eraseSafari"]) {
        ChengIOSHandleBackupURL([NSURL URLWithString:@"chengios://erase-safari"], self);
    } else if ([action isEqualToString:@"eraseDevice"]) {
        ChengIOSHandleBackupURL([NSURL URLWithString:@"chengios://erase-device"], self);
    } else if ([action isEqualToString:@"eraseRandomAll"]) {
        ChengIOSHandleBackupURL([NSURL URLWithString:@"chengios://erase-random-all"], self);
    } else if ([action isEqualToString:@"eraseDeviceRandom"]) {
        ChengIOSHandleBackupURL([NSURL URLWithString:@"chengios://erase-device-random"], self);
    }
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
    NSArray<NSString *> *candidates = @[@"prefs:root=ChengIOS", @"App-prefs:root=ChengIOS", @"App-prefs:ChengIOS"];
    for (NSString *raw in candidates) {
        NSURL *url = [NSURL URLWithString:raw];
        if (!url) continue;
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            return;
        }
    }
}

- (void)respring {
    pid_t pid = 0;
    const char *candidates[] = {
        "/var/jb/usr/bin/sbreload", "/usr/bin/sbreload",
        "/var/jb/usr/bin/killall", "/usr/bin/killall", NULL
    };
    for (int i = 0; candidates[i] != NULL; i++) {
        if (access(candidates[i], X_OK) != 0) continue;
        if (strstr(candidates[i], "sbreload") != NULL) {
            const char *args[] = {candidates[i], NULL};
            if (posix_spawn(&pid, candidates[i], NULL, NULL, (char *const *)args, environ) == 0) return;
        } else {
            const char *args[] = {candidates[i], "-9", "SpringBoard", NULL};
            if (posix_spawn(&pid, candidates[i], NULL, NULL, (char *const *)args, environ) == 0) return;
        }
    }
}

- (NSString *)tokenFromURL:(NSURL *)url {
    if (!url) return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (url.host.length > 0) [parts addObject:url.host.lowercaseString];
    for (NSString *piece in [url.path componentsSeparatedByString:@"/"]) {
        if (piece.length == 0) continue;
        [parts addObject:piece.lowercaseString];
    }
    NSMutableArray<NSString *> *filtered = [NSMutableArray array];
    for (NSString *part in parts) {
        if ([part isEqualToString:@"x-callback-url"] || [part isEqualToString:@"x-callback"]) continue;
        [filtered addObject:part];
    }
    return [[filtered componentsJoinedByString:@"-"] stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
}

- (BOOL)queryFlag:(NSURL *)url names:(NSArray<NSString *> *)names {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        for (NSString *name in names) {
            if ([item.name caseInsensitiveCompare:name] != NSOrderedSame) continue;
            if (item.value.length == 0 || [item.value isEqualToString:@"1"] ||
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
        if ([item.name caseInsensitiveCompare:name] == NSOrderedSame) return item.value;
    }
    return nil;
}

- (void)openCallback:(NSString *)raw {
    if (raw.length == 0) return;
    NSURL *url = [NSURL URLWithString:raw];
    if (!url) return;
    if (@available(iOS 10.0, *)) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (BOOL)token:(NSString *)token hasAny:(NSArray<NSString *> *)names {
    for (NSString *name in names) {
        if ([token isEqualToString:name] || [token containsString:name]) return YES;
    }
    return NO;
}

- (void)handleURL:(NSURL *)url {
    if (!url) return;
    NSString *token = [self tokenFromURL:url];
    NSString *mode = [self queryValue:url name:@"mode"];
    BOOL silent = [self queryFlag:url names:@[@"silent", @"quiet", @"x-silent"]];
    BOOL did = NO;
    if (ChengIOSHandleBackupURL(url, self.navigationController.topViewController ?: self)) {
        did = YES;
    } else {
    BOOL modeAll = [mode caseInsensitiveCompare:@"all"] == NSOrderedSame || [mode caseInsensitiveCompare:@"full"] == NSOrderedSame;
    BOOL modeIdentity = [mode caseInsensitiveCompare:@"identity"] == NSOrderedSame || [mode caseInsensitiveCompare:@"machine"] == NSOrderedSame || [mode caseInsensitiveCompare:@"info"] == NSOrderedSame;
    if (modeAll || [self token:token hasAny:@[@"random-all", @"randomall", @"toan-bo", @"toanbo", @"full"]]) {
        NSString *region = [self queryValue:url name:@"region"] ?: [self queryValue:url name:@"iso"];
        if (region.length > 0) {
            NSDictionary *profile = ChengIOSRandomFullProfileInRegion(region);
            ChengIOSApplyProfile(profile);
            [self reloadProfile];
            if (!silent) {
                [self showSummaryTitle:[NSString stringWithFormat:@"Random %@", region.uppercaseString] profile:profile];
            }
        } else {
            [self runRandom:YES silent:silent];
        }
        did = YES;
    } else if ([token isEqualToString:@"random"] && !modeIdentity) {
        [self runRandom:YES silent:silent]; did = YES;
    } else if (modeIdentity || [self token:token hasAny:@[@"random-identity", @"random-info", @"identity", @"info-may", @"infomay", @"machine"]]) {
        [self runRandom:NO silent:silent]; did = YES;
    } else if ([self token:token hasAny:@[@"copy"]]) {
        [self copySummary]; did = YES;
    } else if ([self token:token hasAny:@[@"profile", @"current", @"hoso", @"ho-so", @"info"]]) {
        [self showSummaryTitle:@"H\u1ed3 s\u01a1 hi\u1ec7n t\u1ea1i" profile:ChengIOSLoadSavedProfile()]; did = YES;
    } else if ([self token:token hasAny:@[@"apps", @"change-apps", @"applist", @"safari"]]) {
        AppListViewController *list = [[AppListViewController alloc] initWithStyle:UITableViewStyleGrouped];
        [self.navigationController pushViewController:list animated:YES];
        did = YES;
    } else if ([self token:token hasAny:@[@"regions", @"region", @"vung", @"vung-mien"]]) {
        RegionListViewController *list = [[RegionListViewController alloc] initWithStyle:UITableViewStyleGrouped];
        [self.navigationController pushViewController:list animated:YES];
        did = YES;
    } else if ([self token:token hasAny:@[@"deeplink", @"deeplinks", @"urls", @"shortcuts"]]) {
        DeeplinkListViewController *list = [[DeeplinkListViewController alloc] initWithStyle:UITableViewStyleGrouped];
        [self.navigationController pushViewController:list animated:YES];
        did = YES;
    } else if ([self token:token hasAny:@[@"setting", @"prefs"]]) {
        [self openSettings]; did = YES;
    } else if ([self token:token hasAny:@[@"respring", @"sbreload", @"ldrestart"]]) {
        [self respring]; did = YES;
    }
    }
    NSString *success = [self queryValue:url name:@"x-success"];
    if (did && success.length > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self openCallback:success];
        });
    }
}

@end
