#import "Prefs.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <ctype.h>
#import <stdlib.h>
#import <substrate.h>

typedef CFTypeRef (*MGCopyAnswer_t)(CFStringRef question, uint32_t *typeCode);
static MGCopyAnswer_t orig_MGCopyAnswer;

static CFTypeRef gRealUDID;
static CFTypeRef gRealUDIDData;
static CFTypeRef gRealSerial;
static CFTypeRef gRealWifi;
static CFTypeRef gRealBT;
static CFTypeRef gRealProductType;
static CFTypeRef gRealHWModel;

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

static CFTypeRef CIRetainOrigAnswer(CFStringRef key) {
    if (!orig_MGCopyAnswer || !key) {
        return NULL;
    }
    uint32_t typeCode = 0;
    return orig_MGCopyAnswer(key, &typeCode);
}

static NSData *CIDataFromHex(NSString *hex) {
    if (hex.length < 2) {
        return nil;
    }
    NSUInteger max = hex.length / 2;
    NSMutableData *data = [NSMutableData dataWithLength:max];
    unsigned char *out = (unsigned char *)data.mutableBytes;
    NSUInteger used = 0;
    const char *raw = hex.UTF8String;
    if (!raw) {
        return nil;
    }
    for (NSUInteger i = 0; raw[i] && raw[i + 1] && used < max; i++) {
        char c1 = raw[i];
        char c2 = raw[i + 1];
        if (!isxdigit(c1) || !isxdigit(c2)) {
            continue;
        }
        char buf[3] = {c1, c2, 0};
        out[used++] = (unsigned char)strtoul(buf, NULL, 16);
        i++;
    }
    if (used == 0) {
        return nil;
    }
    data.length = used;
    return data;
}

static CFTypeRef CIMatchReplace(CFTypeRef result, CFTypeRef realValue, NSString *spoofed) {
    if (!result || !realValue || spoofed.length == 0) {
        return result;
    }
    if (!CFEqual(result, realValue)) {
        return result;
    }
    CFRelease(result);
    if (CFGetTypeID(realValue) == CFDataGetTypeID()) {
        NSData *data = CIDataFromHex(spoofed);
        if (data.length > 0) {
            return CFBridgingRetain(data);
        }
    }
    return CFBridgingRetain(spoofed);
}

static CFTypeRef CIReplaceIdentityResult(CFTypeRef result) {
    if (!result) {
        return result;
    }
    result = CIMatchReplace(result, gRealUDID, OVSSpoofedUniqueDeviceID());
    result = CIMatchReplace(result, gRealUDIDData, OVSSpoofedUniqueDeviceID());
    result = CIMatchReplace(result, gRealSerial, OVSSpoofedSerialNumber());
    result = CIMatchReplace(result, gRealWifi, OVSSpoofedWifiAddress());
    result = CIMatchReplace(result, gRealBT, OVSSpoofedBluetoothAddress());
    if (OVSShouldSpoofModel()) {
        result = CIMatchReplace(result, gRealProductType, OVSSpoofedModel());
        result = CIMatchReplace(result, gRealHWModel, OVSSpoofedHwModel());
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
    if (OVSGestaltEnabled() && OVSGestaltQuestionIsPlainKey(question)) {
        NSString *key = (__bridge NSString *)question;
        id value = OVSGestaltObjectForKey(key);
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            if (result) {
                CFRelease(result);
            }
            result = CFBridgingRetain(value);
        }
    } else if (OVSShopeeIdentityHooksEnabled() && OVSGestaltQuestionIsPlainKey(question)) {
        NSString *key = (__bridge NSString *)question;
        id value = nil;
        if ([key caseInsensitiveCompare:@"UniqueDeviceID"] == NSOrderedSame ||
            [key caseInsensitiveCompare:@"UniqueDeviceIDData"] == NSOrderedSame) {
            value = OVSSpoofedUniqueDeviceID();
        } else if ([key caseInsensitiveCompare:@"SerialNumber"] == NSOrderedSame) {
            value = OVSSpoofedSerialNumber();
        } else if ([key caseInsensitiveCompare:@"WifiAddress"] == NSOrderedSame) {
            value = OVSSpoofedWifiAddress();
        } else if ([key caseInsensitiveCompare:@"BluetoothAddress"] == NSOrderedSame) {
            value = OVSSpoofedBluetoothAddress();
        } else if (OVSShouldSpoofModel() &&
                   ([key caseInsensitiveCompare:@"ProductType"] == NSOrderedSame ||
                    [key caseInsensitiveCompare:@"product-type"] == NSOrderedSame)) {
            value = OVSSpoofedModel();
        } else if (OVSShouldSpoofModel() &&
                   ([key caseInsensitiveCompare:@"HWModelStr"] == NSOrderedSame ||
                    [key caseInsensitiveCompare:@"HardwareModel"] == NSOrderedSame)) {
            value = OVSSpoofedHwModel();
        }
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            if (result) {
                CFRelease(result);
            }
            result = CFBridgingRetain(value);
        }
    }
    if (OVSShopeeIdentityHooksEnabled() || (OVSGestaltEnabled() && OVSDeviceIdentityEnabled())) {
        result = CIReplaceIdentityResult(result);
    }
    OVSEndLowLevelHook();
    return result;
}

%ctor {
    if (OVSIsProtectedProcess() || OVSIsWebKitHelperProcess()) {
        return;
    }
    BOOL shopeeId = OVSShopeeIdentityHooksEnabled();
    if (OVSIsFragileApp() && !shopeeId) {
        return;
    }
    OVSRegisterPreferenceListener();
    shopeeId = OVSShopeeIdentityHooksEnabled();
    BOOL full = OVSGestaltEnabled();
    if (!full && !shopeeId) {
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
    if (orig_MGCopyAnswer && (shopeeId || (full && OVSDeviceIdentityEnabled()))) {
        gRealUDID = CIRetainOrigAnswer(CFSTR("UniqueDeviceID"));
        gRealUDIDData = CIRetainOrigAnswer(CFSTR("UniqueDeviceIDData"));
        gRealSerial = CIRetainOrigAnswer(CFSTR("SerialNumber"));
        gRealWifi = CIRetainOrigAnswer(CFSTR("WifiAddress"));
        gRealBT = CIRetainOrigAnswer(CFSTR("BluetoothAddress"));
        gRealProductType = CIRetainOrigAnswer(CFSTR("ProductType"));
        gRealHWModel = CIRetainOrigAnswer(CFSTR("HWModelStr"));
    }
}