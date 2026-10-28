include ../../common.mk
include $(THEOS)/makefiles/common.mk

# Два модуля: IRCore живёт в SpringBoard, IRSettings — в Настройках (тянет Preferences.framework).
TWEAK_NAME = IRCore IRSettings

IRCore_FILES = IRCore.m
IRCore_CFLAGS = $(IR_CFLAGS)
IRCore_FRAMEWORKS = UIKit

IRSettings_FILES = IRSettings.m
IRSettings_CFLAGS = $(IR_CFLAGS)
IRSettings_FRAMEWORKS = UIKit CoreGraphics
IRSettings_PRIVATE_FRAMEWORKS = Preferences
IRSettings_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
