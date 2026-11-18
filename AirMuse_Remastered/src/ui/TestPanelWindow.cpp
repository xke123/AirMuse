#include "TestPanelWindow.hpp"
#include "GlassRenderer.hpp"
#include "../resource.h"
#include <windowsx.h>
#include <algorithm>
#include <cmath>
#include <cstdio>

using namespace Gdiplus;

namespace airmuse {

namespace {
enum BtnId {
    BTN_STOP = 0, BTN_PREV, BTN_PLAYPAUSE, BTN_NEXT, BTN_EJECT,
    BTN_MINIMIZE, BTN_MINI_TOGGLE, BTN_TOPMOST, BTN_CLOSE,
    BTN_PROGRESS, BTN_VOL_BAR, BTN_LYRICS, BTN_LIBRARY,
    BTN_SRC_APPLE, BTN_SRC_SPOTIFY, BTN_SRC_QQ
};

std::wstring FormatMs(int64_t ms) {
    if (ms < 0) ms = 0;
    int sec = static_cast<int>(ms / 1000);
    wchar_t buf[16];
    swprintf_s(buf, L"%02d:%02d", sec / 60, sec % 60);
    return buf;
}
} // namespace

TestPanelWindow::TestPanelWindow(HINSTANCE hInst, AppController& controller, DockManager& dockMgr)
    : m_hInst(hInst), m_controller(controller), m_dockMgr(dockMgr) {
    MotionCoordinator::Instance().RegisterClient(this);
}

TestPanelWindow::~TestPanelWindow() {
    MotionCoordinator::Instance().UnregisterClient(this);
    if (m_hwnd && IsWindow(m_hwnd)) {
        DestroyWindow(m_hwnd);
    }
}

HWND TestPanelWindow::Create(HWND parentMain) {
    m_parentMain = parentMain;
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.style = CS_DBLCLKS;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = m_hInst;
    wc.lpszClassName = L"AirMuseTestPanel";
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    RegisterClassExW(&wc);

    m_dpi = GetDpiForSystem();

    // 默认定位在当前主面板正上方，底边与主面板顶边咬合重叠 11 DIP
    RECT rcMain{};
    int startX = 120, startY = 20;
    if (parentMain && GetWindowRect(parentMain, &rcMain)) {
        int ov = GlassRenderer::ToPx(11, m_dpi);
        int hPx = GlassRenderer::ToPx(DEFAULT_HEIGHT_DIP, m_dpi);
        startX = rcMain.left;
        startY = rcMain.top - hPx + ov;
    }

    m_hwnd = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        wc.lpszClassName, L"AirMuse Test Panel", WS_POPUP,
        startX, startY,
        GlassRenderer::ToPx(DEFAULT_WIDTH_DIP, m_dpi),
        GlassRenderer::ToPx(DEFAULT_HEIGHT_DIP, m_dpi),
        parentMain, nullptr, m_hInst, this
    );

    m_mainCtrlBmp = GlassRenderer::LoadPngResource(m_hInst, IDR_PNG_MAINCONTROL);
    m_winBtnsBmp  = GlassRenderer::LoadPngResource(m_hInst, IDR_PNG_WINDOWBUTTON);

    BuildUIElements();
    UpdateLayout(m_animProgress);

    return m_hwnd;
}

void TestPanelWindow::SetAnimSpeed(AnimSpeed speed) {
    m_animSpeed = speed;
    m_animDuration = (m_animSpeed == AnimSpeed::Speed2_0s) ? 2.0f : 1.5f;
}

void TestPanelWindow::ToggleAnimSpeed() {
    if (m_animSpeed == AnimSpeed::Speed1_5s) {
        SetAnimSpeed(AnimSpeed::Speed2_0s);
    } else {
        SetAnimSpeed(AnimSpeed::Speed1_5s);
    }
}

void TestPanelWindow::SyncPositionWithMain(bool ensureOnScreen) {
    if (!m_hwnd || !m_parentMain) return;
    RECT rcMain{};
    GetWindowRect(m_parentMain, &rcMain);
    int ov = GlassRenderer::ToPx(11, m_dpi);
    int hPx = GlassRenderer::ToPx(DEFAULT_HEIGHT_DIP, m_dpi);
    int testX = rcMain.left;
    int testY = rcMain.top - hPx + ov;

    if (ensureOnScreen) {
        RECT rcWork{};
        SystemParametersInfoW(SPI_GETWORKAREA, 0, &rcWork, 0);
        int topLimit = rcWork.top + GlassRenderer::ToPx(8, m_dpi);
        if (testY < topLimit) {
            int shift = topLimit - testY;
            SetWindowPos(m_parentMain, nullptr, rcMain.left, rcMain.top + shift, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
            GetWindowRect(m_parentMain, &rcMain);
            testY = rcMain.top - hPx + ov;
        }
    }

    SetWindowPos(m_hwnd, HWND_TOPMOST, testX, testY, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
}

void TestPanelWindow::Unroll(int effectId) {
    m_currentEffect = effectId;
    m_dpi = GetDpiForSystem();
    SyncPositionWithMain(true);

    ShowWindow(m_hwnd, SW_SHOWNOACTIVATE);
    SetWindowPos(m_hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW | SWP_NOACTIVATE);

    // 每次点击展开，从 0.0 开始向外展开至 1.0
    m_animTime = 0.0f;
    m_animProgress = 0.0f;
    m_animTarget = 1.0f;
    Render();
    MotionCoordinator::Instance().RequestFrame();
}

void TestPanelWindow::Rollup(int effectId) {
    m_currentEffect = effectId;
    m_animTarget = 0.0f;
    MotionCoordinator::Instance().RequestFrame();
}

bool TestPanelWindow::StepMotion(float dt) {
    bool animating = false;
    if (m_animTarget > 0.5f) {
        if (m_animTime < m_animDuration) {
            m_animTime = std::min(m_animDuration, m_animTime + dt);
            animating = true;
        }
    } else {
        if (m_animTime > 0.0f) {
            m_animTime = std::max(0.0f, m_animTime - dt);
            animating = true;
        }
    }
    m_animProgress = (m_animDuration > 0.0f) ? std::clamp(m_animTime / m_animDuration, 0.0f, 1.0f) : m_animTarget;

    bool b = m_focusAnim.Step(dt);
    bool c = m_hoverGloss.Step(dt);
    bool btnAnim = false;
    for (auto& btn : m_buttons) {
        if (btn.UpdatePhysics(dt)) btnAnim = true;
    }

    // 当完全收起至玻璃球消失完成后，自动隐藏测试面板窗口
    if (!animating && m_animTarget <= 0.005f && m_animProgress <= 0.005f) {
        if (IsWindowVisible(m_hwnd)) {
            ShowWindow(m_hwnd, SW_HIDE);
        }
    }

    return animating || b || c || btnAnim;
}

void TestPanelWindow::OnMotionRender() {
    Render();
}

void TestPanelWindow::BuildUIElements() {
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
    addBtn(BTN_EJECT,       true,  [this]() {
        // Eject 按钮动作：切换卷轴收起 / 展开
        if (m_animTarget > 0.5f) Rollup(m_currentEffect);
        else Unroll(m_currentEffect);
    });

    addBtn(BTN_MINIMIZE,    false, [this]() { ShowWindow(m_hwnd, SW_HIDE); });
    addBtn(BTN_MINI_TOGGLE, false, [this]() {
        if (m_animTarget > 0.5f) Rollup(m_currentEffect);
        else Unroll(m_currentEffect);
    });
    addBtn(BTN_TOPMOST,     false, nullptr);
    addBtn(BTN_CLOSE,       false, [this]() { Rollup(m_currentEffect); });
    addBtn(BTN_PROGRESS,    false, nullptr);
    addBtn(BTN_VOL_BAR,     false, nullptr);
    addBtn(BTN_LYRICS,      false, nullptr);
    addBtn(BTN_LIBRARY,     false, nullptr);
    addBtn(BTN_SRC_APPLE,   false, nullptr);
    addBtn(BTN_SRC_SPOTIFY, false, nullptr);
    addBtn(BTN_SRC_QQ,      false, nullptr);
}

UIButton* TestPanelWindow::FindBtn(int id) {
    for (auto& b : m_buttons) {
        if (b.id == id) return &b;
    }
    return nullptr;
}

void TestPanelWindow::UpdateLayout(float animT) {
    const float W = static_cast<float>(DEFAULT_WIDTH_DIP);
    const float H = static_cast<float>(DEFAULT_HEIGHT_DIP);
    const float barH = 20.0f;
    const float cy = H * 0.5f;

    float yTop = 0.0f;
    float yBot = H - barH;

    if (animT <= 0.52f) {
        // 阶段一(球) & 阶段二(拉伸): 单根条或球，面板内部按钮全隐藏
        if (m_currentEffect == 2) { yTop = 0.0f; yBot = 0.0f; }
        else if (m_currentEffect == 3) { yTop = H - barH; yBot = H - barH; }
        else { yTop = cy - barH * 0.5f; yBot = cy - barH * 0.5f; }

        for (auto& b : m_buttons) {
            b.visible = false;
            b.enabled = false;
        }
        return;
    }

    if (animT <= 0.70f) {
        // 阶段三: 分裂
        float u = (animT - 0.52f) / 0.18f;
        float s = 3.0f * u * u - 2.0f * u * u * u;
        if (m_currentEffect == 2) {
            yTop = 0.0f;
            yBot = s * barH;
        } else if (m_currentEffect == 3) {
            yTop = (H - barH) - s * barH;
            yBot = H - barH;
        } else {
            yTop = (cy - barH * 0.5f) - s * (barH * 0.5f);
            yBot = (cy - barH * 0.5f) + s * (barH * 0.5f);
        }

        for (auto& b : m_buttons) {
            if (b.id >= BTN_STOP && b.id <= BTN_EJECT) {
                b.visible = false;
                b.enabled = false;
            } else if (b.id == BTN_PROGRESS || b.id == BTN_VOL_BAR) {
                b.visible = false;
                b.enabled = false;
            } else if (b.id == BTN_MINIMIZE) {
                b.bounds = RectF(W - 93.0f, yTop + 4.0f, 13.0f, 13.0f);
                b.visible = true;
                b.enabled = (u > 0.8f);
            } else if (b.id == BTN_MINI_TOGGLE) {
                b.bounds = RectF(W - 77.0f, yTop + 8.0f, 13.0f, 13.0f);
                b.visible = true;
                b.enabled = (u > 0.8f);
            } else if (b.id == BTN_TOPMOST) {
                b.bounds = RectF(W - 61.0f, yTop + 4.0f, 13.0f, 13.0f);
                b.visible = true;
                b.enabled = (u > 0.8f);
            } else if (b.id == BTN_CLOSE) {
                b.bounds = RectF(W - 45.0f, yTop + 8.0f, 13.0f, 13.0f);
                b.visible = true;
                b.enabled = (u > 0.8f);
            } else if (b.id >= BTN_SRC_APPLE && b.id <= BTN_SRC_QQ) {
                int idx = b.id - BTN_SRC_APPLE;
                b.bounds = RectF(32.0f + idx * 18.0f, yBot + 3.0f, 13.0f, 13.0f);
                b.visible = true;
                b.enabled = (u > 0.8f);
            } else if (b.id == BTN_LIBRARY) {
                b.bounds = RectF(W - 63.0f, yBot + 3.0f, 13.0f, 13.0f);
                b.visible = true;
                b.enabled = (u > 0.8f);
            } else if (b.id == BTN_LYRICS) {
                b.bounds = RectF(W - 45.0f, yBot + 3.0f, 13.0f, 13.0f);
                b.visible = true;
                b.enabled = (u > 0.8f);
            }
        }
        return;
    }

    // 阶段四: 卷轴双条展开
    float p = (animT - 0.70f) / 0.30f;
    float s = 3.0f * p * p - 2.0f * p * p * p;
    if (m_currentEffect == 2) {
        yTop = 0.0f;
        yBot = barH + s * (H - 2.0f * barH);
    } else if (m_currentEffect == 3) {
        yTop = (1.0f - s) * (H - 2.0f * barH);
        yBot = H - barH;
    } else {
        yTop = (1.0f - s) * (cy - barH);
        yBot = (1.0f - s) * cy + s * (H - barH);
    }

    for (auto& b : m_buttons) {
        b.visible = true;
        if (b.id >= BTN_STOP && b.id <= BTN_EJECT) {
            float startX = (W - 166.0f) * 0.5f;
            float xs[5] = { startX, startX + 32, startX + 67, startX + 102, startX + 134 };
            b.bounds = RectF(xs[b.id - BTN_STOP], 26.0f, 32.0f, 32.0f);
            b.hitCircle = true;
            b.enabled = (p > 0.45f);
            b.visible = (p > 0.05f);
        }
        else if (b.id == BTN_MINIMIZE) {
            b.bounds = RectF(W - 93.0f, yTop + 4.0f, 13.0f, 13.0f);
            b.enabled = true;
        }
        else if (b.id == BTN_MINI_TOGGLE) {
            b.bounds = RectF(W - 77.0f, yTop + 8.0f, 13.0f, 13.0f);
            b.enabled = true;
        }
        else if (b.id == BTN_TOPMOST) {
            b.bounds = RectF(W - 61.0f, yTop + 4.0f, 13.0f, 13.0f);
            b.enabled = true;
        }
        else if (b.id == BTN_CLOSE) {
            b.bounds = RectF(W - 45.0f, yTop + 8.0f, 13.0f, 13.0f);
            b.enabled = true;
        }
        else if (b.id == BTN_PROGRESS) {
            b.bounds = RectF(68.0f, 64.0f, W - 136.0f, 14.0f);
            b.enabled = (p > 0.65f);
            b.visible = (p > 0.05f);
        }
        else if (b.id == BTN_VOL_BAR) {
            b.bounds = RectF(W - 25.0f, 42.0f, 16.0f, 38.0f);
            b.enabled = (p > 0.65f);
            b.visible = (p > 0.05f);
        }
        else if (b.id >= BTN_SRC_APPLE && b.id <= BTN_SRC_QQ) {
            int idx = b.id - BTN_SRC_APPLE;
            b.bounds = RectF(32.0f + idx * 18.0f, yBot + 3.0f, 13.0f, 13.0f);
            b.enabled = (p > 0.3f);
        }
        else if (b.id == BTN_LIBRARY) {
            b.bounds = RectF(W - 63.0f, yBot + 3.0f, 13.0f, 13.0f);
            b.enabled = (p > 0.3f);
        }
        else if (b.id == BTN_LYRICS) {
            b.bounds = RectF(W - 45.0f, yBot + 3.0f, 13.0f, 13.0f);
            b.enabled = (p > 0.3f);
        }
    }
}

void TestPanelWindow::Render() {
    int wPx = GlassRenderer::ToPx(DEFAULT_WIDTH_DIP, m_dpi);
    int hPx = GlassRenderer::ToPx(DEFAULT_HEIGHT_DIP, m_dpi);
    if (!m_surface.Ensure(wPx, hPx)) return;

    Graphics g(m_surface.hdcMem);
    g.SetSmoothingMode(SmoothingModeAntiAlias);
    g.SetTextRenderingHint(TextRenderingHintClearTypeGridFit);
    g.SetInterpolationMode(InterpolationModeHighQualityBicubic);
    g.ScaleTransform(static_cast<float>(m_dpi) / 96.0f, static_cast<float>(m_dpi) / 96.0f);
    g.Clear(Color(0, 0, 0, 0));

    float animT = m_animProgress;
    UpdateLayout(animT);

    // 1. 绘制带有阶段物理逻辑（球 -> 拉伸 -> 分裂 -> 卷轴展开）的水晶玻璃外框与深色基底
    GlassRenderer::DrawScrollGlassFrame(g, DEFAULT_WIDTH_DIP, DEFAULT_HEIGHT_DIP, animT,
                                        m_hoverGloss.current, m_focusAnim.current, m_currentEffect, m_artworkBmp.get());

    if (animT <= 0.52f) {
        // 处于玻璃球或单根拉伸条状态，中间与边栏元素均不显示
        m_surface.Present(m_hwnd, wPx, hPx, 255);
        return;
    }

    const float W = static_cast<float>(DEFAULT_WIDTH_DIP);
    const float H = static_cast<float>(DEFAULT_HEIGHT_DIP);
    const float barH = 20.0f;
    const float cy = H * 0.5f;

    float yTop = 0.0f;
    float yBot = H - barH;

    if (animT <= 0.70f) {
        float u = (animT - 0.52f) / 0.18f;
        float s = 3.0f * u * u - 2.0f * u * u * u;
        if (m_currentEffect == 2) {
            yTop = 0.0f;
            yBot = s * barH;
        } else if (m_currentEffect == 3) {
            yTop = (H - barH) - s * barH;
            yBot = H - barH;
        } else {
            yTop = (cy - barH * 0.5f) - s * (barH * 0.5f);
            yBot = (cy - barH * 0.5f) + s * (barH * 0.5f);
        }
    } else {
        float p = (animT - 0.70f) / 0.30f;
        float s = 3.0f * p * p - 2.0f * p * p * p;
        if (m_currentEffect == 2) {
            yTop = 0.0f;
            yBot = barH + s * (H - 2.0f * barH);
        } else if (m_currentEffect == 3) {
            yTop = (1.0f - s) * (H - 2.0f * barH);
            yBot = H - barH;
        } else {
            yTop = (1.0f - s) * (cy - barH);
            yBot = (1.0f - s) * cy + s * (H - barH);
        }
    }

    const float midTop = yTop + barH;
    const float midBot = yBot;
    const float midH   = midBot - midTop;

    auto const& info = m_controller.Store().GetPlayback();

    // 2. 中间主面板内容（根据卷轴展开高度动态裁切，呈现画卷视觉）
    if (animT > 0.70f && midH > 2.0f) {
        float p = (animT - 0.70f) / 0.30f;
        GraphicsState sClip = g.Save();
        g.SetClip(RectF(5.0f, midTop, W - 10.0f, midH), CombineModeIntersect);

        float contentAlpha = std::clamp(p * 1.5f - 0.1f, 0.0f, 1.0f);

        // (a) 标题与副标题（曲目与动效标签）
        Gdiplus::Font titleFont(L"Segoe UI", 10.5f, FontStyleBold, UnitPoint);
        Gdiplus::Font subFont(L"Segoe UI", 8.5f, FontStyleRegular, UnitPoint);
        StringFormat centerSf;
        centerSf.SetAlignment(StringAlignmentCenter);
        centerSf.SetLineAlignment(StringAlignmentCenter);
        centerSf.SetTrimming(StringTrimmingEllipsisCharacter);
        centerSf.SetFormatFlags(StringFormatFlagsNoWrap);

        float textLeft = 40.0f;
        float textW    = W - textLeft * 2.0f;
        std::wstring titleText = info.title.empty() ? L"AirMuse Ready" : info.title;
        std::wstring subText;
        if (m_currentEffect == 2) {
            subText = info.artist.empty() ? L"Scroll Mode 2 (从上向下展开)" : info.artist;
        } else if (m_currentEffect == 3) {
            subText = info.artist.empty() ? L"Scroll Mode 3 (从下向上展开)" : info.artist;
        } else {
            subText = info.artist.empty() ? L"Scroll Mode 1 (双向中心卷轴)" : info.artist;
        }

        SolidBrush titleBrush(Color(static_cast<BYTE>(245.0f * contentAlpha), 244, 247, 252));
        SolidBrush subBrush(Color(static_cast<BYTE>(185.0f * contentAlpha), 180, 190, 206));
        g.DrawString(titleText.c_str(), -1, &titleFont, RectF(textLeft, 25.0f, textW, 19.0f), &centerSf, &titleBrush);
        g.DrawString(subText.c_str(), -1, &subFont, RectF(textLeft, 45.0f, textW, 16.0f), &centerSf, &subBrush);

        // (b) 中间播放控制按钮（Stop, Prev, Play/Pause, Next, Eject）
        auto drawMainSprite = [&](int btnId, int spriteIdx) {
            auto* b = FindBtn(btnId);
            if (!b || !b->visible) return;
            float hProg = b->hoverAnim.current;
            float sc    = b->pressAnim.current;
            RectF r = b->bounds;
            float dw = r.Width * sc, dh = r.Height * sc;
            RectF dst(r.X + (r.Width - dw) * 0.5f, r.Y + (r.Height - dh) * 0.5f, dw, dh);

            if (hProg > 0.02f) {
                GlassRenderer::DrawTextHalo(g, r.X + r.Width * 0.5f, r.Y + r.Height * 0.5f, 17.0f, 17.0f,
                                            static_cast<BYTE>(60.0f * hProg * contentAlpha));
            }
            GlassRenderer::DrawImageAlpha(g, m_mainCtrlBmp.get(), dst, spriteIdx * 128, 0, 128, 128,
                                          contentAlpha * (0.80f + 0.20f * hProg), 1.0f + 0.18f * hProg);
        };

        drawMainSprite(BTN_STOP, 0);
        drawMainSprite(BTN_PREV, 1);
        drawMainSprite(BTN_PLAYPAUSE, info.isPlaying ? 3 : 2);
        drawMainSprite(BTN_NEXT, 4);
        drawMainSprite(BTN_EJECT, 5);

        // (c) 胶囊进度条与时间显示
        auto* bProg = FindBtn(BTN_PROGRESS);
        RectF pr = bProg ? bProg->bounds : RectF(68, 64, W - 136, 14);
        bool hl = (bProg && bProg->hoverAnim.current > 0.1f);
        float ratio = (info.durationMs > 0) ? static_cast<float>(info.positionMs) / static_cast<float>(info.durationMs) : 0.0f;
        GlassRenderer::DrawCapsuleProgress(g, RectF(pr.X, pr.Y + 4.0f, pr.Width, 6.0f), ratio, hl, false, FormatMs(info.positionMs));

        Gdiplus::Font timeFont(L"Segoe UI", 7.5f, FontStyleRegular, UnitPoint);
        StringFormat rightSf, leftSf;
        rightSf.SetAlignment(StringAlignmentFar);
        rightSf.SetLineAlignment(StringAlignmentCenter);
        leftSf.SetAlignment(StringAlignmentNear);
        leftSf.SetLineAlignment(StringAlignmentCenter);

        SolidBrush timeBrush(Color(static_cast<BYTE>(210.0f * contentAlpha), 205, 216, 230));
        g.DrawString(FormatMs(info.positionMs).c_str(), -1, &timeFont, RectF(26.0f, pr.Y + 1.0f, 38.0f, 13.0f), &rightSf, &timeBrush);
        g.DrawString(FormatMs(info.durationMs).c_str(), -1, &timeFont, RectF(W - 64.0f, pr.Y + 1.0f, 38.0f, 13.0f), &leftSf, &timeBrush);

        // (d) 音量柱
        int volPercent = static_cast<int>(std::round(info.volume * 100.0f));
        for (int seg = 0; seg < 8; ++seg) {
            int segY = 74 - seg * 4;
            bool active = (seg * 12) < volPercent;
            BYTE va = static_cast<BYTE>((active ? 200.0f : 65.0f) * contentAlpha);
            SolidBrush vb(active ? Color(va, 175, 220, 250) : Color(va, 255, 255, 255));
            g.FillRectangle(&vb, static_cast<int>(W) - 18, segY, 7, 2);
        }

        g.Restore(sClip);
    }

    // 玻璃条元素透明度（阶段三开始淡入）
    float barAlpha = (animT <= 0.52f) ? 0.0f : std::clamp((animT - 0.52f) / 0.18f, 0.0f, 1.0f);
    if (barAlpha > 0.03f) {
        // 3. 顶部玻璃条元素（跟随 yTop 移动）
        // (a) 顶部标头小药丸：模式标识与动画时长
        {
            RectF tagDst(14.0f, yTop + 3.5f, 92.0f, 13.0f);
            GraphicsPath tagPath;
            GlassRenderer::AddRoundedRectPath(tagPath, tagDst.X, tagDst.Y, tagDst.Width, tagDst.Height, 3.2f);
            SolidBrush tagBg(Color(static_cast<BYTE>(55 * barAlpha), 20, 25, 35));
            Pen tagPen(Color(static_cast<BYTE>(100 * barAlpha), 210, 225, 245), 1.0f);
            g.FillPath(&tagBg, &tagPath);
            g.DrawPath(&tagPen, &tagPath);

            Gdiplus::Font tagFont(L"Segoe UI", 7.0f, FontStyleBold, UnitPoint);
            StringFormat tagSf;
            tagSf.SetAlignment(StringAlignmentCenter);
            tagSf.SetLineAlignment(StringAlignmentCenter);
            tagSf.SetFormatFlags(StringFormatFlagsNoWrap);
            SolidBrush tagText(Color(static_cast<BYTE>(220 * barAlpha), 235, 245, 255));
            std::wstring tagLabel = (m_currentEffect == 2) ? L"向下展开 2" :
                                    (m_currentEffect == 3) ? L"向上展开 3" : L"双向卷轴 1";
            tagLabel += (m_animSpeed == AnimSpeed::Speed2_0s) ? L" (2.0s)" : L" (1.5s)";
            g.DrawString(tagLabel.c_str(), -1, &tagFont, tagDst, &tagSf, &tagText);
        }

        // (b) 顶部窗口操作按钮（最小化、卷轴折叠切换、置顶、关闭）
        auto drawWinSprite = [&](int btnId, int col) {
            auto* b = FindBtn(btnId);
            if (!b) return;
            float hProg = b->hoverAnim.current;
            GlassRenderer::DrawImageAlpha(g, m_winBtnsBmp.get(), b->bounds, col * 52, 0, 52, 52,
                                          barAlpha * (0.85f + 0.15f * hProg), 1.08f + 0.2f * hProg);
        };
        drawWinSprite(BTN_MINIMIZE, 0);
        drawWinSprite(BTN_MINI_TOGGLE, 7);
        drawWinSprite(BTN_TOPMOST, 6);
        drawWinSprite(BTN_CLOSE, 2);

        // 4. 底部玻璃条元素（跟随 yBot 移动）
        int srcIds[3] = { BTN_SRC_APPLE, BTN_SRC_SPOTIFY, BTN_SRC_QQ };
        for (int i = 0; i < 3; ++i) {
            if (auto* sb = FindBtn(srcIds[i])) {
                GlassRenderer::DrawPlatformLogo(g, i, sb->bounds, false, 0.78f * barAlpha);
            }
        }
        if (auto* bLib = FindBtn(BTN_LIBRARY)) {
            GlassRenderer::DrawImageAlpha(g, m_winBtnsBmp.get(), bLib->bounds, 1 * 52, 0, 52, 52, 0.85f * barAlpha, 1.08f);
        }
        if (auto* bLrc = FindBtn(BTN_LYRICS)) {
            GlassRenderer::DrawImageAlpha(g, m_winBtnsBmp.get(), bLrc->bounds, 8 * 52, 52, 52, 52, 0.85f * barAlpha, 1.08f);
        }
    }

    m_surface.Present(m_hwnd, wPx, hPx, 255);
}

LRESULT CALLBACK TestPanelWindow::WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    TestPanelWindow* self = nullptr;
    if (msg == WM_CREATE) {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
        self = static_cast<TestPanelWindow*>(cs->lpCreateParams);
        self->m_hwnd = hwnd;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    } else {
        self = reinterpret_cast<TestPanelWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    }
    return self ? self->HandleMessage(msg, wParam, lParam) : DefWindowProcW(hwnd, msg, wParam, lParam);
}

LRESULT TestPanelWindow::HandleMessage(UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE:
        m_dpi = GetDpiForWindow(m_hwnd);
        if (m_dpi == 0) m_dpi = 96;
        return 0;

    case WM_SETFOCUS:
        m_focused = true;
        m_focusAnim.target = 1.0f;
        MotionCoordinator::Instance().RequestFrame();
        return 0;

    case WM_KILLFOCUS:
        m_focused = false;
        m_focusAnim.target = 0.0f;
        MotionCoordinator::Instance().RequestFrame();
        return 0;

    case WM_MOUSEMOVE: {
        if (!m_hovering) {
            m_hovering = true;
            m_hoverGloss.target = 1.0f;
            TRACKMOUSEEVENT tme{ sizeof(tme), TME_LEAVE, m_hwnd, 0 };
            TrackMouseEvent(&tme);
            MotionCoordinator::Instance().RequestFrame();
        }

        float xDip = static_cast<float>(GlassRenderer::ToDip(GET_X_LPARAM(lParam), m_dpi));
        float yDip = static_cast<float>(GlassRenderer::ToDip(GET_Y_LPARAM(lParam), m_dpi));

        int newHover = -1;
        for (auto& b : m_buttons) {
            if (b.HitTest(xDip, yDip)) {
                newHover = b.id;
                break;
            }
        }

        if (newHover != m_hoverBtnId) {
            if (auto* oldB = FindBtn(m_hoverBtnId)) oldB->hoverAnim.target = 0.0f;
            if (auto* newB = FindBtn(newHover))    newB->hoverAnim.target = 1.0f;
            m_hoverBtnId = newHover;
            MotionCoordinator::Instance().RequestFrame();
        }
        return 0;
    }

    case WM_MOUSELEAVE: {
        m_hovering = false;
        m_hoverGloss.target = 0.0f;
        if (auto* oldB = FindBtn(m_hoverBtnId)) {
            oldB->hoverAnim.target = 0.0f;
        }
        m_hoverBtnId = -1;
        MotionCoordinator::Instance().RequestFrame();
        return 0;
    }

    case WM_LBUTTONDOWN: {
        float xDip = static_cast<float>(GlassRenderer::ToDip(GET_X_LPARAM(lParam), m_dpi));
        float yDip = static_cast<float>(GlassRenderer::ToDip(GET_Y_LPARAM(lParam), m_dpi));

        UIButton* hitBtn = nullptr;
        for (auto& b : m_buttons) {
            if (b.HitTest(xDip, yDip)) {
                hitBtn = &b;
                break;
            }
        }

        if (hitBtn) {
            m_pressedBtnId = hitBtn->id;
            hitBtn->pressAnim.SnapTo(0.92f);
            hitBtn->pressAnim.target = 1.0f;
            SetCapture(m_hwnd);
            MotionCoordinator::Instance().RequestFrame();
        } else {
            // 点击非按钮区域，允许随时按住拖拽移动整个测试窗口
            float animT = m_animProgress;
            if (animT > 0.52f) {
                const float barH = 20.0f;
                const float cy = DEFAULT_HEIGHT_DIP * 0.5f;
                float yTop = 0.0f, yBot = DEFAULT_HEIGHT_DIP - barH;
                if (animT <= 0.70f) {
                    float u = (animT - 0.52f) / 0.18f;
                    float s = 3.0f * u * u - 2.0f * u * u * u;
                    if (m_currentEffect == 2) { yTop = 0.0f; yBot = s * barH; }
                    else if (m_currentEffect == 3) { yTop = (DEFAULT_HEIGHT_DIP - barH) - s * barH; yBot = DEFAULT_HEIGHT_DIP - barH; }
                    else { yTop = (cy - barH * 0.5f) - s * (barH * 0.5f); yBot = (cy - barH * 0.5f) + s * (barH * 0.5f); }
                } else {
                    float p = (animT - 0.70f) / 0.30f;
                    float s = 3.0f * p * p - 2.0f * p * p * p;
                    if (m_currentEffect == 2) { yTop = 0.0f; yBot = barH + s * (DEFAULT_HEIGHT_DIP - 2.0f * barH); }
                    else if (m_currentEffect == 3) { yTop = (1.0f - s) * (DEFAULT_HEIGHT_DIP - 2.0f * barH); yBot = DEFAULT_HEIGHT_DIP - barH; }
                    else { yTop = (1.0f - s) * (cy - barH); yBot = (1.0f - s) * cy + s * (DEFAULT_HEIGHT_DIP - barH); }
                }

                if (yDip >= yTop - 2.0f && yDip <= yBot + 22.0f) {
                    ReleaseCapture();
                    SendMessageW(m_hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
                }
            }
        }
        return 0;
    }

    case WM_LBUTTONUP: {
        if (m_pressedBtnId != -1) {
            ReleaseCapture();
            float xDip = static_cast<float>(GlassRenderer::ToDip(GET_X_LPARAM(lParam), m_dpi));
            float yDip = static_cast<float>(GlassRenderer::ToDip(GET_Y_LPARAM(lParam), m_dpi));
            if (auto* b = FindBtn(m_pressedBtnId)) {
                if (b->HitTest(xDip, yDip) && b->onClick) {
                    b->onClick();
                }
            }
            m_pressedBtnId = -1;
            MotionCoordinator::Instance().RequestFrame();
        }
        return 0;
    }

    case WM_DPICHANGED: {
        m_dpi = HIWORD(wParam);
        auto* rc = reinterpret_cast<RECT*>(lParam);
        SetWindowPos(m_hwnd, nullptr, rc->left, rc->top, rc->right - rc->left, rc->bottom - rc->top, SWP_NOZORDER | SWP_NOACTIVATE);
        Render();
        return 0;
    }

    default:
        return DefWindowProcW(m_hwnd, msg, wParam, lParam);
    }
}

} // namespace airmuse
