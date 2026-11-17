#pragma once
#include "../core/WinCommon.hpp"
#include <memory>
#include <string>
#include "../core/AppController.hpp"
#include "DockManager.hpp"
#include "GlassRenderer.hpp"

namespace airmuse {

class LibraryWindow {
public:
    LibraryWindow(HINSTANCE hInst, AppController& controller, DockManager& dockMgr);
    ~LibraryWindow();

    HWND Create(HWND parentMain);
    HWND Hwnd() const { return m_hwnd; }
    HWND WebHostHwnd() const { return m_webHostHwnd; }

    void SetVisible(bool visible);
    void SetTopMost(bool topMost);
    void RefreshHoverIfChanged();
    void Render();

private:
    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
    LRESULT HandleMessage(UINT msg, WPARAM wParam, LPARAM lParam);

    HINSTANCE m_hInst;
    AppController& m_controller;
    DockManager& m_dockMgr;
    HWND m_hwnd = nullptr;
    HWND m_webHostHwnd = nullptr;
    int m_dpi = 96;

    int m_hoverTab = -1; // 3: 关闭按钮, 4: 底部正在播放
    bool m_hovering = false;
    bool m_lastMouseInside = false;

    LayeredSurface m_surface;
    std::unique_ptr<Gdiplus::Bitmap> m_winBtnsBmp;
};

} // namespace airmuse
