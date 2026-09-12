#import "ChengIOSBackup.h"
#import "ChengIOSProfiles.h"

#import <objc/runtime.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import <Security/Security.h>

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

static NSArray<NSString *> *CIBackupRootCandidates(void) {
    return @[
        @"/var/mobile/Media/ChengIOS/Backups",
        @"/private/var/mobile/Media/ChengIOS/Backups",
        @"/var/mobile/Documents/ChengIOS/Backups",
        @"/var/jb/var/mobile/Documents/ChengIOS/Backups"
    ];
}

static BOOL CIValidBackupID(NSString *backupID) {
    if (backupID.length < 4 || backupID.length > 80) {
        return NO;
    }
    if ([backupID hasPrefix:@"."] || [backupID containsString:@".."] ||
        [backupID containsString:@"/"] || [backupID containsString:@"\\"]) {
        return NO;
    }
    for (NSUInteger i = 0; i < backupID.length; i++) {
        unichar c = [backupID characterAtIndex:i];
        BOOL ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.';
        if (!ok) {
            return NO;
        }
    }
    return YES;
}

NSString *ChengIOSBackupRoot(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *preferred = @[
        @"/var/mobile/Media/ChengIOS/Backups",
        @"/private/var/mobile/Media/ChengIOS/Backups"
    ];
    for (NSString *path in preferred) {
        BOOL dir = NO;
        if ([fm fileExistsAtPath:path isDirectory:&dir] && dir) {
            return path;
        }
        if ([fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil] ||
            [fm fileExistsAtPath:path]) {
            return path;
        }
    }
    return CIFirstExistingDir(CIBackupRootCandidates(), YES);
}

static NSString *CIBackupDirForID(NSString *backupID) {
    if (!CIValidBackupID(backupID)) {
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in CIBackupRootCandidates()) {
        NSString *dir = [root stringByAppendingPathComponent:backupID];
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"meta.plist"]] ||
            [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"profile.plist"]]) {
            return dir;
        }
    }
    return nil;
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
        @"com.opa334.altlist",
        @"com.opa334.trollstore",
        @"ws.hbang.newterm2",
        @"com.apptapp.installer",
        @"org.coolstar.electra",
        @"science.xnu.undecimus"
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
    if ([low hasPrefix:@"com.saurik."] || [low hasPrefix:@"org.coolstar.sileo"] ||
        [low hasPrefix:@"xyz.willy.zebra"]) {
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
    if ([low containsString:@"/library/saved application state/"] && parts.count >= 6) {
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
    NSArray<NSString *> *stateRoots = @[
        @"/var/mobile/Library/Saved Application State",
        @"/private/var/mobile/Library/Saved Application State"
    ];
    for (NSString *root in stateRoots) {
        [paths addObject:[root stringByAppendingPathComponent:[bundleID stringByAppendingString:@".savedState"]]];
    }
    return paths;
}

static BOOL CIBundlesAreRelated(NSString *left, NSString *right) {
    if (left.length == 0 || right.length == 0) {
        return NO;
    }
    NSString *a = left.lowercaseString;
    NSString *b = right.lowercaseString;
    if ([a isEqualToString:b]) {
        return YES;
    }
    NSArray<NSArray<NSString *> *> *families = @[
        @[@"com.facebook.", @"com.meta.", @"com.burbn.", @"com.instagram.", @"net.whatsapp."],
        @[@"com.shopee.", @"com.beeasy.", @"com.sgs."]
    ];
    for (NSArray<NSString *> *family in families) {
        BOOL ha = NO;
        BOOL hb = NO;
        for (NSString *prefix in family) {
            if ([a hasPrefix:prefix]) {
                ha = YES;
            }
            if ([b hasPrefix:prefix]) {
                hb = YES;
            }
        }
        if (ha && hb) {
            return YES;
        }
    }
    NSArray<NSString *> *pa = [a componentsSeparatedByString:@"."];
    NSArray<NSString *> *pb = [b componentsSeparatedByString:@"."];
    return pa.count >= 2 && pb.count >= 2 && [pa[0] isEqualToString:pb[0]] && [pa[1] isEqualToString:pb[1]];
}

static BOOL CIGroupUsedByOtherApps(NSString *group, NSString *bundleID, NSArray<NSString *> *erasing) {
    if (group.length == 0) {
        return NO;
    }
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    id ws = [wsClass respondsToSelector:@selector(defaultWorkspace)] ? [wsClass defaultWorkspace] : nil;
    if (![ws respondsToSelector:@selector(allInstalledApplications)]) {
        return NO;
    }
    NSArray *apps = [ws allInstalledApplications];
    for (id app in apps) {
        NSString *other = nil;
        if ([app respondsToSelector:@selector(applicationIdentifier)]) {
            other = [app applicationIdentifier];
        }
        if (other.length == 0 && [app respondsToSelector:@selector(bundleIdentifier)]) {
            other = [app bundleIdentifier];
        }
        if (other.length == 0 || [other isEqualToString:bundleID]) {
            continue;
        }
        if ([erasing containsObject:other] || CIBundlesAreRelated(bundleID, other)) {
            continue;
        }
        NSDictionary *urls = nil;
        if ([app respondsToSelector:@selector(groupContainerURLs)]) {
            urls = [app groupContainerURLs];
        }
        if ([urls isKindOfClass:[NSDictionary class]] && urls[group]) {
            return YES;
        }
    }
    return NO;
}

static BOOL CIKeychainTextMatchesBundle(NSString *text, NSString *bundleID) {
    if (text.length == 0 || bundleID.length == 0) {
        return NO;
    }
    NSString *blob = text.lowercaseString;
    NSString *low = bundleID.lowercaseString;
    if ([blob containsString:low]) {
        return YES;
    }
    if ([low hasPrefix:@"com.facebook."] || [low hasPrefix:@"com.meta."] || [low containsString:@"facebook"]) {
        NSArray<NSString *> *needles = @[
            @"facebook", @"fbauth", @"fbsdk", @"fb_user", @"fb-token", @"fbssoservice",
            @"messenger.com", @"fb.com", @"instagram", @"whatsapp"
        ];
        for (NSString *needle in needles) {
            if ([blob containsString:needle]) {
                return YES;
            }
        }
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."]) {
        return [blob containsString:@"shopee"] || [blob containsString:@"beeasy"];
    }
    NSArray<NSString *> *parts = [low componentsSeparatedByString:@"."];
    if (parts.count >= 2) {
        NSString *vendor = [NSString stringWithFormat:@"%@.%@", parts[0], parts[1]];
        if ([blob containsString:vendor]) {
            return YES;
        }
    }
    return NO;
}

static void CIKeychainDeleteMatching(id secClass, NSString *bundleID) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: secClass,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) {
        return;
    }
    NSArray *items = CFBridgingRelease(result);
    if (![items isKindOfClass:[NSArray class]]) {
        return;
    }
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *blob = [NSString stringWithFormat:@"%@ %@ %@ %@ %@",
                          item[(__bridge id)kSecAttrService] ?: @"",
                          item[(__bridge id)kSecAttrAccount] ?: @"",
                          item[(__bridge id)kSecAttrAccessGroup] ?: @"",
                          item[(__bridge id)kSecAttrLabel] ?: @"",
                          item[(__bridge id)kSecAttrServer] ?: @""];
        if (!CIKeychainTextMatchesBundle(blob, bundleID)) {
            continue;
        }
        NSMutableDictionary *del = [@{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
        } mutableCopy];
        for (id key in @[
            (__bridge id)kSecAttrService,
            (__bridge id)kSecAttrAccount,
            (__bridge id)kSecAttrAccessGroup,
            (__bridge id)kSecAttrLabel,
            (__bridge id)kSecAttrServer
        ]) {
            id value = item[key];
            if (value) {
                del[key] = value;
            }
        }
        SecItemDelete((__bridge CFDictionaryRef)del);
    }
}

static void CIWipeKeychainForProxy(LSApplicationProxy *proxy, NSString *bundleID) {
    if (bundleID.length == 0) {
        return;
    }
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    id ents = nil;
    if ([proxy respondsToSelector:@selector(entitlements)]) {
        ents = proxy.entitlements;
    }
    if ([ents isKindOfClass:[NSDictionary class]]) {
        id kag = ents[@"keychain-access-groups"];
        if ([kag isKindOfClass:[NSArray class]]) {
            for (id group in kag) {
                if ([group isKindOfClass:[NSString class]] && [group length] > 0) {
                    [groups addObject:group];
                }
            }
        }
        id appId = ents[@"application-identifier"];
        if ([appId isKindOfClass:[NSString class]] && [appId length] > 0) {
            [groups addObject:appId];
        }
        id appGroups = ents[@"com.apple.security.application-groups"];
        if ([appGroups isKindOfClass:[NSArray class]]) {
            for (id group in appGroups) {
                if ([group isKindOfClass:[NSString class]] && [group length] > 0) {
                    [groups addObject:group];
                }
            }
        }
    }
    [groups addObject:bundleID];
    if ([bundleID.lowercaseString hasPrefix:@"com.facebook."]) {
        [groups addObjectsFromArray:@[
            @"com.facebook.Facebook",
            @"group.com.facebook.Facebook",
            @"group.com.facebook.family",
            @"group.com.facebook.Messenger"
        ]];
    }
    NSArray *classes = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassIdentity
    ];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *group in groups) {
        if ([seen containsObject:group]) {
            continue;
        }
        [seen addObject:group];
        NSString *low = group.lowercaseString;
        if ([low hasPrefix:@"com.apple."] && ![low containsString:bundleID.lowercaseString]) {
            continue;
        }
        for (id cls in classes) {
            NSDictionary *query = @{
                (__bridge id)kSecClass: cls,
                (__bridge id)kSecAttrAccessGroup: group,
                (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
            };
            SecItemDelete((__bridge CFDictionaryRef)query);
        }
    }
    CIKeychainDeleteMatching((__bridge id)kSecClassGenericPassword, bundleID);
    CIKeychainDeleteMatching((__bridge id)kSecClassInternetPassword, bundleID);
}

static NSDictionary *CIReadMeta(NSString *backupID) {
    NSString *dir = CIBackupDirForID(backupID);
    if (dir.length == 0) {
        return nil;
    }
    NSString *path = [dir stringByAppendingPathComponent:@"meta.plist"];
    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:path];
    NSMutableDictionary *out = [meta isKindOfClass:[NSDictionary class]] ? [meta mutableCopy] : [NSMutableDictionary dictionary];
    out[@"id"] = backupID;
    out[@"path"] = dir;
    if (![out[@"name"] isKindOfClass:[NSString class]] || [out[@"name"] length] == 0) {
        out[@"name"] = backupID;
    }
    return out;
}

NSDictionary *ChengIOSBackupInfo(NSString *backupID) {
    return CIReadMeta(backupID);
}

NSArray<NSDictionary *> *ChengIOSListBackups(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableDictionary<NSString *, NSDictionary *> *map = [NSMutableDictionary dictionary];
    for (NSString *root in CIBackupRootCandidates()) {
        NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
        for (NSString *name in names) {
            if (map[name] || !CIValidBackupID(name)) {
                continue;
            }
            NSDictionary *meta = CIReadMeta(name);
            if (meta) {
                map[name] = meta;
            }
        }
    }
    NSMutableArray<NSDictionary *> *items = [map.allValues mutableCopy];
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
    if (!CIValidBackupID(backupID)) {
        return NO;
    }
    NSString *dir = CIBackupDirForID(backupID);
    if (dir.length == 0) {
        dir = [ChengIOSBackupRoot() stringByAppendingPathComponent:backupID];
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *clean = [meta mutableCopy] ?: [NSMutableDictionary dictionary];
    [clean removeObjectForKey:@"path"];
    NSString *path = [dir stringByAppendingPathComponent:@"meta.plist"];
    return [clean writeToFile:path atomically:YES];
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
        @"version": @"1.2.14",
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
        ChengIOSReplaceRawPrefs(profile);
    }
    if (restoreAppData) {
        NSString *appsDir = [dir stringByAppendingPathComponent:@"apps"];
        NSArray<NSString *> *bundles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appsDir error:nil];
        for (NSString *bundleID in bundles) {
            if (![bundleID isKindOfClass:[NSString class]] ||
                [bundleID containsString:@"/"] || [bundleID containsString:@".."] ||
                ChengIOSBundleIsProtected(bundleID)) {
                continue;
            }
            CITerminateBundle(bundleID);
        }
        [NSThread sleepForTimeInterval:0.4];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *bundleID in bundles) {
            if (![bundleID isKindOfClass:[NSString class]] ||
                [bundleID containsString:@"/"] || [bundleID containsString:@".."] ||
                ChengIOSBundleIsProtected(bundleID)) {
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
    NSString *dir = CIBackupDirForID(backupID);
    if (dir.length == 0) {
        if (error) {
            *error = CIError(3, @"Khong tim thay backup.");
        }
        return NO;
    }
    BOOL allowed = NO;
    for (NSString *root in CIBackupRootCandidates()) {
        if ([dir hasPrefix:root] && ![dir isEqualToString:root]) {
            allowed = YES;
            break;
        }
    }
    if (!allowed) {
        if (error) {
            *error = CIError(3, @"Backup ID khong hop le.");
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

static void CITerminateRelatedBundles(NSString *bundleID) {
    CITerminateBundle(bundleID);
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    id ws = [wsClass respondsToSelector:@selector(defaultWorkspace)] ? [wsClass defaultWorkspace] : nil;
    if (![ws respondsToSelector:@selector(allInstalledApplications)]) {
        return;
    }
    NSString *prefix = [bundleID stringByAppendingString:@"."];
    NSArray *apps = [ws allInstalledApplications];
    for (id app in apps) {
        NSString *ident = nil;
        if ([app respondsToSelector:@selector(applicationIdentifier)]) {
            ident = [app applicationIdentifier];
        }
        if (ident.length == 0 && [app respondsToSelector:@selector(bundleIdentifier)]) {
            ident = [app bundleIdentifier];
        }
        if (ident.length == 0 || [ident isEqualToString:bundleID]) {
            continue;
        }
        if ([ident hasPrefix:prefix]) {
            CITerminateBundle(ident);
        }
    }
}

static BOOL CIEraseOne(NSString *bundleID, NSArray<NSString *> *together) {
    if (ChengIOSBundleIsProtected(bundleID)) {
        return NO;
    }
    CITerminateRelatedBundles(bundleID);
    [NSThread sleepForTimeInterval:0.35];
    BOOL ok = NO;
    NSString *dataPath = CIDataPath(bundleID);
    if (dataPath.length > 0) {
        ok = CIWipeContents(dataPath) || ok;
    }
    NSString *prefix = [bundleID stringByAppendingString:@"."];
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    id ws = [wsClass respondsToSelector:@selector(defaultWorkspace)] ? [wsClass defaultWorkspace] : nil;
    if ([ws respondsToSelector:@selector(allInstalledApplications)]) {
        for (id app in [ws allInstalledApplications]) {
            NSString *ident = nil;
            if ([app respondsToSelector:@selector(applicationIdentifier)]) {
                ident = [app applicationIdentifier];
            }
            if (ident.length == 0 && [app respondsToSelector:@selector(bundleIdentifier)]) {
                ident = [app bundleIdentifier];
            }
            if (![ident hasPrefix:prefix] || ChengIOSBundleIsProtected(ident)) {
                continue;
            }
            NSString *extraData = CIDataPath(ident);
            if (extraData.length > 0) {
                ok = CIWipeContents(extraData) || ok;
            }
        }
    }
    NSMutableDictionary<NSString *, NSString *> *groups = [NSMutableDictionary dictionary];
    [groups addEntriesFromDictionary:CIGroupPaths(bundleID)];
    if ([bundleID.lowercaseString hasPrefix:@"com.facebook."] || [bundleID.lowercaseString hasPrefix:@"com.meta."]) {
        for (NSString *gid in @[
            @"group.com.facebook.Facebook",
            @"group.com.facebook.family",
            @"group.com.facebook.Messenger",
            @"group.com.facebook.Facebook.widget",
            @"group.com.facebook.mlite"
        ]) {
            if (groups[gid].length > 0) {
                continue;
            }
            NSString *path = CIScanContainer(@[
                @"/var/mobile/Containers/Shared/AppGroup",
                @"/private/var/mobile/Containers/Shared/AppGroup"
            ], gid);
            if (path.length > 0) {
                groups[gid] = path;
            }
        }
    }
    for (NSString *group in groups) {
        if (CIGroupUsedByOtherApps(group, bundleID, together)) {
            continue;
        }
        ok = CIWipeContents(groups[group]) || ok;
        for (NSString *root in @[
            @"/var/mobile/Library/Preferences",
            @"/private/var/mobile/Library/Preferences"
        ]) {
            NSString *plist = [root stringByAppendingPathComponent:[group stringByAppendingString:@".plist"]];
            if ([[NSFileManager defaultManager] fileExistsAtPath:plist] && CIPathSafeToMutate(plist)) {
                [[NSFileManager defaultManager] removeItemAtPath:plist error:nil];
            }
        }
    }
    for (NSString *extra in CIExtraWipePaths(bundleID)) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:extra] && CIPathSafeToMutate(extra)) {
            [[NSFileManager defaultManager] removeItemAtPath:extra error:nil];
            ok = YES;
        }
    }
    CIWipeKeychainForProxy(CIProxy(bundleID), bundleID);
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
        if (CIEraseOne(bundleID, targets)) {
            [ok addObject:bundleID];
        } else {
            [failed addObject:bundleID];
        }
    }
    return @{@"ok": ok, @"failed": failed, @"skipped": skipped};
}
