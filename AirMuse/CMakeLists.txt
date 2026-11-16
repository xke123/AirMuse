cmake_minimum_required(VERSION 3.20)
project(AirMuse LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
option(AIRMUSE_BUILD_APP "Build the Windows floating controller" ${WIN32})
option(AIRMUSE_BUILD_TESTS "Build architecture tests" ON)

add_library(airmuse_core
    core/application/PlaybackArbiter.cpp
    core/application/ProviderManager.cpp
    core/application/PlaybackCoordinator.cpp
    providers/mock/MockProvider.cpp
    services/playback/PlaybackClock.cpp
    services/lyrics/LyricsParser.cpp
    services/lyrics/LyricsMatcher.cpp
    services/lyrics/LyricsService.cpp
    presentation/animation/AnimationScheduler.cpp
    presentation/interaction/PlayerViewState.cpp)
target_include_directories(airmuse_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(airmuse_core PUBLIC cxx_std_20)
if(MSVC)
  target_compile_options(airmuse_core PRIVATE /W4 /permissive- /utf-8)
else()
  target_compile_options(airmuse_core PRIVATE -Wall -Wextra -Wpedantic)
endif()

if(WIN32 AND AIRMUSE_BUILD_APP)
  add_executable(AirMuse WIN32 app/main.cpp app/Application.cpp presentation/windows/FloatingWindow.cpp presentation/rendering/PlayerRenderer.cpp)
  target_link_libraries(AirMuse PRIVATE airmuse_core gdiplus dwmapi msimg32)
  target_compile_definitions(AirMuse PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
  file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/resources/ui")
  configure_file(resources/ui/MAINCONTROL.png "${CMAKE_CURRENT_BINARY_DIR}/resources/ui/MAINCONTROL.png" COPYONLY)
  configure_file(resources/ui/MINICONTROL.png "${CMAKE_CURRENT_BINARY_DIR}/resources/ui/MINICONTROL.png" COPYONLY)
  configure_file(resources/ui/WINDOWBUTTON.png "${CMAKE_CURRENT_BINARY_DIR}/resources/ui/WINDOWBUTTON.png" COPYONLY)
endif()

if(AIRMUSE_BUILD_TESTS)
  enable_testing()
  add_executable(airmuse_tests tests/unit/CoreTests.cpp)
  target_link_libraries(airmuse_tests PRIVATE airmuse_core)
  add_test(NAME airmuse_tests COMMAND airmuse_tests)
endif()
