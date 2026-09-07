#import <CoreMedia/CoreMedia.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import "image_utils.h"
#import "VCamPaths.h"
#include <sys/stat.h>
#include <stdint.h>

// Track whether media was loaded for the current prefs; reload when it changes.
static BOOL vcam_needsLoad = YES;
static uint64_t vcam_liveStamp = 0;
static CFAbsoluteTime vcam_lastLiveCheck = 0;
static NSString *vcam_observedMediaPath = nil;
static BOOL vcam_observedEnabled = YES;
static BOOL vcam_hasObservedPreferences = NO;
static CFAbsoluteTime vcam_perfWindowStart = 0;
static double vcam_perfTotal = 0;
static NSUInteger vcam_perfCount = 0;
static NSUInteger vcam_perfSlowCount = 0;

static void vcam_recordPerformance(CFAbsoluteTime elapsed, BOOL replaced) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (vcam_perfWindowStart == 0) vcam_perfWindowStart = now;
    // A failed draw is still useful diagnostically, but don't classify it as
    // a slow render (there was no replacement work to measure).
    vcam_perfTotal += replaced ? elapsed : 0.0;
    vcam_perfCount++;
    if (elapsed > 0.040) vcam_perfSlowCount++;
    if ((now - vcam_perfWindowStart) < 5.0 || vcam_perfCount < 30) return;

    double averageMS = (vcam_perfTotal / (double)vcam_perfCount) * 1000.0;
    NSUInteger slow = vcam_perfSlowCount;
    BOOL anyReplacement = vcam_perfTotal > 0.0;
    vcam_perfWindowStart = now;
    vcam_perfTotal = 0;
    vcam_perfCount = 0;
    vcam_perfSlowCount = 0;
    // Keep this diagnostic deliberately infrequent; never touch the plist on
    // every camera callback.  It lets the app show whether rendering is
    // taking long enough to make the UI feel laggy.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *status = @{
            @"loaded": @(anyReplacement),
            @"message": anyReplacement
                ? [NSString stringWithFormat:@"Hiá»‡u nÄƒng: %.1f ms/frame (%lu cháº­m)", averageMS, (unsigned long)slow]
                : @"KhÃ´ng ghi Ä‘Æ°á»£c frame vÃ o camera",
            @"timestamp": [NSDate date]
        };
        [status writeToFile:VCamStatusFile() atomically:YES];
    });
}

static void vcam_ensureLoaded(void) {
    // Live video updates a single JPEG many times per second.  Do not make the
    // app rewrite preferences (and post a Darwin notification) for every
    // frame; detect the file's nanosecond mtime directly from the camera hook.
    // Stat the live JPEG at most ~12 times per second.  mediaserverd can call
    // this method for every camera sample (30+ times/sec); doing a plist/stat
    // read and decoding a new JPEG for each callback makes the A10 UI feel
    // stuck even though the replacement image itself is valid.
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL preferenceReloadRequested = vcam_needsLoad || !vcam_hasObservedPreferences;
    if (!vcam_needsLoad && (now - vcam_lastLiveCheck) < (1.0 / 12.0)) {
        return;
    }
    vcam_lastLiveCheck = now;
    // Preferences are loaded only on the initial pass or after the app's
    // Darwin notification. A synchronous NSDictionary/plist parse on this
    // callback was needlessly stealing time from the A10 pipeline on every
    // live frame.
    NSString *mediaPath = vcam_observedMediaPath;
    if (preferenceReloadRequested) {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:VCamPreferencesFile()];
        NSString *newPath = [prefs[@"mediaPath"] isKindOfClass:[NSString class]] ? prefs[@"mediaPath"] : nil;
        id enabledValue = prefs[@"enabled"];
        BOOL enabled = enabledValue == nil ? YES : [enabledValue boolValue];
        vcam_observedMediaPath = [newPath copy];
        vcam_observedEnabled = enabled;
        vcam_hasObservedPreferences = YES;
        mediaPath = vcam_observedMediaPath;
    }
    if (!vcam_needsLoad) {
        NSString *path = mediaPath;
        NSString *livePath = [VCamSharedDirectory() stringByAppendingPathComponent:@"media-live.jpg"];
        if ([path isEqualToString:livePath]) {
            struct stat st;
            if (stat(path.fileSystemRepresentation, &st) == 0) {
                uint64_t stamp = ((uint64_t)st.st_mtimespec.tv_sec << 32) ^
                    (uint64_t)st.st_mtimespec.tv_nsec;
                if (stamp != vcam_liveStamp) {
                    vcam_liveStamp = stamp;
                    vcam_needsLoad = YES;
                }
            }
        }
    }
    if (vcam_needsLoad) {
        // Reset the flag before loading so a failure doesn't busy-loop every frame.
        vcam_needsLoad = NO;
        NSString *livePath = [VCamSharedDirectory() stringByAppendingPathComponent:@"media-live.jpg"];
        if ([mediaPath isEqualToString:livePath] && vcam_liveStamp != 0) {
            // Live frames keep the same preference path. Avoid rebuilding the
            // whole media state and writing a status plist for every JPEG.
            if (!reloadReplacementLiveFrame(mediaPath)) vcam_needsLoad = YES;
        } else {
            loadReplacementMedia();
        }
    }
}

// Darwin notification callback: trigger a media reload when prefs change.
static void vcamPrefsChanged(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    vcam_needsLoad = YES;
    vcam_liveStamp = 0;
    vcam_lastLiveCheck = 0;
    vcam_hasObservedPreferences = NO;
}

static void vcamAdjustmentsChanged(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadReplacementAdjustments();
}

%hook BWNodeOutput

- (void)emitSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    unsigned int mediaType = ((unsigned int (*)(id, SEL))objc_msgSend)(self, sel_registerName("mediaType"));
    if (mediaType != 'vide') {
        %orig(sampleBuffer);
        return;
    }

    CVPixelBufferRef originalImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (originalImageBuffer == NULL) {
        %orig(sampleBuffer);
        return;
    }

    // First frame: (re)load media from preferences.
    vcam_ensureLoaded();

    // Camera callbacks may run without a short-lived autorelease pool. Core
    // Image creates temporary objects for every frame, so drain them here and
    // never let an unsupported buffer exception terminate the camera daemon.
    CFAbsoluteTime drawStart = CFAbsoluteTimeGetCurrent();
    BOOL replaced = NO;
    @autoreleasepool {
        @try {
            replaced = drawReplacementOntoBuffer(originalImageBuffer);
        } @catch (NSException *exception) {
            // Leave the real camera frame untouched when Core Image rejects a
            // transient/auxiliary pixel-buffer format.
        }
    }
    vcam_recordPerformance(CFAbsoluteTimeGetCurrent() - drawStart, replaced);

    %orig(sampleBuffer);
}

%end

%ctor {
    // Watch for preference changes so media hot-reloads without a respring.
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        vcamPrefsChanged,
        (__bridge CFStringRef)@"com.yourcompany.vcam.prefs.changed",
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        vcamAdjustmentsChanged,
        (__bridge CFStringRef)@"com.yourcompany.vcam.adjustments.changed",
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}
