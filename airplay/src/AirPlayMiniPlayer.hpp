#pragma once

#include "AirPlayTypes.hpp"
#include "AirPlayGlassRenderer.hpp"
#include <string>
#include <vector>

namespace AirPlay {

class MiniPlayer {
public:
    MiniPlayer();
    ~MiniPlayer();

    // Create the layered window for mini mode
    bool Create(HWND parent, int x, int y, int width = 360, int height = Metrics::MINI_BAR_HEIGHT);
    void Destroy();
    void Show(bool show);

    // Playback state updates
    void SetTrackInfo(const std::wstring& title, const std::wstring& artist);
    void SetPlaybackState(bool isPlaying);
    void SetProgress(float progress, int currentSeconds, int totalSeconds);
    void SetVolume(float volume);

    // Window properties
    HWND GetHwnd() const { return m_hwnd; }
    void SetPosition(int x, int y);
    void SetWidth(int width);

    // Repaint mini bar surface
    void Invalidate();

private:
    static LRESULT CALLBACK StaticWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam);
    LRESULT HandleMessage(UINT uMsg, WPARAM wParam, LPARAM lParam);

    void Paint();
    void UpdateLayout();
    int HitTest(int x, int y) const;

    // Window and DIB state
    HWND m_hwnd = nullptr;
    HWND m_parent = nullptr;
    HDC m_memDC = nullptr;
    HBITMAP m_memBmp = nullptr;
    uint32_t* m_dibPixels = nullptr;

    int m_x = 100;
    int m_y = 100;
    int m_width = 360;
    int m_height = Metrics::MINI_BAR_HEIGHT; // Default 40px (joined glass caps)

    // Sub-elements layout
    struct ControlButton {
        int index;        // Button index in MINICONTROL
        RECT rect;        // Hitbox in window coords
        ButtonState state;// Current state
    };
    std::vector<ControlButton> m_buttons;

    // Hitbox regions
    RECT m_titleRect = {};
    RECT m_progressRect = {};
    RECT m_timeRect = {};
    RECT m_volumeRect = {};

    // Playback and UI state
    std::wstring m_title = L"AirPlay";
    std::wstring m_artist = L"Zion";
    bool m_isPlaying = false;
    float m_progress = 0.0f;
    int m_curSec = 0;
    int m_totalSec = 0;
    float m_volume = 1.0f;

    // Interaction state
    int m_hoveredBtn = -1;
    int m_pressedBtn = -1;
    bool m_isDraggingWindow = false;
    POINT m_dragStartMouse = {};
    POINT m_dragStartWindow = {};

    // Scrolling text animation
    int m_scrollOffset = 0;
    int m_titleTextWidth = 0;
    UINT_PTR m_timerId = 0;

    // Renderer
    GlassRenderer m_renderer;
};

} // namespace AirPlay
