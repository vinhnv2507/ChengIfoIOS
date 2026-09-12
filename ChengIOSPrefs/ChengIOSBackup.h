#import <Foundation/Foundation.h>

NSString *ChengIOSBackupRoot(void);
NSString *ChengIOSSuggestedBackupName(void);
NSArray<NSDictionary *> *ChengIOSListBackups(void);
NSDictionary *ChengIOSBackupInfo(NSString *backupID);
NSString *ChengIOSLatestBackupID(void);

NSArray<NSString *> *ChengIOSSelectedBundleIDs(void);
NSArray<NSString *> *ChengIOSUserSelectedBundleIDs(void);
NSArray<NSString *> *ChengIOSInstalledUserBundleIDs(void);
BOOL ChengIOSBundleIsProtected(NSString *bundleID);
BOOL ChengIOSBundleIsSafari(NSString *bundleID);

NSDictionary *ChengIOSCreateBackup(NSString *name, NSArray<NSString *> *bundleIDs, BOOL includeAppData, NSError **error);
BOOL ChengIOSRestoreBackup(NSString *backupID, BOOL restoreProfile, BOOL restoreAppData, NSError **error);
BOOL ChengIOSDeleteBackup(NSString *backupID, NSError **error);
BOOL ChengIOSRenameBackup(NSString *backupID, NSString *name, NSError **error);
NSDictionary *ChengIOSEraseBundles(NSArray<NSString *> *bundleIDs, NSError **error);
NSDictionary *ChengIOSEraseSafari(NSError **error);
NSDictionary *ChengIOSEraseDeviceApps(BOOL includeSafari, NSError **error);
NSDictionary *ChengIOSEraseThenRandom(NSArray<NSString *> *bundleIDs, BOOL allDevice, BOOL randomAll, NSString *region, NSError **error);

NSString *ChengIOSBackupErrorMessage(NSError *error);
