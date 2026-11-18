cmake_minimum_required(VERSION 3.20)
project(AirMuseWin LANGUAGES CXX RC)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(WV2_DIR "${CMAKE_BINARY_DIR}/webview2")
if(NOT EXISTS "${WV2_DIR}/build/native/include/WebView2.h")
    message(STATUS "Downloading Microsoft.Web.WebView2 SDK...")
    file(DOWNLOAD
        "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/1.0.2903.40"
        "${CMAKE_BINARY_DIR}/webview2.nupkg"
        STATUS WV2_DL_STATUS
    )
    list(GET WV2_DL_STATUS 0 WV2_DL_CODE)
    if(NOT WV2_DL_CODE EQUAL 0)
        message(FATAL_ERROR "Failed to download WebView2 package: ${WV2_DL_STATUS}")
    endif()
    file(ARCHIVE_EXTRACT INPUT "${CMAKE_BINARY_DIR}/webview2.nupkg" DESTINATION "${WV2_DIR}")
endif()

if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    add_compile_options(/utf-8 /W4 /EHsc /permissive-)
    add_compile_options($<$<CONFIG:Release>:/Os> $<$<CONFIG:Release>:/GL> $<$<CONFIG:Release>:/Gy>)
    add_link_options($<$<CONFIG:Release>:/LTCG> $<$<CONFIG:Release>:/OPT:REF> $<$<CONFIG:Release>:/OPT:ICF>)
endif()

add_executable(AirMuse WIN32
    src/main.cpp
    src/core/AppController.cpp
    src/media/MediaArbitrator.cpp
    src/media/SmtcProvider.cpp
    src/media/WebSourceProvider.cpp
    src/lyrics/LyricsEngine.cpp
    src/ui/GlassRenderer.cpp
    src/ui/MotionCoordinator.cpp
    src/ui/DockManager.cpp
    src/ui/MainWindow.cpp
    src/ui/LyricsWindow.cpp
    src/ui/LibraryWindow.cpp
    src/ui/TestPanelWindow.cpp
    src/AirMuse.rc
)

add_custom_command(TARGET AirMuse POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/src/media/airmuse_apple_engine.js"
    "$<TARGET_FILE_DIR:AirMuse>/airmuse_apple_engine.js"
)

target_include_directories(AirMuse PRIVATE
    src
    "${WV2_DIR}/build/native/include"
)

target_compile_definitions(AirMuse PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)

target_link_libraries(AirMuse PRIVATE
    "${WV2_DIR}/build/native/x64/WebView2LoaderStatic.lib"
    gdiplus
    dwmapi
    shell32
    shlwapi
    winhttp
    crypt32
    ole32
    oleaut32
    winmm
    windowsapp
)