#import "AppListViewController.h"
#import "../ChengIOSPrefs/ChengIOSProfiles.h"

#import <objc/runtime.h>

static NSString * const kSafariBundleID = @"com.apple.mobilesafari";

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *bundleIdentifier;
- (id)iconDataForVariant:(NSInteger)variant;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

@interface AppListViewController () <UISearchResultsUpdating>
@property (nonatomic, copy) NSArray<LSApplicationProxy *> *apps;
@property (nonatomic, copy) NSArray<LSApplicationProxy *> *visibleApps;
@property (nonatomic, strong) LSApplicationProxy *safariApp;
@property (nonatomic, strong) NSMutableDictionary *enabled;
@property (nonatomic, strong) UISearchController *search;
@end

@implementation AppListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Change Apps";
    id current = ChengIOSPrefValue(@"appEnabled");
    self.enabled = [current isKindOfClass:[NSDictionary class]] ? [current mutableCopy] : [NSMutableDictionary dictionary];
    [self loadApps];
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"Safari, Facebook, Shopee...";
    if (@available(iOS 11.0, *)) {
        self.navigationItem.searchController = self.search;
    }
    self.tableView.rowHeight = 52;
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

- (BOOL)isSearching {
    NSString *q = self.search.searchBar.text ?: @"";
    return q.length > 0;
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
    self.safariApp = safari;
    self.apps = [filtered sortedArrayUsingComparator:^NSComparisonResult(LSApplicationProxy *a, LSApplicationProxy *b) {
        NSString *idA = a.applicationIdentifier ?: a.bundleIdentifier ?: @"";
        NSString *idB = b.applicationIdentifier ?: b.bundleIdentifier ?: @"";
        NSString *nameA = a.localizedName ?: idA;
        NSString *nameB = b.localizedName ?: idB;
        return [nameA localizedCaseInsensitiveCompare:nameB];
    }];
    self.visibleApps = self.apps;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *q = searchController.searchBar.text.lowercaseString ?: @"";
    if (q.length == 0) {
        self.visibleApps = self.apps;
        [self.tableView reloadData];
        return;
    }
    NSMutableArray *rows = [NSMutableArray array];
    if (self.safariApp) {
        NSString *bundleId = (self.safariApp.applicationIdentifier ?: self.safariApp.bundleIdentifier).lowercaseString;
        NSString *name = self.safariApp.localizedName.lowercaseString ?: @"safari";
        if ([bundleId containsString:q] || [name containsString:q] || [@"safari" containsString:q]) {
            [rows addObject:self.safariApp];
        }
    } else if ([kSafariBundleID containsString:q] || [@"safari" containsString:q]) {
        // Keep a synthetic match by reloading section 0 only when not searching.
    }
    for (LSApplicationProxy *app in self.apps) {
        NSString *bundleId = (app.applicationIdentifier ?: app.bundleIdentifier).lowercaseString;
        NSString *name = app.localizedName.lowercaseString ?: @"";
        if ([bundleId containsString:q] || [name containsString:q]) {
            [rows addObject:app];
        }
    }
    self.visibleApps = rows;
    [self.tableView reloadData];
}

- (void)saveEnabled {
    ChengIOSSetPrefValue(@"appEnabled", self.enabled);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return [self isSearching] ? 1 : 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if ([self isSearching]) {
        NSInteger extra = 0;
        NSString *q = self.search.searchBar.text.lowercaseString ?: @"";
        if (!self.safariApp && ([@"safari" containsString:q] || [kSafariBundleID containsString:q] || [q containsString:@"safari"])) {
            extra = 1;
        }
        return (NSInteger)self.visibleApps.count + extra;
    }
    if (section == 0) {
        return 1;
    }
    return (NSInteger)self.visibleApps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if ([self isSearching]) {
        return nil;
    }
    return section == 0 ? @"Safari" : @"Apps";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if ([self isSearching]) {
        return nil;
    }
    if (section == 0) {
        return @"Safari lu\u00f4n \u1edf \u0111\u1ea7u danh s\u00e1ch, k\u1ec3 c\u1ea3 khi h\u1ec7 th\u1ed1ng \u1ea9n app.";
    }
    return @"Ch\u1ecdn app r\u1ed3i Random. Force-quit app \u0111\u00edch. Kh\u00f4ng ch\u1ecdn SpringBoard.";
}

- (NSString *)bundleIdForIndexPath:(NSIndexPath *)indexPath {
    if (![self isSearching] && indexPath.section == 0) {
        return kSafariBundleID;
    }
    if ([self isSearching] && !self.safariApp) {
        NSString *q = self.search.searchBar.text.lowercaseString ?: @"";
        BOOL wantSafari = [@"safari" containsString:q] || [kSafariBundleID containsString:q] || [q containsString:@"safari"];
        if (wantSafari && indexPath.row == 0) {
            return kSafariBundleID;
        }
        NSInteger row = wantSafari ? indexPath.row - 1 : indexPath.row;
        if (row >= 0 && row < (NSInteger)self.visibleApps.count) {
            LSApplicationProxy *app = self.visibleApps[row];
            return app.applicationIdentifier ?: app.bundleIdentifier;
        }
    }
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.visibleApps.count) {
        return kSafariBundleID;
    }
    LSApplicationProxy *app = self.visibleApps[indexPath.row];
    return app.applicationIdentifier ?: app.bundleIdentifier;
}

- (LSApplicationProxy *)proxyForIndexPath:(NSIndexPath *)indexPath {
    if (![self isSearching] && indexPath.section == 0) {
        return self.safariApp;
    }
    if ([self isSearching] && !self.safariApp) {
        NSString *q = self.search.searchBar.text.lowercaseString ?: @"";
        BOOL wantSafari = [q containsString:@"safari"] || [kSafariBundleID containsString:q];
        if (wantSafari && indexPath.row == 0) {
            return nil;
        }
        NSInteger row = wantSafari ? indexPath.row - 1 : indexPath.row;
        if (row >= 0 && row < (NSInteger)self.visibleApps.count) {
            return self.visibleApps[row];
        }
        return nil;
    }
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.visibleApps.count) {
        return nil;
    }
    return self.visibleApps[indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"app";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.detailTextLabel.numberOfLines = 1;
    }
    NSString *bundleId = [self bundleIdForIndexPath:indexPath];
    LSApplicationProxy *app = [self proxyForIndexPath:indexPath];
    NSString *name = app.localizedName.length ? app.localizedName : nil;
    if (name.length == 0 && [bundleId isEqualToString:kSafariBundleID]) {
        name = @"Safari";
    }
    cell.textLabel.text = name.length ? name : bundleId;
    cell.detailTextLabel.text = bundleId;
    cell.accessoryType = [self.enabled[bundleId] boolValue] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
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
    if (bundleId.length == 0) {
        return;
    }
    BOOL on = [self.enabled[bundleId] boolValue];
    self.enabled[bundleId] = @(!on);
    [self saveEnabled];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
