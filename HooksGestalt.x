#import "Prefs.h"

#import <CoreFoundation/CoreFoundation.h>

#import <dlfcn.h>
#import <stdio.h>
#import <substrate.h>

typedef CFTypeRef (*MGCopyAnswer_t)(CFStringRef);
static MGCopyAnswer_t orig_MGCopyAnswer;

static CFTypeRef OVSCopyGestaltCFAnswer(NSString *key) {
    id value = OVSGestaltObjectForKey(key);
    if (!value) {
        return NULL;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = (NSString *)value;
        if ([key caseInsensitiveCompare:@"UniqueDeviceIDData"] == NSOrderedSame) {
            NSMutableData *data = [NSMutableData data];
            NSString *hex = [[text lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@""];
            if (hex.length % 2 == 0 && hex.length > 0) {
                const char *cString = hex.UTF8String;
                for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
                    unsigned int byte = 0;
                    sscanf(cString + i, "%2x", &byte);
                    unsigned char b = (unsigned char)byte;
                    [data appendBytes:&b length:1];
                }
                return (CFTypeRef)CFBridgingRetain(data);
            }
        }
        return (CFTypeRef)CFBridgingRetain(text);
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return (CFTypeRef)CFBridgingRetain(value);
    }
    if ([value isKindOfClass:[NSData class]]) {
        return (CFTypeRef)CFBridgingRetain(value);
    }
    return NULL;
}

static CFTypeRef hooked_MGCopyAnswer(CFStringRef question) {
    if (!question || !OVSSpoofingEnabled()) {
        return orig_MGCopyAnswer ? orig_MGCopyAnswer(question) : NULL;
    }
    NSString *key = (__bridge NSString *)question;
    CFTypeRef spoofed = OVSCopyGestaltCFAnswer(key);
    if (spoofed) {
        return spoofed;
    }
    return orig_MGCopyAnswer ? orig_MGCopyAnswer(question) : NULL;
}

%ctor {
    if (OVSIsProtectedProcess()) {
        return;
    }
    void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (!handle) {
        handle = dlopen("/System/Library/PrivateFrameworks/MobileGestalt.framework/MobileGestalt", RTLD_LAZY);
    }
    if (!handle) {
        return;
    }
    void *symbol = dlsym(handle, "MGCopyAnswer");
    if (!symbol) {
        return;
    }
    MSHookFunction(symbol, (void *)hooked_MGCopyAnswer, (void **)&orig_MGCopyAnswer);
}
