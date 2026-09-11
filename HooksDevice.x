#import "Prefs.h"

#import <CoreFoundation/CoreFoundation.h>

#import <string.h>
#import <sys/utsname.h>

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

%hookf(CFLocaleRef, CFLocaleCopyCurrent) {
    if (!OVSLocaleEnabled()) {
        CFLocaleRef original = %orig();
        return original;
    }
    NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:OVSSpoofedLocaleIdentifier()];
    return (CFLocaleRef)CFBridgingRetain(locale);
}

%hookf(CFTimeZoneRef, CFTimeZoneCopySystem) {
    if (!OVSLocaleEnabled()) {
        CFTimeZoneRef original = %orig();
        return original;
    }
    NSTimeZone *timeZone = [NSTimeZone timeZoneWithName:OVSSpoofedTimeZoneName()];
    if (!timeZone) {
        CFTimeZoneRef original = %orig();
        return original;
    }
    return (CFTimeZoneRef)CFBridgingRetain(timeZone);
}

%hookf(CFTimeZoneRef, CFTimeZoneCopyDefault) {
    if (!OVSLocaleEnabled()) {
        CFTimeZoneRef original = %orig();
        return original;
    }
    NSTimeZone *timeZone = [NSTimeZone timeZoneWithName:OVSSpoofedTimeZoneName()];
    if (!timeZone) {
        CFTimeZoneRef original = %orig();
        return original;
    }
    return (CFTimeZoneRef)CFBridgingRetain(timeZone);
}

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
    if (!OVSCarrierEnabled()) {
        return original;
    }
    NSString *tech = OVSSpoofedRadioAccessTechnology();
    if ([original isKindOfClass:[NSDictionary class]] && original.count > 0) {
        NSMutableDictionary *rewritten = [original mutableCopy];
        for (id key in original.allKeys) {
            rewritten[key] = tech;
        }
        return rewritten;
    }
    return @{@"0000000100000001": tech};
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

%hook BrowserController
- (NSUUID *)UUID {
    if (!OVSDeviceIdentityEnabled()) {
        return %orig;
    }
    return OVSSpoofedVendorUUID();
}
%end

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
        if (OVSSpoofingEnabled()) {
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

%ctor {
    if (OVSIsProtectedProcess()) {
        return;
    }
    %init;
    if (NSClassFromString(@"CTCarrier") || NSClassFromString(@"CTTelephonyNetworkInfo")) {
        %init(TelephonyHooks);
    }
    if (NSClassFromString(@"ASIdentifierManager")) {
        %init(AdSupportHooks);
    }
}
