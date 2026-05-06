TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = libHynisPatcher

libHynisPatcher_FILES = Tweak.x fishhook.c ZipHandler.m
libHynisPatcher_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
