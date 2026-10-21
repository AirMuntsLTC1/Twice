cmake_minimum_required(VERSION 3.18.1)
project(twice_native)

add_library(twice_native SHARED twice_native.cpp)

find_library(log-lib log)

target_link_libraries(twice_native ${log-lib})

# Export the plain C symbols used by Dart FFI
set_target_properties(twice_native PROPERTIES
    CXX_VISIBILITY_PRESET default
    VISIBILITY_INLINES_HIDDEN OFF
)
