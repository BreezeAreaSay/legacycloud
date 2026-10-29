include ../../common.mk
include $(THEOS)/makefiles/common.mk

# Два модуля: S4ECore живёт в SpringBoard, S4ESettings — в Настройках (тянет Preferences.framework).
TWEAK_NAME = S4ECore S4ESettings

S4ECore_FILES = S4ECore.m
S4ECore_CFLAGS = $(S4E_CFLAGS)
S4ECore_FRAMEWORKS = UIKit

S4ESettings_FILES = S4ESettings.m
S4ESettings_CFLAGS = $(S4E_CFLAGS)
S4ESettings_FRAMEWORKS = UIKit CoreGraphics
S4ESettings_PRIVATE_FRAMEWORKS = Preferences
S4ESettings_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
