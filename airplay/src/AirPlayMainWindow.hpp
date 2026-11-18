#pragma once

#include "AirPlayTypes.hpp"
#include "AirPlayMiniPlayer.hpp"
#include "AirPlayGlassRenderer.hpp"
#include <memory>

namespace AirPlay {

class MainWindow {
public:
    MainWindow();
    ~MainWindow();

    bool Create();
    void RunMessageLoop();

    // Mode Switching
    void SwitchMode(PlayerWindowMode mode);
    PlayerWindowMode GetCurrentMode() const { return m_mode; }

    // Docking & Snapping to screen edges or Windows taskbar ("Shell_TrayWnd")
    void CheckSnapToTaskbar();

private:
    static LRESULT CALLBACK StaticWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam);
    LRESULT HandleMessage(UINT uMsg, WPARAM wParam, LPARAM lParam);

    HWND m_hwnd = nullptr;
    PlayerWindowMode m_mode = PlayerWindowMode::Normal;
    std::unique_ptr<MiniPlayer> m_miniPlayer;
    GlassRenderer m_renderer;

    // Normal window coordinates and settings
    int m_normX = 200;
    int m_normY = 200;
    int m_normW = 300;
    int m_normH = 140;

    // Mini window coordinates
    int m_miniX = 200;
    int m_miniY = 200;
    int m_miniW = 360;
    int m_miniH = Metrics::MINI_BAR_HEIGHT;

    bool m_topmost = false;
};

} // namespace AirPlay
