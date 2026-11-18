#include "MainWindow.hpp"
#include "LyricsWindow.hpp"
#include "LibraryWindow.hpp"
#include "GlassRenderer.hpp"
#include "../resource.h"
#include <windowsx.h>
#include <algorithm>
#include <cstdio>

using namespace Gdiplus;

namespace airmuse {

namespace {
constexpr UINT_PTR TIMER_CLOCK = 1;
constexpr UINT_PTR TIMER_FRAME = 2;

enum BtnId {
    BTN_STOP = 0, BTN_PREV, BTN_PLAYPAUSE, BTN_NEXT, BTN_EJECT,
    BTN_MINIMIZE, BTN_MINI_TOGGLE, BTN_TOPMOST, BTN_CLOSE,
    BTN_PROGRESS, BTN_VOL_BAR, BTN_LYRICS, BTN_LIBRARY,
    BTN_SRC_APPLE, BTN_SRC_SPOTIFY, BTN_SRC_QQ, BTN_MINI_SRC
};

std::wstring FormatMs(int64_t ms) {
    if (ms < 0) ms = 0;
    int sec = static_cast<int>(ms / 1000);
    wchar_t buf[16];
    swprintf_s(buf, L"%02d:%02d", sec / 60, sec % 60);
    return buf;
}
} // namespace

MainWindow::MainWindow(HINSTANCE hInst, AppController& controller, DockManager& dockMgr)
    : m_hInst(hInst), m_controller(controller), m_dockMgr(dockMgr) {}

MainWindow::~MainWindow() = default;

void MainWindow::BindChildWindows(LyricsWindow* lyricsWnd, LibraryWindow* libraryWnd) {
    m_lyricsWnd = lyricsWnd;
    m_libraryWnd = libraryWnd;
}

void MainWindow::InvalidateBgCache() {
    m_bgCacheBmp.reset();
    m_bgCacheW = 0;
    m_bgCacheH = 0;
}

std::vector<std::wstring> MainWindow::GetMiniCycleItems(NowPlayingState const& info) const {
    std::vector<std::wstring> items;
    if (!info.title.empty()) items.push_back(info.title);
    if (!info.artist.empty()) items.push_back(info.artist);
    if (!info.album.empty()) items.push_back(info.album);
    if (items.empty()) items.push_back(L"AirMuse Ready");
    return items;
}

HWND MainWindow::Create() {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.style = CS_DBLCLKS;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = m_hInst;
    wc.hIcon = LoadIconW(m_hInst, MAKEINTRESOURCEW(IDR_MAIN_ICON));
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = L"AirMuseMainWindow";
    RegisterClassExW(&wc);

    m_hwnd = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        wc.lpszClassName, L"AirMuse", WS_POPUP,
        120, 120, DEFAULT_WIDTH_DIP, DEFAULT_HEIGHT_DIP,
        nullptr, nullptr, m_hInst, this
    );
    return m_hwnd;
}

void MainWindow::StartIntroSequence() {
    m_introActive = true;
    m_pendingStartupPanels = true;
    m_introStartTick = GetTickCount64();
    m_introProgress = 0.0f;
    m_introTime = 0.0f;
    Render();
    EnsureFrameTimer();
}

void MainWindow::BuildUIElements() {
    m_buttons.clear();
    auto addBtn = [&](int id, bool circle, std::function<void()> cb) {
        UIButton b;
        b.id = id;
        b.hitCircle = circle;
        b.onClick = std::move(cb);
        m_buttons.push_back(std::move(b));
    };

    addBtn(BTN_STOP,        true,  [this]() { m_controller.Stop(); });
    addBtn(BTN_PREV,        true,  [this]() { m_controller.Previous(); });
    addBtn(BTN_PLAYPAUSE,   true,  [this]() { m_controller.PlayPause(); });
    addBtn(BTN_NEXT,        true,  [this]() { m_controller.Next(); });
    addBtn(BTN_EJECT,       true,  [this]() { SetLibraryVisible(!m_libVisible); });
    addBtn(BTN_MINIMIZE,    false, [this]() {
        ShowWindow(m_hwnd, SW_HIDE);
        if (m_lyricsWnd) ShowWindow(m_lyricsWnd->Hwnd(), SW_HIDE);
        if (m_libraryWnd) m_libraryWnd->SetVisible(false);
    });
    addBtn(BTN_MINI_TOGGLE, false, [this]() { ToggleMiniMode(); });
    addBtn(BTN_TOPMOST,     false, [this]() {
        m_topMost = !m_topMost;
        HWND z = m_topMost ? HWND_TOPMOST : HWND_NOTOPMOST;
        SetWindowPos(m_hwnd, z, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
        if (m_lyricsWnd) SetWindowPos(m_lyricsWnd->Hwnd(), z, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        if (m_libraryWnd) m_libraryWnd->SetTopMost(m_topMost);
        Render();
    });
    addBtn(BTN_CLOSE,       false, []() { PostQuitMessage(0); });
    addBtn(BTN_PROGRESS,    false, nullptr);
    addBtn(BTN_VOL_BAR,     false, nullptr);
    addBtn(BTN_LYRICS,      false, [this]() { SetLyricsVisible(!m_lyricsVisible); });
    addBtn(BTN_LIBRARY,     false, [this]() { SetLibraryVisible(!m_libVisible); });
    addBtn(BTN_SRC_APPLE,   false, [this]() { m_controller.SwitchWebPlatform(WebPlatform::AppleMusic); if (!m_libVisible) SetLibraryVisible(true); else if (m_libraryWnd) m_libraryWnd->Render(); Render(); });
    addBtn(BTN_SRC_SPOTIFY, false, [this]() { m_controller.SwitchWebPlatform(WebPlatform::Spotify);    if (!m_libVisible) SetLibraryVisible(true); else if (m_libraryWnd) m_libraryWnd->Render(); Render(); });
    addBtn(BTN_SRC_QQ,      false, [this]() { m_controller.SwitchWebPlatform(WebPlatform::QQMusic);    if (!m_libVisible) SetLibraryVisible(true); else if (m_libraryWnd) m_libraryWnd->Render(); Render(); });
    addBtn(BTN_MINI_SRC,    false, [this]() { SetLibraryVisible(!m_libVisible); });
}

void MainWindow::UpdateLayout(float w, float h) {
    bool isMini = (h < 50.0f);
    for (auto& b : m_buttons) {
        b.visible = true;
        if (!isMini) {
            float startX = (w - 166.0f) * 0.5f;
            float xs[5] = { startX, startX + 32, startX + 67, startX + 102, startX + 134 };
            if (b.id >= BTN_STOP && b.id <= BTN_EJECT) { b.bounds = RectF(xs[b.id], 26.0f, 32.0f, 32.0f); b.hitCircle = true; }
            else if (b.id == BTN_MINIMIZE)    b.bounds = RectF(w - 93, 4, 13, 13);
            else if (b.id == BTN_MINI_TOGGLE) b.bounds = RectF(w - 77, 8, 13, 13);
            else if (b.id == BTN_TOPMOST)     b.bounds = RectF(w - 61, 4, 13, 13);
            else if (b.id == BTN_CLOSE)       b.bounds = RectF(w - 45, 8, 13, 13);
            else if (b.id == BTN_PROGRESS)    b.bounds = RectF(68, 64, w - 136, 14);
            else if (b.id == BTN_VOL_BAR)     b.bounds = RectF(w - 25, 42, 16, 38);
            else if (b.id == BTN_LIBRARY)     b.bounds = RectF(w - 63, h - 17, 13, 13);
            else if (b.id == BTN_LYRICS)      b.bounds = RectF(w - 45, h - 17, 13, 13);
            else if (b.id == BTN_SRC_APPLE)   b.bounds = RectF(32, h - 17, 13, 13);
            else if (b.id == BTN_SRC_SPOTIFY) b.bounds = RectF(50, h - 17, 13, 13);
            else if (b.id == BTN_SRC_QQ)      b.bounds = RectF(68, h - 17, 13, 13);
            else if (b.id == BTN_MINI_SRC)    b.visible = false;
        } else {
            float startX = (w - 92.0f) * 0.5f;
            float xs[5] = { startX, startX + 18, startX + 37, startX + 56, startX + 74 };
            if (b.id >= BTN_STOP && b.id <= BTN_EJECT) { b.bounds = RectF(xs[b.id], 7.0f, 16.0f, 16.0f); b.hitCircle = false; }
            else if (b.id == BTN_LYRICS)      b.bounds = RectF(w - 61, 8, 13, 13);
            else if (b.id == BTN_MINI_TOGGLE) b.bounds = RectF(w - 77, 8, 13, 13);
            else if (b.id == BTN_CLOSE)       b.bounds = RectF(w - 45, 8, 13, 13);
            else if (b.id == BTN_MINI_SRC)    b.bounds = RectF(45, 8, 13, 13);
            else b.visible = false;
        }
    }
}

void MainWindow::ToggleMiniMode() {
    bool nextMini = !m_miniMode;
    if (nextMini && m_libVisible) {
        SetLibraryVisible(false);
    }
    m_miniMode = nextMini;
    m_dockMgr.SetMiniMode(m_miniMode);
    m_winWidth.target  = static_cast<float>(DEFAULT_WIDTH_DIP);
    m_winHeight.target = m_miniMode ? 30.0f : static_cast<float>(DEFAULT_HEIGHT_DIP);
    if (m_miniMode) {
        m_miniFieldIdx = 0;
        m_miniCycleTick = GetTickCount64();
        auto items = GetMiniCycleItems(m_controller.Store().GetPlayback());
        m_curMiniLine = items[0];
        m_prevMiniLine.clear();
        m_miniTextSlide.SnapTo(1.0f);
    }
    if (m_lyricsWnd && m_dockMgr.LyricsDockSide() != DockSide::None) {
        m_lyricsWnd->SetMiniMode(m_miniMode);
    }
    EnsureFrameTimer();
}

void MainWindow::SetLyricsVisible(bool visible) {
    m_lyricsVisible = visible;
    if (m_lyricsWnd) {
        if (visible && m_dockMgr.LyricsDockSide() != DockSide::None) {
            m_lyricsWnd->SetMiniMode(m_miniMode);
        }
        m_lyricsWnd->SetVisible(visible);
        if (visible) m_dockMgr.SyncAllDocked();
    }
    Render();
}

void MainWindow::SetLibraryVisible(bool visible) {
    m_libVisible = visible;
    if (m_libraryWnd) {
        m_libraryWnd->SetVisible(visible);
        if (visible) m_dockMgr.SyncAllDocked();
    }
    Render();
}

void MainWindow::EnsureFrameTimer() {
    MotionCoordinator::Instance().RequestFrame();
}

bool MainWindow::StepMotion(float dt) {
    bool active = false;

    if (m_introActive) {
        m_introTime += dt;
        if (m_introTime >= m_animDuration) {
            m_introProgress = 1.0f;
            m_introActive = false;
        } else {
            m_introProgress = (m_animDuration > 0.0f) ? std::clamp(m_introTime / m_animDuration, 0.0f, 1.0f) : 1.0f;
        }
        active = true;

        if (m_pendingStartupPanels && m_introProgress >= 0.88f) {
            m_pendingStartupPanels = false;
            SetLyricsVisible(true);
            SetLibraryVisible(true);
        }
    }

    active |= m_winWidth.Step(dt);
    active |= m_winHeight.Step(dt);
    active |= m_hoverPanel.Step(dt);
    active |= m_miniTextSlide.Step(dt);
    active |= m_focusAnim.Step(dt);

    bool sweepActive = false;
    for (auto it = m_sweeps.begin(); it != m_sweeps.end();) {
        it->progress += dt * it->speed;
        if (it->progress >= 1.0f) {
            it = m_sweeps.erase(it);
        } else {
            sweepActive = true;
            ++it;
        }
    }
    active |= sweepActive;

    for (auto& b : m_buttons) {
        b.hoverAnim.target = (m_hoverBtnId == b.id) ? 1.0f : 0.0f;
        b.pressAnim.target = (m_pressedBtnId == b.id) ? 0.90f : 1.0f;
        active |= b.UpdatePhysics(dt);
    }

    int wPx = GlassRenderer::ToPx(static_cast<int>(std::round(m_winWidth.current)), m_dpi);
    int hPx = GlassRenderer::ToPx(static_cast<int>(std::round(m_winHeight.current)), m_dpi);
    RECT rc{};
    GetWindowRect(m_hwnd, &rc);
    if ((rc.right - rc.left) != wPx || (rc.bottom - rc.top) != hPx) {
        SetWindowPos(m_hwnd, nullptr, 0, 0, wPx, hPx, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        m_dockMgr.SyncAllDocked();
    }

    if (!active) {
        GlassRenderer::EnableFrostedBlur(m_hwnd, wPx, hPx, m_dpi, m_winHeight.current < 45.0f);
    }
    return active;
}

void MainWindow::OnMotionRender() {
    Render();
}

void MainWindow::StepAnimations(float dt) {
    if (StepMotion(dt)) {
        Render();
    }
}

void MainWindow::TriggerSweep(float startPos, float endPos, float speed, float originX) {
    SpecularSweep s;
    s.active = true;
    s.startPos = startPos;
    s.endPos = endPos;
    s.progress = 0.0f;
    s.speed = speed;
    s.originX = originX;
    if (m_sweeps.size() >= 2) {
        m_sweeps.erase(m_sweeps.begin());
    }
    m_sweeps.push_back(s);
    MotionCoordinator::Instance().RequestFrame();
}

void MainWindow::Render() {
    int w = static_cast<int>(std::round(m_winWidth.current));
    int h = static_cast<int>(std::round(m_winHeight.current));
    if (w <= 0 || h <= 0) return;

    UpdateLayout(static_cast<float>(w), static_cast<float>(h));

    NowPlayingState info = m_controller.Store().GetPlayback();
    std::wstring trackKey = info.TrackKey();
    if (trackKey != m_cachedArtKey) {
        m_cachedArtKey = trackKey;
        m_artworkBmp = GlassRenderer::DecodeArtworkBitmap(info.artworkBytes);
        InvalidateBgCache();

        auto items = GetMiniCycleItems(info);
        m_miniFieldIdx = 0;
        m_miniCycleTick = GetTickCount64();
        m_prevMiniLine = m_curMiniLine;
        m_curMiniLine = items[0];
        if (m_miniMode && !m_prevMiniLine.empty() && m_prevMiniLine != m_curMiniLine) {
            m_miniTextSlide.SnapTo(0.0f);
            m_miniTextSlide.target = 1.0f;
            EnsureFrameTimer();
        }
    }

    int wPx = GlassRenderer::ToPx(w, m_dpi);
    int hPx = GlassRenderer::ToPx(h, m_dpi);
    float scale = static_cast<float>(m_dpi) / 96.0f;

    if (!m_surface.Ensure(wPx, hPx)) return;

    BYTE masterAlpha = 255;
    {
        Graphics g(m_surface.hdcMem);
        g.Clear(Color(0, 0, 0, 0));
        g.ScaleTransform(scale, scale);
        g.SetSmoothingMode(SmoothingModeHighQuality);
        g.SetTextRenderingHint(TextRenderingHintAntiAlias);
        g.SetInterpolationMode(m_animating ? InterpolationModeBilinear : InterpolationModeHighQualityBicubic);

        float hoverAlpha = m_hoverPanel.current;
        float focusRatio = m_focusAnim.current;

        GraphicsState introClipState{};
        bool hasIntroClip = false;

        if (m_introActive && m_introProgress < 0.999f) {
            float animT = m_introProgress;
            // 绘制带有阶段物理逻辑（球 -> 拉伸 -> 分裂 -> 双向卷轴展开）的水晶玻璃外框与深色基底 (Mode 1: 双向展开)
            GlassRenderer::DrawScrollGlassFrame(g, w, h, animT, 0.0f, focusRatio, 1, m_artworkBmp.get());

            if (animT <= 0.70f) {
                // 阶段1~3：处于水晶玻璃珠、单根拉伸条或两根玻璃条分裂阶段，中间内容尚未卷出
                m_surface.Present(m_hwnd, wPx, hPx, 255);
                return;
            }

            // 阶段4：双向卷轴展开阶段 (animT: 0.70 -> 1.0)
            const float W = static_cast<float>(w);
            const float H = static_cast<float>(h);
            const float barH = 20.0f;
            const float cy = H * 0.5f;

            float p = (animT - 0.70f) / 0.30f;
            float s = 3.0f * p * p - 2.0f * p * p * p;
            float yTop = (1.0f - s) * (cy - barH);
            float yBot = (1.0f - s) * cy + s * (H - barH);

            RectF scrollClip(0.0f, yTop, W, (yBot + barH) - yTop);
            introClipState = g.Save();
            g.SetClip(scrollClip, CombineModeIntersect);
            hasIntroClip = true;
        } else {
            if (h > 50) {
                bool focusSettled = m_focusAnim.IsSettled();
                if (!focusSettled) {
                    InvalidateBgCache();
                    GlassRenderer::DrawAirPlayGlassFrame(g, w, h, 0.0f, focusRatio, m_artworkBmp.get(), true);
                } else {
                    if (!m_bgCacheBmp || m_bgCacheW != wPx || m_bgCacheH != hPx || m_bgCacheFocused != m_focused || m_bgCacheArtKey != m_cachedArtKey) {
                        m_bgCacheBmp = std::make_unique<Bitmap>(wPx, hPx, PixelFormat32bppPARGB);
                        Graphics bg(m_bgCacheBmp.get());
                        bg.Clear(Color(0, 0, 0, 0));
                        bg.ScaleTransform(scale, scale);
                        bg.SetSmoothingMode(SmoothingModeHighQuality);
                        bg.SetInterpolationMode(InterpolationModeHighQualityBicubic);
                        GlassRenderer::DrawAirPlayGlassFrame(bg, w, h, 0.0f, focusRatio, m_artworkBmp.get(), true);
                        m_bgCacheW = wPx;
                        m_bgCacheH = hPx;
                        m_bgCacheFocused = m_focused;
                        m_bgCacheArtKey = m_cachedArtKey;
                    }
                    g.DrawImage(m_bgCacheBmp.get(), RectF(0.0f, 0.0f, static_cast<REAL>(w), static_cast<REAL>(h)),
                                0.0f, 0.0f, static_cast<REAL>(wPx), static_cast<REAL>(hPx), UnitPixel);
                }
            } else {
                GlassRenderer::DrawAirPlayGlassFrame(g, w, h, m_miniMode ? hoverAlpha : 0.0f, focusRatio, nullptr, true);
            }
        }

        // AirPlay Zion 经典光学动效：相机镜头炫光/光晕 (横向贯穿底层渲染，位于文字与页面元素之下)
        for (auto const& s : m_sweeps) {
            if (s.progress < 1.0f) {
                float t = s.progress;
                // 开始稍微慢一点，带加速度 (初速度较低，平滑加速贯穿界面)
                float eased = t * (0.25f + 0.75f * t);
                float sweepPos = s.startPos + (s.endPos - s.startPos) * eased;
                float intensity = std::sin(t * 3.14159265f);
                GlassRenderer::DrawSpecularSweep(g, w, h, sweepPos, intensity, s.originX);
            }
        }

        int64_t livePosMs = m_scrubbing
            ? static_cast<int64_t>(m_scrubRatio * static_cast<float>(info.durationMs))
            : info.EstimatedPositionMs();

        float ratio = (info.durationMs > 0) ? static_cast<float>(livePosMs) / static_cast<float>(info.durationMs) : 0.0f;

        FontFamily ff(L"Microsoft YaHei");
        Font titleFont(&ff, 13.0f, FontStyleBold, UnitPixel);
        Font subFont(&ff, 11.0f, FontStyleRegular, UnitPixel);
        Font timeFont(&ff, 10.0f, FontStyleRegular, UnitPixel);

        StringFormat centerSf, leftSf, rightSf;
        centerSf.SetAlignment(StringAlignmentCenter); centerSf.SetTrimming(StringTrimmingEllipsisCharacter); centerSf.SetFormatFlags(StringFormatFlagsNoWrap);
        leftSf.SetAlignment(StringAlignmentNear);     leftSf.SetTrimming(StringTrimmingEllipsisCharacter);   leftSf.SetFormatFlags(StringFormatFlagsNoWrap);
        rightSf.SetAlignment(StringAlignmentFar);     rightSf.SetFormatFlags(StringFormatFlagsNoWrap);

        auto findBtn = [&](int id) -> UIButton const* {
            for (auto const& b : m_buttons) if (b.id == id) return &b;
            return nullptr;
        };

        if (h > 50) {
            float bodyFade = std::clamp((static_cast<float>(h) - 50.0f) / 40.0f, 0.0f, 1.0f);

            if (m_artworkBmp) {
                GraphicsPath artClip;
                GlassRenderer::AddRoundedRectPath(artClip, 14.0f, 25.0f, 34.0f, 34.0f, 5.0f);
                GraphicsState s = g.Save();
                g.SetClip(&artClip);
                GlassRenderer::DrawImageAlpha(g, m_artworkBmp.get(), RectF(14.0f, 25.0f, 34.0f, 34.0f),
                                              0, 0, m_artworkBmp->GetWidth(), m_artworkBmp->GetHeight(), 0.92f * bodyFade);
                g.Restore(s);
            }

            float idleAlpha = (1.0f - hoverAlpha) * bodyFade;
            if (idleAlpha > 0.02f) {
                float textLeft = m_artworkBmp ? 54.0f : 36.0f;
                float textW    = static_cast<float>(w) - textLeft - 36.0f;
                SolidBrush titleBrush(Color(static_cast<BYTE>(245.0f * idleAlpha), 235, 235, 235));
                SolidBrush subBrush(Color(static_cast<BYTE>(185.0f * idleAlpha), 166, 166, 166));
                g.DrawString(info.title.c_str(), -1, &titleFont, RectF(textLeft, 25.0f, textW, 19.0f), &centerSf, &titleBrush);
                g.DrawString(info.artist.c_str(), -1, &subFont, RectF(textLeft, 45.0f, textW, 16.0f), &centerSf, &subBrush);
            }

            float ctrlAlpha = hoverAlpha * bodyFade;
            if (ctrlAlpha > 0.02f) {
                auto drawMainSprite = [&](int btnId, int spriteIdx) {
                    auto* b = findBtn(btnId);
                    if (!b || !b->visible) return;
                    float hProg = b->hoverAnim.current;
                    float sc    = b->pressAnim.current;
                    RectF r = b->bounds;
                    float dw = r.Width * sc, dh = r.Height * sc;
                    RectF dst(r.X + (r.Width - dw) * 0.5f, r.Y + (r.Height - dh) * 0.5f, dw, dh);

                    if (hProg > 0.02f) {
                        GlassRenderer::DrawTextHalo(g, r.X + r.Width * 0.5f, r.Y + r.Height * 0.5f, 17.0f, 17.0f,
                                                    static_cast<BYTE>(60.0f * hProg * ctrlAlpha));
                    }
                    GlassRenderer::DrawImageAlpha(g, m_mainCtrlBmp.get(), dst, spriteIdx * 128, 0, 128, 128,
                                                  ctrlAlpha * (0.75f + 0.25f * hProg), 1.0f + 0.18f * hProg);
                };

                drawMainSprite(BTN_STOP, 0);
                drawMainSprite(BTN_PREV, 1);
                drawMainSprite(BTN_PLAYPAUSE, info.isPlaying ? 3 : 2);
                drawMainSprite(BTN_NEXT, 4);
                drawMainSprite(BTN_EJECT, 5);

                RectF topGlassClip(3.0f, 2.0f, static_cast<float>(w - 6), 18.0f);
                GlassRenderer::DrawBarSpillFog(g, topGlassClip, static_cast<float>(w - 49), 130.0f, 34.0f, true, static_cast<BYTE>(215.0f * ctrlAlpha));

                auto drawWinSprite = [&](int btnId, int col) {
                    auto* b = findBtn(btnId);
                    if (!b) return;
                    float hProg = b->hoverAnim.current;
                    GlassRenderer::DrawImageAlpha(g, m_winBtnsBmp.get(), b->bounds, col * 52, 0, 52, 52,
                                                  ctrlAlpha * (0.85f + 0.15f * hProg), 1.08f + 0.2f * hProg);
                };
                drawWinSprite(BTN_MINIMIZE, 0);
                drawWinSprite(BTN_MINI_TOGGLE, 7);
                drawWinSprite(BTN_TOPMOST, m_topMost ? 6 : 5);
                drawWinSprite(BTN_CLOSE, 2);

                int volPercent = static_cast<int>(std::round(info.volume * 100.0f));
                for (int seg = 0; seg < 8; ++seg) {
                    int segY = 74 - seg * 4;
                    bool active = (seg * 12) < volPercent;
                    BYTE va = static_cast<BYTE>((active ? 200.0f : 65.0f) * ctrlAlpha);
                    SolidBrush vb(active ? Color(va, 201, 201, 201) : Color(va, 80, 80, 80));
                    g.FillRectangle(&vb, w - 18, segY, 7, 2);
                }

                RectF botGlassClip(3.0f, static_cast<float>(h - 20), static_cast<float>(w - 6), 18.0f);
                GlassRenderer::DrawBarSpillFog(g, botGlassClip, 47.0f, 32.0f, 110.0f, false, static_cast<BYTE>(205.0f * ctrlAlpha));
                GlassRenderer::DrawBarSpillFog(g, botGlassClip, static_cast<float>(w - 47), 80.0f, 32.0f, false, static_cast<BYTE>(215.0f * ctrlAlpha));

                WebPlatform curPlat = m_controller.CurrentWebPlatform();
                int srcIds[3] = { BTN_SRC_APPLE, BTN_SRC_SPOTIFY, BTN_SRC_QQ };
                for (int i = 0; i < 3; ++i) {
                    if (auto* sb = findBtn(srcIds[i])) {
                        bool isAct = (static_cast<int>(curPlat) == i);
                        float logoAlpha = ctrlAlpha * (isAct || sb->hoverAnim.current > 0.1f ? 1.0f : 0.78f);
                        GlassRenderer::DrawPlatformLogo(g, i, sb->bounds, isAct || sb->hoverAnim.current > 0.1f, logoAlpha);
                    }
                }

                if (auto* bLib = findBtn(BTN_LIBRARY)) {
                    float a = ctrlAlpha * (m_libVisible || bLib->hoverAnim.current > 0.1f ? 1.0f : 0.85f);
                    GlassRenderer::DrawImageAlpha(g, m_winBtnsBmp.get(), bLib->bounds, 1 * 52, 0, 52, 52, a, m_libVisible ? 1.2f : 1.08f);
                }
                if (auto* bLrc = findBtn(BTN_LYRICS)) {
                    float a = ctrlAlpha * (m_lyricsVisible || bLrc->hoverAnim.current > 0.1f ? 1.0f : 0.85f);
                    GlassRenderer::DrawImageAlpha(g, m_winBtnsBmp.get(), bLrc->bounds, 8 * 52, 52, 52, 52, a, m_lyricsVisible ? 1.2f : 1.08f);
                }
            }

            if (bodyFade > 0.25f) {
                auto* bProg = findBtn(BTN_PROGRESS);
                RectF pr = bProg ? bProg->bounds : RectF(68, 64, static_cast<REAL>(w - 136), 14);
                bool hl = (bProg && bProg->hoverAnim.current > 0.1f);
                GlassRenderer::DrawCapsuleProgress(g, RectF(pr.X, pr.Y + 4.0f, pr.Width, 6.0f), ratio, hl, m_scrubbing, FormatMs(livePosMs));

                SolidBrush timeBrush(Color(static_cast<BYTE>(210.0f * bodyFade), 166, 166, 166));
                g.DrawString(FormatMs(livePosMs).c_str(), -1, &timeFont, RectF(26.0f, pr.Y + 1.0f, 38.0f, 13.0f), &rightSf, &timeBrush);
                g.DrawString(FormatMs(info.durationMs).c_str(), -1, &timeFont, RectF(static_cast<REAL>(w - 64), pr.Y + 1.0f, 38.0f, 13.0f), &leftSf, &timeBrush);
            }
        } else {
            RectF miniGlassClip(4.5f, 3.5f, static_cast<float>(w - 9), static_cast<float>(h - 7));
            GraphicsState miniSaved = g.Save();
            g.SetClip(miniGlassClip, CombineModeIntersect);

            float idleAlpha = 1.0f - hoverAlpha;
            if (idleAlpha > 0.02f) {
                auto items = GetMiniCycleItems(info);
                std::wstring line = items[static_cast<size_t>(m_miniFieldIdx) % items.size()];
                if (m_curMiniLine.empty()) m_curMiniLine = line;

                StringFormat vCenterSf;
                vCenterSf.SetAlignment(StringAlignmentCenter);
                vCenterSf.SetLineAlignment(StringAlignmentCenter);
                vCenterSf.SetTrimming(StringTrimmingEllipsisCharacter);
                vCenterSf.SetFormatFlags(StringFormatFlagsNoWrap);

                float p = std::clamp(m_miniTextSlide.current, 0.0f, 1.0f);
                float slideDist = 18.0f;
                if (p < 0.98f && !m_prevMiniLine.empty()) {
                    GlassRenderer::DrawGlyphHaloText(g, m_prevMiniLine, ff, 13.0f,
                                                     RectF(12.0f, 5.0f - p * slideDist, static_cast<REAL>(w - 24), static_cast<REAL>(h - 6)),
                                                     vCenterSf, Color(201, 201, 201), idleAlpha * (1.0f - p));
                }
                if (p > 0.02f && !line.empty()) {
                    GlassRenderer::DrawGlyphHaloText(g, line, ff, 13.0f,
                                                     RectF(12.0f, 5.0f + (1.0f - p) * slideDist, static_cast<REAL>(w - 24), static_cast<REAL>(h - 6)),
                                                     vCenterSf, Color(201, 201, 201), idleAlpha * p);
                }
            }
            if (hoverAlpha > 0.02f) {
                GlassRenderer::DrawTextHalo(g, static_cast<float>(w) * 0.5f, static_cast<float>(h) * 0.5f,
                                            68.0f, 14.0f, static_cast<BYTE>(135.0f * hoverAlpha));
                GlassRenderer::DrawTextHalo(g, static_cast<float>(w - 61), static_cast<float>(h) * 0.5f,
                                            38.0f, 14.0f, static_cast<BYTE>(135.0f * hoverAlpha));
                GlassRenderer::DrawTextHalo(g, 51.5f, static_cast<float>(h) * 0.5f,
                                            20.0f, 14.0f, static_cast<BYTE>(135.0f * hoverAlpha));

                if (auto* b = findBtn(BTN_MINI_SRC)) {
                    float a = hoverAlpha * (m_libVisible || b->hoverAnim.current > 0.1f ? 1.0f : 0.85f);
                    GlassRenderer::DrawPlatformLogo(g, static_cast<int>(m_controller.CurrentWebPlatform()), b->bounds,
                                                    m_libVisible || b->hoverAnim.current > 0.1f, a);
                }

                auto drawMiniSprite = [&](int btnId, int spriteIdx) {
                    auto* b = findBtn(btnId);
                    if (!b || !b->visible) return;
                    GlassRenderer::DrawImageAlpha(g, m_miniCtrlBmp.get(), b->bounds, spriteIdx * 64, 0, 64, 64,
                                                  hoverAlpha * (0.85f + 0.15f * b->hoverAnim.current), 1.0f + 0.15f * b->hoverAnim.current);
                };
                drawMiniSprite(BTN_STOP, 0);
                drawMiniSprite(BTN_PREV, 1);
                drawMiniSprite(BTN_PLAYPAUSE, info.isPlaying ? 3 : 2);
                drawMiniSprite(BTN_NEXT, 4);
                drawMiniSprite(BTN_EJECT, 5);
                if (auto* b = findBtn(BTN_LYRICS))      GlassRenderer::DrawImageAlpha(g, m_winBtnsBmp.get(), b->bounds, 8 * 52, 52, 52, 52, hoverAlpha);
                if (auto* b = findBtn(BTN_MINI_TOGGLE)) GlassRenderer::DrawImageAlpha(g, m_winBtnsBmp.get(), b->bounds, 4 * 52, 0, 52, 52, hoverAlpha);
                if (auto* b = findBtn(BTN_CLOSE))       GlassRenderer::DrawImageAlpha(g, m_winBtnsBmp.get(), b->bounds, 2 * 52, 0, 52, 52, hoverAlpha);
            }
            g.Restore(miniSaved);
        }

        if (hasIntroClip) {
            g.Restore(introClipState);
        }
    }
    m_surface.Present(m_hwnd, wPx, hPx, masterAlpha);
}

LRESULT CALLBACK MainWindow::WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    MainWindow* self = nullptr;
    if (msg == WM_CREATE) {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
        self = static_cast<MainWindow*>(cs->lpCreateParams);
        self->m_hwnd = hwnd;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    } else {
        self = reinterpret_cast<MainWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    }
    return self ? self->HandleMessage(msg, wParam, lParam) : DefWindowProcW(hwnd, msg, wParam, lParam);
}

LRESULT MainWindow::HandleMessage(UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE: {
        m_dpi = GetDpiForWindow(m_hwnd);
        if (m_dpi == 0) m_dpi = 96;
        m_dockMgr.SetDpi(m_dpi);

        int wPx = GlassRenderer::ToPx(DEFAULT_WIDTH_DIP, m_dpi);
        int hPx = GlassRenderer::ToPx(DEFAULT_HEIGHT_DIP, m_dpi);

        RECT rcWork{};
        SystemParametersInfoW(SPI_GETWORKAREA, 0, &rcWork, 0);
        int margin = GlassRenderer::ToPx(16, m_dpi);
        int totalW = GlassRenderer::ToPx(DEFAULT_WIDTH_DIP + 330, m_dpi);
        int startX = rcWork.right - totalW - margin;
        int startY = rcWork.top + margin;
        SetWindowPos(m_hwnd, nullptr, startX, startY, wPx, hPx, SWP_NOZORDER | SWP_NOACTIVATE);
        GlassRenderer::EnableFrostedBlur(m_hwnd, wPx, hPx, m_dpi, false);

        HICON hLogo = static_cast<HICON>(LoadImageW(m_hInst, MAKEINTRESOURCEW(IDR_MAIN_ICON), IMAGE_ICON, 48, 48, LR_DEFAULTCOLOR));
        if (hLogo) {
            m_appLogoBmp.reset(Bitmap::FromHICON(hLogo));
            DestroyIcon(hLogo);
        }

        m_mainCtrlBmp = GlassRenderer::LoadPngResource(m_hInst, IDR_PNG_MAINCONTROL);
        m_miniCtrlBmp = GlassRenderer::LoadPngResource(m_hInst, IDR_PNG_MINICONTROL);
        m_winBtnsBmp  = GlassRenderer::LoadPngResource(m_hInst, IDR_PNG_WINDOWBUTTON);
        m_iconBtnsBmp = GlassRenderer::LoadPngResource(m_hInst, IDR_PNG_ICONBUTTON);

        BuildUIElements();

        MotionCoordinator::Instance().AttachHost(m_hwnd);
        MotionCoordinator::Instance().RegisterClient(this);

        m_nid.cbSize = sizeof(NOTIFYICONDATAW);
        m_nid.hWnd = m_hwnd;
        m_nid.uID = 1;
        m_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
        m_nid.uCallbackMessage = WM_APP_TRAY_ICON;
        m_nid.hIcon = LoadIconW(m_hInst, MAKEINTRESOURCEW(IDR_MAIN_ICON));
        wcscpy_s(m_nid.szTip, L"AirMuse - Universal Music Controller");
        Shell_NotifyIconW(NIM_ADD, &m_nid);

        m_miniCycleTick = GetTickCount64();
        SetTimer(m_hwnd, TIMER_CLOCK, 200, nullptr);
        Render();
        return 0;
    }
    case WM_ACTIVATE:
        m_focused = (LOWORD(wParam) != WA_INACTIVE);
        m_focusAnim.target = m_focused ? 1.0f : 0.0f;
        EnsureFrameTimer();
        Render();
        if (m_lyricsWnd) m_lyricsWnd->Render();
        if (m_libraryWnd) m_libraryWnd->RefreshHoverIfChanged();
        return 0;
    case WM_WINDOWPOSCHANGED:
        m_dockMgr.SyncAllDocked();
        return DefWindowProcW(m_hwnd, msg, wParam, lParam);
    case WM_APP_STATE_CHANGED:
        m_controller.OnMediaSourceUpdated();
        Render();
        if (m_lyricsWnd) m_lyricsWnd->OnPlaybackOrLyricsChanged();
        if (m_libraryWnd) m_libraryWnd->Render();
        return 0;
    case WM_APP_LYRICS_UPDATED:
        m_controller.OnLyricsUpdated();
        if (m_lyricsWnd) m_lyricsWnd->OnPlaybackOrLyricsChanged();
        return 0;
    case WM_TIMER:
        if (wParam == TIMER_CLOCK) {
            auto info = m_controller.Store().GetPlayback();
            if (m_miniMode && !m_hovering) {
                ULONGLONG now = GetTickCount64();
                if (m_miniCycleTick == 0) m_miniCycleTick = now;
                auto items = GetMiniCycleItems(info);
                if (items.size() > 1 && (now - m_miniCycleTick) >= 10000) {
                    m_miniCycleTick = now;
                    m_prevMiniLine = items[static_cast<size_t>(m_miniFieldIdx) % items.size()];
                    m_miniFieldIdx = (m_miniFieldIdx + 1) % static_cast<int>(items.size());
                    m_curMiniLine = items[static_cast<size_t>(m_miniFieldIdx)];
                    m_miniTextSlide.SnapTo(0.0f);
                    m_miniTextSlide.target = 1.0f;
                    EnsureFrameTimer();
                }
            }
            if (info.isPlaying) {
                if (!m_animating) Render();
                if (m_lyricsWnd) m_lyricsWnd->OnPlaybackTick();
            }
            if (m_libraryWnd) m_libraryWnd->RefreshHoverIfChanged();
        } else if (wParam == TIMER_MOTION_VSYNC || wParam == TIMER_FRAME) {
            MotionCoordinator::Instance().OnTick();
        }
        return 0;
    case WM_MOUSEMOVE: {
        float xDip = static_cast<float>(GlassRenderer::ToDip(GET_X_LPARAM(lParam), m_dpi));
        float yDip = static_cast<float>(GlassRenderer::ToDip(GET_Y_LPARAM(lParam), m_dpi));

        if (!m_hovering) {
            m_hovering = true;
            m_hoverPanel.target = 1.0f;
            EnsureFrameTimer();
        }

        if (m_scrubbing) {
            for (auto const& b : m_buttons) {
                if (b.id == BTN_PROGRESS && b.bounds.Width > 0) {
                    m_scrubRatio = std::clamp((xDip - b.bounds.X) / b.bounds.Width, 0.0f, 1.0f);
                    Render();
                    break;
                }
            }
            return 0;
        }

        int hit = -1;
        for (auto const& b : m_buttons) {
            if (b.HitTest(xDip, yDip)) { hit = b.id; break; }
        }
        if (hit != m_hoverBtnId) {
            m_hoverBtnId = hit;
            EnsureFrameTimer();
        }

        // AirPlay Zion 经典光学动效：中线跨越与触碰玻璃条出界扫光触发
        float wDip = m_winWidth.current;
        float hDip = m_winHeight.current;
        float normX = (wDip > 0.0f) ? std::clamp(xDip / wDip, 0.20f, 0.80f) : 0.5f;
        float midY = hDip * 0.5f;
        // 移出边界以主界面显示区域（不含玻璃条）为准，即碰到玻璃条(20px)立即触发
        float topGlassBoundary = 20.0f;
        float botGlassBoundary = hDip - 20.0f;

        ULONGLONG nowTick = GetTickCount64();
        float dtMs = (m_lastMouseMoveTick > 0 && nowTick >= m_lastMouseMoveTick)
            ? static_cast<float>(nowTick - m_lastMouseMoveTick) : 16.0f;
        dtMs = std::clamp(dtMs, 1.0f, 100.0f);
        m_lastMouseMoveTick = nowTick;

        if (m_lastMouseY >= 0.0f && hDip > 40.0f) {
            float dy = yDip - m_lastMouseY;
            float speedY = std::abs(dy) / (dtMs * 0.001f);
            // 垂直移动速度达到阈值(>400 DIP/s 或单帧跨越>=14 DIP)，判定为快速扫过/甩动
            bool isFastVerticalMove = (speedY > 400.0f) || (std::abs(dy) >= 14.0f);

            // 1. 中线触发 (仅在移动速度未超标的温和划过时显示；快速划过时不显示过半光带)
            if (m_lastMouseY < midY && yDip >= midY) {
                // 向下跨过中线 -> 从中线 0.5 开始向下流动至底边 1.0
                if (m_lastMidCrossDir != 1) {
                    if (!isFastVerticalMove) {
                        TriggerSweep(0.5f, 1.0f, 2.0f, normX);
                    }
                    m_lastMidCrossDir = 1;
                }
            } else if (m_lastMouseY > midY && yDip <= midY) {
                // 向上跨过中线 -> 从中线 0.5 开始向上流动至顶边 0.0
                if (m_lastMidCrossDir != -1) {
                    if (!isFastVerticalMove) {
                        TriggerSweep(0.5f, 0.0f, 2.0f, normX);
                    }
                    m_lastMidCrossDir = -1;
                }
            }

            // 2. 碰到玻璃条边界反弹触发 (固定触发：无论快慢，碰界必然从头反弹横扫)
            if (!m_botBoundaryTriggered && dy > 0.0f && yDip >= botGlassBoundary) {
                // 向下碰到玻璃条 -> 从底边 1.0 从头反向横扫至顶边 0.0
                TriggerSweep(1.0f, 0.0f, 1.6f, normX);
                m_botBoundaryTriggered = true;
            } else if (!m_topBoundaryTriggered && dy < 0.0f && yDip <= topGlassBoundary) {
                // 向上碰到玻璃条 -> 从顶边 0.0 从头反向横扫至底边 1.0
                TriggerSweep(0.0f, 1.0f, 1.6f, normX);
                m_topBoundaryTriggered = true;
            }

            // 离开玻璃条边界回移时重置边界锁
            if (m_botBoundaryTriggered && yDip < botGlassBoundary - 10.0f) {
                m_botBoundaryTriggered = false;
            }
            if (m_topBoundaryTriggered && yDip > topGlassBoundary + 10.0f) {
                m_topBoundaryTriggered = false;
            }
        }
        m_lastMouseY = yDip;

        TRACKMOUSEEVENT tme{ sizeof(tme), TME_LEAVE, m_hwnd, 0 };
        TrackMouseEvent(&tme);
        return 0;
    }
    case WM_MOUSELEAVE:
        m_hovering = false;
        m_hoverPanel.target = 0.0f;
        m_hoverBtnId = -1;
        m_pressedBtnId = -1;
        m_lastMouseY = -1.0f;
        m_lastMouseMoveTick = 0;
        m_lastMidCrossDir = 0;
        m_topBoundaryTriggered = false;
        m_botBoundaryTriggered = false;
        EnsureFrameTimer();
        return 0;
    case WM_LBUTTONDBLCLK:
        if (m_hoverBtnId == -1) ToggleMiniMode();
        return 0;
    case WM_LBUTTONDOWN: {
        float xDip = static_cast<float>(GlassRenderer::ToDip(GET_X_LPARAM(lParam), m_dpi));
        float yDip = static_cast<float>(GlassRenderer::ToDip(GET_Y_LPARAM(lParam), m_dpi));

        for (auto const& b : m_buttons) {
            if (b.HitTest(xDip, yDip)) {
                m_pressedBtnId = b.id;
                if (b.id == BTN_PROGRESS && b.bounds.Width > 0) {
                    m_scrubbing = true;
                    m_scrubRatio = std::clamp((xDip - b.bounds.X) / b.bounds.Width, 0.0f, 1.0f);
                    SetCapture(m_hwnd);
                }
                EnsureFrameTimer();
                return 0;
            }
        }
        ReleaseCapture();
        SendMessageW(m_hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
        return 0;
    }
    case WM_LBUTTONUP: {
        float xDip = static_cast<float>(GlassRenderer::ToDip(GET_X_LPARAM(lParam), m_dpi));
        float yDip = static_cast<float>(GlassRenderer::ToDip(GET_Y_LPARAM(lParam), m_dpi));

        if (m_scrubbing) {
            m_scrubbing = false;
            m_pressedBtnId = -1;
            ReleaseCapture();
            auto info = m_controller.Store().GetPlayback();
            if (info.durationMs > 0) {
                m_controller.SeekTo(static_cast<int64_t>(m_scrubRatio * static_cast<float>(info.durationMs)));
            }
            Render();
            return 0;
        }

        if (m_pressedBtnId != -1) {
            int clicked = m_pressedBtnId;
            m_pressedBtnId = -1;
            EnsureFrameTimer();
            for (auto const& b : m_buttons) {
                if (b.id == clicked && b.HitTest(xDip, yDip)) {
                    if (b.id == BTN_VOL_BAR) {
                        bool up = (yDip < b.bounds.Y + b.bounds.Height * 0.5f);
                        m_controller.AdjustVolume(up ? 0.1f : -0.1f);
                    } else if (b.onClick) {
                        b.onClick();
                    }
                    break;
                }
            }
        }
        return 0;
    }
    case WM_MOUSEWHEEL: {
        int delta = GET_WHEEL_DELTA_WPARAM(wParam);
        m_controller.AdjustVolume(delta > 0 ? 0.05f : -0.05f);
        Render();
        return 0;
    }
    case WM_APP_TRAY_ICON:
        if (lParam == WM_LBUTTONUP || lParam == WM_LBUTTONDBLCLK) {
            ShowWindow(m_hwnd, SW_SHOW);
            if (m_lyricsVisible && m_lyricsWnd) ShowWindow(m_lyricsWnd->Hwnd(), SW_SHOWNOACTIVATE);
            if (m_libVisible && m_libraryWnd) m_libraryWnd->SetVisible(true);
            SetForegroundWindow(m_hwnd);
        } else if (lParam == WM_RBUTTONUP) {
            PostQuitMessage(0);
        }
        return 0;
    case WM_DESTROY:
        MotionCoordinator::Instance().UnregisterClient(this);
        MotionCoordinator::Instance().DetachHost(m_hwnd);
        KillTimer(m_hwnd, TIMER_CLOCK);
        KillTimer(m_hwnd, TIMER_FRAME);
        Shell_NotifyIconW(NIM_DELETE, &m_nid);
        m_controller.Shutdown();
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(m_hwnd, msg, wParam, lParam);
}

} // namespace airmuse