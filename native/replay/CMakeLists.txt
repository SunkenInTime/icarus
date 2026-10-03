cmake_minimum_required(VERSION 3.14)
project(icarus_replay NONE)

# The replay decoder is a Rust crate. Cargo builds it in release (a debug
# decode is several times slower) into its own target directory under this
# build tree; it is incremental, so an unchanged crate costs a second.
find_program(CARGO cargo
  HINTS "$ENV{CARGO_HOME}/bin" "$ENV{USERPROFILE}/.cargo/bin" "$ENV{HOME}/.cargo/bin"
  REQUIRED)

set(ICARUS_REPLAY_TARGET_DIR "${CMAKE_CURRENT_BINARY_DIR}/cargo")
if(WIN32)
  set(ICARUS_REPLAY_LIBRARY "${ICARUS_REPLAY_TARGET_DIR}/release/icarus_replay.dll")
else()
  set(ICARUS_REPLAY_LIBRARY "${ICARUS_REPLAY_TARGET_DIR}/release/libicarus_replay.so")
endif()
set(ICARUS_REPLAY_LIBRARY "${ICARUS_REPLAY_LIBRARY}" PARENT_SCOPE)
# Apache-2.0 section 4: vrfkit's notices and the license text travel with the
# library, so the runner installs both beside it.
set(ICARUS_REPLAY_NOTICE "${CMAKE_CURRENT_SOURCE_DIR}/NOTICE.md" PARENT_SCOPE)
set(ICARUS_REPLAY_LICENSE "${CMAKE_CURRENT_SOURCE_DIR}/../../LICENSE" PARENT_SCOPE)

add_custom_target(icarus_replay ALL
  COMMAND "${CARGO}" build --release --locked --lib
    --manifest-path "${CMAKE_CURRENT_SOURCE_DIR}/Cargo.toml"
    --target-dir "${ICARUS_REPLAY_TARGET_DIR}"
  BYPRODUCTS "${ICARUS_REPLAY_LIBRARY}"
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
  COMMENT "Building the replay decoder (cargo)"
  USES_TERMINAL
  VERBATIM)
