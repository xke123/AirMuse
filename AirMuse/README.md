# AirMuse (refactored)

AirMuse is a light Windows floating media controller, not a music-library client. It shows active track
information and sends playback commands to the selected media session.

## Build

The C++20 architecture core can be verified without Windows:

    cmake -S AirMuse -B AirMuse/build -DAIRMUSE_BUILD_APP=OFF
    cmake --build AirMuse/build --config Debug
    ctest --test-dir AirMuse/build --output-on-failure

On Windows with MSVC and the Windows SDK, omit the app-off option to build the native floating-window
shell. The original 4K implementation remains untouched in the sibling AirMuse_4K_Remastered directory.

## Stack

C++20, CMake, Win32 shell, a provider adapter boundary, event-driven application core, and testable
lyrics/animation services. Apple Music and SMTC have documented migration contracts under providers.
