TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = libhynisloader

libhynisloader_FILES = Tweak.x fishhook.c ZipHandler.m
libhynisloader_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
