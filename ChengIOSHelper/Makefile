ARCHS = arm64 arm64e

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
TARGET := iphone:clang:latest:15.0
else
TARGET := iphone:clang:latest:12.0
endif

TOOL_NAME = chengiosroot

chengiosroot_FILES = main.m ../ChengIOSPrefs/ChengIOSBackup.m ../ChengIOSPrefs/ChengIOSProfiles.m
chengiosroot_FRAMEWORKS = Foundation Security
chengiosroot_LIBRARIES = sqlite3
chengiosroot_CFLAGS = -fobjc-arc -Wno-unguarded-availability-new -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable -I../ChengIOSPrefs
chengiosroot_CODESIGN_FLAGS = -Sentitlements.plist
chengiosroot_INSTALL_PATH = /usr/local/bin

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tool.mk

after-chengiosroot-stage::
	find "$(THEOS_STAGING_DIR)" -name chengiosroot -exec chmod 6755 {} \;
