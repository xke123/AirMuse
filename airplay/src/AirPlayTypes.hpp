#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <cstdint>
#include <string>

namespace AirPlay {

// Window Classes registered by AirPlay
constexpr const wchar_t* WINDOW_CLASS_BASE = L"AIRPLAY_BASE_WINDOW";
constexpr const wchar_t* WINDOW_CLASS_GUI  = L"FAIRPLAY GUI OBJEXT CLASS";
constexpr const wchar_t* WINDOW_NAME_MAIN  = L"AirPlay";

// Window Message constants (WM_USER + X)
enum WindowMessages : UINT {
    WM_AIRPLAY_COMMAND     = WM_USER + 1,  // Playback control
    WM_AIRPLAY_NOTIFY      = WM_USER + 2,  // State changes
    WM_AIRPLAY_SYSTRAY     = WM_USER + 12, // Tray icon callback
};

// Playback Commands sent via WM_AIRPLAY_COMMAND (wParam)
enum PlaybackCommands : WPARAM {
    CMD_PLAY       = 1,
    CMD_PAUSE      = 2,
    CMD_STOP       = 3,
    CMD_PREV       = 4,
    CMD_NEXT       = 5,
    CMD_OPEN_FILES = 6,
};

// Mini Player Control Button Indices (in MINICONTROL 96x16 sprite sheet)
enum MiniButtonIndex : int {
    MINI_BTN_PREV   = 0,  // X offset: 0px
    MINI_BTN_PLAY   = 1,  // X offset: 16px (when paused)
    MINI_BTN_PAUSE  = 2,  // X offset: 32px (when playing)
    MINI_BTN_STOP   = 3,  // X offset: 48px
    MINI_BTN_NEXT   = 4,  // X offset: 64px
    MINI_BTN_MENU   = 5,  // X offset: 80px (popup menu / playlist)
    
    // Window control buttons (from WINDOWBUTTON 130x26 sprite sheet)
    MINI_BTN_MINIMIZE = 6,
    MINI_BTN_CLOSE    = 7,
};

// Button Interaction States
enum class ButtonState {
    Normal   = 0,
    Hover    = 1,
    Pressed  = 2,
    Disabled = 3
};

// Window Display Modes
enum class PlayerWindowMode {
    Normal,  // Full 3-panel mode: window_main + window_infoshow + window_playlist
    Mini     // Compact single-strip mode: window_main_mini (+ optional mini_info)
};

// Configuration XML Node Names identified in binary
struct ConfigNodes {
    static constexpr const wchar_t* WindowMain        = L"window_main";
    static constexpr const wchar_t* WindowMainMini    = L"window_main_mini";
    static constexpr const wchar_t* WindowInfoShow    = L"window_infoshow";
    static constexpr const wchar_t* WindowInfoShowMini= L"window_infoshow_mini";
    static constexpr const wchar_t* WindowPlaylist    = L"window_playlist";
    static constexpr const wchar_t* NormalMiniSwitch  = L"normal_minibar_switch";
    static constexpr const wchar_t* MiniList          = L"mini_list";
    static constexpr const wchar_t* MiniInfo          = L"mini_info";
    static constexpr const wchar_t* NormList          = L"norm_list";
    static constexpr const wchar_t* NormInfo          = L"norm_info";
};

// Geometry specifications extracted from disassembly
struct Metrics {
    // Glass Slices
    static constexpr int GLASS_BORDER_THICKNESS = 5;   // Left & right border width (0x47DA6A)
    static constexpr int GLASS_CAP_HEIGHT       = 20;  // Top & bottom glass cap height (40px / 2, 0x47BB2F)
    static constexpr int GLASS_TOTAL_VFRAME     = 40;  // Top (20) + Bottom (20) = 40px
    static constexpr int GLASS_CORNER_RADIUS    = 4;   // Native rounded corner radius
    
    // Mini Mode Dimensions
    static constexpr int MINI_BAR_HEIGHT        = 40;  // Height when top & bottom caps are joined
    static constexpr int MINI_BAR_COMPACT_H     = 30;  // Compact docked mini bar height
    static constexpr int MINI_BUTTON_SIZE       = 16;  // 16x16 pixels per control button
    static constexpr int MINI_BUTTON_Y_OFFSET   = 2;   // Y offset from top (+2px, 0x4574D8)
    static constexpr int MINI_WINDOW_BTN_SIZE   = 13;  // Window close/minimize button size (0x47DA36)
    
    // Digital Time Font Metrics (TIMEFONT 90x14)
    static constexpr int TIMEFONT_CHAR_WIDTH    = 6;   // 6px width per digit (0x457C28)
    static constexpr int TIMEFONT_CHAR_HEIGHT   = 7;   // 7px height per digit (0x457C26)
    static constexpr int TIMEFONT_CHAR_STEP     = 7;   // Horizontal step: width + 1px spacing (0x457C85)
    static constexpr int TIMEFONT_Y_BOTTOM_GAP  = 9;   // Y = panel_y + panel_h - 9px (0x457BB8)
};

} // namespace AirPlay
