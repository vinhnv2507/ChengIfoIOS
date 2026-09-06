#import "VCamPaths.h"

#if __has_include(<roothide.h>)
#import <roothide.h>
#define VCAM_HAS_ROOTHIDE 1
#endif

BOOL VCamIsRootless(void) {
#if VCAM_HAS_ROOTHIDE
    return YES;
#else
    return [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"];
#endif
}

NSString *VCamSharedDirectory(void) {
    // mediaserverd is sandboxed away from /var/mobile/Library on newer iOS.
    // The global temporary directory is visible to both the platform app and
    // the camera daemons on rootful and rootless jailbreaks.
#if VCAM_HAS_ROOTHIDE
    return jbroot(@"/var/tmp");
#else
    // /var/tmp is the canonical shared temporary directory visible to both
    // the sandboxed VCam app and camera daemons on iOS 15.  Using the
    // /private/var/tmp spelling can resolve to different jailbreak mount
    // namespaces, leaving mediaserverd with a separate preferences/media
    // file and making the app appear configured while Camera sees nothing.
    return @"/var/tmp";
#endif
}

NSString *VCamPreferencesFile(void) {
    return [VCamSharedDirectory() stringByAppendingPathComponent:@"com.yourcompany.vcam.plist"];
}

NSString *VCamStatusFile(void) {
    return [VCamSharedDirectory() stringByAppendingPathComponent:@"com.yourcompany.vcam.status.plist"];
}

NSString *VCamAdjustmentsFile(void) {
    return [VCamSharedDirectory() stringByAppendingPathComponent:@"com.yourcompany.vcam.adjustments.plist"];
}

NSString *VCamMediaFile(NSString *extension) {
    NSString *name = [NSString stringWithFormat:@"media-%@.%@",
        [[NSUUID UUID] UUIDString], extension.length ? extension : @"dat"];
    return [VCamSharedDirectory() stringByAppendingPathComponent:name];
}
