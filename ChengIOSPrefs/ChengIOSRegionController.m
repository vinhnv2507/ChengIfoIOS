#import "ChengIOSRegionController.h"
#import "ChengIOSProfiles.h"

#import <UIKit/UIKit.h>

@implementation ChengIOSRegionController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Regions" target:self];
    }
    return _specifiers;
}

- (void)randomizeISO:(NSString *)iso title:(NSString *)title {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *profile = iso.length ? ChengIOSRandomFullProfileInRegion(iso) : ChengIOSRandomFullProfile();
        dispatch_async(dispatch_get_main_queue(), ^{
            [self chengApplyAndRespring:profile title:title];
        });
    });
}

- (void)randomizeRegionAuto { [self randomizeISO:nil title:@"Random theo IP"]; }
- (void)randomizeRegionVN { [self randomizeISO:@"vn" title:@"Random Viet Nam"]; }
- (void)randomizeRegionUS { [self randomizeISO:@"us" title:@"Random United States"]; }
- (void)randomizeRegionKR { [self randomizeISO:@"kr" title:@"Random Korea"]; }
- (void)randomizeRegionJP { [self randomizeISO:@"jp" title:@"Random Japan"]; }
- (void)randomizeRegionGB { [self randomizeISO:@"gb" title:@"Random United Kingdom"]; }
- (void)randomizeRegionTH { [self randomizeISO:@"th" title:@"Random Thailand"]; }
- (void)randomizeRegionSG { [self randomizeISO:@"sg" title:@"Random Singapore"]; }
- (void)randomizeRegionAU { [self randomizeISO:@"au" title:@"Random Australia"]; }
- (void)randomizeRegionTW { [self randomizeISO:@"tw" title:@"Random Taiwan"]; }

@end
