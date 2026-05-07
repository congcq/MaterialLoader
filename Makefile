# HynisLoader Makefile
#
# Builds a sideload-ready dylib at build/libhynisloader.dylib. Drag this into
# Sideloadly's "Inject dylibs" list when re-signing the Minecraft IPA, or
# install via TrollFools / .deb on a jailbroken device.
#
# Targets:
#   make            Build sideload-ready dylib at build/libhynisloader.dylib
#   make clean      Remove build artifacts (build/ and .theos/obj)
#
# Requires Theos: https://theos.dev/  (set $THEOS in your shell rc)

TARGET := iphone:clang:latest:14.0
ARCHS  := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = libhynisloader

libhynisloader_FILES      = Tweak.x fishhook.c ZipHandler.m
libhynisloader_FRAMEWORKS = Foundation UIKit
libhynisloader_CFLAGS     = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

# Post-build: produce a sideload-ready copy with @executable_path install name
# and an ad-hoc signature. Sideloadly will re-sign with the user's cert when
# injecting into the IPA.
all::
	@mkdir -p build
	@cp .theos/obj/debug/libhynisloader.dylib build/libhynisloader.dylib
	@install_name_tool -id "@executable_path/libhynisloader.dylib" build/libhynisloader.dylib 2>/dev/null
	@codesign --remove-signature build/libhynisloader.dylib 2>/dev/null || true
	@codesign -s - build/libhynisloader.dylib 2>/dev/null
	@echo "==> Sideload-ready dylib: build/libhynisloader.dylib"

clean::
	@rm -rf build
