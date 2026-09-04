cmake_minimum_required(VERSION 3.21)

project(KeyEcho VERSION 0.1.0 LANGUAGES CXX)

if(NOT WIN32)
    message(FATAL_ERROR "KeyEcho must be configured with a Windows toolchain")
endif()

add_executable(KeyEcho WIN32
    src/main.cpp
    resources/KeyEcho.manifest
)

target_compile_features(KeyEcho PRIVATE cxx_std_20)
target_compile_definitions(KeyEcho PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(KeyEcho PRIVATE Comdlg32 Gdi32)

if(MSVC)
    set_property(TARGET KeyEcho PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    target_compile_options(KeyEcho PRIVATE /W4 /permissive- /utf-8)
else()
    target_compile_options(KeyEcho PRIVATE -Wall -Wextra -Wpedantic)
endif()

install(TARGETS KeyEcho RUNTIME DESTINATION .)
