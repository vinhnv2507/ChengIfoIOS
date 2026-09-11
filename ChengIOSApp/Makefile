ARCHS = arm64 arm64e

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
TARGET := iphone:clang:latest:15.0
else
TARGET := iphone:clang:latest:12.0
endif

APPLICATION_NAME = ChengIOSApp

ChengIOSApp_FILES = main.m AppDelegate.m RootViewController.m AppListViewController.m ../ChengIOSPrefs/ChengIOSProfiles.m
ChengIOSApp_FRAMEWORKS = UIKit Foundation
ChengIOSApp_CFLAGS = -fobjc-arc -Wno-unguarded-availability-new -Wno-deprecated-declarations
ChengIOSApp_CODESIGN_FLAGS = -Sentitlements.plist
ChengIOSApp_INSTALL_PATH = /Applications

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "uicache -p /Applications/ChengIOSApp.app >/dev/null 2>&1 || uicache -p /var/jb/Applications/ChengIOSApp.app >/dev/null 2>&1 || true"
