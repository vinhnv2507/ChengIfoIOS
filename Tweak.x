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
    if (!OVSSpoofingEnabled()) {
        return userAgent;
    }
    if (userAgent.length == 0 || OVSIsWebKitHelperProcess()) {
        return OVSSpoofedSafariUserAgent();
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
    if (!OVSSpoofingEnabled() || OVSIsFragileApp()) {
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
    if (!OVSSpoofingEnabled() || OVSIsFragileApp()) {
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
    if (!OVSLowLevelHooksEnabled() || !OVSDeviceIdentityEnabled()) {
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
    if (!OVSLowLevelHooksEnabled() || !OVSDeviceIdentityEnabled()) {
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
    if (!OVSLowLevelHooksEnabled() || !OVSDeviceIdentityEnabled()) {
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
    if (!OVSDeviceIdentityEnabled() || OVSIsFragileApp()) {
        return %orig;
    }
    return OVSSpoofedVendorUUID();
}
%end

%group BundleHooks
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

@interface WKUserScript : NSObject
- (instancetype)initWithSource:(NSString *)source injectionTime:(NSInteger)injectionTime forMainFrameOnly:(BOOL)forMainFrameOnly;
- (NSString *)source;
@end

@interface WKUserContentController : NSObject
- (void)addUserScript:(WKUserScript *)userScript;
- (NSArray *)userScripts;
@end

@interface WKWebViewConfiguration (ChengIOS)
@property (nonatomic, strong) WKUserContentController *userContentController;
@end

static NSString *OVSNavigatorSpoofJavaScript(void) {
    NSString *ua = OVSSpoofedSafariUserAgent();
    ua = [[ua stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    NSString *model = OVSSpoofedModel() ?: @"";
    NSString *platform = [model.lowercaseString hasPrefix:@"ipad"] ? @"iPad" : @"iPhone";
    return [NSString stringWithFormat:@"(function(){if(window.__chengios_ua)return;window.__chengios_ua=1;var u='%@';var p='%@';try{var n=Navigator.prototype;Object.defineProperty(n,'userAgent',{configurable:true,get:function(){return u}});Object.defineProperty(n,'appVersion',{configurable:true,get:function(){return u}});Object.defineProperty(n,'platform',{configurable:true,get:function(){return p}});}catch(e){}})();", ua, platform];
}

static void OVSAttachWebKitSpoof(id configuration) {
    if (!OVSSpoofingEnabled() || !configuration) {
        return;
    }
    WKUserContentController *controller = nil;
    if ([configuration respondsToSelector:@selector(userContentController)]) {
        controller = [configuration userContentController];
    }
    if (!controller) {
        return;
    }
    for (id script in controller.userScripts) {
        if ([script respondsToSelector:@selector(source)] && [[script source] containsString:@"__chengios_ua"]) {
            return;
        }
    }
    WKUserScript *userScript = [[WKUserScript alloc] initWithSource:OVSNavigatorSpoofJavaScript() injectionTime:0 forMainFrameOnly:NO];
    [controller addUserScript:userScript];
}

%group WebKitHooks
%hook WKWebView
- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    OVSAttachWebKitSpoof(configuration);
    WKWebView *webView = %orig;
    if (OVSSpoofingEnabled()) {
        [webView setCustomUserAgent:OVSSpoofedSafariUserAgent()];
    }
    return webView;
}

- (void)layoutSubviews {
    %orig;
    if (OVSSpoofingEnabled()) {
        NSString *ua = OVSSpoofedSafariUserAgent();
        if (![self.customUserAgent isEqualToString:ua]) {
            [self setCustomUserAgent:ua];
        }
    }
}

- (NSString *)_userAgent {
    if (OVSSpoofingEnabled()) {
        return OVSSpoofedSafariUserAgent();
    }
    NSString *originalAgent = %orig;
    return originalAgent;
}

- (NSString *)customUserAgent {
    if (OVSSpoofingEnabled()) {
        return OVSSpoofedSafariUserAgent();
    }
    NSString *originalAgent = %orig;
    return originalAgent;
}

- (void)setCustomUserAgent:(NSString *)userAgent {
    %orig(OVSRewriteIfNeeded(userAgent));
}

- (NSString *)_applicationNameForUserAgent {
    NSString *originalAgent = %orig;
    return OVSRewriteIfNeeded(originalAgent);
}

- (NSString *)_standardUserAgentWithApplicationName:(NSString *)name {
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

%group LowLevelSysctl
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
%end

%group SafariTabHooks
%hook TabDocument
- (NSString *)userAgent {
    if (OVSSpoofingEnabled()) {
        return OVSSpoofedSafariUserAgent();
    }
    return %orig;
}

- (NSString *)customUserAgent {
    if (OVSSpoofingEnabled()) {
        return OVSSpoofedSafariUserAgent();
    }
    return %orig;
}

- (void)setCustomUserAgent:(NSString *)userAgent {
    %orig(OVSRewriteIfNeeded(userAgent));
}
%end
%end

%ctor {
    if (OVSIsProtectedProcess()) {
        return;
    }
    OVSRegisterPreferenceListener();
    if (OVSIsWebKitHelperProcess()) {
        if (!OVSSpoofingEnabled() || OVSIsFragileApp()) {
            return;
        }
        %init;
        if (NSClassFromString(@"WKWebView")) {
            %init(WebKitHooks);
        }
        return;
    }
    %init;
    if (OVSAppVersionEnabled()) {
        %init(BundleHooks);
    }
    if (!OVSIsFragileApp() && NSClassFromString(@"WKWebView")) {
        %init(WebKitHooks);
    }
    if (!OVSIsFragileApp() && NSClassFromString(@"TabDocument")) {
        %init(SafariTabHooks);
    }
    if (OVSLowLevelHooksEnabled()) {
        %init(LowLevelSysctl);
    }
}
