#import "Prefs.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <substrate.h>

typedef CFTypeRef (*MGCopyAnswer_t)(CFStringRef question, uint32_t *typeCode);
static MGCopyAnswer_t orig_MGCopyAnswer;

static BOOL OVSGestaltQuestionIsPlainKey(CFStringRef question) {
    if (!question || CFGetTypeID(question) != CFStringGetTypeID()) {
        return NO;
    }
    CFIndex length = CFStringGetLength(question);
    if (length < 2 || length > 64) {
        return NO;
    }
    UniChar chars[65];
    CFStringGetCharacters(question, CFRangeMake(0, length), chars);
    for (CFIndex i = 0; i < length; i++) {
        UniChar c = chars[i];
        BOOL ok = (c >= 'A' && c <= 'Z') ||
                  (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') ||
                  c == '-' || c == '_';
        if (!ok) {
            return NO;
        }
    }
    return YES;
}

static CFTypeRef hooked_MGCopyAnswer(CFStringRef question, uint32_t *typeCode) {
    if (!orig_MGCopyAnswer) {
        return NULL;
    }
    if (!OVSBeginLowLevelHook()) {
        return orig_MGCopyAnswer(question, typeCode);
    }

    CFTypeRef result = NULL;
    if ((OVSGestaltEnabled() || OVSNarrowGestaltEnabled()) && OVSGestaltQuestionIsPlainKey(question)) {
        NSString *key = (__bridge NSString *)question;
        id value = OVSGestaltObjectForKey(key);
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            result = CFBridgingRetain(value);
        }
    }
    if (!result) {
        result = orig_MGCopyAnswer(question, typeCode);
    }
    OVSEndLowLevelHook();
    return result;
}

%ctor {
    if (OVSIsProtectedProcess() || OVSIsWebKitHelperProcess()) {
        return;
    }
    OVSRegisterPreferenceListener();
    if (!OVSGestaltEnabled() && !OVSNarrowGestaltEnabled()) {
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
