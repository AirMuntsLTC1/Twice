cmake_minimum_required(VERSION 3.18.1)

project(twice_native LANGUAGES CXX)

add_library(
    twice_native
    SHARED
    twice_native.cpp
)

target_compile_features(twice_native PRIVATE cxx_std_17)

set_target_properties(
    twice_native
    PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
)
