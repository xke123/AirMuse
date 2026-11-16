cmake_minimum_required(VERSION 3.20)
project(AirMuseWin LANGUAGES CXX RC)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Static CRT (/MT) + Size optimization (/Os) + Whole Program Optimization (/GL) for single-file < 600KB binary
if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    add_compile_options(/utf-8 /W4 /EHsc /permissive-)
    add_compile_options($<$<CONFIG:Release>:/Os> $<$<CONFIG:Release>:/GL> $<$<CONFIG:Release>:/Gy>)
    add_link_options($<$<CONFIG:Release>:/LTCG> $<$<CONFIG:Release>:/OPT:REF> $<$<CONFIG:Release>:/OPT:ICF>)
endif()

add_executable(AirMuse WIN32
    src/main.cpp
    src/SmtcController.cpp
    src/AirMuse.rc
)

target_include_directories(AirMuse PRIVATE src)
target_compile_definitions(AirMuse PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(AirMuse PRIVATE
    gdiplus
    dwmapi
    shell32
    shlwapi
    windowsapp
)
