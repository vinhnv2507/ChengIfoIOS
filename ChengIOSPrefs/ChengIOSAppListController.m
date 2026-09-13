#import "ChengIOSAppListController.h"
#import "ChengIOSProfiles.h"

#import <objc/runtime.h>
#import <UIKit/UIKit.h>

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
- (id)localizedNameForContext:(id)context;
- (id)iconDataForVariant:(NSInteger)variant;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

@implementation ChengIOSAppListController {
    NSArray<NSDictionary *> *_apps;
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
    _apps = [rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *nameA = a[@"name"] ?: a[@"bundleId"] ?: @"";
        NSString *nameB = b[@"name"] ?: b[@"bundleId"] ?: @"";
        NSComparisonResult cmp = [nameA localizedCaseInsensitiveCompare:nameB];
        if (cmp != NSOrderedSame) {
            return cmp;
        }
        return [a[@"bundleId"] compare:b[@"bundleId"]];
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
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)_apps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return @"Tick Safari / Facebook / Shopee / ADIA64. Force-quit app dich sau Random.";
}

- (NSDictionary *)rowAt:(NSIndexPath *)indexPath {
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)_apps.count) {
        return nil;
    }
    return _apps[indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"app";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    }

    NSDictionary *row = [self rowAt:indexPath];
    NSString *bundleId = row[@"bundleId"];
    cell.textLabel.text = row[@"name"] ?: bundleId;
    cell.detailTextLabel.text = bundleId;
    cell.accessoryType = [_enabled[bundleId] boolValue] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;

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
    BOOL enabled = [_enabled[bundleId] boolValue];
    _enabled[bundleId] = @(!enabled);
    [self saveEnabled];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
