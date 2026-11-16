#pragma once
#include "../core/WinCommon.hpp"
#include <shellapi.h>
#include <memory>
#include <vector>
#include "../core/AppController.hpp"
#include "SpringAnimator.hpp"
#include "UIElement.hpp"
#include "DockManager.hpp"

namespace airmuse {

class LyricsWindow;
class LibraryWindow;

class MainWindow {
public:
    MainWindow(HINSTANCE hInst, AppController& controller, DockManager& dockMgr);
    ~MainWindow();

    HWND Create();
    HWND Hwnd() const { return m_hwnd; }
    void BindChildWindows(LyricsWindow* lyricsWnd, LibraryWindow* libraryWnd);

    bool IsMiniMode() const { return m_miniMode; }
    bool IsTopMost() const { return m_topMost; }
    void ToggleMiniMode();
    void SetLyricsVisible(bool visible);
    void SetLibraryVisible(bool visible);
    void Render();

private:
    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
    LRESULT HandleMessage(UINT msg, WPARAM wParam, LPARAM lParam);

    void BuildUIElements();
    void UpdateLayout(float w, float h);
    void StepAnimations(float dt);
    void EnsureFrameTimer();

    HINSTANCE m_hInst;
    AppController& m_controller;
    DockManager& m_dockMgr;
    LyricsWindow* m_lyricsWnd = nullptr;
    LibraryWindow* m_libraryWnd = nullptr;

    HWND m_hwnd = nullptr;
    int m_dpi = 96;
    bool m_miniMode = false;
    bool m_topMost = true;
    bool m_focused = true;
    bool m_hovering = false;
    bool m_lyricsVisible = false;
    bool m_libVisible = false;

    SpringValue m_winWidth{ 320.0f, 320.0f, 0.0f, 280.0f, 24.0f };
    SpringValue m_winHeight{ 104.0f, 104.0f, 0.0f, 280.0f, 24.0f };
    SpringValue m_hoverPanel{ 0.0f, 0.0f, 0.0f, 300.0f, 26.0f };
    bool m_animating = false;
    ULONGLONG m_lastFrameTick = 0;

    bool m_scrubbing = false;
    float m_scrubRatio = 0.0f;

    std::vector<UIButton> m_buttons;
    int m_hoverBtnId = -1;
    int m_pressedBtnId = -1;

    std::unique_ptr<Gdiplus::Bitmap> m_mainCtrlBmp;
    std::unique_ptr<Gdiplus::Bitmap> m_miniCtrlBmp;
    std::unique_ptr<Gdiplus::Bitmap> m_winBtnsBmp;
    std::unique_ptr<Gdiplus::Bitmap> m_iconBtnsBmp;
    std::wstring m_cachedArtKey;
    std::unique_ptr<Gdiplus::Bitmap> m_artworkBmp;
    NOTIFYICONDATAW m_nid{};
};

} // namespace airmuse
