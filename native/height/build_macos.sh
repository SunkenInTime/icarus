#!/bin/sh
set -eu

source_dir="$SRCROOT/../native/height"
output_dir="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$output_dir"
set --
for architecture in $ARCHS; do
  set -- "$@" -arch "$architecture"
done
xcrun clang++ -std=c++17 -O2 -fno-fast-math -ffp-contract=off \
  -fvisibility=hidden -fvisibility-inlines-hidden -dynamiclib -pthread \
  -isysroot "$SDKROOT" "-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
  "$@" "$source_dir/icarus_svg_height.cpp" \
  -install_name @rpath/libicarus_height.dylib \
  -o "$output_dir/libicarus_height.dylib"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
    --timestamp=none "$output_dir/libicarus_height.dylib"
fi
