ARCHS = arm64 arm64e

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
TARGET := iphone:clang:latest:15.0
else
TARGET := iphone:clang:latest:7.0
endif

INSTALL_TARGET_PROCESSES = SpringBoard

TWEAK_NAME = ChengIOS
$(TWEAK_NAME)_FILES = Prefs.m Tweak.x HooksDevice.x HooksLocation.x HooksNetwork.x
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation CoreLocation CoreTelephony
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-unused-function

SUBPROJECTS += ChengIOSPrefs

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
