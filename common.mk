# Build settings shared by all Skeuo4Ever tweaks. Included from each tweak's Makefile.
# The iPhone 4S is armv7; SDK 10.3 is the last one with 32-bit stubs (9.3 from theos/sdks has no liblaunch.tbd).
TARGET := iphone:clang:10.3:6.0
ARCHS = armv7
# dpkg on iOS 6 does not understand xz or zstd
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip

S4E_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
S4E_CFLAGS = -fobjc-arc -DTHEOS_LEAN_AND_MEAN -I$(S4E_ROOT)/shared
