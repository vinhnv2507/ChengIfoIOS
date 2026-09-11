#import "ChengIOSCurrentInfoController.h"

@implementation ChengIOSCurrentInfoController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"CurrentInfo" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSArray *keys = [specifier propertyForKey:@"keys"];
    if (![keys isKindOfClass:[NSArray class]] || keys.count == 0) {
        NSString *key = [specifier propertyForKey:@"key"];
        keys = key.length > 0 ? @[key] : @[];
    }
    for (NSString *key in keys) {
        if (![key isKindOfClass:[NSString class]] || key.length == 0) {
            continue;
        }
        CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("com.vinhnv2507.chengiosprefs"));
        if (!value) {
            continue;
        }
        id object = (__bridge_transfer id)value;
        if ([object isKindOfClass:[NSString class]]) {
            NSString *text = [object stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (text.length > 0) {
                return text;
            }
        } else if ([object isKindOfClass:[NSNumber class]]) {
            return [object stringValue];
        }
    }
    return @"\u2014";
}

@end
