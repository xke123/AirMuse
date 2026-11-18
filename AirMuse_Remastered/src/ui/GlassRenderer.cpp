#include <cmath>
#include "GlassRenderer.hpp"
#include <dwmapi.h>
#include <shlwapi.h>
#include <algorithm>
#include <cstdio>

using namespace Gdiplus;

namespace airmuse {

LayeredSurface::~LayeredSurface() {
    Release();
}

void LayeredSurface::Release() {
    if (hdcMem && oldBmp) {
        SelectObject(hdcMem, oldBmp);
        oldBmp = nullptr;
    }
    if (hBmp) {
        DeleteObject(hBmp);
        hBmp = nullptr;
    }
    if (hdcMem) {
        DeleteDC(hdcMem);
        hdcMem = nullptr;
    }
    if (hdcScreen) {
        ReleaseDC(nullptr, hdcScreen);
        hdcScreen = nullptr;
    }
    widthPx = 0;
    heightPx = 0;
}

bool LayeredSurface::Ensure(int wPx, int hPx) {
    if (wPx <= 0 || hPx <= 0) return false;
    if (hBmp && widthPx == wPx && heightPx == hPx) return true;

    Release();

    hdcScreen = GetDC(nullptr);
    if (!hdcScreen) return false;
    hdcMem = CreateCompatibleDC(hdcScreen);
    if (!hdcMem) {
        Release();
        return false;
    }

    BITMAPINFO bmi{};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = wPx;
    bmi.bmiHeader.biHeight = -hPx;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    void* bits = nullptr;
    hBmp = CreateDIBSection(hdcScreen, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!hBmp) {
        Release();
        return false;
    }
    oldBmp = SelectObject(hdcMem, hBmp);
    widthPx = wPx;
    heightPx = hPx;
    return true;
}

void LayeredSurface::Present(HWND hwnd, int wPx, int hPx, BYTE masterAlpha) {
    if (!hwnd || !hdcScreen || !hdcMem || !hBmp) return;
    RECT rcWin{};
    GetWindowRect(hwnd, &rcWin);
    POINT ptDst{ rcWin.left, rcWin.top }, ptSrc{ 0, 0 };
    SIZE szWnd{ wPx, hPx };
    BLENDFUNCTION bf{ AC_SRC_OVER, 0, masterAlpha, AC_SRC_ALPHA };
    UpdateLayeredWindow(hwnd, hdcScreen, &ptDst, &szWnd, hdcMem, &ptSrc, 0, &bf, ULW_ALPHA);
}

void GlassRenderer::EnableFrostedBlur(HWND hwnd, int wPx, int hPx, int dpi, bool mini) {
    int r = ToPx(mini ? 4 : 8, dpi);
    HRGN rgn = CreateRoundRectRgn(ToPx(2, dpi), ToPx(2, dpi), wPx - ToPx(2, dpi), hPx - ToPx(2, dpi), r, r);
    DWM_BLURBEHIND bb{};
    bb.dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION;
    bb.fEnable = TRUE;
    bb.hRgnBlur = rgn;
    DwmEnableBlurBehindWindow(hwnd, &bb);
    DeleteObject(rgn);
}

std::unique_ptr<Bitmap> GlassRenderer::LoadPngResource(HINSTANCE hInst, UINT resId) {
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
    return (bmp->GetLastStatus() == Ok) ? std::move(bmp) : nullptr;
}

std::unique_ptr<Bitmap> GlassRenderer::DecodeArtworkBitmap(std::vector<uint8_t> const& bytes) {
    if (bytes.empty()) return nullptr;
    IStream* stream = SHCreateMemStream(bytes.data(), static_cast<UINT>(bytes.size()));
    if (!stream) return nullptr;
    auto bmp = std::make_unique<Bitmap>(stream);
    stream->Release();
    return (bmp->GetLastStatus() == Ok) ? std::move(bmp) : nullptr;
}

void GlassRenderer::AddRoundedRectPath(GraphicsPath& path, float x, float y, float w, float h, float r) {
    float d = std::min({ r * 2.0f, w, h });
    if (d <= 0.1f) { path.AddRectangle(RectF(x, y, w, h)); return; }
    path.AddArc(x, y, d, d, 180.0f, 90.0f);
    path.AddArc(x + w - d, y, d, d, 270.0f, 90.0f);
    path.AddArc(x + w - d, y + h - d, d, d, 0.0f, 90.0f);
    path.AddArc(x, y + h - d, d, d, 90.0f, 90.0f);
    path.CloseFigure();
}

void GlassRenderer::DrawImageAlpha(Graphics& g, Bitmap* src, RectF const& dst, int sx, int sy, int sw, int sh, float alpha, float brightness) {
    if (!src || alpha <= 0.01f) return;
    alpha = std::clamp(alpha, 0.0f, 1.0f);
    if (alpha >= 0.995f && std::abs(brightness - 1.0f) < 0.005f) {
        g.DrawImage(src, dst, static_cast<REAL>(sx), static_cast<REAL>(sy), static_cast<REAL>(sw), static_cast<REAL>(sh), UnitPixel);
        return;
    }
    ColorMatrix cm = {{
        {brightness, 0, 0, 0, 0},
        {0, brightness, 0, 0, 0},
        {0, 0, brightness, 0, 0},
        {0, 0, 0, alpha, 0},
        {0, 0, 0, 0, 1}
    }};
    ImageAttributes ia;
    ia.SetColorMatrix(&cm, ColorMatrixFlagsDefault, ColorAdjustTypeBitmap);
    g.DrawImage(src, dst, static_cast<REAL>(sx), static_cast<REAL>(sy), static_cast<REAL>(sw), static_cast<REAL>(sh), UnitPixel, &ia);
}

void GlassRenderer::DrawAirPlayGlassFrame(Graphics& g, int dstW, int dstH, float hoverGloss, float focusRatio, Bitmap* ambientArtwork) {
    focusRatio = std::clamp(focusRatio, 0.0f, 1.0f);
    const float padX = 2.0f, padY = 2.0f;
    const float fw = static_cast<float>(dstW) - padX * 2.0f;
    const float fh = static_cast<float>(dstH) - padY * 2.0f;

    if (dstH <= 36) {
        const float mPadX = 4.0f, mPadY = 3.0f;
        const float mW = static_cast<float>(dstW) - mPadX * 2.0f;
        const float mH = static_cast<float>(dstH) - mPadY * 2.0f;
        const float r = 2.5f;

        for (int i = 3; i >= 1; --i) {
            float exp = static_cast<float>(i) * 0.9f;
            GraphicsPath shadowPath;
            AddRoundedRectPath(shadowPath, mPadX - exp, mPadY - exp * 0.7f, mW + exp * 2.0f, mH + exp * 1.6f, r + exp);
            Pen shadowPen(Color(static_cast<BYTE>(22 * (4 - i)), 8, 10, 14), 1.4f);
            g.DrawPath(&shadowPen, &shadowPath);
        }

        GraphicsPath outer;
        AddRoundedRectPath(outer, mPadX, mPadY, mW, mH, r);
        BYTE aTop = static_cast<BYTE>(135 + 45 * hoverGloss);
        BYTE aMid = static_cast<BYTE>(88  + 38 * hoverGloss);
        BYTE aBot = static_cast<BYTE>(52  + 24 * hoverGloss);
        LinearGradientBrush glassBrush(PointF(0, mPadY), PointF(0, mPadY + mH),
                                       Color(aTop, 28, 30, 35), Color(aBot, 210, 214, 222));
        Color colors[3] = {
            Color(aTop, 24, 26, 30),
            Color(aMid, 58, 62, 68),
            Color(aBot, 195, 200, 208)
        };
        REAL pos[3] = { 0.0f, 0.52f, 1.0f };
        glassBrush.SetInterpolationColors(colors, pos, 3);
        g.FillPath(&glassBrush, &outer);

        GraphicsState saved = g.Save();
        g.SetClip(&outer);
        Pen topSheen(Color(static_cast<BYTE>(45 + 55 * focusRatio), 255, 255, 255), 1.0f);
        g.DrawLine(&topSheen, mPadX + 1.0f, mPadY + 1.0f, mPadX + mW - 1.0f, mPadY + 1.0f);
        g.Restore(saved);

        Pen outerRimDark(Color(115, 20, 22, 26), 1.0f);
        g.DrawPath(&outerRimDark, &outer);

        GraphicsPath innerWhite;
        AddRoundedRectPath(innerWhite, mPadX + 0.75f, mPadY + 0.75f, mW - 1.5f, mH - 1.5f, std::max(1.5f, r - 0.5f));
        Pen whiteBorder(Color(static_cast<BYTE>(110 + 75 * focusRatio), 248, 250, 255), 1.0f);
        g.DrawPath(&whiteBorder, &innerWhite);
        return;
    }

    const float barH = 18.0f;
    const float gx = padX;
    const float gw = fw;

    // 顶部水晶玻璃条 (失焦时沉静微暗，激活时晶莹通透带有高光反射)
    {
        GraphicsPath topPath;
        AddRoundedRectPath(topPath, gx, padY, gw, barH + 2.0f, 4.5f);
        BYTE topA = static_cast<BYTE>(60 + 42 * focusRatio);
        BYTE botA = static_cast<BYTE>(32 + 24 * focusRatio);
        LinearGradientBrush topGlass(PointF(0, padY), PointF(0, padY + barH),
                                     Color(topA, 224, 228, 236), Color(botA, 152, 158, 166));
        g.FillPath(&topGlass, &topPath);

        // 顶边 1px 晶体折射高光线 (AirPlay 经典标志)
        Pen topSheen(Color(static_cast<BYTE>(30 + 85 * focusRatio), 255, 255, 255), 1.0f);
        g.DrawLine(&topSheen, gx + 3.0f, padY + 1.0f, gx + gw - 3.0f, padY + 1.0f);

        Pen topBorder(Color(static_cast<BYTE>(110 + 40 * focusRatio), 14, 15, 18), 1.0f);
        g.DrawPath(&topBorder, &topPath);
    }

    float botY = padY + fh - barH;
    // 底部水晶玻璃条
    {
        GraphicsPath botPath;
        AddRoundedRectPath(botPath, gx, botY - 2.0f, gw, barH + 2.0f, 4.5f);
        BYTE botTopA = static_cast<BYTE>(32 + 24 * focusRatio);
        BYTE botBotA = static_cast<BYTE>(54 + 40 * focusRatio);
        LinearGradientBrush botGlass(PointF(0, botY), PointF(0, padY + fh),
                                     Color(botTopA, 152, 158, 166), Color(botBotA, 214, 218, 226));
        g.FillPath(&botGlass, &botPath);
        Pen botBorder(Color(static_cast<BYTE>(110 + 40 * focusRatio), 14, 15, 18), 1.0f);
        g.DrawPath(&botBorder, &botPath);
    }

    float midY = padY + barH;
    float midH = fh - barH * 2.0f;
    if (midH > 0.0f) {
        GraphicsPath midPath;
        AddRoundedRectPath(midPath, padX, midY, fw, midH, 5.5f);
        GraphicsState saved = g.Save();
        g.SetClip(&midPath);

        LinearGradientBrush bodyBrush(PointF(0, midY), PointF(0, midY + midH), Color(240, 36, 38, 42), Color(246, 20, 22, 26));
        g.FillRectangle(&bodyBrush, padX, midY, fw, midH);

        if (ambientArtwork && ambientArtwork->GetWidth() > 0) {
            DrawImageAlpha(g, ambientArtwork, RectF(padX, midY - 40.0f, fw, fw),
                           0, 0, ambientArtwork->GetWidth(), ambientArtwork->GetHeight(), 0.16f, 0.85f);
        }
        g.Restore(saved);

        Pen midDark(Color(175, 10, 11, 14), 1.0f);
        Pen midRim(Color(static_cast<BYTE>(26 + 32 * focusRatio), 255, 255, 255), 1.0f);
        g.DrawPath(&midDark, &midPath);

        GraphicsPath midInner;
        AddRoundedRectPath(midInner, padX + 1.0f, midY + 1.0f, fw - 2.0f, midH - 2.0f, 4.5f);
        g.DrawPath(&midRim, &midInner);

        // 焦点态微弱青色水晶漫反射内轮廓 (AirPlay 经典高光)
        if (focusRatio > 0.05f) {
            Pen crystalGlow(Color(static_cast<BYTE>(32 * focusRatio), 120, 220, 255), 1.0f);
            g.DrawPath(&crystalGlow, &midInner);
        }
    }
}

void GlassRenderer::DrawSpecularSweep(Graphics& g, int dstW, int dstH, float sweepRatio, float intensity, float /*sweepRatioX*/) {
    if (intensity <= 0.005f) return;
    const float padX = 2.0f, padY = 2.0f;
    const float fw = static_cast<float>(dstW) - padX * 2.0f;
    const float fh = static_cast<float>(dstH) - padY * 2.0f;
    const float barH = 18.0f;

    float midY = padY + barH;
    float midH = fh - barH * 2.0f;
    if (fw <= 10.0f || midH <= 10.0f) return;

    // 严格限制在两个玻璃条中间的主面板区域 (midClip)
    GraphicsPath midClip;
    AddRoundedRectPath(midClip, padX, midY, fw, midH, 5.5f);

    GraphicsState saved = g.Save();
    g.SetClip(&midClip, CombineModeIntersect);

    // 计算相机镜头炫光/光晕中心Y轴位置
    float cy = midY + sweepRatio * midH;

    // 绘制具有高斯/钟形羽化分布的横向全贯穿光学光晕层 (避免生硬“灯条”)
    auto drawGaussianSheenLayer = [&](float totalH, BYTE peakAlpha, BYTE r, BYTE gColor, BYTE b) {
        if (peakAlpha == 0 || totalH <= 1.0f) return;
        float y0 = cy - totalH * 0.5f;
        float y1 = cy + totalH * 0.5f;

        // 高斯/钟形羽化权重系数：调高边缘最低亮度部分底色，使整体光晕饱满通透
        static const REAL pos[11] = { 0.00f, 0.08f, 0.18f, 0.32f, 0.42f, 0.50f, 0.58f, 0.68f, 0.82f, 0.92f, 1.00f };
        static const float weights[11] = { 0.00f, 0.28f, 0.54f, 0.80f, 0.94f, 1.00f, 0.94f, 0.80f, 0.54f, 0.28f, 0.00f };

        Color colors[11];
        for (int i = 0; i < 11; ++i) {
            BYTE a = static_cast<BYTE>(std::round(peakAlpha * weights[i]));
            colors[i] = Color(a, r, gColor, b);
        }

        LinearGradientBrush lgb(PointF(padX, y0), PointF(padX, y1), colors[0], colors[10]);
        lgb.SetWrapMode(WrapModeClamp);
        lgb.SetInterpolationColors(colors, pos, 11);

        // 横向贯穿整个面板 (由 midClip 裁切自然契合玻璃圆角)
        RectF bandRect(padX, y0, fw, totalH);
        g.FillRectangle(&lgb, bandRect);
    };

    // 1. 外层漫射镜头镀膜光晕 (Broad AR-Coating Cyan Glow)
    // 宽度(高度)扩充至整个界面的约三分之二 (2/3 dstH)，调高最低亮度部分的基底，柔和饱满
    float totalH = std::max(56.0f, static_cast<float>(dstH) * (2.0f / 3.0f));
    float h1 = totalH;
    BYTE alpha1 = static_cast<BYTE>(std::clamp(intensity * 22.0f, 0.0f, 255.0f));
    drawGaussianSheenLayer(h1, alpha1, 130, 215, 255);

    // 2. 核心光学聚光光晕 (Core Specular Glare / Bloom)
    // 调低最亮部分的亮度（从 38 降至 22），避免中心过曝刺眼
    float h2 = totalH * 0.55f;
    BYTE alpha2 = static_cast<BYTE>(std::clamp(intensity * 22.0f, 0.0f, 255.0f));
    drawGaussianSheenLayer(h2, alpha2, 250, 252, 255);

    // 3. 焦点柔光丝 (Soft Filament Bloom)
    // 调低微焦点亮度（从 20 降至 10），与整体光晕平滑融为一体
    float h3 = 14.0f;
    BYTE alpha3 = static_cast<BYTE>(std::clamp(intensity * 10.0f, 0.0f, 255.0f));
    drawGaussianSheenLayer(h3, alpha3, 255, 255, 255);

    g.Restore(saved);
}

void GlassRenderer::DrawTextHalo(Graphics& g, float cx, float cy, float rx, float ry, BYTE centerAlpha) {
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

void GlassRenderer::DrawBarSpillFog(Graphics& g, RectF const& barClip, float anchorX, float leftSpan, float rightSpan, bool fromBottom, BYTE peakAlpha) {
    if (peakAlpha <= 4 || (leftSpan + rightSpan) <= 4.0f || barClip.Width <= 2.0f || barClip.Height <= 2.0f) return;

    GraphicsState saved = g.Save();
    g.SetClip(barClip, CombineModeIntersect);

    float yNear = fromBottom ? (barClip.Y + barClip.Height + 1.0f) : (barClip.Y - 1.0f);
    float yFar  = fromBottom ? (barClip.Y + 1.5f) : (barClip.Y + barClip.Height - 1.5f);

    float farLeft  = leftSpan * 0.70f;
    float farRight = rightSpan * 0.70f;

    PointF pts[4];
    if (fromBottom) {
        pts[0] = PointF(anchorX - farLeft,   yFar);
        pts[1] = PointF(anchorX + farRight,  yFar);
        pts[2] = PointF(anchorX + rightSpan, yNear);
        pts[3] = PointF(anchorX - leftSpan,  yNear);
    } else {
        pts[0] = PointF(anchorX - leftSpan,  yNear);
        pts[1] = PointF(anchorX + rightSpan, yNear);
        pts[2] = PointF(anchorX + farRight,  yFar);
        pts[3] = PointF(anchorX - farLeft,   yFar);
    }

    for (int layer = 0; layer < 3; ++layer) {
        float expL = static_cast<float>(layer) * (leftSpan > rightSpan ? 6.0f : 2.2f);
        float expR = static_cast<float>(layer) * (rightSpan > leftSpan ? 6.0f : 2.2f);
        float expY = static_cast<float>(layer) * 1.1f;

        PointF lPts[4] = {
            PointF(pts[0].X - expL * 0.7f, pts[0].Y + (fromBottom ? -expY : expY)),
            PointF(pts[1].X + expR * 0.7f, pts[1].Y + (fromBottom ? -expY : expY)),
            PointF(pts[2].X + expR,        pts[2].Y),
            PointF(pts[3].X - expL,        pts[3].Y)
        };

        GraphicsPath path;
        path.AddPolygon(lPts, 4);

        PathGradientBrush pgb(&path);
        float focusY = fromBottom ? (yNear - barClip.Height * 0.25f) : (yNear + barClip.Height * 0.25f);
        pgb.SetCenterPoint(PointF(anchorX, focusY));

        BYTE a = static_cast<BYTE>(peakAlpha * (layer == 0 ? 0.58f : (layer == 1 ? 0.34f : 0.16f)));
        pgb.SetCenterColor(Color(a, 14, 16, 20));
        Color surround(0, 14, 16, 20);
        int cnt = 1;
        pgb.SetSurroundColors(&surround, &cnt);
        pgb.SetFocusScales(0.55f, 0.22f);

        g.FillPath(&pgb, &path);
    }

    g.Restore(saved);
}

void GlassRenderer::DrawPlatformLogo(Graphics& g, int platformIdx, RectF const& r, bool active, float alpha) {
    if (alpha <= 0.02f) return;
    BYTE a = static_cast<BYTE>(std::clamp(alpha, 0.0f, 1.0f) * (active ? 250.0f : 185.0f));
    Color fg = active ? Color(a, 215, 240, 255) : Color(a, 238, 242, 248);

    float cx = r.X + r.Width * 0.5f;
    float cy = r.Y + r.Height * 0.5f;

    if (platformIdx == 0) {
        Pen beamPen(fg, 1.6f);
        Pen stemPen(fg, 1.35f);
        g.DrawLine(&stemPen, cx - 2.2f, cy + 3.2f, cx - 2.2f, cy - 3.0f);
        g.DrawLine(&stemPen, cx + 2.8f, cy + 2.2f, cx + 2.8f, cy - 4.0f);
        g.DrawLine(&beamPen, cx - 2.2f, cy - 3.0f, cx + 2.8f, cy - 4.0f);
        SolidBrush wb(fg);
        g.FillEllipse(&wb, cx - 4.6f, cy + 1.8f, 3.2f, 2.7f);
        g.FillEllipse(&wb, cx + 0.4f, cy + 0.8f, 3.2f, 2.7f);
    } else if (platformIdx == 1) {
        Pen wave1(fg, 1.45f); wave1.SetStartCap(LineCapRound); wave1.SetEndCap(LineCapRound);
        Pen wave2(fg, 1.30f); wave2.SetStartCap(LineCapRound); wave2.SetEndCap(LineCapRound);
        Pen wave3(fg, 1.15f); wave3.SetStartCap(LineCapRound); wave3.SetEndCap(LineCapRound);
        g.DrawArc(&wave1, cx - 5.2f, cy - 3.6f, 10.4f, 6.2f, 218.0f, 104.0f);
        g.DrawArc(&wave2, cx - 4.1f, cy - 1.1f, 8.2f,  5.0f, 218.0f, 104.0f);
        g.DrawArc(&wave3, cx - 3.0f, cy + 1.3f, 6.0f,  3.8f, 218.0f, 104.0f);
    } else {
        Pen stemPen(fg, 1.5f);
        stemPen.SetStartCap(LineCapRound);
        stemPen.SetEndCap(LineCapRound);
        g.DrawLine(&stemPen, cx + 0.2f, cy + 3.0f, cx + 0.2f, cy - 3.8f);
        g.DrawLine(&stemPen, cx + 0.2f, cy - 3.8f, cx + 3.8f, cy - 2.0f);
        SolidBrush wb(fg);
        g.FillEllipse(&wb, cx - 3.6f, cy + 1.2f, 4.5f, 3.4f);
    }
}

namespace {

struct HaloCacheKey {
    std::wstring text;
    std::wstring family;
    int emSizeQ = 0;
    int rectWQ = 0;
    int rectHQ = 0;
    int align = 0;
    ARGB colorArgb = 0;
    int scaleQ = 100;

    bool operator==(HaloCacheKey const& o) const {
        return emSizeQ == o.emSizeQ && rectWQ == o.rectWQ && rectHQ == o.rectHQ &&
               align == o.align && colorArgb == o.colorArgb && scaleQ == o.scaleQ &&
               family == o.family && text == o.text;
    }
};

struct HaloCacheEntry {
    HaloCacheKey key;
    std::unique_ptr<Bitmap> bmp;
};

constexpr float kHaloPadX = 28.0f;
constexpr float kHaloPadY = 22.0f;

std::unique_ptr<Bitmap> RenderGlyphHaloToBitmap(std::wstring const& text, FontFamily const& ff, float emSize,
                                                RectF const& rect, StringFormat const& sf, Color textColor, float scale) {
    int bmpW = std::max(1, static_cast<int>(std::ceil((rect.Width + kHaloPadX * 2.0f) * scale)));
    int bmpH = std::max(1, static_cast<int>(std::ceil((rect.Height + kHaloPadY * 2.0f) * scale)));

    auto bmp = std::make_unique<Bitmap>(bmpW, bmpH, PixelFormat32bppPARGB);
    Graphics bg(bmp.get());
    bg.Clear(Color(0, 0, 0, 0));
    bg.ScaleTransform(scale, scale);
    bg.SetSmoothingMode(SmoothingModeHighQuality);
    bg.SetTextRenderingHint(TextRenderingHintAntiAlias);

    RectF localRect(kHaloPadX, kHaloPadY, rect.Width, rect.Height);

    StringFormat rawSf;
    rawSf.SetAlignment(StringAlignmentNear);
    rawSf.SetLineAlignment(StringAlignmentNear);
    rawSf.SetFormatFlags(StringFormatFlagsNoWrap | StringFormatFlagsMeasureTrailingSpaces);

    GraphicsPath glyphPath;
    glyphPath.AddString(text.c_str(), -1, &ff, FontStyleRegular, emSize, PointF(0.0f, 0.0f), &rawSf);

    RectF bounds{};
    glyphPath.GetBounds(&bounds);
    if (bounds.Width <= 0.1f || bounds.Height <= 0.1f) return bmp;

    if (bounds.Width > localRect.Width) {
        glyphPath.Reset();
        StringFormat clipSf(&sf);
        clipSf.SetLineAlignment(StringAlignmentNear);
        glyphPath.AddString(text.c_str(), -1, &ff, FontStyleRegular, emSize, localRect, &clipSf);
        glyphPath.GetBounds(&bounds);
    }

    float targetCx = localRect.X + localRect.Width * 0.5f;
    float targetCy = localRect.Y + localRect.Height * 0.5f;
    if (sf.GetAlignment() == StringAlignmentNear) {
        targetCx = localRect.X + bounds.Width * 0.5f;
    } else if (sf.GetAlignment() == StringAlignmentFar) {
        targetCx = localRect.X + localRect.Width - bounds.Width * 0.5f;
    }
    float actualCx = bounds.X + bounds.Width * 0.5f;
    float actualCy = bounds.Y + bounds.Height * 0.5f;

    Matrix alignMat;
    alignMat.Translate(targetCx - actualCx, targetCy - actualCy);
    glyphPath.Transform(&alignMat);
    glyphPath.GetBounds(&bounds);

    float cx = bounds.X + bounds.Width * 0.5f;
    float cy = bounds.Y + bounds.Height * 0.5f;

    struct TearLayer { float dx; float dy; float sx; float width; float alpha; };
    const TearLayer tears[] = {
        { -17.0f, -0.7f, 1.18f, 11.5f, 12.0f },
        {  18.0f,  0.6f, 1.20f, 12.0f, 12.0f },
        { -10.0f,  1.0f, 1.10f,  9.5f, 17.0f },
        {  10.5f, -0.9f, 1.12f,  9.5f, 17.0f },
        { -4.5f,  -0.4f, 1.05f,  8.0f, 22.0f },
        {  5.0f,   0.4f, 1.05f,  8.0f, 22.0f }
    };
    for (auto const& tl : tears) {
        BYTE a = static_cast<BYTE>(std::clamp(tl.alpha, 0.0f, 255.0f));
        GraphicsState st = bg.Save();
        bg.TranslateTransform(cx + tl.dx, cy + tl.dy);
        bg.ScaleTransform(tl.sx, 0.90f);
        bg.TranslateTransform(-cx, -cy);
        Pen tearPen(Color(a, 14, 16, 20), tl.width);
        tearPen.SetLineJoin(LineJoinRound);
        tearPen.SetMiterLimit(1.0f);
        bg.DrawPath(&tearPen, &glyphPath);
        bg.Restore(st);
    }

    constexpr int kSamples = 12;
    constexpr float kMaxRadius = 18.0f;
    constexpr float kSigma = 7.2f;
    constexpr float kPeakAlpha = 28.0f;

    for (int i = kSamples; i >= 1; --i) {
        float t = static_cast<float>(i) / static_cast<float>(kSamples);
        float radius = kMaxRadius * (t * t * 0.6f + t * 0.4f);
        float gaussian = std::exp(-(radius * radius) / (2.0f * kSigma * kSigma));
        BYTE a = static_cast<BYTE>(std::clamp(kPeakAlpha * gaussian, 0.0f, 255.0f));
        if (a == 0) continue;

        Pen diffPen(Color(a, 14, 16, 20), radius * 2.0f);
        diffPen.SetLineJoin(LineJoinRound);
        diffPen.SetMiterLimit(1.0f);
        bg.DrawPath(&diffPen, &glyphPath);
    }

    Pen rimPen(Color(38, 18, 20, 24), 0.65f);
    rimPen.SetLineJoin(LineJoinRound);
    bg.DrawPath(&rimPen, &glyphPath);

    SolidBrush fill(textColor);
    bg.FillPath(&fill, &glyphPath);
    return bmp;
}

} // namespace

void GlassRenderer::DrawGlyphHaloText(Graphics& g, std::wstring const& text, FontFamily const& ff, float emSize,
                                      RectF const& rect, StringFormat const& sf, Color textColor, float alphaScale) {
    if (text.empty() || alphaScale <= 0.02f || rect.Width <= 1.0f || rect.Height <= 1.0f) return;

    Matrix mtx;
    g.GetTransform(&mtx);
    REAL elems[6]{};
    mtx.GetElements(elems);
    float scale = (elems[0] > 0.1f) ? elems[0] : 1.0f;

    WCHAR ffName[LF_FACESIZE]{};
    ff.GetFamilyName(ffName);

    HaloCacheKey key;
    key.text = text;
    key.family = ffName;
    key.emSizeQ = static_cast<int>(std::round(emSize * 10.0f));
    key.rectWQ = static_cast<int>(std::round(rect.Width * 10.0f));
    key.rectHQ = static_cast<int>(std::round(rect.Height * 10.0f));
    key.align = static_cast<int>(sf.GetAlignment());
    key.colorArgb = textColor.GetValue();
    key.scaleQ = static_cast<int>(std::round(scale * 100.0f));

    static std::vector<HaloCacheEntry> s_cache;
    Bitmap* cached = nullptr;
    for (size_t i = 0; i < s_cache.size(); ++i) {
        if (s_cache[i].key == key) {
            if (i + 1 < s_cache.size()) {
                auto entry = std::move(s_cache[i]);
                s_cache.erase(s_cache.begin() + static_cast<ptrdiff_t>(i));
                s_cache.push_back(std::move(entry));
            }
            cached = s_cache.back().bmp.get();
            break;
        }
    }

    if (!cached) {
        auto bmp = RenderGlyphHaloToBitmap(text, ff, emSize, rect, sf, textColor, scale);
        cached = bmp.get();
        if (s_cache.size() >= 24) {
            s_cache.erase(s_cache.begin());
        }
        s_cache.push_back(HaloCacheEntry{ std::move(key), std::move(bmp) });
    }

    if (cached) {
        DrawImageAlpha(g, cached,
                       RectF(rect.X - kHaloPadX, rect.Y - kHaloPadY, rect.Width + kHaloPadX * 2.0f, rect.Height + kHaloPadY * 2.0f),
                       0, 0, cached->GetWidth(), cached->GetHeight(), alphaScale, 1.0f);
    }
}

void GlassRenderer::DrawCapsuleProgress(Graphics& g, RectF const& r, float ratio, bool highlight, bool scrubbing, std::wstring const& scrubTimeText) {
    float h = scrubbing ? r.Height + 2.0f : r.Height;
    float y = scrubbing ? r.Y - 1.0f : r.Y;

    GraphicsPath bgPath;
    bgPath.AddArc(r.X, y, h, h, 90, 180);
    bgPath.AddArc(r.X + r.Width - h, y, h, h, 270, 180);
    bgPath.CloseFigure();

    SolidBrush bgBrush(Color(145, 16, 18, 22));
    Pen borderPen(Color(highlight || scrubbing ? 160 : 58, 255, 255, 255), 1.0f);
    g.FillPath(&bgBrush, &bgPath);
    g.DrawPath(&borderPen, &bgPath);

    ratio = std::clamp(ratio, 0.0f, 1.0f);
    if (ratio > 0.015f) {
        float fillW = std::max(h, r.Width * ratio);
        GraphicsPath fgPath;
        fgPath.AddArc(r.X + 1, y + 1, h - 2, h - 2, 90, 180);
        fgPath.AddArc(r.X + fillW - h + 1, y + 1, h - 2, h - 2, 270, 180);
        fgPath.CloseFigure();

        LinearGradientBrush fgBrush(PointF(r.X, y), PointF(r.X, y + h), Color(230, 185, 232, 255), Color(205, 85, 155, 215));
        g.FillPath(&fgBrush, &fgPath);
    }

    if (scrubbing && !scrubTimeText.empty()) {
        float thumbX = r.X + r.Width * ratio;
        RectF tipRect(thumbX - 20.0f, y - 18.0f, 40.0f, 14.0f);
        GraphicsPath tipPath;
        AddRoundedRectPath(tipPath, tipRect.X, tipRect.Y, tipRect.Width, tipRect.Height, 3.0f);
        SolidBrush tipBg(Color(220, 20, 24, 32));
        Pen tipBorder(Color(140, 175, 225, 255), 1.0f);
        g.FillPath(&tipBg, &tipPath);
        g.DrawPath(&tipBorder, &tipPath);

        FontFamily ff(L"Microsoft YaHei UI");
        Font tipFont(&ff, 9.5f, FontStyleBold, UnitPixel);
        StringFormat sf;
        sf.SetAlignment(StringAlignmentCenter);
        sf.SetLineAlignment(StringAlignmentCenter);
        SolidBrush txtBrush(Color(250, 230, 244, 255));
        g.DrawString(scrubTimeText.c_str(), -1, &tipFont, tipRect, &sf, &txtBrush);
    }
}

} // namespace airmuse