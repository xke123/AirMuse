#include "LyricsWindow.hpp"
#include "GlassRenderer.hpp"
#include "../resource.h"
#include <windowsx.h>
#include <algorithm>
#include <cstdio>

using namespace Gdiplus;

namespace airmuse {

LyricsWindow::LyricsWindow(HINSTANCE hInst, AppController& controller, DockManager& dockMgr)
    : m_hInst(hInst), m_controller(controller), m_dockMgr(dockMgr) {}

HWND LyricsWindow::Create(HWND parentMain) {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.style = CS_DBLCLKS;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = m_hInst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = L"AirMuseLyricsWindow";
    RegisterClassExW(&wc);

    m_hwnd = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        wc.lpszClassName, L"AirMuse Lyrics", WS_POPUP,
        120, 222, 320, 216,
        parentMain, nullptr, m_hInst, this
    );
    return m_hwnd;
}

void LyricsWindow::SetVisible(bool visible) {
    ShowWindow(m_hwnd, visible ? SW_SHOWNOACTIVATE : SW_HIDE);
    if (visible) Render();
}

void LyricsWindow::SetMiniMode(bool mini) {
    m_mini = mini;
    m_winHeight.target = mini ? 30.0f : 216.0f;
    Render();
}

void LyricsWindow::Render() {
    if (!m_hwnd || !IsWindowVisible(m_hwnd)) return;

    m_winHeight.Step(0.016f);
    int w = 320;
    int h = static_cast<int>(std::round(m_winHeight.current));
    int wPx = GlassRenderer::ToPx(w, m_dpi);
    int hPx = GlassRenderer::ToPx(h, m_dpi);

    RECT rc{};
    GetWindowRect(m_hwnd, &rc);
    if ((rc.bottom - rc.top) != hPx) {
        SetWindowPos(m_hwnd, nullptr, 0, 0, wPx, hPx, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        GlassRenderer::EnableFrostedBlur(m_hwnd, wPx, hPx, m_dpi, m_mini);
        m_dockMgr.SyncAllDocked();
    }

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

        GlassRenderer::DrawAirPlayGlassFrame(g, w, h, m_mini && m_hovering ? 1.0f : 0.0f, true);

        auto info = m_controller.Store().GetPlayback();
        auto lrc  = m_controller.Store().GetLyrics();
        int64_t livePosMs = info.EstimatedPositionMs() + lrc.offsetMs;

        FontFamily ff(L"Microsoft YaHei");
        Font activeFont(&ff, 12.5f, FontStyleBold, UnitPixel);
        Font normalFont(&ff, 11.0f, FontStyleRegular, UnitPixel);
        Font transFont(&ff, 10.0f, FontStyleRegular, UnitPixel);
        StringFormat centerSf;
        centerSf.SetAlignment(StringAlignmentCenter);
        centerSf.SetTrimming(StringTrimmingEllipsisCharacter);
        centerSf.SetFormatFlags(StringFormatFlagsNoWrap);

        int activeIdx = 0;
        for (int i = 0; i < static_cast<int>(lrc.lines.size()); ++i) {
            if (lrc.lines[i].timeMs <= livePosMs + 150) activeIdx = i;
            else break;
        }

        if (h > 50) {
            if (m_hovering) {
                RectF topGlassClip(3.0f, 2.0f, static_cast<float>(w - 6), 18.0f);
                GlassRenderer::DrawBarSpillFog(g, topGlassClip, 42.0f, 26.0f, 155.0f, true, 195);
                GlassRenderer::DrawBarSpillFog(g, topGlassClip, static_cast<float>(w - 45), 72.0f, 30.0f, true, 215);

                wchar_t hdr[64];
                if (lrc.offsetMs != 0) swprintf_s(hdr, L"Lyrics (偏移 %+.1fs)", lrc.offsetMs / 1000.0);
                else wcscpy_s(hdr, L"Lyrics (滚轮微调延迟)");
                SolidBrush hdrBrush(Color(240, 240, 246, 255));
                g.DrawString(hdr, -1, &transFont, RectF(32.0f, 3.0f, 165.0f, 14.0f), nullptr, &hdrBrush);

                GlassRenderer::DrawImageAlpha(g, m_winBtnsBmp.get(), RectF(w - 63, 4, 13, 13), 7 * 52, 0, 52, 52, m_hoverBtn == 0 ? 1.0f : 0.85f, 1.15f);
                GlassRenderer::DrawImageAlpha(g, m_winBtnsBmp.get(), RectF(w - 45, 4, 13, 13), 2 * 52, 0, 52, 52, m_hoverBtn == 1 ? 1.0f : 0.85f, 1.15f);
            }

            int bodyTop = 20, bodyBot = h - 20, bodyH = bodyBot - bodyTop;
            GraphicsState saved = g.Save();
            g.SetClip(Rect(8, bodyTop + 4, w - 16, bodyH - 8));

            if (lrc.lines.empty()) {
                SolidBrush mb(Color(165, 190, 200, 215));
                g.DrawString(lrc.statusText.c_str(), -1, &normalFont, RectF(14.0f, static_cast<REAL>(bodyTop + bodyH / 2 - 9), static_cast<REAL>(w - 28), 18.0f), &centerSf, &mb);
            } else {
                const float lineStep = 28.0f;
                m_scrollY.target = static_cast<float>(activeIdx) * lineStep;
                m_scrollY.Step(0.016f);

                float centerY = static_cast<float>(bodyTop + bodyH / 2) - 10.0f;
                for (int i = 0; i < static_cast<int>(lrc.lines.size()); ++i) {
                    float y = centerY + (static_cast<float>(i) * lineStep - m_scrollY.current);
                    if (y < bodyTop - 26 || y > bodyBot + 4) continue;

                    float dist = std::abs(y - centerY) / (static_cast<float>(bodyH) * 0.5f);
                    float edgeFade = std::clamp(1.15f - dist * 0.95f, 0.12f, 1.0f);

                    if (i == activeIdx) {
                        SolidBrush ab(Color(static_cast<BYTE>(252 * edgeFade), 175, 225, 255));
                        g.DrawString(lrc.lines[i].text.c_str(), -1, &activeFont, RectF(14.0f, y, static_cast<REAL>(w - 28), 18.0f), &centerSf, &ab);
                        if (!lrc.lines[i].trans.empty()) {
                            SolidBrush tb(Color(static_cast<BYTE>(190 * edgeFade), 160, 195, 220));
                            g.DrawString(lrc.lines[i].trans.c_str(), -1, &transFont, RectF(14.0f, y + 17.0f, static_cast<REAL>(w - 28), 14.0f), &centerSf, &tb);
                        }
                    } else {
                        SolidBrush nb(Color(static_cast<BYTE>(155 * edgeFade), 205, 212, 224));
                        g.DrawString(lrc.lines[i].text.c_str(), -1, &normalFont, RectF(14.0f, y + 1.0f, static_cast<REAL>(w - 28), 16.0f), &centerSf, &nb);
                    }
                }
            }
            g.Restore(saved);
        } else {
            std::wstring curLine = lrc.lines.empty() ? lrc.statusText : lrc.lines[activeIdx].text;
            GlassRenderer::DrawGlyphHaloText(g, curLine, ff, 11.5f, RectF(14.0f, 4.0f, static_cast<REAL>(w - 28), 18.0f),
                                             centerSf, Color(245, 215, 238, 255), 1.0f);
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

LRESULT CALLBACK LyricsWindow::WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    LyricsWindow* self = nullptr;
    if (msg == WM_CREATE) {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
        self = static_cast<LyricsWindow*>(cs->lpCreateParams);
        self->m_hwnd = hwnd;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    } else {
        self = reinterpret_cast<LyricsWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    }
    return self ? self->HandleMessage(msg, wParam, lParam) : DefWindowProcW(hwnd, msg, wParam, lParam);
}

LRESULT LyricsWindow::HandleMessage(UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE:
        m_dpi = GetDpiForWindow(m_hwnd);
        if (m_dpi == 0) m_dpi = 96;
        m_winBtnsBmp = GlassRenderer::LoadPngResource(m_hInst, IDR_PNG_WINDOWBUTTON);
        GlassRenderer::EnableFrostedBlur(m_hwnd, GlassRenderer::ToPx(320, m_dpi), GlassRenderer::ToPx(216, m_dpi), m_dpi, false);
        return 0;
    case WM_MOUSEMOVE: {
        m_hovering = true;
        int x = GlassRenderer::ToDip(GET_X_LPARAM(lParam), m_dpi);
        int y = GlassRenderer::ToDip(GET_Y_LPARAM(lParam), m_dpi);
        m_hoverBtn = Rect(320 - 63, 4, 13, 13).Contains(x, y) ? 0 : (Rect(320 - 45, 4, 13, 13).Contains(x, y) ? 1 : -1);
        TRACKMOUSEEVENT tme{ sizeof(tme), TME_LEAVE, m_hwnd, 0 };
        TrackMouseEvent(&tme);
        Render();
        return 0;
    }
    case WM_MOUSELEAVE:
        m_hovering = false;
        m_hoverBtn = -1;
        Render();
        return 0;
    case WM_LBUTTONDOWN:
        if (m_hoverBtn == 0) { SetMiniMode(!m_mini); return 0; }
        if (m_hoverBtn == 1) { ShowWindow(m_hwnd, SW_HIDE); return 0; }
        ReleaseCapture();
        SendMessageW(m_hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
        return 0;
    case WM_MOUSEWHEEL: {
        int delta = GET_WHEEL_DELTA_WPARAM(wParam);
        m_controller.AdjustLyricsOffset(delta > 0 ? 250 : -250);
        Render();
        return 0;
    }
    case WM_WINDOWPOSCHANGING:
        m_dockMgr.OnLyricsMoving(reinterpret_cast<WINDOWPOS*>(lParam));
        return 0;
    }
    return DefWindowProcW(m_hwnd, msg, wParam, lParam);
}

} // namespace airmuse




