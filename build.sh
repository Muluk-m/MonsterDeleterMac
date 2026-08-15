#!/usr/bin/env bash
# Builds MonsterDeleter.app into ./build.
#   ./build.sh              universal (arm64 + x86_64)
#   UNIVERSAL=0 ./build.sh  native only, much faster for iteration
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MonsterDeleter"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
CONFIG="release"
UNIVERSAL="${UNIVERSAL:-1}"

if [ "$UNIVERSAL" = "1" ]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
else
  ARCH_FLAGS=()
fi

echo "==> swift build (${CONFIG}${UNIVERSAL:+, universal=$UNIVERSAL})"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_PATH="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/$APP_NAME"

mkdir -p "$BUILD_DIR"

ICON_SRC="Resources/icon/monster-logo.png"
ICNS="$BUILD_DIR/AppIcon.icns"
if [ ! -f "$ICNS" ] && [ -f "$ICON_SRC" ]; then
  echo "==> generating AppIcon.icns"
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$ICON_SRC" \
      --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICNS"
  rm -rf "$ICONSET"
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/assets "$APP/Contents/Resources/assets"
[ -f "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough for the app to run locally and for Finder to load
# the Services entry. A Developer ID signature is only needed to skip the
# Gatekeeper prompt on someone else's Mac.
echo "==> ad-hoc codesign"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "==> done: $APP"
lipo -archs "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
