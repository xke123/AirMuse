#include <windows.h>
#include <windowsx.h>
#include <unknwn.h>
#include <objidl.h>
#include <gdiplus.h>
#include <dwmapi.h>
#include <shlwapi.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <memory>
#include <vector>
#include <string>
#include <cstdio>
#include <algorithm>
#include <thread>

#include "resource.h"
#include "SmtcController.hpp"
#include "LyricsProvider.hpp"
#include "WebLibraryPanel.hpp"

using namespace Gdiplus;

namespace {
constexpr UINT WM_SMTC_UPDATED   = WM_APP + 1;
constexpr UINT WM_TRAYICON       = WM_APP + 2;
constexpr UINT WM_LYRICS_UPDATED = WM_APP + 3;
constexpr UINT WM_WEB_UPDATED    = WM_APP + 4;
constexpr UINT_PTR TIMER_CLOCK   = 1;
constexpr UINT_PTR TIMER_ANIM    = 2;
constexpr UINT_PTR TIMER_MORPH   = 3;
constexpr UINT_PTR TIMER_LRC_SCR = 4;

enum DockSide { DOCK_NONE = 0, DOCK_BOTTOM, DOCK_TOP, DOCK_LEFT, DOCK_RIGHT };

constexpr int WIN_W_FULL   = 320;
constexpr int WIN_H_FULL   = 104;
constexpr int WIN_W_MINI   = 320;
constexpr int WIN_H_MINI   = 26;

constexpr int LRC_W_FULL   = 320;
constexpr int LRC_H_FULL   = 216;
constexpr int LRC_W_MINI   = 320;
constexpr int LRC_H_MINI   = 26;

constexpr int LIB_W        = 320;
constexpr int LIB_H        = WIN_H_FULL + LRC_H_FULL - 2; // 318 = exact sum of left two panels

constexpr int SNAP_DIST_PX     = 16;
constexpr int DOCK_OVERLAP_DIP = 2;

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
    BTN_VOL_BAR = 10,
    BTN_LYRICS = 11,
    BTN_LIBRARY = 12
};

enum LrcBtnId {
    LRC_BTN_NONE = -1,
    LRC_BTN_MINI = 0,
    LRC_BTN_CLOSE = 1
};

int GetWindowDpiSafe(HWND hwnd) {
    if (hwnd) {
        UINT dpi = GetDpiForWindow(hwnd);
        if (dpi > 0) return static_cast<int>(dpi);
    }
    return 96;
}

int ToPx(int dip, int dpi) { return MulDiv(dip, dpi, 96); }
int ToDip(int px, int dpi) { return MulDiv(px, 96, dpi); }

void EnableFrostedBlur(HWND hwnd, int wPx, int hPx, int dpi, bool mini) {
    int r = ToPx(mini ? 4 : 10, dpi);
    HRGN rgn = CreateRoundRectRgn(ToPx(2, dpi), ToPx(2, dpi), wPx - ToPx(2, dpi), hPx - ToPx(2, dpi), r, r);
    DWM_BLURBEHIND bb{};
    bb.dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION;
    bb.fEnable = TRUE;
    bb.hRgnBlur = rgn;
    DwmEnableBlurBehindWindow(hwnd, &bb);
    DeleteObject(rgn);
}

struct AppState {
    HWND hwndMain = nullptr;
    HWND hwndLyrics = nullptr;
    HWND hwndLibrary = nullptr;
    HWND hwndWebHost = nullptr;
    WebLibraryPanel webLib;
    HINSTANCE hInst = nullptr;
    SmtcController smtc;
    LyricsProvider lyrics;

    int dpi = 96;

    bool miniMode = false;
    int curW = WIN_W_FULL;
    int curH = WIN_H_FULL;
    bool topMost = true;
    bool winFocused = true;
    bool hovering = false;
    float hoverAlpha = 0.0f;
    int hoverBtn = BTN_NONE;
    int pressedBtn = BTN_NONE;
    int simulatedVol = 80;

    bool lyricsVisible = false;
    bool lyricsMini = false;
    DockSide lyricsDockSide = DOCK_BOTTOM;
    bool lrcScrollActive = false;

    bool libVisible = false;
    bool libDocked = true;
    bool libHovering = false;
    float libHoverAlpha = 0.0f;
    int libHoverBtn = -1;
    int libPressedBtn = -1;
    bool syncingMove = false;
    int lrcW = LRC_W_FULL;
    int lrcH = LRC_H_FULL;
    bool lrcHovering = false;
    float lrcHoverAlpha = 0.0f;
    int lrcHoverBtn = LRC_BTN_NONE;
    int lrcPressedBtn = LRC_BTN_NONE;

    bool animActive = false;
    bool morphActive = false;

    int64_t lastSmtcPosMs = 0;
    ULONGLONG lastSmtcTick = 0;
    std::wstring lastTrackKey;
    float lyricsScrollY = 0.0f;

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

void AddRoundedRectPath(GraphicsPath& path, float x, float y, float w, float h, float r) {
    float d = r * 2.0f;
    if (d > w) d = w;
    if (d > h) d = h;
    path.AddArc(x, y, d, d, 180.0f, 90.0f);
    path.AddArc(x + w - d, y, d, d, 270.0f, 90.0f);
    path.AddArc(x + w - d, y + h - d, d, d, 0.0f, 90.0f);
    path.AddArc(x, y + h - d, d, d, 90.0f, 90.0f);
    path.CloseFigure();
}

void DrawAirPlayGlassFrame(Graphics& g, int dstW, int dstH, float hoverGloss = 0.0f, bool focused = true) {
    const float padX = 2.0f;
    const float padY = 2.0f;
    const float fw = static_cast<float>(dstW) - padX * 2.0f;
    const float fh = static_cast<float>(dstH) - padY * 2.0f;

    if (dstH <= 34) {
        const float mPadX = 4.0f;
        const float mPadY = 3.0f;
        const float mW = static_cast<float>(dstW) - mPadX * 2.0f;
        const float mH = static_cast<float>(dstH) - mPadY * 2.0f;

        // 1. Feathered outer drop shadow (3 soft stepped rings)
        for (int s = 3; s >= 1; --s) {
            GraphicsPath sp;
            float e = static_cast<float>(s);
            AddRoundedRectPath(sp, mPadX - e * 0.7f, mPadY - e * 0.4f + 0.8f, mW + e * 1.4f, mH + e * 1.2f, 2.0f + e * 0.5f);
            Pen spPen(Color(static_cast<BYTE>(14 * (4 - s)), 0, 0, 0), 1.4f);
            g.DrawPath(&spPen, &sp);
        }

        GraphicsPath outer;
        AddRoundedRectPath(outer, mPadX, mPadY, mW, mH, 2.0f);

        // 2. Subtle high-translucency glass gradient (calm on dark backgrounds, airy crystal on white)
        BYTE aTop = static_cast<BYTE>(36 + 22 * hoverGloss);
        BYTE aMid = static_cast<BYTE>(14 + 10 * hoverGloss);
        BYTE aBot = static_cast<BYTE>(54 + 14 * hoverGloss);
        LinearGradientBrush glassBrush(
            PointF(0, mPadY), PointF(0, mPadY + mH),
            Color(aTop, 240, 244, 250),
            Color(aBot, 16, 18, 22)
        );
        Color colors[3] = { Color(aTop, 240, 244, 250), Color(aMid, 140, 146, 156), Color(aBot, 16, 18, 22) };
        REAL pos[3] = { 0.0f, 0.50f, 1.0f };
        glassBrush.SetInterpolationColors(colors, pos, 3);
        g.FillPath(&glassBrush, &outer);

        // 3. Calm 1px outer dark hairline + subdued inner glass rim (no harsh white glare on dark)
        Pen outerDark(Color(135, 12, 14, 18), 1.0f);
        Pen innerRim(Color(static_cast<BYTE>(46 + 22 * hoverGloss), 255, 255, 255), 1.0f);
        g.DrawPath(&outerDark, &outer);

        GraphicsPath inner;
        AddRoundedRectPath(inner, mPadX + 1.0f, mPadY + 1.0f, mW - 2.0f, mH - 2.0f, 1.5f);
        g.DrawPath(&innerRim, &inner);
        return;
    }

    const float radius = 6.0f;
    const float barH = 18.0f;

    {
        GraphicsPath shad;
        AddRoundedRectPath(shad, padX - 0.5f, padY + 0.5f, fw + 1.0f, fh + 1.0f, radius + 1.0f);
        Pen shadPen(Color(55, 0, 0, 0), 2.0f);
        g.DrawPath(&shadPen, &shad);
    }

    GraphicsPath outer;
    AddRoundedRectPath(outer, padX, padY, fw, fh, radius);

    GraphicsState saved = g.Save();
    g.SetClip(&outer);

    LinearGradientBrush topGlass(
        PointF(0, padY), PointF(0, padY + barH),
        Color(92, 220, 225, 232),
        Color(46, 150, 155, 162)
    );
    g.FillRectangle(&topGlass, padX, padY, fw, barH);

    float botY = padY + fh - barH;
    LinearGradientBrush botGlass(
        PointF(0, botY), PointF(0, padY + fh),
        Color(46, 150, 155, 162),
        Color(82, 210, 215, 222)
    );
    g.FillRectangle(&botGlass, padX, botY, fw, barH);

    float midY = padY + barH;
    float midH = fh - barH * 2.0f;
    if (midH > 0.0f) {
        LinearGradientBrush bodyBrush(
            PointF(0, midY), PointF(0, midY + midH),
            Color(232, 42, 42, 44),
            Color(240, 26, 26, 28)
        );
        g.FillRectangle(&bodyBrush, padX + 2.0f, midY, fw - 4.0f, midH);
    }

    g.Restore(saved);

    Pen outerDark(Color(145, 12, 12, 14), 1.0f);
    Pen innerRim(Color(focused ? 52 : 34, 255, 255, 255), 1.0f);

    g.DrawPath(&outerDark, &outer);

    GraphicsPath inner;
    AddRoundedRectPath(inner, padX + 1.0f, padY + 1.0f, fw - 2.0f, fh - 2.0f, radius - 1.0f);
    g.DrawPath(&innerRim, &inner);

    if (midH > 2.0f) {
        g.DrawLine(&innerRim, padX + 1.0f, midY - 1.0f, padX + fw - 2.0f, midY - 1.0f);
        g.DrawLine(&outerDark, padX + 1.0f, midY, padX + fw - 2.0f, midY);

        g.DrawLine(&outerDark, padX + 1.0f, botY, padX + fw - 2.0f, botY);
        g.DrawLine(&innerRim, padX + 1.0f, botY + 1.0f, padX + fw - 2.0f, botY + 1.0f);
    }
}

void DrawTextHalo(Graphics& g, float cx, float cy, float rx, float ry, BYTE centerAlpha) {
    if (centerAlpha <= 4 || rx <= 2.0f || ry <= 2.0f) return;
    GraphicsPath p;
    p.AddEllipse(cx - rx, cy - ry, rx * 2.0f, ry * 2.0f);
    PathGradientBrush pgb(&p);
    pgb.SetCenterColor(Color(centerAlpha, 12, 14, 18));
    Color surround(0, 12, 14, 18);
    int cnt = 1;
    pgb.SetSurroundColors(&surround, &cnt);
    pgb.SetFocusScales(0.45f, 0.35f);
    g.FillPath(&pgb, &p);
}

void DrawGlyphHaloText(Graphics& g, std::wstring const& text, FontFamily const& ff, float emSize,
                       RectF const& rect, StringFormat const& sf, Color textColor, float alphaScale) {
    if (text.empty() || alphaScale <= 0.02f) return;
    GraphicsPath path;
    path.AddString(text.c_str(), -1, &ff, FontStyleRegular, emSize, rect, &sf);

    // Multi-pass round-joined outer glow tightly hugging the exact glyph silhouettes
    struct GlowPass { float width; BYTE alpha; };
    const GlowPass passes[] = {
        { 11.0f, 18 },
        { 7.5f,  28 },
        { 4.5f,  45 },
        { 2.2f,  75 }
    };
    for (auto const& gp : passes) {
        BYTE a = static_cast<BYTE>(static_cast<float>(gp.alpha) * alphaScale);
        if (a == 0) continue;
        Pen pen(Color(a, 8, 10, 14), gp.width);
        pen.SetLineJoin(LineJoinRound);
        g.DrawPath(&pen, &path);
    }

    BYTE ta = static_cast<BYTE>(static_cast<float>(textColor.GetA()) * alphaScale);
    SolidBrush fill(Color(ta, textColor.GetR(), textColor.GetG(), textColor.GetB()));
    g.FillPath(&fill, &path);
}

void DrawCapsuleProgress(Graphics& g, RectF const& r, float ratio, bool highlight) {
    GraphicsPath bgPath;
    bgPath.AddArc(r.X, r.Y, r.Height, r.Height, 90, 180);
    bgPath.AddArc(r.X + r.Width - r.Height, r.Y, r.Height, r.Height, 270, 180);
    bgPath.CloseFigure();

    SolidBrush bgBrush(Color(135, 16, 18, 22));
    Pen borderPen(Color(highlight ? 130 : 58, 255, 255, 255), 1.0f);
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
            Color(215, 175, 225, 255), Color(195, 85, 155, 215)
        );
        g.FillPath(&fgBrush, &fgPath);
    }
}

Rect GetButtonRect(AppState const& st, int idx) {
    int w = st.curW;
    int h = st.curH;
    if (!st.miniMode) {
        int startX = (w - 166) / 2;
        int y = 26;
        int xs[5] = { startX, startX + 32, startX + 67, startX + 102, startX + 134 };
        if (idx >= BTN_STOP && idx <= BTN_EJECT) {
            return Rect(xs[idx], y, 32, 32);
        }
        if (idx == BTN_MINIMIZE)    return Rect(w - 66, 4, 13, 13);
        if (idx == BTN_MINI_TOGGLE) return Rect(w - 50, 4, 13, 13);
        if (idx == BTN_TOPMOST)     return Rect(w - 34, 4, 13, 13);
        if (idx == BTN_CLOSE)       return Rect(w - 18, 4, 13, 13);
        if (idx == BTN_PROGRESS)    return Rect(68, 63, w - 136, 14);
        if (idx == BTN_VOL_BAR)     return Rect(w - 25, 42, 16, 38);
        if (idx == BTN_LIBRARY)     return Rect(w - 46, h - 17, 13, 13);
        if (idx == BTN_LYRICS)      return Rect(w - 28, h - 17, 13, 13);
    } else {
        int startX = (w - 92) / 2;
        int xs[5] = { startX, startX + 18, startX + 37, startX + 56, startX + 74 };
        if (idx >= BTN_STOP && idx <= BTN_EJECT) {
            return Rect(xs[idx], 5, 16, 16);
        }
        if (idx == BTN_LYRICS)      return Rect(w - 52, 6, 13, 13);
        if (idx == BTN_MINI_TOGGLE) return Rect(w - 36, 6, 13, 13);
        if (idx == BTN_CLOSE)       return Rect(w - 20, 6, 13, 13);
    }
    return Rect{};
}

Rect GetLyricsButtonRect(AppState const& st, int idx) {
    int w = st.lrcW;
    int y = st.lyricsMini ? 6 : 4;
    if (idx == LRC_BTN_MINI)  return Rect(w - 36, y, 13, 13);
    if (idx == LRC_BTN_CLOSE) return Rect(w - 20, y, 13, 13);
    return Rect{};
}

int HitTestMain(AppState const& st, int xPx, int yPx) {
    int x = ToDip(xPx, st.dpi);
    int y = ToDip(yPx, st.dpi);

    if (!st.miniMode) {
        if (GetButtonRect(st, BTN_LIBRARY).Contains(x, y)) return BTN_LIBRARY;
        if (GetButtonRect(st, BTN_LYRICS).Contains(x, y)) return BTN_LYRICS;
        if (GetButtonRect(st, BTN_PROGRESS).Contains(x, y)) return BTN_PROGRESS;
    }
    if (st.hoverAlpha < 0.15f) return BTN_NONE;
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
    for (int i = BTN_STOP; i <= BTN_LIBRARY; ++i) {
        if (GetButtonRect(st, i).Contains(x, y)) return i;
    }
    return BTN_NONE;
}

int HitTestLyrics(AppState const& st, int xPx, int yPx) {
    if (st.lrcHoverAlpha < 0.15f) return LRC_BTN_NONE;
    int x = ToDip(xPx, st.dpi);
    int y = ToDip(yPx, st.dpi);
    for (int i = LRC_BTN_MINI; i <= LRC_BTN_CLOSE; ++i) {
        if (GetLyricsButtonRect(st, i).Contains(x, y)) return i;
    }
    return LRC_BTN_NONE;
}

std::wstring FormatMs(int64_t ms) {
    if (ms < 0) ms = 0;
    int totalSec = static_cast<int>(ms / 1000);
    wchar_t buf[16];
    swprintf_s(buf, L"%02d:%02d", totalSec / 60, totalSec % 60);
    return buf;
}

int64_t GetLivePositionMs(AppState const& st, NowPlayingInfo const& info) {
    if (!info.isPlaying || st.lastSmtcTick == 0) return info.positionMs;
    ULONGLONG elapsed = GetTickCount64() - st.lastSmtcTick;
    int64_t est = st.lastSmtcPosMs + static_cast<int64_t>(elapsed);
    if (info.durationMs > 0 && est > info.durationMs) est = info.durationMs;
    return est;
}

void SyncDockedLyricsPos(AppState& st) {
    if (st.lyricsDockSide == DOCK_NONE || !st.hwndLyrics || !IsWindowVisible(st.hwndLyrics)) return;
    RECT rcMain{}, rcLrc{};
    GetWindowRect(st.hwndMain, &rcMain);
    GetWindowRect(st.hwndLyrics, &rcLrc);
    int lw = rcLrc.right - rcLrc.left;
    int lh = rcLrc.bottom - rcLrc.top;
    int ov = ToPx(DOCK_OVERLAP_DIP, st.dpi);
    int x = rcMain.left, y = rcMain.bottom - ov;
    switch (st.lyricsDockSide) {
    case DOCK_BOTTOM: x = rcMain.left; y = rcMain.bottom - ov; break;
    case DOCK_TOP:    x = rcMain.left; y = rcMain.top - lh + ov; break;
    case DOCK_LEFT:   x = rcMain.left - lw + ov; y = rcMain.top; break;
    case DOCK_RIGHT:  x = rcMain.right - ov; y = rcMain.top; break;
    default: return;
    }
    st.syncingMove = true;
    SetWindowPos(st.hwndLyrics, nullptr, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    st.syncingMove = false;
}

bool IsWebPlayerActive(AppState const& st) {
    NowPlayingInfo web = st.webLib.GetNowPlayingSnapshot();
    NowPlayingInfo smtc = st.smtc.GetSnapshot();
    if (!web.title.empty() && web.title != L"未知曲目") {
        if (web.isPlaying || !smtc.isPlaying) return true;
    }
    return false;
}

NowPlayingInfo GetActiveNowPlaying(AppState const& st) {
    if (IsWebPlayerActive(st)) return st.webLib.GetNowPlayingSnapshot();
    return st.smtc.GetSnapshot();
}

void RenderMainWindow(AppState& st) {
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

        DrawAirPlayGlassFrame(g, w, h, st.miniMode ? st.hoverAlpha : 0.0f, st.winFocused);

        NowPlayingInfo info = GetActiveNowPlaying(st);
        int64_t livePosMs = GetLivePositionMs(st, info);

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
            ? static_cast<float>(livePosMs) / static_cast<float>(info.durationMs)
            : 0.0f;

        if (h > 50) {
            float bodyFade = std::clamp((static_cast<float>(h) - 50.0f) / 40.0f, 0.0f, 1.0f);
            float iconAlpha = (0.38f + 0.48f * st.hoverAlpha) * bodyFade;
            if (st.iconBtns) {
                DrawImageAlpha(g, st.iconBtns.get(), Rect(9, 25, 15, 15), 60, 0, 60, 60, iconAlpha);
                DrawImageAlpha(g, st.iconBtns.get(), Rect(9, 43, 15, 15), 180, 0, 60, 60, iconAlpha);
                int volIdx = (st.simulatedVol <= 0) ? 5 : (6 + (std::min)(4, st.simulatedVol / 20));
                DrawImageAlpha(g, st.iconBtns.get(), Rect(w - 24, 24, 15, 15), volIdx * 60, 0, 60, 60, iconAlpha);
            }

            float idleAlpha = (1.0f - st.hoverAlpha) * bodyFade;
            if (idleAlpha > 0.02f) {
                SolidBrush shadowBrush(Color(static_cast<BYTE>(150.0f * idleAlpha), 0, 0, 0));
                SolidBrush titleBrush(Color(static_cast<BYTE>(245.0f * idleAlpha), 244, 247, 252));
                SolidBrush subBrush(Color(static_cast<BYTE>(185.0f * idleAlpha), 180, 190, 206));

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
                    if (isHover && !isPress) {
                        DrawTextHalo(g, static_cast<float>(r.X + 16), static_cast<float>(r.Y + 16), 17.0f, 17.0f,
                            static_cast<BYTE>(55.0f * ctrlAlpha));
                    }
                    float a = ctrlAlpha * (isHover || isPress ? 1.0f : 0.75f);
                    float bright = isPress ? 1.28f : (isHover ? 1.16f : 1.0f);
                    DrawImageAlpha(g, st.mainCtrl.get(), r, spriteIdx * 128, 0, 128, 128, a, bright);
                };
                drawMainBtn(BTN_STOP, 0);
                drawMainBtn(BTN_PREV, 1);
                drawMainBtn(BTN_PLAYPAUSE, info.isPlaying ? 3 : 2);
                drawMainBtn(BTN_NEXT, 4);
                drawMainBtn(BTN_EJECT, 5);

                auto drawWinBtn = [&](int btnIdx, int col) {
                    Rect r = GetButtonRect(st, btnIdx);
                    float a = ctrlAlpha * (st.hoverBtn == btnIdx ? 1.0f : 0.72f);
                    DrawImageAlpha(g, st.winBtns.get(), r, col * 52, 0, 52, 52, a, st.hoverBtn == btnIdx ? 1.2f : 1.0f);
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
                    g.FillRectangle(&vb, w - 18, segY, 7, 2);
                }
                wchar_t vbuf[8];
                swprintf_s(vbuf, L"%d", st.simulatedVol);
                SolidBrush vtb(Color(static_cast<BYTE>(190.0f * ctrlAlpha), 195, 215, 235));
                g.DrawString(vbuf, -1, &timeFont, RectF(static_cast<REAL>(w - 42), 54.0f, 22.0f, 13.0f), &rightSf, &vtb);

                DrawImageAlpha(g, st.winBtns.get(), Rect(18, h - 17, 13, 13), 3 * 52, 0, 52, 52, ctrlAlpha * 0.65f);
            }

            float libBtnAlpha = st.libVisible ? 0.90f : (0.35f + 0.45f * st.hoverAlpha);
            if (st.hoverBtn == BTN_LIBRARY) libBtnAlpha = 1.0f;
            DrawImageAlpha(g, st.winBtns.get(), GetButtonRect(st, BTN_LIBRARY), 1 * 52, 0, 52, 52,
                libBtnAlpha * bodyFade, st.libVisible || st.hoverBtn == BTN_LIBRARY ? 1.2f : 1.0f);

            float lrcBtnAlpha = st.lyricsVisible ? 0.90f : (0.35f + 0.45f * st.hoverAlpha);
            if (st.hoverBtn == BTN_LYRICS) lrcBtnAlpha = 1.0f;
            DrawImageAlpha(g, st.winBtns.get(), GetButtonRect(st, BTN_LYRICS), 8 * 52, 52, 52, 52,
                lrcBtnAlpha * bodyFade, st.lyricsVisible || st.hoverBtn == BTN_LYRICS ? 1.2f : 1.0f);

            if (bodyFade > 0.25f) {
                Rect pr = GetButtonRect(st, BTN_PROGRESS);
                DrawCapsuleProgress(g, RectF(static_cast<REAL>(pr.X), 67.0f,
                    static_cast<REAL>(pr.Width), 6.0f), ratio, st.hoverBtn == BTN_PROGRESS);

                SolidBrush timeBrush(Color(static_cast<BYTE>(210.0f * bodyFade), 205, 216, 230));
                g.DrawString(FormatMs(livePosMs).c_str(), -1, &timeFont, RectF(26.0f, 64.0f, 38.0f, 13.0f), &rightSf, &timeBrush);
                g.DrawString(FormatMs(info.durationMs).c_str(), -1, &timeFont, RectF(static_cast<REAL>(w - 64), 64.0f, 38.0f, 13.0f), &leftSf, &timeBrush);
            }
        } else {
            float idleAlpha = 1.0f - st.hoverAlpha;
            if (idleAlpha > 0.02f) {
                ULONGLONG cycleMs = GetTickCount64() % 10000ULL;
                bool showTitle = (cycleMs < 5000ULL);
                float phaseMs = static_cast<float>(cycleMs % 5000ULL);
                float textFade = 1.0f;
                if (phaseMs < 400.0f) textFade = phaseMs / 400.0f;
                else if (phaseMs > 4600.0f) textFade = (5000.0f - phaseMs) / 400.0f;

                std::wstring text = showTitle ? info.title : info.artist;
                DrawGlyphHaloText(g, text, ff, 11.5f,
                    RectF(14.0f, 5.0f, static_cast<REAL>(w - 28), 16.0f),
                    centerSf, Color(245, 242, 246, 252), idleAlpha * textFade);
            }

            if (st.hoverAlpha > 0.02f) {
                DrawTextHalo(g, static_cast<float>(w) * 0.5f, static_cast<float>(h) * 0.5f,
                    82.0f, 11.0f, static_cast<BYTE>(145.0f * st.hoverAlpha));
                auto drawMiniBtn = [&](int btnIdx, int spriteIdx) {
                    Rect r = GetButtonRect(st, btnIdx);
                    bool isHover = (st.hoverBtn == btnIdx);
                    bool isPress = (st.pressedBtn == btnIdx);
                    if (isPress) r.Y += 1;
                    float a = st.hoverAlpha * (isHover || isPress ? 1.0f : 0.80f);
                    float bright = isPress ? 1.25f : (isHover ? 1.15f : 1.0f);
                    DrawImageAlpha(g, st.miniCtrl.get(), r, spriteIdx * 64, 0, 64, 64, a, bright);
                };
                drawMiniBtn(BTN_STOP, 0);
                drawMiniBtn(BTN_PREV, 1);
                drawMiniBtn(BTN_PLAYPAUSE, info.isPlaying ? 3 : 2);
                drawMiniBtn(BTN_NEXT, 4);
                drawMiniBtn(BTN_EJECT, 5);

                DrawImageAlpha(g, st.winBtns.get(), GetButtonRect(st, BTN_LYRICS), 8 * 52, 52, 52, 52,
                    st.hoverAlpha * (st.hoverBtn == BTN_LYRICS ? 1.0f : 0.72f), st.hoverBtn == BTN_LYRICS ? 1.2f : 1.0f);
                DrawImageAlpha(g, st.winBtns.get(), GetButtonRect(st, BTN_MINI_TOGGLE), 4 * 52, 0, 52, 52,
                    st.hoverAlpha * (st.hoverBtn == BTN_MINI_TOGGLE ? 1.0f : 0.72f), st.hoverBtn == BTN_MINI_TOGGLE ? 1.2f : 1.0f);
                DrawImageAlpha(g, st.winBtns.get(), GetButtonRect(st, BTN_CLOSE), 2 * 52, 0, 52, 52,
                    st.hoverAlpha * (st.hoverBtn == BTN_CLOSE ? 1.0f : 0.72f), st.hoverBtn == BTN_CLOSE ? 1.2f : 1.0f);
            }
        }
    }

    RECT rcWin{};
    GetWindowRect(st.hwndMain, &rcWin);
    POINT ptDst{ rcWin.left, rcWin.top };
    SIZE szWnd{ wPx, hPx };
    POINT ptSrc{ 0, 0 };
    BLENDFUNCTION bf{ AC_SRC_OVER, 0, 255, AC_SRC_ALPHA };
    UpdateLayeredWindow(st.hwndMain, hdcScreen, &ptDst, &szWnd, hdcMem, &ptSrc, 0, &bf, ULW_ALPHA);

    SelectObject(hdcMem, oldBmp);
    DeleteObject(hBmp);
    DeleteDC(hdcMem);
    ReleaseDC(nullptr, hdcScreen);
}

void RenderLyricsWindow(AppState& st) {
    if (!st.hwndLyrics || !IsWindowVisible(st.hwndLyrics)) return;
    int w = st.lrcW;
    int h = st.lrcH;
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

        DrawAirPlayGlassFrame(g, w, h, st.lyricsMini ? st.lrcHoverAlpha : 0.0f, st.winFocused);

        NowPlayingInfo info = GetActiveNowPlaying(st);
        int64_t livePosMs = GetLivePositionMs(st, info);
        LyricsSnapshot lrc = st.lyrics.GetSnapshot();

        FontFamily ff(L"Microsoft YaHei UI");
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
            int bodyTop = 20;
            int bodyBot = h - 20;
            int bodyH = bodyBot - bodyTop;

            if (st.lrcHoverAlpha > 0.02f) {
                SolidBrush hdrBrush(Color(static_cast<BYTE>(170 * st.lrcHoverAlpha), 235, 240, 248));
                g.DrawString(L"Lyrics", -1, &transFont, RectF(14.0f, 3.0f, 80.0f, 14.0f), nullptr, &hdrBrush);

                DrawImageAlpha(g, st.winBtns.get(), GetLyricsButtonRect(st, LRC_BTN_MINI), 7 * 52, 0, 52, 52,
                    st.lrcHoverAlpha * (st.lrcHoverBtn == LRC_BTN_MINI ? 1.0f : 0.72f), st.lrcHoverBtn == LRC_BTN_MINI ? 1.2f : 1.0f);
                DrawImageAlpha(g, st.winBtns.get(), GetLyricsButtonRect(st, LRC_BTN_CLOSE), 2 * 52, 0, 52, 52,
                    st.lrcHoverAlpha * (st.lrcHoverBtn == LRC_BTN_CLOSE ? 1.0f : 0.72f), st.lrcHoverBtn == LRC_BTN_CLOSE ? 1.2f : 1.0f);
            }

            GraphicsState saved = g.Save();
            g.SetClip(Rect(8, bodyTop + 4, w - 16, bodyH - 8));

            if (lrc.lines.empty()) {
                std::wstring msg = lrc.statusText.empty() ? L"暂无同步歌词" : lrc.statusText;
                SolidBrush mb(Color(165, 190, 200, 215));
                g.DrawString(msg.c_str(), -1, &normalFont,
                    RectF(14.0f, static_cast<REAL>(bodyTop + bodyH / 2 - 9), static_cast<REAL>(w - 28), 18.0f),
                    &centerSf, &mb);
            } else {
                const float lineStep = 26.0f;
                float targetScroll = static_cast<float>(activeIdx) * lineStep;
                float diff = targetScroll - st.lyricsScrollY;
                if (std::abs(diff) > 0.4f) {
                    st.lyricsScrollY += diff * 0.18f;
                    if (!st.lrcScrollActive) {
                        st.lrcScrollActive = true;
                        SetTimer(st.hwndMain, TIMER_LRC_SCR, 16, nullptr);
                    }
                } else {
                    st.lyricsScrollY = targetScroll;
                    if (st.lrcScrollActive) {
                        st.lrcScrollActive = false;
                        KillTimer(st.hwndMain, TIMER_LRC_SCR);
                    }
                }

                float centerY = static_cast<float>(bodyTop + bodyH / 2) - 10.0f;
                for (int i = 0; i < static_cast<int>(lrc.lines.size()); ++i) {
                    float y = centerY + (static_cast<float>(i) * lineStep - st.lyricsScrollY);
                    if (y < bodyTop - 24 || y > bodyBot + 4) continue;

                    float dist = std::abs(y - centerY) / (static_cast<float>(bodyH) * 0.5f);
                    float edgeFade = std::clamp(1.15f - dist * 0.95f, 0.12f, 1.0f);

                    if (i == activeIdx) {
                        SolidBrush ab(Color(static_cast<BYTE>(250 * edgeFade), 175, 225, 255));
                        g.DrawString(lrc.lines[i].text.c_str(), -1, &activeFont,
                            RectF(14.0f, y, static_cast<REAL>(w - 28), 18.0f), &centerSf, &ab);
                        if (!lrc.lines[i].trans.empty()) {
                            SolidBrush tb(Color(static_cast<BYTE>(185 * edgeFade), 160, 195, 220));
                            g.DrawString(lrc.lines[i].trans.c_str(), -1, &transFont,
                                RectF(14.0f, y + 17.0f, static_cast<REAL>(w - 28), 14.0f), &centerSf, &tb);
                        }
                    } else {
                        SolidBrush nb(Color(static_cast<BYTE>(155 * edgeFade), 205, 212, 224));
                        g.DrawString(lrc.lines[i].text.c_str(), -1, &normalFont,
                            RectF(14.0f, y + 1.0f, static_cast<REAL>(w - 28), 16.0f), &centerSf, &nb);
                    }
                }
            }
            g.Restore(saved);
        } else {
            std::wstring curLine = lrc.lines.empty()
                ? (lrc.statusText.empty() ? L"♪ 暂无同步歌词" : lrc.statusText)
                : lrc.lines[activeIdx].text;
            int rightPad = st.lrcHoverAlpha > 0.1f ? 42 : 14;
            DrawGlyphHaloText(g, curLine, ff, 11.5f,
                RectF(14.0f, 5.0f, static_cast<REAL>(w - 14 - rightPad), 16.0f),
                centerSf, Color(245, 215, 238, 255), 1.0f);

            if (st.lrcHoverAlpha > 0.02f) {
                DrawImageAlpha(g, st.winBtns.get(), GetLyricsButtonRect(st, LRC_BTN_MINI), 4 * 52, 0, 52, 52,
                    st.lrcHoverAlpha * (st.lrcHoverBtn == LRC_BTN_MINI ? 1.0f : 0.72f), st.lrcHoverBtn == LRC_BTN_MINI ? 1.2f : 1.0f);
                DrawImageAlpha(g, st.winBtns.get(), GetLyricsButtonRect(st, LRC_BTN_CLOSE), 2 * 52, 0, 52, 52,
                    st.lrcHoverAlpha * (st.lrcHoverBtn == LRC_BTN_CLOSE ? 1.0f : 0.72f), st.lrcHoverBtn == LRC_BTN_CLOSE ? 1.2f : 1.0f);
            }
        }
    }

    RECT rcWin{};
    GetWindowRect(st.hwndLyrics, &rcWin);
    POINT ptDst{ rcWin.left, rcWin.top };
    SIZE szWnd{ wPx, hPx };
    POINT ptSrc{ 0, 0 };
    BLENDFUNCTION bf{ AC_SRC_OVER, 0, 255, AC_SRC_ALPHA };
    UpdateLayeredWindow(st.hwndLyrics, hdcScreen, &ptDst, &szWnd, hdcMem, &ptSrc, 0, &bf, ULW_ALPHA);

    SelectObject(hdcMem, oldBmp);
    DeleteObject(hBmp);
    DeleteDC(hdcMem);
    ReleaseDC(nullptr, hdcScreen);
}

void SyncWebHostPos(AppState& st) {
    if (!st.hwndLibrary || !st.hwndWebHost) return;
    RECT rcLib{};
    GetWindowRect(st.hwndLibrary, &rcLib);
    int padX = ToPx(4, st.dpi);
    int topY = ToPx(20, st.dpi);
    int wPx  = ToPx(LIB_W - 8, st.dpi);
    int hPx  = ToPx(LIB_H - 40, st.dpi);
    SetWindowPos(st.hwndWebHost, nullptr, rcLib.left + padX, rcLib.top + topY, wPx, hPx,
        SWP_NOZORDER | SWP_NOACTIVATE);
    st.webLib.Resize(wPx, hPx);
}

void SyncDockedLibraryPos(AppState& st) {
    if (!st.libDocked || !st.hwndLibrary || !IsWindowVisible(st.hwndLibrary)) return;
    RECT rcMain{};
    GetWindowRect(st.hwndMain, &rcMain);
    st.syncingMove = true;
    SetWindowPos(st.hwndLibrary, nullptr, rcMain.right - ToPx(DOCK_OVERLAP_DIP, st.dpi), rcMain.top, 0, 0,
        SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    st.syncingMove = false;
    SyncWebHostPos(st);
}

void RenderLibraryWindow(AppState& st) {
    if (!st.hwndLibrary || !IsWindowVisible(st.hwndLibrary)) return;
    int w = LIB_W;
    int h = LIB_H;
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

        DrawAirPlayGlassFrame(g, w, h, 0.0f, st.winFocused);

        FontFamily ff(L"Microsoft YaHei UI");
        Font hdrFont(&ff, 10.5f, FontStyleRegular, UnitPixel);
        SolidBrush hdrBrush(Color(185, 228, 236, 248));
        g.DrawString(L"Apple Music", -1, &hdrFont, RectF(14.0f, 3.0f, 120.0f, 14.0f), nullptr, &hdrBrush);

        float closeAlpha = 0.45f + 0.45f * st.libHoverAlpha;
        if (st.libHoverBtn == 0) closeAlpha = 1.0f;
        DrawImageAlpha(g, st.winBtns.get(), Rect(w - 20, 4, 13, 13), 2 * 52, 0, 52, 52,
            closeAlpha, st.libHoverBtn == 0 ? 1.2f : 1.0f);
    }

    RECT rcWin{};
    GetWindowRect(st.hwndLibrary, &rcWin);
    POINT ptDst{ rcWin.left, rcWin.top };
    SIZE szWnd{ wPx, hPx };
    POINT ptSrc{ 0, 0 };
    BLENDFUNCTION bf{ AC_SRC_OVER, 0, 255, AC_SRC_ALPHA };
    UpdateLayeredWindow(st.hwndLibrary, hdcScreen, &ptDst, &szWnd, hdcMem, &ptSrc, 0, &bf, ULW_ALPHA);

    SelectObject(hdcMem, oldBmp);
    DeleteObject(hBmp);
    DeleteDC(hdcMem);
    ReleaseDC(nullptr, hdcScreen);
}

void StartHoverAnim(AppState& st) {
    if (!st.animActive) {
        st.animActive = true;
        SetTimer(st.hwndMain, TIMER_ANIM, 16, nullptr);
    }
}

void StartMorphAnim(AppState& st) {
    if (!st.morphActive) {
        st.morphActive = true;
        SetTimer(st.hwndMain, TIMER_MORPH, 16, nullptr);
    }
}

LRESULT CALLBACK LyricsWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto* st = reinterpret_cast<AppState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));

    switch (msg) {
    case WM_CREATE: {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
        st = static_cast<AppState*>(cs->lpCreateParams);
        st->hwndLyrics = hwnd;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(st));
        int wPx = ToPx(st->lrcW, st->dpi);
        int hPx = ToPx(st->lrcH, st->dpi);
        SetWindowPos(hwnd, nullptr, 0, 0, wPx, hPx, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        EnableFrostedBlur(hwnd, wPx, hPx, st->dpi, st->lyricsMini);
        return 0;
    }
    case WM_MOUSEMOVE:
        if (st) {
            if (!st->lrcHovering) {
                st->lrcHovering = true;
                StartHoverAnim(*st);
            }
            int hit = HitTestLyrics(*st, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
            if (hit != st->lrcHoverBtn) {
                st->lrcHoverBtn = hit;
                RenderLyricsWindow(*st);
            }
            TRACKMOUSEEVENT tme{ sizeof(tme), TME_LEAVE, hwnd, 0 };
            TrackMouseEvent(&tme);
        }
        return 0;

    case WM_MOUSELEAVE:
        if (st) {
            st->lrcHovering = false;
            st->lrcHoverBtn = LRC_BTN_NONE;
            st->lrcPressedBtn = LRC_BTN_NONE;
            StartHoverAnim(*st);
        }
        return 0;

    case WM_LBUTTONDBLCLK:
        if (st && HitTestLyrics(*st, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)) == LRC_BTN_NONE) {
            st->lyricsMini = !st->lyricsMini;
            StartMorphAnim(*st);
        }
        return 0;

    case WM_LBUTTONDOWN:
        if (st) {
            int hit = HitTestLyrics(*st, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
            if (hit == LRC_BTN_NONE) {
                ReleaseCapture();
                SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
            } else {
                st->lrcPressedBtn = hit;
                RenderLyricsWindow(*st);
            }
        }
        return 0;

    case WM_LBUTTONUP:
        if (st && st->lrcPressedBtn != LRC_BTN_NONE) {
            int hit = HitTestLyrics(*st, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
            int act = (hit == st->lrcPressedBtn) ? hit : LRC_BTN_NONE;
            st->lrcPressedBtn = LRC_BTN_NONE;
            RenderLyricsWindow(*st);
            if (act == LRC_BTN_MINI) {
                st->lyricsMini = !st->lyricsMini;
                StartMorphAnim(*st);
            } else if (act == LRC_BTN_CLOSE) {
                st->lyricsVisible = false;
                ShowWindow(hwnd, SW_HIDE);
                RenderMainWindow(*st);
            }
        }
        return 0;

    case WM_WINDOWPOSCHANGING:
        if (st && !st->syncingMove && st->hwndMain) {
            auto* wp = reinterpret_cast<WINDOWPOS*>(lParam);
            if (!(wp->flags & SWP_NOMOVE)) {
                RECT rcMain{}, rcLrc{};
                GetWindowRect(st->hwndMain, &rcMain);
                GetWindowRect(hwnd, &rcLrc);
                int lw = rcLrc.right - rcLrc.left;
                int lh = rcLrc.bottom - rcLrc.top;
                int snap = ToPx(SNAP_DIST_PX, st->dpi);
                int ov = ToPx(DOCK_OVERLAP_DIP, st->dpi);

                int botX = rcMain.left,         botY = rcMain.bottom - ov;
                int topX = rcMain.left,         topY = rcMain.top - lh + ov;
                int lftX = rcMain.left - lw + ov, lftY = rcMain.top;
                int rgtX = rcMain.right - ov,   rgtY = rcMain.top;

                if (std::abs(wp->x - botX) <= snap && std::abs(wp->y - botY) <= snap) {
                    wp->x = botX; wp->y = botY; st->lyricsDockSide = DOCK_BOTTOM;
                } else if (std::abs(wp->x - topX) <= snap && std::abs(wp->y - topY) <= snap) {
                    wp->x = topX; wp->y = topY; st->lyricsDockSide = DOCK_TOP;
                } else if (std::abs(wp->x - lftX) <= snap && std::abs(wp->y - lftY) <= snap) {
                    wp->x = lftX; wp->y = lftY; st->lyricsDockSide = DOCK_LEFT;
                } else if (std::abs(wp->x - rgtX) <= snap && std::abs(wp->y - rgtY) <= snap) {
                    wp->x = rgtX; wp->y = rgtY; st->lyricsDockSide = DOCK_RIGHT;
                } else {
                    st->lyricsDockSide = DOCK_NONE;
                }
            }
        }
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

LRESULT CALLBACK LibraryWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto* st = reinterpret_cast<AppState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));

    switch (msg) {
    case WM_CREATE: {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
        st = static_cast<AppState*>(cs->lpCreateParams);
        st->hwndLibrary = hwnd;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(st));
        int wPx = ToPx(LIB_W, st->dpi);
        int hPx = ToPx(LIB_H, st->dpi);
        SetWindowPos(hwnd, nullptr, 0, 0, wPx, hPx, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        EnableFrostedBlur(hwnd, wPx, hPx, st->dpi, false);
        return 0;
    }
    case WM_WINDOWPOSCHANGED:
        if (st) SyncWebHostPos(*st);
        return DefWindowProcW(hwnd, msg, wParam, lParam);

    case WM_MOUSEMOVE:
        if (st) {
            int x = ToDip(GET_X_LPARAM(lParam), st->dpi);
            int y = ToDip(GET_Y_LPARAM(lParam), st->dpi);
            st->libHovering = true;
            int hit = Rect(LIB_W - 20, 4, 13, 13).Contains(x, y) ? 0 : -1;
            if (hit != st->libHoverBtn) {
                st->libHoverBtn = hit;
                RenderLibraryWindow(*st);
            }
            TRACKMOUSEEVENT tme{ sizeof(tme), TME_LEAVE, hwnd, 0 };
            TrackMouseEvent(&tme);
        }
        return 0;

    case WM_MOUSELEAVE:
        if (st) {
            st->libHovering = false;
            st->libHoverBtn = -1;
            st->libPressedBtn = -1;
            RenderLibraryWindow(*st);
        }
        return 0;

    case WM_LBUTTONDOWN:
        if (st) {
            int x = ToDip(GET_X_LPARAM(lParam), st->dpi);
            int y = ToDip(GET_Y_LPARAM(lParam), st->dpi);
            if (Rect(LIB_W - 20, 4, 13, 13).Contains(x, y)) {
                st->libPressedBtn = 0;
            } else {
                ReleaseCapture();
                SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
            }
        }
        return 0;

    case WM_LBUTTONUP:
        if (st && st->libPressedBtn == 0) {
            st->libPressedBtn = -1;
            st->libVisible = false;
            st->webLib.SetVisible(false);
            if (st->hwndWebHost) ShowWindow(st->hwndWebHost, SW_HIDE);
            ShowWindow(hwnd, SW_HIDE);
            RenderMainWindow(*st);
        }
        return 0;

    case WM_WINDOWPOSCHANGING:
        if (st && !st->syncingMove && st->hwndMain) {
            auto* wp = reinterpret_cast<WINDOWPOS*>(lParam);
            if (!(wp->flags & SWP_NOMOVE)) {
                RECT rcMain{};
                GetWindowRect(st->hwndMain, &rcMain);
                int snap = ToPx(SNAP_DIST_PX, st->dpi);
                int dockX = rcMain.right - ToPx(DOCK_OVERLAP_DIP, st->dpi);
                if (std::abs(wp->x - dockX) <= snap && std::abs(wp->y - rcMain.top) <= snap) {
                    wp->x = dockX;
                    wp->y = rcMain.top;
                    st->libDocked = true;
                } else {
                    st->libDocked = false;
                }
            }
        }
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

LRESULT CALLBACK MainWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto* st = reinterpret_cast<AppState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));

    switch (msg) {
    case WM_CREATE: {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
        st = static_cast<AppState*>(cs->lpCreateParams);
        st->hwndMain = hwnd;
        st->dpi = GetWindowDpiSafe(hwnd);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(st));

        int wPx = ToPx(st->curW, st->dpi);
        int hPx = ToPx(st->curH, st->dpi);
        SetWindowPos(hwnd, nullptr, 0, 0, wPx, hPx, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        EnableFrostedBlur(hwnd, wPx, hPx, st->dpi, st->miniMode);

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

        st->lyrics.Initialize(hwnd, WM_LYRICS_UPDATED);
        SetTimer(hwnd, TIMER_CLOCK, 250, nullptr);
        RenderMainWindow(*st);

        std::thread([hwnd, st]() {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            st->smtc.Initialize(hwnd, WM_SMTC_UPDATED);
        }).detach();

        return 0;
    }
    case WM_ACTIVATE:
        if (st) { st->winFocused = (LOWORD(wParam) != WA_INACTIVE); RenderMainWindow(*st); RenderLyricsWindow(*st); }
        return 0;
    case WM_WINDOWPOSCHANGED:
        if (st) { SyncDockedLyricsPos(*st); SyncDockedLibraryPos(*st); }
        return DefWindowProcW(hwnd, msg, wParam, lParam);

    case WM_DPICHANGED:
        if (st) {
            st->dpi = HIWORD(wParam);
            int wPx = ToPx(st->curW, st->dpi);
            int hPx = ToPx(st->curH, st->dpi);
            SetWindowPos(hwnd, nullptr, 0, 0, wPx, hPx, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
            EnableFrostedBlur(hwnd, wPx, hPx, st->dpi, st->miniMode);
            RenderMainWindow(*st);
            if (st->hwndLyrics) {
                int lwPx = ToPx(st->lrcW, st->dpi);
                int lhPx = ToPx(st->lrcH, st->dpi);
                SetWindowPos(st->hwndLyrics, nullptr, 0, 0, lwPx, lhPx, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
                EnableFrostedBlur(st->hwndLyrics, lwPx, lhPx, st->dpi, st->lyricsMini);
                SyncDockedLyricsPos(*st);
                RenderLyricsWindow(*st);
            }
        }
        return 0;

    case WM_SMTC_UPDATED:
    case WM_WEB_UPDATED:
        if (st) {
            NowPlayingInfo info = GetActiveNowPlaying(*st);
            st->lastSmtcPosMs = info.positionMs;
            st->lastSmtcTick = GetTickCount64();
            std::wstring key = info.title + L"|" + info.artist;
            if (key != st->lastTrackKey) {
                st->lastTrackKey = key;
                st->lyricsScrollY = 0.0f;
                st->lyrics.RequestLyrics(info.title, info.artist, info.durationMs);
            }
            RenderMainWindow(*st);
            RenderLyricsWindow(*st);
        }
        return 0;

    case WM_LYRICS_UPDATED:
        if (st) RenderLyricsWindow(*st);
        return 0;

    case WM_TIMER:
        if (!st) return 0;
        if (wParam == TIMER_CLOCK) {
            RenderMainWindow(*st);
            RenderLyricsWindow(*st);
        } else if (wParam == TIMER_LRC_SCR) {
            RenderLyricsWindow(*st);
        } else if (wParam == TIMER_ANIM) {
            auto stepF = [](float cur, float tgt) -> float {
                if (cur < tgt) return (std::min)(tgt, cur + 0.14f);
                if (cur > tgt) return (std::max)(tgt, cur - 0.14f);
                return cur;
            };
            float tgtMain = st->hovering ? 1.0f : 0.0f;
            float tgtLrc  = st->lrcHovering ? 1.0f : 0.0f;
            st->hoverAlpha = stepF(st->hoverAlpha, tgtMain);
            st->lrcHoverAlpha = stepF(st->lrcHoverAlpha, tgtLrc);
            if (st->hoverAlpha == tgtMain && st->lrcHoverAlpha == tgtLrc) {
                st->animActive = false;
                KillTimer(hwnd, TIMER_ANIM);
            }
            RenderMainWindow(*st);
            RenderLyricsWindow(*st);
        } else if (wParam == TIMER_MORPH) {
            int tw = st->miniMode ? WIN_W_MINI : WIN_W_FULL;
            int th = st->miniMode ? WIN_H_MINI : WIN_H_FULL;
            int ltw = st->lyricsMini ? LRC_W_MINI : LRC_W_FULL;
            int lth = st->lyricsMini ? LRC_H_MINI : LRC_H_FULL;

            auto stepToward = [](int cur, int tgt) -> int {
                if (cur == tgt) return cur;
                int diff = tgt - cur;
                int delta = diff / 3;
                if (delta == 0) delta = (diff > 0) ? 1 : -1;
                return cur + delta;
            };

            st->curW = stepToward(st->curW, tw);
            st->curH = stepToward(st->curH, th);
            st->lrcW = stepToward(st->lrcW, ltw);
            st->lrcH = stepToward(st->lrcH, lth);

            int wPx = ToPx(st->curW, st->dpi);
            int hPx = ToPx(st->curH, st->dpi);
            SetWindowPos(hwnd, nullptr, 0, 0, wPx, hPx, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
            EnableFrostedBlur(hwnd, wPx, hPx, st->dpi, st->miniMode);

            if (st->hwndLyrics && IsWindowVisible(st->hwndLyrics)) {
                int lwPx = ToPx(st->lrcW, st->dpi);
                int lhPx = ToPx(st->lrcH, st->dpi);
                SetWindowPos(st->hwndLyrics, nullptr, 0, 0, lwPx, lhPx, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
                EnableFrostedBlur(st->hwndLyrics, lwPx, lhPx, st->dpi, st->lyricsMini);
                SyncDockedLyricsPos(*st);
            }

            if (st->curW == tw && st->curH == th && st->lrcW == ltw && st->lrcH == lth) {
                st->morphActive = false;
                KillTimer(hwnd, TIMER_MORPH);
            KillTimer(hwnd, TIMER_LRC_SCR);
            }
            RenderMainWindow(*st);
            RenderLyricsWindow(*st);
        }
        return 0;

    case WM_MOUSEMOVE:
        if (st) {
            if (!st->hovering) {
                st->hovering = true;
                StartHoverAnim(*st);
            }
            int hit = HitTestMain(*st, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
            if (hit != st->hoverBtn) {
                st->hoverBtn = hit;
                RenderMainWindow(*st);
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
            StartHoverAnim(*st);
        }
        return 0;

    case WM_LBUTTONDBLCLK:
        if (st && HitTestMain(*st, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)) == BTN_NONE) {
            st->miniMode = !st->miniMode;
            st->lyricsMini = st->miniMode;
            StartMorphAnim(*st);
        }
        return 0;

    case WM_LBUTTONDOWN:
        if (st) {
            int hit = HitTestMain(*st, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
            if (hit == BTN_NONE) {
                ReleaseCapture();
                SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
            } else {
                st->pressedBtn = hit;
                RenderMainWindow(*st);
            }
        }
        return 0;

    case WM_LBUTTONUP:
        if (st && st->pressedBtn != BTN_NONE) {
            int xDip = ToDip(GET_X_LPARAM(lParam), st->dpi);
            int yDip = ToDip(GET_Y_LPARAM(lParam), st->dpi);
            int hit = HitTestMain(*st, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
            int act = (hit == st->pressedBtn) ? hit : BTN_NONE;
            st->pressedBtn = BTN_NONE;
            RenderMainWindow(*st);

            switch (act) {
            case BTN_STOP:
                if (IsWebPlayerActive(*st)) st->webLib.Stop(); else st->smtc.Stop();
                break;
            case BTN_PREV:
                if (IsWebPlayerActive(*st)) st->webLib.Previous(); else st->smtc.Previous();
                break;
            case BTN_PLAYPAUSE:
                if (IsWebPlayerActive(*st)) st->webLib.PlayPause(); else st->smtc.PlayPause();
                break;
            case BTN_NEXT:
                if (IsWebPlayerActive(*st)) st->webLib.Next(); else st->smtc.Next();
                break;
            case BTN_EJECT:
                ShellExecuteW(nullptr, L"open", L"music:", nullptr, nullptr, SW_SHOWNORMAL);
                break;
            case BTN_MINIMIZE:
                ShowWindow(hwnd, SW_HIDE);
                if (st->hwndLyrics) ShowWindow(st->hwndLyrics, SW_HIDE);
                if (st->hwndWebHost) ShowWindow(st->hwndWebHost, SW_HIDE);
                if (st->hwndLibrary) ShowWindow(st->hwndLibrary, SW_HIDE);
                break;
            case BTN_MINI_TOGGLE:
                st->miniMode = !st->miniMode;
                st->lyricsMini = st->miniMode;
                StartMorphAnim(*st);
                break;
            case BTN_LIBRARY:
                st->libVisible = !st->libVisible;
                if (st->hwndLibrary) {
                    if (st->libVisible) {
                        ShowWindow(st->hwndLibrary, SW_SHOWNOACTIVATE);
                        SyncDockedLibraryPos(*st);
                        RenderLibraryWindow(*st);
                        if (st->hwndWebHost) {
                            SyncWebHostPos(*st);
                            ShowWindow(st->hwndWebHost, SW_SHOWNOACTIVATE);
                            st->webLib.SetVisible(true);
                        }
                    } else {
                        st->webLib.SetVisible(false);
                        if (st->hwndWebHost) ShowWindow(st->hwndWebHost, SW_HIDE);
                        ShowWindow(st->hwndLibrary, SW_HIDE);
                    }
                }
                RenderMainWindow(*st);
                break;
            case BTN_LYRICS:
                st->lyricsVisible = !st->lyricsVisible;
                if (st->hwndLyrics) {
                    if (st->lyricsVisible) {
                        if (st->lyricsDockSide != DOCK_NONE) {
                            st->lyricsMini = st->miniMode;
                            st->lrcW = st->lyricsMini ? LRC_W_MINI : LRC_W_FULL;
                            st->lrcH = st->lyricsMini ? LRC_H_MINI : LRC_H_FULL;
                            int lwPx = ToPx(st->lrcW, st->dpi);
                            int lhPx = ToPx(st->lrcH, st->dpi);
                            SetWindowPos(st->hwndLyrics, nullptr, 0, 0, lwPx, lhPx, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
                            EnableFrostedBlur(st->hwndLyrics, lwPx, lhPx, st->dpi, st->lyricsMini);
                        }
                        ShowWindow(st->hwndLyrics, SW_SHOWNOACTIVATE);
                        SyncDockedLyricsPos(*st);
                        RenderLyricsWindow(*st);
                    } else {
                        ShowWindow(st->hwndLyrics, SW_HIDE);
                    }
                }
                RenderMainWindow(*st);
                break;
            case BTN_TOPMOST:
                st->topMost = !st->topMost;
                SetWindowPos(hwnd, st->topMost ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
                if (st->hwndLyrics) SetWindowPos(st->hwndLyrics, st->topMost ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
                if (st->hwndLibrary) SetWindowPos(st->hwndLibrary, st->topMost ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
                if (st->hwndWebHost) SetWindowPos(st->hwndWebHost, st->topMost ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
                RenderMainWindow(*st);
                break;
            case BTN_CLOSE:     PostQuitMessage(0); break;
            case BTN_PROGRESS: {
                Rect pr = GetButtonRect(*st, BTN_PROGRESS);
                NowPlayingInfo info = GetActiveNowPlaying(*st);
                if (pr.Width > 0 && info.durationMs > 0) {
                    int64_t targetMs = (static_cast<int64_t>(xDip - pr.X) * info.durationMs) / pr.Width;
                    bool seeked = false;
                    if (IsWebPlayerActive(*st)) {
                        st->webLib.SeekToPositionMs(targetMs);
                        seeked = true;
                    } else {
                        seeked = st->smtc.SeekToPositionMs(targetMs);
                    }
                    if (seeked) {
                        st->lastSmtcPosMs = targetMs;
                        st->lastSmtcTick = GetTickCount64();
                        RenderMainWindow(*st);
                        RenderLyricsWindow(*st);
                    }
                }
                break;
            }
            case BTN_VOL_BAR: {
                Rect vr = GetButtonRect(*st, BTN_VOL_BAR);
                bool up = (yDip < vr.Y + vr.Height / 2);
                st->simulatedVol = std::clamp(st->simulatedVol + (up ? 10 : -10), 0, 100);
                st->smtc.VolumeStep(up);
                RenderMainWindow(*st);
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
            RenderMainWindow(*st);
        }
        return 0;

    case WM_TRAYICON:
        if (lParam == WM_LBUTTONUP || lParam == WM_LBUTTONDBLCLK) {
            ShowWindow(hwnd, SW_SHOW);
            if (st->lyricsVisible && st->hwndLyrics) ShowWindow(st->hwndLyrics, SW_SHOWNOACTIVATE);
            if (st->libVisible && st->hwndLibrary) { ShowWindow(st->hwndLibrary, SW_SHOWNOACTIVATE); if (st->hwndWebHost) ShowWindow(st->hwndWebHost, SW_SHOWNOACTIVATE); }
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
            KillTimer(hwnd, TIMER_LRC_SCR);
            Shell_NotifyIconW(NIM_DELETE, &st->nid);
            st->webLib.Shutdown();
            st->smtc.Shutdown();
        }
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}
} // namespace

int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE, PWSTR, int) {
    SetCurrentProcessExplicitAppUserModelID(L"AirMuse.Player");
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    winrt::init_apartment(winrt::apartment_type::single_threaded);

    GdiplusStartupInput gdiInput;
    ULONG_PTR gdiToken = 0;
    GdiplusStartup(&gdiToken, &gdiInput, nullptr);

    AppState state;
    state.hInst = hInst;

    WNDCLASSEXW wcMain{};
    wcMain.cbSize = sizeof(wcMain);
    wcMain.style = CS_DBLCLKS;
    wcMain.lpfnWndProc = MainWndProc;
    wcMain.hInstance = hInst;
    wcMain.hIcon = LoadIconW(hInst, MAKEINTRESOURCEW(IDR_MAIN_ICON));
    wcMain.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wcMain.lpszClassName = L"AirMuseMainWindow";
    RegisterClassExW(&wcMain);

    WNDCLASSEXW wcLrc{};
    wcLrc.cbSize = sizeof(wcLrc);
    wcLrc.style = CS_DBLCLKS;
    wcLrc.lpfnWndProc = LyricsWndProc;
    wcLrc.hInstance = hInst;
    wcLrc.hIcon = LoadIconW(hInst, MAKEINTRESOURCEW(IDR_MAIN_ICON));
    wcLrc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wcLrc.lpszClassName = L"AirMuseLyricsWindow";
    RegisterClassExW(&wcLrc);

    HWND hwndMain = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        wcMain.lpszClassName, L"AirMuse", WS_POPUP,
        120, 120, WIN_W_FULL, WIN_H_FULL,
        nullptr, nullptr, hInst, &state
    );

    CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        wcLrc.lpszClassName, L"AirMuse Lyrics", WS_POPUP,
        120, 222, LRC_W_FULL, LRC_H_FULL,
        hwndMain, nullptr, hInst, &state
    );

    WNDCLASSEXW wcLib{};
    wcLib.cbSize = sizeof(wcLib);
    wcLib.lpfnWndProc = LibraryWndProc;
    wcLib.hInstance = hInst;
    wcLib.hIcon = LoadIconW(hInst, MAKEINTRESOURCEW(IDR_MAIN_ICON));
    wcLib.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wcLib.lpszClassName = L"AirMuseLibraryWindow";
    RegisterClassExW(&wcLib);

    WNDCLASSEXW wcHost{};
    wcHost.cbSize = sizeof(wcHost);
    wcHost.lpfnWndProc = DefWindowProcW;
    wcHost.hInstance = hInst;
    wcHost.hbrBackground = CreateSolidBrush(RGB(28, 29, 32));
    wcHost.lpszClassName = L"AirMuseWebHost";
    RegisterClassExW(&wcHost);

    HWND hwndLib = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        wcLib.lpszClassName, L"AirMuse Library", WS_POPUP,
        438, 120, LIB_W, LIB_H,
        hwndMain, nullptr, hInst, &state
    );

    state.hwndWebHost = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        wcHost.lpszClassName, L"AirMuse WebHost", WS_POPUP,
        442, 140, LIB_W - 8, LIB_H - 40,
        hwndLib, nullptr, hInst, nullptr
    );
    state.webLib.Initialize(state.hwndWebHost, hwndMain, WM_WEB_UPDATED);

    ShowWindow(hwndMain, SW_SHOW);

    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    GdiplusShutdown(gdiToken);
    return static_cast<int>(msg.wParam);
}
