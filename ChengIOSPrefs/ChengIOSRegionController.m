#import "ChengIOSRegionController.h"
#import "ChengIOSProfiles.h"

@implementation ChengIOSRegionController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Regions" target:self];
    }
    return _specifiers;
}

- (void)randomizeISO:(NSString *)iso title:(NSString *)title {
    NSDictionary *profile = iso.length ? ChengIOSRandomFullProfileInRegion(iso) : ChengIOSRandomFullProfile();
    [self chengApplyProfile:profile];
    [self chengShowProfile:profile title:title full:YES];
}

- (void)randomizeRegionAuto { [self randomizeISO:nil title:@"Random tu dong"]; }
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
