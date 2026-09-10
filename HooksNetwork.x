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
