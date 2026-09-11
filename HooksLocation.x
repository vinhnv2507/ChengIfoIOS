#import "Prefs.h"

#ifndef kCLAuthorizationStatusAuthorizedAlways
#define kCLAuthorizationStatusAuthorizedAlways 3
#endif

static NSHashTable *OVSActiveManagers(void) {
    static NSHashTable *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static void OVSDeliverFakeLocation(CLLocationManager *manager) {
    if (!OVSLocationEnabled() || !manager) {
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            OVSDeliverFakeLocation(manager);
        });
        return;
    }
    CLLocation *location = OVSSpoofedLocation();
    if (!location) {
        return;
    }
    id delegate = manager.delegate;
    if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [delegate locationManager:manager didUpdateLocations:@[location]];
    }
    if ([delegate respondsToSelector:@selector(locationManager:didUpdateToLocation:fromLocation:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [delegate locationManager:manager didUpdateToLocation:location fromLocation:location];
#pragma clang diagnostic pop
    }
}

static void OVSDeliverAuthorization(CLLocationManager *manager) {
    if (!OVSLocationEnabled() || !manager) {
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            OVSDeliverAuthorization(manager);
        });
        return;
    }
    id delegate = manager.delegate;
    if (@available(iOS 14.0, *)) {
        if ([delegate respondsToSelector:@selector(locationManagerDidChangeAuthorization:)]) {
            [delegate locationManagerDidChangeAuthorization:manager];
        }
    }
    if ([delegate respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [delegate locationManager:manager didChangeAuthorizationStatus:kCLAuthorizationStatusAuthorizedAlways];
#pragma clang diagnostic pop
    }
}

@interface OVSLocationTicker : NSObject
@end

@implementation OVSLocationTicker
- (void)tick {
    if (!OVSLocationEnabled()) {
        return;
    }
    NSArray *managers = nil;
    NSHashTable *table = OVSActiveManagers();
    @synchronized (table) {
        managers = [table allObjects];
    }
    for (CLLocationManager *manager in managers) {
        OVSDeliverFakeLocation(manager);
    }
}
@end

static void OVSEnsureTicker(void) {
    static dispatch_once_t onceToken;
    static OVSLocationTicker *ticker;
    dispatch_once(&onceToken, ^{
        ticker = [OVSLocationTicker new];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                              target:ticker
                                                            selector:@selector(tick)
                                                            userInfo:nil
                                                             repeats:YES];
            [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        });
    });
}

static void OVSTrackManager(CLLocationManager *manager) {
    if (!manager) {
        return;
    }
    NSHashTable *table = OVSActiveManagers();
    @synchronized (table) {
        [table addObject:manager];
    }
    OVSEnsureTicker();
    OVSDeliverFakeLocation(manager);
}

static void OVSUntrackManager(CLLocationManager *manager) {
    if (!manager) {
        return;
    }
    NSHashTable *table = OVSActiveManagers();
    @synchronized (table) {
        [table removeObject:manager];
    }
}

%group LocationHooks
%hook CLLocation
- (CLLocationCoordinate2D)coordinate {
    if (OVSLocationHookBypassed() || !OVSLocationEnabled()) {
        return %orig;
    }
    CLLocation *fake = OVSSpoofedLocation();
    if (!fake) {
        return %orig;
    }
    OVSBeginLocationHookBypass();
    CLLocationCoordinate2D coordinate = fake.coordinate;
    OVSEndLocationHookBypass();
    return coordinate;
}

- (CLLocationDistance)altitude {
    if (OVSLocationHookBypassed() || !OVSLocationEnabled()) {
        return %orig;
    }
    CLLocation *fake = OVSSpoofedLocation();
    if (!fake) {
        return %orig;
    }
    OVSBeginLocationHookBypass();
    CLLocationDistance value = fake.altitude;
    OVSEndLocationHookBypass();
    return value;
}

- (CLLocationAccuracy)horizontalAccuracy {
    if (OVSLocationHookBypassed() || !OVSLocationEnabled()) {
        return %orig;
    }
    CLLocation *fake = OVSSpoofedLocation();
    if (!fake) {
        return %orig;
    }
    OVSBeginLocationHookBypass();
    CLLocationAccuracy value = fake.horizontalAccuracy;
    OVSEndLocationHookBypass();
    return value;
}

- (CLLocationAccuracy)verticalAccuracy {
    if (OVSLocationHookBypassed() || !OVSLocationEnabled()) {
        return %orig;
    }
    CLLocation *fake = OVSSpoofedLocation();
    if (!fake) {
        return %orig;
    }
    OVSBeginLocationHookBypass();
    CLLocationAccuracy value = fake.verticalAccuracy;
    OVSEndLocationHookBypass();
    return value;
}

- (NSDate *)timestamp {
    if (OVSLocationHookBypassed() || !OVSLocationEnabled()) {
        return %orig;
    }
    CLLocation *fake = OVSSpoofedLocation();
    if (!fake) {
        return %orig;
    }
    OVSBeginLocationHookBypass();
    NSDate *value = fake.timestamp;
    OVSEndLocationHookBypass();
    return value;
}

- (CLLocationSpeed)speed {
    if (OVSLocationHookBypassed() || !OVSLocationEnabled()) {
        return %orig;
    }
    return -1.0;
}

- (CLLocationDirection)course {
    if (OVSLocationHookBypassed() || !OVSLocationEnabled()) {
        return %orig;
    }
    return -1.0;
}
%end

%hook CLLocationManager
+ (BOOL)locationServicesEnabled {
    return OVSLocationEnabled() ? YES : %orig;
}

+ (NSInteger)authorizationStatus {
    return OVSLocationEnabled() ? kCLAuthorizationStatusAuthorizedAlways : %orig;
}

- (NSInteger)authorizationStatus {
    return OVSLocationEnabled() ? kCLAuthorizationStatusAuthorizedAlways : %orig;
}

- (NSInteger)accuracyAuthorization {
    return OVSLocationEnabled() ? 0 : %orig;
}

- (CLLocation *)location {
    if (OVSLocationEnabled()) {
        CLLocation *fake = OVSSpoofedLocation();
        if (fake) {
            return fake;
        }
    }
    return %orig;
}

- (void)requestWhenInUseAuthorization {
    if (OVSLocationEnabled()) {
        OVSDeliverAuthorization(self);
        return;
    }
    %orig;
}

- (void)requestAlwaysAuthorization {
    if (OVSLocationEnabled()) {
        OVSDeliverAuthorization(self);
        return;
    }
    %orig;
}

- (void)startUpdatingLocation {
    if (OVSLocationEnabled()) {
        OVSTrackManager(self);
        return;
    }
    %orig;
}

- (void)requestLocation {
    if (OVSLocationEnabled()) {
        OVSDeliverFakeLocation(self);
        return;
    }
    %orig;
}

- (void)startMonitoringSignificantLocationChanges {
    if (OVSLocationEnabled()) {
        OVSTrackManager(self);
        return;
    }
    %orig;
}

- (void)stopUpdatingLocation {
    if (OVSLocationEnabled()) {
        OVSUntrackManager(self);
        return;
    }
    %orig;
}

- (void)stopMonitoringSignificantLocationChanges {
    if (OVSLocationEnabled()) {
        OVSUntrackManager(self);
        return;
    }
    %orig;
}

- (void)requestTemporaryFullAccuracyAuthorizationWithPurposeKey:(NSString *)purposeKey {
    if (OVSLocationEnabled()) {
        OVSDeliverAuthorization(self);
        return;
    }
    %orig;
}
%end
%end

%ctor {
    if (OVSIsProtectedProcess()) {
        return;
    }
    if (NSClassFromString(@"CLLocationManager")) {
        %init(LocationHooks);
    }
}
