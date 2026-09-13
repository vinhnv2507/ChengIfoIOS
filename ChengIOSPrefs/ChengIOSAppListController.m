#import "ChengIOSAppListController.h"
#import "ChengIOSProfiles.h"

#import <objc/runtime.h>
#import <UIKit/UIKit.h>

static NSString * const kSafariBundleID = @"com.apple.mobilesafari";

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
    LSApplicationProxy *_safariApp;
    NSMutableDictionary *_enabled;
    UITableView *_tableView;
}

- (void)loadPrefs {
    id current = ChengIOSPrefValue(@"appEnabled");
    _enabled = [current isKindOfClass:[NSDictionary class]] ? [current mutableCopy] : [NSMutableDictionary dictionary];
}

- (void)saveEnabled {
    ChengIOSSetPrefValue(@"appEnabled", _enabled);
}

- (BOOL)keepBundle:(NSString *)bundleId {
    if (bundleId.length == 0) {
        return NO;
    }
    if ([bundleId isEqualToString:kSafariBundleID] ||
        [bundleId isEqualToString:@"com.apple.SafariViewService"] ||
        [bundleId isEqualToString:@"com.apple.webapp"]) {
        return YES;
    }
    if ([bundleId hasPrefix:@"com.apple."]) {
        return NO;
    }
    return YES;
}

- (void)loadApps {
    NSArray *allApps = [[objc_getClass("LSApplicationWorkspace") defaultWorkspace] allInstalledApplications];
    NSMutableArray *filtered = [NSMutableArray array];
    LSApplicationProxy *safari = nil;
    for (LSApplicationProxy *app in allApps) {
        NSString *bundleId = app.applicationIdentifier ?: app.bundleIdentifier;
        if (![self keepBundle:bundleId]) {
            continue;
        }
        if ([bundleId isEqualToString:kSafariBundleID]) {
            safari = app;
            continue;
        }
        [filtered addObject:app];
    }
    _safariApp = safari;
    _apps = [filtered sortedArrayUsingComparator:^NSComparisonResult(LSApplicationProxy *a, LSApplicationProxy *b) {
        NSString *idA = a.applicationIdentifier ?: a.bundleIdentifier ?: @"";
        NSString *idB = b.applicationIdentifier ?: b.bundleIdentifier ?: @"";
        NSString *nameA = a.localizedName ?: idA;
        NSString *nameB = b.localizedName ?: idB;
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return 1;
    }
    return (NSInteger)_apps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? @"Safari" : @"Apps";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return @"Safari lu\u00f4n \u1edf \u0111\u1ea7u danh s\u00e1ch.";
    }
    return @"Ch\u1ecdn Facebook/Shopee \u1edf \u0111\u00e2y. Force-quit app \u0111\u00edch sau Random.";
}

- (NSString *)bundleIdForIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        return kSafariBundleID;
    }
    LSApplicationProxy *app = _apps[indexPath.row];
    return app.applicationIdentifier ?: app.bundleIdentifier;
}

- (LSApplicationProxy *)proxyForIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        return _safariApp;
    }
    return _apps[indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"app";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    }

    NSString *bundleId = [self bundleIdForIndexPath:indexPath];
    LSApplicationProxy *app = [self proxyForIndexPath:indexPath];
    NSString *name = app.localizedName.length ? app.localizedName : nil;
    if (name.length == 0 && [bundleId isEqualToString:kSafariBundleID]) {
        name = @"Safari";
    }
    cell.textLabel.text = name.length ? name : bundleId;
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
    NSString *bundleId = [self bundleIdForIndexPath:indexPath];
    BOOL enabled = [_enabled[bundleId] boolValue];
    _enabled[bundleId] = @(!enabled);
    [self saveEnabled];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
