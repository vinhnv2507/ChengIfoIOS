ARCHS = arm64 arm64e

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
TARGET := iphone:clang:latest:15.0
else
TARGET := iphone:clang:latest:12.0
endif

BUNDLE_NAME = ChengIOSPrefs

ChengIOSPrefs_FILES = APPRootListController.m ChengIOSChangeInfoController.m ChengIOSAppListController.m ChengIOSCurrentInfoController.m SRSwitchTableCell.m ChengIOSProfiles.m
ChengIOSPrefs_FRAMEWORKS = UIKit
ChengIOSPrefs_PRIVATE_FRAMEWORKS = Preferences
ChengIOSPrefs_INSTALL_PATH = /Library/PreferenceBundles
ChengIOSPrefs_CFLAGS = -fobjc-arc -Wno-unguarded-availability-new -Wno-deprecated-declarations

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk
