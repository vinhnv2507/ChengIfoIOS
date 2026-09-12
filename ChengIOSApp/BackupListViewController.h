#import <UIKit/UIKit.h>

BOOL ChengIOSHandleBackupURL(NSURL *url, UIViewController *host);

@interface BackupListViewController : UITableViewController
- (void)promptBackupIncludingAppData:(BOOL)includeAppData suggestedName:(NSString *)name silent:(BOOL)silent;
- (void)promptEraseBundles:(NSArray<NSString *> *)bundleIDs silent:(BOOL)silent;
@end
