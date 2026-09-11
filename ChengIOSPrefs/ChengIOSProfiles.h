#import <Foundation/Foundation.h>

NSDictionary *ChengIOSRandomIdentity(void);
NSDictionary *ChengIOSRandomFullProfile(void);
NSDictionary *ChengIOSLoadSavedProfile(void);
NSString *ChengIOSProfileSummary(NSDictionary *profile);
void ChengIOSApplyProfile(NSDictionary *profile);
