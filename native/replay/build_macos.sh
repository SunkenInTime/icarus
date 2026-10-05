#!/bin/sh
# Xcode build phase: builds libicarus_replay.dylib for every arch in $ARCHS
# (lipo'd into one universal dylib) into the app's Frameworks folder, and
# puts its notices in Resources.
# Needs rustup; the toolchain is native/replay/rust-toolchain.toml's, and a
# missing Apple target is added to it.
set -eu

source_dir="$SRCROOT/../native/replay"
output_dir="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
resources_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
target_dir="$TARGET_TEMP_DIR/icarus_replay_cargo"
# Xcode's PATH does not include rustup's bin directory.
cargo="${CARGO:-$HOME/.cargo/bin/cargo}"
if [ ! -x "$cargo" ]; then
  cargo="$(command -v cargo || true)"
fi
if [ -z "$cargo" ]; then
  echo "error: cargo not found; install Rust with rustup to build the replay decoder" >&2
  exit 1
fi
mkdir -p "$output_dir" "$resources_dir"
# rustup picks the toolchain from rust-toolchain.toml in the working directory.
cd "$source_dir"
rustup="$(dirname "$cargo")/rustup"

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
  if [ -x "$rustup" ] && ! "$rustup" target list --installed | grep -qx "$triple"; then
    "$rustup" target add "$triple"
  fi
  "$cargo" build --release --locked --lib \
    --manifest-path "$source_dir/Cargo.toml" \
    --target "$triple" --target-dir "$target_dir"
  set -- "$@" "$target_dir/$triple/release/libicarus_replay.dylib"
done
xcrun lipo -create "$@" -output "$output_dir/libicarus_replay.dylib"
# Apache-2.0 section 4: vrfkit's notices and the license text ship with the
# library. Resources, not Frameworks: codesign takes every file in Frameworks
# for code.
cp "$source_dir/NOTICE.md" "$resources_dir/icarus_replay_NOTICE.md"
cp "$source_dir/../../LICENSE" "$resources_dir/icarus_replay_LICENSE.txt"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
    --timestamp=none "$output_dir/libicarus_replay.dylib"
fi
