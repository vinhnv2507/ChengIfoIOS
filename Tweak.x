#import "Prefs.h"

#import <UIKit/UIKit.h>

#import <errno.h>
#import <string.h>
#import <sys/sysctl.h>
#import <sys/types.h>
#import <stdint.h>

static BOOL OVSIsMainBundle(NSBundle *bundle) {
    NSString *mainPath = OVSMainBundlePath();
    return bundle && mainPath.length > 0 && [bundle.bundlePath isEqualToString:mainPath];
}

static NSDictionary *OVSSpoofedInfoDictionary(NSDictionary *original) {
    if (!original || !OVSAppVersionEnabled()) {
        return original;
    }
    NSMutableDictionary *dictionary = [original mutableCopy];
    NSString *version = OVSSpoofedAppVersion();
    dictionary[@"CFBundleShortVersionString"] = version;
    dictionary[@"CFBundleVersion"] = version;
    return dictionary;
}

static NSString *OVSRewriteIfNeeded(NSString *userAgent) {
    if (!OVSSpoofingEnabled() || userAgent.length == 0) {
        return userAgent;
    }
    return OVSRewriteUserAgent(userAgent, OVSAppVersionEnabled());
}

static NSDictionary *OVSRewriteHeaderDictionary(NSDictionary *headers) {
    if (!OVSSpoofingEnabled() || headers.count == 0) {
        return headers;
    }
    NSString *userAgent = nil;
    NSString *headerKey = nil;
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) {
            userAgent = headers[key];
            headerKey = key;
            break;
        }
    }
    if (userAgent.length == 0) {
        return headers;
    }
    NSMutableDictionary *rewritten = [headers mutableCopy];
    rewritten[headerKey] = OVSRewriteIfNeeded(userAgent);
    return rewritten;
}

static int OVSSysctlCopyBytes(void *oldp, size_t *oldlenp, const void *value, size_t length) {
    if (!oldp) {
        if (oldlenp) {
            *oldlenp = length;
        }
        return 0;
    }
    if (!oldlenp || *oldlenp < length) {
        if (oldlenp) {
            *oldlenp = length;
        }
        errno = ENOMEM;
        return -1;
    }
    memcpy(oldp, value, length);
    *oldlenp = length;
    return 0;
}

static int OVSSysctlCopyString(void *oldp, size_t *oldlenp, const char *value) {
    return OVSSysctlCopyBytes(oldp, oldlenp, value, strlen(value) + 1);
}

%hook NSProcessInfo
- (NSOperatingSystemVersion)operatingSystemVersion {
    if (!OVSSpoofingEnabled()) {
        NSOperatingSystemVersion original = %orig;
        return original;
    }
    return OVSSpoofedOSVersion();
}

- (NSString *)operatingSystemVersionString {
    if (!OVSSpoofingEnabled()) {
        return %orig;
    }
    return [NSString stringWithFormat:@"Version %@ (Build %@)", OVSSpoofedOSVersionString(), OVSSpoofedBuildNumber()];
}

- (BOOL)isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion)version {
    if (!OVSSpoofingEnabled()) {
        return %orig;
    }
    NSOperatingSystemVersion spoofed = OVSSpoofedOSVersion();
    if (spoofed.majorVersion != version.majorVersion) {
        return spoofed.majorVersion > version.majorVersion;
    }
    if (spoofed.minorVersion != version.minorVersion) {
        return spoofed.minorVersion > version.minorVersion;
    }
    return spoofed.patchVersion >= version.patchVersion;
}

- (NSString *)hostName {
    if (!OVSShouldSpoofHostName()) {
        return %orig;
    }
    return OVSSpoofedHostName();
}

- (NSUInteger)processorCount {
    if (!OVSDeviceIdentityEnabled()) {
        NSUInteger original = %orig;
        return original;
    }
    NSInteger ncpu = OVSSpoofedNCPU();
    if (ncpu <= 0) {
        NSUInteger original = %orig;
        return original;
    }
    return (NSUInteger)ncpu;
}

- (NSUInteger)activeProcessorCount {
    if (!OVSDeviceIdentityEnabled()) {
        NSUInteger original = %orig;
        return original;
    }
    NSInteger ncpu = OVSSpoofedNCPU();
    if (ncpu <= 0) {
        NSUInteger original = %orig;
        return original;
    }
    return (NSUInteger)ncpu;
}

- (unsigned long long)physicalMemory {
    if (!OVSDeviceIdentityEnabled()) {
        unsigned long long original = %orig;
        return original;
    }
    unsigned long long spoofed = OVSSpoofedMemorySize();
    if (spoofed == 0) {
        unsigned long long original = %orig;
        return original;
    }
    return spoofed;
}
%end

%hook UIDevice
- (NSString *)systemVersion {
    if (!OVSSpoofingEnabled()) {
        return %orig;
    }
    return OVSSpoofedOSVersionString();
}

- (id)buildVersion {
    if (!OVSSpoofingEnabled()) {
        return %orig;
    }
    return OVSSpoofedBuildNumber();
}

- (NSString *)name {
    if (!OVSShouldSpoofDeviceName()) {
        return %orig;
    }
    return OVSSpoofedDeviceName();
}

- (NSString *)hostName {
    if (!OVSShouldSpoofHostName()) {
        return %orig;
    }
    return OVSSpoofedHostName();
}

- (NSString *)model {
    if (!OVSShouldSpoofModel()) {
        return %orig;
    }
    return OVSSpoofedModel();
}

- (NSString *)localizedModel {
    if (!OVSShouldSpoofModel()) {
        return %orig;
    }
    return OVSSpoofedModel();
}

- (NSUUID *)identifierForVendor {
    if (!OVSDeviceIdentityEnabled()) {
        return %orig;
    }
    return OVSSpoofedVendorUUID();
}
%end

%hook NSBundle
- (NSDictionary *)infoDictionary {
    NSDictionary *original = %orig;
    return OVSIsMainBundle(self) ? OVSSpoofedInfoDictionary(original) : original;
}

- (NSDictionary *)localizedInfoDictionary {
    NSDictionary *original = %orig;
    return OVSIsMainBundle(self) ? OVSSpoofedInfoDictionary(original) : original;
}

- (id)objectForInfoDictionaryKey:(NSString *)key {
    id original = %orig;
    if (!OVSIsMainBundle(self) || !OVSAppVersionEnabled()) {
        return original;
    }
    if ([key isEqualToString:@"CFBundleShortVersionString"] || [key isEqualToString:@"CFBundleVersion"]) {
        return OVSSpoofedAppVersion();
    }
    return original;
}
%end

%hook NSMutableURLRequest
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)header {
    if (value && [header caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) {
        value = OVSRewriteIfNeeded(value);
    }
    %orig(value, header);
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)header {
    if (value && [header caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) {
        value = OVSRewriteIfNeeded(value);
    }
    %orig(value, header);
}

- (void)setAllHTTPHeaderFields:(NSDictionary *)headerFields {
    %orig(OVSRewriteHeaderDictionary(headerFields));
}
%end

%hook NSURLRequest
- (NSString *)valueForHTTPHeaderField:(NSString *)header {
    NSString *value = %orig;
    if (value && [header caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) {
        return OVSRewriteIfNeeded(value);
    }
    return value;
}

- (NSDictionary *)allHTTPHeaderFields {
    NSDictionary *originalHeaders = %orig;
    return OVSRewriteHeaderDictionary(originalHeaders);
}
%end

%hook NSURLSessionConfiguration
- (NSDictionary *)HTTPAdditionalHeaders {
    NSDictionary *originalHeaders = %orig;
    return OVSRewriteHeaderDictionary(originalHeaders);
}

- (void)setHTTPAdditionalHeaders:(NSDictionary *)headers {
    %orig(OVSRewriteHeaderDictionary(headers));
}
%end

%group WebKitHooks
%hook WKWebView
- (NSString *)_userAgent {
    NSString *originalAgent = %orig;
    return OVSRewriteIfNeeded(originalAgent);
}

- (NSString *)customUserAgent {
    NSString *originalAgent = %orig;
    return OVSRewriteIfNeeded(originalAgent);
}

- (void)setCustomUserAgent:(NSString *)userAgent {
    %orig(OVSRewriteIfNeeded(userAgent));
}

- (NSString *)_applicationNameForUserAgent {
    NSString *originalAgent = %orig;
    return OVSRewriteIfNeeded(originalAgent);
}
%end

%hook WKWebViewConfiguration
- (NSString *)applicationNameForUserAgent {
    NSString *originalAgent = %orig;
    return OVSRewriteIfNeeded(originalAgent);
}

- (void)setApplicationNameForUserAgent:(NSString *)applicationName {
    %orig(OVSRewriteIfNeeded(applicationName));
}

- (NSString *)_applicationNameForDesktopUserAgent {
    NSString *originalAgent = %orig;
    return OVSRewriteIfNeeded(originalAgent);
}
%end

%hook WKBrowsingContextController
- (NSString *)applicationNameForUserAgent {
    NSString *originalAgent = %orig;
    return OVSRewriteIfNeeded(originalAgent);
}
%end
%end

%hookf(int, sysctlbyname, const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (!name || !OVSBeginLowLevelHook()) {
        return %orig(name, oldp, oldlenp, newp, newlen);
    }

    int result = -1;
    BOOL handled = NO;
    if (OVSSpoofingEnabled() && strcmp(name, "kern.osproductversion") == 0) {
        result = OVSSysctlCopyString(oldp, oldlenp, OVSSpoofedOSVersionString().UTF8String);
        handled = YES;
    } else if (OVSSpoofingEnabled() && strcmp(name, "kern.osversion") == 0) {
        result = OVSSysctlCopyString(oldp, oldlenp, OVSSpoofedBuildNumber().UTF8String);
        handled = YES;
    } else if (OVSShouldSpoofHostName() && strcmp(name, "kern.hostname") == 0) {
        result = OVSSysctlCopyString(oldp, oldlenp, OVSSpoofedHostName().UTF8String);
        handled = YES;
    } else if (OVSShouldSpoofModel() && (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.product") == 0)) {
        result = OVSSysctlCopyString(oldp, oldlenp, OVSSpoofedModel().UTF8String);
        handled = YES;
    } else if (OVSGestaltEnabled() && strcmp(name, "kern.ostype") == 0) {
        result = OVSSysctlCopyString(oldp, oldlenp, "Darwin");
        handled = YES;
    } else if (OVSGestaltEnabled() && strcmp(name, "kern.osrelease") == 0) {
        result = OVSSysctlCopyString(oldp, oldlenp, OVSDarwinRelease().UTF8String);
        handled = YES;
    } else if (OVSGestaltEnabled() && strcmp(name, "kern.version") == 0) {
        result = OVSSysctlCopyString(oldp, oldlenp, OVSDarwinVersionString().UTF8String);
        handled = YES;
    } else if (OVSGestaltEnabled() && strcmp(name, "hw.model") == 0) {
        NSString *hw = OVSSpoofedHwModel();
        if (hw.length > 0) {
            result = OVSSysctlCopyString(oldp, oldlenp, hw.UTF8String);
            handled = YES;
        }
    } else if (OVSGestaltEnabled() && (strcmp(name, "hw.ncpu") == 0 || strcmp(name, "hw.physicalcpu") == 0 || strcmp(name, "hw.logicalcpu") == 0)) {
        int ncpu = (int)OVSSpoofedNCPU();
        if (ncpu > 0) {
            result = OVSSysctlCopyBytes(oldp, oldlenp, &ncpu, sizeof(ncpu));
            handled = YES;
        }
    } else if (OVSGestaltEnabled() && strcmp(name, "hw.memsize") == 0) {
        uint64_t mem = (uint64_t)OVSSpoofedMemorySize();
        if (mem > 0) {
            result = OVSSysctlCopyBytes(oldp, oldlenp, &mem, sizeof(mem));
            handled = YES;
        }
    }

    if (!handled) {
        result = %orig(name, oldp, oldlenp, newp, newlen);
    }
    OVSEndLowLevelHook();
    return result;
}

%ctor {
    if (OVSIsProtectedProcess()) {
        return;
    }
    OVSRegisterPreferenceListener();
    %init;
    if (NSClassFromString(@"WKWebView")) {
        %init(WebKitHooks);
    }
}
