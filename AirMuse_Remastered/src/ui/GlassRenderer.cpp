#include <cmath>
#include "GlassRenderer.hpp"
#include <dwmapi.h>
#include <shlwapi.h>
#include <algorithm>
#include <cstdio>

using namespace Gdiplus;

namespace airmuse {

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

void GlassRenderer::DrawAirPlayGlassFrame(Graphics& g, int dstW, int dstH, float hoverGloss, bool focused, Bitmap* ambientArtwork) {
    const float padX = 2.0f, padY = 2.0f;
    const float fw = static_cast<float>(dstW) - padX * 2.0f;
    const float fh = static_cast<float>(dstH) - padY * 2.0f;

    if (dstH <= 36) {
        const float mPadX = 4.0f, mPadY = 3.0f;
        const float mW = static_cast<float>(dstW) - mPadX * 2.0f;
        const float mH = static_cast<float>(dstH) - mPadY * 2.0f;
        const float r = 2.5f;

        // 1. 外圈柔和深色外发光/投影 (利用四周 3~4px 留白区域)
        for (int i = 3; i >= 1; --i) {
            float exp = static_cast<float>(i) * 0.9f;
            GraphicsPath shadowPath;
            AddRoundedRectPath(shadowPath, mPadX - exp, mPadY - exp * 0.7f, mW + exp * 2.0f, mH + exp * 1.6f, r + exp);
            Pen shadowPen(Color(static_cast<BYTE>(22 * (4 - i)), 8, 10, 14), 1.4f);
            g.DrawPath(&shadowPen, &shadowPath);
        }

        // 2. 玻璃主体：全幅自上而下渐变烟熏背景雾（有文字/悬停时整体更深邃，无文字时也有质感暗灰渐变）
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

        // 3. 顶部 1px 玻璃高光折射带
        GraphicsState saved = g.Save();
        g.SetClip(&outer);
        Pen topSheen(Color(85, 255, 255, 255), 1.0f);
        g.DrawLine(&topSheen, mPadX + 1.0f, mPadY + 1.0f, mPadX + mW - 1.0f, mPadY + 1.0f);
        g.Restore(saved);

        // 4. 外圈亮白色半透明玻璃边框 + 极细外轮廓线
        Pen outerRimDark(Color(115, 20, 22, 26), 1.0f);
        g.DrawPath(&outerRimDark, &outer);

        GraphicsPath innerWhite;
        AddRoundedRectPath(innerWhite, mPadX + 0.75f, mPadY + 0.75f, mW - 1.5f, mH - 1.5f, std::max(1.5f, r - 0.5f));
        Pen whiteBorder(Color(175, 248, 250, 255), 1.0f);
        g.DrawPath(&whiteBorder, &innerWhite);
        return;
    }

    const float barH = 18.0f;
    // 左右严格留出 15px padding 的单层独立玻璃条
    const float gx = padX;
    const float gw = fw;

    // 1. 顶部单层玻璃条（无双层重影）
    {
        GraphicsPath topPath;
        AddRoundedRectPath(topPath, gx, padY, gw, barH + 2.0f, 4.5f);
        LinearGradientBrush topGlass(PointF(0, padY), PointF(0, padY + barH), Color(96, 224, 228, 236), Color(48, 152, 158, 166));
        g.FillPath(&topGlass, &topPath);
        Pen topBorder(Color(145, 14, 15, 18), 1.0f);
        g.DrawPath(&topBorder, &topPath);
    }

    // 2. 底部单层玻璃条（无双层重影）
    float botY = padY + fh - barH;
    {
        GraphicsPath botPath;
        AddRoundedRectPath(botPath, gx, botY - 2.0f, gw, barH + 2.0f, 4.5f);
        LinearGradientBrush botGlass(PointF(0, botY), PointF(0, padY + fh), Color(48, 152, 158, 166), Color(88, 214, 218, 226));
        g.FillPath(&botGlass, &botPath);
        Pen botBorder(Color(145, 14, 15, 18), 1.0f);
        g.DrawPath(&botBorder, &botPath);
    }

    // 3. 中间深色主躯干（自然压在上下玻璃条内缘上）
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
        Pen midRim(Color(focused ? 52 : 30, 255, 255, 255), 1.0f);
        g.DrawPath(&midDark, &midPath);
        GraphicsPath midInner;
        AddRoundedRectPath(midInner, padX + 1.0f, midY + 1.0f, fw - 2.0f, midH - 2.0f, 4.5f);
        g.DrawPath(&midRim, &midInner);
    }
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
        // Apple Music: 纯白双连音符矢量图标
        Pen beamPen(fg, 1.6f);
        Pen stemPen(fg, 1.35f);
        g.DrawLine(&stemPen, cx - 2.2f, cy + 3.2f, cx - 2.2f, cy - 3.0f);
        g.DrawLine(&stemPen, cx + 2.8f, cy + 2.2f, cx + 2.8f, cy - 4.0f);
        g.DrawLine(&beamPen, cx - 2.2f, cy - 3.0f, cx + 2.8f, cy - 4.0f);
        SolidBrush wb(fg);
        g.FillEllipse(&wb, cx - 4.6f, cy + 1.8f, 3.2f, 2.7f);
        g.FillEllipse(&wb, cx + 0.4f, cy + 0.8f, 3.2f, 2.7f);
    } else if (platformIdx == 1) {
        // Spotify: 纯白三道声波矢量图标
        Pen wave1(fg, 1.45f); wave1.SetStartCap(LineCapRound); wave1.SetEndCap(LineCapRound);
        Pen wave2(fg, 1.30f); wave2.SetStartCap(LineCapRound); wave2.SetEndCap(LineCapRound);
        Pen wave3(fg, 1.15f); wave3.SetStartCap(LineCapRound); wave3.SetEndCap(LineCapRound);
        g.DrawArc(&wave1, cx - 5.2f, cy - 3.6f, 10.4f, 6.2f, 218.0f, 104.0f);
        g.DrawArc(&wave2, cx - 4.1f, cy - 1.1f, 8.2f,  5.0f, 218.0f, 104.0f);
        g.DrawArc(&wave3, cx - 3.0f, cy + 1.3f, 6.0f,  3.8f, 218.0f, 104.0f);
    } else {
        // QQ 音乐: 纯白单音符矢量图标
        Pen stemPen(fg, 1.5f);
        stemPen.SetStartCap(LineCapRound);
        stemPen.SetEndCap(LineCapRound);
        g.DrawLine(&stemPen, cx + 0.2f, cy + 3.0f, cx + 0.2f, cy - 3.8f);
        g.DrawLine(&stemPen, cx + 0.2f, cy - 3.8f, cx + 3.8f, cy - 2.0f);
        SolidBrush wb(fg);
        g.FillEllipse(&wb, cx - 3.6f, cy + 1.2f, 4.5f, 3.4f);
    }
}

void GlassRenderer::DrawGlyphHaloText(Graphics& g, std::wstring const& text, FontFamily const& ff, float emSize,
                                      RectF const& rect, StringFormat const& sf, Color textColor, float alphaScale) {
    if (text.empty() || alphaScale <= 0.02f) return;

    // 1. 提取精确矢量字形轮廓并计算文字实际包围盒
    GraphicsPath glyphPath;
    glyphPath.AddString(text.c_str(), -1, &ff, FontStyleBold, emSize, rect, &sf);
    RectF bounds{};
    glyphPath.GetBounds(&bounds);
    float cx = bounds.X + bounds.Width * 0.5f;
    float cy = bounds.Y + bounds.Height * 0.5f;

    // 2. 横向“撕扯感”各向异性烟雾拖尾层 (Anisotropic Torn-Fog Smear)
    //    在水平方向做非对称拉长与微幅上下错位，模拟气流撕扯出的丝缕状暗雾
    struct TearLayer { float dx; float dy; float sx; float width; float alpha; };
    const TearLayer tears[] = {
        { -16.0f, -0.8f, 1.18f, 11.0f, 11.0f },
        {  17.5f,  0.6f, 1.20f, 11.5f, 11.0f },
        { -9.5f,   1.1f, 1.10f,  9.5f, 16.0f },
        {  10.5f, -1.0f, 1.12f,  9.5f, 16.0f },
        { -4.5f,  -0.4f, 1.05f,  8.0f, 20.0f },
        {  5.0f,   0.5f, 1.05f,  8.0f, 20.0f }
    };
    for (auto const& tl : tears) {
        BYTE a = static_cast<BYTE>(std::clamp(tl.alpha * alphaScale, 0.0f, 255.0f));
        if (a == 0) continue;
        GraphicsState st = g.Save();
        g.TranslateTransform(cx + tl.dx, cy + tl.dy);
        g.ScaleTransform(tl.sx, 0.92f);
        g.TranslateTransform(-cx, -cy);
        Pen tearPen(Color(a, 14, 16, 20), tl.width);
        tearPen.SetLineJoin(LineJoinRound);
        tearPen.SetMiterLimit(1.0f);
        g.DrawPath(&tearPen, &glyphPath);
        g.Restore(st);
    }

    // 3. 柔和多尺度高斯扩散外发光 (降低峰值透明度，消除一圈圈阶梯感)
    constexpr int kSamples = 12;
    constexpr float kMaxRadius = 18.0f;
    constexpr float kSigma = 7.2f;
    constexpr float kPeakAlpha = 26.0f;

    for (int i = kSamples; i >= 1; --i) {
        float t = static_cast<float>(i) / static_cast<float>(kSamples);
        float radius = kMaxRadius * (t * t * 0.6f + t * 0.4f);
        float gaussian = std::exp(-(radius * radius) / (2.0f * kSigma * kSigma));
        BYTE a = static_cast<BYTE>(std::clamp(kPeakAlpha * gaussian * alphaScale, 0.0f, 255.0f));
        if (a == 0) continue;

        Pen diffPen(Color(a, 14, 16, 20), radius * 2.0f);
        diffPen.SetLineJoin(LineJoinRound);
        diffPen.SetMiterLimit(1.0f);
        g.DrawPath(&diffPen, &glyphPath);
    }

    // 4. 极细微暗内嵌边缘，保持字形清晰但不过分生硬
    BYTE edgeA = static_cast<BYTE>(std::clamp(58.0f * alphaScale, 0.0f, 255.0f));
    if (edgeA > 0) {
        Pen rimPen(Color(edgeA, 18, 20, 24), 0.9f);
        rimPen.SetLineJoin(LineJoinRound);
        g.DrawPath(&rimPen, &glyphPath);
    }

    // 5. 填充更淡、更通透的浅雾灰色文字
    BYTE ta = static_cast<BYTE>(std::clamp(static_cast<float>(textColor.GetA()) * alphaScale, 0.0f, 255.0f));
    SolidBrush fill(Color(ta, textColor.GetR(), textColor.GetG(), textColor.GetB()));
    g.FillPath(&fill, &glyphPath);
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

