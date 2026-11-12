export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:16.0
export THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = ReynardDefault16 NativeLinks16
ReynardDefault16_FILES = Tweak.x
ReynardDefault16_CFLAGS = -fobjc-arc
ReynardDefault16_FRAMEWORKS = Foundation UIKit
NativeLinks16_FILES = NativeLinks.x
NativeLinks16_CFLAGS = -fobjc-arc
NativeLinks16_FRAMEWORKS = Foundation UIKit
SUBPROJECTS = ReynardDefaultPrefs ReynardDefaultCC
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
