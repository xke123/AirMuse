#pragma once
#include "../core/WinCommon.hpp"
#include <memory>
#include "../core/AppController.hpp"
#include "SpringAnimator.hpp"
#include "DockManager.hpp"
#include "GlassRenderer.hpp"
#include "MotionCoordinator.hpp"

namespace airmuse {

class LyricsWindow : public IMotionClient {
public:
    LyricsWindow(HINSTANCE hInst, AppController& controller, DockManager& dockMgr);
    ~LyricsWindow() override;
    HWND Create(HWND parentMain);
    HWND Hwnd() const { return m_hwnd; }

    void SetVisible(bool visible);
    void SetMiniMode(bool mini);
    void OnPlaybackTick();
    void OnPlaybackOrLyricsChanged();
    void Render();

    // IMotionClient
    bool StepMotion(float dt) override;
    void OnMotionRender() override;

private:
    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
    LRESULT HandleMessage(UINT msg, WPARAM wParam, LPARAM lParam);

    void EnsureFrameTimer();
    void StepAnimations(float dt);
    int ComputeStableActiveIndex(LyricsSnapshot const& lrc, int64_t livePosMs);

    HINSTANCE m_hInst;
    AppController& m_controller;
    DockManager& m_dockMgr;
    HWND m_hwnd = nullptr;
    int m_dpi = 96;
    bool m_mini = false;
    bool m_hovering = false;
    int m_hoverBtn = -1;
    int m_lastActiveIdx = -1;
    std::wstring m_lastTrackKey;

    bool m_hiding = false;
    bool m_animating = false;
    ULONGLONG m_lastFrameTick = 0;

    SpringValue m_scrollY{ 0.0f, 0.0f, 0.0f, 220.0f, 30.0f };
    SpringValue m_winHeight{ 216.0f, 216.0f, 0.0f, 280.0f, 24.0f };
    SpringValue m_miniLyricSlide{ 1.0f, 1.0f, 0.0f, 260.0f, 34.0f };
    SpringValue m_revealAnim{ 0.0f, 0.0f, 0.0f, 260.0f, 34.0f };
    SpringValue m_focusAnim{ 1.0f, MotionPreset::Gentle };
    std::wstring m_prevMiniLine;
    std::wstring m_curMiniLine;

    LayeredSurface m_surface;
    std::unique_ptr<Gdiplus::Bitmap> m_winBtnsBmp;
};

} // namespace airmuse