#import <Foundation/Foundation.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface APPRootListController : PSListController
- (void)respring;
- (void)performRespring;
- (void)refreshPrefs;
- (void)randomizeIdentity;
- (void)randomizeAll;
- (void)showCurrentInfo;
- (void)copyCurrentInfo;
- (void)chengApplyProfile:(NSDictionary *)profile;
- (void)chengShowProfile:(NSDictionary *)profile title:(NSString *)title full:(BOOL)full;
@end
