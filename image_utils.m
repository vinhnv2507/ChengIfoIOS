#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import "VCamPaths.h"
#import "VCamLiveFrame.h"
#include <stdlib.h>
#include <math.h>
#include <string.h>

// ---- Preferences bundle ----
NSString *const kVCamEnabledKey = @"enabled";
NSString *const kVCamMediaPathKey = @"mediaPath";
NSString *const kVCamOffsetXKey = @"offsetX";
NSString *const kVCamOffsetYKey = @"offsetY";
NSString *const kVCamZoomKey = @"zoom";
NSString *const kVCamBrightnessKey = @"brightness";
NSString *const kVCamRotationKey = @"rotation";
NSString *const kVCamFlipHorizontalKey = @"flipHorizontal";
NSString *const kVCamFlipVerticalKey = @"flipVertical";

typedef NS_ENUM(NSInteger, VCamMode) {
    VCamModeNone = 0,
    VCamModeImage,
    VCamModeVideo
};

// ---- State (all guarded by vcamLock) ----
static VCamMode currentMode = VCamModeNone;
static CGImageRef replacementImage = NULL;
static NSArray<NSString *> *videoFramePaths = nil;
static CGImageRef currentVideoImage = NULL;
static CVPixelBufferRef liveNV12Buffer = NULL;
static NSUInteger videoFrameIndex = 0;
static CFAbsoluteTime nextVideoFrameTime = 0;
static CIContext *sharedCIContext = NULL;
static CIContext *softwareCIContext = NULL;
static NSLock *vcamLock = NULL;
static NSMutableDictionary<NSString *, id> *renderedFrameCache = nil;
static CGColorSpaceRef sharedColorSpace = NULL;
// Live JPEG decoding must never run on mediaserverd's camera callback thread.
// Keep at most one decode in flight; a newer file replaces the pending one on
// the next callback after the current decode completes.
static BOOL liveDecodePending = NO;
static NSUInteger liveDecodeGeneration = 0;
// Native VideoToolbox frames are copied into a CVPixelBuffer off the camera
// callback.  Reading/mapping a raw NV12 file and allocating an IOSurface can
// take several milliseconds on A10; doing that synchronously makes touches
// and camera delivery stutter.  Keep one latest-frame decode in flight and
// leave the previous buffer active until the new one is ready.
static BOOL liveNV12DecodePending = NO;

static void ensureVCamLock(void) {
    if (vcamLock == NULL) {
        vcamLock = [[NSLock alloc] init];
    }
}

// Cached preference values, refreshed on each (re)load.
static NSString *cachedMediaPath = nil;
static BOOL cachedEnabled = YES;
static CGFloat cachedOffsetX = 0.0;
static CGFloat cachedOffsetY = 0.0;
static CGFloat cachedZoom = 1.0;
static CGFloat cachedBrightness = 0.0;
static CGFloat cachedRotation = 0.0;
static BOOL cachedFlipHorizontal = NO;
static BOOL cachedFlipVertical = NO;

static void readAdjustmentPreferences(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:VCamAdjustmentsFile()];
    cachedOffsetX = MAX(-1.0, MIN(1.0, [prefs[kVCamOffsetXKey] doubleValue]));
    cachedOffsetY = MAX(-1.0, MIN(1.0, [prefs[kVCamOffsetYKey] doubleValue]));
    double zoom = [prefs[kVCamZoomKey] doubleValue];
    cachedZoom = MAX(0.5, MIN(3.0, zoom == 0.0 ? 1.0 : zoom));
    cachedBrightness = MAX(-1.0, MIN(1.0, [prefs[kVCamBrightnessKey] doubleValue]));
    cachedRotation = [prefs[kVCamRotationKey] doubleValue];
    cachedFlipHorizontal = [prefs[kVCamFlipHorizontalKey] boolValue];
    cachedFlipVertical = [prefs[kVCamFlipVerticalKey] boolValue];
}

static void writeLoadStatus(NSString *message, BOOL loaded) {
    NSDictionary *status = @{
        @"loaded": @(loaded),
        @"message": message ?: @"Unknown",
        @"timestamp": [NSDate date]
    };
    [status writeToFile:VCamStatusFile() atomically:YES];
}

static NSString *resolveMediaPath(NSString *path) {
    if (path.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:path]) return path;
    // Rootless jailbreaks can expose the same temp directory through either
    // /var/tmp or /private/var/tmp depending on the process sandbox.  The app
    // and mediaserverd may therefore record equivalent paths with different
    // prefixes; try the canonical aliases before reporting a load failure.
    NSMutableArray<NSString *> *alternates = [NSMutableArray array];
    if ([path hasPrefix:@"/private/var/tmp/"]) {
        [alternates addObject:[path stringByReplacingOccurrencesOfString:@"/private/var/tmp/"
            withString:@"/var/tmp/"]];
        [alternates addObject:[path stringByReplacingOccurrencesOfString:@"/private/var/tmp/"
            withString:@"/var/jb/var/tmp/"]];
        [alternates addObject:[path stringByReplacingOccurrencesOfString:@"/private/var/tmp/"
            withString:@"/var/jb/private/var/tmp/"]];
    } else if ([path hasPrefix:@"/var/tmp/"]) {
        [alternates addObject:[path stringByReplacingOccurrencesOfString:@"/var/tmp/"
            withString:@"/private/var/tmp/"]];
        [alternates addObject:[path stringByReplacingOccurrencesOfString:@"/var/tmp/"
            withString:@"/var/jb/var/tmp/"]];
    }
    for (NSString *candidate in alternates) {
        if ([fm fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

static NSString *currentPrefsMediaPath(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:VCamPreferencesFile()];
    NSString *path = prefs[kVCamMediaPathKey];
    if (![path isKindOfClass:[NSString class]] || path.length == 0) {
        return nil;
    }
    return path;
}

static BOOL currentPrefsEnabled(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:VCamPreferencesFile()];
    id enabled = prefs[kVCamEnabledKey];
    if (enabled == nil) return YES; // default enabled
    return [enabled boolValue];
}

/// Frees all retained media. Must be called with vcamLock held.
static void freeMedia(void) {
    liveDecodeGeneration++;
    if (replacementImage) {
        CGImageRelease(replacementImage);
        replacementImage = NULL;
    }
    if (currentVideoImage) {
        CGImageRelease(currentVideoImage);
        currentVideoImage = NULL;
    }
    if (liveNV12Buffer) {
        CVPixelBufferRelease(liveNV12Buffer);
        liveNV12Buffer = NULL;
    }
    videoFramePaths = nil;
    videoFrameIndex = 0;
    nextVideoFrameTime = 0;
    [renderedFrameCache removeAllObjects];
    currentMode = VCamModeNone;
}

/// Loads an image file (png/jpg/jpeg) into replacementImage. Returns YES on success.
/// Must be called with vcamLock held.
static BOOL loadImageMedia(NSString *path) {
    NSString *resolvedPath = resolveMediaPath(path);
    if (!resolvedPath) return NO;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:resolvedPath], NULL);
    if (!source) return NO;
    // iPhone 7 camera daemons have a tight memory budget. A 4K decoded JPEG
    // alone can occupy over 50 MB, so keep the source near preview resolution.
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
        (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
        (id)kCGImageSourceShouldCacheImmediately : @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize : @(2048)
    });
    if (image) {
        replacementImage = image; // takes ownership of +1 retain
        currentMode = VCamModeImage;
        CFRelease(source);
        return YES;
    }
    CFRelease(source);
    return NO;
}

static BOOL loadVideoMedia(NSString *path) {
    path = resolveMediaPath(path);
    if (!path) return NO;
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) return NO;
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
    NSPredicate *jpegPredicate = [NSPredicate predicateWithBlock:^BOOL(NSString *file, NSDictionary *bindings) {
        NSString *ext = file.pathExtension.lowercaseString;
        return [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"];
    }];
    files = [[files filteredArrayUsingPredicate:jpegPredicate] sortedArrayUsingSelector:@selector(compare:)];
    if (files.count == 0) return NO;
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:files.count];
    for (NSString *file in files) [paths addObject:[path stringByAppendingPathComponent:file]];
    videoFramePaths = [paths copy];
    currentMode = VCamModeVideo;
    return YES;
}

BOOL reloadReplacementLiveFrame(NSString *path) {
    if (path.length == 0) return NO;
    ensureVCamLock();
    [vcamLock lock];

    if (liveDecodePending) {
        [vcamLock unlock];
        return YES;
    }
    liveDecodePending = YES;
    NSUInteger generation = liveDecodeGeneration;
    NSString *requestedPath = [path copy];
    [vcamLock unlock];

    // ImageIO JPEG parsing and thumbnail decode can take tens of milliseconds
    // on an A10. Do it on a utility queue so camera delivery and touch input
    // remain responsive. The old frame stays active until the new one is
    // completely decoded.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *resolvedPath = resolveMediaPath(requestedPath);
        CGImageRef nextImage = NULL;
        if (resolvedPath) {
            CGImageSourceRef source = CGImageSourceCreateWithURL(
                (__bridge CFURLRef)[NSURL fileURLWithPath:resolvedPath], NULL);
            if (source) {
                // Live frames are already small, but asking ImageIO for a
                // thumbnail avoids allocating a full-resolution intermediate
                // image and makes repeated RTSP JPEG updates cheaper on A10.
                NSDictionary *thumbnailOptions = @{
                    (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
                    (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
                    (id)kCGImageSourceShouldCacheImmediately : @YES,
                    (id)kCGImageSourceThumbnailMaxPixelSize : @400
                };
                nextImage = CGImageSourceCreateThumbnailAtIndex(
                    source, 0, (__bridge CFDictionaryRef)thumbnailOptions);
                CFRelease(source);
            }
        }

        ensureVCamLock();
        [vcamLock lock];
        if (nextImage && generation == liveDecodeGeneration) {
            if (replacementImage) CGImageRelease(replacementImage);
            replacementImage = nextImage;
            currentMode = VCamModeImage;
            [renderedFrameCache removeAllObjects];
        }
        liveDecodePending = NO;
        [vcamLock unlock];
    });
    return YES;
}

BOOL reloadReplacementLiveNV12Frame(NSString *path) {
    if (path.length == 0) return NO;
    ensureVCamLock();
    [vcamLock lock];
    if (liveNV12DecodePending) {
        [vcamLock unlock];
        return YES;
    }
    liveNV12DecodePending = YES;
    NSUInteger generation = liveDecodeGeneration;
    NSString *requestedPath = [path copy];
    [vcamLock unlock];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSData *data = [NSData dataWithContentsOfFile:resolveMediaPath(requestedPath)
                options:NSDataReadingMappedIfSafe error:nil];
            CVPixelBufferRef next = NULL;
            if (data.length >= sizeof(VCamLiveNV12Header)) {
                const VCamLiveNV12Header *header = data.bytes;
                size_t yBytes = (size_t)header->yStride * header->height;
                size_t uvBytes = (size_t)header->uvStride * ((header->height + 1) / 2);
                if (header->magic == VCAM_LIVE_NV12_MAGIC && header->width > 0 &&
                    header->height > 0 && header->yStride >= header->width &&
                    header->uvStride >= header->width &&
                    sizeof(*header) + yBytes + uvBytes <= data.length) {
                    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
                    if (CVPixelBufferCreate(kCFAllocatorDefault, header->width, header->height,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            (__bridge CFDictionaryRef)attributes, &next) != kCVReturnSuccess) {
                        next = NULL;
                    }
                    if (next && CVPixelBufferLockBaseAddress(next, 0) == kCVReturnSuccess) {
                        const uint8_t *srcY = (const uint8_t *)data.bytes + sizeof(*header);
                        const uint8_t *srcUV = srcY + yBytes;
                        uint8_t *dstY = CVPixelBufferGetBaseAddressOfPlane(next, 0);
                        uint8_t *dstUV = CVPixelBufferGetBaseAddressOfPlane(next, 1);
                        size_t dstYStride = CVPixelBufferGetBytesPerRowOfPlane(next, 0);
                        size_t dstUVStride = CVPixelBufferGetBytesPerRowOfPlane(next, 1);
                        for (uint32_t y = 0; y < header->height; y++)
                            memcpy(dstY + y * dstYStride, srcY + y * header->yStride,
                                MIN(dstYStride, (size_t)header->yStride));
                        for (uint32_t y = 0; y < (header->height + 1) / 2; y++)
                            memcpy(dstUV + y * dstUVStride, srcUV + y * header->uvStride,
                                MIN(dstUVStride, (size_t)header->uvStride));
                        CVPixelBufferUnlockBaseAddress(next, 0);
                    } else if (next) {
                        CVPixelBufferRelease(next);
                        next = NULL;
                    }
                }
            }

            ensureVCamLock();
            [vcamLock lock];
            if (next && generation == liveDecodeGeneration) {
                if (liveNV12Buffer) CVPixelBufferRelease(liveNV12Buffer);
                liveNV12Buffer = next;
                currentMode = VCamModeImage;
                [renderedFrameCache removeAllObjects];
                next = NULL;
            }
            if (next) CVPixelBufferRelease(next);
            liveNV12DecodePending = NO;
            [vcamLock unlock];
        }
    });
    return YES;
}

void loadReplacementMedia(void) {
    ensureVCamLock();
    [vcamLock lock];

    // 1) Read (and cache) preferences.
    NSString *mediaPath = currentPrefsMediaPath();
    BOOL enabled = currentPrefsEnabled();
    readAdjustmentPreferences();
    if (![mediaPath isEqualToString:cachedMediaPath]) {
        cachedMediaPath = [mediaPath copy];
    }
    if (enabled != cachedEnabled) cachedEnabled = enabled;

    // 2) Always free the previous media first (fixes the memory leak).
    freeMedia();

    // 3) Nothing to do if disabled in preferences.
    if (!cachedEnabled || cachedMediaPath == nil) {
        writeLoadStatus(cachedEnabled ? @"No media selected" : @"VCam disabled", NO);
        [vcamLock unlock];
        return;
    }

    // 4) Ensure CIContext exists once.
    if (sharedCIContext == NULL) {
        sharedCIContext = [CIContext context];
    }
    if (softwareCIContext == NULL) {
        softwareCIContext = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer : @YES }];
    }
    if (renderedFrameCache == nil) {
        renderedFrameCache = [NSMutableDictionary dictionary];
    }
    if (sharedColorSpace == NULL) {
        sharedColorSpace = CGColorSpaceCreateDeviceRGB();
    }

    // 5) Load based on extension.
    NSString *ext = [cachedMediaPath pathExtension].lowercaseString;
    BOOL loaded = NO;
    if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) {
        loaded = loadImageMedia(cachedMediaPath);
    }
    else if ([ext isEqualToString:@"vcamframes"]) {
        loaded = loadVideoMedia(cachedMediaPath);
    }

    if (!loaded) {
        currentMode = VCamModeNone;
        writeLoadStatus(@"Could not load selected media", NO);
    } else {
        writeLoadStatus(currentMode == VCamModeImage ? @"Image loaded" : @"Video loaded", YES);
    }

    [vcamLock unlock];
}

void reloadReplacementAdjustments(void) {
    ensureVCamLock();
    [vcamLock lock];
    readAdjustmentPreferences();
    [renderedFrameCache removeAllObjects];
    [vcamLock unlock];
}

void unloadReplacementMedia(void) {
    ensureVCamLock();
    [vcamLock lock];
    freeMedia();
    [vcamLock unlock];
}

static BOOL copyRenderedBuffer(CVPixelBufferRef source, CVPixelBufferRef destination) {
    if (!source || !destination ||
        CVPixelBufferGetWidth(source) != CVPixelBufferGetWidth(destination) ||
        CVPixelBufferGetHeight(source) != CVPixelBufferGetHeight(destination) ||
        CVPixelBufferGetPixelFormatType(source) != CVPixelBufferGetPixelFormatType(destination)) {
        return NO;
    }

    CVReturn sourceLock = CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    if (sourceLock != kCVReturnSuccess) return NO;
    CVReturn destinationLock = CVPixelBufferLockBaseAddress(destination, 0);
    if (destinationLock != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
        return NO;
    }

    BOOL copied = YES;
    size_t planeCount = CVPixelBufferGetPlaneCount(source);
    if (planeCount > 0 && planeCount == CVPixelBufferGetPlaneCount(destination)) {
        for (size_t plane = 0; plane < planeCount; plane++) {
            uint8_t *sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane);
            uint8_t *destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane);
            size_t rows = MIN(CVPixelBufferGetHeightOfPlane(source, plane),
                              CVPixelBufferGetHeightOfPlane(destination, plane));
            size_t sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane);
            size_t destinationStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane);
            size_t bytesPerRow = MIN(sourceStride, destinationStride);
            if (!sourceBase || !destinationBase) { copied = NO; break; }
            for (size_t row = 0; row < rows; row++) {
                memcpy(destinationBase + row * destinationStride,
                       sourceBase + row * sourceStride, bytesPerRow);
            }
        }
    } else if (planeCount == 0 && CVPixelBufferGetPlaneCount(destination) == 0) {
        uint8_t *sourceBase = CVPixelBufferGetBaseAddress(source);
        uint8_t *destinationBase = CVPixelBufferGetBaseAddress(destination);
        size_t rows = MIN(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination));
        size_t sourceStride = CVPixelBufferGetBytesPerRow(source);
        size_t destinationStride = CVPixelBufferGetBytesPerRow(destination);
        size_t bytesPerRow = MIN(sourceStride, destinationStride);
        if (!sourceBase || !destinationBase) {
            copied = NO;
        } else {
            for (size_t row = 0; row < rows; row++) {
                memcpy(destinationBase + row * destinationStride,
                       sourceBase + row * sourceStride, bytesPerRow);
            }
        }
    } else {
        copied = NO;
    }

    CVPixelBufferUnlockBaseAddress(destination, 0);
    CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    return copied;
}

static BOOL convertBGRAIntoYUV(CVPixelBufferRef bgra, CVPixelBufferRef yuv) {
    if (!bgra || !yuv || CVPixelBufferGetPlaneCount(yuv) != 2 ||
        CVPixelBufferGetWidth(bgra) != CVPixelBufferGetWidth(yuv) ||
        CVPixelBufferGetHeight(bgra) != CVPixelBufferGetHeight(yuv)) return NO;
    if (CVPixelBufferLockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NO;
    if (CVPixelBufferLockBaseAddress(yuv, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly);
        return NO;
    }
    size_t width = CVPixelBufferGetWidth(yuv), height = CVPixelBufferGetHeight(yuv);
    const uint8_t *src = CVPixelBufferGetBaseAddress(bgra);
    uint8_t *dstY = CVPixelBufferGetBaseAddressOfPlane(yuv, 0);
    uint8_t *dstUV = CVPixelBufferGetBaseAddressOfPlane(yuv, 1);
    size_t srcStride = CVPixelBufferGetBytesPerRow(bgra);
    size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(yuv, 0);
    size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(yuv, 1);
    BOOL full = CVPixelBufferGetPixelFormatType(yuv) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    BOOL ok = src && dstY && dstUV;
    if (ok) {
        for (size_t y = 0; y < height; y++) {
            const uint8_t *row = src + y * srcStride;
            uint8_t *out = dstY + y * yStride;
            for (size_t x = 0; x < width; x++) {
                double B = row[x * 4], G = row[x * 4 + 1], R = row[x * 4 + 2];
                double value = full ? (0.114 * B + 0.587 * G + 0.299 * R)
                                    : (16.0 + 0.098 * B + 0.504 * G + 0.257 * R);
                out[x] = (uint8_t)MAX(0.0, MIN(255.0, value + 0.5));
            }
        }
        for (size_t y = 0; y < height; y += 2) {
            const uint8_t *row0 = src + y * srcStride;
            const uint8_t *row1 = src + MIN(y + 1, height - 1) * srcStride;
            uint8_t *out = dstUV + (y / 2) * uvStride;
            for (size_t x = 0; x < width; x += 2) {
                double su = 0, sv = 0;
                for (int sample = 0; sample < 4; sample++) {
                    const uint8_t *row = (sample < 2) ? row0 : row1;
                    size_t sx = MIN(x + (sample & 1), width - 1);
                    double B = row[sx * 4], G = row[sx * 4 + 1], R = row[sx * 4 + 2];
                    if (full) {
                        su += -0.169 * R - 0.331 * G + 0.500 * B + 128.0;
                        sv +=  0.500 * R - 0.419 * G - 0.081 * B + 128.0;
                    } else {
                        su += 128.0 - 0.148 * R - 0.291 * G + 0.439 * B;
                        sv += 128.0 + 0.439 * R - 0.368 * G - 0.071 * B;
                    }
                }
                out[(x / 2) * 2] = (uint8_t)MAX(0.0, MIN(255.0, su * 0.25 + 0.5));
                out[(x / 2) * 2 + 1] = (uint8_t)MAX(0.0, MIN(255.0, sv * 0.25 + 0.5));
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(yuv, 0);
    CVPixelBufferUnlockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly);
    return ok;
}

BOOL drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer) {
    if (!targetBuffer) return NO;

    CGFloat targetWidth = CVPixelBufferGetWidth(targetBuffer);
    CGFloat targetHeight = CVPixelBufferGetHeight(targetBuffer);
    if (targetWidth <= 0 || targetHeight <= 0) return NO;

    ensureVCamLock();
    [vcamLock lock];

    BOOL videoFrameChanged = NO;
    if (currentMode == VCamModeVideo && videoFramePaths.count > 0) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (!currentVideoImage || now >= nextVideoFrameTime) {
            NSString *framePath = videoFramePaths[videoFrameIndex];
            CGImageSourceRef source = CGImageSourceCreateWithURL(
                (__bridge CFURLRef)[NSURL fileURLWithPath:framePath], NULL);
            CGImageRef nextImage = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
            if (source) CFRelease(source);
            if (nextImage) {
                if (currentVideoImage) CGImageRelease(currentVideoImage);
                currentVideoImage = nextImage;
                videoFrameIndex = (videoFrameIndex + 1) % videoFramePaths.count;
                videoFrameChanged = YES;
            }
            nextVideoFrameTime = now + (1.0 / 6.0);
        }
    }
    if (videoFrameChanged) [renderedFrameCache removeAllObjects];

    OSType pixelFormat = CVPixelBufferGetPixelFormatType(targetBuffer);
    NSString *cacheKey = [NSString stringWithFormat:@"%zux%zu-%u",
        (size_t)targetWidth, (size_t)targetHeight, (unsigned int)pixelFormat];
    CVPixelBufferRef cachedBuffer = (__bridge CVPixelBufferRef)renderedFrameCache[cacheKey];
    if (cachedBuffer) {
        BOOL copied = copyRenderedBuffer(cachedBuffer, targetBuffer);
        [vcamLock unlock];
        return copied;
    }

    CIImage *replacementCIImage = nil;
    if (liveNV12Buffer) {
        replacementCIImage = [CIImage imageWithCVPixelBuffer:liveNV12Buffer];
    }
    else if (currentMode == VCamModeImage && replacementImage) {
        replacementCIImage = [CIImage imageWithCGImage:replacementImage];
    }
    else if (currentMode == VCamModeVideo && videoFramePaths.count > 0) {
        if (currentVideoImage) replacementCIImage = [CIImage imageWithCGImage:currentVideoImage];
    }

    if (!replacementCIImage || !sharedCIContext) {
        [vcamLock unlock];
        return NO;
    }

    if (fabs(cachedBrightness) > 0.001) {
        replacementCIImage = [replacementCIImage imageByApplyingFilter:@"CIColorControls"
            withInputParameters:@{kCIInputBrightnessKey: @(cachedBrightness)}];
    }

    CGRect extent = replacementCIImage.extent;
    if (extent.size.width <= 0 || extent.size.height <= 0) {
        [vcamLock unlock];
        return NO;
    }

    CGFloat radians = cachedRotation * (CGFloat)M_PI / 180.0;
    if (fabs(radians) > 0.0001 || cachedFlipHorizontal || cachedFlipVertical) {
        CGFloat centerX = CGRectGetMidX(extent);
        CGFloat centerY = CGRectGetMidY(extent);
        CGAffineTransform transform = CGAffineTransformIdentity;
        transform = CGAffineTransformTranslate(transform, centerX, centerY);
        transform = CGAffineTransformRotate(transform, radians);
        transform = CGAffineTransformScale(transform,
            cachedFlipHorizontal ? -1.0 : 1.0,
            cachedFlipVertical ? -1.0 : 1.0);
        transform = CGAffineTransformTranslate(transform, -centerX, -centerY);
        replacementCIImage = [replacementCIImage imageByApplyingTransform:transform];
        extent = replacementCIImage.extent;
    }

    // Normalize EXIF/transformed origins, then aspect-fill the entire camera frame.
    CIImage *normalized = [replacementCIImage imageByApplyingTransform:
        CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
    CGRect normalizedExtent = normalized.extent;
    CGFloat scale = MAX(targetWidth / normalizedExtent.size.width,
                        targetHeight / normalizedExtent.size.height) * cachedZoom;
    CGAffineTransform scaleXform = CGAffineTransformMakeScale(scale, scale);
    CIImage *scaled = [normalized imageByApplyingTransform:scaleXform];
    CGRect scaledExtent = scaled.extent;

    CGFloat offX = (targetWidth  - scaledExtent.size.width)  / 2.0 + cachedOffsetX * targetWidth;
    CGFloat offY = (targetHeight - scaledExtent.size.height) / 2.0 + cachedOffsetY * targetHeight;
    CGAffineTransform translate = CGAffineTransformMakeTranslation(offX, offY);
    CGRect targetRect = CGRectMake(0, 0, targetWidth, targetHeight);
    CIImage *filled = [[scaled imageByApplyingTransform:translate] imageByCroppingToRect:targetRect];
    CIImage *background = [[CIImage imageWithColor:
        [CIColor colorWithRed:0 green:0 blue:0 alpha:1]] imageByCroppingToRect:targetRect];
    CIImage *final = [filled imageByCompositingOverImage:background];

    CVPixelBufferRef renderedBuffer = NULL;
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVReturn createResult = CVPixelBufferCreate(kCFAllocatorDefault,
        (size_t)targetWidth, (size_t)targetHeight, pixelFormat,
        (__bridge CFDictionaryRef)attributes, &renderedBuffer);
    if (createResult != kCVReturnSuccess || !renderedBuffer) {
        [vcamLock unlock];
        return NO;
    }

    BOOL isYUV = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                 pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    BOOL copied = NO;
    // Fast path: Core Image can write directly to many camera buffers.  This
    // avoids a full CPU RGB->YUV pass on every video frame.
    BOOL directRendered = NO;
    @try {
        [sharedCIContext render:final toCVPixelBuffer:renderedBuffer
                         bounds:targetRect colorSpace:sharedColorSpace];
        directRendered = YES;
    } @catch (NSException *exception) {}
    copied = directRendered && copyRenderedBuffer(renderedBuffer, targetBuffer);
    if (!copied && isYUV) {
        // Slow fallback only for devices/formats where direct CI rendering is
        // rejected.  The resulting target buffer is cached for this frame.
        CVPixelBufferRef bgra = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)targetWidth,
                (size_t)targetHeight, kCVPixelFormatType_32BGRA,
                (__bridge CFDictionaryRef)attributes, &bgra) == kCVReturnSuccess && bgra) {
            BOOL rendered = NO;
            @try {
                [sharedCIContext render:final toCVPixelBuffer:bgra bounds:targetRect
                             colorSpace:sharedColorSpace];
                rendered = YES;
            } @catch (NSException *exception) {}
            if (!rendered && softwareCIContext) {
                @try {
                    [softwareCIContext render:final toCVPixelBuffer:bgra bounds:targetRect
                                    colorSpace:sharedColorSpace];
                    rendered = YES;
                } @catch (NSException *exception) {}
            }
            if (rendered) copied = convertBGRAIntoYUV(bgra, targetBuffer);
            if (copied) {
                CVPixelBufferRef cachedTarget = NULL;
                if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)targetWidth,
                        (size_t)targetHeight, pixelFormat,
                        (__bridge CFDictionaryRef)attributes, &cachedTarget) == kCVReturnSuccess &&
                    cachedTarget && convertBGRAIntoYUV(bgra, cachedTarget)) {
                    renderedFrameCache[cacheKey] = (__bridge id)cachedTarget;
                    CVPixelBufferRelease(cachedTarget);
                }
            }
            CVPixelBufferRelease(bgra);
        }
    }
    if (copied && directRendered) renderedFrameCache[cacheKey] = (__bridge id)renderedBuffer;
    CVPixelBufferRelease(renderedBuffer);

    [vcamLock unlock];
    return copied;
}

// Lifelong state construction (safe on first use; we own it for process lifetime).
__attribute__((constructor))
static void vcamInit(void) {
    if (vcamLock == NULL) {
        vcamLock = [[NSLock alloc] init];
    }
}
