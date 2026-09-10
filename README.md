# ChengIOS

ChengIOS is a standalone iOS jailbreak tweak based on the InfoIOS version-spoofing code. It is intentionally separate from VCam and uses its own package and preferences identifiers.

It automatically spoofs your iOS version to recent versions based on the date. It can also spoof app versions.
 A jailbroken device is required or it may be possible to bundle within an app with default values set.

 - It is made in a way to spoof as many method/function call return values as possible, in short this means that more of the ways the version can be checked are spoofed (forged). This includes many methods from UIDevice, NSURLSession, and your User Agent.
 - It may not cover every single method call but the majority are spoofed.
 - App Version is NOT currently spoofed in NSBundle and App Version is only spoofed in the User Agent (if it exists and is not a custom key name)
 - Other methods are also spoofed to be more generic such as your device's hostname is "iphone.local" and not your custom device name and more.
 - This tweak does not spoof your device type or screen size or anything else similar as that wasn't within the scope of this tweak.
 - This tweak is mostly useful for bypassing iOS and app version requirements so you can continue to operate them easily on your older device.

 Notes:
 - The compiled deb 1.0.0 release spoofs app version to "11.79.1", you will need to compile it for yourself for the updated code which sets this hardcoded version number higher to be more versatile.
 - For compiling you will need the dependency `AltList` for the preferences.

## Package

- Package ID: `com.vinhnv2507.chengios`
- Preferences ID: `com.vinhnv2507.chengiosprefs`
- Supported jailbreak layouts: rootful and rootless (arm64/arm64e)

The GitHub Actions workflow builds both packages and publishes an APT repository on the `gh-pages` branch. Add this URL to Sileo:

`https://raw.githubusercontent.com/vinhnv2507/ChengIfoIOS/gh-pages/`

## 1.1.0 improvements

 - Preference data is cached once per process, avoiding repeated plist parsing on every request and UIKit/WebKit query.
 - App version rewriting now accepts `appver`, `app-version`, and `app_version` parameters (case-insensitive).
 - Missing or malformed preference values fail closed, so unconfigured applications are never spoofed accidentally.

## Planned device-signal modules

The next development phase is split into opt-in modules so each signal can be
tested independently and disabled per application:

 - Location: `CLLocationManager` authorization/status and delivered locations
   (fixed coordinate, GPX route, or per-app profile). This requires careful
   handling of simulated-location metadata and background updates.
 - Network identity: interface address queries (`getifaddrs`/`sysctl`) and
   advertising/vendor identifiers where the OS permits interception. Modern
   iOS does not expose a supported Wi-Fi MAC API; a MAC hook cannot guarantee
   coverage and must not be treated as a security boundary.
 - Additional low-risk signals: device name, hostname, OS/build, locale,
   timezone, carrier strings, identifier-for-vendor, and advertising ID.

Location and network identity spoofing are not enabled by default. They should
be implemented behind explicit per-app preferences and validated on a test
device, because private APIs and daemon-level hooks vary across iOS releases.

<img width="322" height="345" alt="image" src="https://github.com/user-attachments/assets/f7cce2b7-6f8e-4473-9ca6-07acace3bd5e" />
