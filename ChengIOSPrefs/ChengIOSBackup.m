#import "ChengIOSBackup.h"
#import "ChengIOSProfiles.h"

#import <objc/runtime.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static NSString * const kChengBackupErrorDomain = @"com.vinhnv2507.chengios.backup";

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *bundleExecutable;
@property (nonatomic, readonly) NSURL *dataContainerURL;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly) NSDictionary *groupContainerURLs;
@property (nonatomic, readonly) NSDictionary *entitlements;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)terminateApplication:(NSString *)bundleIdentifier withOptions:(id)options;
- (NSArray *)allInstalledApplications;
@end

static NSError *CIError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kChengBackupErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Error"}];
}

NSString *ChengIOSBackupErrorMessage(NSError *error) {
    if (!error) {
        return @"";
    }
    return error.localizedDescription ?: @"Error";
}

static NSString *CIFirstExistingDir(NSArray<NSString *> *candidates, BOOL create) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in candidates) {
        BOOL dir = NO;
        if ([fm fileExistsAtPath:path isDirectory:&dir] && dir) {
            return path;
        }
    }
    if (!create) {
        return candidates.firstObject;
    }
    for (NSString *path in candidates) {
        NSString *parent = [path stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:parent]) {
            continue;
        }
        NSError *err = nil;
        if ([fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&err] ||
            ([fm fileExistsAtPath:path])) {
            return path;
        }
    }
    NSString *fallback = candidates.lastObject ?: @"/var/mobile/Documents/ChengIOS";
    [fm createDirectoryAtPath:fallback withIntermediateDirectories:YES attributes:nil error:nil];
    return fallback;
}

NSString *ChengIOSBackupRoot(void) {
    static NSString *root;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        root = CIFirstExistingDir(@[
            @"/var/mobile/Media/ChengIOS/Backups",
            @"/private/var/mobile/Media/ChengIOS/Backups",
            @"/var/mobile/Documents/ChengIOS/Backups",
            @"/var/jb/var/mobile/Documents/ChengIOS/Backups"
        ], YES);
    });
    return root;
}

static NSString *CISanitizeName(NSString *name) {
    NSString *raw = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw.length == 0) {
        return @"";
    }
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length && out.length < 64; i++) {
        unichar c = [raw characterAtIndex:i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == ' ') {
            [out appendFormat:@"%C", c];
        } else if (c == '/' || c == '\\' || c == ':') {
            [out appendString:@"-"];
        }
    }
    while ([out hasPrefix:@"."]) {
        [out deleteCharactersInRange:NSMakeRange(0, 1)];
    }
    return out;
}

static NSString *CINewBackupID(void) {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    NSString *path = [[ChengIOSBackupRoot() stringByAppendingPathComponent:stamp] stringByAppendingPathComponent:@"meta.plist"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return stamp;
    }
    return [NSString stringWithFormat:@"%@-%u", stamp, arc4random_uniform(900) + 100];
}

NSString *ChengIOSSuggestedBackupName(void) {
    NSDictionary *profile = ChengIOSLoadSavedProfile();
    NSString *product = profile[@"_product"] ?: profile[@"spoofedModel"] ?: @"iPhone";
    NSString *iso = [profile[@"isoCountryCode"] uppercaseString] ?: @"";
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"MM-dd HH:mm";
    NSString *when = [fmt stringFromDate:[NSDate date]];
    if (iso.length > 0) {
        return [NSString stringWithFormat:@"%@ %@ %@", when, product, iso];
    }
    return [NSString stringWithFormat:@"%@ %@", when, product];
}

BOOL ChengIOSBundleIsProtected(NSString *bundleID) {
    if (bundleID.length == 0) {
        return YES;
    }
    NSString *low = bundleID.lowercaseString;
    NSArray<NSString *> *blocked = @[
        @"com.apple.springboard",
        @"com.apple.preferences",
        @"com.apple.backboardd",
        @"com.apple.mobilesafari",
        @"com.apple.safariviewservice",
        @"com.apple.webapp",
        @"com.apple.webkit",
        @"com.vinhnv2507.chengios.app",
        @"com.saurik.cydia",
        @"org.coolstar.sileo",
        @"xyz.willy.zebra",
        @"com.tigisoftware.filza",
        @"com.opa334.altlist"
    ];
    if ([blocked containsObject:low]) {
        return YES;
    }
    if ([low hasPrefix:@"com.apple."]) {
        return YES;
    }
    if ([low hasPrefix:@"com.vinhnv2507.chengios"]) {
        return YES;
    }
    return NO;
}

NSArray<NSString *> *ChengIOSSelectedBundleIDs(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    id enabled = ChengIOSPrefValue(@"appEnabled");
    if ([enabled isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in enabled) {
            if (![key isKindOfClass:[NSString class]] || key.length == 0) {
                continue;
            }
            if ([enabled[key] boolValue] && ![seen containsObject:key]) {
                [out addObject:key];
                [seen addObject:key];
            }
        }
    }
    id spoofed = ChengIOSPrefValue(@"spoofedApps");
    if ([spoofed isKindOfClass:[NSArray class]]) {
        for (id item in spoofed) {
            if (![item isKindOfClass:[NSString class]] || [item length] == 0) {
                continue;
            }
            if (![seen containsObject:item]) {
                [out addObject:item];
                [seen addObject:item];
            }
        }
    }
    [out sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return out;
}

NSArray<NSString *> *ChengIOSUserSelectedBundleIDs(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *bundle in ChengIOSSelectedBundleIDs()) {
        if (!ChengIOSBundleIsProtected(bundle)) {
            [out addObject:bundle];
        }
    }
    return out;
}

static LSApplicationProxy *CIProxy(NSString *bundleID) {
    if (bundleID.length == 0) {
        return nil;
    }
    Class cls = objc_getClass("LSApplicationProxy");
    if (!cls || ![cls respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
        return nil;
    }
    LSApplicationProxy *proxy = [cls applicationProxyForIdentifier:bundleID];
    NSString *ident = proxy.applicationIdentifier ?: proxy.bundleIdentifier;
    if (ident.length == 0) {
        return nil;
    }
    return proxy;
}

static NSString *CIScanContainer(NSArray<NSString *> *roots, NSString *identifier) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in roots) {
        NSArray<NSString *> *uuids = [fm contentsOfDirectoryAtPath:root error:nil];
        for (NSString *uuid in uuids) {
            if (uuid.length < 30) {
                continue;
            }
            NSString *dir = [root stringByAppendingPathComponent:uuid];
            NSString *metaPath = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
            NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
            NSString *found = meta[@"MCMMetadataIdentifier"];
            if (found.length == 0) {
                id info = meta[@"MCMMetadataInfo"];
                if ([info isKindOfClass:[NSDictionary class]]) {
                    found = info[@"MCMMetadataIdentifier"];
                }
            }
            if ([found isEqualToString:identifier]) {
                return dir;
            }
        }
    }
    return nil;
}

static NSString *CIDataPath(NSString *bundleID) {
    LSApplicationProxy *proxy = CIProxy(bundleID);
    NSString *path = proxy.dataContainerURL.path;
    BOOL dir = NO;
    if (path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir] && dir) {
        return path;
    }
    return CIScanContainer(@[
        @"/var/mobile/Containers/Data/Application",
        @"/private/var/mobile/Containers/Data/Application"
    ], bundleID);
}

static NSDictionary<NSString *, NSString *> *CIGroupPaths(NSString *bundleID) {
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    LSApplicationProxy *proxy = CIProxy(bundleID);
    NSDictionary *urls = nil;
    if ([proxy respondsToSelector:@selector(groupContainerURLs)]) {
        urls = proxy.groupContainerURLs;
    }
    [urls enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        (void)stop;
        NSString *group = [key isKindOfClass:[NSString class]] ? key : nil;
        NSString *path = nil;
        if ([obj isKindOfClass:[NSURL class]]) {
            path = [(NSURL *)obj path];
        } else if ([obj isKindOfClass:[NSString class]]) {
            path = obj;
        }
        if (group.length > 0 && path.length > 0) {
            map[group] = path;
        }
    }];
    if (map.count == 0) {
        NSArray *groups = nil;
        id ents = nil;
        if ([proxy respondsToSelector:@selector(entitlements)]) {
            ents = proxy.entitlements;
        }
        if ([ents isKindOfClass:[NSDictionary class]]) {
            groups = ents[@"com.apple.security.application-groups"];
        }
        if ([groups isKindOfClass:[NSArray class]]) {
            for (id group in groups) {
                if (![group isKindOfClass:[NSString class]]) {
                    continue;
                }
                NSString *path = CIScanContainer(@[
                    @"/var/mobile/Containers/Shared/AppGroup",
                    @"/private/var/mobile/Containers/Shared/AppGroup"
                ], group);
                if (path.length > 0) {
                    map[group] = path;
                }
            }
        }
    }
    return map;
}

static BOOL CIShouldSkipName(NSString *name) {
    if (name.length == 0) {
        return YES;
    }
    if ([name isEqualToString:@".com.apple.mobile_container_manager.metadata.plist"]) {
        return YES;
    }
    NSString *low = name.lowercaseString;
    NSArray<NSString *> *skip = @[
        @"caches", @"tmp", @"temp", @"temporaryitems", @"networkcache",
        @"gpucache", @"fscacheddata", @"logs", @"log", @"crashreporter",
        @"webkitcache", @"cache.db", @"cache.db-shm", @"cache.db-wal"
    ];
    if ([skip containsObject:low]) {
        return YES;
    }
    if ([low hasSuffix:@".log"] || [low hasSuffix:@".tmp"]) {
        return YES;
    }
    return NO;
}

static BOOL CIPathSafeToMutate(NSString *path) {
    if (path.length < 28) {
        return NO;
    }
    NSString *low = path.lowercaseString;
    if ([low containsString:@"/chengios/backups"]) {
        return NO;
    }
    NSArray<NSString *> *parts = path.pathComponents;
    if ([low containsString:@"/containers/data/application/"] && parts.count >= 7) {
        return YES;
    }
    if ([low containsString:@"/containers/shared/appgroup/"] && parts.count >= 7) {
        return YES;
    }
    if ([low containsString:@"/library/caches/"] && parts.count >= 6) {
        return YES;
    }
    if ([low containsString:@"/library/splashboard/snapshots/"] && parts.count >= 6) {
        return YES;
    }
    if ([low containsString:@"/library/preferences/"] && [low hasSuffix:@".plist"]) {
        return YES;
    }
    return NO;
}

static unsigned long long CICopyTree(NSString *from, NSString *to) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL dir = NO;
    if (![fm fileExistsAtPath:from isDirectory:&dir]) {
        return 0;
    }
    if (!dir) {
        NSString *parent = [to stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
        [fm removeItemAtPath:to error:nil];
        if ([fm copyItemAtPath:from toPath:to error:nil]) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:to error:nil];
            return [attrs[NSFileSize] unsignedLongLongValue];
        }
        return 0;
    }
    [fm createDirectoryAtPath:to withIntermediateDirectories:YES attributes:nil error:nil];
    unsigned long long total = 0;
    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:from error:nil];
    for (NSString *name in children) {
        if (CIShouldSkipName(name)) {
            continue;
        }
        total += CICopyTree([from stringByAppendingPathComponent:name], [to stringByAppendingPathComponent:name]);
    }
    return total;
}

static BOOL CIWipeContents(NSString *path) {
    if (!CIPathSafeToMutate(path)) {
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL dir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&dir]) {
        return YES;
    }
    if (!dir) {
        return [fm removeItemAtPath:path error:nil];
    }
    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:path error:nil];
    BOOL ok = YES;
    for (NSString *name in children) {
        if ([name hasPrefix:@".com.apple.mobile_container_manager"]) {
            continue;
        }
        NSString *child = [path stringByAppendingPathComponent:name];
        if (![fm removeItemAtPath:child error:nil]) {
            ok = NO;
        }
    }
    return ok;
}

static void CIRunKillall(NSString *processName) {
    if (processName.length == 0 || [processName containsString:@"/"]) {
        return;
    }
    pid_t pid = 0;
    const char *bins[] = {
        "/var/jb/usr/bin/killall",
        "/usr/bin/killall",
        "/var/jb/bin/killall",
        "/usr/bin/killall",
        NULL
    };
    for (int i = 0; bins[i]; i++) {
        if (access(bins[i], X_OK) != 0) {
            continue;
        }
        const char *args[] = {bins[i], "-9", processName.UTF8String, NULL};
        if (posix_spawn(&pid, bins[i], NULL, NULL, (char *const *)args, environ) == 0) {
            int status = 0;
            waitpid(pid, &status, 0);
            return;
        }
    }
}

static void CITerminateBundle(NSString *bundleID) {
    if (bundleID.length == 0) {
        return;
    }
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    id ws = [wsClass respondsToSelector:@selector(defaultWorkspace)] ? [wsClass defaultWorkspace] : nil;
    if ([ws respondsToSelector:@selector(terminateApplication:withOptions:)]) {
        (void)[ws terminateApplication:bundleID withOptions:nil];
    }
    LSApplicationProxy *proxy = CIProxy(bundleID);
    NSString *exec = nil;
    if ([proxy respondsToSelector:@selector(bundleExecutable)]) {
        exec = proxy.bundleExecutable;
    }
    if (exec.length > 0) {
        CIRunKillall(exec);
    }
    NSString *last = bundleID.pathExtension.length ? bundleID.pathExtension : bundleID.lastPathComponent;
    if (last.length > 0 && ![last isEqualToString:exec]) {
        CIRunKillall(last);
    }
}

static NSArray<NSString *> *CIExtraWipePaths(NSString *bundleID) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSArray<NSString *> *prefsRoots = @[
        @"/var/mobile/Library/Preferences",
        @"/private/var/mobile/Library/Preferences",
        @"/var/jb/var/mobile/Library/Preferences"
    ];
    for (NSString *root in prefsRoots) {
        [paths addObject:[root stringByAppendingPathComponent:[bundleID stringByAppendingString:@".plist"]]];
    }
    NSArray<NSString *> *cacheRoots = @[
        @"/var/mobile/Library/Caches",
        @"/private/var/mobile/Library/Caches"
    ];
    for (NSString *root in cacheRoots) {
        [paths addObject:[root stringByAppendingPathComponent:bundleID]];
    }
    NSArray<NSString *> *snapRoots = @[
        @"/var/mobile/Library/SplashBoard/Snapshots",
        @"/private/var/mobile/Library/SplashBoard/Snapshots"
    ];
    for (NSString *root in snapRoots) {
        [paths addObject:[root stringByAppendingPathComponent:bundleID]];
        [paths addObject:[root stringByAppendingPathComponent:[@"sceneID:" stringByAppendingString:bundleID]]];
    }
    return paths;
}

static NSDictionary *CIReadMeta(NSString *backupID) {
    if (backupID.length == 0) {
        return nil;
    }
    NSString *path = [[ChengIOSBackupRoot() stringByAppendingPathComponent:backupID] stringByAppendingPathComponent:@"meta.plist"];
    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![meta isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSMutableDictionary *out = [meta mutableCopy];
    out[@"id"] = backupID;
    out[@"path"] = [ChengIOSBackupRoot() stringByAppendingPathComponent:backupID];
    return out;
}

NSDictionary *ChengIOSBackupInfo(NSString *backupID) {
    return CIReadMeta(backupID);
}

NSArray<NSDictionary *> *ChengIOSListBackups(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = ChengIOSBackupRoot();
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    for (NSString *name in names) {
        NSDictionary *meta = CIReadMeta(name);
        if (meta) {
            [items addObject:meta];
        }
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *ca = a[@"created"] ?: a[@"id"] ?: @"";
        NSString *cb = b[@"created"] ?: b[@"id"] ?: @"";
        return [cb compare:ca];
    }];
    return items;
}

NSString *ChengIOSLatestBackupID(void) {
    return ChengIOSListBackups().firstObject[@"id"];
}

static BOOL CIWriteMeta(NSString *backupID, NSDictionary *meta) {
    NSString *dir = [ChengIOSBackupRoot() stringByAppendingPathComponent:backupID];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"meta.plist"];
    return [meta writeToFile:path atomically:YES];
}

NSDictionary *ChengIOSCreateBackup(NSString *name, NSArray<NSString *> *bundleIDs, BOOL includeAppData, NSError **error) {
    NSString *backupID = CINewBackupID();
    NSString *dir = [ChengIOSBackupRoot() stringByAppendingPathComponent:backupID];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error]) {
        if (error && !*error) {
            *error = CIError(2, @"Khong tao duoc thu muc backup.");
        }
        return nil;
    }

    NSString *label = CISanitizeName(name);
    if (label.length == 0) {
        label = ChengIOSSuggestedBackupName();
    }

    NSDictionary *prefs = ChengIOSLoadRawPrefs() ?: @{};
    NSString *profilePath = [dir stringByAppendingPathComponent:@"profile.plist"];
    [prefs writeToFile:profilePath atomically:YES];

    NSMutableArray<NSString *> *savedBundles = [NSMutableArray array];
    NSMutableArray<NSString *> *failedBundles = [NSMutableArray array];
    unsigned long long bytes = 0;
    NSArray<NSString *> *targets = bundleIDs;
    if (includeAppData && targets.count == 0) {
        targets = ChengIOSUserSelectedBundleIDs();
    }
    if (includeAppData) {
        for (NSString *bundleID in targets) {
            if (![bundleID isKindOfClass:[NSString class]] || ChengIOSBundleIsProtected(bundleID)) {
                [failedBundles addObject:bundleID ?: @""];
                continue;
            }
            CITerminateBundle(bundleID);
        }
        [NSThread sleepForTimeInterval:0.4];
        for (NSString *bundleID in targets) {
            if (![bundleID isKindOfClass:[NSString class]] || ChengIOSBundleIsProtected(bundleID)) {
                continue;
            }
            NSString *dataPath = CIDataPath(bundleID);
            if (dataPath.length == 0) {
                [failedBundles addObject:bundleID];
                continue;
            }
            NSString *appDir = [[dir stringByAppendingPathComponent:@"apps"] stringByAppendingPathComponent:bundleID];
            bytes += CICopyTree(dataPath, [appDir stringByAppendingPathComponent:@"data"]);
            NSDictionary *groups = CIGroupPaths(bundleID);
            for (NSString *group in groups) {
                bytes += CICopyTree(groups[group], [[appDir stringByAppendingPathComponent:@"groups"] stringByAppendingPathComponent:group]);
            }
            [savedBundles addObject:bundleID];
        }
    }

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSMutableDictionary *meta = [@{
        @"id": backupID,
        @"name": label,
        @"created": [fmt stringFromDate:[NSDate date]],
        @"version": @"1.2.11",
        @"includeAppData": @(includeAppData),
        @"bundles": savedBundles,
        @"failedBundles": failedBundles,
        @"bytes": @(bytes),
        @"profileSummary": ChengIOSProfileSummary(ChengIOSLoadSavedProfile()) ?: @""
    } mutableCopy];
    CIWriteMeta(backupID, meta);

    NSString *summaryPath = [dir stringByAppendingPathComponent:@"summary.txt"];
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"%@\n%@\n\n", label, meta[@"created"]];
    [text appendFormat:@"%@\n", meta[@"profileSummary"]];
    if (savedBundles.count > 0) {
        [text appendFormat:@"\nApps:\n%@\n", [savedBundles componentsJoinedByString:@"\n"]];
    }
    [text writeToFile:summaryPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    meta[@"path"] = dir;
    return meta;
}

BOOL ChengIOSRestoreBackup(NSString *backupID, BOOL restoreProfile, BOOL restoreAppData, NSError **error) {
    NSDictionary *meta = CIReadMeta(backupID);
    if (!meta) {
        if (error) {
            *error = CIError(3, @"Khong tim thay backup.");
        }
        return NO;
    }
    NSString *dir = meta[@"path"];
    if (restoreProfile) {
        NSDictionary *profile = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"profile.plist"]];
        if (profile.count == 0) {
            if (error) {
                *error = CIError(3, @"Backup khong co ho so.");
            }
            return NO;
        }
        ChengIOSApplyProfile(profile);
    }
    if (restoreAppData) {
        NSString *appsDir = [dir stringByAppendingPathComponent:@"apps"];
        NSArray<NSString *> *bundles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appsDir error:nil];
        for (NSString *bundleID in bundles) {
            if (ChengIOSBundleIsProtected(bundleID)) {
                continue;
            }
            CITerminateBundle(bundleID);
        }
        [NSThread sleepForTimeInterval:0.4];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *bundleID in bundles) {
            if (ChengIOSBundleIsProtected(bundleID)) {
                continue;
            }
            NSString *live = CIDataPath(bundleID);
            if (live.length == 0) {
                continue;
            }
            CIWipeContents(live);
            NSString *savedData = [[appsDir stringByAppendingPathComponent:bundleID] stringByAppendingPathComponent:@"data"];
            if ([fm fileExistsAtPath:savedData]) {
                CICopyTree(savedData, live);
            }
            NSString *groupsDir = [[appsDir stringByAppendingPathComponent:bundleID] stringByAppendingPathComponent:@"groups"];
            NSArray<NSString *> *groupIDs = [fm contentsOfDirectoryAtPath:groupsDir error:nil];
            NSDictionary *liveGroups = CIGroupPaths(bundleID);
            for (NSString *groupID in groupIDs) {
                NSString *dest = liveGroups[groupID];
                if (dest.length == 0) {
                    dest = CIScanContainer(@[
                        @"/var/mobile/Containers/Shared/AppGroup",
                        @"/private/var/mobile/Containers/Shared/AppGroup"
                    ], groupID);
                }
                if (dest.length == 0) {
                    continue;
                }
                CIWipeContents(dest);
                CICopyTree([groupsDir stringByAppendingPathComponent:groupID], dest);
            }
        }
    }
    return YES;
}

BOOL ChengIOSDeleteBackup(NSString *backupID, NSError **error) {
    if (backupID.length == 0 || [backupID containsString:@"/"] || [backupID containsString:@".."]) {
        if (error) {
            *error = CIError(3, @"Backup ID khong hop le.");
        }
        return NO;
    }
    NSString *dir = [ChengIOSBackupRoot() stringByAppendingPathComponent:backupID];
    NSString *root = ChengIOSBackupRoot();
    if (![dir hasPrefix:root] || [dir isEqualToString:root]) {
        if (error) {
            *error = CIError(3, @"Backup ID khong hop le.");
        }
        return NO;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
        if (error) {
            *error = CIError(3, @"Khong tim thay backup.");
        }
        return NO;
    }
    return [[NSFileManager defaultManager] removeItemAtPath:dir error:error];
}

BOOL ChengIOSRenameBackup(NSString *backupID, NSString *name, NSError **error) {
    NSMutableDictionary *meta = [CIReadMeta(backupID) mutableCopy];
    if (!meta) {
        if (error) {
            *error = CIError(3, @"Khong tim thay backup.");
        }
        return NO;
    }
    NSString *label = CISanitizeName(name);
    if (label.length == 0) {
        if (error) {
            *error = CIError(1, @"Ten backup trong.");
        }
        return NO;
    }
    meta[@"name"] = label;
    [meta removeObjectForKey:@"path"];
    return CIWriteMeta(backupID, meta);
}

static BOOL CIEraseOne(NSString *bundleID) {
    if (ChengIOSBundleIsProtected(bundleID)) {
        return NO;
    }
    CITerminateBundle(bundleID);
    [NSThread sleepForTimeInterval:0.25];
    BOOL ok = NO;
    NSString *dataPath = CIDataPath(bundleID);
    if (dataPath.length > 0) {
        ok = CIWipeContents(dataPath) || ok;
    }
    NSDictionary *groups = CIGroupPaths(bundleID);
    for (NSString *path in groups.allValues) {
        ok = CIWipeContents(path) || ok;
    }
    for (NSString *extra in CIExtraWipePaths(bundleID)) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:extra] && CIPathSafeToMutate(extra)) {
            [[NSFileManager defaultManager] removeItemAtPath:extra error:nil];
            ok = YES;
        }
    }
    return ok;
}

NSDictionary *ChengIOSEraseBundles(NSArray<NSString *> *bundleIDs, NSError **error) {
    NSMutableArray *ok = [NSMutableArray array];
    NSMutableArray *failed = [NSMutableArray array];
    NSMutableArray *skipped = [NSMutableArray array];
    NSArray<NSString *> *targets = bundleIDs.count ? bundleIDs : ChengIOSUserSelectedBundleIDs();
    if (targets.count == 0) {
        if (error) {
            *error = CIError(5, @"Chua chon app nao (tru Safari / app he thong).");
        }
        return @{@"ok": ok, @"failed": failed, @"skipped": skipped};
    }
    for (NSString *bundleID in targets) {
        if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) {
            continue;
        }
        if (ChengIOSBundleIsProtected(bundleID)) {
            [skipped addObject:bundleID];
            continue;
        }
        if (CIEraseOne(bundleID)) {
            [ok addObject:bundleID];
        } else {
            [failed addObject:bundleID];
        }
    }
    return @{@"ok": ok, @"failed": failed, @"skipped": skipped};
}
