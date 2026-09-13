#import "Prefs.h"

#import <stdio.h>

#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <netinet/in.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/types.h>

#import <SystemConfiguration/CaptiveNetwork.h>

@interface NEHotspotNetwork : NSObject
@property (nonatomic, readonly, strong) NSString *SSID;
@property (nonatomic, readonly, strong) NSString *BSSID;
@property (nonatomic, readonly) double signalStrength;
@end

static BOOL OVSShouldSpoofInterface(const char *name) {
    if (!name) {
        return NO;
    }
    if (strncmp(name, "lo", 2) == 0) {
        return NO;
    }
    NSString *wanted = OVSSpoofedInterfaceName();
    if ([wanted isEqualToString:@"*"]) {
        return YES;
    }
    return wanted.length > 0 && strcmp(name, wanted.UTF8String) == 0;
}

static BOOL OVSParseMACAddress(NSString *string, unsigned char outBytes[6]) {
    if (string.length == 0 || !outBytes) {
        return NO;
    }
    unsigned int bytes[6] = {0};
    NSString *normalized = [[string lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@":"];
    if (sscanf(normalized.UTF8String, "%x:%x:%x:%x:%x:%x",
               &bytes[0], &bytes[1], &bytes[2], &bytes[3], &bytes[4], &bytes[5]) != 6) {
        return NO;
    }
    for (int i = 0; i < 6; i++) {
        outBytes[i] = (unsigned char)bytes[i];
    }
    return YES;
}

%hookf(int, getifaddrs, struct ifaddrs **ifap) {
    int result = %orig(ifap);
    if (result != 0 || !ifap || !*ifap || !OVSNetworkEnabled()) {
        return result;
    }

    NSString *ipv4 = OVSSpoofedIPv4();
    NSString *ipv6 = OVSSpoofedIPv6();
    unsigned char mac[6];
    BOOL hasMAC = OVSParseMACAddress(OVSSpoofedMACAddress(), mac);

    for (struct ifaddrs *iface = *ifap; iface; iface = iface->ifa_next) {
        if (!OVSShouldSpoofInterface(iface->ifa_name) || !iface->ifa_addr) {
            continue;
        }
        if (iface->ifa_addr->sa_family == AF_INET && ipv4.length > 0) {
            struct sockaddr_in *address = (struct sockaddr_in *)iface->ifa_addr;
            inet_pton(AF_INET, ipv4.UTF8String, &address->sin_addr);
        } else if (iface->ifa_addr->sa_family == AF_INET6 && ipv6.length > 0) {
            struct sockaddr_in6 *address = (struct sockaddr_in6 *)iface->ifa_addr;
            inet_pton(AF_INET6, ipv6.UTF8String, &address->sin6_addr);
        } else if (iface->ifa_addr->sa_family == AF_LINK && hasMAC) {
            struct sockaddr_dl *link = (struct sockaddr_dl *)iface->ifa_addr;
            if (link->sdl_alen == 6) {
                unsigned char *data = (unsigned char *)LLADDR(link);
                memcpy(data, mac, 6);
            }
        }
    }
    return result;
}

%hookf(CFArrayRef, CNCopySupportedInterfaces) {
    if (!OVSNetworkEnabled() || (OVSSpoofedWifiSSID().length == 0 && OVSSpoofedWifiBSSID().length == 0)) {
        return %orig;
    }
    NSString *iface = OVSSpoofedInterfaceName();
    if ([iface isEqualToString:@"*"] || iface.length == 0) {
        iface = @"en0";
    }
    return (__bridge_retained CFArrayRef)@[iface];
}

%hookf(CFDictionaryRef, CNCopyCurrentNetworkInfo, CFStringRef interfaceName) {
    if (!OVSNetworkEnabled()) {
        return %orig;
    }
    if (interfaceName && !OVSShouldSpoofInterface([(__bridge NSString *)interfaceName UTF8String])) {
        return %orig;
    }
    NSDictionary *info = OVSSpoofedCaptiveNetworkInfo();
    if (info.count == 0) {
        return %orig;
    }
    return (__bridge_retained CFDictionaryRef)info;
}

%group HotspotHooks
%hook NEHotspotNetwork
- (NSString *)SSID {
    if (!OVSNetworkEnabled()) {
        return %orig;
    }
    NSString *ssid = OVSSpoofedWifiSSID();
    if (ssid.length > 0) {
        return ssid;
    }
    return %orig;
}

- (NSString *)BSSID {
    if (!OVSNetworkEnabled()) {
        return %orig;
    }
    NSString *bssid = OVSSpoofedWifiBSSID();
    if (bssid.length > 0) {
        return bssid;
    }
    return %orig;
}

- (double)signalStrength {
    if (!OVSNetworkEnabled() || OVSSpoofedWifiRSSI().length == 0) {
        return %orig;
    }
    return OVSSpoofedWifiSignalStrength();
}
%end
%end

%ctor {
    if (OVSIsProtectedProcess() || OVSIsWebKitHelperProcess() || OVSIsFragileApp()) {
        return;
    }
    %init;
    if (NSClassFromString(@"NEHotspotNetwork")) {
        %init(HotspotHooks);
    }
}
