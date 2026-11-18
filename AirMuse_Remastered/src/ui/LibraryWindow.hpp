#pragma once
#include "../core/WinCommon.hpp"
#include <memory>
#include <string>
#include "../core/AppController.hpp"
#include "DockManager.hpp"
#include "GlassRenderer.hpp"
#include "SpringAnimator.hpp"
#include "MotionCoordinator.hpp"

namespace airmuse {

class LibraryWindow : public IMotionClient {
public:
    static constexpr int DEFAULT_WIDTH_DIP  = 330;
    static constexpr int DEFAULT_HEIGHT_DIP = 334;

    LibraryWindow(HINSTANCE hInst, AppController& controller, DockManager& dockMgr);
    ~LibraryWindow() override;

    HWND Create(HWND parentMain);
    HWND Hwnd() const { return m_hwnd; }
    HWND WebHostHwnd() const { return m_webHostHwnd; }

    void SetVisible(bool visible);
    void SetTopMost(bool topMost);
    void RefreshHoverIfChanged();
    void Render();

    // IMotionClient
    bool StepMotion(float dt) override;
    void OnMotionRender() override;

private:
    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
    LRESULT HandleMessage(UINT msg, WPARAM wParam, LPARAM lParam);
    bool IsActiveOrHovered() const;

    HINSTANCE m_hInst;
    AppController& m_controller;
    DockManager& m_dockMgr;
    HWND m_hwnd = nullptr;
    HWND m_webHostHwnd = nullptr;
    int m_dpi = 96;

    int m_hoverTab = -1; // 3: 关闭按钮, 4: 底部正在播放
    bool m_hovering = false;
    bool m_focused = false;
    bool m_lastActiveOrHover = false;
    bool m_lastMouseInside = false;

    SpringValue m_focusAnim{ 1.0f, MotionPreset::Gentle };

    LayeredSurface m_surface;
    std::unique_ptr<Gdiplus::Bitmap> m_winBtnsBmp;
};

} // namespace airmuse
