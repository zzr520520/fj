# 编译配置
ARCHS = arm64 arm64e
SDK = iphoneos
MIN_VERSION = 14.0

CC = xcrun -sdk $(SDK) clang
CFLAGS = -arch $(ARCHS) -dynamiclib -mios-version-min=$(MIN_VERSION) -fobjc-arc \
         -framework Foundation -framework UIKit -framework CFNetwork

TARGET = AirChatPlus.dylib

all: $(TARGET)

$(TARGET): AirChatPlus.m
	$(CC) $(CFLAGS) -o $@ $^

clean:
	rm -f $(TARGET)
