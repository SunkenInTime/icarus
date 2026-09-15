cmake_minimum_required(VERSION 3.14)
project(icarus_height LANGUAGES CXX)

find_package(Threads REQUIRED)
add_library(icarus_height SHARED icarus_height.cpp icarus_svg_height.cpp)
target_compile_features(icarus_height PRIVATE cxx_std_17)
target_link_libraries(icarus_height PRIVATE Threads::Threads)
set_target_properties(icarus_height PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN YES)
if(MSVC)
  # The geometry oracle uses strict double arithmetic and C++ exceptions.
  # Do not inherit the Flutter runner's _HAS_EXCEPTIONS=0 definition.
  target_compile_options(icarus_height PRIVATE
    "$<$<NOT:$<CONFIG:Debug>>:/O2>" /fp:strict /EHsc)
else()
  target_compile_options(icarus_height PRIVATE
    "$<$<NOT:$<CONFIG:Debug>>:-O2>" -fno-fast-math -ffp-contract=off)
endif()

option(IH_BUILD_TESTS "Build native ABI regression checks" OFF)
if(IH_BUILD_TESTS)
  enable_testing()
  add_executable(height_native_test height_native_test.cpp)
  target_compile_features(height_native_test PRIVATE cxx_std_17)
  target_link_libraries(height_native_test PRIVATE icarus_height)
  add_test(NAME height_native_abi COMMAND height_native_test)
  add_executable(svg_height_native_test svg_height_native_test.cpp)
  target_compile_features(svg_height_native_test PRIVATE cxx_std_17)
  target_link_libraries(svg_height_native_test PRIVATE icarus_height)
  add_test(NAME svg_height_native_abi COMMAND svg_height_native_test)
endif()
