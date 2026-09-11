#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

void OVSReloadPreferences(void);
void OVSRegisterPreferenceListener(void);

NSDictionary *OVSPreferences(void);
id OVSObjectForKey(NSString *key);
BOOL OVSBoolForKey(NSString *key, BOOL defaultValue);
NSString *OVSStringForKey(NSString *key, NSString *defaultValue);
NSString *OVSStringForKeys(NSArray<NSString *> *keys, NSString *defaultValue);
double OVSDoubleForKey(NSString *key, double defaultValue);

NSString *OVSMainBundleIdentifier(void);
NSString *OVSMainBundlePath(void);

BOOL OVSIsProtectedProcess(void);
BOOL OVSMasterEnabled(void);
BOOL OVSAppSelected(void);
BOOL OVSSpoofingEnabled(void);

BOOL OVSUseCustomOSVersion(void);
NSOperatingSystemVersion OVSPredictedOSVersion(void);
NSOperatingSystemVersion OVSSpoofedOSVersion(void);
NSString *OVSSpoofedOSVersionString(void);
NSString *OVSSpoofedOSVersionUnderscore(void);
NSString *OVSSpoofedBuildNumber(void);

BOOL OVSAppVersionEnabled(void);
NSString *OVSSpoofedAppVersion(void);

BOOL OVSDeviceIdentityEnabled(void);
BOOL OVSShouldSpoofDeviceName(void);
BOOL OVSShouldSpoofHostName(void);
BOOL OVSShouldSpoofModel(void);
NSString *OVSSpoofedDeviceName(void);
NSString *OVSSpoofedHostName(void);
NSString *OVSSpoofedModel(void);
NSUUID *OVSSpoofedVendorUUID(void);
NSUUID *OVSSpoofedAdvertisingUUID(void);

BOOL OVSLocaleEnabled(void);
NSString *OVSSpoofedLocaleIdentifier(void);
NSString *OVSSpoofedLanguageCode(void);
NSString *OVSSpoofedTimeZoneName(void);

BOOL OVSCarrierEnabled(void);
NSString *OVSSpoofedCarrierName(void);
NSString *OVSSpoofedMCC(void);
NSString *OVSSpoofedMNC(void);
NSString *OVSSpoofedISOCountryCode(void);

BOOL OVSLocationEnabled(void);
void OVSBeginLocationHookBypass(void);
void OVSEndLocationHookBypass(void);
BOOL OVSLocationHookBypassed(void);
CLLocation *OVSSpoofedLocation(void);

BOOL OVSNetworkEnabled(void);
NSString *OVSSpoofedIPv4(void);
NSString *OVSSpoofedIPv6(void);
NSString *OVSSpoofedMACAddress(void);
NSString *OVSSpoofedInterfaceName(void);
NSString *OVSSpoofedWifiSSID(void);
NSString *OVSSpoofedWifiBSSID(void);
NSString *OVSSpoofedWifiGateway(void);
NSString *OVSSpoofedWifiRSSI(void);
NSDictionary *OVSSpoofedCaptiveNetworkInfo(void);
double OVSSpoofedWifiSignalStrength(void);

NSString *OVSRewriteUserAgent(NSString *userAgent, BOOL rewriteAppVersion);
