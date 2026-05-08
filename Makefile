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

# Pull Name/Version/Author from `control` so the on-screen banner stays in sync
# with package metadata. awk strips the "Field: " prefix; trailing CR (if any)
# is removed for safety on cross-platform checkouts.
HL_NAME    := $(shell awk -F': *' '/^Name:/    {sub(/\r$$/,"",$$2); print $$2}' control)
HL_VERSION := $(shell awk -F': *' '/^Version:/ {sub(/\r$$/,"",$$2); print $$2}' control)
HL_AUTHOR  := $(shell awk -F': *' '/^Author:/  {sub(/\r$$/,"",$$2); print $$2}' control)

libhynisloader_FILES      = Tweak.x fishhook.c ZipHandler.m HyniSign/Tweak.x HyniSign/access_group.c
libhynisloader_FRAMEWORKS = Foundation UIKit
libhynisloader_CFLAGS     = -fobjc-arc \
    -DHL_NAME='"$(HL_NAME)"' \
    -DHL_VERSION='"$(HL_VERSION)"' \
    -DHL_AUTHOR='"$(HL_AUTHOR)"'

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
