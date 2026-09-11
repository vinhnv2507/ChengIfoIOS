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
    NSDictionary *profile = iso.length ? ChengIOSRandomFullProfileInRegion(iso) : ChengIOSRandomFullProfile();
    [self chengApplyProfile:profile];
    NSString *summary = ChengIOSProfileSummary(profile);
    if (![UIAlertController class]) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:summary
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Random lai" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        [self randomizeISO:iso title:title];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Sao chep" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        [UIPasteboard generalPasteboard].string = summary;
    }]];
    [self presentViewController:alert animated:YES completion:nil];
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
