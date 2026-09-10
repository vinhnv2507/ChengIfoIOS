ARCHS ?= arm64

TARGET := iphone:clang:latest:7.0

BUNDLE_NAME = ChengIOSPrefs

ChengIOSPrefs_FILES = APPRootListController.m
ChengIOSPrefs_FRAMEWORKS = UIKit
ChengIOSPrefs_PRIVATE_FRAMEWORKS = Preferences
ChengIOSPrefs_INSTALL_PATH = /Library/PreferenceBundles
ChengIOSPrefs_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk
