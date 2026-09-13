#import <Foundation/Foundation.h>

NSString *ChengIOSBackupRoot(void);
NSString *ChengIOSSuggestedBackupName(void);
NSArray<NSDictionary *> *ChengIOSListBackups(void);
NSDictionary *ChengIOSBackupInfo(NSString *backupID);
NSString *ChengIOSLatestBackupID(void);

NSArray<NSString *> *ChengIOSSelectedBundleIDs(void);
NSArray<NSString *> *ChengIOSUserSelectedBundleIDs(void);
BOOL ChengIOSBundleIsProtected(NSString *bundleID);

NSDictionary *ChengIOSCreateBackup(NSString *name, NSArray<NSString *> *bundleIDs, BOOL includeAppData, NSError **error);
BOOL ChengIOSRestoreBackup(NSString *backupID, BOOL restoreProfile, BOOL restoreAppData, NSError **error);
BOOL ChengIOSDeleteBackup(NSString *backupID, NSError **error);
BOOL ChengIOSRenameBackup(NSString *backupID, NSString *name, NSError **error);
NSDictionary *ChengIOSEraseBundles(NSArray<NSString *> *bundleIDs, NSError **error);

NSString *ChengIOSBackupErrorMessage(NSError *error);

