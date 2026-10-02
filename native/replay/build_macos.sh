#!/bin/sh
# Xcode build phase: builds libicarus_replay.dylib for every arch in $ARCHS
# (lipo'd into one universal dylib) into the app's Frameworks folder.
# Needs rustup with the aarch64-apple-darwin and x86_64-apple-darwin targets.
set -eu

source_dir="$SRCROOT/../native/replay"
output_dir="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
target_dir="$TARGET_TEMP_DIR/icarus_replay_cargo"
cargo="${CARGO:-$HOME/.cargo/bin/cargo}"
if [ ! -x "$cargo" ]; then
  cargo="$(command -v cargo)"
fi
mkdir -p "$output_dir"

# Rust reads MACOSX_DEPLOYMENT_TARGET from the environment Xcode sets; the
# install name is set at link time so nothing edits (and unsigns) the dylib.
export RUSTFLAGS="-C link-arg=-Wl,-install_name,@rpath/libicarus_replay.dylib"

set --
for architecture in $ARCHS; do
  case "$architecture" in
    arm64) triple=aarch64-apple-darwin ;;
    x86_64) triple=x86_64-apple-darwin ;;
    *) echo "error: no Rust target for $architecture" >&2; exit 1 ;;
  esac
  "$cargo" build --release --locked --lib \
    --manifest-path "$source_dir/Cargo.toml" \
    --target "$triple" --target-dir "$target_dir"
  set -- "$@" "$target_dir/$triple/release/libicarus_replay.dylib"
done
xcrun lipo -create "$@" -output "$output_dir/libicarus_replay.dylib"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
    --timestamp=none "$output_dir/libicarus_replay.dylib"
fi
