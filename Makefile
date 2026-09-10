//THEOS_DEVICE_IP = 127.0.0.1

# arm64 keeps the package compatible with older devices (including iPhone 7 Plus).
# Override with ARCHS=arm64e when building specifically for a newer device.
ARCHS ?= arm64

FINALPACKAGE = 1

TARGET := iphone:clang:latest:7.0
INSTALL_TARGET_PROCESSES = SpringBoard

TWEAK_NAME = ChengIOS
$(TWEAK_NAME)_FILES = Tweak.x
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation
$(TWEAK_NAME)_CFLAGS = -fobjc-arc

SUBPROJECTS += ChengIOSPrefs

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
