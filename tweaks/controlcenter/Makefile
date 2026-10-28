include ../../common.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IRControlCenter
IRControlCenter_FILES = IRControlCenter.m IRCCDrawing.m
IRControlCenter_CFLAGS = $(IR_CFLAGS)
IRControlCenter_FRAMEWORKS = UIKit QuartzCore CoreGraphics MediaPlayer AVFoundation
IRControlCenter_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
