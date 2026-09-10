#import "ChengIOSChangeInfoController.h"

@implementation ChengIOSChangeInfoController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"ChangeInfo" target:self];
    }
    return _specifiers;
}

@end
