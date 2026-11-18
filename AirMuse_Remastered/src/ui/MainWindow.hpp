#pragma once
#include "../core/WinCommon.hpp"
#include <shellapi.h>
#include <memory>
#include <vector>
#include "../core/AppController.hpp"
#include "SpringAnimator.hpp"
#include "UIElement.hpp"
#include "DockManager.hpp"
#include "GlassRenderer.hpp"
#include "MotionCoordinator.hpp"

namespace airmuse {

class LyricsWindow;
class LibraryWindow;
class TestPanelWindow;

class MainWindow : public IMotionClient {
public:
    static constexpr int DEFAULT_WIDTH_DIP  = 330;
    static constexpr int DEFAULT_HEIGHT_DIP = 106;

    MainWindow(HINSTANCE hInst, AppController& controller, DockManager& dockMgr);
    ~MainWindow() override;

    HWND Create();
    HWND Hwnd() const { return m_hwnd; }
    void BindChildWindows(LyricsWindow* lyricsWnd, LibraryWindow* libraryWnd);
    void BindTestPanel(TestPanelWindow* testPanelWnd);

    bool IsMiniMode() const { return m_miniMode; }
    bool IsTopMost() const { return m_topMost; }
    void StartIntroSequence();
    void ToggleMiniMode();
    void SetLyricsVisible(bool visible);
    void SetLibraryVisible(bool visible);
    void Render();

    // IMotionClient
    bool StepMotion(float dt) override;
    void OnMotionRender() override;

private:
    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
    LRESULT HandleMessage(UINT msg, WPARAM wParam, LPARAM lParam);

    void BuildUIElements();
    void UpdateLayout(float w, float h);
    void StepAnimations(float dt);
    void EnsureFrameTimer();
    void InvalidateBgCache();
    std::vector<std::wstring> GetMiniCycleItems(NowPlayingState const& info) const;
    void TriggerSweep(float startPos, float endPos, float speed = 1.8f, float originX = 0.5f);

    struct SpecularSweep {
        bool active = true;
        float startPos = 0.0f;
        float endPos = 1.0f;
        float progress = 0.0f;
        float speed = 1.8f;
        float originX = 0.5f;
    };
    std::vector<SpecularSweep> m_sweeps;

    float m_lastMouseY = -1.0f;
    ULONGLONG m_lastMouseMoveTick = 0;
    int m_lastMidCrossDir = 0; // +1 = moving down across mid, -1 = moving up across mid
    bool m_topBoundaryTriggered = false;
    bool m_botBoundaryTriggered = false;

    HINSTANCE m_hInst;
    AppController& m_controller;
    DockManager& m_dockMgr;
    LyricsWindow* m_lyricsWnd = nullptr;
    LibraryWindow* m_libraryWnd = nullptr;
    TestPanelWindow* m_testPanelWnd = nullptr;

    HWND m_hwnd = nullptr;
    int m_dpi = 96;
    bool m_miniMode = false;
    bool m_topMost = true;
    bool m_focused = true;
    bool m_hovering = false;
    bool m_lyricsVisible = false;
    bool m_libVisible = false;
    bool m_animSpeed2s = false; // false = 1.5s, true = 2.0s
    float m_animDuration = 1.5f;
    float m_introProgress = 0.0f;
    float m_introTime = 0.0f;

    SpringValue m_winWidth{ static_cast<float>(DEFAULT_WIDTH_DIP), static_cast<float>(DEFAULT_WIDTH_DIP), 0.0f, 280.0f, 24.0f };
    SpringValue m_winHeight{ static_cast<float>(DEFAULT_HEIGHT_DIP), static_cast<float>(DEFAULT_HEIGHT_DIP), 0.0f, 280.0f, 24.0f };
    SpringValue m_hoverPanel{ 0.0f, 0.0f, 0.0f, 300.0f, 26.0f };
    SpringValue m_miniTextSlide{ 1.0f, 1.0f, 0.0f, 260.0f, 34.0f };
    SpringValue m_focusAnim{ 1.0f, MotionPreset::Gentle };
    bool m_introActive = true;
    bool m_pendingStartupPanels = false;
    ULONGLONG m_introStartTick = 0;

    int m_miniFieldIdx = 0;
    ULONGLONG m_miniCycleTick = 0;
    std::wstring m_prevMiniLine;
    std::wstring m_curMiniLine;

    bool m_animating = false;
    ULONGLONG m_lastFrameTick = 0;

    bool m_scrubbing = false;
    float m_scrubRatio = 0.0f;

    std::vector<UIButton> m_buttons;
    int m_hoverBtnId = -1;
    int m_pressedBtnId = -1;

    LayeredSurface m_surface;
    std::unique_ptr<Gdiplus::Bitmap> m_bgCacheBmp;
    int m_bgCacheW = 0;
    int m_bgCacheH = 0;
    bool m_bgCacheFocused = false;
    std::wstring m_bgCacheArtKey;

    std::unique_ptr<Gdiplus::Bitmap> m_appLogoBmp;
    std::unique_ptr<Gdiplus::Bitmap> m_mainCtrlBmp;
    std::unique_ptr<Gdiplus::Bitmap> m_miniCtrlBmp;
    std::unique_ptr<Gdiplus::Bitmap> m_winBtnsBmp;
    std::unique_ptr<Gdiplus::Bitmap> m_iconBtnsBmp;
    std::wstring m_cachedArtKey;
    std::unique_ptr<Gdiplus::Bitmap> m_artworkBmp;
    NOTIFYICONDATAW m_nid{};
};

} // namespace airmuse