#import "ChengIOSBackup.h"
#import "ChengIOSProfiles.h"

#import <objc/runtime.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#import <Security/Security.h>
#import <sqlite3.h>

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
static BOOL CIPathSafeToMutate(NSString *path);
static NSArray<NSString *> *CIKnownKeychainServices(NSString *bundleID);
static void CIWipeKnownKeychainServices(NSString *bundleID);
static void CISettleForDisk(NSString *bundleID);
static void CISettleAfterDisk(NSString *bundleID);
static NSDictionary<NSString *, NSString *> *CIAllGroupPaths(NSString *bundleID);
static NSDictionary<NSString *, NSString *> *CIScanContainersMatching(NSArray<NSString *> *roots, BOOL (^pred)(NSString *ident));
static void CIKeychainSQLSettle(void);

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
    return @[ @"Documents", @"Library", @"tmp", @"SystemData", @"StoreKit" ];
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
    NSString *type = attrs.fileType;
    if ([type isEqualToString:NSFileTypeDirectory]) {
        NSInteger mode = [path.lastPathComponent isEqualToString:@"tmp"] ? 0777 : 0755;
        [fm setAttributes:@{
            NSFilePosixPermissions: @(mode),
            NSFileOwnerAccountID: @(kCIMobileUID),
            NSFileGroupOwnerAccountID: @(kCIMobileGID)
        } ofItemAtPath:path error:nil];
        for (NSString *name in [fm contentsOfDirectoryAtPath:path error:nil]) {
            CIChownTree([path stringByAppendingPathComponent:name]);
        }
        return;
    }
    if ([type isEqualToString:NSFileTypeRegular]) {
        [fm setAttributes:@{
            NSFilePosixPermissions: @0644,
            NSFileOwnerAccountID: @(kCIMobileUID),
            NSFileGroupOwnerAccountID: @(kCIMobileGID)
        } ofItemAtPath:path error:nil];
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
    if ([low containsString:@"/containers/data/pluginkitplugin/"] && parts.count >= 7) {
        return YES;
    }
    if ([low hasPrefix:@"/var/mobile/library/safari"] || [low hasPrefix:@"/private/var/mobile/library/safari"]) {
        return YES;
    }
    if ([low hasPrefix:@"/var/mobile/library/cookies"] || [low hasPrefix:@"/private/var/mobile/library/cookies"]) {
        return YES;
    }
    if ([low hasPrefix:@"/var/mobile/library/webkit"] || [low hasPrefix:@"/private/var/mobile/library/webkit"]) {
        return YES;
    }
    if ([low hasPrefix:@"/var/mobile/library/httpstorages"] || [low hasPrefix:@"/private/var/mobile/library/httpstorages"]) {
        return YES;
    }
    if ([low containsString:@"/library/safarisafebrowsing"]) {
        return YES;
    }
    if ([low containsString:@"/library/application support/com.facebook"] ||
        [low containsString:@"/library/application support/facebook"] ||
        [low containsString:@"/library/application support/com.shopee"] ||
        [low containsString:@"/library/application support/com.beeasy"] ||
        [low containsString:@"/library/application support/tiktok"] ||
        [low containsString:@"/library/application support/musically"] ||
        [low containsString:@"/library/application support/aweme"] ||
        [low containsString:@"/library/application support/com.zhiliao"] ||
        [low containsString:@"/library/application support/bytedance"]) {
        return parts.count >= 6;
    }
    return NO;
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
    if ([low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
        [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"musically"] ||
        [low containsString:@"aweme"]) {
        CIRunKillall(@"TikTok");
        CIRunKillall(@"Musical.ly");
        CIRunKillall(@"Aweme");
        CIRunKillall(@"trill");
    }
    [NSThread sleepForTimeInterval:0.9];
    CIRunKillall(@"cfprefsd");
    [NSThread sleepForTimeInterval:0.25];
}

static void CISettleAfterDisk(NSString *bundleID) {
    CIRunKillall(@"cfprefsd");
    CIRunKillall(@"securityd");
    CIRunKillall(@"secd");
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
    NSString *low = bundleID.lowercaseString;
    NSArray<NSString *> *prefRoots = @[
        @"/var/mobile/Library/Preferences",
        @"/private/var/mobile/Library/Preferences"
    ];
    NSMutableArray<NSString *> *extraNames = [NSMutableArray array];
    if ([low hasPrefix:@"com.facebook."] || [low hasPrefix:@"com.meta."] || [low containsString:@"facebook"]) {
        [extraNames addObjectsFromArray:@[
            @"com.apple.account.Facebook.plist",
            @"com.apple.account.facebook.plist",
            @"group.com.facebook.Facebook.plist",
            @"group.com.facebook.family.plist",
            @"group.com.facebook.Messenger.plist",
            @"group.com.facebook.msysstorage.plist",
            @"group.com.facebook.platform.plist",
            @"group.com.metaplatforms.family.plist"
        ]];
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."]) {
        [extraNames addObjectsFromArray:@[
            @"group.com.shopee.vn.plist",
            @"group.com.beeasy.marketplace.vn.plist"
        ]];
    }
    if ([low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
        [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"aweme"]) {
        [extraNames addObjectsFromArray:@[
            @"group.com.zhiliaoapp.musically.plist",
            @"com.zhiliaoapp.musically.plist",
            @"com.zhiliaoapp.musically.go.plist"
        ]];
    }
    for (NSString *prefRoot in prefRoots) {
        for (NSString *name in extraNames) {
            [paths addObject:[prefRoot stringByAppendingPathComponent:name]];
        }
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
        @[@"com.facebook.", @"com.meta."],
        @[@"com.burbn.", @"com.instagram."],
        @[@"net.whatsapp."],
        @[@"com.shopee.", @"com.beeasy.", @"com.sgs."],
        @[@"com.zhiliaoapp.", @"com.ss.iphone.", @"com.bytedance."]
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

static BOOL CIBundleIsFacebookFamily(NSString *bundleID) {
    NSString *low = bundleID.lowercaseString;
    return [low hasPrefix:@"com.facebook."] || [low hasPrefix:@"com.meta."] || [low containsString:@"facebook"];
}

static BOOL CIBundleIsInstagramFamily(NSString *bundleID) {
    NSString *low = bundleID.lowercaseString;
    return [low hasPrefix:@"com.burbn."] || [low containsString:@"instagram"] || [low containsString:@"threads"];
}

static BOOL CIBundleIsWhatsAppFamily(NSString *bundleID) {
    return [bundleID.lowercaseString containsString:@"whatsapp"];
}

static BOOL CIKeychainAgrpIsForeignMeta(NSString *agrp, NSString *bundleID) {
    NSString *low = agrp.lowercaseString ?: @"";
    if (low.length == 0) {
        return NO;
    }
    if (CIBundleIsFacebookFamily(bundleID) && !CIBundleIsInstagramFamily(bundleID) && !CIBundleIsWhatsAppFamily(bundleID)) {
        if ([low containsString:@"instagram"] || [low containsString:@"burbn"] ||
            [low containsString:@"whatsapp"] || [low containsString:@"threads"]) {
            return YES;
        }
    }
    if (CIBundleIsInstagramFamily(bundleID) && ([low containsString:@"whatsapp"])) {
        return YES;
    }
    if (CIBundleIsWhatsAppFamily(bundleID) &&
        ([low containsString:@"instagram"] || [low containsString:@"burbn"] || [low containsString:@"threads"])) {
        return YES;
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
    if (CIBundleIsFacebookFamily(bundleID) && !CIBundleIsInstagramFamily(bundleID) && !CIBundleIsWhatsAppFamily(bundleID)) {
        NSArray<NSString *> *needles = @[
            @"facebook", @"fbauth", @"fbsdk", @"fb_user", @"fb-token", @"fbssoservice",
            @"fbssologin", @"fbsso", @"fb_session", @"fbaccesstoken",
            @"com.facebook", @"group.com.facebook", @"43aqtk3442.com.facebook",
            @"messenger.com", @"fb.com", @"facebook.com",
            @"dbl", @"devicebasedlogin", @"device_based_login", @"savedaccount",
            @"saved_account", @"accountswitcher", @"account_switcher", @"fbsaved",
            @"fbsaveduser", @"fbaccountstore", @"msysstorage", @"metaplatforms",
            @"continueas", @"lastloggedin", @"last_user"
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
    if ([low hasPrefix:@"com.apple."]) {
        if (ChengIOSBundleIsSafari(bundleID)) {
            return [blob containsString:@"safari"] || [blob containsString:@"webkit"] || [blob containsString:@"mobilesafari"];
        }
        return NO;
    }
    if ([low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
        [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"musically"] ||
        [low containsString:@"aweme"] || [low containsString:@"bytedance"]) {
        NSArray<NSString *> *needles = @[
            @"tiktok", @"musically", @"zhiliao", @"aweme", @"bytedance",
            @"musical.ly", @"ttaccount", @"tt_token", @"tt_passport",
            @"aweme_passport", @"com.zhiliaoapp", @"com.ss.iphone",
            @"group.com.zhiliaoapp"
        ];
        for (NSString *needle in needles) {
            if ([blob containsString:needle]) {
                return YES;
            }
        }
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

static void CIKeychainSQLSettle(void);
static BOOL CIKeychainAgrpIsForeignMeta(NSString *agrp, NSString *bundleID);
static BOOL CIKeychainAgrpMatchesBundle(NSString *agrp, NSString *bundleID);

static BOOL CIKeychainAgrpMatchesBundle(NSString *agrp, NSString *bundleID) {
    NSString *low = agrp.lowercaseString ?: @"";
    if (low.length == 0 || CIKeychainAgrpIsForeignMeta(agrp, bundleID)) {
        return NO;
    }
    if ([low containsString:bundleID.lowercaseString]) {
        return YES;
    }
    if (CIBundleIsFacebookFamily(bundleID) && !CIBundleIsInstagramFamily(bundleID) && !CIBundleIsWhatsAppFamily(bundleID)) {
        if ([low hasPrefix:@"43aqtk3442.com.facebook"]) {
            return YES;
        }
        if ([low containsString:@"com.facebook"] || [low containsString:@"msysstorage"] ||
            [low containsString:@"metaplatforms"]) {
            return YES;
        }
        if ([low containsString:@"messenger"] && ![low containsString:@"instagram"]) {
            return YES;
        }
        return NO;
    }
    return CIKeychainTextMatchesBundle(low, bundleID);
}

static BOOL CIIsRootProcess(void) {
    return geteuid() == 0;
}

static BOOL CIInHelperProcess(void) {
    return getenv("CHENG_ROOT_HELPER") != NULL;
}

static BOOL CIInDaemonProcess(void) {
    return getenv("CHENG_DAEMON") != NULL;
}

static NSString *CIWorkRootDir(BOOL create) {
    return CIFirstExistingDir(@[
        @"/var/mobile/Media/ChengIOS/.work",
        @"/private/var/mobile/Media/ChengIOS/.work"
    ], create);
}

static NSString *CIInboxDir(BOOL create) {
    NSString *root = CIWorkRootDir(create);
    if (root.length == 0) {
        return nil;
    }
    NSString *inbox = [root stringByAppendingPathComponent:@"inbox"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:inbox withIntermediateDirectories:YES attributes:nil error:nil];
    const char *raw = inbox.fileSystemRepresentation;
    if (raw) {
        chmod(raw, 0777);
    }
    const char *rootRaw = root.fileSystemRepresentation;
    if (rootRaw) {
        chmod(rootRaw, 0777);
    }
    return inbox;
}

static void CIChmodWorld(NSString *path, int mode) {
    if (path.length == 0) {
        return;
    }
    const char *raw = path.fileSystemRepresentation;
    if (raw) {
        chmod(raw, mode);
        lchown(raw, kCIMobileUID, kCIMobileGID);
    }
}

static BOOL CIDaemonIsAlive(void) {
    NSString *root = CIWorkRootDir(NO);
    if (root.length == 0) {
        return NO;
    }
    NSString *path = [root stringByAppendingPathComponent:@"daemon.alive"];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate *mod = attrs[NSFileModificationDate];
    if (![mod isKindOfClass:[NSDate class]]) {
        return NO;
    }
    return [[NSDate date] timeIntervalSinceDate:mod] < 8.0;
}

static NSString *CIRootHelperPath(void) {
    NSArray<NSString *> *cands = @[
        @"/var/jb/usr/local/bin/chengiosroot",
        @"/usr/local/bin/chengiosroot",
        @"/var/jb/usr/bin/chengiosroot",
        @"/usr/bin/chengiosroot"
    ];
    for (NSString *path in cands) {
        if (access(path.fileSystemRepresentation, X_OK) == 0) {
            return path;
        }
    }
    return nil;
}

static NSDictionary *CISpawnHelperOp(NSDictionary *input, NSError **error) {
    NSString *helper = CIRootHelperPath();
    if (helper.length == 0) {
        return nil;
    }
    NSString *op = input[@"op"];
    if (op.length == 0) {
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *work = CIInboxDir(YES);
    if (work.length == 0) {
        work = [ChengIOSBackupRoot() stringByAppendingPathComponent:@".work"];
        [fm createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *stamp = [NSString stringWithFormat:@"%ld-%u", (long)[[NSDate date] timeIntervalSince1970], arc4random()];
    NSString *inPath = [work stringByAppendingPathComponent:[stamp stringByAppendingString:@"-spawn-in.plist"]];
    NSString *outPath = [work stringByAppendingPathComponent:[stamp stringByAppendingString:@"-spawn-out.plist"]];
    if (![input writeToFile:inPath atomically:YES]) {
        if (error) {
            *error = CIError(2, @"Khong ghi duoc input cho root helper.");
        }
        return @{@"ok": @NO, @"error": @"input"};
    }
    CIChmodWorld(inPath, 0666);
    pid_t pid = 0;
    const char *args[] = {
        helper.UTF8String,
        op.UTF8String,
        inPath.fileSystemRepresentation,
        outPath.fileSystemRepresentation,
        NULL
    };
    NSMutableArray<NSString *> *envLines = [NSMutableArray array];
    if (environ) {
        for (char **e = environ; *e; e++) {
            [envLines addObject:[NSString stringWithUTF8String:*e]];
        }
    }
    [envLines addObject:@"CHENG_ROOT_HELPER=1"];
    char **envp = (char **)calloc(envLines.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < envLines.count; i++) {
        envp[i] = (char *)[envLines[i] UTF8String];
    }
    int spawned = posix_spawn(&pid, helper.fileSystemRepresentation, NULL, NULL, (char *const *)args, envp);
    free(envp);
    if (spawned != 0) {
        [fm removeItemAtPath:inPath error:nil];
        return nil;
    }
    int status = 0;
    waitpid(pid, &status, 0);
    NSDictionary *out = [NSDictionary dictionaryWithContentsOfFile:outPath];
    [fm removeItemAtPath:inPath error:nil];
    [fm removeItemAtPath:outPath error:nil];
    if (![out isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return out;
}

static NSDictionary *CIRunDaemonOp(NSDictionary *input, NSError **error) {
    if (!CIDaemonIsAlive()) {
        [NSThread sleepForTimeInterval:1.2];
    }
    if (!CIDaemonIsAlive()) {
        if (error) {
            *error = CIError(2, @"chengiosroot daemon chua chay. Cai 1.2.19, Respring, mo app ChengIOS.");
        }
        return @{@"ok": @NO, @"uid": @(geteuid()), @"daemon": @NO, @"error": @"daemon not running"};
    }
    NSString *inbox = CIInboxDir(YES);
    if (inbox.length == 0) {
        if (error) {
            *error = CIError(2, @"Khong tao duoc inbox cho root daemon.");
        }
        return @{@"ok": @NO, @"error": @"inbox"};
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *stamp = [NSString stringWithFormat:@"%ld-%u", (long)[[NSDate date] timeIntervalSince1970], arc4random()];
    NSString *inPath = [inbox stringByAppendingPathComponent:[stamp stringByAppendingString:@"-in.plist"]];
    NSString *outPath = [inbox stringByAppendingPathComponent:[stamp stringByAppendingString:@"-out.plist"]];
    if (![input writeToFile:inPath atomically:YES]) {
        if (error) {
            *error = CIError(2, @"Khong ghi duoc job cho root daemon.");
        }
        return @{@"ok": @NO, @"error": @"input"};
    }
    CIChmodWorld(inPath, 0666);
    NSDate *start = [NSDate date];
    while ([[NSDate date] timeIntervalSinceDate:start] < 300.0) {
        NSDictionary *out = [NSDictionary dictionaryWithContentsOfFile:outPath];
        if ([out isKindOfClass:[NSDictionary class]]) {
            [fm removeItemAtPath:inPath error:nil];
            [fm removeItemAtPath:outPath error:nil];
            return out;
        }
        if (!CIDaemonIsAlive()) {
            break;
        }
        [NSThread sleepForTimeInterval:0.25];
    }
    [fm removeItemAtPath:inPath error:nil];
    if (error) {
        *error = CIError(2, @"Root daemon timeout. Facebook data lon: thu lai, giu app ChengIOS mo.");
    }
    return @{@"ok": @NO, @"error": @"daemon timeout", @"daemon": @YES};
}

static NSDictionary *CIRunRootOp(NSDictionary *input, NSError **error) {
    if (CIIsRootProcess() || CIInHelperProcess()) {
        return nil;
    }
    NSDictionary *spawned = CISpawnHelperOp(input, error);
    if ([spawned isKindOfClass:[NSDictionary class]]) {
        NSInteger uid = [spawned[@"uid"] integerValue];
        if (uid == 0) {
            return spawned;
        }
    }
    return CIRunDaemonOp(input, error);
}

static NSString *gCIKeychainSQLLastPath = nil;
static BOOL gCIKeychainSQLLastOpen = NO;
static NSString *gCIKeychainSQLCopyDir = nil;

static NSString *CIKeychainSQLPath(void) {
    NSArray<NSString *> *cands = @[
        @"/var/Keychains/keychain-2.db",
        @"/private/var/Keychains/keychain-2.db"
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in cands) {
        if ([fm fileExistsAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static void CIAddOwnerRW(NSString *path) {
    if (path.length == 0) {
        return;
    }
    const char *raw = path.fileSystemRepresentation;
    if (!raw) {
        return;
    }
    struct stat st;
    if (stat(raw, &st) == 0) {
        chmod(raw, st.st_mode | S_IRUSR | S_IWUSR);
    } else {
        chmod(raw, 0600);
    }
}

static void CIKeychainSQLChmodAll(void) {
    NSString *path = CIKeychainSQLPath();
    if (path.length == 0) {
        return;
    }
    CIAddOwnerRW(path);
    CIAddOwnerRW([path stringByAppendingString:@"-wal"]);
    CIAddOwnerRW([path stringByAppendingString:@"-shm"]);
}

static BOOL CIKeychainSQLAgrpProtected(NSString *agrp, NSString *bundleID) {
    NSString *low = agrp.lowercaseString ?: @"";
    if (low.length == 0) {
        return NO;
    }
    if ([low isEqualToString:@"43aqtk3442"]) {
        return YES;
    }
    NSArray<NSString *> *blocked = @[
        @"apple", @"lockdown-identities", @"com.apple.security.sos",
        @"com.apple.cfnetwork", @"com.apple.identities", @"com.apple.certificates",
        @"protectedcloudstorage", @"com.apple.security.oauth"
    ];
    if ([blocked containsObject:low]) {
        return YES;
    }
    if ([low hasPrefix:@"com.apple."]) {
        if (ChengIOSBundleIsSafari(bundleID) &&
            ([low containsString:@"safari"] || [low containsString:@"webkit"] || [low containsString:@"mobilesafari"])) {
            return NO;
        }
        if (CIKeychainTextMatchesBundle(low, bundleID)) {
            return NO;
        }
        return YES;
    }
    return NO;
}

static sqlite3 *CIKeychainSQLOpenPath(NSString *path, BOOL write) {
    if (path.length == 0) {
        return NULL;
    }
    sqlite3 *db = NULL;
    int flags = write ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY;
    if (sqlite3_open_v2(path.fileSystemRepresentation, &db, flags, NULL) != SQLITE_OK) {
        if (db) {
            sqlite3_close(db);
        }
        return NULL;
    }
    sqlite3_busy_timeout(db, 15000);
    sqlite3_exec(db, "PRAGMA cipher_memory_security = OFF;", NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA wal_checkpoint(PASSIVE);", NULL, NULL, NULL);
    gCIKeychainSQLLastOpen = YES;
    gCIKeychainSQLLastPath = path;
    return db;
}

static sqlite3 *CIKeychainSQLOpen(BOOL write) {
    gCIKeychainSQLLastOpen = NO;
    gCIKeychainSQLLastPath = CIKeychainSQLPath();
    if (gCIKeychainSQLLastPath.length == 0 || geteuid() != 0) {
        return NULL;
    }
    CIKeychainSQLChmodAll();
    CIKeychainSQLSettle();
    if (write) {
        return CIKeychainSQLOpenPath(gCIKeychainSQLLastPath, YES);
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *copyDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"cheng-kc-%d-%u", getpid(), arc4random()]];
    [fm createDirectoryAtPath:copyDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *copyDb = [copyDir stringByAppendingPathComponent:@"keychain-2.db"];
    BOOL copied = [fm copyItemAtPath:gCIKeychainSQLLastPath toPath:copyDb error:nil];
    NSString *wal = [gCIKeychainSQLLastPath stringByAppendingString:@"-wal"];
    NSString *shm = [gCIKeychainSQLLastPath stringByAppendingString:@"-shm"];
    if ([fm fileExistsAtPath:wal]) {
        [fm copyItemAtPath:wal toPath:[copyDb stringByAppendingString:@"-wal"] error:nil];
    }
    if ([fm fileExistsAtPath:shm]) {
        [fm copyItemAtPath:shm toPath:[copyDb stringByAppendingString:@"-shm"] error:nil];
    }
    sqlite3 *db = NULL;
    if (copied) {
        gCIKeychainSQLCopyDir = copyDir;
        db = CIKeychainSQLOpenPath(copyDb, NO);
        if (db) {
            return db;
        }
        gCIKeychainSQLCopyDir = nil;
    }
    [fm removeItemAtPath:copyDir error:nil];
    return CIKeychainSQLOpenPath(gCIKeychainSQLLastPath, NO);
}

static void CIKeychainSQLClose(sqlite3 *db) {
    if (db) {
        sqlite3_close(db);
    }
    if (gCIKeychainSQLCopyDir.length > 0) {
        [[NSFileManager defaultManager] removeItemAtPath:gCIKeychainSQLCopyDir error:nil];
        gCIKeychainSQLCopyDir = nil;
    }
}

static NSDictionary *CIKeychainSQLRowCols(sqlite3_stmt *stmt) {
    NSMutableDictionary *cols = [NSMutableDictionary dictionary];
    int n = sqlite3_column_count(stmt);
    for (int i = 0; i < n; i++) {
        const char *name = sqlite3_column_name(stmt, i);
        if (!name) {
            continue;
        }
        NSString *key = [NSString stringWithUTF8String:name];
        if ([key caseInsensitiveCompare:@"rowid"] == NSOrderedSame) {
            continue;
        }
        int type = sqlite3_column_type(stmt, i);
        if (type == SQLITE_NULL) {
            continue;
        }
        if (type == SQLITE_INTEGER) {
            cols[key] = @(sqlite3_column_int64(stmt, i));
        } else if (type == SQLITE_FLOAT) {
            cols[key] = @(sqlite3_column_double(stmt, i));
        } else if (type == SQLITE_BLOB) {
            const void *blob = sqlite3_column_blob(stmt, i);
            int len = sqlite3_column_bytes(stmt, i);
            if (blob && len > 0) {
                cols[key] = [NSData dataWithBytes:blob length:(NSUInteger)len];
            }
        } else {
            const unsigned char *txt = sqlite3_column_text(stmt, i);
            if (txt) {
                cols[key] = [NSString stringWithUTF8String:(const char *)txt];
            }
        }
    }
    return cols;
}

static NSString *CIKeychainSQLRowBlob(NSDictionary *cols) {
    NSMutableArray *parts = [NSMutableArray array];
    [cols enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
        (void)stop;
        if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]]) {
            [parts addObject:[NSString stringWithFormat:@"%@=%@", key, obj]];
        } else if ([obj isKindOfClass:[NSData class]]) {
            NSData *data = obj;
            if (data.length > 0 && data.length < 4096) {
                NSString *asText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (asText.length > 0) {
                    [parts addObject:asText];
                }
            }
        }
    }];
    return [parts componentsJoinedByString:@" "];
}

static BOOL CIKeychainSQLRowMatchesBundle(NSDictionary *cols, NSString *bundleID) {
    if (![cols isKindOfClass:[NSDictionary class]] || bundleID.length == 0) {
        return NO;
    }
    NSString *agrp = [cols[@"agrp"] isKindOfClass:[NSString class]] ? cols[@"agrp"] : @"";
    if (CIKeychainSQLAgrpProtected(agrp, bundleID)) {
        return NO;
    }
    if (CIKeychainAgrpIsForeignMeta(agrp, bundleID)) {
        return NO;
    }
    if (CIKeychainAgrpMatchesBundle(agrp, bundleID)) {
        return YES;
    }
    return CIKeychainTextMatchesBundle(CIKeychainSQLRowBlob(cols), bundleID);
}


static NSArray<NSString *> *CIKeychainSQLTables(void) {
    return @[@"genp", @"inet", @"keys", @"cert"];
}

static NSArray<NSString *> *CIKeychainSQLListAgrps(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (geteuid() != 0) {
        return out;
    }
    sqlite3 *db = CIKeychainSQLOpen(NO);
    if (!db) {
        return out;
    }
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSArray<NSString *> *tables = CIKeychainSQLTables();
    for (NSString *table in tables) {
        NSString *sql = [NSString stringWithFormat:@"SELECT DISTINCT agrp FROM %@", table];
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
            continue;
        }
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *txt = sqlite3_column_text(stmt, 0);
            if (!txt) {
                continue;
            }
            NSString *agrp = [NSString stringWithUTF8String:(const char *)txt];
            if (agrp.length == 0 || [seen containsObject:agrp]) {
                continue;
            }
            [seen addObject:agrp];
            [out addObject:agrp];
        }
        sqlite3_finalize(stmt);
    }
    CIKeychainSQLClose(db);
    return out;
}

static NSArray<NSDictionary *> *CIKeychainSQLDumpForBundle(NSString *bundleID) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    if (bundleID.length == 0 || geteuid() != 0) {
        return out;
    }
    sqlite3 *db = CIKeychainSQLOpen(NO);
    if (!db) {
        return out;
    }
    NSArray<NSString *> *tables = CIKeychainSQLTables();
    for (NSString *table in tables) {
        NSString *sql = [NSString stringWithFormat:@"SELECT rowid, * FROM %@", table];
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
            continue;
        }
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            NSDictionary *cols = CIKeychainSQLRowCols(stmt);
            if (!CIKeychainSQLRowMatchesBundle(cols, bundleID)) {
                continue;
            }
            [out addObject:@{
                @"source": @"sqlite",
                @"table": table,
                @"cols": cols
            }];
        }
        sqlite3_finalize(stmt);
    }
    CIKeychainSQLClose(db);
    return out;
}

static void CIKeychainSQLSettle(void) {
    CIRunKillall(@"securityd");
    CIRunKillall(@"secd");
    [NSThread sleepForTimeInterval:0.25];
}

static NSUInteger CIKeychainSQLWipeForBundle(NSString *bundleID) {
    if (bundleID.length == 0 || geteuid() != 0) {
        return 0;
    }
    CIKeychainSQLSettle();
    sqlite3 *db = CIKeychainSQLOpen(YES);
    if (!db) {
        return 0;
    }
    NSUInteger removed = 0;
    sqlite3_exec(db, "BEGIN IMMEDIATE;", NULL, NULL, NULL);
    NSArray<NSString *> *tables = CIKeychainSQLTables();
    for (NSString *table in tables) {
        NSString *sql = [NSString stringWithFormat:@"SELECT rowid, * FROM %@", table];
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
            continue;
        }
        NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            sqlite3_int64 rowid = sqlite3_column_int64(stmt, 0);
            NSDictionary *cols = CIKeychainSQLRowCols(stmt);
            if (!CIKeychainSQLRowMatchesBundle(cols, bundleID)) {
                continue;
            }
            [ids addObject:@(rowid)];
        }
        sqlite3_finalize(stmt);
        NSString *del = [NSString stringWithFormat:@"DELETE FROM %@ WHERE rowid=?", table];
        sqlite3_stmt *delStmt = NULL;
        if (sqlite3_prepare_v2(db, del.UTF8String, -1, &delStmt, NULL) != SQLITE_OK) {
            continue;
        }
        for (NSNumber *rid in ids) {
            sqlite3_reset(delStmt);
            sqlite3_clear_bindings(delStmt);
            sqlite3_bind_int64(delStmt, 1, rid.longLongValue);
            if (sqlite3_step(delStmt) == SQLITE_DONE) {
                removed += 1;
            }
        }
        sqlite3_finalize(delStmt);
    }
    sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", NULL, NULL, NULL);
    CIKeychainSQLClose(db);
    CIKeychainSQLSettle();
    return removed;
}

static NSUInteger CIKeychainSQLRestoreRows(NSArray *rows) {
    if (![rows isKindOfClass:[NSArray class]] || geteuid() != 0) {
        return 0;
    }
    CIKeychainSQLSettle();
    sqlite3 *db = CIKeychainSQLOpen(YES);
    if (!db) {
        return 0;
    }
    NSUInteger added = 0;
    sqlite3_exec(db, "BEGIN IMMEDIATE;", NULL, NULL, NULL);
    for (NSDictionary *row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *table = row[@"table"];
        NSDictionary *cols = row[@"cols"];
        if (!([table isEqualToString:@"genp"] || [table isEqualToString:@"inet"] || [table isEqualToString:@"keys"] || [table isEqualToString:@"cert"]) ||
            ![cols isKindOfClass:[NSDictionary class]] || cols.count == 0) {
            continue;
        }
        NSString *agrp = [cols[@"agrp"] isKindOfClass:[NSString class]] ? cols[@"agrp"] : @"";
        NSString *svce = [cols[@"svce"] isKindOfClass:[NSString class]] ? cols[@"svce"] : @"";
        NSString *acct = [cols[@"acct"] isKindOfClass:[NSString class]] ? cols[@"acct"] : @"";
        NSString *labl = [cols[@"labl"] isKindOfClass:[NSString class]] ? cols[@"labl"] : @"";
        NSString *delSql = nil;
        sqlite3_stmt *delStmt = NULL;
        if ([table isEqualToString:@"keys"] || [table isEqualToString:@"cert"]) {
            delSql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE IFNULL(agrp,'')=? AND IFNULL(labl,'')=?", table];
            if (sqlite3_prepare_v2(db, delSql.UTF8String, -1, &delStmt, NULL) == SQLITE_OK) {
                sqlite3_bind_text(delStmt, 1, agrp.UTF8String ?: "", -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(delStmt, 2, labl.UTF8String ?: "", -1, SQLITE_TRANSIENT);
                sqlite3_step(delStmt);
                sqlite3_finalize(delStmt);
            }
        } else {
            delSql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE IFNULL(agrp,'')=? AND IFNULL(svce,'')=? AND IFNULL(acct,'')=?", table];
            if (sqlite3_prepare_v2(db, delSql.UTF8String, -1, &delStmt, NULL) == SQLITE_OK) {
                sqlite3_bind_text(delStmt, 1, agrp.UTF8String ?: "", -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(delStmt, 2, svce.UTF8String ?: "", -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(delStmt, 3, acct.UTF8String ?: "", -1, SQLITE_TRANSIENT);
                sqlite3_step(delStmt);
                sqlite3_finalize(delStmt);
            }
        }
        NSArray *keys = cols.allKeys;
        NSMutableArray *quoted = [NSMutableArray array];
        NSMutableArray *qs = [NSMutableArray array];
        for (NSString *key in keys) {
            [quoted addObject:[NSString stringWithFormat:@"\"%@\"", key]];
            [qs addObject:@"?"];
        }
        NSString *sql = [NSString stringWithFormat:@"INSERT INTO %@ (%@) VALUES (%@)",
                         table,
                         [quoted componentsJoinedByString:@","],
                         [qs componentsJoinedByString:@","]];
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
            continue;
        }
        int bind = 1;
        for (NSString *key in keys) {
            id val = cols[key];
            if ([val isKindOfClass:[NSData class]]) {
                NSData *data = val;
                sqlite3_bind_blob(stmt, bind, data.bytes, (int)data.length, SQLITE_TRANSIENT);
            } else if ([val isKindOfClass:[NSNumber class]]) {
                sqlite3_bind_int64(stmt, bind, [val longLongValue]);
            } else if ([val isKindOfClass:[NSString class]]) {
                sqlite3_bind_text(stmt, bind, [val UTF8String], -1, SQLITE_TRANSIENT);
            } else {
                sqlite3_bind_null(stmt, bind);
            }
            bind += 1;
        }
        if (sqlite3_step(stmt) == SQLITE_DONE) {
            added += 1;
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", NULL, NULL, NULL);
    CIKeychainSQLClose(db);
    CIKeychainSQLSettle();
    return added;
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
    if ([low hasPrefix:@"com.zhiliaoapp.musically"] || [low containsString:@"tiktok"]) {
        return @[
            @"com.zhiliaoapp.musically",
            @"com.zhiliaoapp.musically.go",
            @"com.ss.iphone.ugc.Aweme"
        ];
    }
    if ([low hasPrefix:@"com.ss.iphone.ugc.aweme"] || [low containsString:@"aweme"]) {
        return @[
            @"com.ss.iphone.ugc.Aweme"
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

static NSArray<NSString *> *CIFacebookExtraGroups(void) {
    return @[
        @"group.com.facebook.Facebook",
        @"group.com.facebook.family",
        @"group.com.facebook.Messenger",
        @"group.com.facebook.Facebook.widget",
        @"group.com.facebook.mlite",
        @"group.com.facebook.platform",
        @"group.com.facebook.msysstorage",
        @"group.com.metaplatforms.family"
    ];
}

static NSDictionary<NSString *, NSString *> *CIAllGroupPaths(NSString *bundleID) {
    NSDictionary *baseGroups = CIGroupPaths(bundleID);
    NSMutableDictionary<NSString *, NSString *> *map = [baseGroups mutableCopy];
    if (!map) {
        map = [NSMutableDictionary dictionary];
    }
    NSArray<NSString *> *roots = @[
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/private/var/mobile/Containers/Shared/AppGroup"
    ];
    BOOL fb = CIBundleIsFacebookFamily(bundleID);
    BOOL shopee = [bundleID.lowercaseString containsString:@"shopee"] || [bundleID.lowercaseString hasPrefix:@"com.beeasy."];
    BOOL tiktok = [bundleID.lowercaseString containsString:@"tiktok"] || [bundleID.lowercaseString hasPrefix:@"com.zhiliaoapp."] ||
                  [bundleID.lowercaseString hasPrefix:@"com.ss.iphone."] || [bundleID.lowercaseString containsString:@"aweme"];
    NSDictionary *scanned = CIScanContainersMatching(roots, ^BOOL(NSString *ident) {
        if (ident.length == 0 || map[ident]) {
            return NO;
        }
        NSString *low = ident.lowercaseString;
        if (fb) {
            if ([low containsString:@"instagram"] || [low containsString:@"burbn"] ||
                [low containsString:@"whatsapp"] || [low containsString:@"threads"]) {
                return NO;
            }
            return [low containsString:@"facebook"] || [low containsString:@"messenger"] ||
                   [low containsString:@"msysstorage"] || [low containsString:@"metaplatforms"];
        }
        if (shopee) {
            return [low containsString:@"shopee"] || [low containsString:@"beeasy"];
        }
        if (tiktok) {
            return [low containsString:@"zhiliao"] || [low containsString:@"tiktok"] ||
                   [low containsString:@"musically"] || [low containsString:@"aweme"] ||
                   [low containsString:@"bytedance"];
        }
        return NO;
    });
    [map addEntriesFromDictionary:scanned];
    NSMutableArray<NSString *> *extra = [NSMutableArray array];
    if (fb) {
        [extra addObjectsFromArray:CIFacebookExtraGroups()];
    }
    if (shopee) {
        [extra addObjectsFromArray:@[
            @"group.com.shopee.vn",
            @"group.com.shopee.SG",
            @"group.com.beeasy.marketplace.vn"
        ]];
    }
    if (tiktok) {
        [extra addObjectsFromArray:@[
            @"group.com.zhiliaoapp.musically",
            @"group.com.zhiliaoapp.musically.go",
            @"group.com.ss.iphone.ugc.Aweme",
            @"group.com.bytedance.tiktok"
        ]];
    }
    for (NSString *gid in extra) {
        if (map[gid].length > 0) {
            continue;
        }
        NSString *path = CIScanContainer(roots, gid);
        if (path.length > 0) {
            map[gid] = path;
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
    query[(__bridge id)kSecUseAuthenticationUI] = (__bridge id)kSecUseAuthenticationUISkip;
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
    NSData *tag = item[(__bridge id)kSecAttrApplicationTag];
    if ([tag isKindOfClass:[NSData class]] && tag.length > 0) {
        row[@"applicationTag"] = [tag base64EncodedStringWithOptions:0];
    }
    NSData *albl = item[(__bridge id)kSecAttrApplicationLabel];
    if ([albl isKindOfClass:[NSData class]] && albl.length > 0) {
        row[@"applicationLabel"] = [albl base64EncodedStringWithOptions:0];
    }
    id keyClass = CIPlistSafe(item[(__bridge id)kSecAttrKeyClass]);
    if (keyClass) {
        row[@"keyClass"] = keyClass;
    }
    id keyType = CIPlistSafe(item[(__bridge id)kSecAttrKeyType]);
    if (keyType) {
        row[@"keyType"] = keyType;
    }
    id keySize = item[(__bridge id)kSecAttrKeySizeInBits];
    if ([keySize isKindOfClass:[NSNumber class]]) {
        row[@"keySize"] = keySize;
    }
    return row;
}

static BOOL CIKeychainItemMatchesBundle(NSDictionary *item, NSString *bundleID) {
    if (![item isKindOfClass:[NSDictionary class]] || bundleID.length == 0) {
        return NO;
    }
    NSString *agrp = item[(__bridge id)kSecAttrAccessGroup] ?: item[@"accessGroup"] ?: @"";
    if ([agrp isKindOfClass:[NSString class]] && CIKeychainAgrpIsForeignMeta(agrp, bundleID)) {
        return NO;
    }
    if ([agrp isKindOfClass:[NSString class]] && CIKeychainAgrpMatchesBundle(agrp, bundleID)) {
        return YES;
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
    NSString *sig = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@",
                     row[@"class"] ?: @"",
                     row[@"service"] ?: @"",
                     row[@"account"] ?: @"",
                     row[@"accessGroup"] ?: @"",
                     row[@"label"] ?: @"",
                     row[@"server"] ?: @"",
                     row[@"applicationTag"] ?: @""];
    for (NSDictionary *old in out) {
        NSString *osig = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@",
                          old[@"class"] ?: @"",
                          old[@"service"] ?: @"",
                          old[@"account"] ?: @"",
                          old[@"accessGroup"] ?: @"",
                          old[@"label"] ?: @"",
                          old[@"server"] ?: @"",
                          old[@"applicationTag"] ?: @""];
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
    query[(__bridge id)kSecUseAuthenticationUI] = (__bridge id)kSecUseAuthenticationUISkip;
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


static NSString *gCILdidPath = nil;
static NSString *gCIKCSignedError = nil;
static NSUInteger gCIKCAgrpCount = 0;
static NSUInteger gCIKCSignedCount = 0;
static BOOL gCIKCSignedOK = NO;

static int CISpawnWait(NSString *path, NSArray<NSString *> *args) {
    if (path.length == 0) {
        return -1;
    }
    const char *bin = path.fileSystemRepresentation;
    if (!bin || access(bin, X_OK) != 0) {
        return -1;
    }
    NSMutableArray<NSString *> *all = [NSMutableArray arrayWithObject:path];
    if (args.count > 0) {
        [all addObjectsFromArray:args];
    }
    char **argv = (char **)calloc(all.count + 1, sizeof(char *));
    if (!argv) {
        return -1;
    }
    for (NSUInteger i = 0; i < all.count; i++) {
        const char *raw = all[i].fileSystemRepresentation ?: all[i].UTF8String;
        argv[i] = raw ? strdup(raw) : strdup("");
    }
    pid_t pid = 0;
    int rc = posix_spawn(&pid, bin, NULL, NULL, argv, environ);
    for (NSUInteger i = 0; i < all.count; i++) {
        free(argv[i]);
    }
    free(argv);
    if (rc != 0) {
        return -1;
    }
    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return -1;
}

static NSString *CILdidPath(void) {
    if (gCILdidPath.length > 0) {
        return gCILdidPath;
    }
    NSArray<NSString *> *cands = @[
        @"/usr/libexec/am/ldid",
        @"/usr/bin/ldid",
        @"/usr/local/bin/ldid",
        @"/usr/libexec/ldid",
        @"/bin/ldid",
        @"/var/jb/usr/libexec/am/ldid",
        @"/var/jb/usr/bin/ldid",
        @"/var/jb/usr/local/bin/ldid",
        @"/var/jb/usr/libexec/ldid",
        @"/var/jb/bin/ldid"
    ];
    for (NSString *path in cands) {
        if (access(path.fileSystemRepresentation, X_OK) == 0) {
            gCILdidPath = path;
            return path;
        }
    }
    gCILdidPath = @"";
    return nil;
}

static NSString *CIKCAccessPath(void) {
    NSArray<NSString *> *cands = @[
        @"/var/jb/usr/local/bin/chengioskc",
        @"/usr/local/bin/chengioskc",
        @"/var/jb/usr/bin/chengioskc",
        @"/usr/bin/chengioskc"
    ];
    for (NSString *path in cands) {
        if (access(path.fileSystemRepresentation, X_OK) == 0) {
            return path;
        }
    }
    return nil;
}

static NSArray<NSString *> *CIKeychainCollectAgrps(NSString *bundleID) {
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^add)(NSString *) = ^(NSString *value) {
        if (![value isKindOfClass:[NSString class]] || value.length == 0) {
            return;
        }
        if ([value isEqualToString:@"*"] || [value hasSuffix:@".*"]) {
            return;
        }
        if ([seen containsObject:value]) {
            return;
        }
        [seen addObject:value];
        [groups addObject:value];
    };
    LSApplicationProxy *proxy = CIProxy(bundleID);
    NSDictionary *ents = nil;
    if ([proxy respondsToSelector:@selector(entitlements)]) {
        ents = proxy.entitlements;
    }
    if ([ents isKindOfClass:[NSDictionary class]]) {
        id kag = ents[@"keychain-access-groups"];
        if ([kag isKindOfClass:[NSArray class]]) {
            for (id group in kag) {
                add(group);
            }
        }
        id appId = ents[@"application-identifier"];
        add(appId);
        id appGroups = ents[@"com.apple.security.application-groups"];
        if ([appGroups isKindOfClass:[NSArray class]]) {
            for (id group in appGroups) {
                add(group);
            }
        }
    }
    add(bundleID);
    for (NSString *agrp in CIKeychainSQLListAgrps()) {
        if (CIKeychainSQLAgrpProtected(agrp, bundleID) || CIKeychainAgrpIsForeignMeta(agrp, bundleID)) {
            continue;
        }
        if (CIKeychainAgrpMatchesBundle(agrp, bundleID) || CIKeychainTextMatchesBundle(agrp, bundleID)) {
            add(agrp);
        }
    }
    NSString *low = bundleID.lowercaseString;
    if (CIBundleIsFacebookFamily(bundleID) && !CIBundleIsInstagramFamily(bundleID) && !CIBundleIsWhatsAppFamily(bundleID)) {
        for (NSString *value in @[
            @"com.facebook.Facebook",
            @"group.com.facebook.Facebook",
            @"group.com.facebook.family",
            @"group.com.facebook.Messenger",
            @"group.com.facebook.Facebook.widget",
            @"group.com.facebook.mlite",
            @"group.com.facebook.platform",
            @"group.com.facebook.msysstorage",
            @"group.com.metaplatforms.family",
            @"43AQTK3442.com.facebook.Facebook",
            @"43AQTK3442.com.facebook.internal",
            @"43AQTK3442.com.facebook.Messenger"
        ]) {
            add(value);
        }
        for (NSString *agrp in CIKeychainSQLListAgrps()) {
            NSString *alow = agrp.lowercaseString ?: @"";
            if ([alow hasPrefix:@"43aqtk3442.com.facebook"] ||
                ([alow containsString:@"com.facebook"] && ![alow containsString:@"instagram"] && ![alow containsString:@"whatsapp"] && ![alow containsString:@"burbn"])) {
                add(agrp);
            }
        }
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."]) {
        for (NSString *value in @[
            @"group.com.shopee.vn",
            @"group.com.shopee.SG",
            @"group.com.beeasy.marketplace.vn"
        ]) {
            add(value);
        }
    }
    if ([low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
        [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"aweme"]) {
        for (NSString *value in @[
            @"group.com.zhiliaoapp.musically",
            @"group.com.zhiliaoapp.musically.go",
            @"group.com.ss.iphone.ugc.Aweme",
            @"group.com.bytedance.tiktok",
            @"com.zhiliaoapp.musically",
            @"com.zhiliaoapp.musically.go"
        ]) {
            add(value);
        }
    }
    if (ChengIOSBundleIsSafari(bundleID)) {
        for (NSString *value in @[
            @"com.apple.mobilesafari",
            @"group.com.apple.Safari",
            @"group.com.apple.safari"
        ]) {
            add(value);
        }
    }
    id appID = ents[@"application-identifier"];
    NSString *team = CITeamIDFromAppID([appID isKindOfClass:[NSString class]] ? appID : nil);
    if (team.length > 0) {
        add([NSString stringWithFormat:@"%@.%@", team, bundleID]);
    }
    gCIKCAgrpCount = groups.count;
    return groups;
}

static NSString *CIKCWorkCopyDir(void) {
    NSString *root = CIWorkRootDir(YES);
    if (root.length == 0) {
        root = @"/var/tmp";
    }
    NSString *dir = [root stringByAppendingPathComponent:@"kcaccess"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    CIChmodWorld(dir, 0777);
    return dir;
}

static BOOL CIKeychainWriteEntitlements(NSString *path, NSArray<NSString *> *agrps, NSString *appId, NSArray<NSString *> *appGroups) {
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *agrp in agrps) {
        if (agrp.length == 0 || [agrp isEqualToString:@"*"] || [seen containsObject:agrp]) {
            continue;
        }
        [seen addObject:agrp];
        [groups addObject:agrp];
    }
    if (groups.count == 0) {
        [groups addObject:@"com.vinhnv2507.chengioskc"];
    }
    NSMutableDictionary *ent = [@{
        @"platform-application": @YES,
        @"com.apple.private.security.no-container": @YES,
        @"com.apple.private.security.container-required": @NO,
        @"com.apple.private.skip-library-validation": @YES,
        @"com.apple.keystore.access-keychain-keys": @YES,
        @"com.apple.private.security.storage.Keychains": @YES,
        @"application-identifier": (appId.length > 0 ? appId : @"com.vinhnv2507.chengioskc"),
        @"keychain-access-groups": groups
    } mutableCopy];
    if (appGroups.count > 0) {
        ent[@"com.apple.security.application-groups"] = appGroups;
    }
    return [ent writeToFile:path atomically:YES];
}

static NSString *CIKeychainPrepareSignedBinary(NSArray<NSString *> *agrps, NSString *bundleID, NSString **errorOut) {
    gCIKCSignedError = nil;
    gCILdidPath = nil;
    NSString *src = CIKCAccessPath();
    if (src.length == 0) {
        gCIKCSignedError = @"thieu chengioskc";
        if (errorOut) {
            *errorOut = gCIKCSignedError;
        }
        return nil;
    }
    NSString *ldid = CILdidPath();
    if (ldid.length == 0) {
        gCIKCSignedError = @"thieu ldid (cai ldid hoac Apps Manager ldid, iOS 13.5+)";
        if (errorOut) {
            *errorOut = gCIKCSignedError;
        }
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = CIKCWorkCopyDir();
    NSString *dst = [dir stringByAppendingPathComponent:@"chengioskc"];
    NSString *entPath = [dir stringByAppendingPathComponent:@"chengioskc.ent.plist"];
    [fm removeItemAtPath:dst error:nil];
    NSError *copyErr = nil;
    if (![fm copyItemAtPath:src toPath:dst error:&copyErr]) {
        gCIKCSignedError = copyErr.localizedDescription ?: @"copy chengioskc fail";
        if (errorOut) {
            *errorOut = gCIKCSignedError;
        }
        return nil;
    }
    chmod(dst.fileSystemRepresentation, 0755);
    LSApplicationProxy *proxy = CIProxy(bundleID);
    NSDictionary *ents = [proxy respondsToSelector:@selector(entitlements)] ? proxy.entitlements : nil;
    NSString *appId = [ents[@"application-identifier"] isKindOfClass:[NSString class]] ? ents[@"application-identifier"] : nil;
    NSMutableArray<NSString *> *appGroups = [NSMutableArray array];
    id groups = ents[@"com.apple.security.application-groups"];
    if ([groups isKindOfClass:[NSArray class]]) {
        for (id group in groups) {
            if ([group isKindOfClass:[NSString class]] && [group length] > 0) {
                [appGroups addObject:group];
            }
        }
    }
    if (!CIKeychainWriteEntitlements(entPath, agrps, appId, appGroups)) {
        gCIKCSignedError = @"ghi entitlements fail";
        if (errorOut) {
            *errorOut = gCIKCSignedError;
        }
        return nil;
    }
    NSString *flag = [@"-S" stringByAppendingString:entPath];
    int rc = CISpawnWait(ldid, @[flag, dst]);
    if (rc != 0) {
        rc = CISpawnWait(ldid, @[@"-S", entPath, dst]);
    }
    if (rc != 0) {
        gCIKCSignedError = [NSString stringWithFormat:@"ldid -S fail (%d) %@", rc, ldid];
        if (errorOut) {
            *errorOut = gCIKCSignedError;
        }
        return nil;
    }
    chmod(dst.fileSystemRepresentation, 0755);
    if (geteuid() == 0) {
        chown(dst.fileSystemRepresentation, 0, 0);
        chmod(dst.fileSystemRepresentation, 0755);
    }
    return dst;
}

static NSDictionary *CIKeychainRunSigned(NSString *op, NSString *bundleID, NSArray<NSString *> *agrps, NSArray *items) {
    gCIKCSignedOK = NO;
    gCIKCSignedCount = 0;
    if (geteuid() != 0) {
        gCIKCSignedError = @"uid != 0";
        return nil;
    }
    NSString *bin = CIKeychainPrepareSignedBinary(agrps, bundleID, NULL);
    if (bin.length == 0) {
        return nil;
    }
    NSString *dir = [bin stringByDeletingLastPathComponent];
    NSString *inPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-in.plist", op]];
    NSString *outPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-out.plist", op]];
    NSMutableDictionary *job = [@{
        @"op": op ?: @"",
        @"bundleID": bundleID ?: @"",
        @"agrps": agrps ?: @[]
    } mutableCopy];
    if ([items isKindOfClass:[NSArray class]]) {
        job[@"items"] = items;
    }
    [[NSFileManager defaultManager] removeItemAtPath:inPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    if (![job writeToFile:inPath atomically:YES]) {
        gCIKCSignedError = @"ghi job kc fail";
        return nil;
    }
    chmod(inPath.fileSystemRepresentation, 0666);
    int rc = CISpawnWait(bin, @[op, inPath, outPath]);
    NSDictionary *out = [NSDictionary dictionaryWithContentsOfFile:outPath];
    if (![out isKindOfClass:[NSDictionary class]]) {
        gCIKCSignedError = [NSString stringWithFormat:@"chengioskc %@ no output rc=%d", op, rc];
        return nil;
    }
    gCIKCSignedOK = [out[@"ok"] boolValue];
    gCIKCSignedCount = [out[@"count"] unsignedIntegerValue];
    if (!gCIKCSignedOK && [out[@"error"] isKindOfClass:[NSString class]]) {
        gCIKCSignedError = out[@"error"];
    }
    return out;
}

static NSArray<NSDictionary *> *CIKeychainSignedDump(NSString *bundleID) {
    NSArray<NSString *> *agrps = CIKeychainCollectAgrps(bundleID);
    NSDictionary *out = CIKeychainRunSigned(@"dump", bundleID, agrps, nil);
    NSArray *items = out[@"items"];
    if ([items isKindOfClass:[NSArray class]]) {
        return items;
    }
    return @[];
}

static NSUInteger CIKeychainSignedRestore(NSString *bundleID, NSArray *items) {
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) {
        return 0;
    }
    NSMutableArray<NSString *> *agrps = [CIKeychainCollectAgrps(bundleID) mutableCopy];
    if (!agrps) {
        agrps = [NSMutableArray array];
    }

    for (NSDictionary *row in items) {
        if (![row isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *agrp = row[@"accessGroup"];
        if ([agrp isKindOfClass:[NSString class]] && agrp.length > 0 && ![agrps containsObject:agrp]) {
            [agrps addObject:agrp];
        }
    }
    NSDictionary *out = CIKeychainRunSigned(@"restore", bundleID, agrps, items);
    return [out[@"count"] unsignedIntegerValue];
}

static NSUInteger CIKeychainSignedWipe(NSString *bundleID) {
    NSArray<NSString *> *agrps = CIKeychainCollectAgrps(bundleID);
    NSDictionary *out = CIKeychainRunSigned(@"wipe", bundleID, agrps, nil);
    return [out[@"count"] unsignedIntegerValue];
}

static NSArray<NSDictionary *> *CIKeychainDumpForBundle(NSString *bundleID) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSArray *signedItems = CIKeychainSignedDump(bundleID);
    for (NSDictionary *row in signedItems) {
        CIKeychainAddUniqueRow(out, row);
    }
    if (out.count > 0) {
        return out;
    }
    NSArray *classes = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassIdentity
    ];
    NSArray<NSString *> *groups = CIKeychainCollectAgrps(bundleID);
    for (id cls in classes) {
        NSArray *items = CIKeychainCopyItems(cls, YES);
        if (items.count == 0) {
            items = CIKeychainCopyItems(cls, NO);
        }
        for (NSDictionary *item in items) {
            NSString *agrp = item[(__bridge id)kSecAttrAccessGroup] ?: @"";
            if (CIKeychainAgrpMatchesBundle(agrp, bundleID) || CIKeychainItemMatchesBundle(item, bundleID)) {
                CIKeychainAddUniqueRow(out, CIKeychainRowFromItem(cls, item));
            }
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
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *group in groups) {
        if ([seen containsObject:group] || [group hasSuffix:@".*"]) {
            continue;
        }
        [seen addObject:group];
        BOOL agrpOK = CIKeychainAgrpMatchesBundle(group, bundleID) || CIKeychainTextMatchesBundle(group, bundleID);
        for (id cls in classes) {
            NSArray *items = CIKeychainCopyItemsFiltered(cls, @{(__bridge id)kSecAttrAccessGroup: group}, YES);
            if (items.count == 0) {
                items = CIKeychainCopyItemsFiltered(cls, @{(__bridge id)kSecAttrAccessGroup: group}, NO);
            }
            for (NSDictionary *item in items) {
                if (!agrpOK && !CIKeychainItemMatchesBundle(item, bundleID)) {
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
            ![agrp.lowercaseString containsString:@"shopee"] &&
            ![agrp.lowercaseString containsString:@"tiktok"] &&
            ![agrp.lowercaseString containsString:@"zhiliao"] &&
            ![agrp.lowercaseString containsString:@"musically"] &&
            ![agrp.lowercaseString containsString:@"aweme"]) {
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
        if ([glow containsString:@"instagram"] || [glow containsString:@"burbn"] ||
            [glow containsString:@"whatsapp"] || [glow containsString:@"threads"]) {
            return NO;
        }
        return [glow containsString:@"facebook"] || [glow containsString:@"messenger"] ||
               [glow containsString:@"msysstorage"] || [glow containsString:@"metaplatforms"];
    }
    if ([blow containsString:@"shopee"] || [blow hasPrefix:@"com.beeasy."]) {
        return [glow containsString:@"shopee"] || [glow containsString:@"beeasy"];
    }
    if ([blow hasPrefix:@"com.zhiliaoapp."] || [blow containsString:@"tiktok"] ||
        [blow hasPrefix:@"com.ss.iphone."] || [blow containsString:@"aweme"]) {
        return [glow containsString:@"zhiliao"] || [glow containsString:@"tiktok"] ||
               [glow containsString:@"musically"] || [glow containsString:@"aweme"] ||
               [glow containsString:@"bytedance"];
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
    if ([low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
        [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"aweme"] ||
        [low containsString:@"musically"]) {
        [names addObjectsFromArray:@[
            @"TikTok", @"musically", @"Aweme", @"ByteDance",
            @"com.zhiliaoapp.musically", bundleID
        ]];
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
            @"kFacebookSDKAccessTokenKey",
            @"DBLAccounts",
            @"com.facebook.DBL",
            @"device_based_login",
            @"DeviceBasedLogin",
            @"FBAccountStore",
            @"FBSavedAccounts",
            @"com.facebook.accountswitcher",
            @"FBDeviceBasedLogin",
            @"saved_accounts"
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
    if ([low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
        [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"aweme"]) {
        return @[
            @"TTAccount",
            @"TTAccountSession",
            @"TTAccountAuth",
            @"com.zhiliaoapp.musically",
            @"com.zhiliaoapp.musically.go",
            @"aweme",
            @"BDAccount",
            @"tt_passport",
            @"AwemeUserDefaults"
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
    CIKeychainSignedWipe(bundleID);

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
            @"group.com.facebook.msysstorage",
            @"group.com.metaplatforms.family",
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
    if ([bundleID.lowercaseString containsString:@"tiktok"] || [bundleID.lowercaseString hasPrefix:@"com.zhiliaoapp."] ||
        [bundleID.lowercaseString hasPrefix:@"com.ss.iphone."] || [bundleID.lowercaseString containsString:@"aweme"]) {
        [groups addObjectsFromArray:@[
            @"group.com.zhiliaoapp.musically",
            @"group.com.zhiliaoapp.musically.go",
            @"group.com.ss.iphone.ugc.Aweme",
            @"group.com.bytedance.tiktok",
            @"com.zhiliaoapp.musically",
            @"com.zhiliaoapp.musically.go"
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
        if ([low hasPrefix:@"com.apple."] && ![low containsString:bundleID.lowercaseString] &&
            !ChengIOSBundleIsSafari(bundleID) && !CIKeychainTextMatchesBundle(low, bundleID)) {
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


static NSArray<NSString *> *CIAccountNeedles(NSString *bundleID) {
    NSString *low = bundleID.lowercaseString;
    if ([low hasPrefix:@"com.facebook."] || [low hasPrefix:@"com.meta."] || [low containsString:@"facebook"]) {
        return @[@"facebook", @"fbsdk", @"messenger.com"];
    }
    if ([low containsString:@"shopee"] || [low hasPrefix:@"com.beeasy."] || [low hasPrefix:@"com.shopee."]) {
        return @[@"shopee", @"beeasy"];
    }
    if ([low containsString:@"tiktok"] || [low hasPrefix:@"com.zhiliaoapp."] ||
        [low hasPrefix:@"com.ss.iphone."] || [low containsString:@"aweme"] || [low containsString:@"musically"]) {
        return @[@"tiktok", @"musically", @"zhiliao", @"aweme", @"bytedance"];
    }
    return @[];
}

static void CIWipeAccountsForBundle(NSString *bundleID) {
    if (bundleID.length == 0 || geteuid() != 0) {
        return;
    }
    NSArray<NSString *> *needles = CIAccountNeedles(bundleID);
    if (needles.count == 0) {
        return;
    }
    NSArray<NSString *> *cands = @[
        @"/var/mobile/Library/Accounts/Accounts3.sqlite",
        @"/private/var/mobile/Library/Accounts/Accounts3.sqlite"
    ];
    NSString *path = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *cand in cands) {
        if ([fm fileExistsAtPath:cand]) {
            path = cand;
            break;
        }
    }
    if (path.length == 0) {
        return;
    }
    CIRunKillall(@"accountsd");
    [NSThread sleepForTimeInterval:0.15];
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        if (db) {
            sqlite3_close(db);
        }
        return;
    }
    sqlite3_busy_timeout(db, 8000);
    sqlite3_exec(db, "BEGIN IMMEDIATE;", NULL, NULL, NULL);
    NSArray<NSString *> *queries = @[
        @"SELECT a.Z_PK, ifnull(a.ZUSERNAME,''), ifnull(t.ZIDENTIFIER,'') FROM ZACCOUNT a LEFT JOIN ZACCOUNTTYPE t ON a.ZACCOUNTTYPE = t.Z_PK",
        @"SELECT Z_PK, ifnull(ZUSERNAME,''), ifnull(ZACCOUNTDESCRIPTION,'') FROM ZACCOUNT"
    ];
    sqlite3_stmt *stmt = NULL;
    NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
    for (NSString *sql in queries) {
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
            stmt = NULL;
            continue;
        }
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            sqlite3_int64 pk = sqlite3_column_int64(stmt, 0);
            NSMutableString *blob = [NSMutableString string];
            int n = sqlite3_column_count(stmt);
            for (int i = 1; i < n; i++) {
                const unsigned char *txt = sqlite3_column_text(stmt, i);
                if (txt) {
                    [blob appendFormat:@"%s ", txt];
                }
            }
            NSString *low = blob.lowercaseString;
            BOOL hit = NO;
            for (NSString *needle in needles) {
                if ([low containsString:needle]) {
                    hit = YES;
                    break;
                }
            }
            if (hit) {
                [ids addObject:@(pk)];
            }
        }
        sqlite3_finalize(stmt);
        stmt = NULL;
        if (ids.count > 0) {
            break;
        }
    }
    sqlite3_stmt *del = NULL;
    if (ids.count > 0 && sqlite3_prepare_v2(db, "DELETE FROM ZACCOUNT WHERE Z_PK=?", -1, &del, NULL) == SQLITE_OK) {
        for (NSNumber *pk in ids) {
            sqlite3_reset(del);
            sqlite3_clear_bindings(del);
            sqlite3_bind_int64(del, 1, pk.longLongValue);
            sqlite3_step(del);
        }
        sqlite3_finalize(del);
    }
    sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", NULL, NULL, NULL);
    sqlite3_close(db);
    CIRunKillall(@"accountsd");
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
    if (!CIIsRootProcess()) {
        if (CIInHelperProcess()) {
            if (error) {
                *error = CIError(2, @"chengiosroot uid != 0");
            }
            return nil;
        }
        NSDictionary *remote = CIRunRootOp(@{
            @"op": @"backup",
            @"name": name ?: @"",
            @"includeAppData": @(includeAppData),
            @"bundles": bundleIDs ?: @[]
        }, error);
        if (remote) {
            if ([remote[@"ok"] boolValue] && [remote[@"meta"] isKindOfClass:[NSDictionary class]]) {
                return remote[@"meta"];
            }
            if (error && !*error) {
                *error = CIError(2, remote[@"error"] ?: @"Backup root helper loi.");
            }
            return nil;
        }
    }
    NSString *backupID = CINewBackupID();
    NSString *dir = [ChengIOSBackupRoot() stringByAppendingPathComponent:backupID];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error]) {
        if (error && !*error) {
            *error = CIError(2, @"Khong tao duoc thu muc backup.");
        }
        return nil;
    }

    gCIKCSignedError = nil;
    gCIKCSignedCount = 0;
    gCIKCAgrpCount = 0;
    gCIKCSignedOK = NO;
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
    NSUInteger sqlCountTotal = 0;
    NSUInteger secCountTotal = 0;
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
            NSDictionary *groups = CIAllGroupPaths(bundleID);
            NSDictionary *plugins = CIPluginPaths(bundleID);
            NSMutableArray *keychain = [(CIKeychainDumpForBundle(bundleID) ?: @[]) mutableCopy];
            NSArray *sqlItems = CIKeychainSQLDumpForBundle(bundleID);
            sqlCountTotal += sqlItems.count;
            secCountTotal += keychain.count;
            if (sqlItems.count > 0) {
                [keychain addObjectsFromArray:sqlItems];
            }
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
        @"version": @"1.2.19",
        @"includeAppData": @(includeAppData),
        @"bundles": savedBundles,
        @"failedBundles": failedBundles,
        @"bytes": @(bytes),
        @"keychainItems": @(keychainCount),
        @"sqlOpened": @(gCIKeychainSQLLastOpen),
        @"sqlPath": gCIKeychainSQLLastPath ?: @"",
        @"sqlCount": @(sqlCountTotal),
        @"secCount": @(secCountTotal),
        @"signedCount": @(gCIKCSignedCount),
        @"signedOK": @(gCIKCSignedOK),
        @"agrpCount": @(gCIKCAgrpCount),
        @"ldid": CILdidPath() ?: @"",
        @"kcaccess": CIKCAccessPath() ?: @"",
        @"signedError": gCIKCSignedError ?: @"",
        @"asRoot": @(geteuid() == 0),
        @"uid": @(geteuid()),
        @"daemon": @(CIInDaemonProcess()),
        @"helper": CIRootHelperPath() ?: @"",
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
    if (!CIIsRootProcess()) {
        if (CIInHelperProcess()) {
            if (error) {
                *error = CIError(3, @"chengiosroot uid != 0");
            }
            return NO;
        }
        NSDictionary *remote = CIRunRootOp(@{
            @"op": @"restore",
            @"backupID": backupID ?: @"",
            @"restoreProfile": @(restoreProfile),
            @"restoreAppData": @(restoreAppData)
        }, error);
        if (remote) {
            if ([remote[@"ok"] boolValue]) {
                return YES;
            }
            if (error && !*error) {
                *error = CIError(3, remote[@"error"] ?: @"Restore root helper loi.");
            }
            return NO;
        }
    }
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
            NSDictionary *liveGroups = CIAllGroupPaths(bundleID);
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
                NSMutableArray *sqlRows = [NSMutableArray array];
                NSMutableArray *secRows = [NSMutableArray array];
                for (NSDictionary *row in keychain) {
                    if (![row isKindOfClass:[NSDictionary class]]) {
                        continue;
                    }
                    if ([row[@"source"] isEqualToString:@"sqlite"] || row[@"cols"]) {
                        [sqlRows addObject:row];
                    } else {
                        [secRows addObject:row];
                    }
                }
                CIKeychainSignedWipe(bundleID);
                CIWipeKeychainForProxy(CIProxy(bundleID), bundleID);
                CIKeychainSQLWipeForBundle(bundleID);
                CIRunKillall(@"securityd");
                CIRunKillall(@"secd");
                [NSThread sleepForTimeInterval:0.25];
                NSUInteger restored = 0;
                if (secRows.count > 0) {
                    restored = CIKeychainSignedRestore(bundleID, secRows);
                    if (restored == 0) {
                        restored = CIKeychainRestoreItems(secRows);
                    }
                }
                if (restored == 0 && sqlRows.count > 0) {
                    CIKeychainSQLRestoreRows(sqlRows);
                }
                CIRunKillall(@"securityd");
                CIRunKillall(@"secd");
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

    NSString *eraseLow = bundleID.lowercaseString;
    BOOL wipeFamily = [eraseLow hasPrefix:@"com.facebook."] || [eraseLow hasPrefix:@"com.meta."] ||
                      [eraseLow containsString:@"shopee"] || [eraseLow hasPrefix:@"com.beeasy."] ||
                      [eraseLow hasPrefix:@"com.zhiliaoapp."] || [eraseLow containsString:@"tiktok"] ||
                      [eraseLow hasPrefix:@"com.ss.iphone."] || [eraseLow containsString:@"aweme"];
    if (wipeFamily) {
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
    [groups addEntriesFromDictionary:CIAllGroupPaths(bundleID)];
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
    CIKeychainSQLWipeForBundle(bundleID);
    CIWipeAccountsForBundle(bundleID);
    if (wipeFamily) {
        for (NSString *other in CICompanionBundleIDs(bundleID)) {
            CIKeychainSQLWipeForBundle(other);
            CIWipeAccountsForBundle(other);
        }
    }
    CIRunKillall(@"cfprefsd");
    CIRunKillall(@"securityd");
    CIRunKillall(@"secd");
    [NSThread sleepForTimeInterval:0.35];
    if (dataPath.length > 0) {
        CIEmptyContainer(dataPath);
        CIReemptyPrefs(dataPath);
    }
    for (NSString *group in groups) {
        if (!CIGroupAlwaysWipe(group, bundleID) && CIGroupUsedByOtherApps(group, bundleID, together)) {
            continue;
        }
        CIEmptyContainer(groups[group]);
        CIReemptyPrefs(groups[group]);
    }
    for (NSString *pluginID in plugins) {
        CIEmptyContainer(plugins[pluginID]);
        CIReemptyPrefs(plugins[pluginID]);
    }
    CIWipeKeychainForProxy(CIProxy(bundleID), bundleID);
    CIKeychainSQLWipeForBundle(bundleID);
    if (wipeFamily) {
        for (NSString *other in CICompanionBundleIDs(bundleID)) {
            CIWipeKeychainForProxy(CIProxy(other), other);
            CIKeychainSQLWipeForBundle(other);
        }
    }
    CISettleAfterDisk(bundleID);
    return ok;
}

NSDictionary *ChengIOSEraseBundles(NSArray<NSString *> *bundleIDs, NSError **error) {
    if (!CIIsRootProcess()) {
        if (CIInHelperProcess()) {
            if (error) {
                *error = CIError(4, @"chengiosroot uid != 0");
            }
            return @{@"ok": @[], @"failed": bundleIDs ?: @[], @"skipped": @[], @"error": @"uid"};
        }
        NSDictionary *remote = CIRunRootOp(@{
            @"op": @"erase",
            @"bundles": bundleIDs ?: @[]
        }, error);
        if (remote) {
            NSDictionary *result = remote[@"result"];
            if ([result isKindOfClass:[NSDictionary class]]) {
                return result;
            }
        }
    }
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
    if (!CIIsRootProcess()) {
        if (CIInHelperProcess()) {
            if (error) {
                *error = CIError(4, @"chengiosroot uid != 0");
            }
            return @{@"ok": @[], @"failed": @[@"com.apple.mobilesafari"], @"skipped": @[], @"error": @"uid"};
        }
        NSDictionary *remote = CIRunRootOp(@{@"op": @"erase-safari"}, error);
        if (remote) {
            NSDictionary *result = remote[@"result"];
            if ([result isKindOfClass:[NSDictionary class]]) {
                return result;
            }
        }
    }
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
