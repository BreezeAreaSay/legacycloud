# Общие параметры сборки всех твиков iOS6Revive. Подключается из Makefile каждого твика.
# iPhone 4S — armv7; SDK 10.3 — последний с 32-битными заглушками (в 9.3 из theos/sdks нет liblaunch.tbd).
TARGET := iphone:clang:10.3:6.0
ARCHS = armv7
# dpkg на iOS 6 не понимает xz и zstd
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip

IR_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
IR_CFLAGS = -fobjc-arc -DTHEOS_LEAN_AND_MEAN -I$(IR_ROOT)/shared
