ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XCNoAdJump
XCNoAdJump_FILES = Tweak.xm
XCNoAdJump_CFLAGS = -fobjc-arc
XCNoAdJump_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
