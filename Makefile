export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:16.0
export THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = ReynardDefault16 WhatsAppEbayLinks16
ReynardDefault16_FILES = Tweak.x
ReynardDefault16_CFLAGS = -fobjc-arc
ReynardDefault16_FRAMEWORKS = Foundation UIKit
WhatsAppEbayLinks16_FILES = WhatsAppEbayLinks.x
WhatsAppEbayLinks16_CFLAGS = -fobjc-arc
WhatsAppEbayLinks16_FRAMEWORKS = Foundation UIKit
SUBPROJECTS = ReynardDefaultPrefs ReynardDefaultCC
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
