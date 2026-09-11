#import "AppDelegate.h"
#import "RootViewController.h"

@implementation AppDelegate

- (RootViewController *)chengRoot {
    UINavigationController *nav = (UINavigationController *)self.window.rootViewController;
    if (![nav isKindOfClass:[UINavigationController class]]) {
        return nil;
    }
    UIViewController *top = nav.viewControllers.firstObject;
    if (![top isKindOfClass:[RootViewController class]]) {
        return nil;
    }
    return (RootViewController *)top;
}

- (BOOL)chengHandleURL:(NSURL *)url {
    RootViewController *root = [self chengRoot];
    if (!root || !url) {
        return NO;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [root handleURL:url];
    });
    return YES;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    if (@available(iOS 13.0, *)) {
        self.window.backgroundColor = [UIColor systemBackgroundColor];
    } else {
        self.window.backgroundColor = [UIColor whiteColor];
    }
    RootViewController *root = [[RootViewController alloc] initWithStyle:UITableViewStyleGrouped];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)options {
    (void)app;
    (void)options;
    return [self chengHandleURL:url];
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation {
    (void)application;
    (void)sourceApplication;
    (void)annotation;
    return [self chengHandleURL:url];
}

@end
