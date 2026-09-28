TARGET := iphone:clang:latest:14.0
ARCHS  := arm64 arm64e

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = SatanabeCleanUI
SatanabeCleanUI_FILES      = SatanabeCleanUI.mm
SatanabeCleanUI_FRAMEWORKS = UIKit Foundation AVFoundation QuartzCore CoreGraphics UniformTypeIdentifiers
SatanabeCleanUI_CFLAGS     = -fobjc-arc -fmodules -O2

include $(THEOS_MAKE_PATH)/library.mk
