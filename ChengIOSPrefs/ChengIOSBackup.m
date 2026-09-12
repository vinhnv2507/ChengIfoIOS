#import "ChengIOSBackup.h"
#import "ChengIOSProfiles.h"

#import <objc/runtime.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#include <sys/stat.h>
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
@property (nonatomic, readonly) NSString *applicationType;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)terminateApplication:(NSString *)bundleIdentifier withOptions:(id)options;
- (NSArray *)allInstalledApplications;
@end

static void CIRunKillall(NSString *processName);
static void CITerminateBundle(NSString *bundleID);
static void CITerminateRelatedBundles(NSString *bundleID);
static BOOL CIKeychainTextMatchesBundle(NSString *text, NSString *bundleID);
static NSArray<NSString *> *CIKnownKeychainServices(NSString *bundleID);
static void CIWipeKnownKeychainServices(NSString *bundleID);
static void CISettleForDisk(NSString *bundleID);
static void CISettleAfterDisk(NSString *bundleID);

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

BOOL ChengIOSBundleIsSafari(NSString *bundleID) {
    if (bundleID.length == 0) {
        return NO;
    }
    NSString *low = bundleID.lowercaseString;
    return [low isEqualToString:@"com.apple.mobilesafari"] ||
           [low isEqualToString:@"com.apple.safariviewservice"] ||
           [low isEqualToString:@"com.apple.safari"] ||
           [low isEqualToString:@"com.apple.webapp"] ||
           [low hasPrefix:@"com.apple.mobilesafari."];
}

BOOL ChengIOSBundleIsProtected(NSString *bundleID) {
    if (bundleID.length == 0) {
        return YES;
    }
    if (ChengIOSBundleIsSafari(bundleID)) {
        return NO;
    }
    NSString *low = bundleID.lowercaseString;
    NSArray<NSString *> *blocked = @[
        @"com.apple.springboard",
        @"com.apple.preferences",
        @"com.apple.backboardd",
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

static BOOL CIIsReservedName(NSString *name) {
    if (name.length == 0) {
        return YES;
    }
    return [name isEqualToString:@".com.apple.mobile_container_manager.metadata.plist"] ||
           [name hasPrefix:@".com.apple.mobile_container_manager"];
}

static NSArray<NSString *> *CIAppDataSubdirs(void) {
    return @[ @"Documents", @"Library", @"tmp", @"SystemData" ];
}

static const uid_t kCIMobileUID = 501;
static const gid_t kCIMobileGID = 501;

static void CIClearItemFlags(NSString *path) {
    if (path.length == 0) {
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    attrs[NSFileImmutable] = @NO;
    attrs[NSFileAppendOnly] = @NO;
    attrs[NSFilePosixPermissions] = @0777;
    [fm setAttributes:attrs ofItemAtPath:path error:nil];
    const char *raw = path.fileSystemRepresentation;
    if (raw) {
        chmod(raw, 0777);
    }
}

static void CIChownTree(NSString *path) {
    if (path.length == 0) {
        return;
    }
    const char *raw = path.fileSystemRepresentation;
    if (raw) {
        lchown(raw, kCIMobileUID, kCIMobileGID);
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if (![attrs.fileType isEqualToString:NSFileTypeDirectory]) {
        return;
    }
    for (NSString *name in [fm contentsOfDirectoryAtPath:path error:nil]) {
        CIChownTree([path stringByAppendingPathComponent:name]);
    }
}

static BOOL CIRemoveDeep(NSString *path) {
    if (path.length == 0) {
        return YES;
    }
    if (CIIsReservedName(path.lastPathComponent)) {
        return YES;
    }
    CIClearItemFlags(path);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if (!attrs) {
        return YES;
    }
    BOOL ok = YES;
    if ([attrs.fileType isEqualToString:NSFileTypeDirectory]) {
        for (NSString *name in [fm contentsOfDirectoryAtPath:path error:nil]) {
            if (CIIsReservedName(name)) {
                continue;
            }
            if (!CIRemoveDeep([path stringByAppendingPathComponent:name])) {
                ok = NO;
            }
        }
    }
    if (![fm removeItemAtPath:path error:nil]) {
        CIClearItemFlags(path);
        if (![fm removeItemAtPath:path error:nil]) {
            ok = NO;
        }
    }
    return ok;
}

static BOOL CIEmptyDir(NSString *dir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir]) {
        return YES;
    }
    if (!isDir) {
        CIClearItemFlags(dir);
        return [fm removeItemAtPath:dir error:nil];
    }
    CIClearItemFlags(dir);
    BOOL ok = YES;
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        if (CIIsReservedName(name)) {
            continue;
        }
        if (!CIRemoveDeep([dir stringByAppendingPathComponent:name])) {
            ok = NO;
        }
    }
    return ok;
}

static BOOL CIEmptyContainer(NSString *path) {
    if (!CIPathSafeToMutate(path)) {
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
        return YES;
    }
    BOOL ok = YES;
    for (NSString *sub in CIAppDataSubdirs()) {
        if (!CIEmptyDir([path stringByAppendingPathComponent:sub])) {
            ok = NO;
        }
    }
    for (NSString *name in [fm contentsOfDirectoryAtPath:path error:nil]) {
        if (CIIsReservedName(name) || [CIAppDataSubdirs() containsObject:name]) {
            continue;
        }
        if (!CIRemoveDeep([path stringByAppendingPathComponent:name])) {
            ok = NO;
        }
    }
    return ok;
}

static unsigned long long CICopyTree(NSString *from, NSString *to) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (CIIsReservedName(from.lastPathComponent)) {
        return 0;
    }
    NSDictionary *attrs = [fm attributesOfItemAtPath:from error:nil];
    if (!attrs) {
        return 0;
    }
    NSString *type = attrs.fileType;
    if ([type isEqualToString:NSFileTypeDirectory]) {
        [fm createDirectoryAtPath:to withIntermediateDirectories:YES attributes:nil error:nil];
        unsigned long long total = 0;
        for (NSString *name in [fm contentsOfDirectoryAtPath:from error:nil]) {
            if (CIIsReservedName(name)) {
                continue;
            }
            total += CICopyTree([from stringByAppendingPathComponent:name],
                                [to stringByAppendingPathComponent:name]);
        }
        return total;
    }
    if ([type isEqualToString:NSFileTypeRegular] || [type isEqualToString:NSFileTypeSymbolicLink]) {
        NSString *parent = [to stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
        [fm removeItemAtPath:to error:nil];
        if ([fm copyItemAtPath:from toPath:to error:nil]) {
            if ([type isEqualToString:NSFileTypeRegular]) {
                return [attrs[NSFileSize] unsignedLongLongValue];
            }
        }
        return 0;
    }
    return 0;
}

static BOOL CIWipeContents(NSString *path) {
    if (!CIPathSafeToMutate(path)) {
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        return YES;
    }
    if (!isDir) {
        CIClearItemFlags(path);
        return [fm removeItemAtPath:path error:nil];
    }
    return CIEmptyDir(path);
}

static unsigned long long CIBackupContainer(NSString *fromContainer, NSString *toDataDir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long bytes = 0;
    [fm createDirectoryAtPath:toDataDir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *sub in CIAppDataSubdirs()) {
        NSString *src = [fromContainer stringByAppendingPathComponent:sub];
        NSDictionary *attrs = [fm attributesOfItemAtPath:src error:nil];
        if (![attrs.fileType isEqualToString:NSFileTypeDirectory]) {
            continue;
        }
        bytes += CICopyTree(src, [toDataDir stringByAppendingPathComponent:sub]);
    }
    return bytes;
}

static BOOL CIRestoreContainer(NSString *saved, NSString *live) {
    if (!CIPathSafeToMutate(live)) {
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    CIEmptyContainer(live);
    BOOL savedDir = NO;
    if (![fm fileExistsAtPath:saved isDirectory:&savedDir] || !savedDir) {
        return YES;
    }
    for (NSString *sub in CIAppDataSubdirs()) {
        NSString *src = [saved stringByAppendingPathComponent:sub];
        NSDictionary *attrs = [fm attributesOfItemAtPath:src error:nil];
        if (![attrs.fileType isEqualToString:NSFileTypeDirectory]) {
            continue;
        }
        NSString *dst = [live stringByAppendingPathComponent:sub];
        CICopyTree(src, dst);
        CIChownTree(dst);
    }
    for (NSString *name in [fm contentsOfDirectoryAtPath:saved error:nil]) {
        if (CIIsReservedName(name) || [CIAppDataSubdirs() containsObject:name]) {
            continue;
        }
        NSString *dst = [live stringByAppendingPathComponent:name];
        CICopyTree([saved stringByAppendingPathComponent:name], dst);
        CIChownTree(dst);
    }
    return YES;
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

static void CISettleForDisk(NSString *bundleID) {
    CITerminateRelatedBundles(bundleID);
    NSString *low = bundleID.lowercaseString;
    if ([low hasPrefix:@"com.facebook."] || [low hasPrefix:@"com.meta."] || [low containsString:@"facebook"]) {
        CIRunKillall(@"Facebook");
        CIRunKillall(@"Messenger");
        CIRunKillall(@"MessengerLite");
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."]) {
        CIRunKillall(@"Shopee");
        CIRunKillall(@"ShopeeApp");
    }
    [NSThread sleepForTimeInterval:0.9];
    CIRunKillall(@"cfprefsd");
    [NSThread sleepForTimeInterval:0.25];
}

static void CISettleAfterDisk(NSString *bundleID) {
    CIRunKillall(@"cfprefsd");
    [NSThread sleepForTimeInterval:0.2];
    CITerminateRelatedBundles(bundleID);
}

static void CIReemptyPrefs(NSString *container) {
    if (container.length == 0 || !CIPathSafeToMutate(container)) {
        return;
    }
    CIEmptyDir([container stringByAppendingPathComponent:@"Library/Preferences"]);
    CIEmptyDir([container stringByAppendingPathComponent:@"Library/Cookies"]);
    CIEmptyDir([container stringByAppendingPathComponent:@"Library/HTTPStorages"]);
    CIEmptyDir([container stringByAppendingPathComponent:@"Library/Caches"]);
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
            @"fbssologin", @"fbsso", @"fb_session", @"fbaccesstoken", @"fb-token",
            @"com.facebook", @"group.com.facebook", @"43aqtk3442.com.facebook",
            @"messenger.com", @"fb.com", @"facebook.com"
        ];
        for (NSString *needle in needles) {
            if ([blob containsString:needle]) {
                return YES;
            }
        }
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."]) {
        return [blob containsString:@"shopee"] || [blob containsString:@"beeasy"] ||
               [blob containsString:@"shopeepay"] || [blob containsString:@"sea.sgo"];
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

static NSString *CITeamIDFromAppID(NSString *value) {
    if (value.length < 12) {
        return nil;
    }
    NSRange dot = [value rangeOfString:@"."];
    if (dot.location < 8 || dot.location > 12) {
        return nil;
    }
    NSString *team = [value substringToIndex:dot.location];
    for (NSUInteger i = 0; i < team.length; i++) {
        unichar c = [team characterAtIndex:i];
        BOOL ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
        if (!ok) {
            return nil;
        }
    }
    return team;
}

static NSArray<NSString *> *CICompanionBundleIDs(NSString *bundleID) {
    NSString *low = bundleID.lowercaseString;
    if ([low isEqualToString:@"com.facebook.facebook"] || [low hasPrefix:@"com.facebook.facebook."]) {
        return @[
            @"com.facebook.Messenger",
            @"com.facebook.Facebook.lite",
            @"com.facebook.MessengerLite",
            @"com.facebook.Video"
        ];
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."]) {
        return @[
            @"com.shopee.vn",
            @"com.shopee.SG",
            @"com.beeasy.marketplace.vn"
        ];
    }
    return @[];
}

static NSDictionary<NSString *, NSString *> *CIScanContainersMatching(NSArray<NSString *> *roots, BOOL (^pred)(NSString *ident)) {
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    if (!pred) {
        return map;
    }
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
            if (found.length > 0 && pred(found)) {
                map[found] = dir;
            }
        }
    }
    return map;
}

static NSDictionary<NSString *, NSString *> *CIPluginPaths(NSString *bundleID) {
    NSString *prefix = [bundleID stringByAppendingString:@"."];
    NSArray *companions = CICompanionBundleIDs(bundleID);
    return CIScanContainersMatching(@[
        @"/var/mobile/Containers/Data/PluginKitPlugin",
        @"/private/var/mobile/Containers/Data/PluginKitPlugin"
    ], ^BOOL(NSString *ident) {
        if ([ident isEqualToString:bundleID] || [ident hasPrefix:prefix]) {
            return YES;
        }
        for (NSString *other in companions) {
            if ([ident isEqualToString:other] || [ident hasPrefix:[other stringByAppendingString:@"."]]) {
                return YES;
            }
        }
        return ChengIOSBundleIsSafari(bundleID) && (
            [ident.lowercaseString containsString:@"safari"] ||
            [ident.lowercaseString hasPrefix:@"com.apple.webkit"]
        );
    });
}

static NSArray<NSString *> *CISafariLibraryPaths(void) {
    return @[
        @"/var/mobile/Library/Safari",
        @"/private/var/mobile/Library/Safari",
        @"/var/mobile/Library/Cookies",
        @"/private/var/mobile/Library/Cookies",
        @"/var/mobile/Library/WebKit",
        @"/private/var/mobile/Library/WebKit",
        @"/var/mobile/Library/HTTPStorages",
        @"/private/var/mobile/Library/HTTPStorages",
        @"/var/mobile/Library/Caches/com.apple.mobilesafari",
        @"/private/var/mobile/Library/Caches/com.apple.mobilesafari",
        @"/var/mobile/Library/Caches/com.apple.WebKit.WebContent",
        @"/private/var/mobile/Library/Caches/com.apple.WebKit.WebContent",
        @"/var/mobile/Library/Caches/com.apple.WebKit.Networking",
        @"/private/var/mobile/Library/Caches/WebKit",
        @"/var/mobile/Library/Caches/com.apple.Safari",
        @"/var/mobile/Library/SafariSafeBrowsing",
        @"/var/mobile/Library/Preferences/com.apple.mobilesafari.plist",
        @"/private/var/mobile/Library/Preferences/com.apple.mobilesafari.plist",
        @"/var/mobile/Library/Preferences/com.apple.Safari.plist",
        @"/var/mobile/Library/Preferences/com.apple.SafariViewService.plist",
        @"/var/mobile/Library/Saved Application State/com.apple.mobilesafari.savedState",
        @"/var/mobile/Library/SplashBoard/Snapshots/com.apple.mobilesafari",
        @"/var/mobile/Library/SplashBoard/Snapshots/sceneID:com.apple.mobilesafari"
    ];
}

static void CIKillSafariProcesses(void) {
    NSArray<NSString *> *names = @[
        @"MobileSafari", @"SafariViewService",
        @"com.apple.WebKit.WebContent", @"com.apple.WebKit.Networking",
        @"com.apple.WebKit.GPU"
    ];
    for (NSString *name in names) {
        CIRunKillall(name);
    }
    CITerminateBundle(@"com.apple.mobilesafari");
    CITerminateBundle(@"com.apple.SafariViewService");
}

static NSString *CISecClassName(id cls) {
    if (cls == (__bridge id)kSecClassInternetPassword) {
        return @"inet";
    }
    if (cls == (__bridge id)kSecClassKey) {
        return @"keys";
    }
    if (cls == (__bridge id)kSecClassCertificate) {
        return @"cert";
    }
    if (cls == (__bridge id)kSecClassIdentity) {
        return @"idnt";
    }
    return @"genp";
}

static id CISecClassFromName(NSString *name) {
    if ([name isEqualToString:@"inet"]) {
        return (__bridge id)kSecClassInternetPassword;
    }
    if ([name isEqualToString:@"keys"]) {
        return (__bridge id)kSecClassKey;
    }
    if ([name isEqualToString:@"cert"]) {
        return (__bridge id)kSecClassCertificate;
    }
    if ([name isEqualToString:@"idnt"]) {
        return (__bridge id)kSecClassIdentity;
    }
    return (__bridge id)kSecClassGenericPassword;
}

static id CIPlistSafe(id value) {
    if ([value isKindOfClass:[NSString class]] ||
        [value isKindOfClass:[NSNumber class]] ||
        [value isKindOfClass:[NSDate class]] ||
        [value isKindOfClass:[NSData class]]) {
        return value;
    }
    return nil;
}

static NSArray<NSDictionary *> *CIKeychainCopyItems(id secClass, BOOL withData) {
    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: secClass,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecReturnData: @(withData),
        (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
    } mutableCopy];
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) {
        if (result) {
            CFRelease(result);
        }
        [query removeObjectForKey:(__bridge id)kSecAttrSynchronizable];
        result = NULL;
        status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    }
    if (status != errSecSuccess || !result) {
        if (result) {
            CFRelease(result);
        }
        return @[];
    }
    NSArray *items = CFBridgingRelease(result);
    return [items isKindOfClass:[NSArray class]] ? items : @[];
}

static NSDictionary *CIKeychainRowFromItem(id secClass, NSDictionary *item) {
    if (![item isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    row[@"class"] = CISecClassName(secClass);
    NSDictionary *map = @{
        @"service": (__bridge id)kSecAttrService,
        @"account": (__bridge id)kSecAttrAccount,
        @"accessGroup": (__bridge id)kSecAttrAccessGroup,
        @"label": (__bridge id)kSecAttrLabel,
        @"server": (__bridge id)kSecAttrServer,
        @"protocol": (__bridge id)kSecAttrProtocol,
        @"path": (__bridge id)kSecAttrPath,
        @"accessible": (__bridge id)kSecAttrAccessible
    };
    [map enumerateKeysAndObjectsUsingBlock:^(NSString *key, id secKey, BOOL *stop) {
        (void)stop;
        id value = CIPlistSafe(item[secKey]);
        if (value) {
            row[key] = value;
        }
    }];
    id port = item[(__bridge id)kSecAttrPort];
    if ([port isKindOfClass:[NSNumber class]]) {
        row[@"port"] = port;
    }
    id sync = item[(__bridge id)kSecAttrSynchronizable];
    if ([sync isKindOfClass:[NSNumber class]]) {
        row[@"synchronizable"] = sync;
    }
    NSData *data = item[(__bridge id)kSecValueData];
    if ([data isKindOfClass:[NSData class]] && data.length > 0) {
        row[@"data"] = [data base64EncodedStringWithOptions:0];
    }
    NSData *generic = item[(__bridge id)kSecAttrGeneric];
    if ([generic isKindOfClass:[NSData class]] && generic.length > 0) {
        row[@"generic"] = [generic base64EncodedStringWithOptions:0];
    }
    return row;
}

static BOOL CIKeychainItemMatchesBundle(NSDictionary *item, NSString *bundleID) {
    if (![item isKindOfClass:[NSDictionary class]] || bundleID.length == 0) {
        return NO;
    }
    NSString *blob = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@",
                      item[(__bridge id)kSecAttrService] ?: item[@"service"] ?: @"",
                      item[(__bridge id)kSecAttrAccount] ?: item[@"account"] ?: @"",
                      item[(__bridge id)kSecAttrAccessGroup] ?: item[@"accessGroup"] ?: @"",
                      item[(__bridge id)kSecAttrLabel] ?: item[@"label"] ?: @"",
                      item[(__bridge id)kSecAttrServer] ?: item[@"server"] ?: @"",
                      item[(__bridge id)kSecAttrPath] ?: item[@"path"] ?: @""];
    return CIKeychainTextMatchesBundle(blob, bundleID);
}

static void CIKeychainAddUniqueRow(NSMutableArray<NSDictionary *> *out, NSDictionary *row) {
    if (![row isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSString *sig = [NSString stringWithFormat:@"%@|%@|%@|%@",
                     row[@"class"] ?: @"",
                     row[@"service"] ?: @"",
                     row[@"account"] ?: @"",
                     row[@"accessGroup"] ?: @""];
    for (NSDictionary *old in out) {
        NSString *osig = [NSString stringWithFormat:@"%@|%@|%@|%@",
                          old[@"class"] ?: @"",
                          old[@"service"] ?: @"",
                          old[@"account"] ?: @"",
                          old[@"accessGroup"] ?: @""];
        if ([osig isEqualToString:sig]) {
            return;
        }
    }
    [out addObject:row];
}

static NSArray<NSDictionary *> *CIKeychainCopyItemsFiltered(id secClass, NSDictionary *extra, BOOL withData) {
    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: secClass,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecReturnData: @(withData),
        (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
    } mutableCopy];
    [query addEntriesFromDictionary:extra ?: @{}];
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) {
        if (result) {
            CFRelease(result);
        }
        [query removeObjectForKey:(__bridge id)kSecAttrSynchronizable];
        result = NULL;
        status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    }
    if (status != errSecSuccess || !result) {
        if (result) {
            CFRelease(result);
        }
        return @[];
    }
    NSArray *items = CFBridgingRelease(result);
    return [items isKindOfClass:[NSArray class]] ? items : @[];
}

static NSArray<NSDictionary *> *CIKeychainDumpForBundle(NSString *bundleID) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSArray *classes = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword
    ];
    for (id cls in classes) {
        NSArray *items = CIKeychainCopyItems(cls, YES);
        if (items.count == 0) {
            items = CIKeychainCopyItems(cls, NO);
        }
        for (NSDictionary *item in items) {
            if (!CIKeychainItemMatchesBundle(item, bundleID)) {
                continue;
            }
            CIKeychainAddUniqueRow(out, CIKeychainRowFromItem(cls, item));
        }
        for (NSString *service in CIKnownKeychainServices(bundleID)) {
            NSArray *more = CIKeychainCopyItemsFiltered(cls, @{(__bridge id)kSecAttrService: service}, YES);
            if (more.count == 0) {
                more = CIKeychainCopyItemsFiltered(cls, @{(__bridge id)kSecAttrService: service}, NO);
            }
            for (NSDictionary *item in more) {
                CIKeychainAddUniqueRow(out, CIKeychainRowFromItem(cls, item));
            }
        }
    }
    LSApplicationProxy *proxy = CIProxy(bundleID);
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
    }
    [groups addObject:bundleID];
    NSString *low = bundleID.lowercaseString;
    if ([low hasPrefix:@"com.facebook."] || [low containsString:@"facebook"]) {
        [groups addObjectsFromArray:@[
            @"com.facebook.Facebook",
            @"group.com.facebook.Facebook",
            @"group.com.facebook.family",
            @"group.com.facebook.Messenger",
            @"43AQTK3442.com.facebook.Facebook",
            @"43AQTK3442.com.facebook.internal",
            @"43AQTK3442.com.facebook.Messenger"
        ]];
    }
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *group in groups) {
        if ([seen containsObject:group] || [group hasSuffix:@".*"]) {
            continue;
        }
        [seen addObject:group];
        for (id cls in classes) {
            NSArray *items = CIKeychainCopyItemsFiltered(cls, @{(__bridge id)kSecAttrAccessGroup: group}, YES);
            if (items.count == 0) {
                items = CIKeychainCopyItemsFiltered(cls, @{(__bridge id)kSecAttrAccessGroup: group}, NO);
            }
            for (NSDictionary *item in items) {
                if (!CIKeychainItemMatchesBundle(item, bundleID) &&
                    !CIKeychainTextMatchesBundle(group, bundleID)) {
                    continue;
                }
                CIKeychainAddUniqueRow(out, CIKeychainRowFromItem(cls, item));
            }
        }
    }
    return out;
}

static NSUInteger CIKeychainRestoreItems(NSArray *rows) {
    if (![rows isKindOfClass:[NSArray class]]) {
        return 0;
    }
    NSUInteger added = 0;
    for (NSDictionary *row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        id cls = CISecClassFromName(row[@"class"]);
        NSMutableDictionary *add = [NSMutableDictionary dictionary];
        add[(__bridge id)kSecClass] = cls;
        NSDictionary *map = @{
            @"service": (__bridge id)kSecAttrService,
            @"account": (__bridge id)kSecAttrAccount,
            @"accessGroup": (__bridge id)kSecAttrAccessGroup,
            @"label": (__bridge id)kSecAttrLabel,
            @"server": (__bridge id)kSecAttrServer,
            @"protocol": (__bridge id)kSecAttrProtocol,
            @"path": (__bridge id)kSecAttrPath,
            @"accessible": (__bridge id)kSecAttrAccessible
        };
        [map enumerateKeysAndObjectsUsingBlock:^(NSString *key, id secKey, BOOL *stop) {
            (void)stop;
            id value = row[key];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                add[secKey] = value;
            }
        }];
        if ([row[@"port"] isKindOfClass:[NSNumber class]]) {
            add[(__bridge id)kSecAttrPort] = row[@"port"];
        }
        if ([row[@"synchronizable"] isKindOfClass:[NSNumber class]]) {
            add[(__bridge id)kSecAttrSynchronizable] = row[@"synchronizable"];
        }
        NSString *data64 = row[@"data"];
        if ([data64 isKindOfClass:[NSString class]] && data64.length > 0) {
            NSData *data = [[NSData alloc] initWithBase64EncodedString:data64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (data.length > 0) {
                add[(__bridge id)kSecValueData] = data;
            }
        }
        NSString *generic64 = row[@"generic"];
        if ([generic64 isKindOfClass:[NSString class]] && generic64.length > 0) {
            NSData *generic = [[NSData alloc] initWithBase64EncodedString:generic64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (generic.length > 0) {
                add[(__bridge id)kSecAttrGeneric] = generic;
            }
        }
        if (!add[(__bridge id)kSecAttrAccessible]) {
            add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        }
        NSString *agrp = row[@"accessGroup"];
        if ([agrp isKindOfClass:[NSString class]] && [agrp.lowercaseString hasPrefix:@"com.apple."] &&
            ![agrp.lowercaseString containsString:@"facebook"] &&
            ![agrp.lowercaseString containsString:@"shopee"]) {
            continue;
        }
        NSMutableDictionary *del = [add mutableCopy];
        [del removeObjectForKey:(__bridge id)kSecValueData];
        [del removeObjectForKey:(__bridge id)kSecAttrAccessible];
        del[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
        SecItemDelete((__bridge CFDictionaryRef)del);
        OSStatus status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
        if (status == errSecDuplicateItem) {
            SecItemDelete((__bridge CFDictionaryRef)del);
            status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
        }
        if (status == errSecSuccess) {
            added += 1;
        }
    }
    return added;
}

static BOOL CIGroupAlwaysWipe(NSString *group, NSString *bundleID) {
    NSString *glow = group.lowercaseString;
    NSString *blow = bundleID.lowercaseString;
    if ([blow hasPrefix:@"com.facebook."] || [blow hasPrefix:@"com.meta."]) {
        return [glow containsString:@"facebook"] || [glow containsString:@"messenger"];
    }
    if ([blow containsString:@"shopee"] || [blow hasPrefix:@"com.beeasy."]) {
        return [glow containsString:@"shopee"] || [glow containsString:@"beeasy"];
    }
    return NO;
}

static NSArray<NSString *> *CISupportPathsForBundle(NSString *bundleID) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSArray<NSString *> *roots = @[
        @"/var/mobile/Library/Application Support",
        @"/private/var/mobile/Library/Application Support"
    ];
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithObject:bundleID];
    NSString *low = bundleID.lowercaseString;
    if ([low hasPrefix:@"com.facebook."] || [low containsString:@"facebook"]) {
        [names addObjectsFromArray:@[@"Facebook", @"com.facebook.Facebook", @"com.facebook.Messenger"]];
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."]) {
        [names addObjectsFromArray:@[@"Shopee", bundleID]];
    }
    for (NSString *root in roots) {
        for (NSString *name in names) {
            [paths addObject:[root stringByAppendingPathComponent:name]];
        }
    }
    return paths;
}

static NSArray<NSString *> *CIKnownKeychainServices(NSString *bundleID) {
    NSString *low = bundleID.lowercaseString;
    if ([low hasPrefix:@"com.facebook."] || [low hasPrefix:@"com.meta."] || [low containsString:@"facebook"]) {
        return @[
            @"com.facebook.sdk:TokenInformation",
            @"com.facebook.sdk.TokenInformation",
            @"com.facebook.sdk.TokenInformationV2",
            @"com.facebook.sdk:FBSDKAccessToken",
            @"com.facebook.sdk.accessToken",
            @"FBSDKAccessToken",
            @"FBSDKAuthenticationToken",
            @"FBSDKAccessTokenInformation",
            @"com.facebook.auth.token",
            @"com.facebook.auth.oauth",
            @"com.facebook.Facebook",
            @"com.facebook.Messenger",
            @"com.facebook.sdk:AnonymousID",
            @"com.facebook.sdk.anonid",
            @"com.facebook.sdk.login",
            @"com.facebook.accountstore",
            @"FBAccessTokenInformationKey",
            @"kFacebookSDKAccessTokenKey"
        ];
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."]) {
        return @[
            @"ShopeeAccessToken",
            @"shopee_session",
            @"com.shopee.account",
            @"com.shopee.vn",
            @"com.beeasy.marketplace.vn"
        ];
    }
    return bundleID.length ? @[ bundleID ] : @[];
}

static void CIWipeKnownKeychainServices(NSString *bundleID) {
    NSArray<NSString *> *services = CIKnownKeychainServices(bundleID);
    NSArray *classes = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword
    ];
    for (NSString *service in services) {
        for (id cls in classes) {
            NSDictionary *query = @{
                (__bridge id)kSecClass: cls,
                (__bridge id)kSecAttrService: service,
                (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
            };
            SecItemDelete((__bridge CFDictionaryRef)query);
        }
    }
    NSString *low = bundleID.lowercaseString;
    if ([low hasPrefix:@"com.facebook."] || [low containsString:@"facebook"]) {
        NSArray<NSString *> *servers = @[
            @"facebook.com", @"m.facebook.com", @"graph.facebook.com", @"www.facebook.com"
        ];
        for (NSString *server in servers) {
            for (id cls in classes) {
                NSDictionary *query = @{
                    (__bridge id)kSecClass: cls,
                    (__bridge id)kSecAttrServer: server,
                    (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
                };
                SecItemDelete((__bridge CFDictionaryRef)query);
            }
        }
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
            @"group.com.facebook.Messenger",
            @"group.com.facebook.Facebook.widget",
            @"group.com.facebook.mlite",
            @"group.com.facebook.platform",
            @"43AQTK3442.com.facebook.Facebook",
            @"43AQTK3442.com.facebook.internal",
            @"43AQTK3442.com.facebook.Messenger"
        ]];
    }
    if ([bundleID.lowercaseString containsString:@"shopee"] || [bundleID.lowercaseString hasPrefix:@"com.beeasy."]) {
        [groups addObjectsFromArray:@[
            @"group.com.shopee.vn",
            @"group.com.shopee.SG",
            @"group.com.beeasy.marketplace.vn"
        ]];
    }
    if (ChengIOSBundleIsSafari(bundleID)) {
        [groups addObjectsFromArray:@[
            @"com.apple.mobilesafari",
            @"group.com.apple.Safari",
            @"group.com.apple.safari"
        ]];
    }
    id appID = ents[@"application-identifier"];
    NSString *team = CITeamIDFromAppID([appID isKindOfClass:[NSString class]] ? appID : nil);
    if (team.length > 0) {
        [groups addObject:[NSString stringWithFormat:@"%@.%@", team, bundleID]];
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
        if ([group hasSuffix:@".*"]) {
            continue;
        }
        if ([low hasPrefix:@"com.apple."] && ![low containsString:bundleID.lowercaseString] && !ChengIOSBundleIsSafari(bundleID)) {
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
    CIWipeKnownKeychainServices(bundleID);
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
    NSUInteger keychainCount = 0;
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
            CITerminateRelatedBundles(bundleID);
        }
        [NSThread sleepForTimeInterval:1.2];
        CIRunKillall(@"cfprefsd");
        [NSThread sleepForTimeInterval:0.25];
        for (NSString *bundleID in targets) {
            if (![bundleID isKindOfClass:[NSString class]] || ChengIOSBundleIsProtected(bundleID)) {
                continue;
            }
            NSString *dataPath = CIDataPath(bundleID);
            NSDictionary *groups = CIGroupPaths(bundleID);
            NSDictionary *plugins = CIPluginPaths(bundleID);
            NSArray *keychain = CIKeychainDumpForBundle(bundleID);
            if (dataPath.length == 0 && groups.count == 0 && plugins.count == 0 && keychain.count == 0) {
                [failedBundles addObject:bundleID];
                continue;
            }
            NSString *appDir = [[dir stringByAppendingPathComponent:@"apps"] stringByAppendingPathComponent:bundleID];
            [[NSFileManager defaultManager] createDirectoryAtPath:appDir withIntermediateDirectories:YES attributes:nil error:nil];
            if (dataPath.length > 0) {
                bytes += CIBackupContainer(dataPath, [appDir stringByAppendingPathComponent:@"data"]);
            }
            for (NSString *group in groups) {
                bytes += CIBackupContainer(groups[group], [[appDir stringByAppendingPathComponent:@"groups"] stringByAppendingPathComponent:group]);
            }
            for (NSString *pluginID in plugins) {
                bytes += CIBackupContainer(plugins[pluginID], [[appDir stringByAppendingPathComponent:@"plugins"] stringByAppendingPathComponent:pluginID]);
            }
            if (keychain.count > 0) {
                NSString *kcPath = [appDir stringByAppendingPathComponent:@"keychain.plist"];
                [keychain writeToFile:kcPath atomically:YES];
                keychainCount += keychain.count;
            }
            if (ChengIOSBundleIsSafari(bundleID)) {
                CIKillSafariProcesses();
                bytes += CICopyTree(@"/var/mobile/Library/Safari", [appDir stringByAppendingPathComponent:@"safari-library"]);
                bytes += CICopyTree(@"/var/mobile/Library/Cookies", [appDir stringByAppendingPathComponent:@"cookies"]);
                bytes += CICopyTree(@"/var/mobile/Library/WebKit", [appDir stringByAppendingPathComponent:@"webkit"]);
                bytes += CICopyTree(@"/var/mobile/Library/HTTPStorages", [appDir stringByAppendingPathComponent:@"httpstorages"]);
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
        @"version": @"1.2.16",
        @"includeAppData": @(includeAppData),
        @"bundles": savedBundles,
        @"failedBundles": failedBundles,
        @"bytes": @(bytes),
        @"keychainItems": @(keychainCount),
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
            CITerminateRelatedBundles(bundleID);
        }
        [NSThread sleepForTimeInterval:1.2];
        CIRunKillall(@"cfprefsd");
        [NSThread sleepForTimeInterval:0.25];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *bundleID in bundles) {
            if (![bundleID isKindOfClass:[NSString class]] ||
                [bundleID containsString:@"/"] || [bundleID containsString:@".."] ||
                ChengIOSBundleIsProtected(bundleID)) {
                continue;
            }
            NSString *appDir = [appsDir stringByAppendingPathComponent:bundleID];
            NSString *live = CIDataPath(bundleID);
            if (live.length > 0) {
                NSString *savedData = [appDir stringByAppendingPathComponent:@"data"];
                CIRestoreContainer(savedData, live);
            }
            NSString *groupsDir = [appDir stringByAppendingPathComponent:@"groups"];
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
                CIRestoreContainer([groupsDir stringByAppendingPathComponent:groupID], dest);
            }
            NSString *pluginsDir = [appDir stringByAppendingPathComponent:@"plugins"];
            NSArray<NSString *> *pluginIDs = [fm contentsOfDirectoryAtPath:pluginsDir error:nil];
            NSDictionary *livePlugins = CIPluginPaths(bundleID);
            for (NSString *pluginID in pluginIDs) {
                NSString *dest = livePlugins[pluginID];
                if (dest.length == 0) {
                    dest = CIScanContainer(@[
                        @"/var/mobile/Containers/Data/PluginKitPlugin",
                        @"/private/var/mobile/Containers/Data/PluginKitPlugin"
                    ], pluginID);
                }
                if (dest.length == 0) {
                    continue;
                }
                CIRestoreContainer([pluginsDir stringByAppendingPathComponent:pluginID], dest);
            }
            if (ChengIOSBundleIsSafari(bundleID)) {
                CIKillSafariProcesses();
                NSDictionary *safariMap = @{
                    @"safari-library": @"/var/mobile/Library/Safari",
                    @"cookies": @"/var/mobile/Library/Cookies",
                    @"webkit": @"/var/mobile/Library/WebKit",
                    @"httpstorages": @"/var/mobile/Library/HTTPStorages"
                };
                [safariMap enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *dest, BOOL *stop) {
                    (void)stop;
                    NSString *saved = [appDir stringByAppendingPathComponent:name];
                    if (![fm fileExistsAtPath:saved] || !CIPathSafeToMutate(dest)) {
                        return;
                    }
                    CIWipeContents(dest);
                    CICopyTree(saved, dest);
                    CIChownTree(dest);
                }];
            }
            NSArray *keychain = [NSArray arrayWithContentsOfFile:[appDir stringByAppendingPathComponent:@"keychain.plist"]];
            if (keychain.count > 0) {
                CIWipeKeychainForProxy(CIProxy(bundleID), bundleID);
                CIKeychainRestoreItems(keychain);
            }
            CISettleAfterDisk(bundleID);
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
    for (NSString *other in CICompanionBundleIDs(bundleID)) {
        CITerminateBundle(other);
    }
    if (ChengIOSBundleIsSafari(bundleID)) {
        CIKillSafariProcesses();
    }
}

static BOOL CIEraseOne(NSString *bundleID, NSArray<NSString *> *together) {
    if (ChengIOSBundleIsProtected(bundleID)) {
        return NO;
    }
    CISettleForDisk(bundleID);
    BOOL ok = NO;
    NSString *dataPath = CIDataPath(bundleID);
    if (dataPath.length > 0) {
        ok = CIEmptyContainer(dataPath) || ok;
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
                ok = CIEmptyContainer(extraData) || ok;
            }
        }
    }

    if ([bundleID.lowercaseString hasPrefix:@"com.facebook."] || [bundleID.lowercaseString hasPrefix:@"com.meta."]) {
        for (NSString *other in CICompanionBundleIDs(bundleID)) {
            if ([together containsObject:other]) {
                continue;
            }
            CITerminateBundle(other);
            NSString *companionData = CIDataPath(other);
            if (companionData.length > 0) {
                ok = CIEmptyContainer(companionData) || ok;
            }
            CIWipeKeychainForProxy(CIProxy(other), other);
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
        if (!CIGroupAlwaysWipe(group, bundleID) && CIGroupUsedByOtherApps(group, bundleID, together)) {
            continue;
        }
        ok = CIEmptyContainer(groups[group]) || ok;
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
            ok = CIWipeContents(extra) || ok;
        }
    }
    for (NSString *extra in CISupportPathsForBundle(bundleID)) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:extra] && CIPathSafeToMutate(extra)) {
            ok = CIWipeContents(extra) || ok;
        }
    }
    NSDictionary *plugins = CIPluginPaths(bundleID);
    for (NSString *pluginID in plugins) {
        ok = CIEmptyContainer(plugins[pluginID]) || ok;
    }
    if (ChengIOSBundleIsSafari(bundleID)) {
        CIKillSafariProcesses();
        for (NSString *path in CISafariLibraryPaths()) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:path] && CIPathSafeToMutate(path)) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                    BOOL dir = NO;
                    [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir];
                    if (dir) {
                        ok = CIWipeContents(path) || ok;
                    } else {
                        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                        ok = YES;
                    }
                }
            }
        }
    }
    CIRunKillall(@"cfprefsd");
    [NSThread sleepForTimeInterval:0.15];
    CIReemptyPrefs(dataPath);
    for (NSString *group in groups) {
        CIReemptyPrefs(groups[group]);
    }
    for (NSString *pluginID in plugins) {
        CIReemptyPrefs(plugins[pluginID]);
    }
    for (NSString *extra in CIExtraWipePaths(bundleID)) {
        if ([extra.lowercaseString containsString:@"/library/preferences/"] && CIPathSafeToMutate(extra)) {
            CIWipeContents(extra);
        }
    }
    CIWipeKeychainForProxy(CIProxy(bundleID), bundleID);
    CISettleAfterDisk(bundleID);
    return ok;
}

NSDictionary *ChengIOSEraseBundles(NSArray<NSString *> *bundleIDs, NSError **error) {
    NSMutableArray *ok = [NSMutableArray array];
    NSMutableArray *failed = [NSMutableArray array];
    NSMutableArray *skipped = [NSMutableArray array];
    NSArray<NSString *> *targets = bundleIDs.count ? bundleIDs : ChengIOSUserSelectedBundleIDs();
    if (targets.count == 0) {
        if (error) {
            *error = CIError(5, @"Chua chon app nao (tru app he thong / jailbreak).");
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

NSArray<NSString *> *ChengIOSInstalledUserBundleIDs(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    id ws = [wsClass respondsToSelector:@selector(defaultWorkspace)] ? [wsClass defaultWorkspace] : nil;
    if (![ws respondsToSelector:@selector(allInstalledApplications)]) {
        return out;
    }
    for (id app in [ws allInstalledApplications]) {
        NSString *ident = nil;
        if ([app respondsToSelector:@selector(applicationIdentifier)]) {
            ident = [app applicationIdentifier];
        }
        if (ident.length == 0 && [app respondsToSelector:@selector(bundleIdentifier)]) {
            ident = [app bundleIdentifier];
        }
        if (ident.length == 0 || [seen containsObject:ident]) {
            continue;
        }
        if (ChengIOSBundleIsProtected(ident)) {
            continue;
        }
        NSString *type = nil;
        if ([app respondsToSelector:@selector(applicationType)]) {
            type = [app applicationType];
        }
        NSString *path = nil;
        if ([app respondsToSelector:@selector(bundleURL)]) {
            path = [[app bundleURL] path];
        }
        BOOL user = [type caseInsensitiveCompare:@"User"] == NSOrderedSame;
        if (!user && [path containsString:@"/Containers/Bundle/Application/"]) {
            user = YES;
        }
        if (!user) {
            continue;
        }
        [seen addObject:ident];
        [out addObject:ident];
    }
    [out sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return out;
}

NSDictionary *ChengIOSEraseSafari(NSError **error) {
    (void)error;
    NSMutableArray *ok = [NSMutableArray array];
    NSMutableArray *failed = [NSMutableArray array];
    NSArray<NSString *> *targets = @[@"com.apple.mobilesafari", @"com.apple.SafariViewService"];
    for (NSString *bundleID in targets) {
        if (CIEraseOne(bundleID, targets)) {
            [ok addObject:bundleID];
        } else if (ChengIOSBundleIsSafari(bundleID)) {
            CIKillSafariProcesses();
            BOOL any = NO;
            for (NSString *path in CISafariLibraryPaths()) {
                if (![[NSFileManager defaultManager] fileExistsAtPath:path] || !CIPathSafeToMutate(path)) {
                    continue;
                }
                BOOL dir = NO;
                [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir];
                if (dir) {
                    any = CIWipeContents(path) || any;
                } else {
                    any = [[NSFileManager defaultManager] removeItemAtPath:path error:nil] || any;
                }
            }
            if (any) {
                [ok addObject:bundleID];
            } else {
                [failed addObject:bundleID];
            }
        } else {
            [failed addObject:bundleID];
        }
    }
    return @{@"ok": ok, @"failed": failed, @"skipped": @[]};
}

NSDictionary *ChengIOSEraseDeviceApps(BOOL includeSafari, NSError **error) {
    NSMutableArray<NSString *> *targets = [ChengIOSInstalledUserBundleIDs() mutableCopy];
    if (includeSafari) {
        for (NSString *safari in @[@"com.apple.mobilesafari", @"com.apple.SafariViewService"]) {
            if (![targets containsObject:safari]) {
                [targets addObject:safari];
            }
        }
    }
    NSDictionary *result = ChengIOSEraseBundles(targets, error);
    if (includeSafari) {
        NSDictionary *safari = ChengIOSEraseSafari(error);
        NSMutableArray *ok = [result[@"ok"] mutableCopy] ?: [NSMutableArray array];
        NSMutableArray *failed = [result[@"failed"] mutableCopy] ?: [NSMutableArray array];
        for (NSString *item in safari[@"ok"]) {
            if (![ok containsObject:item]) {
                [ok addObject:item];
            }
        }
        for (NSString *item in safari[@"failed"]) {
            if (![failed containsObject:item] && ![ok containsObject:item]) {
                [failed addObject:item];
            }
        }
        return @{@"ok": ok, @"failed": failed, @"skipped": result[@"skipped"] ?: @[]};
    }
    return result;
}

NSDictionary *ChengIOSEraseThenRandom(NSArray<NSString *> *bundleIDs, BOOL allDevice, BOOL randomAll, NSString *region, NSError **error) {
    NSDictionary *erase = allDevice ? ChengIOSEraseDeviceApps(YES, error) : ChengIOSEraseBundles(bundleIDs.count ? bundleIDs : ChengIOSUserSelectedBundleIDs(), error);
    NSDictionary *profile = nil;
    if (region.length > 0) {
        profile = ChengIOSRandomFullProfileInRegion(region);
    } else if (randomAll) {
        profile = ChengIOSRandomFullProfile();
    } else {
        profile = ChengIOSRandomIdentity();
    }
    if (profile.count > 0) {
        ChengIOSApplyProfile(profile);
    }
    return @{
        @"ok": erase[@"ok"] ?: @[],
        @"failed": erase[@"failed"] ?: @[],
        @"skipped": erase[@"skipped"] ?: @[],
        @"profileSummary": ChengIOSProfileSummary(profile) ?: @""
    };
}
