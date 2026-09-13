#import "AppListViewController.h"
#import "../ChengIOSPrefs/ChengIOSProfiles.h"

#import <objc/runtime.h>

static NSArray<NSString *> *CISafariFamilyIDs(void) {
    return @[
        @"com.apple.mobilesafari",
        @"com.apple.SafariViewService",
        @"com.apple.webapp"
    ];
}

static NSString *CISafariFamilyName(NSString *bundleId) {
    if ([bundleId isEqualToString:@"com.apple.mobilesafari"]) {
        return @"Safari";
    }
    if ([bundleId isEqualToString:@"com.apple.SafariViewService"]) {
        return @"Safari View Service";
    }
    if ([bundleId isEqualToString:@"com.apple.webapp"]) {
        return @"Web App";
    }
    return nil;
}

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
@property (nonatomic, copy) NSArray<NSDictionary *> *apps;
@property (nonatomic, copy) NSArray<NSDictionary *> *visibleApps;
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
    if ([CISafariFamilyIDs() containsObject:bundleId]) {
        return YES;
    }
    if ([bundleId hasPrefix:@"com.apple."]) {
        return NO;
    }
    return YES;
}

- (void)loadApps {
    NSArray *allApps = [[objc_getClass("LSApplicationWorkspace") defaultWorkspace] allInstalledApplications];
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (LSApplicationProxy *app in allApps) {
        NSString *bundleId = app.applicationIdentifier ?: app.bundleIdentifier;
        if (![self keepBundle:bundleId] || [seen containsObject:bundleId]) {
            continue;
        }
        [seen addObject:bundleId];
        NSString *name = app.localizedName.length ? app.localizedName : CISafariFamilyName(bundleId);
        [rows addObject:@{
            @"bundleId": bundleId ?: @"",
            @"name": name.length ? name : (bundleId ?: @""),
            @"proxy": app
        }];
    }
    for (NSString *bundleId in CISafariFamilyIDs()) {
        if ([seen containsObject:bundleId]) {
            continue;
        }
        [seen addObject:bundleId];
        NSString *name = CISafariFamilyName(bundleId) ?: bundleId;
        [rows addObject:@{
            @"bundleId": bundleId,
            @"name": name
        }];
    }
    self.apps = [rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *nameA = a[@"name"] ?: a[@"bundleId"] ?: @"";
        NSString *nameB = b[@"name"] ?: b[@"bundleId"] ?: @"";
        NSComparisonResult cmp = [nameA localizedCaseInsensitiveCompare:nameB];
        if (cmp != NSOrderedSame) {
            return cmp;
        }
        return [a[@"bundleId"] compare:b[@"bundleId"]];
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
    for (NSDictionary *row in self.apps) {
        NSString *bundleId = [row[@"bundleId"] lowercaseString] ?: @"";
        NSString *name = [row[@"name"] lowercaseString] ?: @"";
        if ([bundleId containsString:q] || [name containsString:q]) {
            [rows addObject:row];
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
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)self.visibleApps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return @"Tick Safari / Facebook / Shopee / ADIA64 trong danh sach nay. Force-quit app dich sau Random. Khong chon SpringBoard.";
}

- (NSDictionary *)rowAt:(NSIndexPath *)indexPath {
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
    NSDictionary *row = [self rowAt:indexPath];
    NSString *bundleId = row[@"bundleId"];
    cell.textLabel.text = row[@"name"] ?: bundleId;
    cell.detailTextLabel.text = bundleId;
    cell.accessoryType = [self.enabled[bundleId] boolValue] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    UIImage *icon = nil;
    LSApplicationProxy *app = row[@"proxy"];
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
    NSString *bundleId = [self rowAt:indexPath][@"bundleId"];
    if (bundleId.length == 0) {
        return;
    }
    BOOL on = [self.enabled[bundleId] boolValue];
    self.enabled[bundleId] = @(!on);
    [self saveEnabled];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
