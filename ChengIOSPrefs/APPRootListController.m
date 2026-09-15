#import "APPRootListController.h"
#import "ChengIOSProfiles.h"
#import "ChengIOSBackup.h"

#import <notify.h>
#import <spawn.h>
#import <string.h>
#import <unistd.h>
#import <UIKit/UIKit.h>

static NSString * const kChengPrefsID = @"com.vinhnv2507.chengiosprefs";
static const char *kChengPrefsChanged = "com.vinhnv2507.chengiosprefs/changed";
static const char *kChengPrefsReload = "com.vinhnv2507.chengiosprefs/ReloadPrefs";
extern char **environ;

@implementation APPRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) {
        return [specifier propertyForKey:@"default"];
    }
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kChengPrefsID);
    if (value != NULL) {
        return (__bridge_transfer id)value;
    }
    return [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) {
        return;
    }
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)kChengPrefsID);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kChengPrefsID);
    notify_post(kChengPrefsChanged);
    notify_post(kChengPrefsReload);
}

- (void)refreshPrefs {
    [self reloadSpecifiers];
}

- (void)respring {
    if (![UIAlertController class]) {
        [self performRespring];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring"
                                                                   message:@"Khởi động lại SpringBoard để mọi app nạp lại ChengIOS."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        [self performRespring];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performRespring {
    ChengIOSRequestRespring();
}

- (void)chengApplyProfile:(NSDictionary *)profile {
    ChengIOSApplyProfile(profile);
    [self reloadSpecifiers];
}

- (void)chengShowProfile:(NSDictionary *)profile title:(NSString *)title full:(BOOL)full {
    NSString *summary = ChengIOSProfileSummary(profile);
    if (![UIAlertController class]) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:summary
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Random lại" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        if (full) {
            [self randomizeAll];
        } else {
            [self randomizeIdentity];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)chengApplyAndRespring:(NSDictionary *)profile title:(NSString *)title {
    [self chengApplyProfile:profile];
    NSString *summary = ChengIOSProfileSummary(profile);
    if (summary.length > 0) {
        [UIPasteboard generalPasteboard].string = summary;
    }
    if (![UIAlertController class]) {
        [self performRespring];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:@"Da copy ho so. Dang Respring..."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self performRespring];
        });
    }];
}

- (void)randomizeIdentity {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *profile = ChengIOSRandomIdentity();
        dispatch_async(dispatch_get_main_queue(), ^{
            [self chengApplyAndRespring:profile title:@"Random Info May"];
        });
    });
}

- (void)randomizeAll {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *profile = ChengIOSRandomFullProfile();
        dispatch_async(dispatch_get_main_queue(), ^{
            [self chengApplyAndRespring:profile title:@"Random Toan Bo"];
        });
    });
}


- (void)showCurrentInfo {
    NSDictionary *profile = ChengIOSLoadSavedProfile();
    NSString *summary = ChengIOSProfileSummary(profile);
    if (summary.length == 0 || [profile[@"spoofedModel"] length] == 0) {
        summary = @"Chưa có hồ sơ. Bấm Random Info Máy hoặc Random Toàn Bộ trước.";
    }
    if (![UIAlertController class]) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Hồ sơ hiện tại"
                                                                   message:summary
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Sao chép" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        [UIPasteboard generalPasteboard].string = summary;
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)copyCurrentInfo {
    NSString *summary = ChengIOSProfileSummary(ChengIOSLoadSavedProfile());
    if (summary.length == 0) {
        return;
    }
    [UIPasteboard generalPasteboard].string = summary;
    if (![UIAlertController class]) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Đã sao chép"
                                                                   message:summary
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}


@end
