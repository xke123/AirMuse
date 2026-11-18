#include "LyricsWindow.hpp"
#include "GlassRenderer.hpp"
#include "../resource.h"
#include <windowsx.h>
#include <algorithm>
#include <cstdio>

using namespace Gdiplus;

namespace airmuse {

namespace {
constexpr UINT_PTR TIMER_LYRICS_FRAME = 1;
constexpr float LINE_STEP = 28.0f;
} // namespace

LyricsWindow::LyricsWindow(HINSTANCE hInst, AppController& controller, DockManager& dockMgr)
    : m_hInst(hInst), m_controller(controller), m_dockMgr(dockMgr) {
    MotionCoordinator::Instance().RegisterClient(this);
}

LyricsWindow::~LyricsWindow() {
    MotionCoordinator::Instance().UnregisterClient(this);
}

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
    if (visible) {
        if (!IsWindowVisible(m_hwnd)) {
            m_revealAnim.SnapTo(0.0f);
        }
        m_hiding = false;
        m_revealAnim.target = 1.0f;
        ShowWindow(m_hwnd, SW_SHOWNOACTIVATE);
        OnPlaybackOrLyricsChanged();
        EnsureFrameTimer();
    } else {
        if (!IsWindowVisible(m_hwnd)) return;
        m_hiding = true;
        m_revealAnim.target = 0.0f;
        EnsureFrameTimer();
    }
}

void LyricsWindow::SetMiniMode(bool mini) {
    m_mini = mini;
    m_winHeight.target = mini ? 30.0f : 216.0f;
    EnsureFrameTimer();
}

int LyricsWindow::ComputeStableActiveIndex(LyricsSnapshot const& lrc, int64_t livePosMs) {
    if (lrc.lines.empty()) {
        m_lastTrackKey = lrc.trackKey;
        m_lastActiveIdx = 0;
        return 0;
    }

    int rawIdx = 0;
    for (int i = 0; i < static_cast<int>(lrc.lines.size()); ++i) {
        if (lrc.lines[i].timeMs <= livePosMs + 150) rawIdx = i;
        else break;
    }

    if (lrc.trackKey != m_lastTrackKey || m_lastActiveIdx < 0 || m_lastActiveIdx >= static_cast<int>(lrc.lines.size())) {
        m_lastTrackKey = lrc.trackKey;
        m_lastActiveIdx = rawIdx;
        return rawIdx;
    }

    if (rawIdx < m_lastActiveIdx) {
        int64_t curLineTime = lrc.lines[m_lastActiveIdx].timeMs;
        if (livePosMs + 600 >= curLineTime) {
            return m_lastActiveIdx;
        }
    }

    m_lastActiveIdx = rawIdx;
    return rawIdx;
}

void LyricsWindow::EnsureFrameTimer() {
    MotionCoordinator::Instance().RequestFrame();
}

void LyricsWindow::OnPlaybackTick() {
    if (!m_hwnd || !IsWindowVisible(m_hwnd)) return;
    auto info = m_controller.Store().GetPlayback();
    auto lrc  = m_controller.Store().GetLyrics();
    int64_t livePosMs = info.EstimatedPositionMs() + lrc.offsetMs;
    int prevIdx = m_lastActiveIdx;
    int activeIdx = ComputeStableActiveIndex(lrc, livePosMs);
    std::wstring nextLine = !lrc.lines.empty() ? lrc.lines[activeIdx].text : lrc.statusText;
    bool changed = false;
    if (activeIdx != prevIdx) {
        m_scrollY.target = static_cast<float>(activeIdx) * LINE_STEP;
        changed = true;
    }
    if (nextLine != m_curMiniLine) {
        m_prevMiniLine = m_curMiniLine;
        m_curMiniLine = nextLine;
        if (m_mini && !m_prevMiniLine.empty()) {
            m_miniLyricSlide.SnapTo(0.0f);
            m_miniLyricSlide.target = 1.0f;
        }
        changed = true;
    }
    if (changed) EnsureFrameTimer();
}

void LyricsWindow::OnPlaybackOrLyricsChanged() {
    if (!m_hwnd || !IsWindowVisible(m_hwnd)) return;
    auto info = m_controller.Store().GetPlayback();
    auto lrc  = m_controller.Store().GetLyrics();
    int64_t livePosMs = info.EstimatedPositionMs() + lrc.offsetMs;
    int prevIdx = m_lastActiveIdx;
    bool trackChanged = (lrc.trackKey != m_lastTrackKey);
    int activeIdx = ComputeStableActiveIndex(lrc, livePosMs);
    std::wstring nextLine = !lrc.lines.empty() ? lrc.lines[activeIdx].text : lrc.statusText;

    if (trackChanged || activeIdx != prevIdx) {
        m_scrollY.target = static_cast<float>(activeIdx) * LINE_STEP;
        EnsureFrameTimer();
    }
    if (nextLine != m_curMiniLine) {
        m_prevMiniLine = m_curMiniLine;
        m_curMiniLine = nextLine;
        if (m_mini && !m_prevMiniLine.empty()) {
            m_miniLyricSlide.SnapTo(0.0f);
            m_miniLyricSlide.target = 1.0f;
        }
        EnsureFrameTimer();
    }
    Render();
}

bool LyricsWindow::StepMotion(float dt) {
    bool active = false;
    active |= m_winHeight.Step(dt);
    active |= m_scrollY.Step(dt);
    active |= m_miniLyricSlide.Step(dt);
    active |= m_revealAnim.Step(dt);
    active |= m_focusAnim.Step(dt);

    int w = 320;
    int h = static_cast<int>(std::round(m_winHeight.current));
    int wPx = GlassRenderer::ToPx(w, m_dpi);
    int hPx = GlassRenderer::ToPx(h, m_dpi);

    RECT rc{};
    GetWindowRect(m_hwnd, &rc);
    if ((rc.bottom - rc.top) != hPx) {
        SetWindowPos(m_hwnd, nullptr, 0, 0, wPx, hPx, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    if (!active) {
        if (m_hiding) {
            m_hiding = false;
            ShowWindow(m_hwnd, SW_HIDE);
            return false;
        }
        GlassRenderer::EnableFrostedBlur(m_hwnd, wPx, hPx, m_dpi, m_mini);
    }
    return active;
}

void LyricsWindow::OnMotionRender() {
    Render();
}

void LyricsWindow::StepAnimations(float dt) {
    if (StepMotion(dt)) {
        Render();
    }
}

void LyricsWindow::Render() {
    if (!m_hwnd || !IsWindowVisible(m_hwnd)) return;

    int w = 320;
    int h = static_cast<int>(std::round(m_winHeight.current));
    int wPx = GlassRenderer::ToPx(w, m_dpi);
    int hPx = GlassRenderer::ToPx(h, m_dpi);
    if (wPx <= 0 || hPx <= 0) return;

    float scale = static_cast<float>(m_dpi) / 96.0f;
    if (!m_surface.Ensure(wPx, hPx)) return;

    float rev = std::clamp(m_revealAnim.current, 0.0f, 1.0f);
    BYTE masterAlpha = static_cast<BYTE>(std::round(255.0f * rev));

    {
        Graphics g(m_surface.hdcMem);
        g.Clear(Color(0, 0, 0, 0));
        if (rev <= 0.01f) {
            m_surface.Present(m_hwnd, wPx, hPx, 0);
            return;
        }
        g.ScaleTransform(scale, scale);
        g.SetSmoothingMode(SmoothingModeHighQuality);
        g.SetTextRenderingHint(TextRenderingHintAntiAlias);

        if (rev < 0.995f) {
            DockSide side = m_dockMgr.LyricsDockSide();
            float wf = static_cast<float>(w);
            float hf = static_cast<float>(h);
            if (side == DockSide::Top) {
                g.SetClip(RectF(0.0f, hf * (1.0f - rev), wf, hf * rev));
                g.TranslateTransform(0.0f, (1.0f - rev) * hf * 0.45f);
            } else if (side == DockSide::Left) {
                g.SetClip(RectF(wf * (1.0f - rev), 0.0f, wf * rev, hf));
                g.TranslateTransform((1.0f - rev) * wf * 0.45f, 0.0f);
            } else if (side == DockSide::Right) {
                g.SetClip(RectF(0.0f, 0.0f, wf * rev, hf));
                g.TranslateTransform(-(1.0f - rev) * wf * 0.45f, 0.0f);
            } else {
                g.SetClip(RectF(0.0f, 0.0f, wf, hf * rev));
                g.TranslateTransform(0.0f, -(1.0f - rev) * hf * 0.45f);
            }
        }

        GlassRenderer::DrawAirPlayGlassFrame(g, w, h, m_mini && m_hovering ? 1.0f : 0.0f, m_focusAnim.current);

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

        int activeIdx = ComputeStableActiveIndex(lrc, livePosMs);

        if (h > 50) {
            if (m_hovering) {
                RectF topGlassClip(3.0f, 2.0f, static_cast<float>(w - 6), 18.0f);
                GlassRenderer::DrawBarSpillFog(g, topGlassClip, 42.0f, 26.0f, 155.0f, true, 195);
                GlassRenderer::DrawBarSpillFog(g, topGlassClip, static_cast<float>(w - 45), 72.0f, 30.0f, true, 215);

                wchar_t hdr[64];
                if (lrc.offsetMs != 0) swprintf_s(hdr, L"Lyrics (\u504f\u79fb %+.1fs)", lrc.offsetMs / 1000.0);
                else wcscpy_s(hdr, L"Lyrics (\u6eda\u8f6e\u5fae\u8c03\u5ef6\u8fdf)");
                SolidBrush hdrBrush(Color(240, 240, 246, 255));
                g.DrawString(hdr, -1, &transFont, RectF(32.0f, 3.0f, 165.0f, 14.0f), nullptr, &hdrBrush);

                GlassRenderer::DrawImageAlpha(g, m_winBtnsBmp.get(), RectF(static_cast<REAL>(w - 63), 4.0f, 13.0f, 13.0f), 7 * 52, 0, 52, 52, m_hoverBtn == 0 ? 1.0f : 0.85f, 1.15f);
                GlassRenderer::DrawImageAlpha(g, m_winBtnsBmp.get(), RectF(static_cast<REAL>(w - 45), 4.0f, 13.0f, 13.0f), 2 * 52, 0, 52, 52, m_hoverBtn == 1 ? 1.0f : 0.85f, 1.15f);
            }

            int bodyTop = 20, bodyBot = h - 20, bodyH = bodyBot - bodyTop;
            GraphicsState saved = g.Save();
            g.SetClip(Rect(8, bodyTop + 4, w - 16, bodyH - 8), CombineModeIntersect);

            if (lrc.lines.empty()) {
                SolidBrush mb(Color(165, 190, 200, 215));
                g.DrawString(lrc.statusText.c_str(), -1, &normalFont, RectF(14.0f, static_cast<REAL>(bodyTop + bodyH / 2 - 9), static_cast<REAL>(w - 28), 18.0f), &centerSf, &mb);
            } else {
                float centerY = static_cast<float>(bodyTop + bodyH / 2) - 10.0f;
                for (int i = 0; i < static_cast<int>(lrc.lines.size()); ++i) {
                    float y = centerY + (static_cast<float>(i) * LINE_STEP - m_scrollY.current);
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
            RectF miniGlassClip(4.5f, 3.5f, static_cast<float>(w - 9), static_cast<float>(h - 7));
            GraphicsState miniSaved = g.Save();
            g.SetClip(miniGlassClip, CombineModeIntersect);

            bool hasLyrics = !lrc.lines.empty();
            std::wstring curLine = hasLyrics ? lrc.lines[activeIdx].text : lrc.statusText;
            if (m_curMiniLine.empty()) m_curMiniLine = curLine;

            StringFormat vCenterSf;
            vCenterSf.SetAlignment(StringAlignmentCenter);
            vCenterSf.SetLineAlignment(StringAlignmentCenter);
            vCenterSf.SetTrimming(StringTrimmingEllipsisCharacter);
            vCenterSf.SetFormatFlags(StringFormatFlagsNoWrap);

            float baseAlpha = hasLyrics ? 1.0f : 0.85f;
            float p = std::clamp(m_miniLyricSlide.current, 0.0f, 1.0f);
            float slideDist = 18.0f;

            if (p < 0.98f && !m_prevMiniLine.empty()) {
                GlassRenderer::DrawGlyphHaloText(g, m_prevMiniLine, ff, 13.0f,
                                                 RectF(12.0f, 5.0f - p * slideDist, static_cast<REAL>(w - 24), static_cast<REAL>(h - 6)),
                                                 vCenterSf, Color(215, 212, 213, 215), baseAlpha * (1.0f - p));
            }
            if (p > 0.02f && !curLine.empty()) {
                GlassRenderer::DrawGlyphHaloText(g, curLine, ff, 13.0f,
                                                 RectF(12.0f, 5.0f + (1.0f - p) * slideDist, static_cast<REAL>(w - 24), static_cast<REAL>(h - 6)),
                                                 vCenterSf, Color(215, 212, 213, 215), baseAlpha * p);
            }
            g.Restore(miniSaved);
        }
    }
    m_surface.Present(m_hwnd, wPx, hPx, masterAlpha);
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
    case WM_ACTIVATE:
        m_focusAnim.target = (LOWORD(wParam) != WA_INACTIVE) ? 1.0f : 0.0f;
        EnsureFrameTimer();
        return 0;
    case WM_TIMER:
        if (wParam == TIMER_LYRICS_FRAME) {
            ULONGLONG now = GetTickCount64();
            float dt = static_cast<float>(now - m_lastFrameTick) / 1000.0f;
            m_lastFrameTick = now;
            StepAnimations(dt);
        }
        return 0;
    case WM_MOUSEMOVE: {
        bool wasHovering = m_hovering;
        int prevBtn = m_hoverBtn;
        m_hovering = true;
        int x = GlassRenderer::ToDip(GET_X_LPARAM(lParam), m_dpi);
        int y = GlassRenderer::ToDip(GET_Y_LPARAM(lParam), m_dpi);
        m_hoverBtn = Rect(320 - 63, 4, 13, 13).Contains(x, y) ? 0 : (Rect(320 - 45, 4, 13, 13).Contains(x, y) ? 1 : -1);
        TRACKMOUSEEVENT tme{ sizeof(tme), TME_LEAVE, m_hwnd, 0 };
        TrackMouseEvent(&tme);
        if (!wasHovering || prevBtn != m_hoverBtn) Render();
        return 0;
    }
    case WM_MOUSELEAVE:
        m_hovering = false;
        m_hoverBtn = -1;
        Render();
        return 0;
    case WM_LBUTTONDOWN:
        if (m_hoverBtn == 0) { SetMiniMode(!m_mini); return 0; }
        if (m_hoverBtn == 1) { SetVisible(false); return 0; }
        ReleaseCapture();
        SendMessageW(m_hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
        return 0;
    case WM_MOUSEWHEEL: {
        int delta = GET_WHEEL_DELTA_WPARAM(wParam);
        m_controller.AdjustLyricsOffset(delta > 0 ? 250 : -250);
        OnPlaybackOrLyricsChanged();
        return 0;
    }
    case WM_WINDOWPOSCHANGING:
        m_dockMgr.OnLyricsMoving(reinterpret_cast<WINDOWPOS*>(lParam));
        return 0;
    case WM_DESTROY:
        KillTimer(m_hwnd, TIMER_LYRICS_FRAME);
        return 0;
    }
    return DefWindowProcW(m_hwnd, msg, wParam, lParam);
}

} // namespace airmuse