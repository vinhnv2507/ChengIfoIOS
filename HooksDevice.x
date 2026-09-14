#import "Prefs.h"

#import <objc/runtime.h>
#import <substrate.h>

#import <CoreFoundation/CoreFoundation.h>

#import <string.h>
#import <sys/utsname.h>

%group LocaleClassHooks
%hook NSLocale
+ (NSArray *)preferredLanguages {
    if (!OVSLocaleEnabled()) {
        return %orig;
    }
    return @[OVSSpoofedLanguageCode()];
}

+ (NSLocale *)currentLocale {
    if (!OVSLocaleEnabled()) {
        return %orig;
    }
    return [[NSLocale alloc] initWithLocaleIdentifier:OVSSpoofedLocaleIdentifier()];
}

+ (NSLocale *)systemLocale {
    if (!OVSLocaleEnabled()) {
        return %orig;
    }
    return [[NSLocale alloc] initWithLocaleIdentifier:OVSSpoofedLocaleIdentifier()];
}

+ (NSLocale *)autoupdatingCurrentLocale {
    if (!OVSLocaleEnabled()) {
        return %orig;
    }
    return [[NSLocale alloc] initWithLocaleIdentifier:OVSSpoofedLocaleIdentifier()];
}
%end

%hook NSTimeZone
+ (NSTimeZone *)systemTimeZone {
    if (OVSLocaleEnabled()) {
        NSTimeZone *timeZone = [NSTimeZone timeZoneWithName:OVSSpoofedTimeZoneName()];
        if (timeZone) {
            return timeZone;
        }
    }
    return %orig;
}

+ (NSTimeZone *)defaultTimeZone {
    if (OVSLocaleEnabled()) {
        NSTimeZone *timeZone = [NSTimeZone timeZoneWithName:OVSSpoofedTimeZoneName()];
        if (timeZone) {
            return timeZone;
        }
    }
    return %orig;
}

+ (NSTimeZone *)localTimeZone {
    if (OVSLocaleEnabled()) {
        NSTimeZone *timeZone = [NSTimeZone timeZoneWithName:OVSSpoofedTimeZoneName()];
        if (timeZone) {
            return timeZone;
        }
    }
    return %orig;
}
%end
%end

%group LocaleDefaultsHooks
%hook NSUserDefaults
- (id)objectForKey:(NSString *)defaultName {
    if (OVSLocaleEnabled()) {
        if ([defaultName isEqualToString:@"AppleLanguages"]) {
            return @[OVSSpoofedLanguageCode()];
        }
        if ([defaultName isEqualToString:@"AppleLocale"]) {
            return OVSSpoofedLocaleIdentifier();
        }
    }
    return %orig;
}

- (NSArray *)arrayForKey:(NSString *)defaultName {
    if (OVSLocaleEnabled() && [defaultName isEqualToString:@"AppleLanguages"]) {
        return @[OVSSpoofedLanguageCode()];
    }
    return %orig;
}

- (NSString *)stringForKey:(NSString *)defaultName {
    if (OVSLocaleEnabled() && [defaultName isEqualToString:@"AppleLocale"]) {
        return OVSSpoofedLocaleIdentifier();
    }
    return %orig;
}
%end
%end

%group TelephonyHooks
%hook CTCarrier
- (NSString *)carrierName {
    if (!OVSCarrierEnabled()) {
        return %orig;
    }
    return OVSSpoofedCarrierName();
}

- (NSString *)mobileCountryCode {
    if (!OVSCarrierEnabled()) {
        return %orig;
    }
    return OVSSpoofedMCC();
}

- (NSString *)mobileNetworkCode {
    if (!OVSCarrierEnabled()) {
        return %orig;
    }
    return OVSSpoofedMNC();
}

- (NSString *)isoCountryCode {
    if (!OVSCarrierEnabled()) {
        return %orig;
    }
    return OVSSpoofedISOCountryCode();
}

- (BOOL)allowsVOIP {
    if (!OVSCarrierEnabled()) {
        return %orig;
    }
    return YES;
}
%end

%hook CTTelephonyNetworkInfo
- (NSString *)currentRadioAccessTechnology {
    if (!OVSCarrierEnabled()) {
        return %orig;
    }
    return OVSSpoofedRadioAccessTechnology();
}

- (NSDictionary *)serviceCurrentRadioAccessTechnology {
    NSDictionary *original = %orig;
    if (!OVSCarrierEnabled() || ![original isKindOfClass:[NSDictionary class]] || original.count == 0) {
        return original;
    }
    NSString *tech = OVSSpoofedRadioAccessTechnology();
    NSMutableDictionary *rewritten = [original mutableCopy];
    for (id key in original.allKeys) {
        rewritten[key] = tech;
    }
    return rewritten;
}
%end
%end

%group AdSupportHooks
%hook ASIdentifierManager
- (NSUUID *)advertisingIdentifier {
    if (!OVSDeviceIdentityEnabled()) {
        return %orig;
    }
    return OVSSpoofedAdvertisingUUID();
}

- (BOOL)isAdvertisingTrackingEnabled {
    if (!OVSDeviceIdentityEnabled()) {
        return %orig;
    }
    return NO;
}
%end
%end

static BOOL (*CIOrigDCIsSupported)(id, SEL);
static BOOL CIHookedDCIsSupported(id self, SEL _cmd) {
    if (OVSSpoofingEnabled() && OVSIsShopeeFamily()) {
        return NO;
    }
    return CIOrigDCIsSupported ? CIOrigDCIsSupported(self, _cmd) : NO;
}

static void (*CIOrigDCGenerateToken)(id, SEL, id);
static void CIHookedDCGenerateToken(id self, SEL _cmd, id completion) {
    if (OVSSpoofingEnabled() && OVSIsShopeeFamily()) {
        if (completion) {
            void (^block)(NSData *, NSError *) = completion;
            block(nil, [NSError errorWithDomain:@"com.vinhnv2507.chengios" code:2 userInfo:nil]);
        }
        return;
    }
    if (CIOrigDCGenerateToken) {
        CIOrigDCGenerateToken(self, _cmd, completion);
    }
}

static BOOL (*CIOrigAttestIsSupported)(id, SEL);
static BOOL CIHookedAttestIsSupported(id self, SEL _cmd) {
    if (OVSSpoofingEnabled() && OVSIsShopeeFamily()) {
        return NO;
    }
    return CIOrigAttestIsSupported ? CIOrigAttestIsSupported(self, _cmd) : NO;
}

static void CIInstallShopeeDeviceCheckHooks(void) {
    Class dc = NSClassFromString(@"DCDevice");
    if (dc) {
        MSHookMessageEx(dc, @selector(isSupported), (IMP)CIHookedDCIsSupported, (IMP *)&CIOrigDCIsSupported);
        MSHookMessageEx(dc, NSSelectorFromString(@"generateTokenWithCompletionHandler:"), (IMP)CIHookedDCGenerateToken, (IMP *)&CIOrigDCGenerateToken);
    }
    Class attest = NSClassFromString(@"DCAppAttestService");
    if (attest) {
        MSHookMessageEx(attest, @selector(isSupported), (IMP)CIHookedAttestIsSupported, (IMP *)&CIOrigAttestIsSupported);
    }
}

%hook BrowserController
- (NSUUID *)UUID {
    if (!OVSDeviceIdentityEnabled()) {
        return %orig;
    }
    return OVSSpoofedVendorUUID();
}
%end

%group LowLevelUname
%hookf(int, uname, struct utsname *name) {
    int result = %orig(name);
    if (result == 0 && name) {
        if (OVSShouldSpoofHostName()) {
            NSString *hostName = OVSSpoofedHostName();
            strncpy(name->nodename, hostName.UTF8String, sizeof(name->nodename) - 1);
            name->nodename[sizeof(name->nodename) - 1] = '\0';
        }
        if (OVSShouldSpoofModel()) {
            NSString *model = OVSSpoofedModel();
            strncpy(name->machine, model.UTF8String, sizeof(name->machine) - 1);
            name->machine[sizeof(name->machine) - 1] = '\0';
        }
        if (OVSGestaltEnabled()) {
            strncpy(name->sysname, "Darwin", sizeof(name->sysname) - 1);
            name->sysname[sizeof(name->sysname) - 1] = '\0';
            NSString *release = OVSDarwinRelease();
            strncpy(name->release, release.UTF8String, sizeof(name->release) - 1);
            name->release[sizeof(name->release) - 1] = '\0';
            NSString *version = OVSDarwinVersionString();
            strncpy(name->version, version.UTF8String, sizeof(name->version) - 1);
            name->version[sizeof(name->version) - 1] = '\0';
        }
    }
    return result;
}
%end

%ctor {
    if (OVSIsProtectedProcess() || OVSIsWebKitHelperProcess()) {
        return;
    }
    %init;
    if (!OVSIsFragileApp()) {
        %init(LocaleClassHooks);
        if (OVSLocaleEnabled()) {
            %init(LocaleDefaultsHooks);
        }
        if (NSClassFromString(@"CTCarrier") || NSClassFromString(@"CTTelephonyNetworkInfo")) {
            %init(TelephonyHooks);
        }
        if (NSClassFromString(@"ASIdentifierManager")) {
            %init(AdSupportHooks);
        }
    } else if (OVSIsShopeeFamily() && OVSSpoofingEnabled()) {
        if (NSClassFromString(@"ASIdentifierManager")) {
            %init(AdSupportHooks);
        }
        CIInstallShopeeDeviceCheckHooks();
    }
    if (OVSLowLevelHooksEnabled() || OVSMachineHooksEnabled()) {
        %init(LowLevelUname);
    }
}
