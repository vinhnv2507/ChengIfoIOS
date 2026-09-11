#import "Prefs.h"

#import <string.h>
#import <sys/utsname.h>

%hook NSLocale
+ (NSArray *)preferredLanguages {
    return OVSLocaleEnabled() ? @[OVSSpoofedLanguageCode()] : %orig;
}


+ (NSLocale *)currentLocale {
    return OVSLocaleEnabled() ? [[NSLocale alloc] initWithLocaleIdentifier:OVSSpoofedLocaleIdentifier()] : %orig;
}

+ (NSLocale *)systemLocale {
    return OVSLocaleEnabled() ? [[NSLocale alloc] initWithLocaleIdentifier:OVSSpoofedLocaleIdentifier()] : %orig;
}

+ (NSLocale *)autoupdatingCurrentLocale {
    return OVSLocaleEnabled() ? [[NSLocale alloc] initWithLocaleIdentifier:OVSSpoofedLocaleIdentifier()] : %orig;
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
%end

%group TelephonyHooks
%hook CTCarrier
- (NSString *)carrierName {
    return OVSCarrierEnabled() ? OVSSpoofedCarrierName() : %orig;
}

- (NSString *)mobileCountryCode {
    return OVSCarrierEnabled() ? OVSSpoofedMCC() : %orig;
}

- (NSString *)mobileNetworkCode {
    return OVSCarrierEnabled() ? OVSSpoofedMNC() : %orig;
}

- (NSString *)isoCountryCode {
    return OVSCarrierEnabled() ? OVSSpoofedISOCountryCode() : %orig;
}
%end
%end

%group AdSupportHooks
%hook ASIdentifierManager
- (NSUUID *)advertisingIdentifier {
    return OVSDeviceIdentityEnabled() ? OVSSpoofedAdvertisingUUID() : %orig;
}

- (BOOL)isAdvertisingTrackingEnabled {
    return OVSDeviceIdentityEnabled() ? NO : %orig;
}
%end
%end

%hook BrowserController
- (NSUUID *)UUID {
    return OVSDeviceIdentityEnabled() ? OVSSpoofedVendorUUID() : %orig;
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
    }
    return result;
}

%ctor {
    if (OVSIsProtectedProcess()) {
        return;
    }
    %init;
    if (NSClassFromString(@"CTCarrier")) {
        %init(TelephonyHooks);
    }
    if (NSClassFromString(@"ASIdentifierManager")) {
        %init(AdSupportHooks);
    }
}
