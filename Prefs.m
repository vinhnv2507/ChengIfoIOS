#import "Prefs.h"

#import <pthread.h>
#import <stdint.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <sys/types.h>

static pthread_key_t gLocationBypassKey;
static pthread_once_t gLocationBypassOnce = PTHREAD_ONCE_INIT;

static void OVSInitLocationBypassKey(void) {
    pthread_key_create(&gLocationBypassKey, NULL);
}

static int OVSLocationBypassDepth(void) {
    pthread_once(&gLocationBypassOnce, OVSInitLocationBypassKey);
    return (int)(intptr_t)pthread_getspecific(gLocationBypassKey);
}

void OVSBeginLocationHookBypass(void) {
    pthread_once(&gLocationBypassOnce, OVSInitLocationBypassKey);
    int depth = OVSLocationBypassDepth();
    pthread_setspecific(gLocationBypassKey, (void *)(intptr_t)(depth + 1));
}

void OVSEndLocationHookBypass(void) {
    int depth = OVSLocationBypassDepth();
    if (depth > 0) {
        pthread_setspecific(gLocationBypassKey, (void *)(intptr_t)(depth - 1));
    }
}

BOOL OVSLocationHookBypassed(void) {
    return OVSLocationBypassDepth() > 0;
}

static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static NSDictionary *gPrefs;
static NSString *gBuildNumber;
static NSUUID *gVendorUUID;
static NSUUID *gAdvertisingUUID;
static NSArray<CLLocation *> *gGPXLocations;
static NSArray<NSNumber *> *gGPXOffsets;
static NSString *gLoadedGPXPath;
static NSTimeInterval gLocationEpoch;

static NSArray<NSString *> *OVSCandidatePreferencePaths(void) {
    return @[
        @"/var/jb/var/mobile/Library/Preferences/com.vinhnv2507.chengiosprefs.plist",
        @"/var/mobile/Library/Preferences/com.vinhnv2507.chengiosprefs.plist",
        @"/private/var/mobile/Library/Preferences/com.vinhnv2507.chengiosprefs.plist"
    ];
}

static id OVSCopyLocked(id object) {
    if (!object) {
        return nil;
    }
    if ([object isKindOfClass:[NSString class]] ||
        [object isKindOfClass:[NSNumber class]] ||
        [object isKindOfClass:[NSArray class]] ||
        [object isKindOfClass:[NSDictionary class]] ||
        [object isKindOfClass:[NSData class]]) {
        return [object copy];
    }
    return object;
}

void OVSReloadPreferences(void) {
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];

    for (NSString *path in OVSCandidatePreferencePaths()) {
        NSDictionary *fileDict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (fileDict.count > 0) {
            [merged addEntriesFromDictionary:fileDict];
            break;
        }
    }

    CFStringRef appID = CFSTR("com.vinhnv2507.chengiosprefs");
    CFArrayRef keys = CFPreferencesCopyKeyList(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        CFDictionaryRef dict = CFPreferencesCopyMultiple(keys, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (dict) {
            [merged addEntriesFromDictionary:(__bridge NSDictionary *)dict];
            CFRelease(dict);
        }
        CFRelease(keys);
    }

    pthread_mutex_lock(&gMutex);
    gPrefs = [merged copy];
    gGPXLocations = nil;
    gGPXOffsets = nil;
    gLoadedGPXPath = nil;
    pthread_mutex_unlock(&gMutex);
}

static void OVSDarwinCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    OVSReloadPreferences();
}

static void OVSAddDarwinObserver(CFStringRef name) {
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        OVSDarwinCallback,
        name,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}

void OVSRegisterPreferenceListener(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        OVSReloadPreferences();
        OVSAddDarwinObserver(CFSTR("com.vinhnv2507.chengiosprefs/changed"));
        OVSAddDarwinObserver(CFSTR("com.vinhnv2507.chengiosprefs/ReloadPrefs"));
    });
}

NSDictionary *OVSPreferences(void) {
    pthread_mutex_lock(&gMutex);
    NSDictionary *prefs = [gPrefs copy] ?: @{};
    pthread_mutex_unlock(&gMutex);
    return prefs;
}

id OVSObjectForKey(NSString *key) {
    if (key.length == 0) {
        return nil;
    }
    pthread_mutex_lock(&gMutex);
    id value = OVSCopyLocked(gPrefs[key]);
    pthread_mutex_unlock(&gMutex);
    return value;
}

BOOL OVSBoolForKey(NSString *key, BOOL defaultValue) {
    id value = OVSObjectForKey(key);
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) {
        return [value boolValue];
    }
    return defaultValue;
}

NSString *OVSStringForKey(NSString *key, NSString *defaultValue) {
    id value = OVSObjectForKey(key);
    if ([value isKindOfClass:[NSString class]]) {
        NSString *string = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return string.length > 0 ? string : defaultValue;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value stringValue];
    }
    return defaultValue;
}

NSString *OVSStringForKeys(NSArray<NSString *> *keys, NSString *defaultValue) {
    for (NSString *key in keys) {
        NSString *value = OVSStringForKey(key, nil);
        if (value.length > 0) {
            return value;
        }
    }
    return defaultValue;
}

double OVSDoubleForKey(NSString *key, double defaultValue) {
    id value = OVSObjectForKey(key);
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) {
        return [value doubleValue];
    }
    return defaultValue;
}


NSString *OVSMainBundleIdentifier(void) {
    static NSString *identifier;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CFBundleRef bundle = CFBundleGetMainBundle();
        if (bundle) {
            CFStringRef value = CFBundleGetIdentifier(bundle);
            if (value) {
                identifier = [(__bridge NSString *)value copy];
            }
        }
    });
    return identifier;
}

NSString *OVSMainBundlePath(void) {
    static NSString *path;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CFBundleRef bundle = CFBundleGetMainBundle();
        if (!bundle) {
            return;
        }
        CFURLRef url = CFBundleCopyBundleURL(bundle);
        if (!url) {
            return;
        }
        path = [((__bridge NSURL *)url).path copy];
        CFRelease(url);
    });
    return path;
}


BOOL OVSIsProtectedProcess(void) {
    static BOOL protectedProcess;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *processName = [[[NSProcessInfo processInfo] processName] lowercaseString] ?: @"";
        NSString *bundleID = [OVSMainBundleIdentifier() lowercaseString] ?: @"";

        NSArray<NSString *> *blockedNames = @[
            @"springboard", @"backboardd", @"thermalmonitord", @"watchdogd",
            @"mediaserverd", @"logd", @"syslogd", @"cfprefsd", @"usereventagent",
            @"locationd", @"installd", @"assertiond", @"aggregated", @"dasd",
            @"symptomsd", @"wifid", @"bluetoothd", @"runningboardd", @"lsd",
            @"securityd", @"trustd", @"amfid", @"notifyd", @"configd", @"powerd",
            @"fseventsd", @"reportcrash", @"reportmemoryexception", @"parsed",
            @"sharingd", @"searchd", @"akd", @"nsurlsessiond", @"accountsd",
            @"identityservicesd", @"imagent", @"preferences"
        ];
        NSArray<NSString *> *blockedIDs = @[
            @"com.apple.springboard",
            @"com.apple.preferences",
            @"com.apple.backboardd"
        ];
        protectedProcess = [blockedNames containsObject:processName] || [blockedIDs containsObject:bundleID];
    });
    return protectedProcess;
}

BOOL OVSIsWebKitHelperProcess(void) {
    static BOOL helper;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *processName = [[[NSProcessInfo processInfo] processName] lowercaseString] ?: @"";
        NSString *bundleID = [OVSMainBundleIdentifier() lowercaseString] ?: @"";
        helper = [processName containsString:@"webkit"] ||
                 [processName containsString:@"webcontent"] ||
                 [processName containsString:@"safariviewservice"] ||
                 [bundleID hasPrefix:@"com.apple.webkit"] ||
                 [bundleID containsString:@"webcontent"] ||
                 [bundleID isEqualToString:@"com.apple.safariviewservice"];
    });
    return helper;
}


BOOL OVSIsSafariFamily(void) {
    static BOOL safariFamily;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *bundle = [OVSMainBundleIdentifier() lowercaseString] ?: @"";
        NSString *processName = [[[NSProcessInfo processInfo] processName] lowercaseString] ?: @"";
        safariFamily = [bundle isEqualToString:@"com.apple.mobilesafari"] ||
                       [bundle isEqualToString:@"com.apple.safariviewservice"] ||
                       [bundle isEqualToString:@"com.apple.webapp"] ||
                       [processName isEqualToString:@"mobilesafari"] ||
                       [processName isEqualToString:@"safariviewservice"];
    });
    return safariFamily;
}

static BOOL OVSStringLooksFragile(NSString *value) {
    NSString *text = value.lowercaseString ?: @"";
    if (text.length == 0) {
        return NO;
    }
    return [text hasPrefix:@"com.facebook."] ||
           [text hasPrefix:@"com.meta."] ||
           [text hasPrefix:@"com.burbn."] ||
           [text hasPrefix:@"com.instagram."] ||
           [text hasPrefix:@"net.whatsapp."] ||
           [text containsString:@"facebook"] ||
           [text containsString:@"shopee"] ||
           [text containsString:@"instagram"] ||
           [text containsString:@"whatsapp"];
}

static NSString *OVSParentProcessName(void) {
    static NSString *name;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        name = @"";
        pid_t ppid = getppid();
        if (ppid <= 1) {
            return;
        }
        int (*pidpathFn)(int, void *, uint32_t) = dlsym(RTLD_DEFAULT, "proc_pidpath");
        if (!pidpathFn) {
            return;
        }
        char path[1024];
        memset(path, 0, sizeof(path));
        if (pidpathFn(ppid, path, sizeof(path) - 1) > 0) {
            name = [[[NSString stringWithUTF8String:path] lastPathComponent] copy] ?: @"";
        }
    });
    return name;
}

static NSString *OVSBundleIDFromAppPath(NSString *path) {
    if (path.length == 0) {
        return nil;
    }
    NSString *dir = path;
    for (int i = 0; i < 8 && dir.length > 1; i++) {
        NSString *last = dir.lastPathComponent.lowercaseString;
        if ([last isEqualToString:@"mobilesafari.app"] || [last isEqualToString:@"mobilesafari"]) {
            return @"com.apple.mobilesafari";
        }
        if ([last isEqualToString:@"safariviewservice.app"] || [last isEqualToString:@"safariviewservice"]) {
            return @"com.apple.SafariViewService";
        }
        if ([dir.pathExtension.lowercaseString isEqualToString:@"app"]) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"Info.plist"]];
            NSString *bundleID = info[@"CFBundleIdentifier"];
            if (bundleID.length > 0) {
                return bundleID;
            }
        }
        dir = [dir stringByDeletingLastPathComponent];
    }
    return nil;
}

static BOOL OVSStringLooksLikeSafari(NSString *value) {
    NSString *text = value.lowercaseString ?: @"";
    if (text.length == 0) {
        return NO;
    }
    return [text containsString:@"mobilesafari"] ||
           [text containsString:@"com.apple.safari"] ||
           [text isEqualToString:@"safari"] ||
           [text containsString:@"safariviewservice"] ||
           [text containsString:@"com.apple.webapp"];
}

static NSString *OVSContainerBundleIdentifier(void) {
    static NSString *identifier;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        identifier = @"";
        NSString *home = NSHomeDirectory() ?: @"";
        if (home.length == 0) {
            return;
        }
        NSArray<NSString *> *candidates = @[
            [home stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"],
            [[home stringByDeletingLastPathComponent] stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]
        ];
        for (NSString *path in candidates) {
            NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:path];
            NSString *value = meta[@"MCMMetadataIdentifier"];
            if (value.length > 0) {
                identifier = [value copy];
                return;
            }
        }
        if (OVSStringLooksLikeSafari(home)) {
            identifier = @"com.apple.mobilesafari";
        }
    });
    return identifier;
}

static NSString *OVSResponsibleBundleIdentifier(void) {
    static NSString *bundleID;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bundleID = @"";
        pid_t (*responsibleFn)(pid_t) = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
        int (*pidpathFn)(int, void *, uint32_t) = dlsym(RTLD_DEFAULT, "proc_pidpath");
        pid_t target = getpid();
        if (responsibleFn) {
            pid_t responsible = responsibleFn(getpid());
            if (responsible > 1) {
                target = responsible;
            }
        }
        if (pidpathFn && target > 1) {
            char path[1024];
            memset(path, 0, sizeof(path));
            if (pidpathFn(target, path, sizeof(path) - 1) > 0) {
                NSString *found = OVSBundleIDFromAppPath([NSString stringWithUTF8String:path]);
                if (found.length > 0) {
                    bundleID = [found copy];
                }
            }
        }
    });
    return bundleID;
}

static NSString *OVSBundleIDFromProcessArguments(void) {
    NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];
    for (NSUInteger i = 0; i + 1 < args.count; i++) {
        NSString *arg = args[i].lowercaseString;
        if ([arg containsString:@"client-bundle-identifier"] ||
            [arg isEqualToString:@"-bundle-identifier"] ||
            [arg isEqualToString:@"--bundle-identifier"]) {
            NSString *value = args[i + 1];
            if (value.length > 0) {
                return value;
            }
        }
    }
    for (NSString *arg in args) {
        NSString *lower = arg.lowercaseString ?: @"";
        if ([lower containsString:@"com.apple.mobilesafari"]) {
            return @"com.apple.mobilesafari";
        }
        if ([lower containsString:@"com.apple.safariviewservice"]) {
            return @"com.apple.SafariViewService";
        }
    }
    return nil;
}

NSString *OVSEffectiveBundleIdentifier(void) {
    static NSString *effective;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *main = OVSMainBundleIdentifier() ?: @"";
        if (!OVSIsWebKitHelperProcess()) {
            effective = [main copy];
            return;
        }
        NSString *fromArgs = OVSBundleIDFromProcessArguments();
        if (fromArgs.length > 0 && ![fromArgs.lowercaseString hasPrefix:@"com.apple.webkit"]) {
            effective = [fromArgs copy];
            return;
        }
        NSString *responsible = OVSResponsibleBundleIdentifier();
        if (responsible.length > 0 && ![responsible.lowercaseString hasPrefix:@"com.apple.webkit"]) {
            effective = responsible;
            return;
        }
        NSString *container = OVSContainerBundleIdentifier();
        if (container.length > 0 && ![container.lowercaseString hasPrefix:@"com.apple.webkit"]) {
            effective = container;
            return;
        }
        NSString *parent = OVSParentProcessName().lowercaseString;
        if ([parent isEqualToString:@"mobilesafari"] || [parent isEqualToString:@"safari"]) {
            effective = @"com.apple.mobilesafari";
            return;
        }
        if ([parent isEqualToString:@"safariviewservice"]) {
            effective = @"com.apple.SafariViewService";
            return;
        }
        NSString *home = NSHomeDirectory() ?: @"";
        if (OVSStringLooksLikeSafari(home)) {
            effective = @"com.apple.mobilesafari";
            return;
        }
        if (fromArgs.length > 0) {
            effective = [fromArgs copy];
            return;
        }
        effective = [main copy];
    });
    return effective;
}

BOOL OVSIsFragileApp(void) {
    static BOOL fragile;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fragile = OVSStringLooksFragile(OVSEffectiveBundleIdentifier()) ||
                  OVSStringLooksFragile(OVSMainBundleIdentifier()) ||
                  OVSStringLooksFragile([[NSProcessInfo processInfo] processName]) ||
                  OVSStringLooksFragile(OVSParentProcessName()) ||
                  OVSStringLooksFragile(NSHomeDirectory()) ||
                  OVSStringLooksFragile(OVSContainerBundleIdentifier()) ||
                  OVSStringLooksFragile(OVSResponsibleBundleIdentifier());
    });
    return fragile;
}

BOOL OVSGestaltEnabled(void) {
    if (!OVSSpoofingEnabled() || OVSIsWebKitHelperProcess() || OVSIsFragileApp() || OVSIsSafariFamily()) {
        return NO;
    }
    return OVSBoolForKey(@"gestaltEnabled", NO);
}

BOOL OVSLowLevelHooksEnabled(void) {
    return OVSGestaltEnabled();
}

BOOL OVSMachineHooksEnabled(void) {
    return OVSShouldSpoofModel();
}

static pthread_key_t gLowLevelHookKey;
static pthread_once_t gLowLevelHookOnce = PTHREAD_ONCE_INIT;

static void OVSInitLowLevelHookKey(void) {
    pthread_key_create(&gLowLevelHookKey, NULL);
}

BOOL OVSBeginLowLevelHook(void) {
    pthread_once(&gLowLevelHookOnce, OVSInitLowLevelHookKey);
    int depth = (int)(intptr_t)pthread_getspecific(gLowLevelHookKey);
    if (depth > 0) {
        return NO;
    }
    pthread_setspecific(gLowLevelHookKey, (void *)(intptr_t)1);
    return YES;
}

void OVSEndLowLevelHook(void) {
    pthread_once(&gLowLevelHookOnce, OVSInitLowLevelHookKey);
    pthread_setspecific(gLowLevelHookKey, NULL);
}

BOOL OVSMasterEnabled(void) {
    return OVSBoolForKey(@"masterEnabled", YES);
}

static BOOL OVSBundleIsSelected(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0) {
        return NO;
    }
    id apps = OVSObjectForKey(@"spoofedApps");
    if ([apps isKindOfClass:[NSArray class]] && [apps containsObject:bundleIdentifier]) {
        return YES;
    }
    id enabled = OVSObjectForKey(@"appEnabled");
    if ([enabled isKindOfClass:[NSDictionary class]]) {
        id flag = enabled[bundleIdentifier];
        if ([flag isKindOfClass:[NSNumber class]] || [flag isKindOfClass:[NSString class]]) {
            return [flag boolValue];
        }
    }
    return NO;
}

static BOOL OVSSafariFamilySelected(void) {
    return OVSBundleIsSelected(@"com.apple.mobilesafari") ||
           OVSBundleIsSelected(@"com.apple.SafariViewService") ||
           OVSBundleIsSelected(@"com.apple.webapp");
}

BOOL OVSAppSelected(void) {
    if (OVSBundleIsSelected(OVSEffectiveBundleIdentifier()) || OVSBundleIsSelected(OVSMainBundleIdentifier())) {
        return YES;
    }
    if (!OVSIsWebKitHelperProcess() || OVSIsFragileApp() || !OVSSafariFamilySelected()) {
        return NO;
    }
    NSString *host = OVSEffectiveBundleIdentifier() ?: @"";
    NSString *parent = OVSParentProcessName() ?: @"";
    NSString *home = NSHomeDirectory() ?: @"";
    NSString *container = OVSContainerBundleIdentifier() ?: @"";
    NSString *responsible = OVSResponsibleBundleIdentifier() ?: @"";
    if (OVSStringLooksFragile(host) ||
        OVSStringLooksFragile(parent) ||
        OVSStringLooksFragile(home) ||
        OVSStringLooksFragile(container) ||
        OVSStringLooksFragile(responsible)) {
        return NO;
    }
    return OVSStringLooksLikeSafari(host) ||
           OVSStringLooksLikeSafari(parent) ||
           OVSStringLooksLikeSafari(home) ||
           OVSStringLooksLikeSafari(container) ||
           OVSStringLooksLikeSafari(responsible);
}

BOOL OVSSpoofingEnabled(void) {
    if (OVSIsProtectedProcess()) {
        return NO;
    }
    return OVSMasterEnabled() && OVSAppSelected();
}

BOOL OVSShouldSpoofOSVersion(void) {
    return OVSSpoofingEnabled() && !OVSIsFragileApp() && !OVSIsSafariFamily();
}

BOOL OVSUseCustomOSVersion(void) {
    if (OVSBoolForKey(@"useCustomOSVersion", NO)) {
        return YES;
    }
    return OVSStringForKeys(@[@"customOSVersion", @"spoofedSystemVersion"], nil).length > 0;
}

static BOOL OVSParseVersion(NSString *raw, NSOperatingSystemVersion *outVersion) {
    if (raw.length == 0 || !outVersion) {
        return NO;
    }
    NSArray<NSString *> *parts = [raw componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@".-"]];
    if (parts.count == 0) {
        return NO;
    }
    NSInteger major = parts.count > 0 ? [parts[0] integerValue] : 0;
    NSInteger minor = parts.count > 1 ? [parts[1] integerValue] : 0;
    NSInteger patch = parts.count > 2 ? [parts[2] integerValue] : 0;
    if (major <= 0) {
        return NO;
    }
    outVersion->majorVersion = major;
    outVersion->minorVersion = minor;
    outVersion->patchVersion = patch;
    return YES;
}

NSOperatingSystemVersion OVSPredictedOSVersion(void) {
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    NSDateComponents *components = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:[NSDate date]];
    NSInteger year = components.year;
    NSInteger month = components.month;

    NSOperatingSystemVersion version;
    version.patchVersion = 0;
    if (month >= 9) {
        version.majorVersion = 17 + (year - 2024) + 1;
        static const NSInteger kAutumnMinor[] = {0, 0, 1, 1};
        NSInteger index = month - 9;
        version.minorVersion = (index >= 0 && index < 4) ? kAutumnMinor[index] : 1;
        return version;
    }

    version.majorVersion = 17 + (year - 2024);
    NSDictionary<NSNumber *, NSNumber *> *monthToMinor = @{
        @1: @2,
        @2: @3,
        @3: @3,
        @4: @4,
        @5: @4,
        @6: @5,
        @7: @5,
        @8: @6
    };
    NSNumber *minor = monthToMinor[@(month)];
    version.minorVersion = minor ? minor.integerValue : 0;
    return version;
}

NSOperatingSystemVersion OVSSpoofedOSVersion(void) {
    if (OVSUseCustomOSVersion()) {
        NSOperatingSystemVersion parsed;
        if (OVSParseVersion(OVSStringForKeys(@[@"customOSVersion", @"spoofedSystemVersion"], nil), &parsed)) {
            return parsed;
        }
    }
    return OVSPredictedOSVersion();
}

NSString *OVSSpoofedOSVersionString(void) {
    NSOperatingSystemVersion version = OVSSpoofedOSVersion();
    if (version.patchVersion > 0) {
        return [NSString stringWithFormat:@"%ld.%ld.%ld", (long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion];
    }
    return [NSString stringWithFormat:@"%ld.%ld", (long)version.majorVersion, (long)version.minorVersion];
}

NSString *OVSSpoofedOSVersionUnderscore(void) {
    return [OVSSpoofedOSVersionString() stringByReplacingOccurrencesOfString:@"." withString:@"_"];
}

NSString *OVSSpoofedBuildNumber(void) {
    NSString *custom = OVSStringForKeys(@[@"customBuildNumber", @"spoofedBuild"], nil);
    if (custom.length > 0) {
        return custom;
    }
    pthread_mutex_lock(&gMutex);
    if (!gBuildNumber) {
        int firstPart = arc4random_uniform(100);
        char letterPart = (char)('A' + arc4random_uniform(26));
        int secondPart = 100 + (int)arc4random_uniform(900);
        gBuildNumber = [NSString stringWithFormat:@"%02d%c%d", firstPart, letterPart, secondPart];
    }
    NSString *build = gBuildNumber;
    pthread_mutex_unlock(&gMutex);
    return build;
}

BOOL OVSAppVersionEnabled(void) {
    if (OVSIsFragileApp() || OVSIsSafariFamily() || !OVSSpoofingEnabled() || !OVSBoolForKey(@"appVersionEnabled", NO)) {
        return NO;
    }
    NSString *version = OVSSpoofedAppVersion();
    if (version.length == 0 || [version isEqualToString:@"2147483647"]) {
        return NO;
    }
    return YES;
}

NSString *OVSSpoofedAppVersion(void) {
    return OVSStringForKey(@"customAppVersion", nil);
}

BOOL OVSDeviceIdentityEnabled(void) {
    return OVSSpoofingEnabled() && !OVSIsSafariFamily() && OVSBoolForKey(@"deviceIdentityEnabled", NO);
}

NSString *OVSSpoofedDeviceName(void) {
    NSString *value = OVSStringForKeys(@[@"customDeviceName", @"spoofedName"], nil);
    if (value.length > 0) {
        return value;
    }
    return OVSBoolForKey(@"deviceIdentityEnabled", NO) ? @"iPhone" : nil;
}

NSString *OVSSpoofedHostName(void) {
    NSString *value = OVSStringForKeys(@[@"customHostName", @"spoofedHostname"], nil);
    if (value.length > 0) {
        return value;
    }
    return OVSBoolForKey(@"deviceIdentityEnabled", NO) ? @"iphone.local" : nil;
}

NSString *OVSSpoofedModel(void) {
    return OVSStringForKeys(@[@"customDeviceModel", @"spoofedModel"], nil);
}

BOOL OVSShouldSpoofDeviceName(void) {
    return OVSSpoofingEnabled() && !OVSIsSafariFamily() && OVSSpoofedDeviceName().length > 0;
}

BOOL OVSShouldSpoofHostName(void) {
    return OVSSpoofingEnabled() && !OVSIsSafariFamily() && OVSSpoofedHostName().length > 0;
}

BOOL OVSShouldSpoofModel(void) {
    return OVSSpoofingEnabled() && !OVSIsSafariFamily() && OVSSpoofedModel().length > 0;
}

static NSDictionary *OVSHardwareInfoForModel(NSString *model) {
    if (model.length == 0) {
        return nil;
    }
    static NSDictionary *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"iPhone12,1": @{@"hw": @"N104AP", @"chip": @"t8030", @"ram": @4, @"ncpu": @6},
            @"iPhone12,3": @{@"hw": @"D421AP", @"chip": @"t8030", @"ram": @4, @"ncpu": @6},
            @"iPhone12,5": @{@"hw": @"D431AP", @"chip": @"t8030", @"ram": @4, @"ncpu": @6},
            @"iPhone12,8": @{@"hw": @"D79AP", @"chip": @"t8030", @"ram": @3, @"ncpu": @6},
            @"iPhone13,1": @{@"hw": @"D52gAP", @"chip": @"t8101", @"ram": @4, @"ncpu": @6},
            @"iPhone13,2": @{@"hw": @"D53gAP", @"chip": @"t8101", @"ram": @4, @"ncpu": @6},
            @"iPhone13,3": @{@"hw": @"D53pAP", @"chip": @"t8101", @"ram": @6, @"ncpu": @6},
            @"iPhone13,4": @{@"hw": @"D54pAP", @"chip": @"t8101", @"ram": @6, @"ncpu": @6},
            @"iPhone14,4": @{@"hw": @"D16AP", @"chip": @"t8110", @"ram": @4, @"ncpu": @6},
            @"iPhone14,5": @{@"hw": @"D17AP", @"chip": @"t8110", @"ram": @4, @"ncpu": @6},
            @"iPhone14,2": @{@"hw": @"D63AP", @"chip": @"t8110", @"ram": @6, @"ncpu": @6},
            @"iPhone14,3": @{@"hw": @"D64AP", @"chip": @"t8110", @"ram": @6, @"ncpu": @6},
            @"iPhone14,6": @{@"hw": @"D49AP", @"chip": @"t8110", @"ram": @4, @"ncpu": @6},
            @"iPhone14,7": @{@"hw": @"D27AP", @"chip": @"t8110", @"ram": @6, @"ncpu": @6},
            @"iPhone14,8": @{@"hw": @"D28AP", @"chip": @"t8110", @"ram": @6, @"ncpu": @6},
            @"iPhone15,2": @{@"hw": @"D73AP", @"chip": @"t8120", @"ram": @6, @"ncpu": @6},
            @"iPhone15,3": @{@"hw": @"D74AP", @"chip": @"t8120", @"ram": @6, @"ncpu": @6},
            @"iPhone15,4": @{@"hw": @"D37AP", @"chip": @"t8122", @"ram": @6, @"ncpu": @6},
            @"iPhone15,5": @{@"hw": @"D38AP", @"chip": @"t8122", @"ram": @6, @"ncpu": @6},
            @"iPhone16,1": @{@"hw": @"D83AP", @"chip": @"t8130", @"ram": @8, @"ncpu": @6},
            @"iPhone16,2": @{@"hw": @"D84AP", @"chip": @"t8130", @"ram": @8, @"ncpu": @6},
            @"iPhone17,3": @{@"hw": @"D47AP", @"chip": @"t8140", @"ram": @8, @"ncpu": @6},
            @"iPhone17,4": @{@"hw": @"D48AP", @"chip": @"t8140", @"ram": @8, @"ncpu": @6},
            @"iPhone17,1": @{@"hw": @"D93AP", @"chip": @"t8150", @"ram": @8, @"ncpu": @6},
            @"iPhone17,2": @{@"hw": @"D94AP", @"chip": @"t8150", @"ram": @8, @"ncpu": @6},
            @"iPhone17,5": @{@"hw": @"V59AP", @"chip": @"t8140", @"ram": @8, @"ncpu": @6},
            @"iPhone18,3": @{@"hw": @"V57AP", @"chip": @"t8160", @"ram": @8, @"ncpu": @6},
            @"iPhone18,4": @{@"hw": @"V58AP", @"chip": @"t8160", @"ram": @8, @"ncpu": @6},
            @"iPhone18,1": @{@"hw": @"V53AP", @"chip": @"t8170", @"ram": @12, @"ncpu": @6},
            @"iPhone18,2": @{@"hw": @"V54AP", @"chip": @"t8170", @"ram": @12, @"ncpu": @6}
        };
    });
    return map[model];
}

NSString *OVSSpoofedMarketingName(void) {
    NSString *value = OVSStringForKeys(@[@"profileProduct"], nil);
    if (value.length > 0) {
        return value;
    }
    return @"iPhone";
}

NSString *OVSSpoofedHwModel(void) {
    NSString *value = OVSStringForKeys(@[@"hwModelStr"], nil);
    if (value.length > 0) {
        return value;
    }
    NSDictionary *info = OVSHardwareInfoForModel(OVSSpoofedModel());
    return info[@"hw"];
}

NSString *OVSSpoofedHardwarePlatform(void) {
    NSString *value = OVSStringForKeys(@[@"hardwarePlatform"], nil);
    if (value.length > 0) {
        return value;
    }
    NSDictionary *info = OVSHardwareInfoForModel(OVSSpoofedModel());
    return info[@"chip"] ?: @"t8130";
}

NSInteger OVSSpoofedNCPU(void) {
    NSInteger stored = [OVSStringForKeys(@[@"ncpu"], nil) integerValue];
    if (stored > 0) {
        return stored;
    }
    NSDictionary *info = OVSHardwareInfoForModel(OVSSpoofedModel());
    NSInteger mapped = [info[@"ncpu"] integerValue];
    return mapped > 0 ? mapped : 6;
}

unsigned long long OVSSpoofedMemorySize(void) {
    NSInteger gb = [OVSStringForKeys(@[@"memoryGB"], nil) integerValue];
    if (gb <= 0) {
        gb = [OVSHardwareInfoForModel(OVSSpoofedModel())[@"ram"] integerValue];
    }
    if (gb <= 0) {
        return 0;
    }
    return (unsigned long long)gb * 1024ULL * 1024ULL * 1024ULL;
}

NSString *OVSDarwinRelease(void) {
    NSOperatingSystemVersion version = OVSSpoofedOSVersion();
    NSInteger darwinMajor = 0;
    if (version.majorVersion >= 26) {
        darwinMajor = 25 + (version.majorVersion - 26);
    } else if (version.majorVersion > 0) {
        darwinMajor = version.majorVersion + 6;
    } else {
        darwinMajor = 24;
    }
    NSInteger darwinMinor = version.minorVersion;
    if (darwinMinor < 0) {
        darwinMinor = 0;
    }
    return [NSString stringWithFormat:@"%ld.%ld.0", (long)darwinMajor, (long)darwinMinor];
}

NSString *OVSDarwinVersionString(void) {
    NSString *release = OVSDarwinRelease();
    NSString *chip = [OVSSpoofedHardwarePlatform() uppercaseString] ?: @"T8130";
    return [NSString stringWithFormat:@"Darwin Kernel Version %@: Tue Jan  6 00:00:00 PST 2026; root:xnu-11417.140.69~1/RELEASE_ARM64_%@", release, chip];
}

NSString *OVSSpoofedSerialNumber(void) {
    return OVSStringForKeys(@[@"spoofedSerialNumber"], nil);
}

NSString *OVSSpoofedUniqueDeviceID(void) {
    return OVSStringForKeys(@[@"spoofedUniqueDeviceID"], nil);
}

NSString *OVSSpoofedMLBSerial(void) {
    return OVSStringForKeys(@[@"mlbSerialNumber"], nil);
}

NSString *OVSSpoofedIMEI(void) {
    return OVSStringForKeys(@[@"spoofedIMEI"], nil);
}

NSString *OVSSpoofedWifiAddress(void) {
    return OVSStringForKeys(@[@"wifiAddress", @"macAddress"], nil);
}

NSString *OVSSpoofedBluetoothAddress(void) {
    NSString *value = OVSStringForKeys(@[@"bluetoothAddress"], nil);
    if (value.length > 0) {
        return value;
    }
    return OVSSpoofedWifiAddress();
}

NSString *OVSSpoofedRegionInfo(void) {
    NSString *stored = OVSStringForKeys(@[@"regionInfo"], nil);
    if (stored.length > 0) {
        return stored;
    }
    NSString *iso = OVSSpoofedISOCountryCode();
    if (iso.length == 0) {
        return @"US/A";
    }
    return [NSString stringWithFormat:@"%@/A", iso.uppercaseString];
}

NSString *OVSSpoofedRadioAccessTechnology(void) {
    NSString *stored = OVSStringForKeys(@[@"radioAccessTechnology"], nil);
    if (stored.length > 0) {
        return stored;
    }
    NSString *model = OVSSpoofedModel() ?: @"";
    if ([model hasPrefix:@"iPhone12,"]) {
        return @"CTRadioAccessTechnologyLTE";
    }
    return @"CTRadioAccessTechnologyNR";
}

uint64_t OVSSpoofedUniqueChipID(void) {
    NSString *raw = OVSStringForKeys(@[@"spoofedUniqueChipID"], nil);
    if (raw.length == 0) {
        return 0;
    }
    const char *cString = raw.UTF8String;
    if (!cString) {
        return 0;
    }
    if ([raw hasPrefix:@"0x"] || [raw hasPrefix:@"0X"]) {
        return strtoull(cString, NULL, 16);
    }
    return strtoull(cString, NULL, 10);
}

NSUUID *OVSSpoofedVendorUUID(void) {
    NSString *raw = OVSStringForKeys(@[@"spoofedVendorUUID"], nil);
    if (raw.length > 0) {
        NSUUID *parsed = [[NSUUID alloc] initWithUUIDString:raw];
        if (parsed) {
            return parsed;
        }
    }
    pthread_mutex_lock(&gMutex);
    if (!gVendorUUID) {
        gVendorUUID = [NSUUID UUID];
    }
    NSUUID *uuid = gVendorUUID;
    pthread_mutex_unlock(&gMutex);
    return uuid;
}

NSUUID *OVSSpoofedAdvertisingUUID(void) {
    NSString *raw = OVSStringForKeys(@[@"spoofedAdvertisingUUID"], nil);
    if (raw.length > 0) {
        NSUUID *parsed = [[NSUUID alloc] initWithUUIDString:raw];
        if (parsed) {
            return parsed;
        }
    }
    pthread_mutex_lock(&gMutex);
    if (!gAdvertisingUUID) {
        gAdvertisingUUID = [NSUUID UUID];
    }
    NSUUID *uuid = gAdvertisingUUID;
    pthread_mutex_unlock(&gMutex);
    return uuid;
}

static BOOL OVSGestaltKeyIs(NSString *key, NSString *name) {
    return [key caseInsensitiveCompare:name] == NSOrderedSame;
}

id OVSGestaltObjectForKey(NSString *key) {
    if (key.length == 0 || !OVSGestaltEnabled()) {
        return nil;
    }
    unichar first = [key characterAtIndex:0];
    if (first < 32 || first > 126) {
        return nil;
    }

    if (OVSGestaltKeyIs(key, @"ProductVersion")) {
        return OVSSpoofedOSVersionString();
    }
    if (OVSGestaltKeyIs(key, @"BuildVersion")) {
        return OVSSpoofedBuildNumber();
    }
    if (OVSGestaltKeyIs(key, @"ProductType") || OVSGestaltKeyIs(key, @"product-type")) {
        return OVSSpoofedModel();
    }
    if (OVSGestaltKeyIs(key, @"HWModelStr") || OVSGestaltKeyIs(key, @"HWModel") || OVSGestaltKeyIs(key, @"hw-model") || OVSGestaltKeyIs(key, @"HardwareModel")) {
        return OVSSpoofedHwModel();
    }
    if (OVSGestaltKeyIs(key, @"DeviceClass")) {
        return @"iPhone";
    }
    if (OVSGestaltKeyIs(key, @"DeviceName") || OVSGestaltKeyIs(key, @"marketing-name") || OVSGestaltKeyIs(key, @"MarketingProductName")) {
        return OVSSpoofedMarketingName();
    }
    if (OVSGestaltKeyIs(key, @"UserAssignedDeviceName")) {
        return OVSSpoofedDeviceName();
    }
    if (OVSGestaltKeyIs(key, @"SerialNumber")) {
        NSString *serial = OVSSpoofedSerialNumber();
        return serial.length ? serial : nil;
    }
    if (OVSGestaltKeyIs(key, @"UniqueDeviceID")) {
        NSString *udid = OVSSpoofedUniqueDeviceID();
        return udid.length ? udid : nil;
    }
    if (OVSGestaltKeyIs(key, @"WifiAddress")) {
        NSString *mac = OVSSpoofedWifiAddress();
        return mac.length ? mac : nil;
    }
    if (OVSGestaltKeyIs(key, @"BluetoothAddress")) {
        NSString *mac = OVSSpoofedBluetoothAddress();
        return mac.length ? mac : nil;
    }
    return nil;
}

BOOL OVSLocaleEnabled(void) {
    return !OVSIsFragileApp() && !OVSIsSafariFamily() && OVSSpoofingEnabled() && OVSBoolForKey(@"localeEnabled", NO);
}

NSString *OVSSpoofedLocaleIdentifier(void) {
    return OVSStringForKey(@"localeIdentifier", @"en_US");
}

NSString *OVSSpoofedLanguageCode(void) {
    NSString *locale = OVSSpoofedLocaleIdentifier();
    NSArray<NSString *> *parts = [locale componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"_-"]];
    return parts.count > 0 ? parts[0] : @"en";
}

NSString *OVSSpoofedTimeZoneName(void) {
    return OVSStringForKey(@"timeZoneName", @"America/Los_Angeles");
}

BOOL OVSCarrierEnabled(void) {
    return !OVSIsFragileApp() && !OVSIsSafariFamily() && OVSSpoofingEnabled() && OVSBoolForKey(@"carrierEnabled", NO);
}

NSString *OVSSpoofedCarrierName(void) {
    return OVSStringForKey(@"carrierName", @"Carrier");
}

NSString *OVSSpoofedMCC(void) {
    return OVSStringForKey(@"mobileCountryCode", @"310");
}

NSString *OVSSpoofedMNC(void) {
    return OVSStringForKey(@"mobileNetworkCode", @"260");
}

NSString *OVSSpoofedISOCountryCode(void) {
    return OVSStringForKey(@"isoCountryCode", @"us");
}

static NSDate *OVSParseISODate(NSString *rawTime) {
    if (rawTime.length == 0) {
        return nil;
    }
    static NSDateFormatter *basicFormatter;
    static NSDateFormatter *fractionalFormatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        basicFormatter = [[NSDateFormatter alloc] init];
        basicFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        basicFormatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        basicFormatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
        fractionalFormatter = [[NSDateFormatter alloc] init];
        fractionalFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fractionalFormatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        fractionalFormatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    });
    return [basicFormatter dateFromString:rawTime] ?: [fractionalFormatter dateFromString:rawTime];
}

static CLLocation *OVSMakeLocation(double lat, double lon, double alt, double accuracy, NSDate *timestamp) {
    OVSBeginLocationHookBypass();
    CLLocation *location = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(lat, lon)
                                                         altitude:alt
                                               horizontalAccuracy:accuracy
                                                 verticalAccuracy:accuracy
                                                           course:-1.0
                                                            speed:-1.0
                                                        timestamp:timestamp ?: [NSDate date]];
    OVSEndLocationHookBypass();
    return location;
}

static void OVSEnsureGPXLoaded(void) {
    NSString *path = OVSStringForKey(@"gpxPath", nil);
    pthread_mutex_lock(&gMutex);
    BOOL alreadyLoaded = [gLoadedGPXPath isEqualToString:path] && gGPXLocations != nil;
    pthread_mutex_unlock(&gMutex);
    if (alreadyLoaded || path.length == 0) {
        return;
    }

    NSString *xml = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (xml.length == 0) {
        return;
    }

    NSRegularExpression *pointRegex = [NSRegularExpression regularExpressionWithPattern:@"<trkpt\\b([^>]*)>([\\s\\S]*?)</trkpt>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *latRegex = [NSRegularExpression regularExpressionWithPattern:@"\\blat=\"([^\"]+)\"" options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *lonRegex = [NSRegularExpression regularExpressionWithPattern:@"\\blon=\"([^\"]+)\"" options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *eleRegex = [NSRegularExpression regularExpressionWithPattern:@"<ele>\\s*([^<]+)\\s*</ele>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *timeRegex = [NSRegularExpression regularExpressionWithPattern:@"<time>\\s*([^<]+)\\s*</time>" options:NSRegularExpressionCaseInsensitive error:nil];
    
    NSMutableArray<CLLocation *> *points = [NSMutableArray array];
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
    NSDate *firstDate = nil;
    NSTimeInterval fallbackOffset = 0;

    NSArray<NSTextCheckingResult *> *matches = [pointRegex matchesInString:xml options:0 range:NSMakeRange(0, xml.length)];
    for (NSTextCheckingResult *match in matches) {
        if (match.numberOfRanges < 3) {
            continue;
        }
        NSString *attrs = [xml substringWithRange:[match rangeAtIndex:1]];
        NSString *inner = [xml substringWithRange:[match rangeAtIndex:2]];
        NSTextCheckingResult *latMatch = [latRegex firstMatchInString:attrs options:0 range:NSMakeRange(0, attrs.length)];
        NSTextCheckingResult *lonMatch = [lonRegex firstMatchInString:attrs options:0 range:NSMakeRange(0, attrs.length)];
        if (!latMatch || !lonMatch) {
            continue;
        }
        double lat = [[attrs substringWithRange:[latMatch rangeAtIndex:1]] doubleValue];
        double lon = [[attrs substringWithRange:[lonMatch rangeAtIndex:1]] doubleValue];
        double alt = 0;
        NSTextCheckingResult *eleMatch = [eleRegex firstMatchInString:inner options:0 range:NSMakeRange(0, inner.length)];
        if (eleMatch) {
            alt = [[inner substringWithRange:[eleMatch rangeAtIndex:1]] doubleValue];
        }
        NSTimeInterval offset = fallbackOffset;
        NSTextCheckingResult *timeMatch = [timeRegex firstMatchInString:inner options:0 range:NSMakeRange(0, inner.length)];
        if (timeMatch) {
            NSString *rawTime = [inner substringWithRange:[timeMatch rangeAtIndex:1]];
            NSDate *date = OVSParseISODate(rawTime);
            if (date) {
                if (!firstDate) {
                    firstDate = date;
                }
                offset = [date timeIntervalSinceDate:firstDate];
            }
        }
        [points addObject:OVSMakeLocation(lat, lon, alt, 5.0, nil)];
        [offsets addObject:@(offset)];
        fallbackOffset += 1.0;
    }

    pthread_mutex_lock(&gMutex);
    gGPXLocations = [points copy];
    gGPXOffsets = [offsets copy];
    gLoadedGPXPath = [path copy];
    pthread_mutex_unlock(&gMutex);
}

BOOL OVSLocationEnabled(void) {
    if (OVSIsFragileApp() || !OVSSpoofingEnabled() || !OVSBoolForKey(@"locationEnabled", NO)) {
        return NO;
    }
    NSString *gpxPath = OVSStringForKey(@"gpxPath", nil);
    if (gpxPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:gpxPath]) {
        return YES;
    }
    id lat = OVSObjectForKey(@"latitude");
    id lon = OVSObjectForKey(@"longitude");
    return lat != nil && lon != nil &&
           ([lat isKindOfClass:[NSNumber class]] || [lat isKindOfClass:[NSString class]]) &&
           ([lon isKindOfClass:[NSNumber class]] || [lon isKindOfClass:[NSString class]]);
}

CLLocation *OVSSpoofedLocation(void) {
    if (!OVSLocationEnabled()) {
        return nil;
    }

    OVSEnsureGPXLoaded();
    double accuracy = OVSDoubleForKey(@"accuracy", 5.0);
    if (accuracy <= 0) {
        accuracy = 5.0;
    }

    pthread_mutex_lock(&gMutex);
    if (gLocationEpoch == 0) {
        gLocationEpoch = [NSDate date].timeIntervalSinceReferenceDate;
    }
    NSTimeInterval elapsed = [NSDate date].timeIntervalSinceReferenceDate - gLocationEpoch;
    NSArray<CLLocation *> *points = gGPXLocations;
    NSArray<NSNumber *> *offsets = gGPXOffsets;
    pthread_mutex_unlock(&gMutex);

    if (points.count > 0) {
        NSTimeInterval duration = offsets.lastObject.doubleValue;
        if (duration > 0) {
            NSTimeInterval needle = fmod(elapsed, duration + 1.0);
            NSUInteger chosen = 0;
            for (NSUInteger i = 0; i < offsets.count; i++) {
                if (offsets[i].doubleValue <= needle) {
                    chosen = i;
                } else {
                    break;
                }
            }
            CLLocation *point = points[chosen];
            OVSBeginLocationHookBypass();
            double pointLat = point.coordinate.latitude;
            double pointLon = point.coordinate.longitude;
            double pointAlt = point.altitude;
            OVSEndLocationHookBypass();
            return OVSMakeLocation(pointLat, pointLon, pointAlt, accuracy, [NSDate date]);
        }
        NSUInteger index = ((NSUInteger)elapsed) % points.count;
        CLLocation *point = points[index];
        OVSBeginLocationHookBypass();
            double pointLat = point.coordinate.latitude;
            double pointLon = point.coordinate.longitude;
            double pointAlt = point.altitude;
            OVSEndLocationHookBypass();
            return OVSMakeLocation(pointLat, pointLon, pointAlt, accuracy, [NSDate date]);
    }

    return OVSMakeLocation(
        OVSDoubleForKey(@"latitude", 0),
        OVSDoubleForKey(@"longitude", 0),
        OVSDoubleForKey(@"altitude", 0),
        accuracy,
        [NSDate date]
    );
}

BOOL OVSNetworkEnabled(void) {
    if (OVSIsFragileApp() || OVSIsSafariFamily() || !OVSSpoofingEnabled() || !OVSBoolForKey(@"networkEnabled", NO)) {
        return NO;
    }
    return OVSSpoofedIPv4().length > 0 ||
           OVSSpoofedIPv6().length > 0 ||
           OVSSpoofedMACAddress().length > 0 ||
           OVSSpoofedWifiSSID().length > 0 ||
           OVSSpoofedWifiBSSID().length > 0 ||
           OVSSpoofedWifiGateway().length > 0;
}

NSString *OVSSpoofedIPv4(void) {
    return OVSStringForKey(@"ipv4Address", nil);
}

NSString *OVSSpoofedIPv6(void) {
    return OVSStringForKey(@"ipv6Address", nil);
}

NSString *OVSSpoofedMACAddress(void) {
    return OVSStringForKey(@"macAddress", nil);
}

NSString *OVSSpoofedInterfaceName(void) {
    return OVSStringForKey(@"interfaceName", @"en0");
}

NSString *OVSSpoofedWifiSSID(void) {
    return OVSStringForKey(@"wifiSSID", nil);
}

NSString *OVSSpoofedWifiBSSID(void) {
    return OVSStringForKey(@"wifiBSSID", nil);
}

NSString *OVSSpoofedWifiGateway(void) {
    return OVSStringForKey(@"wifiGateway", nil);
}

NSString *OVSSpoofedWifiRSSI(void) {
    return OVSStringForKey(@"wifiRSSI", nil);
}

NSDictionary *OVSSpoofedCaptiveNetworkInfo(void) {
    NSString *ssid = OVSSpoofedWifiSSID();
    NSString *bssid = OVSSpoofedWifiBSSID();
    if (ssid.length == 0 && bssid.length == 0) {
        return nil;
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (ssid.length > 0) {
        info[@"SSID"] = ssid;
        NSData *data = [ssid dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length > 0) {
            info[@"SSIDDATA"] = data;
        }
    }
    if (bssid.length > 0) {
        info[@"BSSID"] = bssid;
    }
    return [info copy];
}

double OVSSpoofedWifiSignalStrength(void) {
    NSString *raw = OVSSpoofedWifiRSSI();
    if (raw.length == 0) {
        return 0.72;
    }
    double dbm = raw.doubleValue;
    double normalized = (dbm + 90.0) / 60.0;
    if (normalized < 0.0) {
        return 0.0;
    }
    if (normalized > 1.0) {
        return 1.0;
    }
    return normalized;
}

static NSString *OVSReplaceFirst(NSString *input, NSString *pattern, NSString *replacement) {
    if (input.length == 0 || pattern.length == 0 || !replacement) {
        return input;
    }
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&error];
    if (!regex || error) {
        return input;
    }
    NSTextCheckingResult *match = [regex firstMatchInString:input options:0 range:NSMakeRange(0, input.length)];
    if (!match || match.numberOfRanges < 2) {
        return input;
    }
    return [input stringByReplacingCharactersInRange:[match rangeAtIndex:1] withString:replacement];
}

NSString *OVSSpoofedSafariUserAgent(void) {
    NSString *os = OVSSpoofedOSVersionUnderscore() ?: @"18_0";
    NSString *build = OVSSpoofedBuildNumber() ?: @"22A3354";
    NSInteger major = OVSSpoofedOSVersion().majorVersion;
    if (major <= 0) {
        major = 18;
    }
    NSString *model = OVSSpoofedModel() ?: @"";
    NSString *device = [model.lowercaseString hasPrefix:@"ipad"] ? @"iPad" : @"iPhone";
    return [NSString stringWithFormat:@"Mozilla/5.0 (%@; CPU %@ OS %@ like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/%ld.0 Mobile/%@ Safari/604.1", device, device, os, (long)major, build];
}

NSString *OVSRewriteUserAgent(NSString *userAgent, BOOL rewriteAppVersion) {
    if (userAgent.length == 0) {
        return OVSSpoofingEnabled() ? OVSSpoofedSafariUserAgent() : userAgent;
    }

    NSString *underscore = OVSSpoofedOSVersionUnderscore();
    NSString *dotted = OVSSpoofedOSVersionString();
    NSString *rewritten = userAgent;
    rewritten = OVSReplaceFirst(rewritten, @"OS (\\d+(?:_\\d+)*) like Mac OS X", underscore);
    rewritten = OVSReplaceFirst(rewritten, @"iOS/(\\d+(?:\\.\\d+)*)", dotted);
    rewritten = OVSReplaceFirst(rewritten, @"Version/(\\d+(?:\\.\\d+)*)", [NSString stringWithFormat:@"%ld.0", (long)OVSSpoofedOSVersion().majorVersion]);
    rewritten = OVSReplaceFirst(rewritten, @"Mobile/([A-Za-z0-9]+)", OVSSpoofedBuildNumber());

    if (rewriteAppVersion) {
        NSString *appVersion = OVSSpoofedAppVersion();
        rewritten = OVSReplaceFirst(rewritten, @"(?i)(?:app(?:ver|[-_]version)|CFNetworkAppVersion)=(\\d+(?:\\.\\d+)*)", appVersion);
        rewritten = OVSReplaceFirst(rewritten, @"(?i)(?:app(?:ver|[-_]version))/(\\d+(?:\\.\\d+)*)", appVersion);
    }
    return rewritten;
}


__attribute__((constructor))
static void OVSPrefsConstructor(void) {
    if (OVSIsProtectedProcess()) {
        return;
    }
    OVSRegisterPreferenceListener();
}
