#import "ChengIOSDeeplinksController.h"
#import <UIKit/UIKit.h>

@implementation ChengIOSDeeplinksController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Deeplinks" target:self];
    }
    return _specifiers;
}

- (void)copyURL:(PSSpecifier *)specifier {
    NSString *url = [specifier propertyForKey:@"url"];
    if (url.length == 0) {
        return;
    }
    [UIPasteboard generalPasteboard].string = url;
    if (![UIAlertController class]) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Da sao chep"
                                                                   message:url
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
