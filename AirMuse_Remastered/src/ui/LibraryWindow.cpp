#include "LibraryWindow.hpp"
#include "GlassRenderer.hpp"
#include "../resource.h"
#include <windowsx.h>
#include <string>

using namespace Gdiplus;

namespace airmuse {

LibraryWindow::LibraryWindow(HINSTANCE hInst, AppController& controller, DockManager& dockMgr)
    : m_hInst(hInst), m_controller(controller), m_dockMgr(dockMgr) {}

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
    wcHost.hbrBackground = CreateSolidBrush(RGB(28, 29, 32));
    wcHost.lpszClassName = L"AirMuseWebHost";
    RegisterClassExW(&wcHost);

    m_hwnd = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        wc.lpszClassName, L"AirMuse Library", WS_POPUP,
        438, 120, 320, 318,
        parentMain, nullptr, m_hInst, this
    );

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
        m_dockMgr.SyncAllDocked();
        Render();
    }
}

void LibraryWindow::SetTopMost(bool topMost) {
    HWND z = topMost ? HWND_TOPMOST : HWND_NOTOPMOST;
    SetWindowPos(m_hwnd, z, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    SetWindowPos(m_webHostHwnd, z, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

void LibraryWindow::Render() {
    if (!m_hwnd || !IsWindowVisible(m_hwnd)) return;
    int w = 320, h = 318;
    int wPx = GlassRenderer::ToPx(w, m_dpi);
    int hPx = GlassRenderer::ToPx(h, m_dpi);
    float scale = static_cast<float>(m_dpi) / 96.0f;

    HDC hdcScreen = GetDC(nullptr);
    HDC hdcMem = CreateCompatibleDC(hdcScreen);
    BITMAPINFO bmi{};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = wPx;
    bmi.bmiHeader.biHeight = -hPx;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    void* bits = nullptr;
    HBITMAP hBmp = CreateDIBSection(hdcScreen, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
    HGDIOBJ oldBmp = SelectObject(hdcMem, hBmp);

    {
        Graphics g(hdcMem);
        g.ScaleTransform(scale, scale);
        g.SetSmoothingMode(SmoothingModeHighQuality);
        g.SetTextRenderingHint(TextRenderingHintAntiAlias);

        GlassRenderer::DrawAirPlayGlassFrame(g, w, h, 0.0f, true);

        POINT ptCursor{};
        GetCursorPos(&ptCursor);
        RECT rcWinNow{};
        GetWindowRect(m_hwnd, &rcWinNow);
        bool isMouseInside = PtInRect(&rcWinNow, ptCursor) || m_hovering;

        if (isMouseInside) {
            FontFamily ff(L"Microsoft YaHei UI");
            StringFormat leftSf;
            leftSf.SetAlignment(StringAlignmentNear);
            leftSf.SetLineAlignment(StringAlignmentCenter);
            leftSf.SetTrimming(StringTrimmingEllipsisCharacter);
            leftSf.SetFormatFlags(StringFormatFlagsNoWrap);

            // 1. 顶部内缩玻璃条：左侧显示“未登录的 xxx”或“用户名 + 的 xxx”，右侧关闭按钮
            RectF topGlassClip(3.0f, 2.0f, static_cast<float>(w - 6), 18.0f);

            WebPlatform cur = m_controller.CurrentWebPlatform();
            std::wstring svcName = (cur == WebPlatform::Spotify) ? L"Spotify" : (cur == WebPlatform::QQMusic ? L"QQ 音乐" : L"Apple Music");
            std::wstring userName = m_controller.CurrentWebUserName();
            std::wstring headerTitle = userName.empty() ? (L"未登录的 " + svcName) : (userName + L" 的 " + svcName);

            // 左侧标题梯形暗雾：左侧收齐(12px)，右侧延伸至黄金分割点(182px)
            GlassRenderer::DrawBarSpillFog(g, topGlassClip, 42.0f, 26.0f, 165.0f, true, 195);
            GlassRenderer::DrawGlyphHaloText(g, headerTitle, ff, 10.5f, RectF(32.0f, 3.0f, 210.0f, 16.0f), leftSf, Color(245, 240, 246, 255), 1.0f);

            // 右上角关闭按钮梯形暗雾：右侧收齐(10px)，左侧延伸至黄金分割点(68px)
            GlassRenderer::DrawBarSpillFog(g, topGlassClip, static_cast<float>(w - 38), 65.0f, 24.0f, true, m_hoverTab == 3 ? 225 : 185);
            GlassRenderer::DrawImageAlpha(g, m_winBtnsBmp.get(), RectF(w - 45, 4, 13, 13), 2 * 52, 0, 52, 52, m_hoverTab == 3 ? 1.0f : 0.88f, 1.18f);

            // 2. 底部内缩玻璃条：靠左显示“正在播放 · 来源名称”，悬停高亮，点击跳转定位
            auto info = m_controller.Store().GetPlayback();
            std::wstring sourceLabel;
            if (!info.contextTitle.empty()) {
                sourceLabel = L"正在播放 · " + info.contextTitle;
            } else if (!info.title.empty() && info.title != L"AirMuse Ready") {
                sourceLabel = L"正在播放 · " + info.title;
            }

            if (!sourceLabel.empty()) {
                RectF botGlassClip(3.0f, static_cast<float>(h - 20), static_cast<float>(w - 6), 18.0f);
                RectF botRect(32.0f, static_cast<float>(h - 19), static_cast<float>(w - 64), 16.0f);
                bool hoverBot = (m_hoverTab == 4);

                // 左侧收齐(12px)，右侧延伸至黄金分割点(195px)，上宽下窄倒梯形
                GlassRenderer::DrawBarSpillFog(g, botGlassClip, 42.0f, 26.0f, 180.0f, false, hoverBot ? 235 : 195);

                Color botColor = hoverBot ? Color(255, 185, 232, 255) : Color(245, 242, 246, 252);
                GlassRenderer::DrawGlyphHaloText(g, sourceLabel, ff, 10.5f, botRect, leftSf, botColor, 1.0f);
            }
        }
    }

    RECT rcWin{};
    GetWindowRect(m_hwnd, &rcWin);
    POINT ptDst{ rcWin.left, rcWin.top }, ptSrc{ 0, 0 };
    SIZE szWnd{ wPx, hPx };
    BLENDFUNCTION bf{ AC_SRC_OVER, 0, 255, AC_SRC_ALPHA };
    UpdateLayeredWindow(m_hwnd, hdcScreen, &ptDst, &szWnd, hdcMem, &ptSrc, 0, &bf, ULW_ALPHA);

    SelectObject(hdcMem, oldBmp);
    DeleteObject(hBmp);
    DeleteDC(hdcMem);
    ReleaseDC(nullptr, hdcScreen);
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
    case WM_WINDOWPOSCHANGED:
        m_dockMgr.SyncWebHostBounds();
        m_controller.ResizeWebHost(GlassRenderer::ToPx(312, m_dpi), GlassRenderer::ToPx(276, m_dpi));
        return DefWindowProcW(m_hwnd, msg, wParam, lParam);
    case WM_MOUSEMOVE: {
        m_hovering = true;
        int x = GlassRenderer::ToDip(GET_X_LPARAM(lParam), m_dpi);
        int y = GlassRenderer::ToDip(GET_Y_LPARAM(lParam), m_dpi);
        int hit = -1;
        if (Rect(275, 4, 14, 14).Contains(x, y)) hit = 3;
        if (Rect(30, 300, 260, 16).Contains(x, y)) hit = 4;
        if (hit != m_hoverTab) m_hoverTab = hit;
        Render();
        TRACKMOUSEEVENT tme{ sizeof(tme), TME_LEAVE, m_hwnd, 0 };
        TrackMouseEvent(&tme);
        return 0;
    }
    case WM_MOUSELEAVE:
        m_hovering = false;
        m_hoverTab = -1;
        Render();
        return 0;
    case WM_LBUTTONDOWN:
        if (m_hoverTab == 3) {
            SetVisible(false);
            return 0;
        }
        if (m_hoverTab == 4) {
            m_controller.JumpToPlayingContext();
            return 0;
        }
        ReleaseCapture();
        SendMessageW(m_hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
        return 0;
    case WM_WINDOWPOSCHANGING:
        m_dockMgr.OnLibraryMoving(reinterpret_cast<WINDOWPOS*>(lParam));
        return 0;
    }
    return DefWindowProcW(m_hwnd, msg, wParam, lParam);
}

} // namespace airmuse




