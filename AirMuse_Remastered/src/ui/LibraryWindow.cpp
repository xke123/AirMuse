#include "LibraryWindow.hpp"
#include "GlassRenderer.hpp"
#include "../resource.h"
#include <windowsx.h>
#include <string>
#include <algorithm>

using namespace Gdiplus;

namespace airmuse {

LibraryWindow::LibraryWindow(HINSTANCE hInst, AppController& controller, DockManager& dockMgr)
    : m_hInst(hInst), m_controller(controller), m_dockMgr(dockMgr) {
    MotionCoordinator::Instance().RegisterClient(this);
}

LibraryWindow::~LibraryWindow() {
    MotionCoordinator::Instance().UnregisterClient(this);
}

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

    int startX = 120 + DEFAULT_WIDTH_DIP, startY = 120;
    if (parentMain) {
        RECT rcMain{};
        GetWindowRect(parentMain, &rcMain);
        startX = rcMain.right;
        startY = rcMain.top;
    }

    m_hwnd = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        wc.lpszClassName, L"AirMuse Library", WS_POPUP,
        startX, startY, DEFAULT_WIDTH_DIP, DEFAULT_HEIGHT_DIP,
        parentMain, nullptr, m_hInst, this
    );

    // WebView2 前台视口：严格嵌入在中间内容区
    m_webHostHwnd = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        wcHost.lpszClassName, L"AirMuse WebHost", WS_POPUP,
        startX + 5, startY + 20, DEFAULT_WIDTH_DIP - 10, DEFAULT_HEIGHT_DIP - 40,
        m_hwnd, nullptr, m_hInst, nullptr
    );

    return m_hwnd;
}

void LibraryWindow::SetVisible(bool visible) {
    if (visible) {
        if (!IsWindowVisible(m_hwnd)) {
            m_animTime = 0.0f;
            m_animProgress = 0.0f;
        }
        m_hiding = false;
        m_animTarget = 1.0f;
        m_dockMgr.SyncAllDocked();
        ShowWindow(m_hwnd, SW_SHOWNOACTIVATE);
        ShowWindow(m_webHostHwnd, SW_HIDE);
        m_controller.SetWebVisible(true);
        m_lastActiveOrHover = true;
        Render();
        MotionCoordinator::Instance().RequestFrame();
    } else {
        if (!IsWindowVisible(m_hwnd)) return;
        m_hiding = true;
        m_animTarget = 0.0f;
        ShowWindow(m_webHostHwnd, SW_HIDE);
        m_controller.SetWebVisible(false);
        MotionCoordinator::Instance().RequestFrame();
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
    float target = active ? 1.0f : 0.0f;
    if (m_focusAnim.target != target) {
        m_focusAnim.target = target;
        MotionCoordinator::Instance().RequestFrame();
    }
}

bool LibraryWindow::StepMotion(float dt) {
    bool active = false;
    active |= m_focusAnim.Step(dt);

    if (m_animTarget > 0.5f) {
        if (m_animTime < m_animDuration) {
            m_animTime = std::min(m_animDuration, m_animTime + dt);
            active = true;
        }
    } else {
        if (m_animTime > 0.0f) {
            m_animTime = std::max(0.0f, m_animTime - dt);
            active = true;
        }
    }
    m_animProgress = (m_animDuration > 0.0f) ? std::clamp(m_animTime / m_animDuration, 0.0f, 1.0f) : m_animTarget;

    // WebView2 前台视口与展开联动：在卷轴展开接近完成（>= 0.92）时显示前台页面，在收起过程中保持隐藏
    if (m_animTarget > 0.5f && m_animProgress >= 0.92f) {
        if (m_webHostHwnd && !IsWindowVisible(m_webHostHwnd)) {
            m_dockMgr.SyncWebHostBounds();
            ShowWindow(m_webHostHwnd, SW_SHOWNOACTIVATE);
        }
    } else {
        if (m_webHostHwnd && IsWindowVisible(m_webHostHwnd)) {
            ShowWindow(m_webHostHwnd, SW_HIDE);
        }
    }

    if (!active) {
        if (m_hiding && m_animProgress <= 0.005f) {
            m_hiding = false;
            ShowWindow(m_hwnd, SW_HIDE);
            if (m_webHostHwnd) ShowWindow(m_webHostHwnd, SW_HIDE);
            return false;
        }
    }
    return active;
}

void LibraryWindow::OnMotionRender() {
    Render();
}

void LibraryWindow::Render() {
    if (!m_hwnd || !IsWindowVisible(m_hwnd)) return;
    int w = DEFAULT_WIDTH_DIP, h = DEFAULT_HEIGHT_DIP;
    int wPx = GlassRenderer::ToPx(w, m_dpi);
    int hPx = GlassRenderer::ToPx(h, m_dpi);
    float scale = static_cast<float>(m_dpi) / 96.0f;

    if (!m_surface.Ensure(wPx, hPx)) return;

    float animT = m_animProgress;
    if (animT <= 0.005f) {
        m_surface.Present(m_hwnd, wPx, hPx, 0);
        return;
    }

    {
        Graphics g(m_surface.hdcMem);
        g.Clear(Color(0, 0, 0, 0));
        g.ScaleTransform(scale, scale);
        g.SetSmoothingMode(SmoothingModeHighQuality);
        g.SetTextRenderingHint(TextRenderingHintAntiAlias);

        float focus = m_focusAnim.current;
        float barAlpha = 1.0f;
        float yBot = static_cast<float>(h - 20);

        if (animT < 0.999f) {
            GlassRenderer::DrawScrollGlassFrame(g, w, h, animT, 0.0f, focus, 2);

            if (animT <= 0.52f) {
                m_surface.Present(m_hwnd, wPx, hPx, 255);
                return;
            }

            barAlpha = std::clamp((animT - 0.52f) / 0.18f, 0.0f, 1.0f);
            const float barH = 20.0f;
            if (animT <= 0.70f) {
                float u = (animT - 0.52f) / 0.18f;
                float s = 3.0f * u * u - 2.0f * u * u * u;
                yBot = s * barH;
            } else {
                float p = (animT - 0.70f) / 0.30f;
                float s = 3.0f * p * p - 2.0f * p * p * p;
                yBot = barH + s * (static_cast<float>(h) - 2.0f * barH);
            }
        } else {
            GlassRenderer::DrawAirPlayGlassFrame(g, w, h, 0.0f, focus);
        }

        // 平滑渐显/渐隐顶部与底部的玻璃条文字及按钮
        float effAlpha = focus * barAlpha;
        if (effAlpha > 0.01f) {
            FontFamily ff(L"Microsoft YaHei UI");
            StringFormat leftSf;
            leftSf.SetAlignment(StringAlignmentNear);
            leftSf.SetLineAlignment(StringAlignmentCenter);
            leftSf.SetTrimming(StringTrimmingEllipsisCharacter);
            leftSf.SetFormatFlags(StringFormatFlagsNoWrap);

            // 2. 顶部玻璃条 (Y: 0 ~ 20 DIP)
            RectF topGlassClip(5.0f, 2.0f, static_cast<float>(w - 10), 18.0f);

            WebPlatform cur = m_controller.CurrentWebPlatform();
            std::wstring svcName = (cur == WebPlatform::Spotify) ? L"Spotify" : (cur == WebPlatform::QQMusic ? L"QQ 音乐" : L"Apple Music");
            std::wstring userName = m_controller.CurrentWebUserName();
            std::wstring headerTitle = userName.empty() ? (L"未登录的 " + svcName) : (userName + L" 的 " + svcName);

            // 标题光晕与文字 (随 effAlpha 平滑呼吸)
            BYTE topFogAlpha = static_cast<BYTE>(std::round(195.0f * effAlpha));
            GlassRenderer::DrawBarSpillFog(g, topGlassClip, 42.0f, 26.0f, 165.0f, true, topFogAlpha);
            GlassRenderer::DrawGlyphHaloText(g, headerTitle, ff, 10.5f, RectF(32.0f, 3.0f, static_cast<float>(w - 75), 16.0f), leftSf, Color(201, 201, 201), effAlpha);

            // 右上角关闭按钮 (悬停高亮 + 平滑淡入淡出)
            bool hoverClose = (m_hoverTab == 3);
            BYTE closeFogAlpha = static_cast<BYTE>(std::round((hoverClose ? 225.0f : 185.0f) * effAlpha));
            GlassRenderer::DrawBarSpillFog(g, topGlassClip, static_cast<float>(w - 38), 65.0f, 24.0f, true, closeFogAlpha);
            GlassRenderer::DrawImageAlpha(g, m_winBtnsBmp.get(), RectF(static_cast<REAL>(w - 45), 4.0f, 13.0f, 13.0f), 2 * 52, 0, 52, 52, (hoverClose ? 1.0f : 0.88f) * effAlpha, 1.18f);

            // 3. 底部玻璃条 (跟随 yBot 动态移动)
            auto info = m_controller.Store().GetPlayback();
            std::wstring sourceLabel = L"Apple Music 就绪";
            if (!info.contextTitle.empty()) {
                sourceLabel = L"正在播放 · " + info.contextTitle;
            } else if (!info.title.empty() && info.title != L"AirMuse Ready") {
                sourceLabel = L"正在播放 · " + info.title + (info.artist.empty() ? L"" : (L" - " + info.artist));
            }

            RectF botGlassClip(5.0f, yBot, static_cast<float>(w - 10), 18.0f);
            bool hoverBot = (m_hoverTab == 4);
            BYTE botFogAlpha = static_cast<BYTE>(std::round((hoverBot ? 235.0f : 195.0f) * effAlpha));
            GlassRenderer::DrawBarSpillFog(g, botGlassClip, 42.0f, 26.0f, 180.0f, false, botFogAlpha);

            RectF botRect(16.0f, yBot + 2.0f, static_cast<float>(w - 32), 16.0f);
            Color botColor = hoverBot ? Color(255, 201, 201, 201) : Color(245, 166, 166, 166);
            GlassRenderer::DrawGlyphHaloText(g, sourceLabel, ff, 9.5f, botRect, leftSf, botColor, effAlpha);
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
        GlassRenderer::EnableFrostedBlur(m_hwnd, GlassRenderer::ToPx(DEFAULT_WIDTH_DIP, m_dpi), GlassRenderer::ToPx(DEFAULT_HEIGHT_DIP, m_dpi), m_dpi, false);
        return 0;

    case WM_ACTIVATE:
        m_focused = (LOWORD(wParam) != WA_INACTIVE);
        RefreshHoverIfChanged();
        return 0;

    case WM_WINDOWPOSCHANGED:
        m_dockMgr.SyncWebHostBounds();
        m_controller.ResizeWebHost(GlassRenderer::ToPx(DEFAULT_WIDTH_DIP - 10, m_dpi), GlassRenderer::ToPx(DEFAULT_HEIGHT_DIP - 40, m_dpi));
        return DefWindowProcW(m_hwnd, msg, wParam, lParam);

    case WM_MOUSEMOVE: {
        m_hovering = true;
        int x = GlassRenderer::ToDip(GET_X_LPARAM(lParam), m_dpi);
        int y = GlassRenderer::ToDip(GET_Y_LPARAM(lParam), m_dpi);
        int hit = -1;
        if (x >= DEFAULT_WIDTH_DIP - 48 && x <= DEFAULT_WIDTH_DIP - 24 && y >= 0 && y <= 20) hit = 3; // 关闭按钮
        if (y >= DEFAULT_HEIGHT_DIP - 20 && y <= DEFAULT_HEIGHT_DIP) hit = 4;                           // 底部播放条
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
