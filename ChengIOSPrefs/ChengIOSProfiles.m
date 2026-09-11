#import "ChengIOSProfiles.h"

#import <CoreFoundation/CoreFoundation.h>
#import <stdint.h>
#import <notify.h>


static NSArray<NSString *> *CIPrefsPaths(void) {
    return @[
        @"/var/jb/var/mobile/Library/Preferences/com.vinhnv2507.chengiosprefs.plist",
        @"/var/mobile/Library/Preferences/com.vinhnv2507.chengiosprefs.plist",
        @"/private/var/mobile/Library/Preferences/com.vinhnv2507.chengiosprefs.plist"
    ];
}

static BOOL CIIsPlistValue(id value) {
    return [value isKindOfClass:[NSString class]] ||
           [value isKindOfClass:[NSNumber class]] ||
           [value isKindOfClass:[NSArray class]] ||
           [value isKindOfClass:[NSDictionary class]] ||
           [value isKindOfClass:[NSData class]] ||
           [value isKindOfClass:[NSDate class]];
}

static NSMutableDictionary *CILoadRawPrefs(void) {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
    for (NSString *path in CIPrefsPaths()) {
        NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:path];
        if (file.count > 0) {
            [prefs addEntriesFromDictionary:file];
            break;
        }
    }
    CFStringRef appID = CFSTR("com.vinhnv2507.chengiosprefs");
    CFArrayRef keys = CFPreferencesCopyKeyList(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        CFDictionaryRef dict = CFPreferencesCopyMultiple(keys, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (dict) {
            [prefs addEntriesFromDictionary:(__bridge NSDictionary *)dict];
            CFRelease(dict);
        }
        CFRelease(keys);
    }
    return prefs;
}

static id CIPick(NSArray *items) {
    if (items.count == 0) {
        return nil;
    }
    return items[arc4random_uniform((uint32_t)items.count)];
}

static id CIPickWeighted(NSArray<NSDictionary *> *items, NSString *weightKey) {
    if (items.count == 0) {
        return nil;
    }
    NSUInteger total = 0;
    for (NSDictionary *item in items) {
        NSUInteger weight = [item[weightKey] unsignedIntegerValue];
        total += weight > 0 ? weight : 1;
    }
    NSUInteger pick = arc4random_uniform((uint32_t)MAX(total, 1));
    NSUInteger acc = 0;
    for (NSDictionary *item in items) {
        NSUInteger weight = [item[weightKey] unsignedIntegerValue];
        acc += weight > 0 ? weight : 1;
        if (pick < acc) {
            return item;
        }
    }
    return items.lastObject;
}

static NSArray *CIBiasRecent(NSArray *items) {
    if (items.count <= 2) {
        return items;
    }
    if (arc4random_uniform(10) < 7) {
        return [items subarrayWithRange:NSMakeRange(items.count - 2, 2)];
    }
    if (items.count >= 3 && arc4random_uniform(2) == 0) {
        return [items subarrayWithRange:NSMakeRange(items.count - 3, 3)];
    }
    return items;
}

static NSString *CILatin(NSString *input) {
    if (input.length == 0) {
        return @"";
    }
    NSMutableString *text = [input mutableCopy];
    CFStringTransform((__bridge CFMutableStringRef)text, NULL, kCFStringTransformToLatin, false);
    CFStringTransform((__bridge CFMutableStringRef)text, NULL, kCFStringTransformStripCombiningMarks, false);
    return text;
}

static NSString *CIHostnameFromName(NSString *name) {
    NSString *latin = CILatin(name);
    if (latin.length == 0) {
        return @"iPhone.local";
    }
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < latin.length; i++) {
        unichar c = [latin characterAtIndex:i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
            [out appendFormat:@"%C", c];
        } else if (c == 0x27 || c == 0x2019) {
            continue;
        } else if ((c == ' ' || c == '-' || c == '_' || c == '.') && out.length > 0 && ![out hasSuffix:@"-"]) {
            [out appendString:@"-"];
        }
    }
    while (out.length > 0 && [out hasSuffix:@"-"]) {
        [out deleteCharactersInRange:NSMakeRange(out.length - 1, 1)];
    }
    if (out.length == 0) {
        return @"iPhone.local";
    }
    if (out.length > 32) {
        NSString *trimmed = [[out substringToIndex:32] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-"]];
        return [trimmed stringByAppendingString:@".local"];
    }
    return [out stringByAppendingString:@".local"];
}

static NSString *CIRandomMAC(void) {
    unsigned int first = (arc4random_uniform(64) * 4u) | 0x02u;
    return [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x",
            first & 0xFF,
            arc4random_uniform(256),
            arc4random_uniform(256),
            arc4random_uniform(256),
            arc4random_uniform(256),
            arc4random_uniform(256)];
}

static NSString *CIRandomIPv4(void) {
    uint32_t roll = arc4random_uniform(100);
    NSUInteger host = 20 + arc4random_uniform(180);
    if (roll < 5) {
        return [NSString stringWithFormat:@"172.20.10.%lu", (unsigned long)(2 + arc4random_uniform(12))];
    }
    if (roll < 18) {
        return [NSString stringWithFormat:@"10.0.0.%lu", (unsigned long)host];
    }
    NSArray<NSNumber *> *nets = @[@0, @1, @1, @1, @2, @10, @31, @50, @100, @101];
    return [NSString stringWithFormat:@"192.168.%@.%lu", CIPick(nets), (unsigned long)host];
}

static NSString *CIRandomIPv6(NSArray<NSString *> *prefixes) {
    if (arc4random_uniform(10) < 3 || prefixes.count == 0) {
        return [NSString stringWithFormat:@"fd%02x:%x:%x:%x::%x",
                arc4random_uniform(256),
                arc4random_uniform(0xFFFF),
                arc4random_uniform(0xFFFF),
                1 + arc4random_uniform(16),
                2 + arc4random_uniform(4000)];
    }
    NSString *prefix = CIPick(prefixes);
    return [NSString stringWithFormat:@"%@:%x:%x:%x:%x:%x:%x",
            prefix,
            1 + arc4random_uniform(0xFF),
            arc4random_uniform(0xFFFF),
            arc4random_uniform(0xFFFF),
            arc4random_uniform(0xFFFF),
            arc4random_uniform(0xFFFF),
            1 + arc4random_uniform(0xFFFE)];
}

static NSString *CIRandomAppVersion(void) {
    uint32_t roll = arc4random_uniform(100);
    if (roll < 12) {
        return [NSString stringWithFormat:@"%u.%u", 1 + arc4random_uniform(15), arc4random_uniform(20)];
    }
    if (roll < 28) {
        return [NSString stringWithFormat:@"%u.%u.%u", 24 + arc4random_uniform(3), 1 + arc4random_uniform(12), arc4random_uniform(20)];
    }
    NSUInteger major = 1 + arc4random_uniform(18);
    NSUInteger minor = arc4random_uniform(16);
    NSUInteger patch = arc4random_uniform(12);
    return [NSString stringWithFormat:@"%lu.%lu.%lu", (unsigned long)major, (unsigned long)minor, (unsigned long)patch];
}

static NSString *CICoord(double value) {
    return [NSString stringWithFormat:@"%.6f", value];
}

static double CIJitter(double span) {
    return ((int)arc4random_uniform(2001) - 1000) * span;
}

static NSArray<NSDictionary *> *CIOS18(void) {
    return @[
        @{@"version": @"18.5", @"build": @"22F76"},
        @{@"version": @"18.6", @"build": @"22G86"},
        @{@"version": @"18.6.1", @"build": @"22G90"},
        @{@"version": @"18.6.2", @"build": @"22G100"},
        @{@"version": @"18.7", @"build": @"22H20"}
    ];
}

static NSArray<NSDictionary *> *CIOS18From183(void) {
    NSArray *early = @[
        @{@"version": @"18.3.2", @"build": @"22D82"},
        @{@"version": @"18.4.1", @"build": @"22E252"}
    ];
    return [early arrayByAddingObjectsFromArray:CIOS18()];
}

static NSArray<NSDictionary *> *CIOS26(void) {
    return @[
        @{@"version": @"26.0", @"build": @"23A341"},
        @{@"version": @"26.0.1", @"build": @"23A355"},
        @{@"version": @"26.1", @"build": @"23B85"},
        @{@"version": @"26.2", @"build": @"23C55"},
        @{@"version": @"26.3", @"build": @"23D60"},
        @{@"version": @"26.4", @"build": @"23E240"},
        @{@"version": @"26.5", @"build": @"23F76"},
        @{@"version": @"26.6", @"build": @"23G82"}
    ];
}

static NSArray<NSDictionary *> *CIJoin(NSArray *left, NSArray *right) {
    return [left arrayByAddingObjectsFromArray:right];
}


static NSArray<NSDictionary *> *CIDevices(void) {
    NSArray *ios18 = CIOS18();
    NSArray *ios183 = CIOS18From183();
    NSArray *ios26 = CIOS26();
    NSArray *iosBoth = CIJoin(ios18, ios26);
    NSArray *ios16e = CIJoin(ios183, ios26);
    return @[
        @{@"model": @"iPhone12,1", @"product": @"iPhone 11", @"os": ios18, @"weight": @2},
        @{@"model": @"iPhone12,3", @"product": @"iPhone 11 Pro", @"os": ios18, @"weight": @2},
        @{@"model": @"iPhone12,5", @"product": @"iPhone 11 Pro Max", @"os": ios18, @"weight": @3},
        @{@"model": @"iPhone12,8", @"product": @"iPhone SE", @"os": ios18, @"weight": @1},
        @{@"model": @"iPhone13,1", @"product": @"iPhone 12 mini", @"os": iosBoth, @"weight": @2},
        @{@"model": @"iPhone13,2", @"product": @"iPhone 12", @"os": iosBoth, @"weight": @3},
        @{@"model": @"iPhone13,3", @"product": @"iPhone 12 Pro", @"os": iosBoth, @"weight": @3},
        @{@"model": @"iPhone13,4", @"product": @"iPhone 12 Pro Max", @"os": iosBoth, @"weight": @4},
        @{@"model": @"iPhone14,4", @"product": @"iPhone 13 mini", @"os": iosBoth, @"weight": @2},
        @{@"model": @"iPhone14,5", @"product": @"iPhone 13", @"os": iosBoth, @"weight": @5},
        @{@"model": @"iPhone14,2", @"product": @"iPhone 13 Pro", @"os": iosBoth, @"weight": @5},
        @{@"model": @"iPhone14,3", @"product": @"iPhone 13 Pro Max", @"os": iosBoth, @"weight": @6},
        @{@"model": @"iPhone14,6", @"product": @"iPhone SE", @"os": iosBoth, @"weight": @2},
        @{@"model": @"iPhone14,7", @"product": @"iPhone 14", @"os": iosBoth, @"weight": @6},
        @{@"model": @"iPhone14,8", @"product": @"iPhone 14 Plus", @"os": iosBoth, @"weight": @3},
        @{@"model": @"iPhone15,2", @"product": @"iPhone 14 Pro", @"os": iosBoth, @"weight": @7},
        @{@"model": @"iPhone15,3", @"product": @"iPhone 14 Pro Max", @"os": iosBoth, @"weight": @8},
        @{@"model": @"iPhone15,4", @"product": @"iPhone 15", @"os": iosBoth, @"weight": @8},
        @{@"model": @"iPhone15,5", @"product": @"iPhone 15 Plus", @"os": iosBoth, @"weight": @4},
        @{@"model": @"iPhone16,1", @"product": @"iPhone 15 Pro", @"os": iosBoth, @"weight": @10},
        @{@"model": @"iPhone16,2", @"product": @"iPhone 15 Pro Max", @"os": iosBoth, @"weight": @12},
        @{@"model": @"iPhone17,3", @"product": @"iPhone 16", @"os": iosBoth, @"weight": @10},
        @{@"model": @"iPhone17,4", @"product": @"iPhone 16 Plus", @"os": iosBoth, @"weight": @5},
        @{@"model": @"iPhone17,1", @"product": @"iPhone 16 Pro", @"os": iosBoth, @"weight": @12},
        @{@"model": @"iPhone17,2", @"product": @"iPhone 16 Pro Max", @"os": iosBoth, @"weight": @14},
        @{@"model": @"iPhone17,5", @"product": @"iPhone 16e", @"os": ios16e, @"weight": @4},
        @{@"model": @"iPhone18,3", @"product": @"iPhone 17", @"os": ios26, @"weight": @10},
        @{@"model": @"iPhone18,4", @"product": @"iPhone 17 Air", @"os": ios26, @"weight": @6},
        @{@"model": @"iPhone18,1", @"product": @"iPhone 17 Pro", @"os": ios26, @"weight": @12},
        @{@"model": @"iPhone18,2", @"product": @"iPhone 17 Pro Max", @"os": ios26, @"weight": @14}
    ];
}


static NSArray<NSDictionary *> *CIRegions(void) {
    return @[
        @{
            @"locale": @"vi_VN",
            @"timeZone": @"Asia/Ho_Chi_Minh",
            @"iso": @"vn",
            @"weight": @45,
            @"ipv6": @[@"2402:800", @"2001:ee0", @"2405:4802"],
            @"carriers": @[
                @{@"name": @"Viettel", @"mcc": @"452", @"mnc": @"04"},
                @{@"name": @"Vinaphone", @"mcc": @"452", @"mnc": @"01"},
                @{@"name": @"Mobifone", @"mcc": @"452", @"mnc": @"02"},
                @{@"name": @"Vietnamobile", @"mcc": @"452", @"mnc": @"05"}
            ],
            @"cities": @[
                @{@"name": @"Ho Chi Minh", @"lat": @10.7769, @"lon": @106.7009, @"alt": @10.0, @"tz": @"Asia/Ho_Chi_Minh"},
                @{@"name": @"Hà Nội", @"lat": @21.0278, @"lon": @105.8342, @"alt": @16.0, @"tz": @"Asia/Ho_Chi_Minh"},
                @{@"name": @"Đà Nẵng", @"lat": @16.0544, @"lon": @108.2022, @"alt": @6.0, @"tz": @"Asia/Ho_Chi_Minh"},
                @{@"name": @"Hải Phòng", @"lat": @20.8449, @"lon": @106.6881, @"alt": @8.0, @"tz": @"Asia/Ho_Chi_Minh"},
                @{@"name": @"Cần Thơ", @"lat": @10.0452, @"lon": @105.7469, @"alt": @4.0, @"tz": @"Asia/Ho_Chi_Minh"},
                @{@"name": @"Nha Trang", @"lat": @12.2388, @"lon": @109.1967, @"alt": @5.0, @"tz": @"Asia/Ho_Chi_Minh"},
                @{@"name": @"Huế", @"lat": @16.4637, @"lon": @107.5909, @"alt": @9.0, @"tz": @"Asia/Ho_Chi_Minh"}
            ],
            @"names": @[@"iPhone", @"iPhone của An", @"iPhone của Minh", @"iPhone của Linh", @"iPhone của Huy", @"iPhone của Trang", @"iPhone của Nam", @"iPhone của Hà"]
        },
        @{
            @"locale": @"en_US",
            @"iso": @"us",
            @"weight": @12,
            @"ipv6": @[@"2601:647", @"2607:fb90", @"2600:1010"],
            @"carriers": @[
                @{@"name": @"T-Mobile", @"mcc": @"310", @"mnc": @"260"},
                @{@"name": @"Verizon", @"mcc": @"311", @"mnc": @"480"},
                @{@"name": @"AT&T", @"mcc": @"310", @"mnc": @"410"}
            ],
            @"cities": @[
                @{@"name": @"San Francisco", @"lat": @37.7749, @"lon": @-122.4194, @"alt": @16.0, @"tz": @"America/Los_Angeles"},
                @{@"name": @"Los Angeles", @"lat": @34.0522, @"lon": @-118.2437, @"alt": @87.0, @"tz": @"America/Los_Angeles"},
                @{@"name": @"New York", @"lat": @40.7128, @"lon": @-74.0060, @"alt": @10.0, @"tz": @"America/New_York"},
                @{@"name": @"Chicago", @"lat": @41.8781, @"lon": @-87.6298, @"alt": @182.0, @"tz": @"America/Chicago"},
                @{@"name": @"Houston", @"lat": @29.7604, @"lon": @-95.3698, @"alt": @13.0, @"tz": @"America/Chicago"},
                @{@"name": @"Seattle", @"lat": @47.6062, @"lon": @-122.3321, @"alt": @56.0, @"tz": @"America/Los_Angeles"}
            ],
            @"names": @[@"iPhone", @"Alex's iPhone", @"Jamie's iPhone", @"Chris's iPhone", @"Taylor's iPhone"]
        },
        @{
            @"locale": @"ja_JP",
            @"iso": @"jp",
            @"weight": @8,
            @"ipv6": @[@"2400:4050", @"240b:10"],
            @"carriers": @[
                @{@"name": @"NTT DOCOMO", @"mcc": @"440", @"mnc": @"10"},
                @{@"name": @"au", @"mcc": @"440", @"mnc": @"50"},
                @{@"name": @"SoftBank", @"mcc": @"440", @"mnc": @"20"},
                @{@"name": @"Rakuten", @"mcc": @"440", @"mnc": @"11"}
            ],
            @"cities": @[
                @{@"name": @"Tokyo", @"lat": @35.6762, @"lon": @139.6503, @"alt": @40.0, @"tz": @"Asia/Tokyo"},
                @{@"name": @"Osaka", @"lat": @34.6937, @"lon": @135.5023, @"alt": @5.0, @"tz": @"Asia/Tokyo"},
                @{@"name": @"Nagoya", @"lat": @35.1815, @"lon": @136.9066, @"alt": @15.0, @"tz": @"Asia/Tokyo"}
            ],
            @"names": @[@"iPhone", @"Yui's iPhone", @"Haruto's iPhone"]
        },
        @{
            @"locale": @"ko_KR",
            @"iso": @"kr",
            @"weight": @6,
            @"ipv6": @[@"2001:2d8", @"2406:5900"],
            @"carriers": @[
                @{@"name": @"SKTelecom", @"mcc": @"450", @"mnc": @"05"},
                @{@"name": @"KT", @"mcc": @"450", @"mnc": @"08"},
                @{@"name": @"LG U+", @"mcc": @"450", @"mnc": @"06"}
            ],
            @"cities": @[
                @{@"name": @"Seoul", @"lat": @37.5665, @"lon": @126.9780, @"alt": @38.0, @"tz": @"Asia/Seoul"},
                @{@"name": @"Busan", @"lat": @35.1796, @"lon": @129.0756, @"alt": @14.0, @"tz": @"Asia/Seoul"}
            ],
            @"names": @[@"iPhone", @"Minjun's iPhone", @"Seojean's iPhone"]
        },
        @{
            @"locale": @"en_GB",
            @"iso": @"gb",
            @"weight": @6,
            @"ipv6": @[@"2a00:23c0", @"2a00:1a00"],
            @"carriers": @[
                @{@"name": @"EE", @"mcc": @"234", @"mnc": @"30"},
                @{@"name": @"O2", @"mcc": @"234", @"mnc": @"10"},
                @{@"name": @"Vodafone", @"mcc": @"234", @"mnc": @"15"},
                @{@"name": @"Three", @"mcc": @"234", @"mnc": @"20"}
            ],
            @"cities": @[
                @{@"name": @"London", @"lat": @51.5074, @"lon": @-0.1278, @"alt": @11.0, @"tz": @"Europe/London"},
                @{@"name": @"Manchester", @"lat": @53.4808, @"lon": @-2.2426, @"alt": @38.0, @"tz": @"Europe/London"}
            ],
            @"names": @[@"iPhone", @"Sam's iPhone", @"Oliver's iPhone"]
        },
        @{
            @"locale": @"th_TH",
            @"iso": @"th",
            @"weight": @5,
            @"ipv6": @[@"2405:9800", @"2001:44c8"],
            @"carriers": @[
                @{@"name": @"AIS", @"mcc": @"520", @"mnc": @"03"},
                @{@"name": @"dtac", @"mcc": @"520", @"mnc": @"18"},
                @{@"name": @"TrueMove H", @"mcc": @"520", @"mnc": @"04"}
            ],
            @"cities": @[
                @{@"name": @"Bangkok", @"lat": @13.7563, @"lon": @100.5018, @"alt": @2.0, @"tz": @"Asia/Bangkok"},
                @{@"name": @"Chiang Mai", @"lat": @18.7883, @"lon": @98.9853, @"alt": @310.0, @"tz": @"Asia/Bangkok"}
            ],
            @"names": @[@"iPhone", @"Nong's iPhone", @"Ploy's iPhone"]
        },
        @{
            @"locale": @"en_SG",
            @"iso": @"sg",
            @"weight": @4,
            @"ipv6": @[@"2400:8901", @"2001:d00"],
            @"carriers": @[
                @{@"name": @"Singtel", @"mcc": @"525", @"mnc": @"01"},
                @{@"name": @"StarHub", @"mcc": @"525", @"mnc": @"05"},
                @{@"name": @"M1", @"mcc": @"525", @"mnc": @"03"}
            ],
            @"cities": @[
                @{@"name": @"Singapore", @"lat": @1.3521, @"lon": @103.8198, @"alt": @15.0, @"tz": @"Asia/Singapore"}
            ],
            @"names": @[@"iPhone", @"Wei's iPhone", @"Amel's iPhone"]
        },
        @{
            @"locale": @"en_AU",
            @"iso": @"au",
            @"weight": @4,
            @"ipv6": @[@"2001:8003", @"2403:5800"],
            @"carriers": @[
                @{@"name": @"Telstra", @"mcc": @"505", @"mnc": @"01"},
                @{@"name": @"Optus", @"mcc": @"505", @"mnc": @"02"},
                @{@"name": @"Vodafone", @"mcc": @"505", @"mnc": @"03"}
            ],
            @"cities": @[
                @{@"name": @"Sydney", @"lat": @-33.8688, @"lon": @151.2093, @"alt": @19.0, @"tz": @"Australia/Sydney"},
                @{@"name": @"Melbourne", @"lat": @-37.8136, @"lon": @144.9631, @"alt": @31.0, @"tz": @"Australia/Melbourne"}
            ],
            @"names": @[@"iPhone", @"Jack's iPhone", @"Mia's iPhone"]
        },
        @{
            @"locale": @"zh_TW",
            @"iso": @"tw",
            @"weight": @4,
            @"ipv6": @[@"2001:b000", @"2404:130"],
            @"carriers": @[
                @{@"name": @"Chunghwa", @"mcc": @"466", @"mnc": @"92"},
                @{@"name": @"Taiwan Mobile", @"mcc": @"466", @"mnc": @"97"},
                @{@"name": @"FarEasTone", @"mcc": @"466", @"mnc": @"01"}
            ],
            @"cities": @[
                @{@"name": @"Taipei", @"lat": @25.0330, @"lon": @121.5654, @"alt": @9.0, @"tz": @"Asia/Taipei"},
                @{@"name": @"Kaohsiung", @"lat": @22.6273, @"lon": @120.3014, @"alt": @9.0, @"tz": @"Asia/Taipei"}
            ],
            @"names": @[@"iPhone", @"Wei's iPhone", @"iPhone"]
        }
    ];
}



static NSString *CIHexUpper(NSUInteger width) {
    if (width >= 4) {
        return [NSString stringWithFormat:@"%04X", arc4random_uniform(0xFFFF)];
    }
    return [NSString stringWithFormat:@"%02X", arc4random_uniform(256)];
}

static NSString *CIOwnerHint(NSString *name) {
    NSString *latin = CILatin(name ?: @"");
    NSArray<NSString *> *parts = [latin componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *last = parts.lastObject;
    if (last.length == 0 || [last caseInsensitiveCompare:@"iPhone"] == NSOrderedSame) {
        return @"Home";
    }
    if ([last caseInsensitiveCompare:@"Pro"] == NSOrderedSame ||
        [last caseInsensitiveCompare:@"Max"] == NSOrderedSame ||
        [last caseInsensitiveCompare:@"Air"] == NSOrderedSame ||
        [last caseInsensitiveCompare:@"Plus"] == NSOrderedSame ||
        [last caseInsensitiveCompare:@"mini"] == NSOrderedSame) {
        return @"Home";
    }
    return last;
}

static NSString *CIRandomSSID(NSDictionary *region, NSString *deviceName, NSString *ipv4) {
    if ([ipv4 hasPrefix:@"172.20.10."]) {
        return deviceName.length > 0 ? deviceName : @"iPhone";
    }
    NSString *locale = region[@"locale"] ?: @"vi_VN";
    NSString *hex4 = CIHexUpper(4);
    NSString *hex2 = CIHexUpper(2);
    NSString *owner = CIOwnerHint(deviceName);
    uint32_t roll = arc4random_uniform(100);
    NSArray *router = @[
        [NSString stringWithFormat:@"TP-Link_%@", hex4],
        [NSString stringWithFormat:@"TP-Link_%@_5G", hex4],
        [NSString stringWithFormat:@"Xiaomi-%@", hex4],
        [NSString stringWithFormat:@"Redmi%@", hex4],
        [NSString stringWithFormat:@"ASUS_%@", hex2]
    ];
    NSArray *isp = nil;
    NSArray *home = nil;
    if ([locale hasPrefix:@"vi"]) {
        isp = @[@"Viettel", @"Viettel-5G", @"Viettel Fiber", @"FPT", @"FPT-Fiber", @"FPT Telecom", @"VNPT-Fiber", @"VNPT-Wifi",
                [NSString stringWithFormat:@"Viettel_%@", hex4], [NSString stringWithFormat:@"FPT_%@", hex2]];
        home = @[[NSString stringWithFormat:@"%@_Wifi", owner], [NSString stringWithFormat:@"WiFi-%@", owner], [NSString stringWithFormat:@"%@_5G", owner]];
    } else if ([locale isEqualToString:@"en_US"]) {
        isp = @[@"ATT-WiFi", @"MySpectrumWiFi", [NSString stringWithFormat:@"NETGEAR%@", hex2], [NSString stringWithFormat:@"ATT-%@", hex4], @"HomeInternet"];
        home = @[[NSString stringWithFormat:@"%@ WiFi", owner], [NSString stringWithFormat:@"%@ Network", owner]];
    } else if ([locale isEqualToString:@"ja_JP"]) {
        isp = @[@"au-Wi-Fi", @"docomo", @"SoftBank-WiFi", [NSString stringWithFormat:@"Buffalo-%@", hex4]];
        home = @[[NSString stringWithFormat:@"%@-WiFi", owner]];
    } else if ([locale isEqualToString:@"ko_KR"]) {
        isp = @[@"KT_WiFi", @"SK_WiFi", [NSString stringWithFormat:@"iptime_%@", hex2]];
        home = @[[NSString stringWithFormat:@"%@_WiFi", owner]];
    } else if ([locale isEqualToString:@"en_GB"]) {
        isp = @[@"BT-WiFi", @"Virgin Media", [NSString stringWithFormat:@"SKY%@", hex4]];
        home = @[[NSString stringWithFormat:@"%@ WiFi", owner]];
    } else if ([locale isEqualToString:@"th_TH"]) {
        isp = @[@"AIS Fibre", @"TRUE-WiFi", @"3BB"];
        home = @[[NSString stringWithFormat:@"%@_WiFi", owner]];
    } else if ([locale isEqualToString:@"en_SG"]) {
        isp = @[@"Singtel-WiFi", @"StarHub", @"M1-Fibre"];
        home = @[[NSString stringWithFormat:@"%@ WiFi", owner]];
    } else if ([locale isEqualToString:@"en_AU"]) {
        isp = @[@"Telstra", @"Optus-WiFi", @"NBN"];
        home = @[[NSString stringWithFormat:@"%@ WiFi", owner]];
    } else if ([locale isEqualToString:@"zh_TW"]) {
        isp = @[@"Hinet", @"Chunghwa", @"HiNet-WiFi"];
        home = @[[NSString stringWithFormat:@"%@_WiFi", owner]];
    } else {
        isp = @[@"WiFi", @"Home-WiFi"];
        home = @[[NSString stringWithFormat:@"%@_WiFi", owner]];
    }
    if (roll < 40 && isp.count > 0) {
        return CIPick(isp);
    }
    if (roll < 80) {
        return CIPick(router);
    }
    return CIPick(home);
}

static NSString *CIRandomBSSID(void) {
    NSArray<NSString *> *ouis = @[
        @"50:c7:bf", @"14:eb:b6", @"98:da:c4",
        @"64:b4:73", @"28:6c:07", @"04:d4:c4",
        @"2c:56:dc", @"20:08:ed", @"a8:5e:45",
        @"c8:3a:35", @"e4:d3:32", @"10:fe:ed"
    ];
    NSString *oui = CIPick(ouis);
    return [NSString stringWithFormat:@"%@:%02x:%02x:%02x",
            oui,
            arc4random_uniform(256),
            arc4random_uniform(256),
            arc4random_uniform(256)];
}

static NSString *CIGatewayFromIPv4(NSString *ipv4) {
    NSArray<NSString *> *parts = [ipv4 componentsSeparatedByString:@"."];
    if (parts.count != 4) {
        return @"192.168.1.1";
    }
    return [NSString stringWithFormat:@"%@.%@.%@.1", parts[0], parts[1], parts[2]];
}

static NSString *CIRandomRSSI(void) {
    int rssi = -38 - (int)arc4random_uniform(28);
    return [NSString stringWithFormat:@"%d", rssi];
}

static NSString *CIFirstString(NSDictionary *prefs, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id value = prefs[key];
        if ([value isKindOfClass:[NSString class]]) {
            NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (text.length > 0) {
                return text;
            }
        } else if ([value isKindOfClass:[NSNumber class]]) {
            return [value stringValue];
        }
    }
    return @"";
}


static NSString *CIRandomHex(NSUInteger length, BOOL upper) {
    static const char *lower = "0123456789abcdef";
    static const char *digits = "0123456789ABCDEF";
    const char *alphabet = upper ? digits : lower;
    NSMutableString *text = [NSMutableString stringWithCapacity:length];
    for (NSUInteger i = 0; i < length; i++) {
        [text appendFormat:@"%c", alphabet[arc4random_uniform(16)]];
    }
    return text;
}

static NSString *CIRandomSerial(void) {
    static const char *alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
    NSMutableString *text = [NSMutableString stringWithCapacity:10];
    for (int i = 0; i < 10; i++) {
        [text appendFormat:@"%c", alphabet[arc4random_uniform(32)]];
    }
    return text;
}

static NSString *CIRandomMLB(void) {
    return [NSString stringWithFormat:@"F%d%@%@", 1 + (int)arc4random_uniform(9), CIRandomSerial(), CIRandomHex(3, YES)];
}

static NSString *CIRandomIMEI(void) {
    NSMutableString *digits = [NSMutableString stringWithString:@"35"];
    for (int i = 0; i < 12; i++) {
        [digits appendFormat:@"%u", arc4random_uniform(10)];
    }
    NSInteger sum = 0;
    for (NSInteger i = 0; i < 14; i++) {
        NSInteger n = [digits characterAtIndex:(NSUInteger)i] - '0';
        if ((13 - i) % 2 == 0) {
            n *= 2;
            if (n > 9) {
                n -= 9;
            }
        }
        sum += n;
    }
    NSInteger check = (10 - (sum % 10)) % 10;
    return [digits stringByAppendingFormat:@"%ld", (long)check];
}

static NSString *CIRandomChipID(void) {
    uint64_t value = ((uint64_t)arc4random() << 32) | arc4random();
    value |= 0x100000000ULL;
    return [NSString stringWithFormat:@"%llu", (unsigned long long)value];
}

static NSDictionary *CIHardwareForModel(NSString *model) {
    static NSDictionary *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"iPhone12,1": @{@"hw": @"N104AP", @"chip": @"t8030", @"ram": @4, @"ncpu": @6},
            @"iPhone12,3": @{@"hw": @"D421AP", @"chip": @"t8030", @"ram": @4, @"ncpu": @6},
            @"iPhone12,5": @{@"hw": @"D431AP", @"chip": @"t8030", @"ram": @4, @"ncpu": @6},
            @"iPhone12,8": @{@"hw": @"D79AP", @"chip": @"t8030", @"ram": @3, @"ncpu": @6},
            @"iPhone13,1": @{@"hw": @"D52gAP", @"chip": @"t8101", @"ram": @4, @"ncpu": @6},
            @"iPhone13,2": @{@"hw": @"D53gAP", @"chip": @"t8101", @"ram": @4, @"ncpu": @6},
            @"iPhone13,3": @{@"hw": @"D53pAP", @"chip": @"t8101", @"ram": @6, @"ncpu": @6},
            @"iPhone13,4": @{@"hw": @"D54pAP", @"chip": @"t8101", @"ram": @6, @"ncpu": @6},
            @"iPhone14,4": @{@"hw": @"D16AP", @"chip": @"t8110", @"ram": @4, @"ncpu": @6},
            @"iPhone14,5": @{@"hw": @"D17AP", @"chip": @"t8110", @"ram": @4, @"ncpu": @6},
            @"iPhone14,2": @{@"hw": @"D63AP", @"chip": @"t8110", @"ram": @6, @"ncpu": @6},
            @"iPhone14,3": @{@"hw": @"D64AP", @"chip": @"t8110", @"ram": @6, @"ncpu": @6},
            @"iPhone14,6": @{@"hw": @"D49AP", @"chip": @"t8110", @"ram": @4, @"ncpu": @6},
            @"iPhone14,7": @{@"hw": @"D27AP", @"chip": @"t8110", @"ram": @6, @"ncpu": @6},
            @"iPhone14,8": @{@"hw": @"D28AP", @"chip": @"t8110", @"ram": @6, @"ncpu": @6},
            @"iPhone15,2": @{@"hw": @"D73AP", @"chip": @"t8120", @"ram": @6, @"ncpu": @6},
            @"iPhone15,3": @{@"hw": @"D74AP", @"chip": @"t8120", @"ram": @6, @"ncpu": @6},
            @"iPhone15,4": @{@"hw": @"D37AP", @"chip": @"t8122", @"ram": @6, @"ncpu": @6},
            @"iPhone15,5": @{@"hw": @"D38AP", @"chip": @"t8122", @"ram": @6, @"ncpu": @6},
            @"iPhone16,1": @{@"hw": @"D83AP", @"chip": @"t8130", @"ram": @8, @"ncpu": @6},
            @"iPhone16,2": @{@"hw": @"D84AP", @"chip": @"t8130", @"ram": @8, @"ncpu": @6},
            @"iPhone17,3": @{@"hw": @"D47AP", @"chip": @"t8140", @"ram": @8, @"ncpu": @6},
            @"iPhone17,4": @{@"hw": @"D48AP", @"chip": @"t8140", @"ram": @8, @"ncpu": @6},
            @"iPhone17,1": @{@"hw": @"D93AP", @"chip": @"t8150", @"ram": @8, @"ncpu": @6},
            @"iPhone17,2": @{@"hw": @"D94AP", @"chip": @"t8150", @"ram": @8, @"ncpu": @6},
            @"iPhone17,5": @{@"hw": @"V59AP", @"chip": @"t8140", @"ram": @8, @"ncpu": @6},
            @"iPhone18,3": @{@"hw": @"V57AP", @"chip": @"t8160", @"ram": @8, @"ncpu": @6},
            @"iPhone18,4": @{@"hw": @"V58AP", @"chip": @"t8160", @"ram": @8, @"ncpu": @6},
            @"iPhone18,1": @{@"hw": @"V53AP", @"chip": @"t8170", @"ram": @12, @"ncpu": @6},
            @"iPhone18,2": @{@"hw": @"V54AP", @"chip": @"t8170", @"ram": @12, @"ncpu": @6}
        };
    });
    return map[model] ?: @{@"hw": @"D83AP", @"chip": @"t8130", @"ram": @8, @"ncpu": @6};
}

static NSString *CIRadioForModel(NSString *model) {
    if ([model hasPrefix:@"iPhone12,"]) {
        return @"CTRadioAccessTechnologyLTE";
    }
    return @"CTRadioAccessTechnologyNR";
}

static NSDictionary *CIBuildProfile(BOOL full) {
    NSDictionary *device = CIPickWeighted(CIDevices(), @"weight");
    NSDictionary *os = CIPick(CIBiasRecent(device[@"os"]));
    NSDictionary *region = CIPickWeighted(CIRegions(), @"weight");
    NSDictionary *carrier = CIPick(region[@"carriers"]);
    NSDictionary *city = CIPick(region[@"cities"]);
    NSString *product = device[@"product"];
    NSString *name = CIPick(region[@"names"]);
    if ([name isEqualToString:@"iPhone"] && arc4random_uniform(5) == 0) {
        name = product;
    }
    NSString *host = CIHostnameFromName(name);
    NSString *timeZone = city[@"tz"] ?: region[@"timeZone"] ?: @"Asia/Ho_Chi_Minh";

    NSMutableDictionary *profile = [@{
        @"spoofedModel": device[@"model"],
        @"customDeviceModel": device[@"model"],
        @"spoofedName": name,
        @"customDeviceName": name,
        @"spoofedSystemVersion": os[@"version"],
        @"customOSVersion": os[@"version"],
        @"spoofedBuild": os[@"build"],
        @"customBuildNumber": os[@"build"],
        @"spoofedHostname": host,
        @"customHostName": host,
        @"useCustomOSVersion": @YES,
        @"deviceIdentityEnabled": @YES,
        @"profileProduct": product,
        @"profileCity": city[@"name"] ?: @"",
        @"_product": product,
        @"_region": region[@"locale"],
        @"_city": city[@"name"] ?: @""
    } mutableCopy];

    NSDictionary *hw = CIHardwareForModel(device[@"model"]);
    NSString *wifi = CIRandomMAC();
    profile[@"hwModelStr"] = hw[@"hw"];
    profile[@"hardwarePlatform"] = hw[@"chip"];
    profile[@"memoryGB"] = hw[@"ram"];
    profile[@"ncpu"] = hw[@"ncpu"];
    profile[@"spoofedVendorUUID"] = [[NSUUID UUID] UUIDString];
    profile[@"spoofedAdvertisingUUID"] = [[NSUUID UUID] UUIDString];
    profile[@"spoofedSerialNumber"] = CIRandomSerial();
    profile[@"spoofedUniqueDeviceID"] = CIRandomHex(40, NO);
    profile[@"spoofedUniqueChipID"] = CIRandomChipID();
    profile[@"spoofedIMEI"] = CIRandomIMEI();
    profile[@"mlbSerialNumber"] = CIRandomMLB();
    profile[@"wifiAddress"] = wifi;
    profile[@"bluetoothAddress"] = CIRandomMAC();
    profile[@"regionInfo"] = [NSString stringWithFormat:@"%@/A", [region[@"iso"] uppercaseString] ?: @"US"];
    profile[@"radioAccessTechnology"] = CIRadioForModel(device[@"model"]);

    if (!full) {
        return profile;
    }

    double jitter = (arc4random_uniform(10) < 7) ? 0.000003 : 0.000012;
    double lat = [city[@"lat"] doubleValue] + CIJitter(jitter);
    double lon = [city[@"lon"] doubleValue] + CIJitter(jitter);
    double alt = [city[@"alt"] doubleValue] + CIJitter(0.02);

    profile[@"masterEnabled"] = @YES;
    profile[@"localeEnabled"] = @YES;
    profile[@"localeIdentifier"] = region[@"locale"];
    profile[@"timeZoneName"] = timeZone;
    profile[@"carrierEnabled"] = @YES;
    profile[@"carrierName"] = carrier[@"name"];
    profile[@"mobileCountryCode"] = carrier[@"mcc"];
    profile[@"mobileNetworkCode"] = carrier[@"mnc"];
    profile[@"isoCountryCode"] = region[@"iso"];
    profile[@"locationEnabled"] = @YES;
    profile[@"latitude"] = CICoord(lat);
    profile[@"longitude"] = CICoord(lon);
    profile[@"altitude"] = [NSString stringWithFormat:@"%.0f", alt];
    profile[@"accuracy"] = [NSString stringWithFormat:@"%u", 5 + arc4random_uniform(16)];
    profile[@"gpxPath"] = @"";
    NSString *ipv4 = CIRandomIPv4();
    profile[@"networkEnabled"] = @YES;
    profile[@"interfaceName"] = @"en0";
    profile[@"ipv4Address"] = ipv4;
    profile[@"ipv6Address"] = CIRandomIPv6(region[@"ipv6"]);
    profile[@"macAddress"] = wifi;
    profile[@"wifiSSID"] = CIRandomSSID(region, name, ipv4);
    profile[@"wifiBSSID"] = CIRandomBSSID();
    profile[@"wifiGateway"] = CIGatewayFromIPv4(ipv4);
    profile[@"wifiRSSI"] = CIRandomRSSI();
    profile[@"appVersionEnabled"] = @NO;
    profile[@"customAppVersion"] = CIRandomAppVersion();
    return profile;
}

NSDictionary *ChengIOSRandomIdentity(void) {
    return CIBuildProfile(NO);
}

NSDictionary *ChengIOSRandomFullProfile(void) {
    return CIBuildProfile(YES);
}

NSString *ChengIOSProfileSummary(NSDictionary *profile) {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"%@ (%@)\n", profile[@"_product"] ?: @"iPhone", profile[@"spoofedModel"]];
    [text appendFormat:@"iOS %@ (%@)\n", profile[@"spoofedSystemVersion"], profile[@"spoofedBuild"]];
    [text appendFormat:@"Tên: %@\n", profile[@"spoofedName"]];
    [text appendFormat:@"Host: %@", profile[@"spoofedHostname"]];
    if ([profile[@"hwModelStr"] length] || [profile[@"spoofedSerialNumber"] length]) {
        [text appendFormat:@"\nBoard: %@", profile[@"hwModelStr"] ?: @"-"];
        [text appendFormat:@"\nChip: %@  RAM: %@ GB", profile[@"hardwarePlatform"] ?: @"-", profile[@"memoryGB"] ?: @"-"];
        [text appendFormat:@"\nSerial: %@", profile[@"spoofedSerialNumber"] ?: @"-"];
        [text appendFormat:@"\nUDID: %@", profile[@"spoofedUniqueDeviceID"] ?: @"-"];
        [text appendFormat:@"\nIDFV: %@", profile[@"spoofedVendorUUID"] ?: @"-"];
        if ([profile[@"spoofedIMEI"] length]) {
            [text appendFormat:@"\nIMEI: %@", profile[@"spoofedIMEI"]];
        }
    }
    if ([profile[@"localeIdentifier"] length] || [profile[@"wifiSSID"] length] || [profile[@"ipv4Address"] length]) {
        [text appendFormat:@"\nLocale: %@ / %@", profile[@"localeIdentifier"], profile[@"timeZoneName"]];
        [text appendFormat:@"\nNhà mạng: %@ (%@-%@)", profile[@"carrierName"], profile[@"mobileCountryCode"], profile[@"mobileNetworkCode"]];
        [text appendFormat:@"\nGPS: %@, %@ (%@)", profile[@"latitude"], profile[@"longitude"], profile[@"_city"] ?: @""];
        [text appendFormat:@"\nIP: %@\nMAC: %@", profile[@"ipv4Address"], profile[@"macAddress"]];
        if ([profile[@"wifiSSID"] length] || [profile[@"wifiBSSID"] length]) {
            [text appendFormat:@"\nWi-Fi: %@", profile[@"wifiSSID"] ?: @"-"];
            [text appendFormat:@"\nBSSID: %@", profile[@"wifiBSSID"] ?: @"-"];
            [text appendFormat:@"\nGW: %@  RSSI: %@", profile[@"wifiGateway"] ?: @"-", profile[@"wifiRSSI"] ?: @"-"];
        }
        [text appendFormat:@"\nApp: %@", profile[@"customAppVersion"]];
    }
    return text;
}

void ChengIOSApplyProfile(NSDictionary *profile) {
    if (profile.count == 0) {
        return;
    }
    NSMutableDictionary *merged = CILoadRawPrefs();
    [profile enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        (void)stop;
        if (![key isKindOfClass:[NSString class]] || [key hasPrefix:@"_"] || !CIIsPlistValue(value)) {
            return;
        }
        merged[key] = value;
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR("com.vinhnv2507.chengiosprefs"));
    }];
    CFPreferencesAppSynchronize(CFSTR("com.vinhnv2507.chengiosprefs"));
    for (NSString *path in CIPrefsPaths()) {
        NSString *dir = [path stringByDeletingLastPathComponent];
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
            continue;
        }
        [merged writeToFile:path atomically:YES];
    }
    notify_post("com.vinhnv2507.chengiosprefs/changed");
    notify_post("com.vinhnv2507.chengiosprefs/ReloadPrefs");
}

NSMutableDictionary *ChengIOSLoadRawPrefs(void) {
    return CILoadRawPrefs();
}

void ChengIOSSetPrefValue(NSString *key, id value) {
    if (key.length == 0 || !value) {
        return;
    }
    ChengIOSApplyProfile(@{key: value});
}

id ChengIOSPrefValue(NSString *key) {
    if (key.length == 0) {
        return nil;
    }
    return CILoadRawPrefs()[key];
}

NSDictionary *ChengIOSLoadSavedProfile(void) {

    NSMutableDictionary *prefs = CILoadRawPrefs();

    NSString *model = CIFirstString(prefs, @[@"spoofedModel", @"customDeviceModel"]);
    NSString *name = CIFirstString(prefs, @[@"spoofedName", @"customDeviceName"]);
    NSString *version = CIFirstString(prefs, @[@"spoofedSystemVersion", @"customOSVersion"]);
    NSString *build = CIFirstString(prefs, @[@"spoofedBuild", @"customBuildNumber"]);
    NSString *host = CIFirstString(prefs, @[@"spoofedHostname", @"customHostName"]);
    NSString *product = CIFirstString(prefs, @[@"profileProduct"]);
    NSString *city = CIFirstString(prefs, @[@"profileCity"]);

    NSMutableDictionary *profile = [NSMutableDictionary dictionary];
    profile[@"spoofedModel"] = model;
    profile[@"spoofedName"] = name;
    profile[@"spoofedSystemVersion"] = version;
    profile[@"spoofedBuild"] = build;
    profile[@"spoofedHostname"] = host;
    profile[@"_product"] = product.length ? product : (model.length ? model : @"iPhone");
    profile[@"_city"] = city;
    profile[@"localeIdentifier"] = CIFirstString(prefs, @[@"localeIdentifier"]);
    profile[@"timeZoneName"] = CIFirstString(prefs, @[@"timeZoneName"]);
    profile[@"carrierName"] = CIFirstString(prefs, @[@"carrierName"]);
    profile[@"mobileCountryCode"] = CIFirstString(prefs, @[@"mobileCountryCode"]);
    profile[@"mobileNetworkCode"] = CIFirstString(prefs, @[@"mobileNetworkCode"]);
    profile[@"isoCountryCode"] = CIFirstString(prefs, @[@"isoCountryCode"]);
    profile[@"latitude"] = CIFirstString(prefs, @[@"latitude"]);
    profile[@"longitude"] = CIFirstString(prefs, @[@"longitude"]);
    profile[@"altitude"] = CIFirstString(prefs, @[@"altitude"]);
    profile[@"accuracy"] = CIFirstString(prefs, @[@"accuracy"]);
    profile[@"ipv4Address"] = CIFirstString(prefs, @[@"ipv4Address"]);
    profile[@"ipv6Address"] = CIFirstString(prefs, @[@"ipv6Address"]);
    profile[@"macAddress"] = CIFirstString(prefs, @[@"macAddress"]);
    profile[@"wifiSSID"] = CIFirstString(prefs, @[@"wifiSSID"]);
    profile[@"wifiBSSID"] = CIFirstString(prefs, @[@"wifiBSSID"]);
    profile[@"wifiGateway"] = CIFirstString(prefs, @[@"wifiGateway"]);
    profile[@"wifiRSSI"] = CIFirstString(prefs, @[@"wifiRSSI"]);
    profile[@"customAppVersion"] = CIFirstString(prefs, @[@"customAppVersion"]);
    profile[@"interfaceName"] = CIFirstString(prefs, @[@"interfaceName"]);
    profile[@"hwModelStr"] = CIFirstString(prefs, @[@"hwModelStr"]);
    profile[@"hardwarePlatform"] = CIFirstString(prefs, @[@"hardwarePlatform"]);
    profile[@"memoryGB"] = CIFirstString(prefs, @[@"memoryGB"]);
    profile[@"ncpu"] = CIFirstString(prefs, @[@"ncpu"]);
    profile[@"spoofedSerialNumber"] = CIFirstString(prefs, @[@"spoofedSerialNumber"]);
    profile[@"spoofedUniqueDeviceID"] = CIFirstString(prefs, @[@"spoofedUniqueDeviceID"]);
    profile[@"spoofedVendorUUID"] = CIFirstString(prefs, @[@"spoofedVendorUUID"]);
    profile[@"spoofedAdvertisingUUID"] = CIFirstString(prefs, @[@"spoofedAdvertisingUUID"]);
    profile[@"spoofedIMEI"] = CIFirstString(prefs, @[@"spoofedIMEI"]);
    profile[@"wifiAddress"] = CIFirstString(prefs, @[@"wifiAddress", @"macAddress"]);
    profile[@"bluetoothAddress"] = CIFirstString(prefs, @[@"bluetoothAddress"]);
    profile[@"regionInfo"] = CIFirstString(prefs, @[@"regionInfo"]);
    profile[@"radioAccessTechnology"] = CIFirstString(prefs, @[@"radioAccessTechnology"]);
    return profile;
}
