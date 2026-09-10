#import "APPRootListController.h"

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
    pid_t pid = 0;
    const char *candidates[] = {
        "/var/jb/usr/bin/sbreload",
        "/usr/bin/sbreload",
        "/var/jb/usr/bin/killall",
        "/usr/bin/killall",
        NULL
    };
    for (int i = 0; candidates[i] != NULL; i++) {
        if (access(candidates[i], X_OK) != 0) {
            continue;
        }
        if (strstr(candidates[i], "sbreload") != NULL) {
            const char *args[] = {candidates[i], NULL};
            if (posix_spawn(&pid, candidates[i], NULL, NULL, (char *const *)args, environ) == 0) {
                return;
            }
        } else {
            const char *args[] = {candidates[i], "-9", "SpringBoard", NULL};
            if (posix_spawn(&pid, candidates[i], NULL, NULL, (char *const *)args, environ) == 0) {
                return;
            }
        }
    }
}

@end
