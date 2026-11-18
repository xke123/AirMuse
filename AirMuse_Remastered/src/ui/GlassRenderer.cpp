#include <cmath>
#include "GlassRenderer.hpp"
#include <dwmapi.h>
#include <shlwapi.h>
#include <algorithm>
#include <cstdio>
#include "../resource.h"
#include "GlassAssets.inl"

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

static Gdiplus::Bitmap* GetFocusGlassBitmap() {
    static Gdiplus::Bitmap* bmp = nullptr;
    if (!bmp) {
        auto loaded = GlassRenderer::LoadPngResource(GetModuleHandleW(nullptr), IDR_PNG_WINDOWGLASS_FCS);
        if (loaded) {
            bmp = loaded.release();
        } else {
            bmp = new Gdiplus::Bitmap(30, 40, 30 * sizeof(uint32_t), PixelFormat32bppARGB, (BYTE*)s_airplayGlassFocusPixels);
        }
    }
    return bmp;
}

static Gdiplus::Bitmap* GetUnfocusGlassBitmap() {
    static Gdiplus::Bitmap* bmp = nullptr;
    if (!bmp) {
        auto loaded = GlassRenderer::LoadPngResource(GetModuleHandleW(nullptr), IDR_PNG_WINDOWGLASS);
        if (loaded) {
            bmp = loaded.release();
        } else {
            bmp = new Gdiplus::Bitmap(30, 40, 30 * sizeof(uint32_t), PixelFormat32bppARGB, (BYTE*)s_airplayGlassUnfocusPixels);
        }
    }
    return bmp;
}

static void DrawAirPlay9Slice(Graphics& g, Bitmap* bmp, int dstW, int dstH, float opacity) {
    if (!bmp || dstW <= 0 || dstH <= 0 || opacity <= 0.001f) return;

    ImageAttributes* pAttr = nullptr;
    ImageAttributes attr;
    if (opacity < 0.999f) {
        ColorMatrix matrix = {{
            {1.0f, 0.0f, 0.0f, 0.0f, 0.0f},
            {0.0f, 1.0f, 0.0f, 0.0f, 0.0f},
            {0.0f, 0.0f, 1.0f, 0.0f, 0.0f},
            {0.0f, 0.0f, 0.0f, opacity, 0.0f},
            {0.0f, 0.0f, 0.0f, 0.0f, 1.0f}
        }};
        attr.SetColorMatrix(&matrix, ColorMatrixFlagsDefault, ColorAdjustTypeBitmap);
        pAttr = &attr;
    }

    const float s = static_cast<float>(bmp->GetWidth()) / 30.0f;
    const float dstCW = 15.0f;
    const float dstCH = 20.0f;
    const float srcCW = 15.0f * s;
    const float srcCH = 20.0f * s;
    const float srcW  = static_cast<float>(bmp->GetWidth());
    const float srcH  = static_cast<float>(bmp->GetHeight());
    const float fDstW = static_cast<float>(dstW);
    const float fDstH = static_cast<float>(dstH);

    // 4 Corners (Logical 15x20 DIP, source scaled by s)
    g.DrawImage(bmp, RectF(0.0f, 0.0f, dstCW, dstCH), 0.0f, 0.0f, srcCW, srcCH, UnitPixel, pAttr);
    g.DrawImage(bmp, RectF(fDstW - dstCW, 0.0f, dstCW, dstCH), srcW - srcCW, 0.0f, srcCW, srcCH, UnitPixel, pAttr);
    g.DrawImage(bmp, RectF(0.0f, fDstH - dstCH, dstCW, dstCH), 0.0f, srcH - srcCH, srcCW, srcCH, UnitPixel, pAttr);
    g.DrawImage(bmp, RectF(fDstW - dstCW, fDstH - dstCH, dstCW, dstCH), srcW - srcCW, srcH - srcCH, srcCW, srcCH, UnitPixel, pAttr);

    // Horizontal edges:
    if (fDstW > dstCW * 2.0f) {
        float edgeDstW = fDstW - dstCW * 2.0f;
        float edgeSrcX = 14.0f * s;
        float edgeSrcW = 2.0f * s;
        g.DrawImage(bmp, RectF(dstCW, 0.0f, edgeDstW, dstCH), edgeSrcX, 0.0f, edgeSrcW, srcCH, UnitPixel, pAttr);
        g.DrawImage(bmp, RectF(dstCW, fDstH - dstCH, edgeDstW, dstCH), edgeSrcX, srcH - srcCH, edgeSrcW, srcCH, UnitPixel, pAttr);
    }
    // Vertical edges (only 5 DIP wide border, avoiding thick pillar bleed into body):
    if (fDstH > dstCH * 2.0f) {
        float edgeDstH = fDstH - dstCH * 2.0f;
        const float edgeW = 5.0f;
        const float srcEdgeW = 5.0f * s;
        float edgeSrcY = 19.0f * s;
        float edgeSrcH = 2.0f * s;
        g.DrawImage(bmp, RectF(0.0f, dstCH, edgeW, edgeDstH), 0.0f, edgeSrcY, srcEdgeW, edgeSrcH, UnitPixel, pAttr);
        g.DrawImage(bmp, RectF(fDstW - edgeW, dstCH, edgeW, edgeDstH), srcW - srcEdgeW, edgeSrcY, srcEdgeW, edgeSrcH, UnitPixel, pAttr);
    }
}

void GlassRenderer::DrawAirPlayGlassFrame(Graphics& g, int dstW, int dstH, float hoverGloss, float focusRatio, Bitmap* ambientArtwork) {
    DrawAirPlayGlassFrame(g, dstW, dstH, hoverGloss, focusRatio, ambientArtwork, false);
}

void GlassRenderer::DrawAirPlayGlassFrame(Graphics& g, int dstW, int dstH, float /*hoverGloss*/, float focusRatio, Bitmap* ambientArtwork, bool hasMainGloss) {
    focusRatio = std::clamp(focusRatio, 0.0f, 1.0f);

    if (dstH <= 36) {
        Bitmap* bmpFocus = GetFocusGlassBitmap();
        Bitmap* bmpUnfocus = GetUnfocusGlassBitmap();

        InterpolationMode oldInterp = g.GetInterpolationMode();
        g.SetInterpolationMode(InterpolationModeHighQualityBicubic);

        GraphicsPath outerClip;
        AddRoundedRectPath(outerClip, 0.0f, 0.0f, static_cast<float>(dstW), static_cast<float>(dstH), 3.2f);
        GraphicsState sClip = g.Save();
        g.SetClip(&outerClip, CombineModeIntersect);

        if (focusRatio >= 0.99f) {
            DrawAirPlay9Slice(g, bmpFocus, dstW, dstH, 1.0f);
        } else if (focusRatio <= 0.01f) {
            DrawAirPlay9Slice(g, bmpUnfocus, dstW, dstH, 1.0f);
        } else {
            DrawAirPlay9Slice(g, bmpUnfocus, dstW, dstH, 1.0f);
            DrawAirPlay9Slice(g, bmpFocus, dstW, dstH, focusRatio);
        }

        g.Restore(sClip);
        g.SetInterpolationMode(oldInterp);
        return;
    }

    // 1. 中间主显示区域底色 (Middle Main Body)
    const float midY = 20.0f;
    const float midH = static_cast<float>(dstH) - 40.0f;
    const float midX = 5.0f;
    const float midW = static_cast<float>(dstW) - 10.0f;

    if (midH > 0.0f && midW > 0.0f) {
        if (hasMainGloss) {
            // 主面板垂直方向从 rgb(58, 58, 58) 过度到 rgb(31, 31, 31)
            LinearGradientBrush bodyBaseBrush(PointF(midX, midY), PointF(midX, midY + midH),
                                              Color(255, 58, 58, 58), Color(255, 31, 31, 31));
            g.FillRectangle(&bodyBaseBrush, RectF(midX, midY, midW, midH));
        } else {
            // 歌词面板和数据来源面板的主色: rgb(23, 23, 23)
            SolidBrush bodyBaseBrush(Color(255, 23, 23, 23));
            g.FillRectangle(&bodyBaseBrush, RectF(midX, midY, midW, midH));
        }

        // 专辑背景微漫反射 (如有)
        if (ambientArtwork && ambientArtwork->GetWidth() > 0) {
            GraphicsState s = g.Save();
            g.SetClip(RectF(midX, midY, midW, midH));
            DrawImageAlpha(g, ambientArtwork, RectF(midX, midY - 30.0f, midW, midW),
                           0, 0, ambientArtwork->GetWidth(), ambientArtwork->GetHeight(), 0.15f, 0.85f);
            g.Restore(s);
        }
    }

    // 2. 原版 9-宫格水晶玻璃外框绘制 (1:1 视网膜级 4x 资产超采样)
    Bitmap* bmpFocus = GetFocusGlassBitmap();
    Bitmap* bmpUnfocus = GetUnfocusGlassBitmap();

    InterpolationMode oldInterp = g.GetInterpolationMode();
    g.SetInterpolationMode(InterpolationModeHighQualityBicubic);

    if (focusRatio >= 0.99f) {
        DrawAirPlay9Slice(g, bmpFocus, dstW, dstH, 1.0f);
    } else if (focusRatio <= 0.01f) {
        DrawAirPlay9Slice(g, bmpUnfocus, dstW, dstH, 1.0f);
    } else {
        DrawAirPlay9Slice(g, bmpUnfocus, dstW, dstH, 1.0f);
        DrawAirPlay9Slice(g, bmpFocus, dstW, dstH, focusRatio);
    }

    g.SetInterpolationMode(oldInterp);

    // 3. 原版物理咬合卡槽接缝 (Groove Seams) - 必须在 9-宫格后绘制，确保玻璃与暗色之间的分界线清晰锐利！
    if (midH > 0.0f && midW > 0.0f) {
        // 顶部接缝 (y=20): 玻璃底深色咬合暗槽线 + 下方 1px 亚像素微光反光亮线
        Pen grooveDarkTop(Color(static_cast<BYTE>(190 + 35 * focusRatio), 12, 13, 16), 1.0f);
        Pen grooveWhiteTop(Color(static_cast<BYTE>(45 + 35 * focusRatio), 255, 255, 255), 1.0f);
        g.DrawLine(&grooveDarkTop, midX, 20.0f, midX + midW, 20.0f);
        g.DrawLine(&grooveWhiteTop, midX, 21.0f, midX + midW, 21.0f);

        // 底部接缝 (y=dstH-20): 玻璃顶深色咬合暗槽线 + 下方 1px 亚像素微光反光亮线
        float botY = static_cast<float>(dstH - 20);
        Pen grooveDarkBot(Color(static_cast<BYTE>(190 + 35 * focusRatio), 12, 13, 16), 1.0f);
        Pen grooveWhiteBot(Color(static_cast<BYTE>(45 + 35 * focusRatio), 255, 255, 255), 1.0f);
        g.DrawLine(&grooveDarkBot, midX, botY - 1.0f, midX + midW, botY - 1.0f);
        g.DrawLine(&grooveWhiteBot, midX, botY, midX + midW, botY);
    }
}

void GlassRenderer::DrawScrollGlassFrame(Graphics& g, int dstW, int dstH, float animProgress, float /*hoverGloss*/, float focusRatio, int mode, Bitmap* ambientArtwork) {
    animProgress = std::clamp(animProgress, 0.0f, 1.0f);
    focusRatio = std::clamp(focusRatio, 0.0f, 1.0f);

    const float W = static_cast<float>(dstW);
    const float H = static_cast<float>(dstH);
    const float barH = 20.0f;
    const float cx = W * 0.5f;

    float cy = H * 0.5f;
    if (mode == 2) cy = barH * 0.5f;           // 10.0f (顶栏中心)
    else if (mode == 3) cy = H - barH * 0.5f;  // 96.0f (底栏中心)

    Bitmap* bmpFocus = GetFocusGlassBitmap();
    Bitmap* bmpUnfocus = GetUnfocusGlassBitmap();

    // =========================================================================
    // 统一玻璃切片渲染核心 (100% 全阶段采用原版 9-宫格纯净白玻璃切片资产，零手绘渐变色)
    // =========================================================================
    auto makeAttr = [](float opacity, ImageAttributes& attr) -> ImageAttributes* {
        if (opacity >= 0.999f) return nullptr;
        ColorMatrix matrix = {{
            {1.0f, 0.0f, 0.0f, 0.0f, 0.0f},
            {0.0f, 1.0f, 0.0f, 0.0f, 0.0f},
            {0.0f, 0.0f, 1.0f, 0.0f, 0.0f},
            {0.0f, 0.0f, 0.0f, opacity, 0.0f},
            {0.0f, 0.0f, 0.0f, 0.0f, 1.0f}
        }};
        attr.SetColorMatrix(&matrix, ColorMatrixFlagsDefault, ColorAdjustTypeBitmap);
        return &attr;
    };

    // 1. 渲染独立单根封闭玻璃条 (用于阶段一玻璃珠与阶段二单条拉伸，上高光+下高光，全圆角)
    auto drawSingleBar = [&](Bitmap* bmp, float x0, float y0, float curW, float cornerR, float opacity) {
        if (!bmp || curW <= 0.5f || opacity <= 0.001f) return;
        ImageAttributes attr;
        ImageAttributes* pAttr = makeAttr(opacity, attr);

        const float s = static_cast<float>(bmp->GetWidth()) / 30.0f;
        const float dstCW = 15.0f;
        const float srcCW = 15.0f * s;
        const float srcCH_half = 10.0f * s; // 40 px @ 4x
        const float srcW  = static_cast<float>(bmp->GetWidth());
        const float srcH  = static_cast<float>(bmp->GetHeight());
        const float srcY_bot = srcH - srcCH_half; // 120 px @ 4x

        GraphicsPath clipPath;
        bool needsClip = (cornerR > 3.2f || curW < W - 0.5f);
        if (needsClip) {
            AddRoundedRectPath(clipPath, x0, y0, curW, 20.0f, cornerR);
        }

        GraphicsState sClip = g.Save();
        if (needsClip) {
            g.SetClip(&clipPath, CombineModeIntersect);
        }

        if (curW <= dstCW * 2.0f) {
            float halfW = curW * 0.5f;
            float ratio = halfW / dstCW;
            // 上半部 (0..10 DIP)
            g.DrawImage(bmp, RectF(x0, y0, halfW, 10.0f), 0.0f, 0.0f, srcCW * ratio, srcCH_half, UnitPixel, pAttr);
            g.DrawImage(bmp, RectF(x0 + halfW, y0, halfW, 10.0f), srcW - srcCW * ratio, 0.0f, srcCW * ratio, srcCH_half, UnitPixel, pAttr);
            // 下半部 (10..20 DIP)
            g.DrawImage(bmp, RectF(x0, y0 + 10.0f, halfW, 10.0f), 0.0f, srcY_bot, srcCW * ratio, srcCH_half, UnitPixel, pAttr);
            g.DrawImage(bmp, RectF(x0 + halfW, y0 + 10.0f, halfW, 10.0f), srcW - srcCW * ratio, srcY_bot, srcCW * ratio, srcCH_half, UnitPixel, pAttr);
        } else {
            float edgeDstW = curW - dstCW * 2.0f;
            float edgeSrcX = 14.0f * s;
            float edgeSrcW = 2.0f * s;
            // 上半部 (0..10 DIP)
            g.DrawImage(bmp, RectF(x0, y0, dstCW, 10.0f), 0.0f, 0.0f, srcCW, srcCH_half, UnitPixel, pAttr);
            g.DrawImage(bmp, RectF(x0 + curW - dstCW, y0, dstCW, 10.0f), srcW - srcCW, 0.0f, srcCW, srcCH_half, UnitPixel, pAttr);
            g.DrawImage(bmp, RectF(x0 + dstCW, y0, edgeDstW, 10.0f), edgeSrcX, 0.0f, edgeSrcW, srcCH_half, UnitPixel, pAttr);
            // 下半部 (10..20 DIP)
            g.DrawImage(bmp, RectF(x0, y0 + 10.0f, dstCW, 10.0f), 0.0f, srcY_bot, srcCW, srcCH_half, UnitPixel, pAttr);
            g.DrawImage(bmp, RectF(x0 + curW - dstCW, y0 + 10.0f, dstCW, 10.0f), srcW - srcCW, srcY_bot, srcCW, srcCH_half, UnitPixel, pAttr);
            g.DrawImage(bmp, RectF(x0 + dstCW, y0 + 10.0f, edgeDstW, 10.0f), edgeSrcX, srcY_bot, edgeSrcW, srcCH_half, UnitPixel, pAttr);
        }

        g.Restore(sClip);
    };

    // 2. 渲染顶部玻璃条 (高度 20 DIP，源自 bmp 的 0..80 像素，顶高光+底咬合平边)
    auto drawTopBar = [&](Bitmap* bmp, float x0, float y0, float curW, float cornerR, float opacity) {
        if (!bmp || curW <= 0.5f || opacity <= 0.001f) return;
        ImageAttributes attr;
        ImageAttributes* pAttr = makeAttr(opacity, attr);

        const float s = static_cast<float>(bmp->GetWidth()) / 30.0f;
        const float dstCW = 15.0f;
        const float srcCW = 15.0f * s;
        const float srcCH = 20.0f * s; // 80 px @ 4x
        const float srcW  = static_cast<float>(bmp->GetWidth());

        GraphicsPath clipPath;
        bool needsClip = (cornerR > 3.2f || curW < W - 0.5f);
        if (needsClip) {
            AddRoundedRectPath(clipPath, x0, y0, curW, 20.0f, cornerR);
        }

        GraphicsState sClip = g.Save();
        if (needsClip) {
            g.SetClip(&clipPath, CombineModeIntersect);
        }

        if (curW <= dstCW * 2.0f) {
            float halfW = curW * 0.5f;
            float ratio = halfW / dstCW;
            g.DrawImage(bmp, RectF(x0, y0, halfW, 20.0f), 0.0f, 0.0f, srcCW * ratio, srcCH, UnitPixel, pAttr);
            g.DrawImage(bmp, RectF(x0 + halfW, y0, halfW, 20.0f), srcW - srcCW * ratio, 0.0f, srcCW * ratio, srcCH, UnitPixel, pAttr);
        } else {
            float edgeDstW = curW - dstCW * 2.0f;
            float edgeSrcX = 14.0f * s;
            float edgeSrcW = 2.0f * s;
            g.DrawImage(bmp, RectF(x0, y0, dstCW, 20.0f), 0.0f, 0.0f, srcCW, srcCH, UnitPixel, pAttr);
            g.DrawImage(bmp, RectF(x0 + curW - dstCW, y0, dstCW, 20.0f), srcW - srcCW, 0.0f, srcCW, srcCH, UnitPixel, pAttr);
            g.DrawImage(bmp, RectF(x0 + dstCW, y0, edgeDstW, 20.0f), edgeSrcX, 0.0f, edgeSrcW, srcCH, UnitPixel, pAttr);
        }

        g.Restore(sClip);
    };

    // 3. 渲染底部玻璃条 (高度 20 DIP，源自 bmp 的 80..160 像素，顶咬合平边+底高光)
    auto drawBotBar = [&](Bitmap* bmp, float x0, float y0, float curW, float cornerR, float opacity) {
        if (!bmp || curW <= 0.5f || opacity <= 0.001f) return;
        ImageAttributes attr;
        ImageAttributes* pAttr = makeAttr(opacity, attr);

        const float s = static_cast<float>(bmp->GetWidth()) / 30.0f;
        const float dstCW = 15.0f;
        const float srcCW = 15.0f * s;
        const float srcCH = 20.0f * s; // 80 px @ 4x
        const float srcW  = static_cast<float>(bmp->GetWidth());
        const float srcH  = static_cast<float>(bmp->GetHeight());
        const float srcY  = srcH - srcCH; // 80 px @ 4x

        GraphicsPath clipPath;
        bool needsClip = (cornerR > 3.2f || curW < W - 0.5f);
        if (needsClip) {
            AddRoundedRectPath(clipPath, x0, y0, curW, 20.0f, cornerR);
        }

        GraphicsState sClip = g.Save();
        if (needsClip) {
            g.SetClip(&clipPath, CombineModeIntersect);
        }

        if (curW <= dstCW * 2.0f) {
            float halfW = curW * 0.5f;
            float ratio = halfW / dstCW;
            g.DrawImage(bmp, RectF(x0, y0, halfW, 20.0f), 0.0f, srcY, srcCW * ratio, srcCH, UnitPixel, pAttr);
            g.DrawImage(bmp, RectF(x0 + halfW, y0, halfW, 20.0f), srcW - srcCW * ratio, srcY, srcCW * ratio, srcCH, UnitPixel, pAttr);
        } else {
            float edgeDstW = curW - dstCW * 2.0f;
            float edgeSrcX = 14.0f * s;
            float edgeSrcW = 2.0f * s;
            g.DrawImage(bmp, RectF(x0, y0, dstCW, 20.0f), 0.0f, srcY, srcCW, srcCH, UnitPixel, pAttr);
            g.DrawImage(bmp, RectF(x0 + curW - dstCW, y0, dstCW, 20.0f), srcW - srcCW, srcY, srcCW, srcCH, UnitPixel, pAttr);
            g.DrawImage(bmp, RectF(x0 + dstCW, y0, edgeDstW, 20.0f), edgeSrcX, srcY, edgeSrcW, srcCH, UnitPixel, pAttr);
        }

        g.Restore(sClip);
    };

    // 4. 渲染双条展开后的两侧垂直连贯玻璃侧边 (5 DIP 宽)
    auto drawSideEdges = [&](Bitmap* bmp, float x0, float curW, float midTop, float midH, float opacity) {
        if (!bmp || midH <= 0.0f || opacity <= 0.001f) return;
        ImageAttributes attr;
        ImageAttributes* pAttr = makeAttr(opacity, attr);

        const float s = static_cast<float>(bmp->GetWidth()) / 30.0f;
        const float edgeW = 5.0f;
        const float srcEdgeW = 5.0f * s;
        const float srcEdgeH = 2.0f * s;
        const float edgeSrcY = 19.0f * s;
        const float srcW  = static_cast<float>(bmp->GetWidth());

        g.DrawImage(bmp, RectF(x0, midTop, edgeW, midH), 0.0f, edgeSrcY, srcEdgeW, srcEdgeH, UnitPixel, pAttr);
        g.DrawImage(bmp, RectF(x0 + curW - edgeW, midTop, edgeW, midH), srcW - srcEdgeW, edgeSrcY, srcEdgeW, srcEdgeH, UnitPixel, pAttr);
    };

    auto renderWithFocus = [&](auto&& drawFunc) {
        InterpolationMode oldInterp = g.GetInterpolationMode();
        g.SetInterpolationMode(InterpolationModeHighQualityBicubic);
        if (focusRatio >= 0.99f) {
            drawFunc(bmpFocus, 1.0f);
        } else if (focusRatio <= 0.01f) {
            drawFunc(bmpUnfocus, 1.0f);
        } else {
            drawFunc(bmpUnfocus, 1.0f);
            drawFunc(bmpFocus, focusRatio);
        }
        g.SetInterpolationMode(oldInterp);
    };

    // =========================================================================
    // 阶段一: [0.00 ~ 0.22] 纯净原版玻璃珠凝聚 (Glass Orb Pop-in)
    // =========================================================================
    if (animProgress <= 0.22f) {
        float u = animProgress / 0.22f;
        float diam = 20.0f * std::min(1.0f, u * 1.15f);
        float r = diam * 0.5f;
        if (r < 0.5f) return;

        float alpha = std::clamp(u * 1.4f, 0.0f, 1.0f);

        // 外部纯白微光柔和光晕 (纯无色透明度过渡)
        {
            GraphicsPath glowPath;
            glowPath.AddEllipse(cx - r * 1.6f, cy - r * 1.6f, r * 3.2f, r * 3.2f);
            PathGradientBrush glowPgb(&glowPath);
            glowPgb.SetCenterPoint(PointF(cx, cy));
            glowPgb.SetCenterColor(Color(static_cast<BYTE>(50.0f * u), 255, 255, 255));
            Color surroundGlow(0, 255, 255, 255);
            int cnt = 1;
            glowPgb.SetSurroundColors(&surroundGlow, &cnt);
            g.FillPath(&glowPgb, &glowPath);
        }

        // 直接用系统原版白玻璃切片渲染小球 (圆角 r = diam * 0.5，形成天然无瑕的水晶玻璃圆珠)
        renderWithFocus([&](Bitmap* bmp, float op) {
            drawSingleBar(bmp, cx - r, cy - 10.0f, diam, r, op * alpha);
        });

        // 高光处的星芒闪光
        if (u > 0.35f) {
            float starU = std::clamp((u - 0.35f) / 0.55f, 0.0f, 1.0f);
            float starIntensity = std::sin(starU * 3.14159f);
            if (starIntensity > 0.02f) {
                float hx = cx - r * 0.35f;
                float hy = cy - r * 0.42f;
                float rayLen = 5.0f * starIntensity;
                BYTE starA = static_cast<BYTE>(240.0f * starIntensity);
                Pen starPen(Color(starA, 255, 255, 255), 1.0f);
                g.DrawLine(&starPen, hx - rayLen, hy, hx + rayLen, hy);
                g.DrawLine(&starPen, hx, hy - rayLen, hx, hy + rayLen);
                SolidBrush centerGlint(Color(starA, 255, 255, 255));
                g.FillEllipse(&centerGlint, hx - 1.0f, hy - 1.0f, 2.0f, 2.0f);
            }
        }
        return;
    }

    // =========================================================================
    // 阶段二: [0.22 ~ 0.52] 原版白玻璃横向拉伸延展成单根玻璃条 (Horizontal Stretch)
    // =========================================================================
    if (animProgress <= 0.52f) {
        float u = (animProgress - 0.22f) / 0.30f;
        float s = 3.0f * u * u - 2.0f * u * u * u;
        float curW = 20.0f + s * (W - 20.0f);
        float r = std::min(10.0f, 10.0f - s * 6.8f); // 10 -> 3.2
        float x0 = cx - curW * 0.5f;

        // 横向微光纯白辉光
        {
            GraphicsPath sheenPath;
            sheenPath.AddEllipse(x0 - 6.0f, cy - 14.0f, curW + 12.0f, 28.0f);
            PathGradientBrush sheenPgb(&sheenPath);
            sheenPgb.SetCenterPoint(PointF(cx, cy));
            sheenPgb.SetCenterColor(Color(static_cast<BYTE>(35.0f * (1.0f - u * 0.35f)), 255, 255, 255));
            Color surroundSheen(0, 255, 255, 255);
            int cnt = 1;
            sheenPgb.SetSurroundColors(&surroundSheen, &cnt);
            g.FillPath(&sheenPgb, &sheenPath);
        }

        // 单根玻璃条横向拉伸 (100% 原版白玻璃材质，圆角从 10 渐变为 3.2)
        renderWithFocus([&](Bitmap* bmp, float op) {
            drawSingleBar(bmp, x0, cy - 10.0f, curW, r, op);
        });
        return;
    }

    // =========================================================================
    // 阶段三 & 四: [0.52 ~ 0.70] 单条分裂为双条; [0.70 ~ 1.00] 卷轴双条展开
    // =========================================================================
    float yTop = 0.0f;
    float yBot = H - barH;
    float contactY = H * 0.5f;
    float splitGlowAlpha = 0.0f;

    if (animProgress <= 0.70f) {
        // [阶段三: 分裂]
        float u = (animProgress - 0.52f) / 0.18f;
        float s = 3.0f * u * u - 2.0f * u * u * u;
        splitGlowAlpha = (1.0f - u) * std::sin(u * 3.14159f);

        if (mode == 2) {
            yTop = 0.0f;
            yBot = s * barH;
            contactY = barH;
        } else if (mode == 3) {
            yTop = (H - barH) - s * barH;
            yBot = H - barH;
            contactY = H - barH;
        } else {
            // mode 1: 从中心分裂
            yTop = (cy - barH * 0.5f) - s * (barH * 0.5f);
            yBot = (cy - barH * 0.5f) + s * (barH * 0.5f);
            contactY = cy;
        }
    } else {
        // [阶段四: 卷轴展开]
        float p = (animProgress - 0.70f) / 0.30f;
        float s = 3.0f * p * p - 2.0f * p * p * p;
        if (mode == 2) {
            yTop = 0.0f;
            yBot = barH + s * (H - 2.0f * barH);
            contactY = barH;
        } else if (mode == 3) {
            yTop = (1.0f - s) * (H - 2.0f * barH);
            yBot = H - barH;
            contactY = H - barH;
        } else {
            yTop = (1.0f - s) * (cy - barH);
            yBot = (1.0f - s) * cy + s * (H - barH);
            contactY = cy;
        }
    }

    const float midTop = yTop + barH;
    const float midBot = yBot;
    const float midH   = midBot - midTop;
    const float midX   = 5.0f;
    const float midW   = W - 10.0f;

    // 1. 中间主显示区域底色 (仅在卷轴展开且高度大于0时绘制)
    if (midH > 0.0f && midW > 0.0f) {
        if (mode == 1) {
            // 主面板: 垂直方向从 rgb(58, 58, 58) 过度到 rgb(31, 31, 31)
            LinearGradientBrush bodyBaseBrush(PointF(midX, midTop), PointF(midX, midBot),
                                              Color(255, 58, 58, 58), Color(255, 31, 31, 31));
            g.FillRectangle(&bodyBaseBrush, RectF(midX, midTop, midW, midH));
        } else {
            // 歌词面板与数据来源面板的主色: rgb(23, 23, 23)
            SolidBrush bodyBaseBrush(Color(255, 23, 23, 23));
            g.FillRectangle(&bodyBaseBrush, RectF(midX, midTop, midW, midH));
        }

        // 专辑背景微漫反射 (如有)
        if (ambientArtwork && ambientArtwork->GetWidth() > 0) {
            float pScroll = std::max(0.0f, (animProgress - 0.70f) / 0.30f);
            GraphicsState s = g.Save();
            g.SetClip(RectF(midX, midTop, midW, midH));
            DrawImageAlpha(g, ambientArtwork, RectF(midX, midTop - 30.0f, midW, midW),
                           0, 0, ambientArtwork->GetWidth(), ambientArtwork->GetHeight(), 0.15f * pScroll, 0.85f);
            g.Restore(s);
        }

        // 卷轴两端物理滚轴阴影
        if (midH > 2.0f) {
            float pScroll = (animProgress - 0.70f) / 0.30f;
            float shadowDepth = std::min(10.0f, midH * 0.45f);
            LinearGradientBrush topRollShadow(PointF(midX, midTop), PointF(midX, midTop + shadowDepth),
                                              Color(static_cast<BYTE>(90 * (1.0f - pScroll * 0.5f)), 0, 0, 0),
                                              Color(0, 0, 0, 0));
            g.FillRectangle(&topRollShadow, RectF(midX, midTop, midW, shadowDepth));

            LinearGradientBrush botRollShadow(PointF(midX, midBot - shadowDepth), PointF(midX, midBot),
                                              Color(0, 0, 0, 0),
                                              Color(static_cast<BYTE>(90 * (1.0f - pScroll * 0.5f)), 0, 0, 0));
            g.FillRectangle(&botRollShadow, RectF(midX, midBot - shadowDepth, midW, shadowDepth));
        }
    }

    // 2. 原版 9-宫格水晶玻璃条绘制 (100% 材质同源，物理分离无重叠叠黑)
    renderWithFocus([&](Bitmap* bmp, float op) {
        if (animProgress <= 0.70f) {
            // [阶段三: 分裂过程中的两根玻璃条]
            if (mode == 2) {
                // 顶部玻璃条在 0..20，底部玻璃条从 y=20 向下平滑伸展滑出，两者互不重叠
                drawTopBar(bmp, 0.0f, yTop, W, 3.2f, op);
                GraphicsState sBot = g.Save();
                g.SetClip(RectF(0.0f, barH, W, H - barH), CombineModeIntersect);
                drawBotBar(bmp, 0.0f, yBot, W, 3.2f, op);
                g.Restore(sBot);
            } else if (mode == 3) {
                // 底部玻璃条在 H-20..H，顶部玻璃条从 y=H-20 向上平滑伸展滑出，两者互不重叠
                drawBotBar(bmp, 0.0f, yBot, W, 3.2f, op);
                GraphicsState sTop = g.Save();
                g.SetClip(RectF(0.0f, 0.0f, W, H - barH), CombineModeIntersect);
                drawTopBar(bmp, 0.0f, yTop, W, 3.2f, op);
                g.Restore(sTop);
            } else {
                // mode 1: 中心对称分裂 (通过中心交界线裁切，实现零重叠、物理无瑕分离)
                GraphicsState sTop = g.Save();
                g.SetClip(RectF(0.0f, 0.0f, W, cy), CombineModeIntersect);
                drawTopBar(bmp, 0.0f, yTop, W, 3.2f, op);
                g.Restore(sTop);

                GraphicsState sBot = g.Save();
                g.SetClip(RectF(0.0f, cy, W, H - cy), CombineModeIntersect);
                drawBotBar(bmp, 0.0f, yBot, W, 3.2f, op);
                g.Restore(sBot);
            }
        } else {
            // [阶段四: 卷轴展开中的两根玻璃条与侧边连贯边框]
            drawTopBar(bmp, 0.0f, yTop, W, 3.2f, op);
            drawBotBar(bmp, 0.0f, yBot, W, 3.2f, op);
            drawSideEdges(bmp, 0.0f, W, midTop, midH, op);
        }
    });

    // 3. 原版物理咬合卡槽接缝 (Groove Seams) 与 分裂裂隙能量光
    if (midH > 0.5f) {
        Pen grooveDarkTop(Color(static_cast<BYTE>(190 + 35 * focusRatio), 12, 13, 16), 1.0f);
        Pen grooveWhiteTop(Color(static_cast<BYTE>(45 + 35 * focusRatio), 255, 255, 255), 1.0f);
        g.DrawLine(&grooveDarkTop, midX, midTop, midX + midW, midTop);
        g.DrawLine(&grooveWhiteTop, midX, midTop + 1.0f, midX + midW, midTop + 1.0f);

        Pen grooveDarkBot(Color(static_cast<BYTE>(190 + 35 * focusRatio), 12, 13, 16), 1.0f);
        Pen grooveWhiteBot(Color(static_cast<BYTE>(45 + 35 * focusRatio), 255, 255, 255), 1.0f);
        g.DrawLine(&grooveDarkBot, midX, midBot - 1.0f, midX + midW, midBot - 1.0f);
        g.DrawLine(&grooveWhiteBot, midX, midBot, midX + midW, midBot);
    } else {
        // 两根玻璃条咬合接触线
        Pen contactDark(Color(static_cast<BYTE>(175 + 45 * focusRatio), 14, 15, 18), 1.0f);
        Pen contactLight(Color(static_cast<BYTE>(75 + 65 * focusRatio), 255, 255, 255), 1.0f);
        g.DrawLine(&contactDark, 2.0f, contactY, W - 2.0f, contactY);
        g.DrawLine(&contactLight, 3.0f, contactY + 1.0f, W - 3.0f, contactY + 1.0f);

        // 分裂瞬间的纯白能量辉光
        if (splitGlowAlpha > 0.02f) {
            BYTE ga = static_cast<BYTE>(210.0f * splitGlowAlpha);
            Pen energyPen(Color(ga, 240, 248, 255), 1.2f);
            g.DrawLine(&energyPen, 8.0f, contactY, W - 8.0f, contactY);
        }
    }
}

void GlassRenderer::DrawSpecularSweep(Graphics& g, int dstW, int dstH, float sweepRatio, float intensity, float /*sweepRatioX*/) {
    if (intensity <= 0.005f) return;
    const float padX = 5.0f;
    const float fw = static_cast<float>(dstW) - padX * 2.0f;
    const float midY = 20.0f;
    const float midH = static_cast<float>(dstH) - 40.0f;
    if (fw <= 10.0f || midH <= 10.0f) return;

    // 严格限制在两个玻璃条中间的主面板区域 (midClip)
    RectF midClip(padX, midY, fw, midH);

    GraphicsState saved = g.Save();
    g.SetClip(midClip, CombineModeIntersect);

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

    // 进度条背景底槽：与系统主色 rgb(23, 23, 23) 统一
    SolidBrush bgBrush(Color(180, 23, 23, 23));
    Pen borderPen(Color(highlight || scrubbing ? 160 : 60, 201, 201, 201), 1.0f);
    g.FillPath(&bgBrush, &bgPath);
    g.DrawPath(&borderPen, &bgPath);

    ratio = std::clamp(ratio, 0.0f, 1.0f);
    if (ratio > 0.015f) {
        float fillW = std::max(h, r.Width * ratio);
        GraphicsPath fgPath;
        fgPath.AddArc(r.X + 1, y + 1, h - 2, h - 2, 90, 180);
        fgPath.AddArc(r.X + fillW - h + 1, y + 1, h - 2, h - 2, 270, 180);
        fgPath.CloseFigure();

        // 胶囊进度条填充色：垂直方向从 高亮色 rgb(201, 201, 201) 过渡到 UI主色 rgb(166, 166, 166)
        LinearGradientBrush fgBrush(PointF(r.X, y), PointF(r.X, y + h),
                                    Color(245, 201, 201, 201),
                                    Color(220, 166, 166, 166));
        g.FillPath(&fgBrush, &fgPath);
    }

    if (scrubbing && !scrubTimeText.empty()) {
        float thumbX = r.X + r.Width * ratio;
        RectF tipRect(thumbX - 20.0f, y - 18.0f, 40.0f, 14.0f);
        GraphicsPath tipPath;
        AddRoundedRectPath(tipPath, tipRect.X, tipRect.Y, tipRect.Width, tipRect.Height, 3.0f);
        SolidBrush tipBg(Color(230, 23, 23, 23));
        Pen tipBorder(Color(180, 201, 201, 201), 1.0f);
        g.FillPath(&tipBg, &tipPath);
        g.DrawPath(&tipBorder, &tipPath);

        FontFamily ff(L"Microsoft YaHei UI");
        Font tipFont(&ff, 9.5f, FontStyleBold, UnitPixel);
        StringFormat sf;
        sf.SetAlignment(StringAlignmentCenter);
        sf.SetLineAlignment(StringAlignmentCenter);
        SolidBrush txtBrush(Color(255, 201, 201, 201));
        g.DrawString(scrubTimeText.c_str(), -1, &tipFont, tipRect, &sf, &txtBrush);
    }
}

} // namespace airmuse