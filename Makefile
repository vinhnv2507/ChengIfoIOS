ARCHS = arm64 arm64e

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
TARGET := iphone:clang:latest:15.0
else
TARGET := iphone:clang:latest:12.0
endif

TWEAK_NAME = ChengIOS
$(TWEAK_NAME)_FILES = Prefs.m Tweak.x HooksDevice.x HooksLocation.x HooksNetwork.x HooksGestalt.x
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation CoreLocation CoreTelephony SystemConfiguration
$(TWEAK_NAME)_WEAK_FRAMEWORKS = NetworkExtension
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-unused-function -Wno-unguarded-availability-new

SUBPROJECTS += ChengIOSPrefs
SUBPROJECTS += ChengIOSApp
SUBPROJECTS += ChengIOSHelper
SUBPROJECTS += ChengIOSKC

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
