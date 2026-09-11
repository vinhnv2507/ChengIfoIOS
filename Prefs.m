#import "Prefs.h"

#import <pthread.h>
#import <stdint.h>
#import <math.h>

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

BOOL OVSMasterEnabled(void) {
    return OVSBoolForKey(@"masterEnabled", YES);
}

BOOL OVSAppSelected(void) {
    NSString *bundleIdentifier = OVSMainBundleIdentifier();
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

BOOL OVSSpoofingEnabled(void) {
    if (OVSIsProtectedProcess()) {
        return NO;
    }
    return OVSMasterEnabled() && OVSAppSelected();
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
    return OVSSpoofingEnabled() && OVSBoolForKey(@"appVersionEnabled", YES);
}

NSString *OVSSpoofedAppVersion(void) {
    return OVSStringForKey(@"customAppVersion", @"2147483647");
}

BOOL OVSDeviceIdentityEnabled(void) {
    return OVSSpoofingEnabled() && OVSBoolForKey(@"deviceIdentityEnabled", NO);
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
    return OVSSpoofingEnabled() && OVSSpoofedDeviceName().length > 0;
}

BOOL OVSShouldSpoofHostName(void) {
    return OVSSpoofingEnabled() && OVSSpoofedHostName().length > 0;
}

BOOL OVSShouldSpoofModel(void) {
    return OVSSpoofingEnabled() && OVSSpoofedModel().length > 0;
}

NSUUID *OVSSpoofedVendorUUID(void) {
    pthread_mutex_lock(&gMutex);
    if (!gVendorUUID) {
        gVendorUUID = [NSUUID UUID];
    }
    NSUUID *uuid = gVendorUUID;
    pthread_mutex_unlock(&gMutex);
    return uuid;
}

NSUUID *OVSSpoofedAdvertisingUUID(void) {
    pthread_mutex_lock(&gMutex);
    if (!gAdvertisingUUID) {
        gAdvertisingUUID = [NSUUID UUID];
    }
    NSUUID *uuid = gAdvertisingUUID;
    pthread_mutex_unlock(&gMutex);
    return uuid;
}

BOOL OVSLocaleEnabled(void) {
    return OVSSpoofingEnabled() && OVSBoolForKey(@"localeEnabled", NO);
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
    return OVSSpoofingEnabled() && OVSBoolForKey(@"carrierEnabled", NO);
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
    if (!OVSSpoofingEnabled() || !OVSBoolForKey(@"locationEnabled", NO)) {
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
    if (!OVSSpoofingEnabled() || !OVSBoolForKey(@"networkEnabled", NO)) {
        return NO;
    }
    return OVSSpoofedIPv4().length > 0 || OVSSpoofedIPv6().length > 0 || OVSSpoofedMACAddress().length > 0;
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

NSString *OVSRewriteUserAgent(NSString *userAgent, BOOL rewriteAppVersion) {
    if (userAgent.length == 0) {
        return userAgent;
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
