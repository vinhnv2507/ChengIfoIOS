#import <Foundation/Foundation.h>
#import <Security/Security.h>

// Shared by the app, preferences and privileged keychain helper. Never infer
// ownership of system credentials from an SSID/account containing an app name.
static inline NSString *CIKeychainPolicyText(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSData class]]) {
        return [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding] ?: @"";
    }
    return @"";
}

static inline BOOL CIKeychainProtectedAccessGroup(id value) {
    NSString *low = CIKeychainPolicyText(value).lowercaseString;
    if (low.length == 0 || [low containsString:@"*"]) return YES;
    if ([@[@"apple", @"lockdown-identities", @"protectedcloudstorage",
           @"43aqtk3442"] containsObject:low]) return YES;
    if ([low hasPrefix:@"com.apple."] || [low hasPrefix:@"group.com.apple."]) {
        // Keep the existing Safari/WebKit app cleanup available.
        return !([low containsString:@"safari"] || [low containsString:@"webkit"]);
    }
    return NO;
}

static inline BOOL CIKeychainProtectedItem(NSDictionary *item) {
    if (![item isKindOfClass:[NSDictionary class]]) return YES;
    id group = item[(__bridge id)kSecAttrAccessGroup] ?: item[@"accessGroup"] ?: item[@"agrp"];
    if (CIKeychainProtectedAccessGroup(group)) return YES;
    NSString *service = CIKeychainPolicyText(item[(__bridge id)kSecAttrService] ?: item[@"service"] ?: item[@"svce"]).lowercaseString;
    if ([service isEqualToString:@"airport"] || [service hasPrefix:@"airport network"] ||
        [service hasPrefix:@"com.apple.wifi"] || [service hasPrefix:@"com.apple.airport"] ||
        [service hasPrefix:@"com.apple.network"] || [service hasPrefix:@"com.apple.eap"] ||
        [service hasPrefix:@"com.apple.internetsharing"]) return YES;
    NSString *description = CIKeychainPolicyText(item[(__bridge id)kSecAttrDescription] ?: item[@"desc"]).lowercaseString;
    return [description isEqualToString:@"airport network password"];
}

// Resolve a broad query to individual records and delete only by persistent
// reference. A missing reference or unknown access group fails closed.
static inline NSUInteger CIKeychainDeleteUnprotectedItems(NSDictionary *query) {
    if (CIKeychainProtectedAccessGroup(query[(__bridge id)kSecAttrAccessGroup]) &&
        query[(__bridge id)kSecAttrAccessGroup]) return 0;
    NSMutableDictionary *lookup = [query mutableCopy];
    lookup[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
    lookup[(__bridge id)kSecReturnAttributes] = @YES;
    lookup[(__bridge id)kSecReturnPersistentRef] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)lookup, &result);
    if (status != errSecSuccess || !result) {
        if (result) CFRelease(result);
        return 0;
    }
    id raw = CFBridgingRelease(result);
    NSArray *items = [raw isKindOfClass:[NSArray class]] ? raw : @[raw];
    NSUInteger deleted = 0;
    for (id item in items) {
        if (![item isKindOfClass:[NSDictionary class]] || CIKeychainProtectedItem(item)) continue;
        NSData *reference = item[(__bridge id)kSecValuePersistentRef];
        if (![reference isKindOfClass:[NSData class]] || reference.length == 0) continue;
        NSDictionary *exact = @{(__bridge id)kSecValuePersistentRef: reference};
        if (SecItemDelete((__bridge CFDictionaryRef)exact) == errSecSuccess) deleted++;
    }
    return deleted;
}
