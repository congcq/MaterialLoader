#!/bin/bash
# check-build.sh — smoke tests for the built libhynisloader.dylib.
#
# Verifies architecture, install name, framework dependencies, absence of
# CydiaSubstrate, presence of the fopen-rebind machinery, presence of the
# linked-in HyniSign submodule, and that HL_VERSION from `control` is
# actually baked into the binary (proves Makefile->Tweak.x propagation).
#
# Run after `make` from the project root:
#
#   bash tests/check-build.sh

set -e

DYLIB="${1:-build/libhynisloader.dylib}"

if [ ! -f "$DYLIB" ]; then
    echo "ERROR: $DYLIB not found. Run 'make' from the project root first." >&2
    exit 1
fi

failed=0
check() {
    local name="$1"
    local cond="$2"
    if [ "$cond" = "ok" ]; then
        printf "  ok    %s\n" "$name"
    else
        printf "  FAIL  %s — %s\n" "$name" "$cond"
        failed=$((failed + 1))
    fi
}

echo "Checking $DYLIB..."

# Architecture: arm64 only (target is iOS).
archs=$(lipo -archs "$DYLIB" 2>/dev/null || echo "?")
if [ "$archs" = "arm64" ]; then
    check "arm64-only architecture" ok
else
    check "arm64-only architecture" "got '$archs'"
fi

# Install name. Sideloadly re-signs at @executable_path scope.
iname=$(otool -D "$DYLIB" | tail -n +2 | tr -d '[:space:]')
expected_iname="@executable_path/libhynisloader.dylib"
if [ "$iname" = "$expected_iname" ]; then
    check "install_name=$expected_iname" ok
else
    check "install_name=$expected_iname" "got '$iname'"
fi

# Required framework dependencies.
#   Foundation/CoreFoundation/UIKit — banner + general runtime
#   QuartzCore                      — CALayer/CAShapeLayer/CATextLayer pill
#   CoreGraphics                    — CGRect/CGColor for the pill
#   Security                        — pulled in via the HyniSign submodule
linkage=$(otool -L "$DYLIB")
for fw in Foundation CoreFoundation UIKit QuartzCore CoreGraphics Security; do
    if echo "$linkage" | grep -q "/${fw}.framework/${fw}"; then
        check "links ${fw}.framework" ok
    else
        check "links ${fw}.framework" "missing"
    fi
done

# libz is required for the resource-pack zip extraction path (ZipHandler.m).
if echo "$linkage" | grep -q "libz\."; then
    check "links libz" ok
else
    check "links libz" "missing"
fi

# Must NOT depend on CydiaSubstrate. The dylib uses %ctor only, never
# %hook, since CydiaSubstrate.framework is absent on stock iOS and would
# fail dylib load on a sideloaded device.
if echo "$linkage" | grep -q "CydiaSubstrate"; then
    check "no CydiaSubstrate dependency" "found CydiaSubstrate in load commands"
else
    check "no CydiaSubstrate dependency" ok
fi

# Symbols defined by Tweak.x and the bundled helpers.
syms=$(nm "$DYLIB" 2>/dev/null || true)
for sym in hook_fopen extractFileFromZip readFileFromZip isArchivePack; do
    if echo "$syms" | grep -q " _${sym}\$"; then
        check "defines ${sym}" ok
    else
        check "defines ${sym}" "symbol not found"
    fi
done

# HyniSign submodule is linked in (Makefile compiles HyniSign/Tweak.x +
# HyniSign/access_group.c). HyniSignCopyStripped is the helper export.
if echo "$syms" | grep -q "HyniSignCopyStripped"; then
    check "HyniSign submodule linked (HyniSignCopyStripped present)" ok
else
    check "HyniSign submodule linked (HyniSignCopyStripped present)" "symbol not found"
fi

# fishhook rebind target name appears as a constant string. If this
# disappears, the renderer redirect is silently a no-op.
strings_out=$(strings "$DYLIB")
if echo "$strings_out" | grep -qx "fopen"; then
    check "embeds fopen rebind name" ok
else
    check "embeds fopen rebind name" "string not found"
fi

# dlsym target for the HyniSwizzleFPS interop. Optional at runtime, but
# the string must survive into the binary or the FPS suffix never lights up.
if echo "$strings_out" | grep -qx "HSFPS_EffectiveCap"; then
    check "embeds HSFPS_EffectiveCap dlsym name" ok
else
    check "embeds HSFPS_EffectiveCap dlsym name" "string not found"
fi

# HL_VERSION from `control` is propagated into the binary by the Makefile
# (-D flags). Catches drift where the on-screen banner and the package
# metadata disagree.
ctrl_version=$(awk -F': *' '/^Version:/ {sub(/\r$/,"",$2); print $2}' control 2>/dev/null || true)
if [ -n "$ctrl_version" ] && echo "$strings_out" | grep -qF "v${ctrl_version}"; then
    check "binary embeds version v${ctrl_version} from control" ok
else
    check "binary embeds version from control" "control says '${ctrl_version}', not found in dylib strings"
fi

echo
if [ "$failed" -eq 0 ]; then
    echo "All build smoke tests passed."
    exit 0
else
    echo "$failed check(s) failed." >&2
    exit 1
fi
