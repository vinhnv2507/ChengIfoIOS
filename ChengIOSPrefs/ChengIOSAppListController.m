#import "ChengIOSAppListController.h"

#import <notify.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

static NSString * const kPrefsID = @"com.vinhnv2507.chengiosprefs";
static NSString * const kEnabledKey = @"appEnabled";

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *bundleIdentifier;
- (id)localizedNameForContext:(id)context;
- (id)iconDataForVariant:(NSInteger)variant;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

@implementation ChengIOSAppListController {
    NSArray<LSApplicationProxy *> *_apps;
    NSMutableDictionary *_enabled;
    UITableView *_tableView;
}

- (NSString *)prefsPath {
    return [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", kPrefsID];
}

- (NSMutableDictionary *)loadPrefs {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:[self prefsPath]] ?: [NSMutableDictionary dictionary];
    id current = prefs[kEnabledKey];
    if (![current isKindOfClass:[NSDictionary class]]) {
        CFPropertyListRef cfValue = CFPreferencesCopyAppValue((__bridge CFStringRef)kEnabledKey, (__bridge CFStringRef)kPrefsID);
        if (cfValue) {
            current = (__bridge_transfer id)cfValue;
        }
    }
    _enabled = [current isKindOfClass:[NSDictionary class]] ? [current mutableCopy] : [NSMutableDictionary dictionary];
    return prefs;
}

- (void)saveEnabled {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:[self prefsPath]] ?: [NSMutableDictionary dictionary];
    prefs[kEnabledKey] = _enabled;
    [prefs writeToFile:[self prefsPath] atomically:YES];
    CFPreferencesSetAppValue((__bridge CFStringRef)kEnabledKey, (__bridge CFPropertyListRef)_enabled, (__bridge CFStringRef)kPrefsID);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsID);
    notify_post("com.vinhnv2507.chengiosprefs/changed");
    notify_post("com.vinhnv2507.chengiosprefs/ReloadPrefs");
}

- (void)loadApps {
    NSArray *allApps = [[objc_getClass("LSApplicationWorkspace") defaultWorkspace] allInstalledApplications];
    NSMutableArray *filtered = [NSMutableArray array];
    for (LSApplicationProxy *app in allApps) {
        NSString *bundleId = app.applicationIdentifier ?: app.bundleIdentifier;
        if (bundleId.length == 0 || [bundleId hasPrefix:@"com.apple."]) {
            continue;
        }
        [filtered addObject:app];
    }
    _apps = [filtered sortedArrayUsingComparator:^NSComparisonResult(LSApplicationProxy *a, LSApplicationProxy *b) {
        NSString *nameA = a.localizedName ?: a.applicationIdentifier;
        NSString *nameB = b.localizedName ?: b.applicationIdentifier;
        return [nameA localizedCaseInsensitiveCompare:nameB];
    }];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Change Apps";
    [self loadPrefs];
    [self loadApps];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = (id)self;
    _tableView.delegate = (id)self;
    [self.view addSubview:_tableView];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"app";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    }

    LSApplicationProxy *app = _apps[indexPath.row];
    NSString *bundleId = app.applicationIdentifier ?: app.bundleIdentifier;
    cell.textLabel.text = app.localizedName.length ? app.localizedName : bundleId;
    cell.detailTextLabel.text = bundleId;
    cell.accessoryType = [_enabled[bundleId] boolValue] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;

    UIImage *icon = nil;
    if ([app respondsToSelector:@selector(iconDataForVariant:)]) {
        NSData *data = [app iconDataForVariant:0];
        if ([data isKindOfClass:[NSData class]]) {
            icon = [UIImage imageWithData:data];
        }
    }
    cell.imageView.image = icon;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    LSApplicationProxy *app = _apps[indexPath.row];
    NSString *bundleId = app.applicationIdentifier ?: app.bundleIdentifier;
    BOOL enabled = [_enabled[bundleId] boolValue];
    _enabled[bundleId] = @(!enabled);
    [self saveEnabled];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
