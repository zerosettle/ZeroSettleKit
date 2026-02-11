#!/bin/bash
set -euo pipefail

# Build ZeroSettleKit.xcframework directly from the Swift package.
# No wrapper Xcode project needed — xcodebuild treats a Package.swift
# directory as an implicit workspace.
#
# SPM archives don't install the .swiftmodule into the framework bundle,
# so we use separate derivedDataPaths per platform and copy the modules
# into the framework before creating the xcframework.

PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PACKAGE_DIR"

SCHEME="ZeroSettleKit"
ARCHIVES="$PACKAGE_DIR/archives"
OUTPUT="$PACKAGE_DIR/ZeroSettleKit.xcframework"
DEPLOYMENT_TARGET="17.0"

echo "==> Cleaning previous artifacts…"
rm -rf "$ARCHIVES" "$OUTPUT"

echo "==> Archiving for iOS device (arm64)…"
xcodebuild archive \
  -scheme "$SCHEME" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVES/iOS.xcarchive" \
  -derivedDataPath "$ARCHIVES/DerivedData-iOS" \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

echo "==> Archiving for iOS Simulator (arm64 + x86_64)…"
xcodebuild archive \
  -scheme "$SCHEME" \
  -destination "generic/platform=iOS Simulator" \
  -archivePath "$ARCHIVES/Sim.xcarchive" \
  -derivedDataPath "$ARCHIVES/DerivedData-Sim" \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

# SPM archives install the binary into the framework but omit the
# Modules/ directory. Copy the swiftmodule from BuildProductsPath
# into each framework before creating the xcframework.
echo "==> Injecting Swift modules into framework bundles…"

IOS_FW="$ARCHIVES/iOS.xcarchive/Products/usr/local/lib/ZeroSettleKit.framework"
SIM_FW="$ARCHIVES/Sim.xcarchive/Products/usr/local/lib/ZeroSettleKit.framework"

IOS_SWIFTMODULE=$(find "$ARCHIVES/DerivedData-iOS" -path "*/BuildProductsPath/Release-iphoneos/ZeroSettleKit.swiftmodule" -type d | head -1)
SIM_SWIFTMODULE=$(find "$ARCHIVES/DerivedData-Sim" -path "*/BuildProductsPath/Release-iphonesimulator/ZeroSettleKit.swiftmodule" -type d | head -1)

# ZeroSettleCore is @_exported by ZeroSettleKit, so its module must also be available
IOS_CORE_SWIFTMODULE=$(find "$ARCHIVES/DerivedData-iOS" -path "*/BuildProductsPath/Release-iphoneos/ZeroSettleCore.swiftmodule" -type d | head -1)
SIM_CORE_SWIFTMODULE=$(find "$ARCHIVES/DerivedData-Sim" -path "*/BuildProductsPath/Release-iphonesimulator/ZeroSettleCore.swiftmodule" -type d | head -1)

if [ -z "$IOS_SWIFTMODULE" ] || [ -z "$SIM_SWIFTMODULE" ]; then
  echo "ERROR: Could not find ZeroSettleKit .swiftmodule directories in DerivedData!"
  exit 1
fi
if [ -z "$IOS_CORE_SWIFTMODULE" ] || [ -z "$SIM_CORE_SWIFTMODULE" ]; then
  echo "ERROR: Could not find ZeroSettleCore .swiftmodule directories in DerivedData!"
  exit 1
fi

# Find the generated ObjC compatibility header
IOS_SWIFT_H=$(find "$ARCHIVES/DerivedData-iOS" -path "*/GeneratedModuleMaps-iphoneos/ZeroSettleKit-Swift.h" | head -1)
SIM_SWIFT_H=$(find "$ARCHIVES/DerivedData-Sim" -path "*/GeneratedModuleMaps-iphonesimulator/ZeroSettleKit-Swift.h" | head -1)

inject_modules() {
  local FW="$1" SWIFTMOD="$2" CORE_SWIFTMOD="$3" SWIFT_H="$4"

  # Modules: swiftmodule + core swiftmodule + modulemap
  mkdir -p "$FW/Modules"
  cp -R "$SWIFTMOD" "$FW/Modules/"
  cp -R "$CORE_SWIFTMOD" "$FW/Modules/"
  cat > "$FW/Modules/module.modulemap" <<'MAP'
framework module ZeroSettleKit {
  header "ZeroSettleKit-Swift.h"
  export *
}
MAP

  # Headers: generated ObjC compatibility header
  mkdir -p "$FW/Headers"
  cp "$SWIFT_H" "$FW/Headers/"
}

inject_modules "$IOS_FW" "$IOS_SWIFTMODULE" "$IOS_CORE_SWIFTMODULE" "$IOS_SWIFT_H"
inject_modules "$SIM_FW" "$SIM_SWIFTMODULE" "$SIM_CORE_SWIFTMODULE" "$SIM_SWIFT_H"

echo "==> Creating XCFramework…"
xcodebuild -create-xcframework \
  -framework "$IOS_FW" \
  -framework "$SIM_FW" \
  -output "$OUTPUT"

# --- Verification ---
echo ""
echo "==> Verifying swiftinterface contains public types…"
SWIFTINTERFACE=$(find "$OUTPUT" -name "*.swiftinterface" | head -1)
if [ -z "$SWIFTINTERFACE" ]; then
  echo "ERROR: No .swiftinterface file found in xcframework!"
  exit 1
fi

if grep -q "struct Price" "$SWIFTINTERFACE"; then
  echo "OK: Found 'struct Price' in swiftinterface."
else
  echo "ERROR: swiftinterface is empty or missing public types!"
  echo "File: $SWIFTINTERFACE"
  echo "--- Contents (first 30 lines) ---"
  head -30 "$SWIFTINTERFACE"
  exit 1
fi

echo ""
echo "==> Build successful: $OUTPUT"
