#import "Prefs.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <substrate.h>

typedef CFTypeRef (*MGCopyAnswer_t)(CFStringRef question, uint32_t *typeCode);
static MGCopyAnswer_t orig_MGCopyAnswer;

static BOOL OVSGestaltQuestionUsable(CFStringRef question) {
    if (!question || CFGetTypeID(question) != CFStringGetTypeID()) {
        return NO;
    }
    CFIndex length = CFStringGetLength(question);
    if (length < 2 || length > 80) {
        return NO;
    }
    return YES;
}

static CFTypeRef OVSApplyGestaltSpoof(CFStringRef question, CFTypeRef result) {
    if (!OVSGestaltQuestionUsable(question)) {
        return result;
    }
    NSString *key = (__bridge NSString *)question;
    id original = nil;
    if (result && CFGetTypeID(result) == CFStringGetTypeID()) {
        original = (__bridge NSString *)result;
    }
    id value = OVSGestaltReplacementForQuestion(key, original);
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        if (result) {
            CFRelease(result);
        }
        return CFBridgingRetain(value);
    }
    return result;
}

static CFTypeRef hooked_MGCopyAnswer(CFStringRef question, uint32_t *typeCode) {
    if (!orig_MGCopyAnswer) {
        return NULL;
    }
    if (!OVSBeginLowLevelHook()) {
        return orig_MGCopyAnswer(question, typeCode);
    }
    CFTypeRef result = orig_MGCopyAnswer(question, typeCode);
    result = OVSApplyGestaltSpoof(question, result);
    OVSEndLowLevelHook();
    return result;
}

%ctor {
    if (OVSIsProtectedProcess() || OVSIsWebKitHelperProcess()) {
        return;
    }
    OVSRegisterPreferenceListener();
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
