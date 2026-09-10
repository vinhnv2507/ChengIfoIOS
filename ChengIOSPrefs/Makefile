ARCHS ?= arm64

#ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
#TARGET := iphone:clang:16.2:15.0
#else
TARGET := iphone:clang:13.5:7.0
#endif

BUNDLE_NAME = ChengIOSPrefs

ChengIOSPrefs_FILES = APPRootListController.m
ChengIOSPrefs_FRAMEWORKS = UIKit
ChengIOSPrefs_PRIVATE_FRAMEWORKS = Preferences
ChengIOSPrefs_INSTALL_PATH = /Library/PreferenceBundles
ChengIOSPrefs_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk
