#import "Prefs.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <errno.h>
#import <mach-o/dyld.h>
#import <stdlib.h>
#import <string.h>
#import <substrate.h>
#import <sys/stat.h>
#import <unistd.h>

static BOOL OVSCstrHas(const char *hay, const char *needle) {
    if (!hay || !needle || needle[0] == '\0') {
        return NO;
    }
    size_t n = strlen(needle);
    for (const char *p = hay; *p; p++) {
        if (strncasecmp(p, needle, n) == 0) {
            return YES;
        }
    }
    return NO;
}

static BOOL OVSPathLooksJailbreak(NSString *path) {
    if (path.length == 0) {
        return NO;
    }
    NSString *low = path.lowercaseString;
    if ([low containsString:@"/containers/data/"] ||
        [low containsString:@"/containers/bundle/"] ||
        [low containsString:@"/containers/shared/"] ||
        [low containsString:@"/var/mobile/library/caches/"] ||
        [low containsString:@"/var/mobile/media/"]) {
        return NO;
    }
    return [low containsString:@"/var/jb"] ||
           [low containsString:@"/private/var/jb"] ||
           [low containsString:@"mobilesubstrate"] ||
           [low containsString:@"tweakinject"] ||
           [low containsString:@"libsubstrate"] ||
           [low containsString:@"cydiasubstrate"] ||
           [low containsString:@"ellekit"] ||
           [low containsString:@"libhooker"] ||
           [low containsString:@"substitute"] ||
           [low containsString:@"cephei"] ||
           [low containsString:@"rocketbootstrap"] ||
           [low containsString:@"preferenceloader"] ||
           [low containsString:@"chengios"] ||
           [low containsString:@"/applications/cydia.app"] ||
           [low containsString:@"/applications/sileo.app"] ||
           [low containsString:@"/applications/zebra.app"] ||
           [low containsString:@"/applications/installer.app"] ||
           [low containsString:@"/applications/filza.app"] ||
           [low containsString:@"/library/dpkg"] ||
           [low containsString:@"/etc/apt"] ||
           [low containsString:@"/var/lib/apt"] ||
           [low containsString:@"/var/lib/cydia"] ||
           [low containsString:@"/var/cache/apt"] ||
           [low containsString:@"/usr/libexec/cydia"] ||
           [low containsString:@"/usr/bin/apt"] ||
           [low containsString:@"/usr/bin/dpkg"] ||
           [low containsString:@"/usr/sbin/sshd"] ||
           [low containsString:@"frida"] ||
           [low containsString:@"cycript"] ||
           [low containsString:@"checkra1n"] ||
           [low containsString:@"unc0ver"] ||
           [low containsString:@"palera1n"] ||
           [low containsString:@"dopamine"] ||
           [low containsString:@"procursus"] ||
           [low containsString:@"/electra"] ||
           [low containsString:@"/taurine"] ||
           [low containsString:@"/chimera"] ||
           [low containsString:@"cydia.plist"] ||
           [low containsString:@"sileo.plist"] ||
           [low containsString:@"/binpack"];
}

static BOOL OVSCPathLooksJailbreak(const char *path) {
    if (!path || path[0] == '\0') {
        return NO;
    }
    return OVSPathLooksJailbreak([NSString stringWithUTF8String:path]);
}

static BOOL OVSHiddenDylib(const char *name) {
    if (!name) {
        return NO;
    }
    return OVSCstrHas(name, "ChengIOS") ||
           OVSCstrHas(name, "MobileSubstrate") ||
           OVSCstrHas(name, "libsubstrate") ||
           OVSCstrHas(name, "SubstrateLoader") ||
           OVSCstrHas(name, "TweakInject") ||
           OVSCstrHas(name, "ellekit") ||
           OVSCstrHas(name, "libhooker") ||
           OVSCstrHas(name, "substitute") ||
           OVSCstrHas(name, "CydiaSubstrate") ||
           OVSCstrHas(name, "PreferenceLoader") ||
           OVSCstrHas(name, "Cephei") ||
           OVSCstrHas(name, "RocketBootstrap") ||
           OVSCstrHas(name, "AltList") ||
           OVSCstrHas(name, "ABypass") ||
           OVSCstrHas(name, "Shadow.dylib");
}

static BOOL OVSHideJailbreakDeep(void) {
    return OVSHideJailbreakEnabled() && !OVSIsFragileApp() && !OVSIsTikTokFamily();
}

static int (*CIOrigAccess)(const char *, int);
static int CIHookedAccess(const char *path, int mode) {
    if (OVSHideJailbreakEnabled() && OVSCPathLooksJailbreak(path)) {
        errno = ENOENT;
        return -1;
    }
    return CIOrigAccess ? CIOrigAccess(path, mode) : -1;
}

static int (*CIOrigLstat)(const char *, struct stat *);
static int CIHookedLstat(const char *path, struct stat *buf) {
    if (OVSHideJailbreakEnabled() && OVSCPathLooksJailbreak(path)) {
        errno = ENOENT;
        return -1;
    }
    return CIOrigLstat ? CIOrigLstat(path, buf) : -1;
}

static int (*CIOrigStat)(const char *, struct stat *);
static int CIHookedStat(const char *path, struct stat *buf) {
    if (OVSHideJailbreakEnabled() && OVSCPathLooksJailbreak(path)) {
        errno = ENOENT;
        return -1;
    }
    return CIOrigStat ? CIOrigStat(path, buf) : -1;
}

static char *(*CIOrigGetenv)(const char *);
static char *CIHookedGetenv(const char *name) {
    if (OVSHideJailbreakEnabled() && name && strcmp(name, "DYLD_INSERT_LIBRARIES") == 0) {
        return NULL;
    }
    return CIOrigGetenv ? CIOrigGetenv(name) : NULL;
}

static pid_t (*CIOrigFork)(void);
static pid_t CIHookedFork(void) {
    if (OVSHideJailbreakDeep()) {
        errno = EPERM;
        return -1;
    }
    return CIOrigFork ? CIOrigFork() : -1;
}

static uint32_t (*CIOrigDyldImageCount)(void);
static const char *(*CIOrigDyldGetImageName)(uint32_t);

static uint32_t CIHookedDyldImageCount(void) {
    uint32_t count = CIOrigDyldImageCount ? CIOrigDyldImageCount() : 0;
    if (!OVSHideJailbreakDeep()) {
        return count;
    }
    uint32_t visible = 0;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = CIOrigDyldGetImageName ? CIOrigDyldGetImageName(i) : NULL;
        if (!OVSHiddenDylib(name)) {
            visible += 1;
        }
    }
    return visible;
}

static const char *CIHookedDyldGetImageName(uint32_t image_index) {
    if (!OVSHideJailbreakDeep()) {
        return CIOrigDyldGetImageName ? CIOrigDyldGetImageName(image_index) : NULL;
    }
    uint32_t count = CIOrigDyldImageCount ? CIOrigDyldImageCount() : 0;
    uint32_t visible = 0;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = CIOrigDyldGetImageName ? CIOrigDyldGetImageName(i) : NULL;
        if (OVSHiddenDylib(name)) {
            continue;
        }
        if (visible == image_index) {
            return name;
        }
        visible += 1;
    }
    return NULL;
}

static void CIHookSym(const char *name, void *replacement, void **original) {
    if (!name || !replacement || !original) {
        return;
    }
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (!sym) {
        return;
    }
    MSHookFunction(sym, replacement, original);
}

%group HideJBHooks
%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)path {
    if (OVSHideJailbreakEnabled() && OVSPathLooksJailbreak(path)) {
        return NO;
    }
    return %orig;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    if (OVSHideJailbreakEnabled() && OVSPathLooksJailbreak(path)) {
        if (isDirectory) {
            *isDirectory = NO;
        }
        return NO;
    }
    return %orig;
}

- (NSDictionary *)attributesOfItemAtPath:(NSString *)path error:(NSError **)error {
    if (OVSHideJailbreakEnabled() && OVSPathLooksJailbreak(path)) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        }
        return nil;
    }
    return %orig;
}
%end

%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    if (OVSHideJailbreakEnabled() && url.scheme.length > 0) {
        NSString *scheme = url.scheme.lowercaseString;
        if ([scheme isEqualToString:@"cydia"] ||
            [scheme isEqualToString:@"sileo"] ||
            [scheme isEqualToString:@"zbra"] ||
            [scheme isEqualToString:@"zebra"] ||
            [scheme isEqualToString:@"filza"] ||
            [scheme isEqualToString:@"undecimus"] ||
            [scheme isEqualToString:@"activator"] ||
            [scheme isEqualToString:@"chengios"]) {
            return NO;
        }
    }
    return %orig;
}
%end
%end

%ctor {
    if (OVSIsProtectedProcess() || OVSIsWebKitHelperProcess() || OVSIsShopeeFamily()) {
        return;
    }
    OVSRegisterPreferenceListener();
    if (!OVSHideJailbreakEnabled()) {
        return;
    }
    %init(HideJBHooks);
    CIHookSym("access", (void *)CIHookedAccess, (void **)&CIOrigAccess);
    CIHookSym("lstat", (void *)CIHookedLstat, (void **)&CIOrigLstat);
    CIHookSym("stat", (void *)CIHookedStat, (void **)&CIOrigStat);
    CIHookSym("getenv", (void *)CIHookedGetenv, (void **)&CIOrigGetenv);
    if (OVSHideJailbreakDeep()) {
        CIHookSym("fork", (void *)CIHookedFork, (void **)&CIOrigFork);
        CIHookSym("_dyld_image_count", (void *)CIHookedDyldImageCount, (void **)&CIOrigDyldImageCount);
        CIHookSym("_dyld_get_image_name", (void *)CIHookedDyldGetImageName, (void **)&CIOrigDyldGetImageName);
    }
}