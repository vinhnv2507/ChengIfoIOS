ARCHS = arm64 arm64e

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
TARGET := iphone:clang:latest:15.0
else
TARGET := iphone:clang:latest:12.0
endif

TOOL_NAME = chengioskc

chengioskc_FILES = main.m
chengioskc_FRAMEWORKS = Foundation Security
chengioskc_CFLAGS = -fobjc-arc -Wno-unguarded-availability-new -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable
chengioskc_CODESIGN_FLAGS = -Sentitlements.plist
chengioskc_INSTALL_PATH = /usr/local/bin

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tool.mk

after-chengioskc-stage::
	find "$(THEOS_STAGING_DIR)" -name chengioskc -exec chmod 6755 {} \;
