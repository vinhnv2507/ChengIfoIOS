#import <Foundation/Foundation.h>

NSDictionary *ChengIOSRandomIdentity(void);
NSDictionary *ChengIOSRandomFullProfile(void);
NSDictionary *ChengIOSRandomFullProfileInRegion(NSString *iso);
NSArray<NSDictionary *> *ChengIOSRegionChoices(void);
NSDictionary *ChengIOSLoadSavedProfile(void);
NSString *ChengIOSProfileSummary(NSDictionary *profile);
void ChengIOSApplyProfile(NSDictionary *profile);
NSDictionary *ChengIOSMintAppIdentity(void);
void ChengIOSAssignAppIdentity(NSArray<NSString *> *bundleIDs, NSDictionary *identity);
void ChengIOSReplaceRawPrefs(NSDictionary *prefs);
NSMutableDictionary *ChengIOSLoadRawPrefs(void);
void ChengIOSSetPrefValue(NSString *key, id value);
id ChengIOSPrefValue(NSString *key);
