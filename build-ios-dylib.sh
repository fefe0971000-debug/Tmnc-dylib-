#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"
LOG_FILE="${BUILD_LOG_FILE:-BUILD_LOG.txt}"
exec > >(tee "$LOG_FILE") 2>&1

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ')"
OUTPUT="${DYLIB_OUTPUT:-UniversalUIInspector.dylib}"

rm -f "$OUTPUT"
echo "UniversalUIInspector arm64 iOS build"
echo "sdk=$SDK"
echo "sdk_version=$SDK_VERSION"
echo "xcode=$XCODE_VERSION"
echo "output=$OUTPUT"

xcrun --sdk iphoneos clang \
  -dynamiclib \
  -fobjc-arc \
  -fblocks \
  -fmodules \
  -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min=13.0 \
  -Wno-deprecated-declarations \
  -Wno-unused-function \
  -Wno-unused-variable \
  -framework UIKit \
  -framework QuartzCore \
  -lz \
  -install_name @rpath/UniversalUIInspector.dylib \
  UniversalUIInspector/UniversalUIInspector.m \
  UniversalUIInspector/LegacyCollectors.m \
  -o "$OUTPUT"

file "$OUTPUT"
xcrun lipo "$OUTPUT" -verify_arch arm64
xcrun otool -hv "$OUTPUT" | tee MACHO_HEADER.txt
xcrun otool -L "$OUTPUT" | tee LINKED_FRAMEWORKS.txt
shasum -a 256 "$OUTPUT" | tee SHA256.txt
SIZE="$(stat -f%z "$OUTPUT")"
cat > BUILD_INFO.txt <<EOF
branch: universal-inspector-build
commit: $(git rev-parse HEAD)
runner: macos-14
xcode: $XCODE_VERSION
iOS SDK: $SDK_VERSION
architecture: arm64
platform: iOS device
deployment target: iOS 13.0
dylib size: $SIZE bytes
install name: @rpath/UniversalUIInspector.dylib
linked frameworks: UIKit, QuartzCore; library: libz
build script: build-ios-dylib.sh
EOF

echo "Build succeeded: $OUTPUT"
