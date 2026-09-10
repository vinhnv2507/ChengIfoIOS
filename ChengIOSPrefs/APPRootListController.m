#include "APPRootListController.h"
#import <Preferences/PSSpecifier.h>

@implementation APPRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	}

	return _specifiers;
}

@end

static NSString * const ChengIOSPrefsPath = @"/private/var/mobile/Library/Preferences/com.vinhnv2507.chengiosprefs.plist";

static NSMutableDictionary *ChengIOSLoadPrefs(void) {
	NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:ChengIOSPrefsPath];
	return stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

static void ChengIOSSavePrefs(NSDictionary *prefs) {
	[prefs writeToFile:ChengIOSPrefsPath atomically:YES];
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.vinhnv2507.chengiosprefs/changed"), NULL, NULL, true);
}

@implementation ChengIOSAppListController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Change Apps";
}

- (NSArray *)specifiers {
	if (!_specifiers) {
		NSMutableArray *items = [NSMutableArray array];
		NSMutableDictionary *apps = [NSMutableDictionary dictionary];
		NSArray *roots = @[@"/Applications", @"/var/containers/Bundle/Application"];
		NSFileManager *fm = [NSFileManager defaultManager];
		for (NSString *root in roots) {
			NSArray *entries = [fm subpathsAtPath:root];
			for (NSString *relative in entries) {
				if (![relative.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
				NSString *path = [root stringByAppendingPathComponent:relative];
				NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
				NSString *bundleID = info[@"CFBundleIdentifier"];
				if (bundleID.length == 0 || apps[bundleID]) continue;
				NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: bundleID;
				apps[bundleID] = name;
			}
		}
		NSArray *sortedIDs = [apps.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
			return [apps[a] localizedCaseInsensitiveCompare:apps[b]];
		}];
		for (NSString *bundleID in sortedIDs) {
			PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:apps[bundleID] target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
			[specifier setProperty:bundleID forKey:@"key"];
			[specifier setProperty:bundleID forKey:@"bundleIdentifier"];
			[items addObject:specifier];
		}
		_specifiers = items;
	}
	return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
	NSDictionary *prefs = ChengIOSLoadPrefs();
	NSDictionary *enabledApps = prefs[@"appEnabled"];
	NSString *key = [specifier propertyForKey:@"key"];
	return enabledApps[key] ?: @NO;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
	NSMutableDictionary *prefs = ChengIOSLoadPrefs();
	NSMutableDictionary *apps = [prefs[@"appEnabled"] mutableCopy] ?: [NSMutableDictionary dictionary];
	NSString *key = [specifier propertyForKey:@"key"];
	apps[key] = @([value boolValue]);
	prefs[@"appEnabled"] = apps;
	ChengIOSSavePrefs(prefs);
}
@end

@implementation ChengIOSChangeInfoController
- (NSArray *)specifiers {
	if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"ChangeInfo" target:self];
	return _specifiers;
}
- (void)resetInfo:(id)sender {
	NSMutableDictionary *prefs = ChengIOSLoadPrefs();
	for (NSString *key in @[@"spoofedModel", @"spoofedName", @"spoofedSystemVersion", @"spoofedBuild", @"spoofedHostname"]) [prefs removeObjectForKey:key];
	ChengIOSSavePrefs(prefs);
	[self reloadSpecifiers];
}
@end
