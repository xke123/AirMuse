#include <windows.h>
#include <windowsx.h>
#include <unknwn.h>
#include <objidl.h>
#include <gdiplus.h>
#include <dwmapi.h>
#include <shlwapi.h>
#include <shellapi.h>
#include <memory>
#include <vector>
#include <string>
#include <cstdio>
#include <algorithm>
#include <thread>

#include "resource.h"
#include "SmtcController.hpp"

using namespace Gdiplus;

namespace {
constexpr UINT WM_SMTC_UPDATED = WM_APP + 1;
constexpr UINT WM_TRAYICON     = WM_APP + 2;
constexpr UINT_PTR TIMER_CLOCK = 1;
constexpr UINT_PTR TIMER_ANIM  = 2;
constexpr UINT_PTR TIMER_MORPH = 3;

// Logical DIP sizes (scaled by per-monitor DPI at runtime for razor-sharp text & UI)
constexpr int WIN_W_FULL = 320;
constexpr int WIN_H_FULL = 104;
constexpr int WIN_W_MINI = 268;
constexpr int WIN_H_MINI = 40;

enum BtnId {
    BTN_NONE = -1,
    BTN_STOP = 0,
    BTN_PREV = 1,
    BTN_PLAYPAUSE = 2,
    BTN_NEXT = 3,
    BTN_EJECT = 4,
    BTN_MINIMIZE = 5,
    BTN_MINI_TOGGLE = 6,
    BTN_TOPMOST = 7,
    BTN_CLOSE = 8,
    BTN_PROGRESS = 9,
    BTN_VOL_BAR = 10
};

int GetWindowDpiSafe(HWND hwnd) {
    if (hwnd) {
        UINT dpi = GetDpiForWindow(hwnd);
        if (dpi > 0) return static_cast<int>(dpi);
    }
    return 96;
}

int ToPx(int dip, int dpi) {
    return MulDiv(dip, dpi, 96);
}

int ToDip(int px, int dpi) {
    return MulDiv(px, 96, dpi);
}

void EnableFrostedBlur(HWND hwnd, int wPx, int hPx, int dpi) {
    int r = ToPx(12, dpi);
    HRGN rgn = CreateRoundRectRgn(ToPx(4, dpi), ToPx(3, dpi), wPx - ToPx(3, dpi), hPx - ToPx(2, dpi), r, r);
    DWM_BLURBEHIND bb{};
    bb.dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION;
    bb.fEnable = TRUE;
    bb.hRgnBlur = rgn;
    DwmEnableBlurBehindWindow(hwnd, &bb);
    DeleteObject(rgn);
}

struct AppState {
    HWND hwnd = nullptr;
    HINSTANCE hInst = nullptr;
    SmtcController smtc;

    int dpi = 96;
    bool miniMode = false;
    int curW = WIN_W_FULL; // Logical DIPs
    int curH = WIN_H_FULL; // Logical DIPs
    bool morphActive = false;

    bool topMost = true;
    bool hovering = false;
    float hoverAlpha = 0.0f;
    bool animActive = false;

    int hoverBtn = BTN_NONE;
    int pressedBtn = BTN_NONE;
    int simulatedVol = 80;

    std::unique_ptr<Bitmap> glassIdle;
    std::unique_ptr<Bitmap> glassFocus;
    std::unique_ptr<Bitmap> mainCtrl;
    std::unique_ptr<Bitmap> miniCtrl;
    std::unique_ptr<Bitmap> winBtns;
    std::unique_ptr<Bitmap> iconBtns;

    NOTIFYICONDATAW nid{};
};

std::unique_ptr<Bitmap> LoadPngResource(HINSTANCE hInst, UINT resId) {
    HRSRC hRes = FindResourceW(hInst, MAKEINTRESOURCEW(resId), RT_RCDATA);
    if (!hRes) return nullptr;
    DWORD size = SizeofResource(hInst, hRes);
    HGLOBAL hMem = LoadResource(hInst, hRes);
    if (!hMem) return nullptr;
    void* ptr = LockResource(hMem);
    if (!ptr || size == 0) return nullptr;

    IStream* stream = SHCreateMemStream(static_cast<const BYTE*>(ptr), size);
    if (!stream) return nullptr;
    auto bmp = std::make_unique<Bitmap>(stream);
    stream->Release();
    if (bmp->GetLastStatus() != Ok) return nullptr;
    return bmp;
}

void DrawImageAlpha(Graphics& g, Bitmap* src, Rect const& dst, int sx, int sy, int sw, int sh, float alpha, float brightness = 1.0f) {
    if (!src || alpha <= 0.01f) return;
    alpha = std::clamp(alpha, 0.0f, 1.0f);
    ColorMatrix cm = {{
        {brightness, 0, 0, 0, 0},
        {0, brightness, 0, 0, 0},
        {0, 0, brightness, 0, 0},
        {0, 0, 0, alpha, 0},
        {0, 0, 0, 0, 1}
    }};
    ImageAttributes ia;
    ia.SetColorMatrix(&cm, ColorMatrixFlagsDefault, ColorAdjustTypeBitmap);
    g.DrawImage(src, dst, sx, sy, sw, sh, UnitPixel, &ia);
}

void DrawOriginalAirPlayGlass(Graphics& g, Bitmap* glass, int dstW, int dstH, float alpha = 1.0f) {
    if (!glass || alpha <= 0.01f) return;
    const int halfW = static_cast<int>(glass->GetWidth()) / 2;   // 15
    const int halfH = static_cast<int>(glass->GetHeight()) / 2;  // 20

    ColorMatrix cm = {{
        {1, 0, 0, 0, 0},
        {0, 1, 0, 0, 0},
        {0, 0, 1, 0, 0},
        {0, 0, 0, alpha, 0},
        {0, 0, 0, 0, 1}
    }};
    ImageAttributes ia;
    ia.SetColorMatrix(&cm, ColorMatrixFlagsDefault, ColorAdjustTypeBitmap);
    ia.SetWrapMode(WrapModeTileFlipXY);

    auto drawSlice = [&](int dx, int dy, int dw, int dh, int sx, int sy, int sw, int sh) {
        if (dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0) return;
        InterpolationMode prev = g.GetInterpolationMode();
        if (sw == 1 || sh == 1) g.SetInterpolationMode(InterpolationModeNearestNeighbor);
        g.DrawImage(glass, Rect(dx, dy, dw, dh), sx, sy, sw, sh, UnitPixel, &ia);
        if (sw == 1 || sh == 1) g.SetInterpolationMode(prev);
    };

    drawSlice(0, 0, halfW, halfH, 0, 0, halfW, halfH);
    drawSlice(halfW, 0, dstW - halfW * 2, halfH, halfW, 0, 1, halfH);
    drawSlice(dstW - halfW, 0, halfW, halfH, halfW, 0, halfW, halfH);

    drawSlice(0, dstH - halfH, halfW, halfH, 0, halfH, halfW, halfH);
    drawSlice(halfW, dstH - halfH, dstW - halfW * 2, halfH, halfW, halfH, 1, halfH);
    drawSlice(dstW - halfW, dstH - halfH, halfW, halfH, halfW, halfH, halfW, halfH);

    int midH = dstH - halfH * 2;
    if (midH > 0) {
        drawSlice(0, halfH, 5, midH, 0, halfH - 1, 5, 1);
        drawSlice(dstW - 5, halfH, 5, midH, halfW * 2 - 5, halfH - 1, 5, 1);

        BYTE aTop = static_cast<BYTE>(226.0f * alpha);
        BYTE aBot = static_cast<BYTE>(236.0f * alpha);
        LinearGradientBrush bodyBrush(
            Point(0, halfH), Point(0, dstH - halfH),
            Color(aTop, 46, 46, 48),
            Color(aBot, 28, 28, 30)
        );
        g.FillRectangle(&bodyBrush, 5, halfH, dstW - 10, midH);

        Pen topEdge(Color(static_cast<BYTE>(170.0f * alpha), 15, 15, 18), 1.0f);
        Pen topHighlight(Color(static_cast<BYTE>(45.0f * alpha), 255, 255, 255), 1.0f);
        Pen botEdge(Color(static_cast<BYTE>(170.0f * alpha), 15, 15, 18), 1.0f);
        g.DrawLine(&topEdge, 5, halfH, dstW - 6, halfH);
        g.DrawLine(&topHighlight, 5, halfH + 1, dstW - 6, halfH + 1);
        g.DrawLine(&botEdge, 5, dstH - halfH - 1, dstW - 6, dstH - halfH - 1);
    } else {
        SolidBrush miniInner(Color(static_cast<BYTE>(195.0f * alpha), 32, 34, 38));
        Pen miniBorder(Color(static_cast<BYTE>(130.0f * alpha), 15, 15, 18), 1.0f);
        g.FillRectangle(&miniInner, 7, 6, dstW - 14, dstH - 12);
        g.DrawRectangle(&miniBorder, 7, 6, dstW - 15, dstH - 13);
    }
}

void DrawCapsuleProgress(Graphics& g, RectF const& r, float ratio, bool highlight) {
    GraphicsPath bgPath;
    bgPath.AddArc(r.X, r.Y, r.Height, r.Height, 90, 180);
    bgPath.AddArc(r.X + r.Width - r.Height, r.Y, r.Height, r.Height, 270, 180);
    bgPath.CloseFigure();

    SolidBrush bgBrush(Color(135, 16, 18, 22));
    Pen borderPen(Color(highlight ? 140 : 65, 255, 255, 255), 1.0f);
    g.FillPath(&bgBrush, &bgPath);
    g.DrawPath(&borderPen, &bgPath);

    if (ratio > 0.015f) {
        float fillW = (std::max)(r.Height, r.Width * (std::min)(1.0f, ratio));
        GraphicsPath fgPath;
        fgPath.AddArc(r.X + 1, r.Y + 1, r.Height - 2, r.Height - 2, 90, 180);
        fgPath.AddArc(r.X + fillW - r.Height + 1, r.Y + 1, r.Height - 2, r.Height - 2, 270, 180);
        fgPath.CloseFigure();
        LinearGradientBrush fgBrush(
            PointF(r.X, r.Y), PointF(r.X, r.Y + r.Height),
            Color(225, 175, 225, 255), Color(205, 85, 155, 215)
        );
        g.FillPath(&fgBrush, &fgPath);
    }
}

Rect GetButtonRect(AppState const& st, int idx) {
    int w = st.curW;
    if (!st.miniMode) {
        int startX = (w - 166) / 2;
        int y = 26;
        int xs[5] = { startX, startX + 32, startX + 67, startX + 102, startX + 134 };
        if (idx >= BTN_STOP && idx <= BTN_EJECT) {
            return Rect(xs[idx], y, 32, 32);
        }
        if (idx == BTN_MINIMIZE)    return Rect(w - 68, 3, 13, 13);
        if (idx == BTN_MINI_TOGGLE) return Rect(w - 52, 3, 13, 13);
        if (idx == BTN_TOPMOST)     return Rect(w - 36, 3, 13, 13);
        if (idx == BTN_CLOSE)       return Rect(w - 20, 3, 13, 13);
        if (idx == BTN_PROGRESS)    return Rect(68, 67, w - 136, 6);
        if (idx == BTN_VOL_BAR)     return Rect(w - 25, 42, 16, 38);
    } else {
        if (idx == BTN_PREV)        return Rect(12, 12, 16, 16);
        if (idx == BTN_PLAYPAUSE)   return Rect(30, 12, 16, 16);
        if (idx == BTN_STOP)        return Rect(48, 12, 16, 16);
        if (idx == BTN_NEXT)        return Rect(66, 12, 16, 16);
        if (idx == BTN_EJECT)       return Rect(84, 12, 16, 16);
        if (idx == BTN_MINI_TOGGLE) return Rect(w - 38, 13, 13, 13);
        if (idx == BTN_CLOSE)       return Rect(w - 22, 13, 13, 13);
        if (idx == BTN_PROGRESS)    return Rect(10, 31, w - 20, 3);
    }
    return Rect{};
}

int HitTestButton(AppState const& st, int xPx, int yPx) {
    if (st.hoverAlpha < 0.15f) return BTN_NONE;
    int x = ToDip(xPx, st.dpi);
    int y = ToDip(yPx, st.dpi);

    if (!st.miniMode && st.curH >= 72) {
        for (int i = BTN_STOP; i <= BTN_EJECT; ++i) {
            Rect r = GetButtonRect(st, i);
            int cx = r.X + 16;
            int cy = r.Y + 16;
            int dx = x - cx;
            int dy = y - cy;
            if (dx * dx + dy * dy <= 16 * 16) return i;
        }
    }
    for (int i = BTN_STOP; i <= BTN_VOL_BAR; ++i) {
        if (GetButtonRect(st, i).Contains(x, y)) return i;
    }
    return BTN_NONE;
}

std::wstring FormatMs(int64_t ms) {
    if (ms < 0) ms = 0;
    int totalSec = static_cast<int>(ms / 1000);
    wchar_t buf[16];
    swprintf_s(buf, L"%02d:%02d", totalSec / 60, totalSec % 60);
    return buf;
}

void RenderWindow(AppState& st) {
    int w = st.curW;
    int h = st.curH;
    int wPx = ToPx(w, st.dpi);
    int hPx = ToPx(h, st.dpi);
    float scale = static_cast<float>(st.dpi) / 96.0f;

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
        g.SetTextContrast(0);
        g.SetInterpolationMode(InterpolationModeHighQualityBicubic);
        g.SetPixelOffsetMode(PixelOffsetModeHalf);

        if (st.glassIdle) {
            DrawOriginalAirPlayGlass(g, st.glassIdle.get(), w, h, 1.0f);
        }
        if (st.glassFocus && st.hoverAlpha > 0.01f) {
            DrawOriginalAirPlayGlass(g, st.glassFocus.get(), w, h, st.hoverAlpha);
        }

        NowPlayingInfo info = st.smtc.GetSnapshot();

        FontFamily ff(L"Microsoft YaHei UI");
        Font titleFont(&ff, 13.0f, FontStyleBold, UnitPixel);
        Font subFont(&ff, 11.0f, FontStyleRegular, UnitPixel);
        Font timeFont(&ff, 10.0f, FontStyleRegular, UnitPixel);

        StringFormat centerSf;
        centerSf.SetAlignment(StringAlignmentCenter);
        centerSf.SetTrimming(StringTrimmingEllipsisCharacter);
        centerSf.SetFormatFlags(StringFormatFlagsNoWrap);

        StringFormat rightSf;
        rightSf.SetAlignment(StringAlignmentFar);
        rightSf.SetFormatFlags(StringFormatFlagsNoWrap);

        StringFormat leftSf;
        leftSf.SetAlignment(StringAlignmentNear);
        leftSf.SetTrimming(StringTrimmingEllipsisCharacter);
        leftSf.SetFormatFlags(StringFormatFlagsNoWrap);

        float ratio = (info.durationMs > 0)
            ? static_cast<float>(info.positionMs) / static_cast<float>(info.durationMs)
            : 0.0f;

        if (h > 64) {
            float bodyFade = std::clamp((static_cast<float>(h) - 64.0f) / 40.0f, 0.0f, 1.0f);
            float iconAlpha = (0.42f + 0.48f * st.hoverAlpha) * bodyFade;
            if (st.iconBtns) {
                DrawImageAlpha(g, st.iconBtns.get(), Rect(9, 25, 15, 15), 15, 0, 15, 15, iconAlpha);
                DrawImageAlpha(g, st.iconBtns.get(), Rect(9, 43, 15, 15), 45, 0, 15, 15, iconAlpha);

                int volIdx = (st.simulatedVol <= 0) ? 5 : (6 + (std::min)(4, st.simulatedVol / 20));
                DrawImageAlpha(g, st.iconBtns.get(), Rect(w - 24, 24, 15, 15), volIdx * 15, 0, 15, 15, iconAlpha);
            }

            float idleAlpha = (1.0f - st.hoverAlpha) * bodyFade;
            if (idleAlpha > 0.02f) {
                BYTE aTitle = static_cast<BYTE>(245.0f * idleAlpha);
                BYTE aSub   = static_cast<BYTE>(185.0f * idleAlpha);
                BYTE aShad  = static_cast<BYTE>(150.0f * idleAlpha);
                SolidBrush shadowBrush(Color(aShad, 0, 0, 0));
                SolidBrush titleBrush(Color(aTitle, 244, 247, 252));
                SolidBrush subBrush(Color(aSub, 180, 190, 206));

                RectF rTitle(36.0f, 25.0f, static_cast<REAL>(w - 72), 19.0f);
                RectF rShadow = rTitle; rShadow.Y += 1.0f;
                g.DrawString(info.title.c_str(), -1, &titleFont, rShadow, &centerSf, &shadowBrush);
                g.DrawString(info.title.c_str(), -1, &titleFont, rTitle, &centerSf, &titleBrush);

                RectF rSub(36.0f, 45.0f, static_cast<REAL>(w - 72), 16.0f);
                g.DrawString(info.artist.c_str(), -1, &subFont, rSub, &centerSf, &subBrush);
            }

            float ctrlAlpha = st.hoverAlpha * bodyFade;
            if (ctrlAlpha > 0.02f) {
                auto drawMainBtn = [&](int btnIdx, int spriteIdx) {
                    Rect r = GetButtonRect(st, btnIdx);
                    bool isHover = (st.hoverBtn == btnIdx);
                    bool isPress = (st.pressedBtn == btnIdx);
                    if (isPress) r.Y += 1;

                    float a = ctrlAlpha * (isHover || isPress ? 1.0f : 0.80f);
                    float bright = isPress ? 1.25f : (isHover ? 1.15f : 1.0f);
                    DrawImageAlpha(g, st.mainCtrl.get(), r, spriteIdx * 32, 0, 32, 32, a, bright);
                };
                drawMainBtn(BTN_STOP, 0);
                drawMainBtn(BTN_PREV, 1);
                drawMainBtn(BTN_PLAYPAUSE, info.isPlaying ? 3 : 2);
                drawMainBtn(BTN_NEXT, 4);
                drawMainBtn(BTN_EJECT, 5);

                auto drawWinBtn = [&](int btnIdx, int col) {
                    Rect r = GetButtonRect(st, btnIdx);
                    float a = ctrlAlpha * (st.hoverBtn == btnIdx ? 1.0f : 0.72f);
                    DrawImageAlpha(g, st.winBtns.get(), r, col * 13, 0, 13, 13, a, st.hoverBtn == btnIdx ? 1.2f : 1.0f);
                };
                drawWinBtn(BTN_MINIMIZE, 0);
                drawWinBtn(BTN_MINI_TOGGLE, 7);
                drawWinBtn(BTN_TOPMOST, st.topMost ? 6 : 5);
                drawWinBtn(BTN_CLOSE, 2);

                for (int seg = 0; seg < 8; ++seg) {
                    int segY = 74 - seg * 4;
                    bool active = (seg * 12) < st.simulatedVol;
                    BYTE va = static_cast<BYTE>((active ? 195.0f : 65.0f) * ctrlAlpha);
                    SolidBrush vb(active ? Color(va, 175, 220, 250) : Color(va, 255, 255, 255));
                    g.FillRectangle(&vb, w - 20, segY, 7, 2);
                }

                DrawImageAlpha(g, st.winBtns.get(), Rect(18, h - 16, 13, 13), 3 * 13, 0, 13, 13, ctrlAlpha * 0.65f);
                DrawImageAlpha(g, st.winBtns.get(), Rect(w - 31, h - 16, 13, 13), 8 * 13, 13, 13, 13, ctrlAlpha * 0.65f);
            }

            if (bodyFade > 0.25f) {
                Rect pr = GetButtonRect(st, BTN_PROGRESS);
                DrawCapsuleProgress(g, RectF(static_cast<REAL>(pr.X), static_cast<REAL>(pr.Y),
                    static_cast<REAL>(pr.Width), 6.0f), ratio, st.hoverBtn == BTN_PROGRESS);

                BYTE ta = static_cast<BYTE>(210.0f * bodyFade);
                SolidBrush timeBrush(Color(ta, 205, 216, 230));
                std::wstring curStr = FormatMs(info.positionMs);
                std::wstring totStr = FormatMs(info.durationMs);
                g.DrawString(curStr.c_str(), -1, &timeFont,
                    RectF(26.0f, 64.0f, 38.0f, 13.0f), &rightSf, &timeBrush);
                g.DrawString(totStr.c_str(), -1, &timeFont,
                    RectF(static_cast<REAL>(w - 64), 64.0f, 38.0f, 13.0f), &leftSf, &timeBrush);
            }
        } else {
            float idleAlpha = 1.0f - st.hoverAlpha;
            if (idleAlpha > 0.02f) {
                SolidBrush tb(Color(static_cast<BYTE>(245.0f * idleAlpha), 244, 247, 252));
                SolidBrush subTb(Color(static_cast<BYTE>(180.0f * idleAlpha), 180, 194, 212));

                std::wstring displayTitle = info.title + L"  -  " + info.artist;
                g.DrawString(displayTitle.c_str(), -1, &subFont,
                    RectF(14.0f, 12.0f, static_cast<REAL>(w - 66), 16.0f), &leftSf, &tb);

                std::wstring curStr = FormatMs(info.positionMs);
                g.DrawString(curStr.c_str(), -1, &timeFont,
                    RectF(static_cast<REAL>(w - 50), 13.0f, 36.0f, 13.0f), &rightSf, &subTb);
            }

            if (st.hoverAlpha > 0.02f) {
                auto drawMiniBtn = [&](int btnIdx, int spriteIdx) {
                    Rect r = GetButtonRect(st, btnIdx);
                    bool isHover = (st.hoverBtn == btnIdx);
                    bool isPress = (st.pressedBtn == btnIdx);
                    if (isPress) r.Y += 1;
                    float a = st.hoverAlpha * (isHover || isPress ? 1.0f : 0.82f);
                    float bright = isPress ? 1.25f : (isHover ? 1.15f : 1.0f);
                    DrawImageAlpha(g, st.miniCtrl.get(), r, spriteIdx * 16, 0, 16, 16, a, bright);
                };
                drawMiniBtn(BTN_PREV, 1);
                drawMiniBtn(BTN_PLAYPAUSE, info.isPlaying ? 3 : 2);
                drawMiniBtn(BTN_STOP, 0);
                drawMiniBtn(BTN_NEXT, 4);
                drawMiniBtn(BTN_EJECT, 5);

                SolidBrush tb(Color(static_cast<BYTE>(235.0f * st.hoverAlpha), 240, 245, 252));
                g.DrawString(info.title.c_str(), -1, &subFont,
                    RectF(104.0f, 12.0f, static_cast<REAL>(w - 146), 16.0f), &leftSf, &tb);

                DrawImageAlpha(g, st.winBtns.get(), GetButtonRect(st, BTN_MINI_TOGGLE), 4 * 13, 0, 13, 13,
                    st.hoverAlpha * (st.hoverBtn == BTN_MINI_TOGGLE ? 1.0f : 0.78f), st.hoverBtn == BTN_MINI_TOGGLE ? 1.2f : 1.0f);
                DrawImageAlpha(g, st.winBtns.get(), GetButtonRect(st, BTN_CLOSE), 2 * 13, 0, 13, 13,
                    st.hoverAlpha * (st.hoverBtn == BTN_CLOSE ? 1.0f : 0.78f), st.hoverBtn == BTN_CLOSE ? 1.2f : 1.0f);
            }

            Rect pr = GetButtonRect(st, BTN_PROGRESS);
            SolidBrush miniBarBg(Color(95, 12, 14, 18));
            g.FillRectangle(&miniBarBg, pr);
            if (ratio > 0.01f) {
                int fw = static_cast<int>(pr.Width * std::clamp(ratio, 0.0f, 1.0f));
                SolidBrush miniBarFg(Color(215, 135, 200, 245));
                g.FillRectangle(&miniBarFg, pr.X, pr.Y, fw, pr.Height);
            }
        }
    }

    RECT rcWin{};
    GetWindowRect(st.hwnd, &rcWin);
    POINT ptDst{ rcWin.left, rcWin.top };
    SIZE szWnd{ wPx, hPx };
    POINT ptSrc{ 0, 0 };
    BLENDFUNCTION bf{ AC_SRC_OVER, 0, 255, AC_SRC_ALPHA };

    UpdateLayeredWindow(st.hwnd, hdcScreen, &ptDst, &szWnd, hdcMem, &ptSrc, 0, &bf, ULW_ALPHA);

    SelectObject(hdcMem, oldBmp);
    DeleteObject(hBmp);
    DeleteDC(hdcMem);
    ReleaseDC(nullptr, hdcScreen);
}

void StartHoverAnim(AppState& st, HWND hwnd) {
    if (!st.animActive) {
        st.animActive = true;
        SetTimer(hwnd, TIMER_ANIM, 16, nullptr);
    }
}

void StartMorphAnim(AppState& st, HWND hwnd) {
    if (!st.morphActive) {
        st.morphActive = true;
        SetTimer(hwnd, TIMER_MORPH, 16, nullptr);
    }
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto* st = reinterpret_cast<AppState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));

    switch (msg) {
    case WM_CREATE: {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
        st = static_cast<AppState*>(cs->lpCreateParams);
        st->hwnd = hwnd;
        st->dpi = GetWindowDpiSafe(hwnd);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(st));

        int wPx = ToPx(st->curW, st->dpi);
        int hPx = ToPx(st->curH, st->dpi);
        SetWindowPos(hwnd, nullptr, 0, 0, wPx, hPx, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        EnableFrostedBlur(hwnd, wPx, hPx, st->dpi);

        st->glassIdle  = LoadPngResource(st->hInst, IDR_PNG_WINDOWGLASS);
        st->glassFocus = LoadPngResource(st->hInst, IDR_PNG_WINDOWGLASS_FCS);
        st->mainCtrl   = LoadPngResource(st->hInst, IDR_PNG_MAINCONTROL);
        st->miniCtrl   = LoadPngResource(st->hInst, IDR_PNG_MINICONTROL);
        st->winBtns    = LoadPngResource(st->hInst, IDR_PNG_WINDOWBUTTON);
        st->iconBtns   = LoadPngResource(st->hInst, IDR_PNG_ICONBUTTON);

        st->nid.cbSize = sizeof(NOTIFYICONDATAW);
        st->nid.hWnd = hwnd;
        st->nid.uID = 1;
        st->nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
        st->nid.uCallbackMessage = WM_TRAYICON;
        st->nid.hIcon = LoadIconW(st->hInst, MAKEINTRESOURCEW(IDR_MAIN_ICON));
        wcscpy_s(st->nid.szTip, L"AirMuse - Apple Music Controller");
        Shell_NotifyIconW(NIM_ADD, &st->nid);

        SetTimer(hwnd, TIMER_CLOCK, 1000, nullptr);
        RenderWindow(*st);

        std::thread([hwnd, st]() {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            st->smtc.Initialize(hwnd, WM_SMTC_UPDATED);
        }).detach();

        return 0;
    }
    case WM_DPICHANGED:
        if (st) {
            st->dpi = HIWORD(wParam);
            int wPx = ToPx(st->curW, st->dpi);
            int hPx = ToPx(st->curH, st->dpi);
            SetWindowPos(hwnd, nullptr, 0, 0, wPx, hPx, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
            EnableFrostedBlur(hwnd, wPx, hPx, st->dpi);
            RenderWindow(*st);
        }
        return 0;

    case WM_SMTC_UPDATED:
        if (st) RenderWindow(*st);
        return 0;

    case WM_TIMER:
        if (!st) return 0;
        if (wParam == TIMER_CLOCK) {
            RenderWindow(*st);
        } else if (wParam == TIMER_ANIM) {
            float target = st->hovering ? 1.0f : 0.0f;
            float step = 0.14f;
            if (st->hoverAlpha < target) {
                st->hoverAlpha = (std::min)(target, st->hoverAlpha + step);
            } else if (st->hoverAlpha > target) {
                st->hoverAlpha = (std::max)(target, st->hoverAlpha - step);
            }
            if (st->hoverAlpha == target) {
                st->animActive = false;
                KillTimer(hwnd, TIMER_ANIM);
            }
            RenderWindow(*st);
        } else if (wParam == TIMER_MORPH) {
            int tw = st->miniMode ? WIN_W_MINI : WIN_W_FULL;
            int th = st->miniMode ? WIN_H_MINI : WIN_H_FULL;

            auto stepToward = [](int cur, int tgt) -> int {
                if (cur == tgt) return cur;
                int diff = tgt - cur;
                int delta = diff / 3;
                if (delta == 0) delta = (diff > 0) ? 1 : -1;
                return cur + delta;
            };

            st->curW = stepToward(st->curW, tw);
            st->curH = stepToward(st->curH, th);

            int wPx = ToPx(st->curW, st->dpi);
            int hPx = ToPx(st->curH, st->dpi);
            SetWindowPos(hwnd, nullptr, 0, 0, wPx, hPx,
                SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
            EnableFrostedBlur(hwnd, wPx, hPx, st->dpi);

            if (st->curW == tw && st->curH == th) {
                st->morphActive = false;
                KillTimer(hwnd, TIMER_MORPH);
            }
            RenderWindow(*st);
        }
        return 0;

    case WM_MOUSEMOVE:
        if (st) {
            if (!st->hovering) {
                st->hovering = true;
                StartHoverAnim(*st, hwnd);
            }
            int hit = HitTestButton(*st, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
            if (hit != st->hoverBtn) {
                st->hoverBtn = hit;
                RenderWindow(*st);
            }
            TRACKMOUSEEVENT tme{ sizeof(tme), TME_LEAVE, hwnd, 0 };
            TrackMouseEvent(&tme);
        }
        return 0;

    case WM_MOUSELEAVE:
        if (st) {
            st->hovering = false;
            st->hoverBtn = BTN_NONE;
            st->pressedBtn = BTN_NONE;
            StartHoverAnim(*st, hwnd);
        }
        return 0;

    case WM_LBUTTONDBLCLK:
        if (st && HitTestButton(*st, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)) == BTN_NONE) {
            st->miniMode = !st->miniMode;
            StartMorphAnim(*st, hwnd);
        }
        return 0;

    case WM_LBUTTONDOWN:
        if (st) {
            int hit = HitTestButton(*st, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
            if (hit == BTN_NONE) {
                ReleaseCapture();
                SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
            } else {
                st->pressedBtn = hit;
                RenderWindow(*st);
            }
        }
        return 0;

    case WM_LBUTTONUP:
        if (st && st->pressedBtn != BTN_NONE) {
            int xDip = ToDip(GET_X_LPARAM(lParam), st->dpi);
            int yDip = ToDip(GET_Y_LPARAM(lParam), st->dpi);
            int hit = HitTestButton(*st, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
            int act = (hit == st->pressedBtn) ? hit : BTN_NONE;
            st->pressedBtn = BTN_NONE;
            RenderWindow(*st);

            switch (act) {
            case BTN_STOP:      st->smtc.Stop(); break;
            case BTN_PREV:      st->smtc.Previous(); break;
            case BTN_PLAYPAUSE: st->smtc.PlayPause(); break;
            case BTN_NEXT:      st->smtc.Next(); break;
            case BTN_EJECT:
                ShellExecuteW(nullptr, L"open", L"music:", nullptr, nullptr, SW_SHOWNORMAL);
                break;
            case BTN_MINIMIZE:  ShowWindow(hwnd, SW_HIDE); break;
            case BTN_MINI_TOGGLE:
                st->miniMode = !st->miniMode;
                StartMorphAnim(*st, hwnd);
                break;
            case BTN_TOPMOST:
                st->topMost = !st->topMost;
                SetWindowPos(hwnd, st->topMost ? HWND_TOPMOST : HWND_NOTOPMOST,
                    0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
                RenderWindow(*st);
                break;
            case BTN_CLOSE:     PostQuitMessage(0); break;
            case BTN_PROGRESS: {
                Rect pr = GetButtonRect(*st, BTN_PROGRESS);
                NowPlayingInfo info = st->smtc.GetSnapshot();
                if (pr.Width > 0 && info.durationMs > 0) {
                    int64_t targetMs = (static_cast<int64_t>(xDip - pr.X) * info.durationMs) / pr.Width;
                    int deltaSec = static_cast<int>((targetMs - info.positionMs) / 1000);
                    st->smtc.SeekRelativeSeconds(deltaSec);
                }
                break;
            }
            case BTN_VOL_BAR: {
                Rect vr = GetButtonRect(*st, BTN_VOL_BAR);
                bool up = (yDip < vr.Y + vr.Height / 2);
                st->simulatedVol = std::clamp(st->simulatedVol + (up ? 10 : -10), 0, 100);
                st->smtc.VolumeStep(up);
                RenderWindow(*st);
                break;
            }
            }
        }
        return 0;

    case WM_MOUSEWHEEL:
        if (st) {
            int delta = GET_WHEEL_DELTA_WPARAM(wParam);
            st->simulatedVol = std::clamp(st->simulatedVol + (delta > 0 ? 5 : -5), 0, 100);
            st->smtc.VolumeStep(delta > 0);
            RenderWindow(*st);
        }
        return 0;

    case WM_TRAYICON:
        if (lParam == WM_LBUTTONUP || lParam == WM_LBUTTONDBLCLK) {
            ShowWindow(hwnd, SW_SHOW);
            SetForegroundWindow(hwnd);
        } else if (lParam == WM_RBUTTONUP) {
            PostQuitMessage(0);
        }
        return 0;

    case WM_DESTROY:
        if (st) {
            KillTimer(hwnd, TIMER_CLOCK);
            KillTimer(hwnd, TIMER_ANIM);
            KillTimer(hwnd, TIMER_MORPH);
            Shell_NotifyIconW(NIM_DELETE, &st->nid);
            st->smtc.Shutdown();
        }
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}
} // namespace

int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE, PWSTR, int) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    winrt::init_apartment(winrt::apartment_type::single_threaded);

    GdiplusStartupInput gdiInput;
    ULONG_PTR gdiToken = 0;
    GdiplusStartup(&gdiToken, &gdiInput, nullptr);

    AppState state;
    state.hInst = hInst;

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.style = CS_DBLCLKS;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.hIcon = LoadIconW(hInst, MAKEINTRESOURCEW(IDR_MAIN_ICON));
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = L"AirMuseLayeredWindow";
    RegisterClassExW(&wc);

    HWND hwnd = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        wc.lpszClassName,
        L"AirMuse",
        WS_POPUP,
        120, 120, WIN_W_FULL, WIN_H_FULL,
        nullptr, nullptr, hInst, &state
    );
    ShowWindow(hwnd, SW_SHOW);

    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    GdiplusShutdown(gdiToken);
    return static_cast<int>(msg.wParam);
}