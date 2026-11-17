#include "LibraryWindow.hpp"
#include "GlassRenderer.hpp"
#include "../resource.h"
#include <windowsx.h>
#include <string>
#include <algorithm>

using namespace Gdiplus;

namespace airmuse {

LibraryWindow::LibraryWindow(HINSTANCE hInst, AppController& controller, DockManager& dockMgr)
    : m_hInst(hInst), m_controller(controller), m_dockMgr(dockMgr) {}

LibraryWindow::~LibraryWindow() = default;

HWND LibraryWindow::Create(HWND parentMain) {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = m_hInst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = L"AirMuseLibraryWindow";
    RegisterClassExW(&wc);

    WNDCLASSEXW wcHost{};
    wcHost.cbSize = sizeof(wcHost);
    wcHost.lpfnWndProc = DefWindowProcW;
    wcHost.hInstance = m_hInst;
    wcHost.hbrBackground = CreateSolidBrush(RGB(24, 24, 27));
    wcHost.lpszClassName = L"AirMuseWebHost";
    RegisterClassExW(&wcHost);

    m_hwnd = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        wc.lpszClassName, L"AirMuse Library", WS_POPUP,
        438, 120, 320, 318,
        parentMain, nullptr, m_hInst, this
    );

    // WebView2 前台视口：严格嵌入在中间内容区 (宽 312 x 高 276 DIP)
    m_webHostHwnd = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        wcHost.lpszClassName, L"AirMuse WebHost", WS_POPUP,
        442, 144, 312, 276,
        m_hwnd, nullptr, m_hInst, nullptr
    );

    return m_hwnd;
}

void LibraryWindow::SetVisible(bool visible) {
    ShowWindow(m_hwnd, visible ? SW_SHOWNOACTIVATE : SW_HIDE);
    ShowWindow(m_webHostHwnd, visible ? SW_SHOWNOACTIVATE : SW_HIDE);
    m_controller.SetWebVisible(visible);
    if (visible) {
        m_lastActiveOrHover = true;
        m_dockMgr.SyncAllDocked();
        Render();
    }
}

void LibraryWindow::SetTopMost(bool topMost) {
    HWND z = topMost ? HWND_TOPMOST : HWND_NOTOPMOST;
    SetWindowPos(m_hwnd, z, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    SetWindowPos(m_webHostHwnd, z, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

bool LibraryWindow::IsActiveOrHovered() const {
    if (!m_hwnd || !IsWindowVisible(m_hwnd)) return false;

    // 1. 光标是否在窗口矩形内 (包含顶部/底部玻璃条及中间 WebView2 区域)
    POINT ptCursor{};
    GetCursorPos(&ptCursor);
    RECT rcWin{};
    GetWindowRect(m_hwnd, &rcWin);
    if (PtInRect(&rcWin, ptCursor)) return true;
    if (m_hovering) return true;

    // 2. 当前前台激活窗口是否属于本分层窗口、WebView2 宿主窗口或其子孙句柄
    HWND fg = GetForegroundWindow();
    if (fg) {
        if (fg == m_hwnd || fg == m_webHostHwnd) return true;
        if (m_webHostHwnd && IsChild(m_webHostHwnd, fg)) return true;
        if (m_hwnd && IsChild(m_hwnd, fg)) return true;
    }

    return m_focused;
}

void LibraryWindow::RefreshHoverIfChanged() {
    if (!m_hwnd || !IsWindowVisible(m_hwnd)) return;
    bool active = IsActiveOrHovered();
    if (active != m_lastActiveOrHover) {
        m_lastActiveOrHover = active;
        Render();
    }
}

void LibraryWindow::Render() {
    if (!m_hwnd || !IsWindowVisible(m_hwnd)) return;
    int w = 320, h = 318;
    int wPx = GlassRenderer::ToPx(w, m_dpi);
    int hPx = GlassRenderer::ToPx(h, m_dpi);
    float scale = static_cast<float>(m_dpi) / 96.0f;

    if (!m_surface.Ensure(wPx, hPx)) return;

    {
        Graphics g(m_surface.hdcMem);
        g.Clear(Color(0, 0, 0, 0));
        g.ScaleTransform(scale, scale);
        g.SetSmoothingMode(SmoothingModeHighQuality);
        g.SetTextRenderingHint(TextRenderingHintAntiAlias);

        // 1. 窗口外框：亚克力磨砂玻璃背景 (根据焦点状态决定亮边)
        bool showGlassText = IsActiveOrHovered();
        GlassRenderer::DrawAirPlayGlassFrame(g, w, h, 0.0f, showGlassText);

        // 仅在获得焦点或鼠标悬停时绘制顶部与底部的玻璃条文字及按钮
        if (showGlassText) {
            FontFamily ff(L"Microsoft YaHei UI");
            StringFormat leftSf;
            leftSf.SetAlignment(StringAlignmentNear);
            leftSf.SetLineAlignment(StringAlignmentCenter);
            leftSf.SetTrimming(StringTrimmingEllipsisCharacter);
            leftSf.SetFormatFlags(StringFormatFlagsNoWrap);

            // 2. 顶部玻璃条 (Y: 0 ~ 24 DIP，不可显示内容，仅作为窗口边框标题与关闭按钮)
            RectF topGlassClip(3.0f, 2.0f, static_cast<float>(w - 6), 18.0f);

            WebPlatform cur = m_controller.CurrentWebPlatform();
            std::wstring svcName = (cur == WebPlatform::Spotify) ? L"Spotify" : (cur == WebPlatform::QQMusic ? L"QQ 音乐" : L"Apple Music");
            std::wstring userName = m_controller.CurrentWebUserName();
            if (userName.empty() && cur == WebPlatform::AppleMusic) userName = L"小可";
            std::wstring headerTitle = userName.empty() ? (L"未登录的 " + svcName) : (userName + L" 的 " + svcName);

            // 标题光晕与文字
            GlassRenderer::DrawBarSpillFog(g, topGlassClip, 42.0f, 26.0f, 165.0f, true, 195);
            GlassRenderer::DrawGlyphHaloText(g, headerTitle, ff, 10.5f, RectF(32.0f, 3.0f, 210.0f, 16.0f), leftSf, Color(245, 240, 246, 255), 1.0f);

            // 右上角关闭按钮
            bool hoverClose = (m_hoverTab == 3);
            GlassRenderer::DrawBarSpillFog(g, topGlassClip, static_cast<float>(w - 38), 65.0f, 24.0f, true, hoverClose ? 225 : 185);
            GlassRenderer::DrawImageAlpha(g, m_winBtnsBmp.get(), RectF(static_cast<REAL>(w - 45), 4.0f, 13.0f, 13.0f), 2 * 52, 0, 52, 52, hoverClose ? 1.0f : 0.88f, 1.18f);

            // 3. 底部玻璃条 (Y: 298 ~ 318 DIP，不可显示内容，仅作为正在播放状态条)
            auto info = m_controller.Store().GetPlayback();
            std::wstring sourceLabel = L"Apple Music 就绪";
            if (!info.contextTitle.empty()) {
                sourceLabel = L"正在播放 · " + info.contextTitle;
            } else if (!info.title.empty() && info.title != L"AirMuse Ready") {
                sourceLabel = L"正在播放 · " + info.title + (info.artist.empty() ? L"" : (L" - " + info.artist));
            }

            RectF botGlassClip(4.0f, static_cast<float>(h - 20), static_cast<float>(w - 8), 18.0f);
            bool hoverBot = (m_hoverTab == 4);
            GlassRenderer::DrawBarSpillFog(g, botGlassClip, 42.0f, 26.0f, 180.0f, false, hoverBot ? 235 : 195);

            RectF botRect(16.0f, static_cast<float>(h - 19), static_cast<float>(w - 32), 16.0f);
            Color botColor = hoverBot ? Color(255, 185, 232, 255) : Color(245, 242, 246, 252);
            GlassRenderer::DrawGlyphHaloText(g, sourceLabel, ff, 9.5f, botRect, leftSf, botColor, 1.0f);
        }
    }

    m_surface.Present(m_hwnd, wPx, hPx, 255);
}

LRESULT CALLBACK LibraryWindow::WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    LibraryWindow* self = nullptr;
    if (msg == WM_CREATE) {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
        self = static_cast<LibraryWindow*>(cs->lpCreateParams);
        self->m_hwnd = hwnd;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    } else {
        self = reinterpret_cast<LibraryWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    }
    return self ? self->HandleMessage(msg, wParam, lParam) : DefWindowProcW(hwnd, msg, wParam, lParam);
}

LRESULT LibraryWindow::HandleMessage(UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE:
        m_dpi = GetDpiForWindow(m_hwnd);
        if (m_dpi == 0) m_dpi = 96;
        m_winBtnsBmp = GlassRenderer::LoadPngResource(m_hInst, IDR_PNG_WINDOWBUTTON);
        GlassRenderer::EnableFrostedBlur(m_hwnd, GlassRenderer::ToPx(320, m_dpi), GlassRenderer::ToPx(318, m_dpi), m_dpi, false);
        return 0;

    case WM_ACTIVATE:
        m_focused = (LOWORD(wParam) != WA_INACTIVE);
        RefreshHoverIfChanged();
        return 0;

    case WM_WINDOWPOSCHANGED:
        m_dockMgr.SyncWebHostBounds();
        m_controller.ResizeWebHost(GlassRenderer::ToPx(312, m_dpi), GlassRenderer::ToPx(276, m_dpi));
        return DefWindowProcW(m_hwnd, msg, wParam, lParam);

    case WM_MOUSEMOVE: {
        m_hovering = true;
        int x = GlassRenderer::ToDip(GET_X_LPARAM(lParam), m_dpi);
        int y = GlassRenderer::ToDip(GET_Y_LPARAM(lParam), m_dpi);
        int hit = -1;
        if (x >= 320 - 48 && x <= 320 - 24 && y >= 0 && y <= 24) hit = 3; // 关闭按钮
        if (y >= 298 && y <= 318) hit = 4;                                // 底部播放条
        bool stateChanged = (hit != m_hoverTab || !m_lastActiveOrHover);
        m_hoverTab = hit;
        m_lastActiveOrHover = true;
        if (stateChanged) {
            Render();
        }
        TRACKMOUSEEVENT tme{ sizeof(tme), TME_LEAVE, m_hwnd, 0 };
        TrackMouseEvent(&tme);
        return 0;
    }

    case WM_MOUSELEAVE:
        m_hovering = false;
        m_hoverTab = -1;
        RefreshHoverIfChanged();
        Render();
        return 0;

    case WM_LBUTTONDOWN: {
        int y = GlassRenderer::ToDip(GET_Y_LPARAM(lParam), m_dpi);
        if (m_hoverTab == 3) {
            SetVisible(false);
            return 0;
        }
        if (m_hoverTab == 4) {
            m_controller.JumpToPlayingContext();
            return 0;
        }
        if (y < 24) {
            ReleaseCapture();
            SendMessageW(m_hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
            return 0;
        }
        return 0;
    }

    case WM_WINDOWPOSCHANGING:
        m_dockMgr.OnLibraryMoving(reinterpret_cast<WINDOWPOS*>(lParam));
        return 0;
    }
    return DefWindowProcW(m_hwnd, msg, wParam, lParam);
}

} // namespace airmuse
